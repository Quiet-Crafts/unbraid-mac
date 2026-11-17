import CryptoKit
import Foundation

/// What a restore does to the traffic, asked of the compiler rather than worked out beside it: this Mac's setup and the
/// restored one are compiled the way the engine gets them (with stand-in tunnels for provider routes, which a sheet has
/// no sign-in for, and the same app patterns), and the same connections are walked through both configs' route rules as
/// the engine walks them: first match, `resolve` and `sniff` going on to the next rule. What each connection then gets
/// (refused, a tunnel, Direct; and whose resolver looks its names up) is compared.
nonisolated enum RestoreTraffic {
    /// How one connection leaves under a compiled config.
    struct Outcome: Equatable, Sendable {
        enum Exit: Equatable, Sendable { case rejected, direct, home, tunnel(String) }
        /// Who answers the lookups of its name: unbraid's DNS filter, the provider's own blocking, the local network's
        /// resolver, or the route's own. Nil for a connection to an address.
        enum Resolver: Equatable, Sendable { case filter, provider, local, route }
        var exit: Exit
        var resolver: Resolver?
    }

    /// A compiled config, read for walking.
    struct Config {
        var rules: [[String: Any]]
        var final: String
        var servers: [String: [String: Any]]
        var defaultResolver: String
        /// The addresses of providers' own blocking resolvers, to tell them from a route's ordinary one.
        var blocking: Set<String>
    }

    /// unbraid's own bundle as the compiler is given it (its traffic always goes direct).
    static let selfPattern = Compiler.pattern(forPath: "/Applications/unbraid.app", ignoringCase: true)
    /// A program no app rule names: it follows the default route.
    static let otherProgram = "/Applications/Another Program (unbraid check).app/Contents/MacOS/another"
    /// A name no website rule covers, and the address its lookup gets on a VPN: an ordinary site on the internet.
    static let otherName = "unbraid-check.example", publicAddress = "203.0.113.80"
    /// The address the fake resolver hands out for a name (the first stand-in range).
    static let fakeAddress = "198.18.0.5"

    /// The patterns the compiler would get for `keys`, made up from their keys as a backup's check does: an app's key
    /// names its bundle in /Applications, a tool's is its path.
    static func patterns(_ keys: some Sequence<String>) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: Set(keys).map { key in (key, [Compiler.pattern(forPath: key.hasPrefix("/") ? key : "/Applications/\(key).app", ignoringCase: true)]) })
    }

    /// `s` compiled with stand-in tunnels: a provider route gets a WireGuard tunnel of its own (provider routes can't be
    /// connected without a sign-in, which a restore doesn't touch), an own server's route its config, a route waiting for
    /// its config none (refused, as it is). Nil when the compiler refuses the setup.
    static func compile(_ s: Setup, apps: [String: [String]]) -> Config? {
        var links: [String: Link] = [:], blocked: Set<String> = []
        for (n, r) in s.routes.enumerated() {
            if LinkPicker.keyLeftOut(r, in: s) { blocked.insert(r.id) }
            else if let l = LinkPicker.imported(r) { links[r.id] = l }
            else { links[r.id] = standIn(r, n) }
        }
        let input = Compiler.Input(setup: s, links: links, blocked: blocked, apps: apps, selfPattern: selfPattern,
                                   tsSuffix: s.tailscale ? Compiler.trustedStoredSuffix(s.home) : nil)
        guard let text = try? Compiler.compile(input), let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let route = o["route"] as? [String: Any], let rules = route["rules"] as? [[String: Any]], let final = route["final"] as? String,
              let dns = o["dns"] as? [String: Any] else { return nil }
        let servers = Dictionary(((dns["servers"] as? [[String: Any]]) ?? []).compactMap { d in (d["tag"] as? String).map { ($0, d) } }) { a, _ in a }
        let blocking = Set(["nord", "mullvad", "pia", "ivpn"].compactMap { p in Providers.get(p)?.blockingDns { s.opt(p, $0) } })
        return Config(rules: rules, final: final, servers: servers,
                      defaultResolver: (route["default_domain_resolver"] as? String) ?? (dns["final"] as? String) ?? "local", blocking: blocking)
    }

    /// A WireGuard tunnel of its own for provider route `r`, made up: distinct per route, so no two share one.
    private static func standIn(_ r: Route, _ n: Int) -> Link {
        func key(_ salt: String) -> String { Data(SHA256.hash(data: Data((salt + r.id).utf8))).base64EncodedString() }
        let host = "198.51.100.\(n % 250 + 1)"
        let peer = WgPeer(name: r.name, privateKey: key("private"), address: ["10.5.0.2/32"], publicKey: key("public"), endpoint: "\(host):51820",
                          allowedIps: ["0.0.0.0/0"])
        return .wg(Server(name: r.name, host: host, ip: host, publicKey: peer.publicKey, load: 0), peer)
    }

    /// A TCP connection to port 443 from `process` (nil: none found) to `name` (looked up through the fake resolver,
    /// as every name is) or to `address`. Nil when a rule holds something this walk doesn't know.
    static func connect(_ c: Config, process: String?, name: String?, address: String = publicAddress) -> Outcome? {
        var ip = name == nil ? address : fakeAddress
        var resolver: String?
        var regexes: [String: NSRegularExpression] = [:]
        func regex(_ p: String) -> NSRegularExpression? {
            if let r = regexes[p] { return r }
            let r = try? NSRegularExpression(pattern: p)
            regexes[p] = r
            return r
        }
        func strings(_ v: Any?) -> [String] { (v as? [String]) ?? ((v as? String).map { [$0] } ?? []) }
        /// Whether `r` matches; nil when it holds a condition this walk can't judge.
        func matches(_ r: [String: Any]) -> Bool? {
            var hit = true
            // A rule's name conditions are one: any of them matching is enough, as in the engine.
            if r["domain"] != nil || r["domain_suffix"] != nil {
                let exact = strings(r["domain"]).contains { $0.lowercased() == name }
                let suffix = strings(r["domain_suffix"]).contains { s in name.map { n in s.hasPrefix(".") ? n.hasSuffix(s) : (n == s || n.hasSuffix("." + s)) } == true }
                hit = name != nil && (exact || suffix)
            }
            for (k, v) in r {
                switch k {
                case "action", "outbound", "server", "no_drop", "rewrite_ttl", "strategy", "rcode", "invert", "mode": continue
                case "type": guard v as? String == "logical" else { return nil }
                case "rules":
                    let subs = (v as? [[String: Any]]) ?? []
                    var results: [Bool] = []
                    for sub in subs { guard let m = matches(sub) else { return nil }; results.append(m) }
                    hit = hit && (r["mode"] as? String == "or" ? results.contains(true) : results.allSatisfy { $0 })
                case "inbound": hit = hit && strings(v).contains("tun")
                case "auth_user", "protocol": hit = false
                case "ip_version": hit = hit && (v as? Int) == 4
                case "network": hit = hit && strings(v).contains("tcp")
                case "port": hit = hit && ((v as? [Int])?.contains(443) ?? ((v as? Int) == 443))
                case "ip_cidr": hit = hit && strings(v).contains { contains($0, ip) }
                case "process_path_regex":
                    hit = hit && process.map { p in strings(v).contains { regex($0)?.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)) != nil } } == true
                case "domain", "domain_suffix": continue
                default: return nil
                }
            }
            return hit != (r["invert"] as? Bool == true)
        }
        func outcome(_ tag: String) -> Outcome {
            let exit: Outcome.Exit = tag == "direct" ? .direct : tag == "home-wg" ? .home : .tunnel(tag)
            return Outcome(exit: exit, resolver: name == nil ? nil : kind(c, resolver ?? c.defaultResolver))
        }
        for r in c.rules {
            guard let hit = matches(r) else { return nil }
            guard hit else { continue }
            if let o = r["outbound"] as? String { return outcome(o) }
            switch r["action"] as? String {
            case "reject": return Outcome(exit: .rejected)
            case "resolve":
                guard name != nil else { continue }
                resolver = (r["server"] as? String) ?? c.defaultResolver
                ip = publicAddress
            case "sniff", "route-options": continue
            default: return nil
            }
        }
        return outcome(c.final)
    }

    /// Whose resolver the DNS server `tag` is.
    private static func kind(_ c: Config, _ tag: String) -> Outcome.Resolver {
        if tag == "dns-filter" { return .filter }
        if tag == "local" { return .local }
        guard let d = c.servers[tag] else { return .route }
        // The filter is written with its own port (and TLS or a path); a route's resolver with neither.
        if d["server_port"] != nil { return .filter }
        if let a = d["server"] as? String, c.blocking.contains(a) { return .provider }
        return .route
    }

    private static func contains(_ cidr: String, _ ip: String) -> Bool {
        guard !cidr.contains(":"), !ip.contains(":"), let n = Compiler.canonical(cidr), let bits = n.split(separator: "/").last else { return false }
        return Compiler.canonical("\(ip)/\(bits)") == n
    }

    /// A path inside what `pattern` matches: a bundle's executable, or a tool itself.
    static func samplePath(_ pattern: String) -> String? {
        var p = pattern
        if p.hasPrefix("(?i)") { p.removeFirst(4) }
        guard p.hasPrefix("^") else { return nil }
        p.removeFirst()
        let bundle = p.hasSuffix("/")
        guard bundle || p.hasSuffix("$") else { return nil }
        p.removeLast()
        // Undo NSRegularExpression.escapedPattern: a backslash escapes the character after it.
        var out = "", escaped = false
        for ch in p {
            if escaped { out.append(ch); escaped = false } else if ch == "\\" { escaped = true } else { out.append(ch) }
        }
        return bundle ? out + "/Contents/MacOS/main" : out
    }

    // MARK: What gets weaker

    /// One app, website or home address whose connection protects less after the restore, and how.
    enum Loss: Equatable, Sendable { case unblocked, toDirect, filter, providerBlocking, homeDirect }

    static func loss(_ was: Outcome, _ now: Outcome) -> Loss? {
        if was.exit == .rejected { return now.exit == .rejected ? nil : .unblocked }
        if now.exit == .rejected { return nil }
        if was.exit != .direct, now.exit == .direct { return .toDirect }
        if was.resolver == .filter, now.resolver != .filter { return .filter }
        if was.resolver == .provider, now.resolver != .provider, now.resolver != .filter { return .providerBlocking }
        return nil
    }

    /// What a restore from `current` to `next` changes for the worse, item by item; nil when either setup can't be
    /// compiled (the caller then has no way to tell, and says so its own way).
    struct Losses: Equatable, Sendable {
        var defaultRoute: Loss?
        /// Per app key, per website name (a name and the probe under it count once), per home address.
        var apps: [String: Loss] = [:], sites: [String: Loss] = [:], home: [String: Loss] = [:]
    }

    static func losses(_ current: Setup, _ next: Setup, apps given: [String: [String]]? = nil) -> Losses? {
        let keys = Set(current.apps.keys).union(next.apps.keys).union(current.prefs.effectiveFilter.apps.keys).union(next.prefs.effectiveFilter.apps.keys)
        let apps = (given ?? [:]).merging(patterns(keys.subtracting(given?.keys.map { $0 } ?? []))) { a, _ in a }
        guard let was = compile(current, apps: apps), let now = compile(next, apps: apps) else { return nil }
        func pair(_ process: String?, _ name: String?, _ address: String = publicAddress) -> (Outcome, Outcome)? {
            guard let a = connect(was, process: process, name: name, address: address), let b = connect(now, process: process, name: name, address: address) else { return nil }
            return (a, b)
        }
        var out = Losses()
        guard let d = pair(otherProgram, otherName) else { return nil }
        out.defaultRoute = loss(d.0, d.1)
        for (key, patterns) in apps.sorted(by: { $0.key < $1.key }) {
            guard let path = patterns.lazy.compactMap(samplePath).first, let o = pair(path, otherName) else { continue }
            out.apps[key] = loss(o.0, o.1)
        }
        let names = Set(Sites.applied(current).keys).union(Sites.applied(next).keys)
        for name in names.sorted() {
            let found = [name, "zz-check." + name].compactMap { pair(otherProgram, $0) }.compactMap { loss($0.0, $0.1) }
            out.sites[name] = found.first
        }
        // Addresses of the home networks either setup reaches through a tunnel, and one on the local network.
        let ranges = [current, next].flatMap { s in (s.home.tailscale ? s.home.subnets : []) + (s.home.wg.map(Compiler.homeCidrs) ?? []) }
        for address in Set(ranges.compactMap(firstHost) + ["192.168.1.20"]).sorted() {
            // Through the home tunnel (or the tailnet) before, Direct after.
            guard let o = pair(otherProgram, nil, address), o.0.exit == .home || o.0.exit == .tunnel(Compiler.tsTag), o.1.exit == .direct else { continue }
            out.home[address] = .homeDirect
        }
        return out
    }

    /// The first host address of an IPv4 range.
    private static func firstHost(_ cidr: String) -> String? {
        guard let n = Compiler.canonical(cidr), !n.contains(":") else { return nil }
        let parts = n.split(separator: "/")[0].split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        let v = (parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3]) &+ 1
        return [v >> 24, v >> 16 & 255, v >> 8 & 255, v & 255].map(String.init).joined(separator: ".")
    }
}
