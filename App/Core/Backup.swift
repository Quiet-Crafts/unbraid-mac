import Foundation

/// What a backup holds (`BackupFile` seals it) and the rules for restoring one.
///
/// The plaintext is JSON: `{"format":1,"platform":"mac","app":"…","created":<epoch ms>,"keys":<bool>,"mac":{…}}`, where
/// `mac` is the setup as this app saves it. The setup sits under `mac`, not under the Android app's `setup`, so neither
/// app takes the other's setup for its own: the two models differ.
///
/// In it: routes and the default, app and website choices, favourites, profiles (and which is in use), own servers, the
/// Home WireGuard tunnel, preferences and provider page settings. Never in it: provider sign-ins (they live outside the
/// setup, in `Store.accounts`), anything of Tailscale (it belongs to this Mac's sign-in), the statistics consent, the
/// profile request salt and a pending profile switch. Without keys, own servers and the routes through them keep only
/// what isn't secret and wait for their config after a restore (`Route.keyless`), and the Home WireGuard tunnel stays out.
nonisolated enum Backup {
    static let format = 1
    static let platform = "mac"
    /// The profile a restore keeps this Mac's setup as (or "Previous 2", and so on).
    static let previous = "Previous"
    /// What a backup may hold at most: more than unbraid lets anyone set up, far less than would slow a restore.
    static let maxRoutes = 200, maxServers = 100, maxApps = 1000, maxString = 64 << 10, maxConfig = 256 << 10

    /// Why a plaintext can't be restored. `invalid` says what, never a key or a password.
    enum Failure: Error, Equatable {
        case otherPlatform, newer, damaged
        case invalid(String)

        var message: String {
            switch self {
            case .otherPlatform: "This backup was made by unbraid for Android. Moving a setup from Android isn't supported yet."
            case .newer: "This backup was made by a newer unbraid. Update unbraid to restore it."
            case .damaged: "This backup is damaged or incomplete. Use another copy of it."
            case .invalid(let why): "This backup can't be restored: \(why)."
            }
        }
    }

    /// A backup read and checked whole (`read`): nothing of it has touched this Mac yet.
    struct Content: Equatable, Sendable {
        var setup: Setup
        var app: String
        var created: Date
        /// False: saved without own servers' keys and passwords and without the Home WireGuard tunnel.
        var keys: Bool
        var summary: Summary
    }

    /// What a setup holds, as the save and restore sheets count it.
    struct Summary: Equatable, Sendable {
        var routes = 0, apps = 0, websites = 0, profiles = 0, servers = 0
        /// Own servers without their keys.
        var keyless = 0
        var homeTunnel = false

        init(_ s: Setup) {
            routes = s.routes.count; apps = s.apps.count; websites = s.sites.count; profiles = s.profiles.count
            servers = s.servers.count; keyless = s.servers.filter(\.keyless).count; homeTunnel = s.home.wg != nil
        }
        init(routes: Int = 0, apps: Int = 0, websites: Int = 0, profiles: Int = 0, servers: Int = 0, keyless: Int = 0, homeTunnel: Bool = false) {
            (self.routes, self.apps, self.websites, self.profiles, self.servers, self.keyless, self.homeTunnel) = (routes, apps, websites, profiles, servers, keyless, homeTunnel)
        }
    }

    // MARK: Saving

    /// Whether `s` holds anything the keys switch decides on: own servers, imported routes or a Home WireGuard tunnel.
    static func hasSecrets(_ s: Setup) -> Bool {
        !s.servers.isEmpty || s.home.wg != nil || s.routes.contains { $0.imported && $0.tsExit == nil }
    }

    /// The setup a backup of `s` holds (see the type's comment for what is left out).
    static func contents(_ s: Setup, keys: Bool) -> Setup {
        var c = s
        c.home = Home(wg: keys ? s.home.wg : nil)
        c.prefs.stats = false
        c.pendingSwitch = nil; c.profileSalt = nil; c.testing = []; c.blockedForLostRoute = 0
        c = named(c)
        guard !keys else { return c }
        c = linked(c)
        c.servers = c.servers.map { $0.withoutSecrets() }
        c.routes = c.routes.map { $0.withoutSecrets() }
        return c
    }

    static func export(_ setup: Setup, app: String, created: Date, keys: Bool) -> Data {
        let body = Body(format: format, platform: platform, app: app, created: Int64((created.timeIntervalSince1970 * 1000).rounded()), keys: keys,
                        mac: contents(setup, keys: keys))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Every part of a setup encodes; a failure here would be a bug, and an empty file is never written for it.
        return (try? encoder.encode(body)) ?? Data()
    }

    /// `s` with each pinned provider server kept by its name and host only. Its address and key are the provider's
    /// to say: every provider looks a pinned server up in its own list again, and takes the saved address and key only
    /// while that list can't be read. A backup must never be what names the server a provider's tunnel is made to,
    /// so a restored pin waits for the provider's list instead (written this way, and read this way whatever was written).
    static func named(_ s: Setup) -> Setup {
        var s = s
        for i in s.routes.indices { s.routes[i].loc = bare(s.routes[i].loc) }
        s.favorites = s.favorites.map(bare)
        // The same for the one provider setting that names addresses (IVPN's block list is a pair of its resolvers):
        // it starts again from the provider's standard one, and is chosen again from the provider's own list.
        s.opts["ivpn"]?["list"] = nil
        return s
    }

    /// `l` with its pinned server kept by name and host only (see `named`).
    private static func bare(_ l: Location) -> Location {
        var l = l
        l.pinned = l.pinned.map { Server(name: $0.name, host: $0.host, ip: "", publicKey: "", load: -1, city: $0.city, country: $0.country) }
        return l
    }

    /// `s` with every imported route tied to an own server, so one saved without keys has a way to get them back.
    private static func linked(_ s: Setup) -> Setup {
        var s = s
        for i in s.routes.indices {
            let r = s.routes[i]
            guard r.imported, r.tsExit == nil, !s.servers.contains(where: { $0.id == r.own }) else { continue }
            if let o = s.servers.first(where: { $0.wg == r.wg && $0.ovpn == r.ovpn && $0.ss == r.ss }) { s.routes[i].own = o.id; continue }
            let o = OwnServer(id: fresh("s", Set(s.servers.map(\.id))), wg: r.wg, ovpn: r.ovpn, ss: r.ss)
            s.servers.append(o)
            s.routes[i].own = o.id
        }
        return s
    }

    private struct Body: Codable {
        var format: Int, platform: String, app: String, created: Int64, keys: Bool, mac: Setup
    }

    // MARK: Reading

    /// What can be told of a plaintext before it is read whole: who made it, and in which format.
    private struct Head: Decodable {
        var format: Int?, platform: String?, android: Bool, version: Int?
        enum Keys: String, CodingKey { case format, platform, setup, mac }
        enum Inner: String, CodingKey { case version }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: Keys.self)
            format = try? c.decode(Int.self, forKey: .format); platform = try? c.decode(String.self, forKey: .platform)
            android = c.contains(.setup)
            version = (try? c.nestedContainer(keyedBy: Inner.self, forKey: .mac)).flatMap { try? $0.decodeIfPresent(Int.self, forKey: .version) } ?? nil
        }
    }

    /// The choices as written, before the setup's reader repairs them (an app on a route that isn't there turned to
    /// Block, say): a backup is restored as it was made, or not at all.
    private struct Raw: Decodable {
        struct P: Decodable, Equatable { var name: String; var defaultRoute: String; var apps: [String: String]?; var sites: [String: String]? }
        struct S: Decodable { var defaultRoute: String?; var apps: [String: String]?; var sites: [String: String]?; var profiles: [P]?; var profile: String? }
        var mac: S
    }

    /// `plain` read and checked whole (`valid`); throws `Failure` and changes nothing.
    static func read(_ plain: Data) throws -> Content {
        guard plain.count <= BackupFile.maxSize, let head = try? JSONDecoder().decode(Head.self, from: plain) else { throw Failure.damaged }
        if head.android || head.platform != platform { throw Failure.otherPlatform }
        guard let f = head.format, f >= 1 else { throw Failure.damaged }
        if f > format || (head.version ?? 1) > Setup.format { throw Failure.newer }
        guard let tree = try? JSONSerialization.jsonObject(with: plain) else { throw Failure.damaged }
        guard sane(tree) else { throw Failure.invalid("it holds more than unbraid keeps") }
        let body: Body, raw: Raw
        do {
            // Strictly: a value that is there and can't be read fails the backup instead of taking a default.
            body = try SavedDecoding.$strict.withValue(true) { try JSONDecoder().decode(Body.self, from: plain) }
            raw = try JSONDecoder().decode(Raw.self, from: plain)
        } catch is Setup.Newer { throw Failure.newer } catch { throw Failure.damaged }
        var s = named(body.mac)
        s.defaultRoute = raw.mac.defaultRoute ?? s.defaultRoute; s.apps = raw.mac.apps ?? [:]; s.sites = raw.mac.sites ?? [:]
        s.profiles = (raw.mac.profiles ?? []).map { Profile(name: $0.name, defaultRoute: $0.defaultRoute, apps: $0.apps ?? [:], sites: $0.sites ?? [:]) }
        s.profile = raw.mac.profile
        s.blockedForLostRoute = 0
        let setup = try valid(s)
        // What passes is what the reader made of it: anything it repaired was refused above.
        guard setup.apps == body.mac.apps, setup.sites == body.mac.sites, setup.profiles == body.mac.profiles,
              setup.profile == body.mac.profile, setup.defaultRoute == body.mac.defaultRoute else { throw Failure.damaged }
        return Content(setup: setup, app: body.app, created: Date(timeIntervalSince1970: Double(body.created) / 1000), keys: body.keys,
                       summary: Summary(setup))
    }

    /// No string longer than `maxString` (an OpenVPN config up to `maxConfig`), so a hostile file can't fill memory
    /// through the parsers.
    private static func sane(_ v: Any, key: String = "") -> Bool {
        switch v {
        case let s as String: return s.utf8.count <= (key == "config" ? maxConfig : maxString)
        case let a as [Any]: return a.allSatisfy { sane($0, key: key) }
        case let d as [String: Any]: return d.allSatisfy { $0.key.utf8.count <= maxString && sane($0.value, key: $0.key) }
        default: return true
        }
    }

    private static func need(_ ok: Bool, _ why: @autoclosure () -> String) throws { if !ok { throw Failure.invalid(why()) } }

    nonisolated(unsafe) private static let idPattern = /[A-Za-z0-9._-]{1,64}/
    /// Characters no name, address or key of a saved setup has: control and direction characters.
    private static let strange = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{061C}\u{2028}\u{2029}"))
    private static func plain(_ s: String, max: Int) -> Bool { s.utf8.count <= max && s.unicodeScalars.allSatisfy { !strange.contains($0) } }
    private static func plainName(_ n: String) -> Bool { !n.trimmingCharacters(in: .whitespaces).isEmpty && plain(n, max: 256) }

    /// `s` if every part of it is as unbraid itself would save it: own servers pass the same checks as an import, every
    /// reference names something that exists, profiles follow their rules, and the engine can build the setup and each
    /// saved profile. Throws `Failure.invalid`.
    static func valid(_ s: Setup) throws -> Setup {
        try need(s.routes.count <= maxRoutes && s.servers.count <= maxServers && s.profiles.count <= Setup.maxProfiles && s.favorites.count <= 2000
                 && s.apps.count <= maxApps && s.profiles.allSatisfy({ $0.apps.count <= maxApps }) && s.prefs.filter.apps.count <= maxApps,
                 "it holds more than unbraid keeps")
        // Never a name the compiler keeps for itself: a route called so would be read as Direct, Block or a refusal.
        func ids(_ list: [String]) -> Bool { list.allSatisfy { $0.wholeMatch(of: idPattern) != nil && !Compiler.reservedIds.contains($0) } && Set(list).count == list.count }
        try need(ids(s.routes.map(\.id)), "a route has a missing or repeated name")
        try need(ids(s.servers.map(\.id)), "an own server has a missing or repeated name")
        for sv in s.servers {
            try need([sv.wg != nil, sv.ovpn != nil, sv.ss != nil].filter { $0 }.count == 1, "an own server has no configuration")
            try check(sv.name, sv.wg, sv.ovpn, sv.ss, keyless: sv.keyless)
        }
        for r in s.routes {
            let n = [r.wg != nil, r.ovpn != nil, r.ss != nil, r.tsExit != nil].filter { $0 }.count
            try need(n <= 1, "a route has more than one exit")
            if n == 0 { try need(Providers.get(r.loc.provider) != nil, "a route uses a provider this unbraid doesn't know") }
            if let x = r.tsExit { try need(!x.isEmpty && plain(x, max: 253) && plain(r.tsName ?? "", max: 256), "a Tailscale route is damaged") }
            // A route saved without keys gets them back only through its own server, which must be saved without them too.
            let own = s.servers.first { $0.id == r.own }
            try need(r.keyless == (own?.keyless == true) && (!r.keyless || (n == 1 && r.tsExit == nil)), "a route and its own server don't match")
            // And it is that server's: this Mac's config for the server is what the route gets back, so a route that
            // names one server while describing another would come out somewhere else than it says.
            if r.keyless, let own { try need(r.wg == own.wg && r.ovpn == own.ovpn && r.ss == own.ss, "a route and its own server don't match") }
            if r.wg != nil || r.ovpn != nil || r.ss != nil { try check(r.name, r.wg, r.ovpn, r.ss, keyless: r.keyless) }
        }
        if let w = s.home.wg { try check(w.name, w, nil, nil, keyless: false) }
        // An app or a website may be on Block; a default route never is.
        let known = Set(s.routes.map(\.id))
        func ok(_ id: String) -> Bool { id == DIRECT || id == BLOCK || known.contains(id) }
        func apps(_ m: [String: String]) -> Bool { m.allSatisfy { !$0.key.isEmpty && plain($0.key, max: 1024) && ok($0.value) } }
        func sites(_ m: [String: String]) -> Bool { m.count <= Sites.max && m.allSatisfy { Sites.isClean($0.key) && ok($0.value) } }
        try need(s.defaultRoute != BLOCK && ok(s.defaultRoute) && apps(s.apps), "an app or the default route names a route that isn't there")
        try need(sites(s.sites), "a website's address or route is damaged")
        for p in s.profiles {
            var others = s
            others.profiles.removeAll { $0.name == p.name }
            try need(others.profiles.count == s.profiles.count - 1 && others.profileName(p.name) == p.name, "a profile has a name unbraid can't use")
            try need(p.defaultRoute != BLOCK && ok(p.defaultRoute) && apps(p.apps) && sites(p.sites), "profile \(p.name) names a route that isn't there")
        }
        try need(s.profile == nil || s.profiles.contains { $0.name == s.profile }, "the profile in use is missing")
        let filter = s.prefs.effectiveFilter
        try need(filter.id == nil || filter.server != nil, "the Protection filter is damaged")
        try need(s.opts.count <= 64 && s.opts.allSatisfy { $0.key.count <= 64 && $0.value.count <= 64 && $0.value.allSatisfy { $0.key.count <= 64 && $0.value.count <= 256 } },
                 "a provider page setting is damaged")
        // Built as the engine would get it with no provider signed in: own servers get their tunnels, the rest is refused.
        // Every saved profile too: one that can't run would only fail once the user switches to it.
        var v = s
        try need(runs(v), "its setup can't run")
        // Profiles that choose the same build the same config: each distinct choice is built once.
        var built: Set<Profile> = [Profile(name: "", defaultRoute: s.defaultRoute, apps: s.apps, sites: s.sites)]
        for p in s.profiles where p.name != s.profile {
            guard built.insert(Profile(name: "", defaultRoute: p.defaultRoute, apps: p.apps, sites: p.sites)).inserted else { continue }
            v = s
            v.use(p.name)
            try need(runs(v), "profile \(p.name) can't run")
        }
        // A route copied from an own server that is gone keeps its config, no longer tied to it.
        var out = s
        // WireGuard configs as the import reads them today: one saved by an older build in a way the import no longer
        // writes (an MTU out of range, say) is taken as read instead of refusing a backup the user can't mend.
        for i in out.servers.indices where !out.servers[i].keyless { out.servers[i].wg = out.servers[i].wg.flatMap(asRead) }
        for i in out.routes.indices where !out.routes[i].keyless { out.routes[i].wg = out.routes[i].wg.flatMap(asRead) }
        out.home.wg = out.home.wg.flatMap(asRead)
        for i in out.routes.indices where out.routes[i].own.map({ id in !s.servers.contains { $0.id == id } }) == true { out.routes[i].own = nil }
        return out
    }

    /// A server saved without keys holds nothing secret, and the rest of it is as an import leaves it; one with keys
    /// passes the import's own parser (WireGuard and Shadowsocks written back as a config or link and read again). The
    /// reason names the server, never a key, a password or a line of its config.
    private static func check(_ name: String, _ wg: WgPeer?, _ ovpn: OvpnProfile?, _ ss: SsProfile?, keyless: Bool) throws {
        let ok: Bool
        if keyless {
            if let w = wg {
                ok = w.privateKey.isEmpty && w.presharedKey == nil && WgConf.validEndpoint(w.endpoint) && plain(w.endpoint, max: 300) && validWgKey(w.publicKey)
                    && w.address.count <= 16 && w.allowedIps.count <= 256 && w.dns.count <= 16 && (w.address + w.allowedIps + w.dns).allSatisfy { plain($0, max: 64) }
            } else if let o = ovpn {
                ok = o == OvpnProfile(name: o.name, config: "")
            } else if let p = ss {
                ok = p.password.isEmpty && p.pluginOpts == nil && !p.server.isEmpty && plain(p.server, max: 253) && plain(p.method, max: 64)
                    && (1...65535).contains(p.port) && plain(p.plugin ?? "", max: 64)
            } else { ok = false }
        } else if let w = wg {
            // As the import would read it; what it reads differently (an older build's value) is taken as read (`asRead`).
            ok = asRead(w) != nil
        } else if let o = ovpn {
            ok = o.config.utf8.count <= maxConfig && o.username.utf8.count <= 1024 && o.password.utf8.count <= 1024
                && (try? Manual.parseOvpn(o.config, name: o.name, username: o.username, password: o.password)) != nil
        } else if let p = ss {
            ok = (try? Manual.parseSs(Manual.ssLink(p), name: p.name)) == p
        } else { ok = false }
        try need(ok && plainName(name), "own server \(String(name.prefix(40))) is damaged")
    }

    /// A WireGuard config written out and read back by the import's own parser; nil when the import refuses it.
    private static func asRead(_ w: WgPeer) -> WgPeer? { try? WgConf.parse(WgConf.text(w), name: w.name) }

    /// Whether the engine's config for `v` builds and is one the tunnel extension accepts.
    private static func runs(_ v: Setup) -> Bool {
        var links: [String: Link] = [:], blocked: Set<String> = []
        for r in v.activeRoutes {
            if !LinkPicker.keyLeftOut(r, in: v), let l = LinkPicker.imported(r) { links[r.id] = l } else { blocked.insert(r.id) }
        }
        let apps = Dictionary(uniqueKeysWithValues: v.apps.keys.map { key in
            (key, [Compiler.pattern(forPath: key.hasPrefix("/") ? key : "/Applications/\(key).app", ignoringCase: true)])
        })
        let input = Compiler.Input(setup: v, links: links, blocked: blocked, apps: apps, selfPattern: Compiler.pattern(forPath: "/Applications/unbraid.app", ignoringCase: true))
        guard let config = try? Compiler.compile(input) else { return false }
        return (try? ConfigVet.check(config)) != nil
    }

    // MARK: Restoring

    /// What a restore will do, worked out before anything changes, so the sheet can say it before the user confirms.
    struct Plan: Equatable, Sendable {
        /// This Mac's setup once restored.
        var setup: Setup
        /// The profile this Mac's setup is kept as; nil when that wasn't asked, nothing is set up here, or `unkept`.
        var keptAs: String?
        /// Keeping this Mac's setup was asked, but the backup's profiles leave no room or name for it: it would go.
        var unkept = false
        /// What the backup holds, and what of this Mac's it replaces.
        var holds: Summary
        var replaces: Summary
        /// The kill switch or Connect on Demand come out differently: the VPN restarts.
        var protectionChanges = false
        /// Own servers that wait for their config, by name.
        var needConfig: [String] = []
        /// Where the restored setup protects less than this Mac's does now, one sentence each: said before the user
        /// confirms, since a restore replaces these along with everything else.
        var weakens: [String] = []
        /// This Mac's Home WireGuard tunnel goes, and the backup has none to put in its place.
        var dropsHome = false
        /// Own servers whose security is weak, as an import warns before taking them ("name: why"); this Mac's own
        /// servers with the very same config were accepted here already and aren't listed. Restore waits for the
        /// user to accept them, as the import does.
        var weak: [String] = []
    }

    /// Where `next` protects less than `current` (see `Plan.weakens`): the kill switch, Connect on Demand, the DNS filter
    /// (its server and what it covers, app by app too), the local network, own servers that connect elsewhere under the
    /// same name, the provider's own blocking settings, the
    /// default route, and apps and websites that go out less protected. Only the setup in use is compared: a saved
    /// profile runs nothing until it is chosen. On a Mac with nothing set up, only the preferences are.
    static func weakens(_ current: Setup, _ next: Setup) -> [String] {
        var out: [String] = []
        let levels: [KillLevel: (Int, String)] = [.off: (0, "Off"), .internet: (1, "Internet"), .home: (2, "Internet and home network")]
        if let was = levels[current.prefs.killLevel], let now = levels[next.prefs.killLevel], now.0 < was.0 { out.append("The kill switch goes from \(was.1) to \(now.1).") }
        if current.prefs.alwaysOn && !next.prefs.alwaysOn { out.append("Connect on demand is turned off.") }
        let was = current.prefs.effectiveFilter, now = next.prefs.effectiveFilter
        if was.server != nil && now.server == nil { out.append("The DNS filter is turned off.") }
        else if was.server != nil, was.server != now.server { out.append("The DNS filter changes to another server.") }
        else if was.server != nil, (was.routes && !now.routes) || (was.direct && !now.direct) || (was.directApps && !now.directApps)
                    || Set(was.apps.keys).union(now.apps.keys).contains(where: { was.through($0) && !now.through($0) }) {
            out.append("The DNS filter covers less than it does now.")
        }
        if !current.prefs.lan && next.prefs.lan { out.append("Apps can reach the local network again.") }
        out += exitChanges(current, next)
        // Routes and choices a new install starts with aren't the user's: nothing to compare them with.
        guard setUp(current) else { return out }
        // A provider's own blocking runs only while unbraid's filter doesn't take its place on VPN routes.
        if !was.coversRoutes && !now.coversRoutes { out += providerWeakens(current, next) }
        let vpn = { (id: String) in id != DIRECT && id != BLOCK }
        if vpn(current.defaultRoute), next.defaultRoute == DIRECT {
            out.append("The default route goes from \(current.route(current.defaultRoute)?.name ?? "a VPN") to Direct.")
        }
        let apps = Set(current.apps.keys).union(next.apps.keys).filter { vpn(current.routeOf($0)) && next.routeOf($0) == DIRECT }.count
        let sites = current.sites.filter { vpn($0.value) && next.sites[$0.key] == DIRECT }.count
        let direct = [count(apps, "app"), count(sites, "website")].filter { !$0.hasPrefix("0 ") }
        if !direct.isEmpty { out.append("\(list(direct)) \(apps + sites == 1 ? "goes" : "go") from a VPN route to Direct.") }
        let blocked = current.apps.filter { $0.value == BLOCK && next.apps[$0.key] != BLOCK }.count
        if blocked > 0 { out.append(blocked == 1 ? "1 app that is blocked now won't be." : "\(blocked) apps that are blocked now won't be.") }
        let unblocked = current.sites.filter { $0.value == BLOCK && next.sites[$0.key] != BLOCK }.count
        if unblocked > 0 { out.append(unblocked == 1 ? "1 website that is blocked now won't be." : "\(unblocked) websites that are blocked now won't be.") }
        return out
    }

    /// An own server, a route of its own or the Home WireGuard tunnel that keeps its name here but connects somewhere
    /// else, or sets other DNS servers: a familiar name is no sign that the traffic goes where it went. Hosts only,
    /// never a key.
    private static func exitChanges(_ current: Setup, _ next: Setup) -> [String] {
        let was = exits(current), now = exits(next)
        var out: [String] = []
        for (name, n) in now.sorted(by: { $0.key < $1.key }) {
            guard let c = was[name] else { continue }
            let who = name == homeKey ? "The Home WireGuard tunnel" : "\"\(name)\""
            if let h = n.host, let o = c.host, h.lowercased() != o.lowercased() { out.append("\(who) connects to \(h) instead of \(o).") }
            if n.dns != c.dns { out.append(n.dns.isEmpty ? "\(who) no longer sets its own DNS servers." : "\(who) uses other DNS servers: \(n.dns.joined(separator: ", ")).") }
        }
        return out
    }

    private static let homeKey = "\u{0}home"

    /// Where each exit of `s` that the user set up connects (its host) and the DNS servers it sets, by name.
    private static func exits(_ s: Setup) -> [String: (host: String?, dns: [String])] {
        func host(_ wg: WgPeer?, _ ovpn: OvpnProfile?, _ ss: SsProfile?) -> String? {
            if let e = wg?.endpoint, let colon = e.lastIndex(of: ":") { return String(e[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
            if let ss { return ss.server }
            for line in (ovpn?.config ?? "").split(whereSeparator: \.isNewline) {
                let words = line.split(whereSeparator: \.isWhitespace)
                if words.count > 1, words[0] == "remote" { return String(words[1]) }
            }
            return nil
        }
        var out: [String: (host: String?, dns: [String])] = [:]
        func add(_ name: String, _ wg: WgPeer?, _ ovpn: OvpnProfile?, _ ss: SsProfile?) {
            if out[name] == nil { out[name] = (host(wg, ovpn, ss).map { String($0.prefix(80)) }, wg?.dns ?? []) }
        }
        for sv in s.servers { add(sv.name, sv.wg, sv.ovpn, sv.ss) }
        for r in s.routes where r.imported && r.tsExit == nil && r.own == nil { add(r.name, r.wg, r.ovpn, r.ss) }
        if let w = s.home.wg { add(homeKey, w, nil, nil) }
        return out
    }

    /// The provider settings that block or choose more carefully, turned off for a provider `next` has routes on; the
    /// block list a backup never holds, gone back to the standard one; and routes whose own blocking choice turns it off.
    private static func providerWeakens(_ current: Setup, _ next: Setup) -> [String] {
        var out: [String] = [], said: Set<String> = []
        for id in Set(next.routes.filter { !$0.imported }.map(\.loc.provider)).sorted() {
            guard let p = Providers.get(id) else { continue }
            // The blocking settings count only where a route of this provider blocks now; which servers it uses always.
            let blocking = current.routes.contains { !$0.imported && $0.loc.provider == id && current.protects($0) }
            let off = (blocking ? ["protect", "adult", "gambling", "social", "hardcore", "owned"] : ["owned"]).compactMap { key in
                p.option(key).flatMap { current.opt(id, key) == "on" && next.opt(id, key) != "on" ? $0.label : nil }
            }
            if !off.isEmpty { out.append("\(list(off)) \(off.count == 1 ? "is" : "are") turned off for \(p.name).") }
            if current.opt(id, "protect") == "on", next.opt(id, "protect") != "on" { said.insert(id) }
            if blocking, next.opt(id, "protect") == "on", let l = p.option("list"), current.opt(id, "list") != l.defaultValue, next.opt(id, "list") == l.defaultValue {
                out.append("\(p.name)'s \(l.label.lowercased()) goes back to the standard one.")
            }
        }
        let routes = next.routes.filter { r in
            !said.contains(r.loc.provider) && !next.protects(r) && current.route(r.id).map { !$0.imported && $0.loc.provider == r.loc.provider && current.protects($0) } == true
        }.count
        if routes > 0 { out.append("The provider's own blocking is turned off for \(count(routes, "route")).") }
        return out
    }

    /// Whether anything is set up on this Mac beyond what a new install starts with.
    static func setUp(_ s: Setup) -> Bool {
        let fresh = Setup()
        return s.routes != fresh.routes || s.defaultRoute != fresh.defaultRoute || !s.apps.isEmpty || !s.sites.isEmpty || !s.profiles.isEmpty
            || !s.servers.isEmpty || s.home.wg != nil
    }

    static func restored(onto current: Setup, from content: Content, keepPrevious: Bool, now: Date) -> Setup {
        plan(onto: current, from: content, keepPrevious: keepPrevious, now: now).setup
    }

    /// This Mac's setup replaced by `content`'s. This Mac's Tailscale, statistics consent and profile request salt
    /// stay; its Home WireGuard tunnel stays too unless the backup has keys. A server saved without keys that this Mac
    /// still has (`OwnServer.sameAs`) takes this Mac's config. With `keepPrevious` (and something set up here), the
    /// setup in use is kept as the profile `previous` (or with a number), with this Mac's routes and own servers: one
    /// whose id the backup uses for something else gets a new id, and the kept profile follows it. `now` is when the
    /// restore happens, for rules that run from it.
    static func plan(onto current: Setup, from content: Content, keepPrevious: Bool, now: Date) -> Plan {
        var b = content.setup
        // Saved without keys: an own server this Mac still has gets its config back here.
        let full = Dictionary(b.servers.filter(\.keyless).compactMap { k in
            current.servers.first { !$0.keyless && $0.id == k.id && k.sameAs($0) }.map { (k.id, $0) }
        }) { a, _ in a }
        if !full.isEmpty {
            b.servers = b.servers.map { full[$0.id] ?? $0 }
            for i in b.routes.indices where b.routes[i].keyless {
                guard let sv = full[b.routes[i].own ?? ""] else { continue }
                (b.routes[i].wg, b.routes[i].ovpn, b.routes[i].ss, b.routes[i].keyless) = (sv.wg, sv.ovpn, sv.ss, false)
            }
        }
        var r = b
        r.home = current.home
        if content.keys { r.home.wg = b.home.wg }
        r.prefs.stats = current.prefs.stats
        r.profileSalt = current.profileSalt; r.pendingSwitch = nil; r.testing = []; r.blockedForLostRoute = 0
        var replaced = Summary(current)
        replaced.homeTunnel = current.home.wg != nil && content.keys
        var plan = Plan(setup: r, holds: content.summary, replaces: replaced,
                        protectionChanges: current.prefs.killLevel != r.prefs.killLevel || current.prefs.alwaysOn != r.prefs.alwaysOn)
        plan.weakens = weakens(current, r)
        plan.dropsHome = current.home.wg != nil && r.home.wg == nil
        plan.weak = weak(b, accepted: current)
        guard keepPrevious, setUp(current) else { plan.needConfig = needConfig(plan.setup); return plan }
        guard r.profiles.count < Setup.maxProfiles,
              let name = ([previous] + (2...Setup.maxProfiles + 1).map { "\(previous) \($0)" }).lazy.compactMap({ r.profileName($0) }).first else {
            plan.unkept = true; plan.needConfig = needConfig(plan.setup); return plan
        }
        // Every own server and route of this Mac comes along (routes aren't per profile here: they all show), shared
        // where the backup has the very same one, under a new id where it uses that id for something else.
        var serverIds = Set(r.servers.map(\.id) + current.servers.map(\.id)), sv: [String: String] = [:]
        for s in current.servers {
            if let there = r.servers.first(where: { $0.id == s.id }) {
                if filed(there) == filed(s) { sv[s.id] = s.id; continue }
                let id = fresh("s", serverIds)
                var moved = s
                moved.id = id
                r.servers.append(moved); serverIds.insert(id); sv[s.id] = id
            } else { r.servers.append(s); serverIds.insert(s.id); sv[s.id] = s.id }
        }
        var routeIds = Set(r.routes.map(\.id) + current.routes.map(\.id)), rt: [String: String] = [:]
        for x in current.routes {
            var c = x
            // Tied to a server this Mac no longer has: untied, as a backup's reader unties it.
            c.own = x.own.flatMap { sv[$0] }
            if let there = r.route(x.id) {
                if filed(there) == filed(c) { rt[x.id] = x.id; continue }
                c.id = fresh("r", routeIds)
            }
            r.routes.append(c); routeIds.insert(c.id); rt[x.id] = c.id
        }
        let m = { (id: String) in rt[id] ?? id }
        let valid = Set(current.routes.map(\.id) + [DIRECT, BLOCK])
        let kept = Profile(name: name, defaultRoute: valid.contains(current.defaultRoute) && current.defaultRoute != BLOCK ? m(current.defaultRoute) : DIRECT,
                           apps: current.apps.filter { valid.contains($0.value) }.mapValues(m),
                           sites: current.sites.filter { valid.contains($0.value) }.mapValues(m))
        r.profiles.append(kept)
        plan.setup = r
        plan.keptAs = name
        plan.needConfig = needConfig(r)
        return plan
    }

    private static func needConfig(_ s: Setup) -> [String] { s.servers.filter(\.keyless).map(\.name) }

    /// Own servers and routes of their own in `s` that the import would warn about (`Manual.weakness`), unless
    /// `accepted` has the very same config: "name: why", once each.
    static func weak(_ s: Setup, accepted: Setup) -> [String] {
        let known = Set(accepted.servers.flatMap { [$0.ovpn.map(AnyHashable.init), $0.ss.map(AnyHashable.init)] }.compactMap { $0 }
                        + accepted.routes.flatMap { [$0.ovpn.map(AnyHashable.init), $0.ss.map(AnyHashable.init)] }.compactMap { $0 })
        var out: [String] = []
        let all = s.servers.filter { !$0.keyless }.map { ($0.name, $0.ovpn, $0.ss) } + s.routes.filter { !$0.keyless }.map { ($0.name, $0.ovpn, $0.ss) }
        for (name, ovpn, ss) in all {
            let why = ovpn.flatMap { known.contains($0) ? nil : (try? Manual.weakness($0)) ?? nil } ?? ss.flatMap { known.contains($0) ? nil : Manual.weakness($0) }
            if let why, !out.contains("\(name): \(why)") { out.append("\(name): \(why)") }
        }
        return out
    }

    /// A route or server as a backup of it reads back (pin by name and host, WireGuard config as the import reads it),
    /// so this Mac's own one is known for the same when the backup was made here.
    private static func filed(_ r: Route) -> Route {
        var r = r
        r.loc = bare(r.loc)
        if !r.keyless { r.wg = r.wg.map { asRead($0) ?? $0 } }
        return r
    }
    private static func filed(_ s: OwnServer) -> OwnServer {
        var s = s
        if !s.keyless { s.wg = s.wg.map { asRead($0) ?? $0 } }
        return s
    }

    private static func fresh(_ prefix: String, _ taken: Set<String>) -> String {
        while true {
            let id = prefix + UUID().uuidString.prefix(8).lowercased()
            if !taken.contains(id) { return id }
        }
    }

    // MARK: Words for the sheets

    /// The save sheet's count: "It holds 4 routes, 11 app choices, 5 websites, 2 profiles and 1 own server."
    static func holds(_ s: Summary) -> String {
        let parts = counts(s) + (s.homeTunnel ? ["the Home WireGuard tunnel"] : [])
        return parts.isEmpty ? "It holds your preferences." : "It holds \(list(parts))."
    }

    /// The restore sheet's "In this backup": "4 routes, 11 app choices, 5 websites, 2 profiles, 1 own server without its keys".
    static func inBackup(_ s: Summary) -> String {
        var parts = counts(s, servers: false)
        if s.servers > 0 {
            let n = count(s.servers, "own server")
            parts.append(s.keyless == 0 ? n : s.keyless == s.servers ? "\(n) without \(s.servers == 1 ? "its" : "their") keys" : "\(n) (\(s.keyless) without keys)")
        }
        if s.homeTunnel { parts.append("the Home WireGuard tunnel") }
        return parts.isEmpty ? "Preferences only" : parts.joined(separator: ", ")
    }

    /// The restore sheet's "It replaces": "Your 3 routes, 8 app choices and 1 profile on this Mac. Provider sign-ins,
    /// Tailscale and statistics stay as they are."
    static func replaces(_ s: Summary) -> String {
        let parts = counts(s) + (s.homeTunnel ? ["Home WireGuard tunnel"] : [])
        let stay = "Provider sign-ins, Tailscale and statistics stay as they are."
        return parts.isEmpty ? "Nothing set up on this Mac yet. \(stay)" : "Your \(list(parts)) on this Mac. \(stay)"
    }

    private static func counts(_ s: Summary, servers: Bool = true) -> [String] {
        [(s.routes, "route"), (s.apps, "app choice"), (s.websites, "website"), (s.profiles, "profile"), (servers ? s.servers : 0, "own server")]
            .filter { $0.0 > 0 }.map { count($0.0, $0.1) }
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
    private static func list(_ p: [String]) -> String { p.count < 2 ? p.joined() : p.dropLast().joined(separator: ", ") + " and " + p.last! }

    // MARK: Passphrase

    /// How hard a passphrase is to guess. A hint only, except with server keys in the file: then `easy` is refused.
    enum Strength: Equatable, Sendable {
        case easy, fair, hard
        var text: String {
            switch self {
            case .easy: "Easy to guess. Use 12 or more characters, or four or more words."
            case .fair: "Fair. Longer is safer: four or more words work well."
            case .hard: "Hard to guess"
            }
        }
    }

    /// The Android app's rule: four or more words of three letters or more, or enough bits for its length and the kinds
    /// of character it uses.
    static func strength(_ passphrase: String) -> Strength {
        let kinds = [(26, passphrase.contains(where: \.isLowercase)), (26, passphrase.contains(where: \.isUppercase)), (10, passphrase.contains(where: \.isNumber)),
                     (33, passphrase.contains { !$0.isLetter && !$0.isNumber })]
        let pool = max(1, kinds.reduce(0) { $0 + ($1.1 ? $1.0 : 0) })
        let bits = Double(passphrase.count) * log2(Double(pool))
        let words = passphrase.split(whereSeparator: \.isWhitespace).filter { $0.count >= 3 }.count
        return words >= 4 || bits >= 72 ? .hard : bits >= 50 ? .fair : .easy
    }
}

// MARK: - Without keys

nonisolated extension WgPeer {
    func withoutSecrets() -> WgPeer { var p = self; p.privateKey = ""; p.presharedKey = nil; return p }
}

nonisolated extension OvpnProfile {
    /// An OpenVPN profile holds its keys inside the config: only the name stays.
    func withoutSecrets() -> OvpnProfile { OvpnProfile(name: name, config: "") }
}

nonisolated extension SsProfile {
    func withoutSecrets() -> SsProfile { var p = self; p.password = ""; p.pluginOpts = nil; return p }
}

nonisolated extension OwnServer {
    func withoutSecrets() -> OwnServer {
        var s = self
        (s.wg, s.ovpn, s.ss, s.keyless) = (wg?.withoutSecrets(), ovpn?.withoutSecrets(), ss?.withoutSecrets(), true)
        return s
    }
}

nonisolated extension Route {
    /// A provider route or a Tailscale exit holds no key: it stays as it is.
    func withoutSecrets() -> Route {
        guard imported, tsExit == nil else { return self }
        var r = self
        (r.wg, r.ovpn, r.ss, r.keyless) = (wg?.withoutSecrets(), ovpn?.withoutSecrets(), ss?.withoutSecrets(), true)
        return r
    }
}

nonisolated extension Setup {
    /// Own server `id`, restored without keys, given `server`'s config and name, and every route through it unblocked.
    /// Nil unless `id` waits for its config and `server` is of the same kind.
    func refilled(_ id: String, with server: OwnServer) -> Setup? {
        guard let old = servers.first(where: { $0.id == id && $0.keyless }), old.kind == server.kind,
              [server.wg != nil, server.ovpn != nil, server.ss != nil].filter({ $0 }).count == 1 else { return nil }
        var s = self, sv = server
        sv.id = id; sv.keyless = false
        s.servers = servers.map { $0.id == id ? sv : $0 }
        for i in s.routes.indices where s.routes[i].own == id {
            (s.routes[i].wg, s.routes[i].ovpn, s.routes[i].ss, s.routes[i].keyless) = (sv.wg, sv.ovpn, sv.ss, false)
        }
        return s
    }
}
