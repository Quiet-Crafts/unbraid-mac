import CryptoKit
import Foundation

/// Route ids with a fixed meaning: Direct goes out unprotected, Block refuses every connection (a per-app firewall).
nonisolated let DIRECT = "direct"
nonisolated let BLOCK = "block"

/// Where a route exits. Only `provider` set = that provider's fastest server anywhere.
nonisolated struct Location: Codable, Hashable, Sendable {
    var provider = "nord"
    var countryId: Int?
    var countryCode: String?
    var country: String?
    var cityId: Int?
    var city: String?
    /// Provider-specific region or city id (Mullvad "se-got", PIA "de-frankfurt").
    var region: String?
    var group: String?
    /// NordVPN only: nil = NordLynx, else openvpn_udp / openvpn_tcp. Double VPN and Onion always use OpenVPN.
    var proto: String?
    var pinned: Server?

    enum CodingKeys: String, CodingKey { case provider, countryId, countryCode, country, cityId, city, region, group, proto = "protocol", pinned }

    var label: String { pinned?.name ?? city.map { "\(country ?? "") · \($0)" } ?? country ?? "Fastest" }
    var code: String { countryCode ?? "··" }

    /// What makes two locations the same place: Nord ids are Nord's own; other providers' ids are derived, so those
    /// compare by code, city and region. Pins compare by server name.
    var ident: Location {
        var l = self
        if provider != "nord" { l.countryId = nil; l.cityId = nil }
        l.pinned = pinned.map { Server(name: $0.name, host: "", ip: "", publicKey: "", load: -1) }
        return l
    }

    /// How a location is remembered as a favourite: its ident, without server group or protocol.
    var favKey: Location { var l = ident; l.group = nil; l.proto = nil; return l }
}

nonisolated struct Server: Codable, Hashable, Sendable {
    var name: String
    var host: String
    var ip: String
    var publicKey: String
    var load: Int
    var city = ""
    var country = ""
}

/// A plain WireGuard peer, e.g. a FRITZ!Box export.
nonisolated struct WgPeer: Codable, Hashable, Sendable {
    var name: String
    var privateKey: String
    var address: [String]
    var publicKey: String
    var presharedKey: String?
    var endpoint: String
    var allowedIps: [String]
    var dns: [String] = []
    var mtu = 1420
    var keepalive: Int? = nil
}

/// An imported OpenVPN profile (ExpressVPN, CyberGhost…): the raw .ovpn plus its login.
nonisolated struct OvpnProfile: Codable, Hashable, Sendable {
    var name: String
    var config: String
    var username = ""
    var password = ""
}

/// A Shadowsocks server (e.g. an Outline access key).
nonisolated struct SsProfile: Codable, Hashable, Sendable {
    var name: String
    var server: String
    var port: Int
    var method: String
    var password: String
    var plugin: String?
    var pluginOpts: String?
}

/// One exit. Exactly one source: a provider `loc`, an imported `wg`/`ovpn`/`ss` server, or `tsExit`, a Tailscale exit
/// node (its tailnet IP) reached through the built-in Tailscale client.
nonisolated struct Route: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var loc = Location()
    var wg: WgPeer?
    var ovpn: OvpnProfile?
    var ss: SsProfile?
    var tsExit: String?
    /// Display name of the `tsExit` node.
    var tsName: String?
    var hue = 0
    /// The provider's own ad and tracker blocking DNS (Mullvad blocklists, PIA MACE, IVPN AntiTracker).
    var filter: Bool? = nil
    /// The saved OwnServer whose config this route copies, so renaming or removing it reaches the route.
    var own: String?

    var name: String { wg?.name ?? ovpn?.name ?? ss?.name ?? tsName ?? tsExit ?? loc.country ?? "Fastest" }
    var code: String { wg != nil ? "WG" : ovpn != nil ? "OV" : ss != nil ? "SS" : tsExit != nil ? "TS" : loc.code }
    /// Not tied to a provider account.
    var imported: Bool { wg != nil || ovpn != nil || ss != nil || tsExit != nil }
    /// Who carries this route: the provider, or the kind of own server.
    var source: String {
        wg != nil ? "WireGuard" : ovpn != nil ? "OpenVPN" : ss != nil ? "Shadowsocks" : tsExit != nil ? "Tailscale" : Providers.short(loc.provider)
    }
}

nonisolated struct Home: Codable, Hashable, Sendable {
    var tailscale = false
    var tsAuthKey: String?
    /// The node identity the extension has sealed for this user and control server (`TsEnrolment`): while set, the auth
    /// key stays out of the configuration.
    var tsEnrolled: String?
    /// Self-hosted coordination server (Headscale); nil = Tailscale's.
    var tsControlUrl: String?
    /// The tailnet's MagicDNS domain in use: Tailscale's own as reported, another only once the user accepted it.
    var tsSuffix: String?
    var tsSuffixConfirmed: Bool = false
    /// LANs behind a Tailscale subnet router, e.g. 192.168.1.0/24, reached through Tailscale from anywhere.
    var subnets: [String] = []
    var wg: WgPeer?
}

nonisolated struct Filter: Codable, Hashable, Sendable {
    var id: String? = nil
    var value = ""
    var routes = false
    var direct = false
    var directApps = false
    var apps: [String: Bool] = [:]

    init(id: String? = nil, value: String = "", routes: Bool = false, direct: Bool = false, directApps: Bool = false, apps: [String: Bool] = [:]) {
        self.id = id; self.value = value; self.routes = routes; self.direct = direct; self.directApps = directApps; self.apps = apps
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.saved(.id, nil); value = try c.saved(.value, ""); routes = try c.saved(.routes, false); direct = try c.saved(.direct, false)
        directApps = try c.saved(.directApps, false); apps = try c.saved(.apps, [:])
    }
    var server: FilterServer? {
        guard let id else { return nil }
        if id == "own" { return FilterServer.own(value) }
        guard var server = FilterServer.presets.first(where: { $0.id == id }) else { return nil }
        if id == "nextdns" {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard v.range(of: #"^[A-Za-z0-9]{1,32}$"#, options: .regularExpression) != nil else { return nil }
            server.path = "/" + v
        }
        return server
    }
    var coversRoutes: Bool { routes && server != nil }
    func through(_ app: String) -> Bool { server != nil && (apps[app] ?? directApps) }
}

nonisolated struct FilterServer: Hashable, Sendable {
    var id: String, name: String, blocks: String, address: String
    var tls: String?
    var path: String? = "/dns-query"
    var port: Int = 443
    static let presets: [FilterServer] = [
        .init(id: "adguard", name: "AdGuard DNS", blocks: "Ads and trackers", address: "94.140.14.14", tls: "dns.adguard-dns.com"),
        .init(id: "adguard-family", name: "AdGuard DNS Family", blocks: "Ads, trackers and adult sites", address: "94.140.14.15", tls: "family.adguard-dns.com"),
        .init(id: "cloudflare-security", name: "Cloudflare 1.1.1.2", blocks: "Malware", address: "1.1.1.2", tls: "security.cloudflare-dns.com"),
        .init(id: "cloudflare-family", name: "Cloudflare 1.1.1.3", blocks: "Malware and adult sites", address: "1.1.1.3", tls: "family.cloudflare-dns.com"),
        .init(id: "nextdns", name: "NextDNS", blocks: "What your NextDNS profile blocks", address: "45.90.28.0", tls: "dns.nextdns.io"),
        .init(id: "quad9", name: "Quad9", blocks: "Malware", address: "9.9.9.9", tls: "dns.quad9.net"),
    ]
    static func ipv4(_ value: String) -> Bool {
        let p = value.split(separator: ".", omittingEmptySubsequences: false)
        return p.count == 4 && p.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } && UInt8($0) != nil && ($0 == "0" || $0.first != "0") }
    }
    var byName: Bool { !Self.ipv4(address) }
    private static let ownPattern = try? NSRegularExpression(pattern: #"^(https|tls)://([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?(/(?:[A-Za-z0-9._~!$&'()*+,;=:@/-]|%[0-9A-Fa-f]{2})*)?$"#)

    static func own(_ text: String) -> FilterServer? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ipv4(text) { return .init(id: "own", name: text, blocks: "", address: text, tls: nil, path: nil, port: 53) }
        guard let m = ownPattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func part(_ n: Int) -> String { Range(m.range(at: n), in: text).map { String(text[$0]) } ?? "" }
        let scheme = part(1), rawHost = part(2).lowercased(), rawPort = part(3), path = part(4)
        let host = String(rawHost.reversed().drop(while: { $0 == "." }).reversed())
        let hostPattern = #"^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$"#
        guard ipv4(host) || host.range(of: hostPattern, options: .regularExpression) != nil,
              scheme == "https" || path.isEmpty else { return nil }
        let port = rawPort.isEmpty ? (scheme == "https" ? 443 : 853) : (Int(rawPort) ?? 0)
        guard (1...65535).contains(port) else { return nil }
        return .init(id: "own", name: text, blocks: "", address: host, tls: ipv4(host) && scheme == "https" ? nil : host,
                     path: scheme == "https" ? (path.isEmpty ? "/dns-query" : path) : nil, port: port)
    }
}

nonisolated struct Prefs: Codable, Hashable, Sendable {
    var threatProtection = true
    var customDns: [String] = []
    var filter = Filter()
    var effectiveFilter: Filter { filter.id == nil && !customDns.isEmpty ? Filter(id: "own", value: customDns[0], routes: true) : filter }
    var lan = true
    /// Local statistics; off until the user agrees, and nothing is recorded while off.
    var stats = false
    #if DEBUG
    var testAllRoutes = true
    #else
    var testAllRoutes = false
    #endif
    /// macOS kill switch (includeAllNetworks): nothing leaves outside the tunnel while it is up or reconnecting.
    var killSwitch = false
    /// The kill switch's Home level: blocked apps can't reach the home network either. See `killLevel`.
    var killSwitchHome = false
    /// Connect On Demand: macOS brings the tunnel back after sleep, network changes and restarts.
    var alwaysOn = false
}

/// One of the user's own servers, added in Settings and picked for any route (which keeps a copy of the config).
nonisolated struct OwnServer: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var wg: WgPeer?
    var ovpn: OvpnProfile?
    var ss: SsProfile?

    var name: String { wg?.name ?? ovpn?.name ?? ss?.name ?? "" }
    var kind: String { wg != nil ? "WireGuard" : ovpn != nil ? "OpenVPN" : "Shadowsocks" }
    var code: String { wg != nil ? "WG" : ovpn != nil ? "OVPN" : "SS" }
}

nonisolated struct Profile: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var defaultRoute: String
    var apps: [String: String] = [:]
    var id: String { name }
}

/// Everything the user configures. Apps are keyed by bundle identifier, or by full path for a command-line tool.
nonisolated struct ProfileSwitch: Codable, Hashable, Sendable {
    var id: UUID
    var target: String
    var from: String?
    var when: Date
    var switched: Profile
    var previous: Profile? = nil
    var previousEngine: String? = nil
    /// The user's selection before the switch can be newer than the engine's last recorded setup.
    var before: Profile? = nil
    var beforePrefs: Prefs? = nil
    var switchedPrefs: Prefs? = nil

    func rollback(_ current: inout Setup, fallback: Setup) {
        var ran = fallback
        if let selection = before ?? previous {
            ran.profile = selection.name.isEmpty ? nil : selection.name
            ran.defaultRoute = selection.defaultRoute
            ran.apps = selection.apps
        }
        // Older pending switches didn't record protection. Keep it rather than guess what they changed.
        ran.prefs = beforePrefs ?? current.prefs
        var switched = current
        switched.profile = target
        switched.defaultRoute = self.switched.defaultRoute
        switched.apps = self.switched.apps
        switched.prefs = switchedPrefs ?? current.prefs
        current.back(to: ran, after: switched)
    }

    func confirmsPrevious(engine: String?, foreign: Bool, fallback: Bool, trusted: Bool) -> Bool {
        guard previous != nil, let expected = previousEngine, let engine else { return false }
        return !foreign && !fallback && trusted && engine == expected
    }

    enum Decision: Equatable { case waiting, applied, refused, stopped, superseded }

    func decide(current: Setup, running: Setup?, refused: Setup?, standIn: RunState.StandIn, stopped: Bool) -> Decision {
        guard current.pendingSwitch?.id == id, current.profile == target else { return .superseded }
        if stopped { return .stopped }
        if let refused, refused.pendingSwitch?.id == id, refused.profile == target { return .refused }
        if standIn != .none { return .waiting }
        if let running, (running.defaultRoute == current.defaultRoute && running.apps == current.apps) ||
            (running.defaultRoute == switched.defaultRoute && running.apps == switched.apps) { return .applied }
        return .waiting
    }
}

nonisolated struct Setup: Codable, Hashable, Sendable {
    var routes = [Route(id: "nl", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands"))] {
        didSet {
            // Imports, sign-outs and server removal all remove routes through this value.
            if !Set(oldValue.map(\.id)).isSubset(of: Set(routes.map(\.id))) { tidyProfiles() }
        }
    }
    var defaultRoute = "nl"
    var apps: [String: String] = [:]
    /// Starred countries, cities or pinned servers, shown first in the picker.
    var favorites = [
        Location(countryId: 228, countryCode: "US", country: "United States"),
        Location(countryId: 106, countryCode: "IT", country: "Italy"),
        Location(countryId: 153, countryCode: "NL", country: "Netherlands"),
    ]
    var home = Home()
    var prefs = Prefs()
    var servers: [OwnServer] = []
    var opts: [String: [String: String]] = [:]
    var profiles: [Profile] = []
    var profile: String? = nil
    var pendingSwitch: ProfileSwitch? = nil
    /// Private to this user's sealed setup; keeps profile requests valid across an unchanged relaunch.
    var profileSalt: String? = nil
    var testing: Set<String> = []

    enum CodingKeys: String, CodingKey { case routes, defaultRoute, apps, favorites, home, prefs, servers, opts, profiles, profile, pendingSwitch, profileSalt }

    /// Profile request identity is not part of the setup the engine runs.
    static func == (lhs: Setup, rhs: Setup) -> Bool {
        lhs.routes == rhs.routes && lhs.defaultRoute == rhs.defaultRoute && lhs.apps == rhs.apps &&
        lhs.favorites == rhs.favorites && lhs.home == rhs.home && lhs.prefs == rhs.prefs &&
        lhs.servers == rhs.servers && lhs.opts == rhs.opts && lhs.profiles == rhs.profiles &&
        lhs.profile == rhs.profile && lhs.pendingSwitch == rhs.pendingSwitch && lhs.testing == rhs.testing
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(routes); hasher.combine(defaultRoute); hasher.combine(apps); hasher.combine(favorites)
        hasher.combine(home); hasher.combine(prefs); hasher.combine(servers); hasher.combine(opts)
        hasher.combine(profiles); hasher.combine(profile); hasher.combine(pendingSwitch); hasher.combine(testing)
    }

    /// Only the store includes the request salt. Engine records and revisions encode the operational setup.
    static let includeProfileSalt = CodingUserInfoKey(rawValue: "includeProfileSalt")!

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(routes, forKey: .routes); try c.encode(defaultRoute, forKey: .defaultRoute)
        try c.encode(apps, forKey: .apps); try c.encode(favorites, forKey: .favorites)
        try c.encode(home, forKey: .home); try c.encode(prefs, forKey: .prefs)
        try c.encode(servers, forKey: .servers); try c.encode(opts, forKey: .opts)
        try c.encode(profiles, forKey: .profiles); try c.encodeIfPresent(profile, forKey: .profile)
        try c.encodeIfPresent(pendingSwitch, forKey: .pendingSwitch)
        if encoder.userInfo[Self.includeProfileSalt] as? Bool == true { try c.encodeIfPresent(profileSalt, forKey: .profileSalt) }
    }

    func opt(_ provider: String, _ key: String) -> String? {
        guard let option = Providers.get(provider)?.option(key) else { return nil }
        let value = opts[provider]?[key]
        if provider == "ivpn", key == "list", let value, Ivpn.validList(value) { return value }
        if provider == "ivpn", key == "port", let value, value == "auto" || (Int(value).map { (1...65535).contains($0) } ?? false) { return value }
        return value.flatMap { option.accepts($0) ? $0 : nil } ?? option.defaultValue
    }

    func protects(_ route: Route) -> Bool {
        !route.imported && (route.filter ?? (opt(route.loc.provider, "protect") == "on"))
    }

    func route(_ id: String?) -> Route? { routes.first { $0.id == id } }
    func routeOf(_ app: String) -> String { apps[app] ?? defaultRoute }
    var allAppsUseDefault: Bool { apps.values.allSatisfy { $0 == defaultRoute } }
    /// Routes that carry traffic right now: the default plus any with apps.
    var activeRoutes: [Route] {
        let used = Set(apps.values)
        return routes.filter { $0.id == defaultRoute || used.contains($0.id) || testing.contains($0.id) }
    }
    /// The Tailscale exit node in use, if an active route goes out through one (Tailscale allows one at a time).
    var tsExit: String? { activeRoutes.lazy.compactMap(\.tsExit).first }
    /// Tailscale runs for home access or for an exit-node route.
    var tailscale: Bool { home.tailscale || tsExit != nil }
}

nonisolated enum ProfileGeneration {
    static func value(_ setup: Setup, accounts: [String: String]) -> String {
        guard let salt = setup.profileSalt, UUID(uuidString: salt) != nil else { return "" }
        struct State: Encodable { var setup: Setup; var accounts: [String: String] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.userInfo[Setup.includeProfileSalt] = true
        let data = try! encoder.encode(State(setup: setup, accounts: accounts))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct City: Codable, Hashable, Sendable {
    var id: Int
    var name: String
    var key: String?
}

nonisolated struct Country: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var name: String
    var code: String
    var serverCount = 0
    var cities: [City] = []
}

/// An id that stays the same when a provider adds or drops places, so saved routes and favourites keep matching.
/// FNV-1a over the lowercased key: stable across launches, unlike Swift's seeded `hashValue`.
nonisolated func stableId(_ key: String) -> Int {
    var h: UInt32 = 2_166_136_261
    for b in key.lowercased().utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
    return Int(h & 0x7fff_ffff)
}

// MARK: - Decoding with defaults

/// Files written by an older build lack newer fields: every field falls back to its default instead of failing the
/// whole file (which would lose the user's setup).
extension KeyedDecodingContainer {
    nonisolated func callAsFunction<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
    }

    /// For what unbraid saves: a field that is missing or can't be read falls back to its default, as above. Read
    /// strictly (`SavedDecoding.strict`), one that is there and can't be read (null where a value is needed included)
    /// fails instead: the store reads that way first, to keep a malformed file as ".bad" before it is saved over.
    nonisolated func saved<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) throws -> T {
        guard SavedDecoding.strict else { return self(key, fallback()) }
        return contains(key) ? try decode(T.self, forKey: key) : fallback()
    }
}

/// How what unbraid saves is read (see `KeyedDecodingContainer.saved`).
nonisolated enum SavedDecoding {
    @TaskLocal static var strict = false
}

nonisolated extension Setup {
    nonisolated init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let s = Setup()
        routes = try c.saved(.routes, s.routes); defaultRoute = try c.saved(.defaultRoute, s.defaultRoute); apps = try c.saved(.apps, s.apps)
        profiles = try c.saved(.profiles, []); profile = try c.saved(.profile, nil); pendingSwitch = try c.saved(.pendingSwitch, nil)
        profileSalt = try c.saved(.profileSalt, nil)
        favorites = try c.saved(.favorites, s.favorites); home = try c.saved(.home, s.home); prefs = try c.saved(.prefs, s.prefs); servers = try c.saved(.servers, s.servers); opts = try c.saved(.opts, [:])
        if !c.contains(.opts) {
            opts["nord"] = ["protect": prefs.threatProtection ? "on" : "off"]
            for i in routes.indices where !routes[i].imported {
                if routes[i].loc.provider == "nord" || (routes[i].loc.provider != "pia" && routes[i].filter == false) { routes[i].filter = nil }
            }
        }
        struct Saved: Decodable { var killSwitchHome: Bool? }
        // Saved before Block required the kill switch: blocked apps were kept off the home network, so they keep that.
        if apps.values.contains(BLOCK), (try? c.decode(Saved.self, forKey: .prefs))?.killSwitchHome == nil {
            prefs.killLevel = .home
        }
        repairProfiles()
        requireKillSwitchForBlocks()
    }

    /// The home network bypasses the tunnel: as the prefs say, and never while an app is blocked, whatever they say (the
    /// block must cover it too; Store.update keeps the kill switch on then anyway).
    var lanBypassesTunnel: Bool { prefs.lanBypassesTunnel && !apps.values.contains(BLOCK) }

    /// Block needs the kill switch (an app could otherwise bind to Wi-Fi itself and get round the tunnel): any blocked
    /// app turns it on at the Internet level, in the same change, so no block ever runs without it.
    mutating func requireKillSwitchForBlocks() {
        if apps.values.contains(BLOCK), prefs.killLevel == .off { prefs.killLevel = .internet }
    }
}

nonisolated extension Prefs {
    nonisolated init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let p = Prefs()
        threatProtection = try c.saved(.threatProtection, p.threatProtection); customDns = try c.saved(.customDns, p.customDns); lan = try c.saved(.lan, p.lan)
        testAllRoutes = try c.saved(.testAllRoutes, p.testAllRoutes)
        filter = try c.saved(.filter, customDns.first.map { Filter(id: "own", value: $0, routes: true) } ?? Filter())
        if !c.contains(.filter), !customDns.isEmpty { customDns = [] }
        stats = try c.saved(.stats, p.stats); killSwitch = try c.saved(.killSwitch, p.killSwitch); alwaysOn = try c.saved(.alwaysOn, p.alwaysOn)
        killSwitchHome = try c.saved(.killSwitchHome, p.killSwitchHome)
    }
}

/// The kill switch's reach. Off: macOS may send traffic outside the tunnel while it is down or reconnecting. Internet:
/// nothing leaves outside it, but the home network (the Wi-Fi's own subnet) is reached directly, by every app. Home:
/// the home network enters the tunnel as well, so blocked apps can't reach it either.
nonisolated enum KillLevel: String, CaseIterable, Sendable {
    case off, internet, home
}

nonisolated extension Prefs {
    var killLevel: KillLevel {
        get { !killSwitch ? .off : killSwitchHome ? .home : .internet }
        set { killSwitch = newValue != .off; killSwitchHome = newValue == .home }
    }

    /// The home network bypasses the tunnel (excludeLocalNetworks) only with the kill switch off: with it on, macOS drops
    /// local traffic kept outside the tunnel (measured on macOS 27, 2026-10-21), so it enters and the engine sends it
    /// direct.
    var lanBypassesTunnel: Bool { lan && killLevel == .off }
    /// Blocked apps keep the home network at the kill switch's Internet level; never its resolvers or a remote home.
    var blockedAppsReachLAN: Bool { lan && killLevel == .internet }
}

nonisolated extension WgPeer {
    nonisolated init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        privateKey = try c.decode(String.self, forKey: .privateKey)
        address = try c.decode([String].self, forKey: .address)
        publicKey = try c.decode(String.self, forKey: .publicKey)
        presharedKey = try c.saved(.presharedKey, nil)
        endpoint = try c.decode(String.self, forKey: .endpoint)
        allowedIps = try c.decode([String].self, forKey: .allowedIps)
        dns = try c.saved(.dns, []); mtu = try c.saved(.mtu, 1420); keepalive = try c.saved(.keepalive, nil)
    }
}

nonisolated extension Home {
    nonisolated init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        tailscale = try c.saved(.tailscale, false); tsAuthKey = try c.saved(.tsAuthKey, nil); tsControlUrl = try c.saved(.tsControlUrl, nil)
        tsSuffix = try c.saved(.tsSuffix, nil); tsSuffixConfirmed = try c.saved(.tsSuffixConfirmed, false); tsEnrolled = try c.saved(.tsEnrolled, nil)
        subnets = try c.saved(.subnets, []); wg = try c.saved(.wg, nil)
    }
}

nonisolated extension Route {
    nonisolated init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        loc = try c.saved(.loc, Location()); wg = try c.saved(.wg, nil); ovpn = try c.saved(.ovpn, nil); ss = try c.saved(.ss, nil); tsExit = try c.saved(.tsExit, nil)
        tsName = try c.saved(.tsName, nil); hue = try c.saved(.hue, 0); filter = try c.saved(.filter, nil); own = try c.saved(.own, nil)
    }
}

nonisolated extension Setup {
    static let maxProfiles = 20
    static let profileNameLimit = 12
    private static let forbiddenProfileCharacters = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{061C}\u{2028}\u{2029}"))

    func profileName(_ raw: String, except: String? = nil) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Self.profileNameLimit,
              name.unicodeScalars.allSatisfy({ $0.value == 0x200D || !Self.forbiddenProfileCharacters.contains($0) }),
              !profiles.contains(where: { $0.name != except && $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }) else { return nil }
        return name
    }

    var saved: [Profile] {
        profiles.map { $0.name == profile ? Profile(name: $0.name, defaultRoute: defaultRoute, apps: apps) : $0 }
    }

    mutating func use(_ name: String) {
        guard name != profile, let target = profiles.first(where: { $0.name == name }) else { return }
        profiles = saved; profile = target.name; defaultRoute = target.defaultRoute; apps = target.apps
        requireKillSwitchForBlocks()
    }

    mutating func beginProfileSwitch(_ name: String, id: UUID, running: Setup?, engine: String?) {
        guard name != profile, profiles.contains(where: { $0.name == name }) else { return }
        let before = Profile(name: profile ?? "", defaultRoute: defaultRoute, apps: apps), beforePrefs = prefs
        use(name)
        pendingSwitch = ProfileSwitch(id: id, target: name, from: before.name.isEmpty ? nil : before.name, when: .now,
            switched: Profile(name: name, defaultRoute: defaultRoute, apps: apps),
            previous: running.map { Profile(name: $0.profile ?? "", defaultRoute: $0.defaultRoute, apps: $0.apps) },
            previousEngine: engine, before: before, beforePrefs: beforePrefs, switchedPrefs: prefs)
    }

    mutating func saveAs(_ raw: String) {
        guard profiles.count < Self.maxProfiles, let name = profileName(raw) else { return }
        profiles = saved + [Profile(name: name, defaultRoute: defaultRoute, apps: apps)]; profile = name
    }

    mutating func rename(_ old: String, _ raw: String) {
        guard let index = profiles.firstIndex(where: { $0.name == old }), let name = profileName(raw, except: old) else { return }
        profiles[index].name = name
        if profile == old { profile = name }
    }

    mutating func forget(_ name: String) {
        profiles.removeAll { $0.name == name }
        if profile == name { profile = nil }
    }

    mutating func move(_ name: String, by offset: Int) {
        guard let index = profiles.firstIndex(where: { $0.name == name }) else { return }
        let destination = max(0, min(profiles.count - 1, index + offset))
        profiles.insert(profiles.remove(at: index), at: destination)
    }

    mutating func tidyProfiles() {
        let valid = Set(routes.map(\.id) + [DIRECT, BLOCK])
        for index in profiles.indices {
            if !valid.contains(profiles[index].defaultRoute) { profiles[index].defaultRoute = routes.first?.id ?? DIRECT }
            profiles[index].apps = profiles[index].apps.filter { valid.contains($0.value) && $0.value != profiles[index].defaultRoute }
        }
    }

    mutating func repairProfiles() {
        let raw = profiles
        profiles = []
        for var p in raw {
            guard profiles.count < Self.maxProfiles, let name = profileName(p.name) else { continue }
            p.name = name; profiles.append(p)
        }
        if !profiles.contains(where: { $0.name == profile }) { profile = nil }
        tidyProfiles()
    }

    mutating func back(to ran: Setup, after switched: Setup? = nil) {
        if let switched {
            let currentDefault = defaultRoute, currentApps = apps, currentProfile = profile
            let currentPrefs = prefs
            back(to: ran)
            if currentDefault != switched.defaultRoute { defaultRoute = currentDefault }
            for key in Set(currentApps.keys).union(switched.apps.keys) where currentApps[key] != switched.apps[key] {
                apps[key] = currentApps[key]
            }
            if currentProfile != switched.profile { profile = currentProfile }
            if defaultRoute != ran.defaultRoute || apps != ran.apps { profile = nil }
            if currentPrefs.killLevel != switched.prefs.killLevel || currentPrefs.killSwitchHome != switched.prefs.killSwitchHome {
                prefs.killSwitch = currentPrefs.killSwitch
                prefs.killSwitchHome = currentPrefs.killSwitchHome
            }
            requireKillSwitchForBlocks()
            return
        }
        let valid = Set(routes.map(\.id) + [DIRECT, BLOCK])
        let same = profiles.first { $0.name == ran.profile && $0.defaultRoute == ran.defaultRoute && $0.apps == ran.apps }
        profiles = saved
        profile = same?.name
        defaultRoute = valid.contains(ran.defaultRoute) ? ran.defaultRoute : (routes.first?.id ?? DIRECT)
        apps = ran.apps.filter { valid.contains($0.value) && $0.value != defaultRoute }
        prefs.killSwitch = ran.prefs.killSwitch
        prefs.killSwitchHome = ran.prefs.killSwitchHome
        requireKillSwitchForBlocks()
    }
}

nonisolated extension Profile {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.saved(.name, "")
        defaultRoute = try c.saved(.defaultRoute, DIRECT)
        apps = try c.saved(.apps, [:])
    }
}
