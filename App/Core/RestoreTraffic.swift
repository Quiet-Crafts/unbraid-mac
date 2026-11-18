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
    final class Config {
        let rules: [[String: Any]]
        /// The lookup rules, and the resolver of what none claims.
        var dns: [[String: Any]] = [], dnsFinal = "local"
        let final: String
        let servers: [String: [String: Any]]
        let defaultResolver: String
        /// The addresses of providers' own blocking resolvers, to tell them from a route's ordinary one.
        let blocking: Set<String>
        /// One matcher per list of program patterns a rule holds, made once for every walk of this config. The patterns
        /// the compiler writes for apps are literal paths (`Compiler.pattern(forPath:)`): those are compared as text;
        /// anything else is one expression for the whole list.
        private var matchers: [[String]: Matcher] = [:]
        private struct Matcher {
            /// Bundles (a path inside), tools (that path), each lower-cased when the pattern ignores case.
            var bundles: [(String, Bool)] = [], tools: [(String, Bool)] = []
            var rest: NSRegularExpression?
            func matches(_ path: String) -> Bool {
                let lower = path.lowercased()
                if bundles.contains(where: { ($0.1 ? lower : path).hasPrefix($0.0) }) { return true }
                if tools.contains(where: { ($0.1 ? lower : path) == $0.0 }) { return true }
                return rest?.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
            }
        }

        init(rules: [[String: Any]], final: String, servers: [String: [String: Any]], defaultResolver: String, blocking: Set<String>) {
            (self.rules, self.final, self.servers, self.defaultResolver, self.blocking) = (rules, final, servers, defaultResolver, blocking)
        }

        func matches(_ patterns: [String], _ path: String) -> Bool {
            if let m = matchers[patterns] { return m.matches(path) }
            var m = Matcher(), other: [String] = []
            for p in patterns {
                let fold = p.hasPrefix("(?i)")
                // Literal only when it reads back to exactly the pattern the compiler would write for it.
                if let sample = samplePath(p) {
                    let bundle = p.hasSuffix("/"), path = bundle ? String(sample.dropLast("/Contents/MacOS/main".count)) : sample
                    if Compiler.pattern(forPath: path, ignoringCase: fold) == p {
                        if bundle { m.bundles.append(((fold ? path.lowercased() : path) + "/", fold)) } else { m.tools.append((fold ? path.lowercased() : path, fold)) }
                        continue
                    }
                }
                other.append(p)
            }
            if !other.isEmpty { m.rest = try? NSRegularExpression(pattern: other.map { "(?:\($0))" }.joined(separator: "|")) }
            matchers[patterns] = m
            return m.matches(path)
        }
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
        let c = Config(rules: rules, final: final, servers: servers,
                       defaultResolver: (route["default_domain_resolver"] as? String) ?? (dns["final"] as? String) ?? "local", blocking: blocking)
        c.dns = (dns["rules"] as? [[String: Any]]) ?? []
        c.dnsFinal = dns["final"] as? String ?? "local"
        return c
    }

    /// A WireGuard tunnel of its own for provider route `r`, made up: distinct per route, so no two share one.
    private static func standIn(_ r: Route, _ n: Int) -> Link {
        func key(_ salt: String) -> String { Data(SHA256.hash(data: Data((salt + r.id).utf8))).base64EncodedString() }
        let host = "198.51.100.\(n % 250 + 1)"
        let peer = WgPeer(name: r.name, privateKey: key("private"), address: ["10.5.0.2/32"], publicKey: key("public"), endpoint: "\(host):51820",
                          allowedIps: ["0.0.0.0/0"])
        return .wg(Server(name: r.name, host: host, ip: host, publicKey: peer.publicKey, load: 0), peer)
    }

    /// A TCP connection to port 443 from `process` (nil: none found) to `name` or to `address`. The name is first looked
    /// up as the system resolver asks for every app (with no program to match): refused or not found, nothing connects
    /// (rejected); a stand-in address, and the connection carries the name to the website rules; a real one from a
    /// resolver of its own (the tailnet's, the local network's), and it goes to that address by no name. Nil when a rule
    /// holds something this walk doesn't know.
    static func connect(_ c: Config, process given: String?, name looked: String?, address: String = publicAddress) -> Outcome? {
        var ip = looked == nil ? address : fakeAddress
        var resolver: String?
        var qtype: String?, process = given, name = looked
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
                case "query_type": hit = hit && qtype.map { strings(v).contains($0) } == true
                case "auth_user", "protocol": hit = false
                case "ip_version": hit = hit && (v as? Int) == 4
                case "network": hit = hit && strings(v).contains("tcp")
                case "port": hit = hit && ((v as? [Int])?.contains(443) ?? ((v as? Int) == 443))
                case "ip_cidr": hit = hit && strings(v).contains { contains($0, ip) }
                case "process_path_regex":
                    hit = hit && process.map { c.matches(strings(v), $0) } == true
                case "domain", "domain_suffix": continue
                default: return nil
                }
            }
            return hit != (r["invert"] as? Bool == true)
        }
        func outcome(_ tag: String) -> Outcome {
            let exit: Outcome.Exit = tag == "direct" ? .direct : tag == "home-wg" ? .home : .tunnel(tag)
            return Outcome(exit: exit, resolver: looked == nil ? nil : kind(c, resolver ?? c.defaultResolver))
        }
        if looked != nil {
            qtype = "A"
            var answer: String? = nil
            process = nil
            for r in c.dns {
                guard let hit = matches(r) else { return nil }
                guard hit else { continue }
                answer = r["action"] as? String == "predefined" ? "" : r["server"] as? String ?? ""
                break
            }
            process = given
            qtype = nil
            switch answer ?? c.dnsFinal {
            case "": return Outcome(exit: .rejected)
            case "fake": break
            case let server: resolver = server; name = nil; ip = publicAddress
            }
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
    enum Loss: Equatable, Sendable, CaseIterable { case unblocked, toDirect, filter, providerBlocking, homeDirect }

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

    /// How bad a loss is, so the worst of several (an app's copies, a website seen from several apps) is the one kept.
    private static func rank(_ l: Loss?) -> Int { switch l { case .unblocked: 5; case .toDirect, .homeDirect: 4; case .filter: 3; case .providerBlocking: 2; case nil: 0 } }

    /// The most walks one comparison makes: every app, website and address is walked at least once whatever this
    /// says; websites are walked from every kind of app only while this allows.
    static let maxWalks = 20_000

    static func losses(_ current: Setup, _ next: Setup, apps given: [String: [String]]? = nil) -> Losses? {
        let keys = Set(current.apps.keys).union(next.apps.keys).union(current.prefs.effectiveFilter.apps.keys).union(next.prefs.effectiveFilter.apps.keys)
        let all = (given ?? [:]).merging(patterns(keys.subtracting(given?.keys.map { $0 } ?? []))) { a, _ in a }
        // Apps the compiler can't tell apart (the same choice and filter switch on both sides, one copy, none inside
        // another's bundle or around one) go the same way: one of each is compiled and walked, and stands for the rest.
        let nested = nesting(all)
        var stands: [String: String] = [:], groups: [String: String] = [:]
        for key in all.keys.sorted() {
            guard !nested.contains(key), all[key]?.count == 1 else { stands[key] = key; continue }
            let f = (current.prefs.effectiveFilter.apps[key], next.prefs.effectiveFilter.apps[key])
            let kind = "\(current.apps[key] ?? "-")|\(next.apps[key] ?? "-")|\(String(describing: f.0))|\(String(describing: f.1))"
            if groups[kind] == nil { groups[kind] = key }
            stands[key] = groups[kind]
        }
        let apps = all.filter { stands[$0.key] == $0.key }
        guard let was = compile(current.keeping(apps.keys), apps: apps), let now = compile(next.keeping(apps.keys), apps: apps) else { return nil }
        func pair(_ process: String?, _ name: String?, _ address: String = publicAddress) -> (Outcome, Outcome)? {
            guard let a = connect(was, process: process, name: name, address: address), let b = connect(now, process: process, name: name, address: address) else { return nil }
            return (a, b)
        }
        var out = Losses()
        guard let d = pair(otherProgram, otherName) else { return nil }
        out.defaultRoute = loss(d.0, d.1)
        // Every copy of every app (a bundle can be installed in more than one place, or inside another), the worst kept.
        // Copies that go the same way before and after are one kind of app, for the websites below.
        var kinds: [String: String] = ["\(d.0)|\(d.1)": otherProgram]
        // What each walked program loses on its own: a website seen from it says only what is the website's.
        var own: [String: Loss] = [:]
        own[otherProgram] = out.defaultRoute
        for (key, patterns) in apps.sorted(by: { $0.key < $1.key }) {
            var worst: Loss?
            for path in Set(patterns.compactMap(samplePath)).sorted() {
                guard let o = pair(path, otherName) else { continue }
                let l = loss(o.0, o.1)
                if rank(l) > rank(worst) { worst = l }
                if kinds["\(o.0)|\(o.1)"] == nil { kinds["\(o.0)|\(o.1)"] = path; own[path] = l }
            }
            out.apps[key] = worst
        }
        for (key, stand) in stands where stand != key { out.apps[key] = out.apps[stand] }
        // Every name with a website rule on either side, and one under it, from every kind of app: a website rule
        // comes before its app's route, so a name given Direct takes an app on a VPN there too.
        // Every saved one, applied or not: whether its name's own resolver comes first is the walk's to find.
        let names = Set(current.sites.keys).union(next.sites.keys).filter(Sites.isClean).sorted()
        let programs = [otherProgram] + kinds.values.filter { $0 != otherProgram }.sorted()
        let fromApps = names.count * 2 * programs.count <= maxWalks ? programs : [otherProgram]
        // A tailnet's own domain under a saved website (example.org above corp.example.org) is probed too, said for that
        // website: whether its names get an answer of their own can change with the restore while the website doesn't.
        let domains = Set([Sites.tailnet(of: current), Sites.tailnet(of: next)].compactMap { $0 })
        for name in names {
            var worst: Loss?
            for probe in [name, "zz-check." + name] + domains.filter({ $0 != name && Sites.under($0, name) }).sorted().map({ "zz-check." + $0 }) {
                for program in fromApps {
                    guard let o = pair(program, probe) else { continue }
                    let l = loss(o.0, o.1)
                    // The app's own change (unblocked, say) is said for the app, not again for each website it opens.
                    if l == own[program] ?? nil { continue }
                    if rank(l) > rank(worst) { worst = l }
                }
            }
            out.sites[name] = worst
        }
        // The edges of every home range either setup reaches through a tunnel (its first and last address: a range
        // narrowed at either end shows there), and one on the local network.
        let ranges = [current, next].flatMap { s in (s.home.tailscale ? s.home.subnets : []) + (s.home.wg.map(Compiler.homeCidrs) ?? []) }
        for address in Set(ranges.flatMap(edges) + ["192.168.1.20"]).sorted() {
            // Through the home tunnel (or the tailnet) before, Direct after.
            guard let o = pair(otherProgram, nil, address), o.0.exit == .home || o.0.exit == .tunnel(Compiler.tsTag), o.1.exit == .direct else { continue }
            out.home[address] = .homeDirect
        }
        return out
    }

    /// The apps whose patterns lie inside another's bundle, or hold another's: found by walking up each path, not by
    /// comparing every pair.
    private static func nesting(_ apps: [String: [String]]) -> Set<String> {
        var owner: [String: String] = [:]
        for (key, patterns) in apps { for p in patterns where p.hasSuffix("/") { if let path = samplePath(p) { owner[String(path.dropLast("/Contents/MacOS/main".count)).lowercased()] = key } } }
        var out: Set<String> = []
        for (key, patterns) in apps {
            for p in patterns {
                guard let path = samplePath(p)?.lowercased() else { out.insert(key); continue }
                var up = (path as NSString).deletingLastPathComponent
                // A bundle's own sample lies inside itself: start above the bundle.
                if p.hasSuffix("/") { up = ((up as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent }
                while up.count > 1 {
                    if let o = owner[up], o != key { out.insert(key); out.insert(o) }
                    up = (up as NSString).deletingLastPathComponent
                }
            }
        }
        return out
    }

    /// The first and last host addresses of an IPv4 range; a /32 or /31 its own addresses.
    static func edges(_ cidr: String) -> [String] {
        guard let n = Compiler.canonical(cidr), !n.contains(":") else { return [] }
        let halves = n.split(separator: "/"), bits = Int(halves[1]) ?? 32
        let parts = halves[0].split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return [] }
        let base = parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3]
        let last = base | (bits == 0 ? UInt32.max : (UInt32(1) << (32 - bits)) &- 1)
        let ends = bits >= 31 ? [base, last] : [base &+ 1, last &- 1]
        return Set(ends).sorted().map { v in [v >> 24, v >> 16 & 255, v >> 8 & 255, v & 255].map(String.init).joined(separator: ".") }
    }

}

nonisolated private extension Setup {
    /// This setup with only the app choices and filter switches of `keys` (the apps that stand for the others).
    func keeping(_ keys: some Collection<String>) -> Setup {
        let k = Set(keys)
        var s = self
        s.apps = apps.filter { k.contains($0.key) }
        s.prefs.filter.apps = prefs.filter.apps.filter { k.contains($0.key) }
        return s
    }
}
