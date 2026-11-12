import CryptoKit
import Darwin
import Foundation

/// Turns a Setup into a sing-box config.
///
/// Order of decisions for every connection: anything coming in through a tunnel is refused → DNS → unbraid itself →
/// blocked apps → home networks → LAN → the app's route → default route. On macOS every app goes through the tunnel and is matched by the path of the process that
/// owns the connection: Direct apps leave through the engine's `direct` outbound, blocked apps are refused.
nonisolated enum Compiler {
    static let nordDns = "103.86.96.100"
    static let nordTP = "103.86.96.108"
    static let tsTag = "home-ts"
    /// Inbound tag of the app's own way into a chosen exit, for speed and health tests: a proxy on 127.0.0.1 whose
    /// user name is the exit's tunnel tag and whose password is random per engine start.
    static let probeTag = "probe"
    /// In-tunnel blocking resolvers, from each provider's docs: Mullvad ads+trackers+malware, PIA MACE, IVPN AntiTracker.
    static let filterDns = ["mullvad": "100.64.0.7", "pia": "10.0.0.244", "ivpn": "10.0.254.2"]
    static let lan = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4", "255.255.255.255/32"]
    /// Local IPv6 that must never be refused with the rest of IPv6: unique-local, link-local, multicast.
    static let lan6 = ["fc00::/7", "fe80::/10", "ff00::/8"]
    static let tailnet = "100.64.0.0/10"

    struct Input: Sendable {
        var setup: Setup
        var links: [String: Link]
        /// Automatic port rotation per provider.
        var portStep: [String: Int] = [:]
        /// Routes without a usable tunnel. Their traffic is refused until a tunnel is available.
        var blocked: Set<String> = []
        /// Process path patterns per app key (bundle id or tool path); apps not installed have none, except where they
        /// were last seen (see `remembered`). Keys the setup doesn't route only count as apps here.
        var apps: [String: [String]]
        /// App keys whose patterns are only places they were last seen: not on this Mac now. Their rules stay (one
        /// installed there again is matched from its first connection), but they don't count as an app blocked or on
        /// an exit for what guards the whole Mac (ping, connections without an owner, HTTPS lookups): that would hold
        /// for good for an app that is gone, and the scan after its return restores it.
        var remembered: Set<String> = []
        /// unbraid's own bundle: its provider sign-ins and catalogue downloads never depend on a tunnel.
        var selfPattern: String
        /// The tailnet's MagicDNS domain, if known and accepted (Store.tsSuffix).
        var tsSuffix: String?
        /// Loopback port and password of the app's own way into each exit; nil = none.
        var probe: (port: Int, password: String)?
        /// What happens to connections whose program can't be found (see `Ownerless`).
        var ownerless: Ownerless = .refusedWhileBlocking
        var tsLoginPending = false
    }

    /// A connection whose program the engine can't find (it ended right after sending, the socket was the kernel's, or
    /// the lookup failed) matches no app rule, Block's included, and would take the default route. Refusing it is safer
    /// but can break traffic that has no owner for legitimate reasons, so the choice is one place:
    /// - followsDefault: as before, the default route (Direct, or the default VPN).
    /// - refusedWhileBlocking (default): refused while any app is blocked, so a blocked app can't get out that way.
    /// - refusedWhileSplit: also refused with Direct as the default and apps on a VPN, so a VPN app's last packets can't
    ///   leave from the Mac's own address.
    /// LAN, home, tailnet and unbraid's own traffic are decided before, and ping has its own rule.
    enum Ownerless: Sendable { case followsDefault, refusedWhileBlocking, refusedWhileSplit }

    /// Route id → the tunnel tag it runs on: routes that resolve to one server with one login share a tunnel.
    static func shared(_ s: Setup, _ links: [String: Link], blocked: Set<String> = []) throws -> [String: String] {
        guard clashes(s, links.filter { !blocked.contains($0.key) }).isEmpty else { throw Refused(clashMessage) }
        var owners: [String: String] = [:]
        var out: [String: String] = [:]
        for r in s.activeRoutes where r.tsExit == nil && !blocked.contains(r.id) {
            guard let link = links[r.id] else { throw Fail("No server for \(r.name)") }
            let key = linkKey(r, link)
            if owners[key] == nil { owners[key] = "r-\(r.id)" }
            out[r.id] = owners[key]
        }
        return out
    }

    static func compile(_ input: Input) throws -> String {
        var i = input
        i.links = LinkPicker.ported(i.setup, i.links, step: i.portStep)
        return try build(i).string
    }

    /// The resolver used by each health-checked exit.
    static func probeDNS(_ input: Input) throws -> [String: String] {
        var i = input
        i.links = LinkPicker.ported(i.setup, i.links, step: i.portStep)
        return try Plan(i).probeTags
    }

    /// What a change that failed twice leaves running (`Connection.recover`): every app that would go through a VPN
    /// route is blocked, as Block blocks (connections and lookups refused, the local network only as Settings allow
    /// blocked apps), and so is everything else unless Direct is the default: connections refused before anything is
    /// looked up for them, lookups that no Direct app asked for refused. Direct apps and unbraid itself go direct (a
    /// Direct app inside the bundle of an app on a VPN is blocked with it). No tunnel and no credentials, so nothing a
    /// provider or the tailnet could fail on. Built again from its own output, it comes out the same.
    static func denyAll(_ i: Input) throws -> String {
        let blocking = denyAllInput(i)
        return try build(blocking, deny: blocking.setup.defaultRoute == denied).string
    }

    /// What `denyAll` builds from [i]: no route, no link, no probe, nothing of the home tunnels; each app Direct or blocked.
    static func denyAllInput(_ i: Input) -> Input {
        let s = i.setup
        var prefs = s.prefs
        // As for a pause: without the home tunnels a remote home's subnets can't be told from this network.
        if s.home.wg != nil || (s.home.tailscale && !s.home.subnets.isEmpty), prefs.killLevel == .internet { prefs.killSwitchHome = true }
        // With a VPN as the default, the default route is one no route answers to: Direct apps then get rules of their
        // own, ahead of the refusal of everything else.
        let deny = s.defaultRoute != DIRECT
        var blocking = i
        var apps = s.apps.mapValues { $0 == DIRECT ? DIRECT : BLOCK }
        // An app on a VPN default inside a Direct app's bundle (`nestedDefaults`) is blocked with the other VPN apps.
        if deny { for key in nestedDefaults(s, i.apps) { apps[key] = BLOCK } }
        blocking.setup = Setup(routes: [], defaultRoute: deny ? denied : DIRECT, apps: apps, favorites: [], prefs: prefs)
        blocking.links = [:]
        blocking.blocked = []
        blocking.probe = nil
        return blocking
    }

    /// What the extension seals in place of a copy a sign-out or erase removed while Connect on Demand couldn't be turned
    /// off (`Connection.sealFallbackIfStuck`): nothing set up (no route, no app, no home, no tailnet), everything direct,
    /// with the user's kill-switch and local-network preferences. No account and no server: what macOS starts from it
    /// keeps the Mac online.
    static func fallback(prefs: Prefs, selfPattern: String) throws -> String {
        var prefs = prefs
        prefs.filter = Filter(); prefs.customDns = []
        let setup = Setup(routes: [], defaultRoute: DIRECT, apps: [:], favorites: [], home: Home(), prefs: prefs, servers: [])
        return try compile(Input(setup: setup, links: [:], apps: [:], selfPattern: selfPattern, tsSuffix: nil, probe: nil))
    }

    /// The system resolver: its lookups are everyone's, so a deny-all never refuses it as an app (see `othersRefused`).
    static let systemResolver = "^/usr/sbin/mDNSResponder$"

    /// The default route of a deny-all configuration that doesn't let everything else out directly.
    static let denied = "denied"
    private static let filteredDirect = "__filtered_direct"

    /// The tailnet's search domain the tunnel's resolver gets with [i] (short names expand to it, as with the Tailscale
    /// app): its MagicDNS domain while the setup has a Tailscale home and the extension takes the name, otherwise none ("").
    /// [tailnet]: whether the user's setup has one, when [i] runs without its home (a pause, a deny-all): the domain stays,
    /// so a short tailnet name still expands to it and is refused (see `dns`) rather than asked of the local network.
    static func searchDomain(_ i: Input, tailnet: Bool? = nil) -> String {
        guard tailnet ?? i.setup.home.tailscale, let d = tsSuffix(i.tsSuffix), Staging.isSearchDomain(d) else { return "" }
        return d
    }

    /// [deny]: what no app rule claims is refused (see `denyAll`).
    private static func build(_ i: Input, deny: Bool = false) throws -> J {
        let p = try Plan(i, deny: deny)
        let (endpoints, outbounds) = try transports(p)
        let tunnels = Array(Set(endpoints.compactMap { $0["tag"]?.str })).sorted()
        let config: J = [
            "log": ["level": "warn", "timestamp": false],
            "dns": dns(p, refusing: tunnels),
            "inbounds": .a(inbounds(p)),
            "endpoints": .a(endpoints),
            "outbounds": .a(outbounds),
            "route": ["rules": .a(routingRules(p, refusing: tunnels)), "final": .s(p.active.isEmpty || p.i.blocked.contains(p.s.defaultRoute) ? "direct" : p.tag(p.s.defaultRoute)),
                      "auto_detect_interface": true, "default_domain_resolver": "local"],
            "experimental": ["cache_file": ["enabled": true, "path": "cache.db", "store_fakeip": true]],
        ]
        return config
    }

    /// What every part of the config reads, decided once: the routes in use, the tunnel each runs on, the apps matched
    /// to them and the home ranges.
    private struct Plan {
        let s: Setup
        let i: Input
        let active: [Route]
        /// Route id → its tunnel tag (see `shared`).
        let shared: [String: String]
        /// Apps with their own route (or the default one, inside a bundle with another), grouped by route, matched by the
        /// paths of their processes. Apps not installed match nothing and are left out, unless remembered where they were.
        let perApp: [(id: String, match: J)]
        /// Whether an app installed here is blocked, and whether one is on an exit of its own (see `Input.remembered`).
        let blocking: Bool
        let appsOnExits: Bool
        /// Ranges reached through a home tunnel: the tailnet's advertised subnets and the home WireGuard's.
        let home: [String]
        /// Every tunnel the app can test → the DNS of a route on it.
        let probeTags: [String: String]
        /// Where lookups no rule claims go (mDNSResponder's for every app, and `final` for the engine's own, though its
        /// servers' names are resolved on `local` by `default_domain_resolver`): the default VPN's resolver, or the local
        /// one with Direct as the default or no route in use.
        let defaultDns: String
        /// What no app rule claims is refused, connections and lookups (`denyAll`).
        let deny: Bool

        init(_ i: Input, deny: Bool = false) throws {
            let s = i.setup, active = s.activeRoutes.filter { !i.blocked.contains($0.id) }
            self.s = s; self.i = i; self.active = active; self.deny = deny
            // Block is an app's choice, not a default: everything else would go Direct, or to tunnels that don't exist.
            guard s.defaultRoute != BLOCK else { throw Fail("Block can't be the default route. Make Direct or a VPN route the default.") }
            // A default that names no route (a damaged or older saved setup) would send everything Direct when nothing else
            // is in use, and name a tunnel that doesn't exist otherwise: refused either way, never silently Direct.
            guard deny || s.defaultRoute == DIRECT || s.route(s.defaultRoute) != nil else {
                throw Fail("The default route is no longer one of your routes. Choose a default route in unbraid, then connect again.")
            }
            guard Set(active.compactMap(\.tsExit)).count <= 1 else {
                throw Fail("Tailscale allows one exit node at a time. Use the same node for every Tailscale route.")
            }
            // Tailscale-exit routes ride the Tailscale endpoint, whose exit node is set there. Routes that resolve to the
            // same server with the same credentials share one tunnel: two with one key would fight over it.
            shared = try Compiler.shared(s, i.links, blocked: i.blocked)
            var byRoute: [(id: String, patterns: [String])] = []
            // The setup keeps no entry for an app on the default route: one nested in a bundle routed elsewhere is
            // grouped with the default route here (`nestedDefaults`).
            let routeOf = { (key: String) in s.apps[key] ?? s.defaultRoute }
            for (id, keys) in Dictionary(grouping: Array(s.apps.keys) + Compiler.nestedDefaults(s, i.apps), by: { routeOf($0) == DIRECT && s.prefs.effectiveFilter.through($0) ? Compiler.filteredDirect : routeOf($0) }).sorted(by: { $0.key < $1.key })
            where id == DIRECT || id == Compiler.filteredDirect || id == BLOCK || s.activeRoutes.contains(where: { $0.id == id }) {
                let patterns = keys.sorted().flatMap { i.apps[$0] ?? [] }
                if !patterns.isEmpty { byRoute.append((id, patterns)) }
            }
            // An app inside another's bundle (Simulator inside Xcode, a helper tool) matches the outer bundle's pattern
            // too, and the first rule wins: patterns go first by how many app bundles contain them, so the innermost
            // assignment decides whatever the routes are called. Without nesting this is one group per route, by id.
            // An app on the default route needs no rule of its own, unless it sits inside a bundle with another route: then
            // its rule keeps it (connections and lookups) on the default route.
            let all = Set(byRoute.flatMap(\.patterns)), assigned = byRoute.filter { $0.id != s.defaultRoute }.flatMap(\.patterns)
            var tiers: [(depth: Int, order: Int, id: String, patterns: [String])] = []
            for (order, g) in byRoute.enumerated() {
                let own = g.id != s.defaultRoute || (g.id == DIRECT && s.prefs.effectiveFilter.server != nil && s.prefs.effectiveFilter.direct) ? g.patterns : g.patterns.filter { p in assigned.contains { Compiler.contains($0, p) } }
                let byDepth = Dictionary(grouping: own) { p in all.filter { Compiler.contains($0, p) }.count }
                tiers += byDepth.map { (depth: $0.key, order: order, id: g.id, patterns: $0.value) }
            }
            perApp = tiers.sorted { ($1.depth, $0.order) < ($0.depth, $1.order) }.map { (id: $0.id, match: J.strings($0.patterns)) }
            // Only patterns of apps here count; a pattern an app here shares with one remembered is that app's. A blocked
            // bundle remembered still refuses an app here inside it, so that one counts as blocked, routed or not (a pause
            // routes blocks only, but passes every app's patterns).
            let live = Set(i.apps.filter { !i.remembered.contains($0.key) }.values.joined())
            let liveRoutes = Set(tiers.filter { !live.isDisjoint(with: $0.patterns) }.map(\.id))
            let blockedPatterns = tiers.filter { $0.id == BLOCK || i.blocked.contains($0.id) }.flatMap(\.patterns)
            blocking = liveRoutes.contains(BLOCK) || !liveRoutes.isDisjoint(with: i.blocked) || blockedPatterns.contains { b in live.contains { Compiler.contains(b, $0) } }
            appsOnExits = liveRoutes.contains { $0 != DIRECT && $0 != Compiler.filteredDirect && $0 != BLOCK }
            home = (s.home.tailscale ? homeSubnets(s) : []) + (s.home.wg.map(homeCidrs) ?? [])
            defaultDns = s.defaultRoute == DIRECT && s.prefs.effectiveFilter.server != nil && s.prefs.effectiveFilter.direct && !deny ? "dns-filter" : s.defaultRoute == DIRECT || active.isEmpty || i.blocked.contains(s.defaultRoute) ? "local" : Self.dns(s.defaultRoute, s, shared, i.links)
            // Tailscale even without an exit route (its nodes). Health checks distinguish failed exits from an offline Mac,
            // including when STUN is blocked, so Direct joins any other.
            var probeTags: [String: String] = [:]
            for r in active where probeTags[Self.tag(r.id, s, shared)] == nil { probeTags[Self.tag(r.id, s, shared)] = Self.dns(r.id, s, shared, i.links) }
            if s.tailscale, probeTags[tsTag] == nil { probeTags[tsTag] = defaultDns }
            if !probeTags.isEmpty { probeTags["direct"] = "local" }
            self.probeTags = probeTags
        }

        private static func tag(_ id: String, _ s: Setup, _ shared: [String: String]) -> String {
            (id == DIRECT || id == Compiler.filteredDirect) ? "direct" : s.route(id)?.tsExit != nil ? tsTag : shared[id] ?? "r-\(id)"
        }

        func tag(_ id: String) -> String { Self.tag(id, s, shared) }
        private static func dns(_ id: String, _ s: Setup, _ shared: [String: String], _ links: [String: Link]) -> String {
            if id == Compiler.filteredDirect { return "dns-filter" }
            if id == DIRECT { return "local" }
            if s.prefs.effectiveFilter.coversRoutes { return "dns-\(tag(id, s, shared))" }
            if let r = s.route(id), case .ovpn = links[id], !s.prefs.effectiveFilter.coversRoutes && (r.imported || r.loc.provider != "nord") {
                return "dns-ovpn-\(tag(id, s, shared))"
            }
            return "dns-r-\(id)"
        }
        func dns(_ id: String) -> String { Self.dns(id, s, shared, i.links) }
        func onTs(_ id: String) -> Bool { s.route(id)?.tsExit != nil }
        var homeTs: Bool { s.home.tailscale }
        /// OpenVPN routes use the DNS their server pushes, except NordVPN's own: those keep Nord's resolvers.
        func pushedDns(_ r: Route) -> Bool { !s.prefs.effectiveFilter.coversRoutes && (r.imported || r.loc.provider != "nord") }
        /// The match of the blocked apps, installed here or remembered where they were; a block with nothing to match
        /// changes nothing. `blocking`: one is installed here. `appsOnExits`: apps here kept on an exit of their own, whose
        /// lookups and pings must not leave by the default route.
        var blocked: [J] { perApp.filter { $0.id == BLOCK }.map(\.match) }
        /// In a deny-all whose blocked apps don't keep the local network, what has a program that is neither unbraid, a
        /// Direct app nor the system resolver (an app following the VPN default) is refused as a blocked app is, where a
        /// blocked app is: before DNS (its own lookups never reach a resolver) and the local network. Traffic without a
        /// program keeps the exceptions documented for it. Nil otherwise.
        var othersRefused: J? {
            guard deny, !s.prefs.blockedAppsReachLAN else { return nil }
            let own = [J.s(i.selfPattern), .s(Compiler.systemResolver)] + perApp.filter { $0.id == DIRECT || $0.id == Compiler.filteredDirect }.flatMap { $0.match.list ?? [] }
            return ["type": "logical", "mode": "and", "action": "reject",
                    "rules": [["process_path_regex": ["."]], ["process_path_regex": .a(own), "invert": true]]]
        }
    }

    /// Order of decisions: what comes in through a tunnel → blocked apps → DNS → the app's own tests → unbraid itself →
    /// home networks and LAN → each app's route → the default route.
    private static func routingRules(_ p: Plan, refusing tunnels: [String]) -> [J] {
        let s = p.s
        // Destination rules that beat any app rule, repeated after every resolve: fake-IP connections only get a real
        // address there.
        let unspecified: J = ["ip_cidr": ["0.0.0.0/32", "::/128"], "action": "reject", "no_drop": true]
        var network: [J] = [unspecified]
        if let w = s.home.wg, !homeCidrs(w).isEmpty { network.append(["ip_cidr": J.strings(homeCidrs(w)), "outbound": "home-wg"]) }
        if p.homeTs { network.append(["ip_cidr": J.strings([tailnet] + homeSubnets(s)), "outbound": .s(tsTag)]) }
        if s.prefs.lan { network.append(["ip_cidr": J.strings(lan + lan6), "outbound": "direct"]) }

        // Tailscale's control plane and login pages never ride the tailnet for apps on a Tailscale exit: a not yet
        // signed-in exit node would otherwise block its own sign-in.
        var tsLogin: [(String, J)] = []
        if s.tailscale && p.i.tsLoginPending {
            if s.tsExit != nil && officialTs(s.home) { tsLogin.append(("domain_suffix", ["tailscale.com", "tailscale.io"])) }
            if let h = s.home.tsControlUrl.flatMap({ URL(string: $0)?.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }) {
                // An address is matched as one; any other host by name, one starting with a digit ("1-control.example.com") too.
                if !h.contains(":") || !h.contains("%") {
                    tsLogin.append(ipv4(h) != nil ? ("ip_cidr", .a([.s("\(h)/32")])) : h.contains(":") ? ("ip_cidr", .a([.s("\(h)/128")])) : ("domain", .a([.s(h)])))
                }
            }
        }

        // Blocked apps first: no LAN, no home, no connections. Their DNS queries reach the engine through the system
        // resolver (mDNSResponder), which has no app to match; those get fake addresses that lead nowhere. At the kill
        // switch's Internet level they keep the home network, as that level says (it enters the tunnel at both levels).
        // Never DNS, though: a resolver on the home network (the router's) would answer, a channel to the internet.
        var rules: [J] = []
        // A tunnel's far side (the provider's server, the home server, a tailnet peer) can open connections into it. The
        // engine takes those to the tunnel's own address as the Mac's localhost and routes any other like the Mac's own
        // traffic: into the home network, or out through Direct from the user's address. unbraid only connects out, so
        // nothing that arrives through a tunnel goes anywhere. Replies to the Mac's own connections don't come here, except
        // fragmented ones and those arriving after the engine forgot their flow: it can't map them back to the app, so
        // they are refused here, lost either way.
        if !tunnels.isEmpty { rules.append(["inbound": J.strings(tunnels), "action": "reject"]) }
        rules.append(["ip_cidr": J.strings(Array(ConfigVet.fakeRanges.dropFirst())), "action": "reject", "no_drop": true])
        if s.prefs.blockedAppsReachLAN {
            rules += p.blocked.map { ["process_path_regex": $0, "port": [53, 853], "action": "reject"] }
            // A remote home's subnets (through Tailscale or a home tunnel) aren't this network: refused, never sent direct.
            if !p.home.isEmpty { rules += p.blocked.map { ["process_path_regex": $0, "ip_cidr": J.strings(p.home), "action": "reject"] } }
            rules += p.blocked.map { ["process_path_regex": $0, "ip_cidr": J.strings(lan + lan6), "outbound": "direct"] }
        }
        rules += p.blocked.map { ["process_path_regex": $0, "action": "reject"] }
        if let refuse = p.othersRefused { rules.append(refuse) }
        rules += [
            ["protocol": "dns", "action": "hijack-dns"],
            // UDP only: the engine never completes a hijacked TCP connection, and apps test "am I online?" with TCP to
            // 8.8.8.8:53. That TCP goes out through the app's own exit like any other connection.
            ["port": 53, "network": "udp", "action": "hijack-dns"],
        ]
        // The app's own tests: each proxy user goes out through its exit only, names resolved there too.
        if p.i.probe != nil {
            for (t, dns) in p.probeTags.sorted(by: { $0.key < $1.key }) {
                rules.append(["inbound": .s(probeTag), "auth_user": [.s(t)], "action": "resolve", "server": .s(dns)])
                rules.append(unspecified)
                rules.append(["inbound": .s(probeTag), "auth_user": [.s(t)], "outbound": .s(t)])
            }
        }
        rules.append(["process_path_regex": [.s(p.i.selfPattern)], "outbound": "direct"])
        rules += network
        // Connections with no program to match (see `Ownerless`): TCP and UDP only, as one rule (an `invert` beside
        // `network` would turn both around and catch ping too).
        let refuseOwnerless = switch p.i.ownerless {
        case .followsDefault: false
        case .refusedWhileBlocking: p.blocking
        case .refusedWhileSplit: p.blocking || s.defaultRoute == DIRECT && p.appsOnExits
        }
        if refuseOwnerless {
            rules.append(["type": "logical", "mode": "and", "action": "reject",
                          "rules": [["network": ["tcp", "udp"]], ["process_path_regex": ["."], "invert": true]]])
        }

        // A route's way out: its tailnet sign-in pages direct (before its exit's DNS, which an exit node not yet signed in
        // can't answer), names resolved on its exit, the destination rules again, then the exit. The default route takes
        // what is left, and leaves through the route's `final`.
        func wayOut(_ id: String, _ match: J?, dns: String) {
            func rule(_ fields: [String: J]) -> J { var r = fields; r["process_path_regex"] = match; return .o(r) }
            if p.onTs(id) { rules += tsLogin.map { k, v in rule([k: v, "outbound": "direct"]) } }
            rules.append(rule(["action": "resolve", "server": .s(dns)]))
            rules += network
            if match != nil { rules.append(rule(["outbound": .s(p.tag(id))])) }
        }
        for (id, match) in p.perApp where id != BLOCK {
            if p.i.blocked.contains(id) { rules.append(["process_path_regex": match, "action": "reject", "no_drop": true]) }
            else { wayOut(id, match, dns: p.dns(id)) }
        }
        if p.deny || p.i.blocked.contains(s.defaultRoute) {
            // Refused before anything is looked up for it: a fake address resolved here would ask the local resolver.
            rules += network
            rules.append(["action": "reject", "no_drop": true])
        } else { wayOut(s.defaultRoute, nil, dns: p.defaultDns) }

        // Exits are IPv4: IPv6 is captured by the tunnel and refused here, so it fails fast and never leaks beside it.
        rules.append(["ip_version": 6, "action": "reject"])
        // Ping has no owner the engine can look up, so it lands here: with Direct as the default, an app kept on a VPN
        // could ping out from the Mac's own address, and a blocked app could still ping. Refused after the LAN and home
        // rules, so the router and home devices still answer.
        if p.blocking || s.defaultRoute == DIRECT && p.appsOnExits { rules.append(["network": "icmp", "action": "reject"]) }
        return rules
    }

    /// The tunnels: one endpoint or outbound per shared tunnel, the home WireGuard, and Tailscale.
    private static func transports(_ p: Plan) throws -> (endpoints: [J], outbounds: [J]) {
        let s = p.s
        var endpoints: [J] = []
        var outbounds: [J] = [["type": "direct", "tag": "direct"]]
        for r in p.active {
            guard p.shared[r.id] == "r-\(r.id)", let link = p.i.links[r.id] else { continue }
            switch link {
            case .wg(_, let peer, _, _): endpoints.append(try wg(p.tag(r.id), peer, r.name, maxMtu: r.imported ? 1280 : 1420))
            case .ovpn(_, let o):
                let e = try Manual.ovpnEndpoint(p.tag(r.id), o)
                endpoints.append(p.active.contains { p.tag($0.id) == p.tag(r.id) && (p.pushedDns($0) || (s.prefs.effectiveFilter.coversRoutes && s.prefs.effectiveFilter.server?.byName == true && ($0.imported || $0.loc.provider != "nord"))) } ? openVpn(e) : e)
            case .ss(_, let o): outbounds.append(Manual.ssOutbound(p.tag(r.id), o))
            case .ts: break
            }
        }
        if let w = s.home.wg { endpoints.append(try wg("home-wg", w, "the home network")) }
        if s.tailscale {
            var ts: J = ["type": "tailscale", "tag": .s(tsTag), "state_directory": "tailscale", "hostname": "unbraid", "accept_routes": true]
            // Only until the node is enrolled: its identity, sealed, logs it in from then on (`TsEnrolment`).
            if let k = s.home.tsAuthKey, s.home.tsEnrolled == nil { ts["auth_key"] = .s(k) }
            if let raw = s.home.tsControlUrl {
                // Over plain HTTP a network attacker could hand Tailscale a fake control-server key. The same check as
                // the Settings sheet's, so an address saved as "HTTPS://…" by an earlier version works too.
                guard let u = TsLogin.controlUrl(raw) else { throw Fail("Headscale needs an https:// address. Change it in Settings.") }
                ts["control_url"] = .s(u)
            }
            if let x = s.tsExit { ts["exit_node"] = .s(x); ts["exit_node_allow_lan_access"] = .b(s.prefs.lan) }
            endpoints.append(ts)
        }
        return (endpoints, outbounds)
    }

    /// Reverse lookups of private, link-local and unique-local addresses, which unbraid keeps on the local network's
    /// resolver: they are about devices around the Mac, not sites, so they don't follow the apps to a VPN. Public
    /// addresses' go out like any other lookup; the tailnet's go to its resolver while it is reached (`tailnetReverse`).
    static let localReverse = ["10.in-addr.arpa"] + (16...31).map { "\($0).172.in-addr.arpa" }
        + ["168.192.in-addr.arpa", "254.169.in-addr.arpa", "c.f.ip6.arpa", "d.f.ip6.arpa", "8.e.f.ip6.arpa", "9.e.f.ip6.arpa",
           "a.e.f.ip6.arpa", "b.e.f.ip6.arpa"]

    /// The tailnet's reverse zones: 100.64.0.0/10 and Tailscale's IPv6 range fd7a:115c:a1e0::/48 (as Tailscale's MagicDNS
    /// routes them).
    static let tailnetReverse = ["0.e.1.a.c.5.1.1.a.7.d.f.ip6.arpa"] + (64...127).map { "\($0).100.in-addr.arpa" }

    /// Resolvers and the order they answer in: lookups from a tunnel and blocked apps' refused, the tailnet's names, local
    /// names, fake addresses for every A/AAAA, then other query types on the asking app's exit, else by the default route.
    private static func dns(_ p: Plan, refusing tunnels: [String]) -> J {
        let s = p.s
        var servers: [J] = [["type": "fakeip", "tag": "fake", "inet4_range": .s(ConfigVet.fakeRanges[0])], ["type": "local", "tag": "local"]]
        var pushed = Set<String>()
        let filter = s.prefs.effectiveFilter
        if let server = filter.server, (p.defaultDns == "dns-filter" || p.perApp.contains(where: { $0.id == filteredDirect })) {
            servers.append(filterDns(server, tag: "dns-filter", detour: nil, boot: "local"))
        }
        for r in p.active {
            let link = p.i.links[r.id]
            if let server = filter.server, filter.routes {
                guard pushed.insert("filter-\(p.tag(r.id))").inserted else { continue }
                let boot = "boot-\(p.tag(r.id))"
                if server.byName, pushed.insert(boot).inserted {
                    if case .ovpn = link, r.imported || r.loc.provider != "nord" {
                        servers.append(["type": "openvpn", "tag": .s(boot), "endpoint": .s(p.tag(r.id)), "accept_default_resolvers": true, "fallback_server": "9.9.9.9"])
                    } else {
                        servers.append(["type": "udp", "tag": .s(boot), "server": .s(dnsServer(s, r, link, providerBlocking: false)), "detour": .s(p.tag(r.id))])
                    }
                }
                servers.append(filterDns(server, tag: p.dns(r.id), detour: p.tag(r.id), boot: boot))
            } else if case .ovpn = link, p.pushedDns(r) {
                guard pushed.insert(p.tag(r.id)).inserted else { continue }
                servers.append(["type": "openvpn", "tag": .s(p.dns(r.id)), "endpoint": .s(p.tag(r.id)), "accept_default_resolvers": true, "fallback_server": "9.9.9.9"])
            } else {
                servers.append(["type": "udp", "tag": .s(p.dns(r.id)), "server": .s(dnsServer(s, r, link)), "detour": .s(p.tag(r.id))])
            }
        }
        if p.homeTs { servers.append(["type": "tailscale", "tag": "dns-tailnet", "endpoint": .s(tsTag), "accept_default_resolvers": false]) }

        let suffix = tsSuffix(p.i.tsSuffix)
        var rules: [J] = []
        // Lookups from a tunnel's far side (a tailnet peer asking through Tailscale's peer API) are never answered.
        if !tunnels.isEmpty { rules.append(["inbound": J.strings(tunnels), "action": "predefined", "rcode": "REFUSED"]) }
        // Blocked apps first, before any exception: a lookup sent straight to the tunnel's resolver (any type, TXT and
        // the like included) would otherwise be a way out. Their lookups through mDNSResponder can't be told apart from
        // anyone else's and follow the rules below; the addresses they get lead nowhere for them.
        rules += p.blocked.map { ["process_path_regex": $0, "action": "predefined", "rcode": "REFUSED"] }
        let official = officialTs(s.home)
        let domains = Array(Set((official ? ["ts.net"] : []) + [suffix].compactMap { $0 })).sorted()
        if p.homeTs && !domains.isEmpty { rules.append(["domain_suffix": J.strings(domains), "server": "dns-tailnet"]) }
        // Its reverse zones too, whatever the type: a lookup there names a tailnet address, which no other resolver should
        // see (the tailnet's answers NXDOMAIN, unless the tailnet routes those zones to a resolver of its own).
        if p.homeTs { rules.append(["domain_suffix": J.strings(tailnetReverse), "server": "dns-tailnet"]) }
        // The tailnet's domain while Tailscale isn't running: refused rather than looked up on the local network. A pause
        // and a deny-all keep the search domain (`searchDomain`), so short tailnet names expand to it and end here too.
        if !p.homeTs, let suffix { rules.append(["domain_suffix": [.s(suffix)], "action": "predefined", "rcode": "NXDOMAIN"]) }
        if s.prefs.lan { rules.append(["domain_suffix": ["local", "lan", "home.arpa", "fritz.box"], "server": "local"]) }
        // With LAN access off too: it decides which apps reach those devices, not whose resolver names them.
        rules.append(["query_type": ["PTR"], "domain_suffix": J.strings(localReverse), "server": "local"])
        rules.append(["query_type": ["A", "AAAA"], "server": "fake", "rewrite_ttl": 1])
        // Other query types (HTTPS, SVCB, TXT, SRV…) go to the asking app's own route, not the default one.
        for (id, match) in p.perApp where id != BLOCK {
            if p.i.blocked.contains(id) { rules.append(["process_path_regex": match, "action": "predefined", "rcode": "REFUSED"]) }
            else { rules.append(["process_path_regex": match, "server": .s(p.dns(id))]) }
        }
        // Most apps resolve through mDNSResponder, which matches no app above, so the rest take the default route's
        // resolver: with Direct as the default the local one, which keeps service discovery, Kerberos and captive portals
        // working, at the price that an app on a VPN asking the system for TXT or SRV asks the ISP's. HTTPS and SVCB
        // lookups, made for most sites a browser opens, would show the ISP the sites an app on a VPN or a blocked app
        // visits: they are answered empty instead, which costs those connections the records' hints, protocol parameters
        // and Encrypted Client Hello keys.
        // The Direct filter answers from this Mac's own address just as the local resolver does.
        if (p.defaultDns == "local" || p.defaultDns == "dns-filter") && (p.blocking || p.appsOnExits) {
            rules.append(["query_type": ["HTTPS", "SVCB"], "action": "predefined", "rcode": "NOERROR"])
        }
        if p.deny || p.i.blocked.contains(s.defaultRoute) { rules.append(["action": "predefined", "rcode": "REFUSED"]) }

        return [
            "servers": .a(servers), "rules": .a(rules), "final": .s(p.defaultDns), "strategy": "ipv4_only",
            // A slow or re-handshaking exit must not hold every app's new connections: answer from the cache (stale at
            // most an hour) and refresh in the background; give up on a lookup sooner than the 10 s default.
            "optimistic": ["enabled": true, "timeout": "1h"], "timeout": "5s", "cache_capacity": 4096,
        ]
    }

    private static func filterDns(_ server: FilterServer, tag: String, detour: String?, boot: String) -> J {
        var dns: J = ["type": .s(server.path != nil ? "https" : server.tls != nil ? "tls" : "udp"),
                      "tag": .s(tag), "server": .s(server.address), "server_port": .i(server.port)]
        if let path = server.path { dns["path"] = .s(path) }
        if server.path != nil || server.tls != nil {
            var tls: J = ["enabled": true]
            if let name = server.tls { tls["server_name"] = .s(name) }
            dns["tls"] = tls
        }
        if server.byName { dns["domain_resolver"] = .s(boot) }
        if let detour { dns["detour"] = .s(detour) }
        return dns
    }

    /// The tun, and the app's own test proxy when there is a tunnel to test.
    private static func inbounds(_ p: Plan) -> [J] {
        let s = p.s
        var tun: J = [
            "type": "tun", "tag": "tun", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"], "mtu": 9000,
            "auto_route": true, "strict_route": true, "stack": "gvisor",
            // UDP that reaches the engine's NAT (through `direct` or Shadowsocks, and VPN traffic that misses the per-flow
            // path: a fragmented datagram, Tailscale before it has an address) gets a session per destination address and
            // port, each judged on its own: one socket's datagrams to another destination never ride the route its first
            // one took (a LAN address, say), and each fake address is translated (a session translates only its first).
            // Reuse of the very same source and destination can still inherit a session's route. It costs Direct and
            // Shadowsocks their endpoint-independent mapping (peer-to-peer hole punching), even with nothing on a VPN.
            "udp_mapping": "address_and_port_dependent",
            // Idle UDP sessions and flows are forgotten after this (TCP has its own timers; DNS, QUIC and STUN shorter
            // ones). Each `direct` session holds a socket, so per-destination sessions must not linger for long.
            "udp_timeout": "5m",
            // The tunnel's own IPv4 subnet, so its resolver (the nameserver in /etc/resolv.conf) is reached through the
            // tunnel: it lies inside 172.16.0.0/12, which LAN access excludes, and the longer prefix wins. (IPv6 routes are
            // set by the extension itself, which keeps ::/0 whole: Tunnel/Platform.swift.)
            "route_address": J.strings(["0.0.0.0/0", "::/0", "172.19.0.0/30"] + p.home),
        ]
        // LAN bypasses the tunnel only with the kill switch off (see Setup.lanBypassesTunnel, which the profile follows
        // too); home subnets reached through a tunnel stay routed (the longer prefix wins). With an app blocked it enters,
        // so the block holds there too, and the LAN rule sends everyone else's LAN direct.
        if s.lanBypassesTunnel {
            tun["route_exclude_address"] = J.strings(lan.filter { !p.home.contains($0) } + lan6)
        }
        var inbounds: [J] = [tun]
        // No tunnel to test, no inbound: sing-box would run a proxy with an empty user list unauthenticated.
        if let probe = p.i.probe, !p.probeTags.isEmpty {
            inbounds.append(["type": "mixed", "tag": .s(probeTag), "listen": "127.0.0.1", "listen_port": .i(probe.port),
                             "users": .a(p.probeTags.keys.sorted().map { ["username": .s($0), "password": .s(probe.password)] })])
        }
        return inbounds
    }

    // MARK: - Helpers

    /// Private ranges only: a home tunnel must never capture public traffic meant for an exit.
    private static let privateRanges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"]

    /// Parsed while the user types: any text, a lone "/" included, must come back nil rather than trap.
    private static func ipv4(_ cidr: String) -> (UInt32, Int)? {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let octets = Catalog.Entry.octets(String(parts[0])) else { return nil }
        let prefix = parts.count == 2 ? String(parts[1]) : "32"
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isASCII && $0.isNumber }), let len = Int(prefix), (0...32).contains(len) else { return nil }
        return (octets.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }, len)
    }

    static func canonical(_ cidr: String) -> String? {
        guard let (ip, len) = ipv4(cidr) else { return nil }
        let net = len == 0 ? 0 : ip & (~UInt32(0) << UInt32(32 - len))
        return (0..<4).reversed().map { String(net >> UInt32($0 * 8) & 255) }.joined(separator: ".") + "/\(len)"
    }

    private static func homeSubnets(_ s: Setup) -> [String] {
        var seen: Set<String> = []
        return s.home.subnets.compactMap(canonical).filter { isPrivate($0) && seen.insert($0).inserted }
    }

    /// True when the whole of `cidr` lies inside a private IPv4 range.
    static func isPrivate(_ cidr: String) -> Bool {
        guard let (a, l) = ipv4(cidr) else { return false }
        return privateRanges.contains { r in
            let (b, m) = ipv4(r)!
            return l >= m && (m == 0 || (a ^ b) >> UInt32(32 - m) == 0)
        }
    }

    /// Networks to send through the home tunnel: its private AllowedIPs, else the interface's own subnet.
    static func homeCidrs(_ p: WgPeer) -> [String] {
        func ranges(_ values: [String]) -> [String] {
            var seen: Set<String> = []
            return values.compactMap(canonical).filter { isPrivate($0) && seen.insert($0).inserted }
        }
        let allowed = ranges(p.allowedIps)
        return allowed.isEmpty ? ranges(p.address) : allowed
    }

    /// Resolver inside a route's tunnel: custom DNS, else the provider's blocking resolver if asked, else the tunnel's
    /// own, else Nord's (filtering when Threat Protection Lite is on), else Quad9.
    private static func dnsServer(_ s: Setup, _ r: Route, _ link: Link?, providerBlocking: Bool = true) -> String {
        let provider = r.imported ? nil : r.loc.provider
        if providerBlocking, let p = provider, s.protects(r), let f = Providers.get(p)?.blockingDns({ s.opt(p, $0) }) { return f }
        if case .wg(_, let peer, _, _) = link, let d = peer.dns.first { return d }
        return provider == "nord" ? nordDns : "9.9.9.9"
    }

    /// The engine's error for a bad key quotes it, so every key is checked here and never named.
    private static func wg(_ tag: String, _ p: WgPeer, _ name: String, maxMtu: Int = 1280) throws -> J {
        guard validWgKey(p.privateKey), validWgKey(p.publicKey), p.presharedKey.map(validWgKey) ?? true else {
            throw Fail("Invalid WireGuard key for \(name)")
        }
        // Split at the last colon: "[2001:db8::1]:51820" has empty parts that a split would drop ("2001:db8:1").
        let colon = p.endpoint.lastIndex(of: ":") ?? p.endpoint.endIndex
        let host = String(p.endpoint[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let port = colon < p.endpoint.endIndex ? Int(p.endpoint[p.endpoint.index(after: colon)...]) : nil
        var peer: J = ["address": .s(host), "port": .i(port ?? 51820), "public_key": .s(p.publicKey),
                       "allowed_ips": ["0.0.0.0/0"]]
        if (p.keepalive ?? 25) > 0 { peer["persistent_keepalive_interval"] = .i(p.keepalive ?? 25) }
        if let psk = p.presharedKey { peer["pre_shared_key"] = .s(psk) }
        // 1280 fits every path (tethering, 464XLAT); 1420 makes 1480-byte packets that stall big uploads there.
        return ["type": "wireguard", "tag": .s(tag), "mtu": .i(min(p.mtu, maxMtu)), "address": J.strings(p.address),
                "private_key": .s(p.privateKey), "peers": [peer]]
    }

    private static let openVpnRouting = ["route ", "route-ipv6 ", "route-metric", "redirect-gateway", "redirect-private", "block-ipv6", "block-outside-dns"]

    /// Manual builds OpenVPN endpoints with `route_no_pull`, which also drops the pushed DNS. Here the server's routes
    /// stay ignored (sing-box's own rules steer traffic) but its DNS is kept, for the `openvpn` DNS server.
    private static func openVpn(_ e: J) -> J {
        var o = e.obj ?? [:]
        o["route_no_pull"] = nil
        o["pull_filters"] = .a(openVpnRouting.map { ["action": "ignore", "text": .s($0)] } + (e["pull_filters"]?.list ?? []))
        return .o(o)
    }

    /// A MagicDNS suffix as Tailscale reports it ("tail1234.ts.net." or a Headscale base domain), or nil if unusable.
    static func tsSuffix(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              s.wholeMatch(of: /[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+/) != nil, s != "ts.net" else { return nil }
        // A control server could report "co.uk" and take every lookup under it to the tailnet's resolver: a tailnet's
        // domain has at least two labels and is not a public suffix of the usual country form. Any other (a registrable
        // domain such as apple.com) still needs the user's yes, unless it is Tailscale's own (see Store.tsSuffix).
        guard s.wholeMatch(of: /(co|com|net|org|gov|edu|ac|or|ne|go)\.[a-z]{2}/) == nil else { return nil }
        return s
    }

    /// Tailscale's own domain for a tailnet: all of ts.net goes to the tailnet's resolver anyway while Tailscale runs.
    static func trustedStoredSuffix(_ home: Home) -> String? {
        guard let suffix = home.tsSuffix else { return nil }
        if !officialTs(home) && tsSuffixIsTailscales(suffix) && !home.tsSuffixConfirmed { return nil }
        return suffix
    }

    static func officialTs(_ home: Home) -> Bool {
        home.tsControlUrl == nil || (URL(string: home.tsControlUrl ?? "")?.host?.lowercased()).map { $0 == "tailscale.com" || $0.hasSuffix(".tailscale.com") } == true
    }

    static func tsSuffixIsTailscales(_ suffix: String) -> Bool { suffix.hasSuffix(".ts.net") }

    private static func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// Same key = same physical exit with the same credentials, whichever route asked for it.
    static func linkKey(_ r: Route, _ l: Link) -> String {
        switch l {
        // Everything that defines the tunnel: a newer preshared key, address or MTU is another tunnel, not the first one's.
        case .wg(_, let p, _, _): wgKey(p, maxMtu: r.imported ? 1280 : 1420)
        // Same remotes but another protocol, CA or login is another tunnel: compare the whole profile.
        case .ovpn(_, let p): ["ovpn", sha(p.config), p.username, sha(p.password)].joined(separator: "|")
        case .ss(_, let p): ["ss", p.server, String(p.port), p.method, sha(p.password), p.plugin ?? "", sha(p.pluginOpts ?? "")].joined(separator: "|")
        case .ts: "ts"
        }
    }

    static let clashMessage = "Another of your WireGuard connections uses this key on the same server with other settings. Use one config for both."

    private static func wgHost(_ p: WgPeer) -> String {
        guard let colon = p.endpoint.lastIndex(of: ":") else { return p.endpoint.lowercased() }
        let host = p.endpoint[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !host.utf8.contains(0) else { return host }
        var address6 = in6_addr()
        var address4 = in_addr()
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET6, host, &address6) == 1, inet_ntop(AF_INET6, &address6, &output, socklen_t(output.count)) != nil {
            return String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let strictIPv4 = parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && (part.count == 1 || part.first != "0") && part.utf8.allSatisfy { (48...57).contains($0) }
        }
        if strictIPv4, inet_pton(AF_INET, host, &address4) == 1, inet_ntop(AF_INET, &address4, &output, socklen_t(output.count)) != nil {
            return String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return host
    }

    private static func wgKey(_ p: WgPeer, maxMtu: Int = 1280) -> String {
        let port = p.endpoint.lastIndex(of: ":").map { String(p.endpoint[p.endpoint.index(after: $0)...]) } ?? ""
        return ["wg", wgHost(p), port, p.publicKey, sha(p.privateKey), sha(p.presharedKey ?? ""),
                p.address.joined(separator: ","), String(min(p.mtu, maxMtu)), String(p.keepalive ?? 25)].joined(separator: "|")
    }

    static func clashes(_ s: Setup, _ links: [String: Link]) -> Set<String> {
        var seen: [String: String] = [:]
        func identity(_ p: WgPeer) -> String { [wgHost(p), p.publicKey, sha(p.privateKey)].joined(separator: "|") }
        if let home = s.home.wg { seen[identity(home)] = "home" }
        var result: Set<String> = []
        for r in s.activeRoutes {
            guard case .wg(_, let p, _, _) = links[r.id] else { continue }
            let id = identity(p), key = wgKey(p, maxMtu: r.imported ? 1280 : 1420)
            if let old = seen[id] { if old != key { result.insert(r.id) } }
            else { seen[id] = key }
        }
        return result
    }

    /// True when every path `inner` matches is inside the bundle `outer` matches (and they differ).
    static func contains(_ outer: String, _ inner: String) -> Bool {
        let fold = outer.hasPrefix("(?i)")
        func bare(_ p: String) -> String {
            let s = p.hasPrefix("(?i)") ? String(p.dropFirst(4)) : p
            return fold ? s.lowercased() : s
        }
        // A bundle's pattern ends in an unescaped "/", where a path inside it has an escaped one.
        let o = bare(outer), i = bare(inner)
        return o.hasSuffix("/") && i.hasPrefix(o.dropLast() + "\\/")
    }

    /// Apps in [apps] the setup doesn't route (so on its default route) that sit inside the bundle of an app it routes
    /// elsewhere, Block aside (a blocked bundle refuses what is inside it first). They match the outer bundle's pattern
    /// too, so they get a rule of their own that keeps them on the default route, as the app list shows them.
    static func nestedDefaults(_ s: Setup, _ apps: [String: [String]]) -> [String] {
        let outer = s.apps.filter { $0.value != s.defaultRoute && $0.value != BLOCK }.keys.flatMap { apps[$0] ?? [] }
        guard !outer.isEmpty else { return [] }
        return apps.filter { s.apps[$0.key] == nil && $0.value.contains { p in outer.contains { contains($0, p) } } }.keys.sorted()
    }

    /// The process path pattern for an app bundle or a tool: everything inside the bundle (helpers, XPC services and
    /// nested apps are its own), or exactly that executable. On a volume that ignores case (the Mac's own, by default)
    /// "/applications/foo.APP" is the same app, and the engine sees the path as the program was opened: there the
    /// pattern ignores case too. On a case-sensitive volume two names differing in case are two apps, so it doesn't.
    static func pattern(forPath path: String) -> String { pattern(forPath: path, ignoringCase: volumeIgnoresCase(path)) }

    static func pattern(forPath path: String, ignoringCase: Bool) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: path)
        let fold = ignoringCase ? "(?i)" : ""
        return path.lowercased().hasSuffix(".app") ? "\(fold)^\(escaped)/" : "\(fold)^\(escaped)$"
    }

    /// Whether the volume holding `path` (or its nearest existing folder) treats names differing only in case as one.
    /// Unknown is taken as yes, the Mac's default.
    static func volumeIgnoresCase(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path)
        while true {
            if let sensitive = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames {
                return !sensitive
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return true }
            url = parent
        }
    }
}
