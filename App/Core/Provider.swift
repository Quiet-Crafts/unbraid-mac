import Foundation

/// Credentials were refused: the user must sign in again.
nonisolated struct AuthError: LocalizedError {
    let errorDescription: String?
    let url: String?
    init(_ message: String = "Sign-in was refused", url: String? = nil) { errorDescription = message; self.url = url }
}

/// What a failed sign-in tells the user: the provider's own reason, a status it answered with (then it isn't the
/// connection), or that it couldn't be reached.
nonisolated func signInFailure(_ error: Error, _ name: String) -> String {
    switch error {
    case let e as Fail: e.errorDescription ?? "\(name) didn't accept these details"
    case let e as AuthError: e.errorDescription ?? "\(name) didn't accept these details"
    case let e as Http.Status where e.code == 429: "\(name) is limiting sign-in attempts. Wait a few minutes, then try again."
    case let e as Http.Status: "\(name) answered with an error (HTTP \(e.code)). Try again later."
    default: "Couldn't reach \(name). Check the connection."
    }
}

/// A closed form cannot receive the result of a sign-in it started.
nonisolated struct SignInForms {
    private var versions: [String: Int] = [:]
    func version(_ id: String) -> Int { versions[id, default: 0] }
    mutating func close(_ id: String) { versions[id, default: 0] += 1 }
}

/// Only clear the nonempty secret that was saved; a newer clipboard value belongs to its owner. A secret copied with a
/// trailing newline or space still counts: whitespace around either side is ignored.
nonisolated func clipboardContains(_ clipboard: String?, secret: String) -> Bool {
    let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    return !secret.isEmpty && clipboard?.trimmingCharacters(in: .whitespacesAndNewlines) == secret
}

/// Provider DNS protection is replaced while unbraid's filter covers VPN routes.
nonisolated func providerProtectionAvailable(_ filter: Filter) -> Bool { !filter.coversRoutes }
nonisolated func providerProtectionAvailable(_ customDns: [String]) -> Bool { customDns.isEmpty }

/// One sign-in form field. `file` = can hold a whole config file (multi-line, with a "Choose file" action).
nonisolated struct Field: Hashable, Sendable {
    var key: String
    var label: String
    var secret = true
    var hint = ""
    var file = false
    var qr = false
}

nonisolated func challengeAnswer(_ field: Field, _ value: String) -> String {
    field.secret ? value : value.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A sign-in question, including provider state needed to answer it.
nonisolated struct Challenge: Error, Sendable {
    var message: String
    var field: Field
    var image: Data? = nil
    var state: [String: String] = [:]
}

/// A provider page setting and the values it accepts.
nonisolated struct ProviderOption: Hashable, Sendable {
    struct Choice: Hashable, Sendable { var value: String; var label: String }
    enum Kind: Hashable, Sendable { case choice([Choice]), toggle, number(ClosedRange<Int>) }
    var key: String
    var label: String
    var kind: Kind
    var defaultValue: String
    var advanced = false
    var help = ""
    var affectsCountries = false
    var affectsLinks = true

    func accepts(_ value: String) -> Bool {
        switch kind {
        case .toggle: return value == "on" || value == "off"
        case .choice(let choices): return choices.contains { $0.value == value }
        case .number(let range): return value.isEmpty || (Int(value).map { range.contains($0) } ?? false)
        }
    }

    static let mtu = ProviderOption(key: "mtu", label: "MTU", kind: .choice(
        [Choice(value: "auto", label: "Default (1280)")] + [1320, 1360, 1380, 1400, 1420].map { Choice(value: String($0), label: String($0)) }),
        defaultValue: "auto", advanced: true, help: "Default works on every network. Larger can be faster on Wi-Fi but can stall uploads on mobile data")
    static let limit = ProviderOption(key: "limit", label: "Your plan's limit", kind: .number(1...999), defaultValue: "", advanced: true, affectsLinks: false)
}

/// A ready tunnel for one exit, produced at connect time.
nonisolated enum Link: Codable, Hashable, Sendable {
    case wg(Server, WgPeer, ports: [Int] = [], entries: [String] = [])
    case ovpn(Server, OvpnProfile)
    case ss(Server, SsProfile)
    /// Out through the built-in Tailscale client's exit node.
    case ts(Server)

    private enum Kind: String, CodingKey { case wg, ovpn, ss, ts }
    private enum Value: String, CodingKey { case _0, _1, ports, entries }

    init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: Kind.self)
        guard let kind = outer.allKeys.first, outer.allKeys.count == 1 else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid link")) }
        let c = try outer.nestedContainer(keyedBy: Value.self, forKey: kind)
        let server = try c.decode(Server.self, forKey: ._0)
        switch kind {
        case .wg: self = .wg(server, try c.decode(WgPeer.self, forKey: ._1), ports: try c.decodeIfPresent([Int].self, forKey: .ports) ?? [], entries: try c.decodeIfPresent([String].self, forKey: .entries) ?? [])
        case .ovpn: self = .ovpn(server, try c.decode(OvpnProfile.self, forKey: ._1))
        case .ss: self = .ss(server, try c.decode(SsProfile.self, forKey: ._1))
        case .ts: self = .ts(server)
        }
    }

    func encode(to encoder: Encoder) throws {
        var outer = encoder.container(keyedBy: Kind.self)
        switch self {
        case .wg(let s, let p, let ports, let entries):
            var c = outer.nestedContainer(keyedBy: Value.self, forKey: .wg)
            try c.encode(s, forKey: ._0); try c.encode(p, forKey: ._1)
            try c.encode(ports, forKey: .ports); try c.encode(entries, forKey: .entries)
        case .ovpn(let s, let p):
            var c = outer.nestedContainer(keyedBy: Value.self, forKey: .ovpn)
            try c.encode(s, forKey: ._0); try c.encode(p, forKey: ._1)
        case .ss(let s, let p):
            var c = outer.nestedContainer(keyedBy: Value.self, forKey: .ss)
            try c.encode(s, forKey: ._0); try c.encode(p, forKey: ._1)
        case .ts(let s):
            var c = outer.nestedContainer(keyedBy: Value.self, forKey: .ts)
            try c.encode(s, forKey: ._0)
        }
    }

    var server: Server {
        switch self { case .wg(let s, _, _, _), .ovpn(let s, _), .ss(let s, _), .ts(let s): s }
    }
}

/// Async implementations enter the concurrent executor, including parsing after network awaits.
/// A VPN provider unbraid can sign in to. `account` is the opaque blob `signIn` returned; the store keeps it sealed.
nonisolated protocol Provider: Sendable {
    var id: String { get }
    var name: String { get }
    var fields: [Field] { get }
    /// Where the user finds what `fields` ask for.
    var help: String { get }
    /// Whether `Server.load` is real. Providers without load data must not show "lowest load" or 0 %.
    var hasLoad: Bool { get }
    /// The tunnel protocol its servers use, shown in the picker (NordVPN lets the user choose).
    var proto: String { get }
    var protection: ProviderOption? { get }
    var defaults: [String: String] { get }
    func options(_ account: String) async throws -> [ProviderOption]
    func blockingDns(_ opts: (String) -> String?) -> String?
    var blockingNote: String { get }
    var blockingUrl: String? { get }
    var configHelp: (String, String)? { get }
    var listSource: String? { get }
    func listDate(_ account: String) async throws -> Int64?
    var keySetup: Int { get }
    var oneKey: Bool { get }
    var deviceURL: String? { get }
    func device(_ account: String) async throws -> String?
    func deviceCount(_ account: String) async throws -> Int?
    func plan(_ account: String) async throws -> String?
    func limit(_ account: String) async throws -> Limit?
    func revoked(_ account: String) async throws -> Bool
    func facts(_ account: String) async throws -> String?

    /// Validates the credentials with the provider and returns what `connect` needs later.
    func signIn(_ input: [String: String]) async throws -> String
    /// Countries with cities, sorted by name. City.key and Location.region carry provider-specific ids.
    func countries(_ account: String) async throws -> [Country]
    /// The same, and whether they come from a list read live just now: only those count as a fresh cached catalogue.
    func freshCountries(_ account: String) async throws -> (countries: [Country], live: Bool, published: Int64?, failed: Bool)
    func freshCountries(_ account: String, opts: [String: String]) async throws -> (countries: [Country], live: Bool, published: Int64?, failed: Bool)
    func connect(_ loc: Location, _ account: String, opts: [String: String]) async throws -> Link
    func servers(_ loc: Location, _ account: String, limit: Int, opts: [String: String]) async throws -> [Server]
    /// Picks the best server for `loc` and returns a ready tunnel.
    func connect(_ loc: Location, _ account: String) async throws -> Link
    /// Up to `limit` servers for a manual pick, best first.
    func servers(_ loc: Location, _ account: String, limit: Int) async throws -> [Server]
    /// Releases what `signIn` registered (device slot, session). False if that failed; the account is forgotten anyway.
    func signOut(_ account: String) async -> Bool
    /// Whether a saved tunnel (from an earlier connection, or cached for when the provider is down) may be reused.
    func trusts(_ link: Link, _ account: String) -> Bool
    /// The part of `trusts` that needs no account, for a tunnel taken over while the keychain can't be read yet.
    func vouches(_ link: Link) -> Bool
}

nonisolated extension Provider {
    var hasLoad: Bool { false }
    var proto: String { "WireGuard" }
    var protection: ProviderOption? {
        guard ["nord", "mullvad", "pia", "ivpn"].contains(id) else { return nil }
        return ProviderOption(key: "protect", label: id == "nord" ? "Threat Protection Lite" : id == "pia" ? "MACE" : "\(name) blocking", kind: .toggle, defaultValue: id == "nord" ? "on" : "off")
    }
    var defaults: [String: String] { [:] }
    @concurrent func options(_ account: String) async throws -> [ProviderOption] { linkOptions }
    func blockingDns(_ opts: (String) -> String?) -> String? {
        if id == "mullvad" {
            let bits = [("adult", 8), ("gambling", 16), ("social", 32)].reduce(7) { $0 + (opts($1.0) == "on" ? $1.1 : 0) }
            return "100.64.0.\(bits)"
        }
        return ["nord": "103.86.96.108", "pia": "10.0.0.244", "ivpn": "10.0.254.2"][id]
    }
    var blockingNote: String {
        switch id {
        case "proton-free": "None on the Free plan. Use unbraid's Protection filter instead"
        case "proton": "NetShield is chosen when you make a config at Proton. Or use unbraid's Protection filter instead"
        case "airvpn": "Set in the AirVPN Client Area. It works through AirVPN's DNS, so not while unbraid's filter is on"
        default: "unbraid can't turn it on or off. Use unbraid's Protection filter instead"
        }
    }
    var blockingUrl: String? { nil }
    var configHelp: (String, String)? { nil }
    var listSource: String? { nil }
    @concurrent func listDate(_ account: String) async throws -> Int64? { nil }
    var keySetup: Int { 0 }
    var oneKey: Bool { false }
    var deviceURL: String? { nil }
    @concurrent func device(_ account: String) async throws -> String? { nil }
    @concurrent func deviceCount(_ account: String) async throws -> Int? { nil }
    @concurrent func plan(_ account: String) async throws -> String? { nil }
    @concurrent func limit(_ account: String) async throws -> Limit? {
        switch id {
        case "nord", "proton": Limit(unit: "connection", perTunnel: true, value: 10)
        case "proton-free": Limit(unit: "connection", perTunnel: true, value: 1)
        case "airvpn": Limit(unit: "connection", perTunnel: true, value: 5)
        case "mullvad": Limit(unit: "device", perTunnel: false, value: 5)
        case "ivpn": Limit(unit: "device", perTunnel: false, value: nil)
        default: Limit(unit: "connection", perTunnel: true, value: nil)
        }
    }
    @concurrent func revoked(_ account: String) async throws -> Bool { false }
    @concurrent func facts(_ account: String) async throws -> String? { nil }

    var commonOptions: [ProviderOption] { proto == "WireGuard" ? [.mtu, .limit] : [.limit] }
    var linkOptions: [ProviderOption] {
        var result: [ProviderOption] = []
        if id == "mullvad" {
            result += [("adult", "Adult content"), ("gambling", "Gambling"), ("social", "Social media")].map { ProviderOption(key: $0.0, label: $0.1, kind: .toggle, defaultValue: "off", help: "Also blocked while Mullvad blocking is on") }
            result.append(ProviderOption(key: "owned", label: "Mullvad-owned servers only", kind: .toggle, defaultValue: "off", help: "Leaves out servers Mullvad rents. Servers you pinned stay", affectsCountries: true))
            result.append(ProviderOption(key: "port", label: "Port", kind: .choice([.init(value: "auto", label: "Automatic")] + [51820, 53, 123, 4500].map { .init(value: String($0), label: "UDP \($0)") }), defaultValue: "auto", advanced: true, help: "Automatic tries 51820 first, then other ports when a network blocks it"))
        }
        if id == "ivpn" {
            result.append(ProviderOption(key: "list", label: "Block list", kind: .choice([.init(value: "10.0.254.2|10.0.254.3", label: "Default")]), defaultValue: "10.0.254.2|10.0.254.3"))
            result.append(ProviderOption(key: "hardcore", label: "Hardcore mode", kind: .toggle, defaultValue: "off", advanced: true))
            result.append(ProviderOption(key: "port", label: "Port", kind: .choice([.init(value: "auto", label: "Automatic")]), defaultValue: "auto", advanced: true))
        }
        if id == "airvpn" {
            result.append(ProviderOption(key: "port", label: "Port", kind: .choice([.init(value: "auto", label: "Automatic"), .init(value: "1637", label: "UDP 1637"), .init(value: "47107", label: "UDP 47107")]), defaultValue: "auto", advanced: true))
            result.append(ProviderOption(key: "entry", label: "Entry address", kind: .choice([.init(value: "1", label: "Standard"), .init(value: "2", label: "Alternative")]), defaultValue: "1", advanced: true))
        }
        return result
    }
    func option(_ key: String) -> ProviderOption? { ([protection].compactMap { $0 } + commonOptions + linkOptions).first { $0.key == key } }
    @concurrent func servers(_ loc: Location, _ account: String, limit: Int) async throws -> [Server] { [] }
    @concurrent func signOut(_ account: String) async -> Bool { true }
    func trusts(_ link: Link, _ account: String) -> Bool { true }
    func vouches(_ link: Link) -> Bool { true }
    @concurrent func freshCountries(_ account: String) async throws -> (countries: [Country], live: Bool, published: Int64?, failed: Bool) { (try await countries(account), true, nil, false) }
    @concurrent func freshCountries(_ account: String, opts: [String: String]) async throws -> (countries: [Country], live: Bool, published: Int64?, failed: Bool) { try await freshCountries(account) }
    @concurrent func connect(_ loc: Location, _ account: String, opts: [String: String]) async throws -> Link { try await connect(loc, account) }
    @concurrent func servers(_ loc: Location, _ account: String, limit: Int, opts: [String: String]) async throws -> [Server] { try await servers(loc, account, limit: limit) }
}

/// Providers that only offer downloadable configs: the user imports one file per location.
nonisolated struct ImportGuide: Hashable, Sendable {
    var id: String
    var name: String
    var openVpn: Bool
    var `where`: String
    var url: String
}

nonisolated enum Providers {
    static let all: [any Provider] = [Nord(), Mullvad(), Pia(), Ivpn(), Proton(), ProtonFree(), Surfshark(), ExpressVpn(), Windscribe(), AirVpn()]
    static func get(_ id: String) -> (any Provider)? { all.first { $0.id == id } }

    /// Name short enough for a route label: "Nord", "PIA", "Proton".
    static func short(_ id: String) -> String {
        ["nord": "Nord", "pia": "PIA", "proton": "Proton", "proton-free": "Proton Free"][id] ?? get(id)?.name ?? id
    }

    static let imports = [
        ImportGuide(id: "purevpn", name: "PureVPN", openVpn: false, where: "Member Area → Manual configuration → WireGuard", url: "https://my.purevpn.com/"),
        ImportGuide(id: "cyberghost", name: "CyberGhost", openVpn: true, where: "My Devices → Configure new device → OpenVPN", url: "https://my.cyberghostvpn.com/"),
    ]
}

/// JSON shared by providers and the store.
nonisolated enum JSON {
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ what: String) throws -> T {
        // Decoding errors can quote the input (tokens, keys): replace them with a fixed message.
        do { return try JSONDecoder().decode(type, from: data) } catch { throw Fail("Unexpected reply from \(what)") }
    }
    static func encode<T: Encodable>(_ v: T) -> String { String(decoding: (try? JSONEncoder().encode(v)) ?? Data(), as: UTF8.self) }
    /// Parses loosely typed provider replies ([String: Any] / [Any]).
    static func object(_ data: Data, _ what: String) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data) } catch { throw Fail("Unexpected reply from \(what)") }
    }
}
