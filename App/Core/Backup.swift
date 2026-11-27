import Foundation

/// What a backup holds (`BackupFile` seals it) and the rules for restoring one.
///
/// The plaintext is JSON: `{"format":1,"platform":"mac","app":"…","created":<epoch ms>,"keys":<bool>,"mac":{…}}`, where
/// `mac` is the setup as this app saves it. The setup sits under `mac`, not under the Android app's `setup`, so neither
/// app takes the other's setup for its own: the two models differ.
///
/// In it: routes and the default, app and website choices, favourites, profiles (and which is in use), own servers, the
/// Home WireGuard tunnel, preferences and provider page settings, Tailscale exit routes (a node's name and tailnet address)
/// among the routes. Never in it: provider sign-ins (they live outside the setup, in `Store.accounts`), this Mac's
/// Tailscale sign-in and home access settings, the statistics consent, the
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
        /// With keys: proxy server passwords by keychain item (`Socks5Profile.item`), as `read` named them anew.
        var passwords: [String: String] = [:]
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

    /// [passwords]: proxy server passwords by keychain item. With keys, a proxy route whose login has none here waits for
    /// it after a restore, as it would without keys.
    static func export(_ setup: Setup, app: String, created: Date, keys: Bool, passwords: [String: String] = [:]) -> Data {
        var mac = contents(setup, keys: keys), kept: [String: String] = [:]
        for i in mac.routes.indices where keys {
            guard let x = mac.routes[i].socks5, x.username != nil else { continue }
            if let p = passwords[x.item] { kept[x.item] = p } else { mac.routes[i].keyless = true }
        }
        let body = Body(format: format, platform: platform, app: app, created: Int64((created.timeIntervalSince1970 * 1000).rounded()), keys: keys,
                        mac: mac, socks5: kept.isEmpty ? nil : kept)
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
            // A proxy server gets its password back on the route itself.
            guard r.imported, r.tsExit == nil, r.socks5 == nil, !s.servers.contains(where: { $0.id == r.own }) else { continue }
            if let o = s.servers.first(where: { $0.wg == r.wg && $0.ovpn == r.ovpn && $0.ss == r.ss }) { s.routes[i].own = o.id; continue }
            let o = OwnServer(id: fresh("s", Set(s.servers.map(\.id))), wg: r.wg, ovpn: r.ovpn, ss: r.ss)
            s.servers.append(o)
            s.routes[i].own = o.id
        }
        return s
    }

    private struct Body: Codable {
        var format: Int, platform: String, app: String, created: Int64, keys: Bool, mac: Setup
        /// Proxy server passwords by keychain item, in a backup with keys only.
        var socks5: [String: String]? = nil
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
        var setup = try valid(s)
        // What passes is what the reader made of it: anything it repaired was refused above.
        guard setup.apps == body.mac.apps, setup.sites == body.mac.sites, setup.profiles == body.mac.profiles,
              setup.profile == body.mac.profile, setup.defaultRoute == body.mac.defaultRoute else { throw Failure.damaged }
        let items = Set(setup.routes.compactMap { $0.keyless || $0.socks5?.username == nil ? nil : $0.socks5?.item })
        let passwords = body.socks5 ?? [:]
        try need((body.keys || passwords.isEmpty) && Set(passwords.keys).isSubset(of: items) && passwords.values.allSatisfy { $0.utf8.count <= 255 },
                 "a proxy server's password is damaged")
        // New keychain items: a restore never writes over a password this Mac keeps for a route of its own.
        let renamed = Dictionary(uniqueKeysWithValues: Set(setup.routes.compactMap { $0.socks5?.item }).map { ($0, UUID().uuidString) })
        for i in setup.routes.indices { if let old = setup.routes[i].socks5?.item { setup.routes[i].socks5?.item = renamed[old]! } }
        return Content(setup: setup, app: version(body.app), created: Date(timeIntervalSince1970: Double(body.created) / 1000), keys: body.keys,
                       summary: Summary(setup), passwords: Dictionary(uniqueKeysWithValues: passwords.map { (renamed[$0.key]!, $0.value) }))
    }

    nonisolated(unsafe) private static let versionPattern = /[0-9][0-9A-Za-z.+-]{0,31}/
    /// The version that made a backup, shown on the restore sheet: a short plain version string, or nothing. The rest of
    /// the file is checked before it is shown; this is the one free text the sheet would print as it came.
    static func version(_ app: String) -> String { app.wholeMatch(of: versionPattern) != nil ? app : "" }

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
    /// Characters no name, address or key of a saved setup has: control and format characters (zero-width ones, the
    /// byte-order mark and the soft hyphen among them), direction characters, and the Hangul fillers, letters that
    /// show nothing, so a name can't look empty or like another.
    private static let strange = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{061C}\u{2028}\u{2029}"
        + "\u{3164}\u{115F}\u{1160}\u{FFA0}"))
    nonisolated(unsafe) private static let countryCodePattern = /[\p{L}\p{N}·]{1,3}/
    /// A provider route's place as a provider list would give it: a country code of at most three letters or digits
    /// ("··" for a country unbraid has no code for), the rest without control or invisible characters. The country
    /// code reaches a request (the speed test asks M-Lab for a server in it, `Ndt7.locatePath`), the rest is shown.
    private static func placeOk(_ l: Location) -> Bool {
        (l.countryCode.map { $0.wholeMatch(of: countryCodePattern) != nil } ?? true)
            && [l.group, l.region, l.country, l.city, l.proto, l.pinned?.name, l.pinned?.city, l.pinned?.country, l.pinned?.host, l.pinned?.ip].allSatisfy { $0.map { placeName($0) } ?? true }
            && (l.country.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? true)
    }
    /// A place's name as a provider list may write it: as `plain`, but the zero-width joiner and non-joiner, which
    /// some scripts and emoji need, may stand between visible characters.
    private static func placeName(_ s: String) -> Bool {
        s.utf8.count <= 1024 && s.unicodeScalars.allSatisfy { $0 == "\u{200C}" || $0 == "\u{200D}" || !strange.contains($0) }
            && (s.isEmpty || s.unicodeScalars.contains { $0 != "\u{200C}" && $0 != "\u{200D}" && !CharacterSet.whitespaces.contains($0) })
    }
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
        let known = Set(s.routes.map(\.id))
        for r in s.routes {
            let n = [r.wg != nil, r.ovpn != nil, r.ss != nil, r.socks5 != nil, r.tsExit != nil].filter { $0 }.count
            try need(n <= 1, "a route has more than one exit")
            if n == 0 {
                try need(Providers.get(r.loc.provider) != nil, "a route uses a provider this unbraid doesn't know")
                try need(placeOk(r.loc), "a route's place is damaged")
            }
            if let x = r.tsExit { try need(!x.isEmpty && plain(x, max: 253) && plain(r.tsName ?? "", max: 256), "a Tailscale route is damaged") }
            // A route saved without keys gets them back only through its own server, which must be saved without them too.
            let own = s.servers.first { $0.id == r.own }
            // A proxy server has no own server: it waits for the password of its login on the route itself.
            if let x = r.socks5 {
                try need(x.valid && r.own == nil && (!r.keyless || x.username != nil) && plainName(x.name) && plain(x.username ?? "", max: 255)
                         && x.proxyApp.map { !$0.isEmpty && plain($0, max: 1024) } != false,
                         "proxy server \(String(x.name.prefix(40))) is damaged")
            } else {
                try need(r.keyless == (own?.keyless == true) && (!r.keyless || (n == 1 && r.tsExit == nil)), "a route and its own server don't match")
            }
            // And it is that server's: this Mac's config for the server is what the route gets back, so a route that
            // names one server while describing another would come out somewhere else than it says.
            if r.keyless, let own { try need(r.wg == own.wg && r.ovpn == own.ovpn && r.ss == own.ss, "a route and its own server don't match") }
            if r.wg != nil || r.ovpn != nil || r.ss != nil { try check(r.name, r.wg, r.ovpn, r.ss, keyless: r.keyless) }
            // A Via names a route that is there, goes straight to its server (so no loop and no chain of three), and is one
            // this route can use: the same rules as in the app (`Setup.viaProblem`).
            // A route whose first route was removed is saved as it is (one-tunnel included): it stays blocked until the user
            // picks another Via. A one-tunnel flag with no Via at all is damage.
            try need(!(r.viaNative && r.via == nil), "a route's Via is damaged")
            try need(r.via == nil || r.via.map { !known.contains($0) } == true || s.viaProblem(r) == nil, "a route goes through a route that can't be used")
        }
        // Starred places become a route's place when picked.
        try need(s.favorites.allSatisfy(placeOk), "a favorite place is damaged")
        if let w = s.home.wg { try check(w.name, w, nil, nil, keyless: false) }
        // An app or a website may be on Block; a default route never is.
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
        // A route on a Via runs through its entry only: with none to run (a provider's, here) it is refused, as it is live.
        for r in v.activeRoutes where r.via != nil && (r.viaNative || r.via.map { links[$0] == nil } == true) { links.removeValue(forKey: r.id); blocked.insert(r.id) }
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
        /// Unkept because the backup's routes or own servers and this Mac's together are more than a backup holds.
        var tooBig = false
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
        /// Own servers whose security is weak, as an import warns before taking them ("name: what is weak"); this Mac's own
        /// servers with the very same config were accepted here already and aren't listed. Restore waits for the
        /// user to accept them, as the import does.
        var weak: [String] = []
    }

    /// Where `next` protects less than `current` (see `Plan.weakens`). Settings: the kill switch, Connect on Demand, the
    /// DNS filter's server, the local network, the provider's own blocking settings, and own servers that connect
    /// elsewhere under the same id or name. Traffic: what the default route, every app and every website name either
    /// setup names effectively get (`traffic`, `lost`), said in a few sentences. Only the setup in use is compared: a
    /// saved profile runs nothing until it is chosen. On a Mac with nothing set up, only the settings are.
    static func weakens(_ current: Setup, _ next: Setup, apps: [String: [String]]? = nil) -> [String] {
        var out: [String] = []
        let levels: [KillLevel: (Int, String)] = [.off: (0, "Off"), .internet: (1, "Internet"), .home: (2, "Internet and home network")]
        if let was = levels[current.prefs.killLevel], let now = levels[next.prefs.killLevel], now.0 < was.0 { out.append("The kill switch goes from \(was.1) to \(now.1).") }
        if current.prefs.alwaysOn && !next.prefs.alwaysOn { out.append("Connect on demand is turned off.") }
        let was = current.prefs.effectiveFilter, now = next.prefs.effectiveFilter
        let filterOff = was.server != nil && now.server == nil
        if filterOff { out.append("The DNS filter is turned off.") }
        else if was.server != nil, now.server != nil, was.server != now.server { out.append("The DNS filter changes to another server.") }
        if !current.prefs.lan && next.prefs.lan { out.append("Apps can reach the local network again.") }
        out += exitChanges(current, next)
        // Routes and choices a new install starts with aren't the user's: nothing to compare them with.
        guard setUp(current) else { return out }
        // Said even while unbraid's filter takes the provider's place on VPN routes: the filter may be turned off later,
        // and then the provider's setting is what protects them.
        out += providerWeakens(current, next)
        guard let l = RestoreTraffic.losses(current, next, apps: apps) else {
            // Either setup is one the engine would refuse whole: nothing can be said app by app.
            return out + ["What this restore changes for each app and website couldn't be worked out."]
        }
        return out + trafficNotes(l, current: current, filterOff: filterOff)
    }

    /// An own server, a route through one or the Home WireGuard tunnel that keeps its id or name here but connects to
    /// another host, port or server key, or sets other DNS servers: a familiar name is no sign that the traffic goes
    /// where it went. Each is named with its host only, never a key; a sentence said for a server isn't said again for
    /// its route.
    private static func exitChanges(_ current: Setup, _ next: Setup) -> [String] {
        let was = exits(current)
        var out: [String] = []
        for n in exits(next) {
            guard let c = was.first(where: { $0.key == n.key }) ?? was.first(where: { $0.name == n.name }) else { continue }
            let who = n.key == homeKey ? "The Home WireGuard tunnel" : "\"\(n.name)\""
            var said: [String] = []
            // Compared whole, shown shortened: two long names that differ only at the end are still two servers.
            if let h = n.host, let o = c.host, h.lowercased() != o.lowercased(), shown(h) != shown(o) { said.append("\(who) connects to \(shown(h)) instead of \(shown(o)).") }
            else if let h = n.host, n.host?.lowercased() != c.host?.lowercased() || n.port != c.port || n.peer != c.peer || n.remotes != c.remotes {
                // Another of its servers, or another port: name the one that is new.
                let new = n.remotes.first { !c.remotes.contains($0) }.flatMap { r in r.lastIndex(of: ":").map { String(r[..<$0]) } } ?? h
                said.append("\(who) connects to another server at \(shown(new)).")
            }
            // The certificate or name an OpenVPN server must show: the same address with other trust is another server.
            if let t = n.trust, let o = c.trust, t != o { said.append("\(who): the server it trusts changes.") }
            if n.dns != c.dns { said.append(n.dns.isEmpty ? "\(who) no longer sets its own DNS servers." : "\(who) uses other DNS servers: \(n.dns.joined(separator: ", ")).") }
            for line in said where !out.contains(line) { out.append(line) }
        }
        return out
    }

    private static let homeKey = "\u{0}home"
    /// A host as the sheet shows it: at most 60 characters, its end kept (where names differ most), never wrapped in the middle of a key.
    private static func shown(_ host: String) -> String { host.count <= 60 ? host : "…" + host.suffix(59) }

    /// One exit the user set up: what it is (`key`: a server's or route's id), its name, where it connects (host and port,
    /// and a WireGuard server's public key) and the DNS servers it sets.
    private struct Exit { var key: String, name: String, host: String?, port: String?, peer: String?, dns: [String]; var remotes: [String] = []; var trust: [String: Set<String>]? }

    /// Every own server, every route through one (it runs its own copy of the config) and the Home WireGuard tunnel.
    private static func exits(_ s: Setup) -> [Exit] {
        func exit(_ key: String, _ name: String, _ wg: WgPeer?, _ ovpn: OvpnProfile?, _ ss: SsProfile?) -> Exit {
            var host: String?, port: String?
            if let e = wg?.endpoint, let colon = e.lastIndex(of: ":") {
                (host, port) = (String(e[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")), String(e[e.index(after: colon)...]))
            } else if let ss { (host, port) = (ss.server, String(ss.port)) }
            // OpenVPN: every server the engine may pick, with the port and protocol each gets, as the import builds them.
            var remotes: [String] = [], trust: [String: Set<String>]?
            if let o = ovpn, let e = try? Manual.ovpnEndpoint("check", o).string,
               let j = try? JSONSerialization.jsonObject(with: Data(e.utf8)) as? [String: Any] {
                let list = (j["servers"] as? [[String: Any]]) ?? [j]
                remotes = list.compactMap { r in (r["server"] as? String).map { "\($0):\(r["server_port"] as? Int ?? 0)/\(r["network"] as? String ?? "")" } }
                trust = (j["tls"] as? [String: Any]).map(openVpnTrust)
                if let first = list.first { (host, port) = (first["server"] as? String, (first["server_port"] as? Int).map(String.init)) }
            }
            return Exit(key: key, name: name, host: host, port: port, peer: wg?.publicKey, dns: wg?.dns ?? [], remotes: remotes, trust: trust)
        }
        return s.servers.map { exit("s:" + $0.id, $0.name, $0.wg, $0.ovpn, $0.ss) }
            + s.routes.filter { $0.imported && $0.tsExit == nil }.map { exit("r:" + $0.id, $0.name, $0.wg, $0.ovpn, $0.ss) }
            + (s.home.wg.map { [exit(homeKey, "", $0, nil, nil)] } ?? [])
    }

    /// What decides whether an OpenVPN server is accepted, from the compiled endpoint's `tls` settings: the certificates
    /// it trusts, any pinned fingerprints, the name and usage it must show, and the key (and kind) that wraps the control
    /// channel. Values are only compared, never shown. Spacing counts everywhere except inside certificate and key text.
    static func openVpnTrust(_ tls: [String: Any]) -> [String: Set<String>] {
        func bare(_ s: String) -> String { String(s.filter { !$0.isWhitespace }) }
        var out: [String: Set<String>] = [:]
        for k in ["certificate", "peer_fingerprint", "server_name", "server_name_type", "remote_certificate_ku",
                  "remote_certificate_eku", "remote_certificate_tls", "ns_certificate_type", "certificate_profile"] {
            let values = (tls[k] as? [String]) ?? (tls[k] as? String).map { [$0] } ?? []
            // A certificate list is compared block by block; anything else value by value.
            let set = Set(k == "certificate" ? values.flatMap { $0.components(separatedBy: "-----END CERTIFICATE-----") }.map(bare).filter { !$0.isEmpty } : values)
            if !set.isEmpty { out[k] = set }
        }
        if let w = tls["control_wrap"] as? [String: Any] {
            out["control_wrap"] = Set(w.compactMap { k, v in (v as? String).map { "\(k)=" + (k == "key" ? bare($0) : $0) } })
        }
        return out
    }

    /// The losses, in the sheet's few sentences: every one the comparison finds has one.
    static func trafficNotes(_ found: RestoreTraffic.Losses, current: Setup, filterOff: Bool) -> [String] {
        typealias Loss = RestoreTraffic.Loss
        // Leaving a home tunnel for Direct is leaving a tunnel for Direct, wherever it is found.
        func plain(_ x: Loss?) -> Loss? { x == .homeDirect ? .toDirect : x }
        var l = found
        (l.defaultRoute, l.apps, l.sites) = (plain(l.defaultRoute), l.apps.mapValues { plain($0)! }, l.sites.mapValues { plain($0)! })
        let apps = Array(l.apps.values), sites = Array(l.sites.values)
        func n(_ list: [Loss], _ kind: Loss) -> Int { list.filter { $0 == kind }.count }
        func parts(_ kind: Loss) -> [String] {
            (l.defaultRoute == kind ? ["The default route"] : []) + [count(n(apps, kind), "app"), count(n(sites, kind), "website")].filter { !$0.hasPrefix("0 ") }
        }
        func one(_ p: [String]) -> Bool { p.count == 1 && (p[0].hasPrefix("The") || p[0].hasPrefix("1 ")) }
        var out: [String] = []
        if l.defaultRoute == .toDirect { out.append("The default route goes from \(current.route(current.defaultRoute)?.name ?? "a VPN") to Direct.") }
        let direct = parts(.toDirect).filter { !$0.hasPrefix("The") }
        if !direct.isEmpty { out.append("\(list(direct)) \(one(direct) ? "goes" : "go") from a VPN route to Direct.") }
        // Said once for all when the filter is turned off.
        let filter = parts(.filter)
        if !filter.isEmpty, !filterOff { out.append("\(list(filter)) \(one(filter) ? "loses" : "lose") the DNS filter.") }
        let blocking = parts(.providerBlocking)
        if !blocking.isEmpty { out.append("\(list(blocking)) \(one(blocking) ? "loses the provider's ad and tracker blocking it has" : "lose the provider's ad and tracker blocking they have") now.") }
        // Refused now because its route waits for its server's config, rather than blocked by choice: said apart.
        func waiting(_ id: String?) -> Bool { id.flatMap(current.route).map { LinkPicker.keyLeftOut($0, in: current) } == true }
        if l.defaultRoute == .unblocked {
            out.append(waiting(current.defaultRoute) ? "The default route can't connect now, because its route waits for a server's config; after the restore its traffic goes out."
                                                     : "The default route can't connect now; after the restore its traffic goes out.")
        }
        let rules = Sites.applied(current)
        func rule(_ name: String) -> String? { rules.filter { Sites.under(name, $0.key) }.max { $0.key.count < $1.key.count }?.value }
        let opened = l.apps.filter { $0.value == .unblocked }.keys, openedSites = l.sites.filter { $0.value == .unblocked && !l.partly.contains($0.key) }.keys
        let openedUnder = l.sites.filter { $0.value == .unblocked && l.partly.contains($0.key) }.count
        let appsWaiting = opened.filter { waiting(current.routeOf($0)) }.count, sitesWaiting = openedSites.filter { waiting(rule($0)) }.count
        let appsBlocked = opened.count - appsWaiting, sitesBlocked = openedSites.count - sitesWaiting
        if appsBlocked > 0 { out.append(appsBlocked == 1 ? "1 app that is blocked now won't be." : "\(appsBlocked) apps that are blocked now won't be.") }
        if sitesBlocked > 0 { out.append(sitesBlocked == 1 ? "1 website that is blocked now won't be." : "\(sitesBlocked) websites that are blocked now won't be.") }
        if openedUnder > 0 { out.append("Under \(count(openedUnder, "website")), names of a Tailscale network that are blocked now won't be.") }
        let wait = [count(appsWaiting, "app"), count(sitesWaiting, "website")].filter { !$0.hasPrefix("0 ") }
        if !wait.isEmpty {
            out.append("\(list(wait)) that can't connect now, because \(one(wait) ? "its route waits" : "their routes wait") for a server's config, \(one(wait) ? "goes" : "go") out without it.")
        }
        if !l.home.isEmpty { out.append("Part of the home network goes Direct instead of through the home tunnel.") }
        return out
    }

    /// The provider settings that block or choose more carefully, turned off for a provider `next` has routes on; the
    /// block list a backup never holds, gone back to the standard one; and routes whose own blocking choice turns it
    /// off. Blocking settings count only where a route of that provider blocks now.
    private static func providerWeakens(_ current: Setup, _ next: Setup) -> [String] {
        let blocks = ["protect": "ads and trackers", "adult": "adult sites", "gambling": "gambling sites", "social": "social media", "hardcore": "Google and Facebook"]
        var out: [String] = []
        for id in Set(next.routes.filter { !$0.imported }.map(\.loc.provider)).sorted() {
            guard let p = Providers.get(id) else { continue }
            func off(_ key: String) -> Bool { p.option(key) != nil && current.opt(id, key) == "on" && next.opt(id, key) != "on" }
            if current.routes.contains(where: { !$0.imported && $0.loc.provider == id && current.protects($0) }) {
                let what = ["protect", "adult", "gambling", "social", "hardcore"].filter(off).compactMap { blocks[$0] }
                // "ads and trackers" is a pair already: what follows it comes after a comma.
                if !what.isEmpty { out.append("\(p.name) stops blocking " + (what.count > 1 && what[0] == blocks["protect"] ? "\(what[0]), and \(list(Array(what.dropFirst())))." : "\(list(what)).")) }
                if next.opt(id, "protect") == "on", let l = p.option("list"), current.opt(id, "list") != l.defaultValue, next.opt(id, "list") == l.defaultValue {
                    out.append("\(p.name)'s \(l.label.lowercased()) goes back to the standard one.")
                }
            }
            if off("owned") { out.append("\(p.name) no longer keeps to the servers it owns.") }
        }
        // A route's own choice, where the provider's setting doesn't already say it.
        let routes = next.routes.filter { r in
            !next.protects(r) && !(current.opt(r.loc.provider, "protect") == "on" && next.opt(r.loc.provider, "protect") != "on")
                && current.route(r.id).map { !$0.imported && $0.loc.provider == r.loc.provider && current.protects($0) } == true
        }.count
        if routes > 0 { out.append("Ad and tracker blocking is turned off for \(count(routes, "route")).") }
        return out
    }

    /// Whether anything is set up on this Mac beyond what a new install starts with.
    static func setUp(_ s: Setup) -> Bool {
        let fresh = Setup()
        return s.routes != fresh.routes || s.defaultRoute != fresh.defaultRoute || !s.apps.isEmpty || !s.sites.isEmpty || !s.profiles.isEmpty
            || !s.servers.isEmpty || s.home.wg != nil
    }

    static func restored(onto current: Setup, from content: Content, keepPrevious: Bool, now: Date, held: Set<String> = []) -> Setup {
        plan(onto: current, from: content, keepPrevious: keepPrevious, now: now, held: held).setup
    }

    /// This Mac's setup replaced by `content`'s. This Mac's Tailscale, statistics consent and profile request salt
    /// stay; its Home WireGuard tunnel stays too unless the backup has keys. A server saved without keys that this Mac
    /// still has (`OwnServer.sameAs`) takes this Mac's config, and a proxy server this Mac has with its password keeps
    /// this Mac's keychain item (`keptItems`). With `keepPrevious` (and something set up here), the setup in use is kept as the profile
    /// `previous` (or with a number), with this Mac's routes and own servers: shared where the backup has the same one,
    /// under a new id where it uses that id for something else, and the kept profile follows it. `now` is when the
    /// restore happens, for rules that run from it. `apps` are the patterns of the apps on this Mac, as the engine is
    /// given them, for what the sheet says each app gets (made up from their keys when nil). `held`: this Mac's proxy
    /// keychain items that hold a password (`Socks5Secrets.held`), the same for the sheet and the restore.
    static func plan(onto current: Setup, from content: Content, keepPrevious: Bool, now: Date, held: Set<String> = [], apps: [String: [String]]? = nil,
                     judge: Bool = true) -> Plan {
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
        // A proxy server this Mac has with its password keeps this Mac's item (`keptItems`), with or without keys.
        let mine = keptItems(onto: current, from: b, held: held)
        for i in b.routes.indices {
            guard let item = b.routes[i].socks5.flatMap({ mine[$0.item] }) else { continue }
            b.routes[i].socks5?.item = item; b.routes[i].keyless = false
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
        // The slow part (both setups compiled and walked): left out where only the restored setup is needed.
        if judge { plan.weakens = weakens(current, r, apps: apps) }
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
        // A Via of the backup that points at nothing in the backup keeps pointing at nothing: never at a route of this Mac
        // that happens to have that id.
        let inBackup = Set(r.routes.map(\.id))
        for i in r.routes.indices { if let v = r.routes[i].via, !inBackup.contains(v) { r.routes[i].via = fresh("gone", routeIds) } }
        // Entries first (a Via goes through a route that goes straight, so no chain): a route's Via follows its entry to the
        // id that entry has here, and is compared with the backup's route only then. Appended in this Mac's own order.
        var added: [(at: Int, route: Route)] = []
        for (at, x) in current.routes.enumerated().sorted(by: { ($0.element.via == nil ? 0 : 1, $0.offset) < ($1.element.via == nil ? 0 : 1, $1.offset) }) {
            var c = x
            // Tied to a server this Mac no longer has: untied, as a backup's reader unties it.
            c.own = x.own.flatMap { sv[$0] }
            // A Via whose route this Mac no longer has stays a Via to nothing (blocked), never one to a route of the backup's.
            c.via = x.via.map { v in rt[v] ?? (current.route(v) == nil ? fresh("gone", routeIds) : v) }
            if let there = r.route(x.id) {
                if filed(there) == filed(c) { rt[x.id] = x.id; continue }
                c.id = fresh("r", routeIds)
            }
            added.append((at, c)); routeIds.insert(c.id); rt[x.id] = c.id
        }
        r.routes.append(contentsOf: added.sorted { $0.at < $1.at }.map(\.route))
        // Together more than a backup holds: the next backup of it couldn't be restored, so nothing is kept and the
        // backup is restored on its own (the plan's setup is still that one).
        guard r.routes.count <= maxRoutes, r.servers.count <= maxServers else {
            plan.unkept = true; plan.tooBig = true; plan.needConfig = needConfig(plan.setup); return plan
        }
        let m = { (id: String) in rt[id] ?? id }
        let valid = Set(current.routes.map(\.id) + [DIRECT, BLOCK])
        let kept = Profile(name: name, defaultRoute: valid.contains(current.defaultRoute) && current.defaultRoute != BLOCK ? m(current.defaultRoute) : DIRECT,
                           apps: current.apps.filter { valid.contains($0.value) }.mapValues(m),
                           sites: current.sites.filter { valid.contains($0.value) }.mapValues(m))
        r.profiles.append(kept)
        plan.setup = r
        plan.keptAs = name
        // The setup in use comes along: what goes is this Mac's other profiles, settings and Home WireGuard tunnel.
        plan.replaces = Summary(profiles: current.profiles.count, homeTunnel: replaced.homeTunnel)
        plan.needConfig = needConfig(r)
        return plan
    }

    private static func needConfig(_ s: Setup) -> [String] { s.servers.filter(\.keyless).map(\.name) }

    /// [s] with each proxy route whose password the keychain didn't take ([items]) waiting for it (`Route.keyless`).
    static func waiting(_ s: Setup, for items: Set<String>) -> Setup {
        var s = s
        for i in s.routes.indices where s.routes[i].socks5.map({ items.contains($0.item) }) == true { s.routes[i].keyless = true }
        return s
    }

    /// Own servers and routes of their own in `s` that the import would warn about (`Manual.weakness`), unless
    /// `accepted` has the very same config: "name: why", once each.
    static func weak(_ s: Setup, accepted: Setup) -> [String] {
        let known = Set(accepted.servers.flatMap { [$0.ovpn.map(AnyHashable.init), $0.ss.map(AnyHashable.init)] }.compactMap { $0 }
                        + accepted.routes.flatMap { [$0.ovpn.map(AnyHashable.init), $0.ss.map(AnyHashable.init)] }.compactMap { $0 })
        var out: [String] = []
        let all = s.servers.filter { !$0.keyless }.map { ($0.name, $0.ovpn, $0.ss) } + s.routes.filter { !$0.keyless }.map { ($0.name, $0.ovpn, $0.ss) }
        for (name, ovpn, ss) in all {
            let why = ovpn.flatMap { known.contains($0) ? nil : (try? Manual.weakness($0)) ?? nil } ?? ss.flatMap { known.contains($0) ? nil : Manual.weakness($0) }
            // The import's first sentence says what is weak; the rest (what it risks) the sheet says once for all.
            guard let why, let first = why.split(separator: ". ", maxSplits: 1).first else { continue }
            var what = String(first).hasSuffix(".") ? String(first.dropLast()) : String(first)
            if what.hasPrefix("This config ") { what = String(what.dropFirst("This config ".count)) }
            if !out.contains("\(name): \(what)") { out.append("\(name): \(what)") }
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

    /// The backup's proxy items that stay this Mac's own (the backup's item → this Mac's): every route of the backup on
    /// that item has a route here with the same id, not waiting for its password, with the very same proxy server apart
    /// from the item (`sameProxy`); all of those are on one item of this Mac, which [held] has its password (or the proxy
    /// takes no login); and no other item of the backup comes to that one. A restore never writes over a password this
    /// Mac keeps, and never gives a route a password of another login. Anything else gets the backup's own.
    static func keptItems(onto current: Setup, from backup: Setup, held: Set<String>) -> [String: String] {
        var out: [String: String] = [:]
        for (item, routes) in Dictionary(grouping: backup.routes.filter { $0.socks5 != nil }, by: { $0.socks5?.item ?? "" }) {
            let here = routes.compactMap { r in
                current.route(r.id).flatMap { m in m.keyless ? nil : m.socks5.flatMap { sameProxy($0, r.socks5) ? $0 : nil } }
            }
            guard here.count == routes.count, Set(here.map(\.item)).count == 1, let mine = here.first,
                  held.contains(mine.item) || here.allSatisfy({ $0.username == nil }) else { continue }
            out[item] = mine.item
        }
        let taken = Dictionary(grouping: out.values, by: { $0 }).mapValues(\.count)
        return out.filter { taken[$0.value] == 1 }
    }

    /// The backup's proxy passwords a restore writes: none for an item whose routes keep this Mac's (`keptItems`).
    static func passwords(_ content: Content, onto current: Setup, held: Set<String>) -> [String: String] {
        let kept = keptItems(onto: current, from: content.setup, held: held)
        return content.passwords.filter { kept[$0.key] == nil }
    }

    /// The same proxy server, login and proxy app, whatever keychain item holds the password. Compared byte for byte:
    /// two spellings Swift takes for one string are two logins to the proxy.
    private static func sameProxy(_ a: Socks5Profile, _ b: Socks5Profile?) -> Bool {
        guard let b else { return false }
        func bytes(_ x: Socks5Profile) -> [[UInt8]?] { [Array(x.name.utf8), Array(x.host.utf8), x.username.map { Array($0.utf8) }, x.proxyApp.map { Array($0.utf8) }] }
        return a.port == b.port && bytes(a) == bytes(b)
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
    /// your Tailscale sign-in and statistics stay as they are."
    static func replaces(_ s: Summary, keptAs: String? = nil) -> String {
        if let keptAs {
            let parts = ["settings"] + counts(s) + (s.homeTunnel ? ["Home WireGuard tunnel"] : [])
            return "Your \(list(parts)) on this Mac. The setup in use is kept as the profile \"\(keptAs)\". Provider sign-ins, your Tailscale sign-in and statistics stay as they are."
        }
        let parts = counts(s) + (s.homeTunnel ? ["Home WireGuard tunnel"] : [])
        let stay = "Provider sign-ins, your Tailscale sign-in and statistics stay as they are."
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
            case .easy: "Easy to guess. Four or more different words work well."
            case .fair: "Fair. Longer is safer: four or more words work well."
            case .hard: "No obvious pattern found: the meter knows common ones only"
            }
        }
    }

    /// How hard a passphrase is to guess, by a few rules that can be said in a sentence each. It is judged as the file's
    /// key is made from it (NFC), in lower case, cut into words at spaces and ASCII punctuation:
    /// - each word counts once: a word whose stem (the word without the number at its start or end) came before adds
    ///   nothing, nor does the punctuation after it, so "pass1 pass2 pass3" is one word; spaces add nothing;
    /// - a common password counts as one character;
    /// - in what is left, a character adds nothing when it repeats the one before, starts a stretch of two or more
    ///   that already appeared (and the number right after such a stretch of three or more: "pass1pass2"), or
    ///   continues a walk: a step to a neighbouring letter or digit (abc, 321, in any script's digits) or key on a
    ///   keyboard (qaz, asd; a shifted digit is its key: !QAZ), after such a step, or the same with every other
    ///   character (q1w2e3).
    /// The whole passphrase is judged: runs of one character count once before anything else, so a long repeat at its
    /// start doesn't hide what follows (up to 4,096 characters, far more than any rating needs).
    /// Server keys go in a file only under a passphrase rated hard (`BackupTexts.saveCheck`).
    /// Hard: four or more different words of three characters or more that count for 12 characters together, or 72
    /// bits from the counted characters: a plain one (ASCII, a letter with a case or a digit in any script) by the kinds of
    /// plain character used (lower case, upper case, digits, punctuation), any other (letters without case such as Han,
    /// emoji) 7, or 11 when those make up most of it. Letters make walks in ASCII only; digits in any script.
    /// It catches obvious patterns only, and says so.
    static func strength(_ passphrase: String) -> Strength {
        let p = passphrase.precomposedStringWithCanonicalMapping
        let (words, kept) = distinctWords(p)
        let chars = guessable(kept), counted = chars.count
        // Plain characters by the kinds of plain character used; any other (another script, an emoji) by a fixed
        // amount, larger only when those make up most of it: one of them doesn't make every plain one count more.
        // Plain: ASCII, and letters with a case in any script (é, д): a small alphabet each, like a-z.
        func plain(_ c: Character) -> Bool { c.isASCII || c.isLowercase || c.isUppercase || c.isNumber }
        let ascii = p.filter(plain)
        let kinds = [(26, ascii.contains(where: \.isLowercase)), (26, ascii.contains(where: \.isUppercase)), (10, ascii.contains(where: \.isNumber)),
                     (33, ascii.contains { !$0.isLetter && !$0.isNumber && !$0.isWhitespace })]
        let pool = Double(max(2, kinds.reduce(0) { $0 + ($1.1 ? $1.0 : 0) }))
        let other = chars.filter { !plain($0) }.count
        let bits = Double(counted - other) * log2(pool) + Double(other) * (2 * other > counted ? 11 : 7)
        let fourWords = words.filter { $0.count >= 3 && guessable($0).count >= 3 }.count >= 4 && counted >= 12
        return fourWords || bits >= 72 ? .hard : bits >= 50 ? .fair : .easy
    }

    /// Passwords everyone tries first: each counts as one character wherever it appears.
    private static let common = ["password", "passw0rd", "qwerty", "azerty", "letmein", "welcome", "iloveyou", "admin", "unbraid", "monkey", "dragon", "123456"]

    /// The words of `p` in lower case, each common password one character, each stem once (see `strength`), and the
    /// text that counts: the words kept, each with the punctuation after it (spaces add nothing).
    private static func distinctWords(_ p: String) -> (words: [String], kept: String) {
        var t = p.lowercased()
        for w in common { t = t.replacingOccurrences(of: w, with: "\u{1}") }
        func separator(_ c: Character) -> Bool { c.isWhitespace || (c.isASCII && !c.isLetter && !c.isNumber && c != "\u{1}") }
        // Pieces: a word and the separators after it; what comes before the first word stands alone.
        var pieces: [(word: String, after: String)] = [("", "")]
        // Runs of one character first, then the cap: a long repeat at the start can't push the rest out of it.
        for c in t.reduce(into: "", { if $0.last != $1 { $0.append($1) } }).prefix(4096) {
            if separator(c) { pieces[pieces.count - 1].after.append(c) }
            else if pieces[pieces.count - 1].after.isEmpty { pieces[pieces.count - 1].word.append(c) }
            else { pieces.append((String(c), "")) }
        }
        var stems: Set<String> = [], words: [String] = [], kept = ""
        for piece in pieces {
            let stem = String(piece.word.drop(while: \.isNumber).reversed().drop(while: \.isNumber).reversed())
            guard piece.word.isEmpty || stems.insert(stem.isEmpty ? piece.word : stem).inserted else { continue }
            if !piece.word.isEmpty { words.append(piece.word) }
            kept += piece.word + piece.after.filter { !$0.isWhitespace }
        }
        return (words, kept)
    }

    /// Plain letters and digits next to each other on a QWERTY, QWERTZ or AZERTY keyboard, both ways.
    private static let keyboard: Set<String> = {
        var pairs: Set<String> = []
        for rows in [["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"], ["1234567890", "qwertzuiop", "asdfghjkl", "yxcvbnm"],
                     ["1234567890", "azertyuiop", "qsdfghjklm", "wxcvbn"]] {
            let keys = rows.enumerated().flatMap { r, row in row.enumerated().map { (ch: $0.element, x: Double($0.offset) + [0, 0.5, 0.75, 1.25][r], y: r) } }
            for a in keys { for b in keys where a.ch != b.ch && abs(a.y - b.y) <= 1 && abs(a.x - b.x) <= 1 { pairs.insert("\(a.ch)\(b.ch)") } }
        }
        return pairs
    }()

    /// The characters of `s` (as the user sees them) that add to a guess (see `strength`).
    private static func guessable(_ s: String) -> [Character] {
        // A run of one character is one: then a long repeat costs nothing to look at, and what follows it is judged.
        var c: [Character] = []
        for ch in s where ch != c.last { c.append(ch); if c.count == 4096 { break } }
        /// A shifted digit on a keyboard is that digit's key.
        func key(_ ch: Character) -> Character { "!@#$%^&*()".firstIndex(of: ch).map { Array("1234567890")[$0.utf16Offset(in: "!@#$%^&*()")] } ?? ch }
        /// A step between two letters or digits next to each other: in the alphabet, in a script's digits, or on a keyboard.
        func step(_ a: Character, _ b: Character) -> Bool {
            if let x = a.wholeNumberValue, let y = b.wholeNumberValue, a.isNumber, b.isNumber { return abs(x - y) == 1 }
            let a = key(a), b = key(b)
            guard a.isASCII, b.isASCII, a.isLetter || a.isNumber, b.isLetter || b.isNumber, let x = a.asciiValue, let y = b.asciiValue else { return false }
            return abs(Int(x) - Int(y)) == 1 || keyboard.contains("\(a)\(b)")
        }
        /// The longest stretch starting at `i` that already appeared before it.
        func seen(_ i: Int) -> Int {
            var best = 0
            for j in 0..<i where c[j] == c[i] {
                var k = 0
                while i + k < c.count, j + k < i, c[j + k] == c[i + k] { k += 1 }
                best = max(best, k)
            }
            return best
        }
        var n: [Character] = [], i = 0
        while i < c.count {
            let l = seen(i)
            if l >= 2 {
                i += l
                // A counter after a repeated word: "pass1pass2pass3".
                if l >= 3 { while i < c.count, c[i].isNumber { i += 1 } }
                continue
            }
            let walk = (i >= 2 && step(c[i - 2], c[i - 1]) && step(c[i - 1], c[i])) || (i >= 4 && step(c[i - 4], c[i - 2]) && step(c[i - 2], c[i]))
            if (i == 0 || c[i] != c[i - 1]) && !walk { n.append(c[i]) }
            i += 1
        }
        return n
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
    /// A provider route, a Tailscale exit or a proxy server without a login holds no key: it stays as it is. A proxy
    /// server's password is never in the route; it keeps its username and waits for the password.
    func withoutSecrets() -> Route {
        guard imported, tsExit == nil, socks5.map({ $0.username != nil }) != false else { return self }
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
