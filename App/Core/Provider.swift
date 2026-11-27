import Foundation
import Synchronization

/// Credentials were refused: the user must sign in again.
nonisolated struct AuthError: LocalizedError {
    let errorDescription: String?
    let url: String?
    init(_ message: String = "Sign-in was refused", url: String? = nil) { errorDescription = message; self.url = url }
}

/// Every device slot is taken, and the provider can free one by signing out all the account's other devices. `confirm`
/// tells the user so, who must agree first; signing in again with `retry` added to the form does it. `account` is the
/// account the offer was made for: an agreement never carries over to another one.
nonisolated struct SlotsFull: LocalizedError {
    let errorDescription: String?
    let url: String?
    let account: String
    let confirm: String
    let retry: [String: String]
}

/// A provider's key isn't ready: the route stays off (never a plain tunnel).
nonisolated struct KeyNotReady: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// What a failed sign-in tells the user: the provider's own reason, a status it answered with (then it isn't the
/// connection), or that it couldn't be reached.
/// A sign-in that failed after the provider opened a session unbraid then couldn't close: the slot needs removing by hand,
/// so the app says so even when the form it started from has closed.
nonisolated struct SessionLeftOpen: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

nonisolated func signInFailure(_ error: Error, _ name: String) -> String {
    switch error {
    case let e as Fail: e.errorDescription ?? "\(name) didn't accept these details"
    case let e as SessionLeftOpen: e.errorDescription ?? "\(name) didn't accept these details"
    case let e as AuthError: e.errorDescription ?? "\(name) didn't accept these details"
    case let e as SlotsFull: e.errorDescription ?? "\(name) didn't accept these details"
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
    /// The sign-in fields as typed when this was asked: it answers for that account alone.
    var asked: [String: String] = [:]
    /// Whether `typed` (the sign-in fields now) are the ones this was asked for.
    func fits(_ typed: [String: String]) -> Bool { asked.allSatisfy { typed[$0.key] == $0.value } }
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
    /// Numbers the user may type instead of a choice (a port, say); empty = choices only.
    var custom: [ClosedRange<Int>] = []

    /// A typed value `custom` takes: digits only, within one of its ranges.
    func allows(typed: String) -> Bool {
        guard !typed.isEmpty, typed.allSatisfy(\.isASCII), typed.allSatisfy(\.isNumber), let n = Int(typed) else { return false }
        return custom.contains { $0.contains(n) }
    }

    func accepts(_ value: String) -> Bool {
        switch kind {
        case .toggle: return value == "on" || value == "off"
        case .choice(let choices): return choices.contains { $0.value == value } || allows(typed: value)
        case .number(let range): return value.isEmpty || (Int(value).map { range.contains($0) } ?? false)
        }
    }

    static let mtu = ProviderOption(key: "mtu", label: "MTU", kind: .choice(
        [Choice(value: "auto", label: "Default (1280)")] + [1320, 1360, 1380, 1400, 1420].map { Choice(value: String($0), label: String($0)) }),
        defaultValue: "auto", advanced: true, help: "Default works on every network. Larger can be faster on Wi-Fi but can stall uploads on mobile data")
    /// Random packets before each WireGuard handshake: they get past some networks that recognise WireGuard's first packet.
    static let junk = ProviderOption(key: "junk", label: "Junk packets", kind: .toggle, defaultValue: "off", advanced: true,
        help: "Sends a few random packets before each connection starts, which gets past some VPN blocking. The servers ignore them")
    /// How many the engine sends when the switch is on.
    static let junkCount = 5
    /// IVPN: the WireGuard tunnel goes inside V2Ray, which looks like ordinary web traffic (for networks that block VPNs).
    static let disguise = ProviderOption(key: "disguise", label: "Disguise", kind: .toggle, defaultValue: "off", advanced: true,
        help: "Wraps the tunnel in V2Ray so it looks like ordinary web traffic, for networks that block VPNs. A little slower. A server without it stays off")
    static let limit = ProviderOption(key: "limit", label: "Your plan's limit", kind: .number(1...999), defaultValue: "", advanced: true, affectsLinks: false)
}

/// One entry of a provider's protocol choice: what is stored in `Location.proto` (nil = the provider's WireGuard), its
/// name and the line that explains it.
nonisolated struct ProtocolChoice: Hashable, Sendable {
    var key: String?
    var label: String
    var note: String
}

/// Why a route can't run as chosen and no other tunnel may stand in (a cached one included): the message says what to change.
nonisolated struct Unsupported: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// The Automatic protocol: WireGuard, and OpenVPN TCP once a network has blocked WireGuard on every port. Which routes
/// are on TCP is kept in memory only, by route id: it starts over with every connection and on a network change.
nonisolated enum AutoProtocol {
    static let key = "auto"
    static let tcp = "openvpn_tcp"
    private static let onTcp = Mutex<Set<String>>([])

    static func isOnTcp(_ route: String) -> Bool { onTcp.withLock { $0.contains(route) } }
    static var routes: Set<String> { onTcp.withLock { $0 } }
    /// True the first time: the route has just switched.
    @discardableResult static func toTcp(_ route: String) -> Bool { onTcp.withLock { $0.insert(route).inserted } }
    static func reset() { onTcp.withLock { $0.removeAll() } }
    /// The switch to TCP didn't give a tunnel (the profile couldn't be had): back to WireGuard, so that the next round that finds
    /// it dead tries TCP again, and nothing says TCP is in use.
    static func fallBack(_ route: String) { onTcp.withLock { _ = $0.remove(route) } }

    /// The protocol a route connects with now: Automatic is WireGuard (nil) or OpenVPN TCP; any other choice as it is.
    static func of(_ r: Route) -> String? {
        guard !r.imported, r.loc.proto == key else { return r.loc.proto }
        // Through another route (Via) it stays on WireGuard: OpenVPN can't go through one.
        return isOnTcp(r.id) && r.via == nil ? tcp : nil
    }

    /// A route's location as the provider is asked for it: its protocol resolved.
    static func resolved(_ r: Route) -> Location {
        var l = r.loc
        if !r.imported, l.proto == key { l.proto = of(r) }
        return l
    }

    /// Whether a kept or cached tunnel was made with the protocol the route uses now: an Automatic route never gets
    /// back the WireGuard tunnel that stopped answering, nor the TCP one after the network changed.
    static func matches(_ r: Route, _ l: Link) -> Bool {
        guard !r.imported, r.loc.proto == key else { return true }
        let tcpNow = isOnTcp(r.id) && r.via == nil
        if case .ovpn = l { return tcpNow }
        return !tcpNow
    }

    /// The protocol a provider route says it uses after its place: "OpenVPN", "OpenVPN TCP", and for an Automatic route
    /// that is on TCP and running "Using OpenVPN TCP". Nil for WireGuard, and for a provider with no protocol choice.
    static func label(_ r: Route, onTcp: [String], running: Bool) -> String? {
        guard !r.imported, let p = r.loc.proto, Providers.get(r.loc.provider)?.protocols.contains(where: { $0.key == p }) == true else { return nil }
        if p == key { return onTcp.contains(r.id) && running ? "Using OpenVPN TCP" : nil }
        return ["openvpn_udp": "OpenVPN", "openvpn_tcp": "OpenVPN TCP"][p]
    }

    /// WireGuard is blocked on this network once every port it can use has been tried: [step] ports have failed and the
    /// one in use now is the next. A route with a single port (a fixed one, or a provider with one) has nothing to step to.
    static func exhausted(ports: Int, canStep: Bool, step: Int) -> Bool { !canStep || step + 1 >= ports }
}

/// A server's delay (ms) and packet loss (%) as its provider measured them, oldest first; NaN where it has no sample.
/// `days`: the period they cover.
nonisolated struct Quality: Equatable, Sendable {
    var delay: [Float]
    var loss: [Float]
    var days: Int

    private static func known(_ values: [Float]) -> [Float] { values.filter { !$0.isNaN } }
    var delayAverage: Float? { let k = Self.known(delay); return k.isEmpty ? nil : k.reduce(0, +) / Float(k.count) }
    var delayRange: (low: Float, high: Float)? { let k = Self.known(delay); return k.min().flatMap { lo in k.max().map { (lo, $0) } } }
    var lossAverage: Float? { let k = Self.known(loss); return k.isEmpty ? nil : k.reduce(0, +) / Float(k.count) }
    var lossMost: Float? { Self.known(loss).max() }

    private static func number(_ v: Float) -> String {
        let text = v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// One plain line: "Delay 2.1 ms on average (1.8 to 4), packet loss 0%".
    var line: String {
        var parts: [String] = []
        if let a = delayAverage { parts.append("Delay \(Self.number(a)) ms on average" + (delayRange.map { " (\(Self.number($0.low)) to \(Self.number($0.high)))" } ?? "")) }
        if let a = lossAverage { parts.append("packet loss \(Self.number(a))%" + (lossMost.flatMap { $0 > 0 ? " (at most \(Self.number($0))%)" : nil } ?? "")) }
        guard !parts.isEmpty else { return "No measurements in this period" }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// A ready tunnel for one exit, produced at connect time.
nonisolated enum Link: Codable, Hashable, Sendable {
    case wg(Server, WgPeer, ports: [Int] = [], entries: [String] = [])
    case ovpn(Server, OvpnProfile)
    case ss(Server, SsProfile)
    /// A proxy server, as the route gives it: never its password (the compiler gets that apart, `Compiler.Input.socks5`).
    case socks5(Server, Socks5Profile)
    /// Out through the built-in Tailscale client's exit node.
    case ts(Server)

    private enum Kind: String, CodingKey { case wg, ovpn, ss, socks5, ts }
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
        case .socks5: self = .socks5(server, try c.decode(Socks5Profile.self, forKey: ._1))
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
        case .socks5(let s, let p):
            var c = outer.nestedContainer(keyedBy: Value.self, forKey: .socks5)
            try c.encode(s, forKey: ._0); try c.encode(p, forKey: ._1)
        case .ts(let s):
            var c = outer.nestedContainer(keyedBy: Value.self, forKey: .ts)
            try c.encode(s, forKey: ._0)
        }
    }

    var server: Server {
        switch self { case .wg(let s, _, _, _), .ovpn(let s, _), .ss(let s, _), .socks5(let s, _), .ts(let s): s }
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
    /// The tunnel protocols the picker offers for a route, first the default (`key` nil). Empty: no choice.
    var protocols: [ProtocolChoice] { get }
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
    /// The connections the account has open now, every app's, where the provider says (nil: it doesn't, or can't now).
    func inUse(_ account: String) async throws -> Int?
    /// Whether the provider publishes how its servers performed (`quality`).
    var reportsQuality: Bool { get }
    /// What the provider measured of one server over the last week; nil when it can't say. Asks the provider.
    func quality(_ server: String) async -> Quality?
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
    /// Whether a server still suits the page settings `opts` as the provider's latest list says. Only an unpinned route's
    /// kept tunnel is asked.
    func suits(_ server: Server, opts: [String: String]) -> Bool
    /// Whether the account's key has a quantum-safe preshared key; nil = the provider has no quantum-safe exchange.
    func quantumSafe(_ account: String) -> Bool?
    /// The part of `trusts` that needs no account, for a tunnel taken over while the keychain can't be read yet.
    func vouches(_ link: Link) -> Bool
}

nonisolated extension Provider {
    /// Setting up a tunnel contacts the server itself (not the provider's API), so it can't go through another route (Via).
    var viaUnsafe: Bool { id == "pia" }
    /// Offers its own multi-hop (`WgPeer.hopPort`), used for a Via between two of its routes when the user picks it.
    var nativeHop: Bool { id == "ivpn" }
    var hasLoad: Bool { false }
    var proto: String { "WireGuard" }
    var protocols: [ProtocolChoice] { [] }
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
    @concurrent func inUse(_ account: String) async throws -> Int? { nil }
    var reportsQuality: Bool { false }
    @concurrent func quality(_ server: String) async -> Quality? { nil }
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

    var commonOptions: [ProviderOption] { proto == "WireGuard" ? [.mtu, .junk, .limit] : [.limit] }
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
            result.append(.disguise)
        }
        if id == "airvpn" {
            result.append(ProviderOption(key: "port", label: "Port", kind: .choice([.init(value: "auto", label: "Automatic"), .init(value: "1637", label: "UDP 1637"), .init(value: "47107", label: "UDP 47107"), .init(value: "51820", label: "UDP 51820 (Alternative entry)")]), defaultValue: "auto", advanced: true, help: "Automatic tries each in turn when a network blocks one. 51820 always goes to the alternative entry address"))
            result.append(ProviderOption(key: "entry", label: "Entry address", kind: .choice([.init(value: "1", label: "Standard"), .init(value: "2", label: "Alternative")]), defaultValue: "1", advanced: true))
        }
        return result
    }
    func option(_ key: String) -> ProviderOption? { ([protection].compactMap { $0 } + commonOptions + linkOptions).first { $0.key == key } }
    @concurrent func servers(_ loc: Location, _ account: String, limit: Int) async throws -> [Server] { [] }
    @concurrent func signOut(_ account: String) async -> Bool { true }
    func quantumSafe(_ account: String) -> Bool? { nil }
    func trusts(_ link: Link, _ account: String) -> Bool { true }
    func suits(_ server: Server, opts: [String: String]) -> Bool { true }
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
    /// What to know before downloading, shown under the provider's name.
    var note: String? = nil
}

nonisolated enum Providers {
    static let all: [any Provider] = [Nord(), Mullvad(), Pia(), Ivpn(), Proton(), ProtonFree(), Surfshark(), ExpressVpn(), Windscribe(), AirVpn()]
    static func get(_ id: String) -> (any Provider)? { all.first { $0.id == id } }

    /// Name short enough for a route label: "Nord", "PIA", "Proton".
    static func short(_ id: String) -> String {
        ["nord": "Nord", "pia": "PIA", "proton": "Proton", "proton-free": "Proton Free"][id] ?? get(id)?.name ?? id
    }

    static let imports = [
        ImportGuide(id: "purevpn", name: "PureVPN", openVpn: false, where: "Member Area → Manual configuration → WireGuard", url: "https://my.purevpn.com/",
                    note: "Import and connect within about 30 minutes of downloading: PureVPN files that aren't used soon stop working."),
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
