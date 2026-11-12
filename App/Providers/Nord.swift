import Foundation

/// NordVPN: NordLynx (WireGuard), or OpenVPN UDP/TCP, required for Double VPN and Onion over VPN.
nonisolated struct Nord: Provider {
    struct Account: Codable, Sendable {
        var token: String
        var key: String
        var user = ""
        var pass = ""

        init(token: String, key: String, user: String = "", pass: String = "") { (self.token, self.key, self.user, self.pass) = (token, key, user, pass) }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            self.init(token: try c.decode(String.self, forKey: .token), key: try c.decode(String.self, forKey: .key), user: c(.user, ""), pass: c(.pass, ""))
        }
    }

    /// Groups only served over OpenVPN.
    static let openVpnOnly: Set = ["legacy_double_vpn", "legacy_onion_over_vpn"]
    static let dedicatedIp = "legacy_dedicated_ip"

    let id = "nord"
    let name = "NordVPN"
    let fields = [Field(key: "token", label: "Access token", hint: "Paste token")]
    let help = "Nord Account → NordVPN → Manual setup → Generate new token."
    /// Every NordVPN server carries its load, and the recommendations come lowest load first.
    let hasLoad = true
    let oneKey = true

    @concurrent func signIn(_ input: [String: String]) async throws -> String {
        let t = (input["token"] ?? "").filter { !$0.isWhitespace }
        guard t.wholeMatch(of: /[A-Za-z0-9]{32,128}/) != nil else { throw Fail("That doesn't look like a NordVPN token") }
        let c = try await NordApi.credentials(t)
        return JSON.encode(Account(token: t, key: c.key, user: c.user, pass: c.pass))
    }

    static func account(_ blob: String) throws -> Account { try JSON.decode(Account.self, Data(blob.utf8), "the account store") }

    @concurrent func countries(_ account: String) async throws -> [Country] { try await NordApi.countries().sorted { $0.name < $1.name } }

    static func tech(_ loc: Location) -> String {
        if let g = loc.group, openVpnOnly.contains(g) { return loc.proto.flatMap { $0.hasPrefix("openvpn") ? $0 : nil } ?? "openvpn_udp" }
        return loc.proto ?? "wireguard_udp"
    }

    @concurrent func connect(_ loc: Location, _ account: String) async throws -> Link {
        let a = try Self.account(account)
        let tech = Self.tech(loc)
        let sv: Server
        if let p = loc.pinned { sv = try Self.current(try await Catalog.unlessOutage { try await lookup(p.name, tech) }, p) } else if loc.group == Self.dedicatedIp {
            guard let s = try await dedicated(a, loc, tech).first else { throw Fail("Your Dedicated IP isn't in \(loc.label)") }
            sv = s
        } else {
            // One of the three least loaded, not always the first: Nord gives an account one WireGuard key for every
            // device, and two devices with one key on one server knock each other off. Every device at the same
            // place (and Nord's own apps) is told the same first choice.
            guard let s = try await NordApi.recommend(loc, tech: tech).randomElement() else { throw Fail("No NordVPN server for \(loc.label)") }
            sv = s
        }
        guard Catalog.Entry.publicIPv4(sv.ip) else { throw Fail("\(sv.name) can't be reached right now") }
        if tech == "wireguard_udp" { return .wg(sv, Self.peer(sv, a.key)) }
        // OpenVPN: Nord publishes one profile per server; the login is the account's service credentials.
        var (user, pass) = (a.user, a.pass)
        if user.isEmpty { let c = try await NordApi.credentials(a.token); (user, pass) = (c.user, c.pass) }
        let proto = String(tech.dropFirst("openvpn_".count))
        guard sv.host.wholeMatch(of: /[a-z0-9-]+\.nordvpn\.com/) != nil else { throw Fail("Unexpected server name") }
        let data = try await Http.get("https://downloads.nordcdn.com/configs/files/ovpn_\(proto)/servers/\(sv.host).\(proto).ovpn")
        return .ovpn(sv, try Self.profile(String(decoding: data, as: UTF8.self), sv, user: user, pass: pass))
    }

    /// The downloaded profile, parsed. The tunnel dials whatever `remote` lines it holds, so each must be a public
    /// address, as every other path requires of its endpoint; a host name, private or loopback address is refused.
    static func profile(_ text: String, _ sv: Server, user: String, pass: String) throws -> OvpnProfile {
        let hosts = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return words.first == "remote" ? (words.count > 1 ? String(words[1]) : "") : nil
        }
        guard !hosts.isEmpty, hosts.allSatisfy(Catalog.Entry.publicIPv4) else { throw Fail("\(sv.name) can't be reached right now") }
        return try Manual.parseOvpn(withLegacyCiphers(text), name: sv.name, username: user, password: pass)
    }

    /// Servers by Nord's name for them; tests replace it.
    var lookup: @Sendable (_ name: String, _ tech: String) async throws -> [Server] = { try await NordApi.named($0, tech: $1) }

    /// A pinned server as Nord lists it now (address and key), matched by host name among the servers with its name;
    /// nil (the API can't be reached) = the saved values. Gone only on evidence: no server by that name at all, or the
    /// name now on another host (renamed by Nord: pick it again). An answer of other servers only means Nord ignored the
    /// name filter (it silently ignores filters it doesn't know): no evidence, so the saved values.
    static func current(_ found: [Server]?, _ p: Server) throws -> Server {
        guard let found else { return p }
        if let s = found.first(where: { $0.host.caseInsensitiveCompare(p.host) == .orderedSame }) { return s }
        if found.isEmpty || found.contains(where: { $0.name.caseInsensitiveCompare(p.name) == .orderedSame }) {
            throw Catalog.Gone(provider: "NordVPN", server: p.name)
        }
        return p
    }

    /// Country codes that have servers in a specialty `group` (P2P, Double VPN, Onion…).
    @concurrent static func groupCountries(_ group: String) async throws -> Set<String> {
        try await NordApi.groupCountries(group, openVpnOnly.contains(group) ? "openvpn_udp" : "wireguard_udp")
    }

    /// The servers of the account's own Dedicated IP, narrowed to `loc`'s country; an account without one is told so.
    private func dedicated(_ a: Account, _ loc: Location, _ tech: String) async throws -> [Server] {
        let mine = try await NordApi.dedicated(a.token, tech)
        if mine.isEmpty { throw Fail("This NordVPN account has no Dedicated IP. Add one in your Nord Account, or pick another server group.") }
        guard let cc = loc.countryCode else { return mine }
        return mine.filter { $0.country.caseInsensitiveCompare(cc) == .orderedSame }
    }

    @concurrent func servers(_ loc: Location, _ account: String, limit: Int) async throws -> [Server] {
        if loc.group == Self.dedicatedIp { return Array(try await dedicated(try Self.account(account), loc, Self.tech(loc)).prefix(limit)) }
        var l = loc
        l.pinned = nil
        return try await NordApi.recommend(l, limit: limit, tech: Self.tech(loc))
    }

    /// Nord's profiles rely on `cipher AES-256-CBC`, which OpenVPN 2.6 (and our engine) ignore for negotiation; Nord's
    /// servers still need CBC offered, so the 2.6-style equivalent is spelled out (verified live: without it the
    /// tunnel never comes up).
    private static let legacyCiphers = "\ndata-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-256-CBC\ndata-ciphers-fallback AES-256-CBC\n"

    static func withLegacyCiphers(_ profile: String) -> String { profile + legacyCiphers }

    static func peer(_ sv: Server, _ key: String) -> WgPeer {
        WgPeer(name: sv.name, privateKey: key, address: ["10.5.0.2/32"], publicKey: sv.publicKey, endpoint: "\(sv.ip):51820", allowedIps: ["0.0.0.0/0"])
    }
}
