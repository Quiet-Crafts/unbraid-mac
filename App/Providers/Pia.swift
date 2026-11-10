import Foundation
import Security
import Synchronization

/// Private Internet Access over WireGuard, following PIA's official scripts
/// (https://github.com/pia-foss/manual-connections): `get_token.sh`, `get_region.sh` and
/// `connect_to_wireguard_with_token.sh`. Account blob: `Account` (login, last token, WireGuard key pair).
///
/// Unverified: a successful sign-in and a successful `addKey` (no PIA account was available). Verified without an
/// account: the server list shape, the 401 on bad credentials (token endpoint and `addKey`), and the pinned-CA TLS
/// handshake to a WireGuard server by IP with the `cn` as host name.
nonisolated struct Pia: Provider {
    struct Account: Codable, Hashable {
        var username: String
        var password: String
        var token: String
        var tokenTime: Int64
        var privateKey: String
        var publicKey: String
    }

    struct Wg: Decodable, Hashable {
        let ip: String
        let cn: String
    }

    struct Servers: Decodable, Hashable {
        var wg: [Wg] = []
    }

    struct Region: Decodable, Hashable {
        let id: String
        let name: String
        let country: String
        var geo = false
        var portForward = false
        var offline = false
        var servers = Servers()
        enum CodingKeys: String, CodingKey { case id, name, country, geo, portForward = "port_forward", offline, servers }

        /// `name` without the country prefix PIA puts on some regions ("DE Berlin" -> "Berlin").
        var city: String { name.replacing(countryPrefix, with: "") }
    }

    private struct ServerList: Decodable { let regions: [Region] }

    struct AddKey {
        let serverKey: String
        let serverPort: Int
        let peerIp: String
        let dns: [String]
    }

    private struct TokenReply: Decodable { var token: String? }

    private struct AddKeyReply: Decodable {
        var status: String?
        var serverKey: String?
        var serverPort: Int?
        var peerIp: String?
        var dns: [String]?
        enum CodingKeys: String, CodingKey { case status, serverKey = "server_key", serverPort = "server_port", peerIp = "peer_ip", dns = "dns_servers" }
    }

    private struct Token { let value: String, at: Int64 }

    private static let tokenUrl = "https://www.privateinternetaccess.com/api/client/v2/token"
    private static let listUrl = "https://serverlist.piaservers.net/vpninfo/servers/v6"
    private static let tokenRefreshMs: Int64 = 20 * 3_600_000
    private static let tries = 3
    private struct TokenCache {
        var tokens: [String: Token] = [:]
        var generations: [String: UInt64] = [:]
    }
    private static let cache = Mutex(TokenCache())

    let id = "pia"
    let name = "Private Internet Access"
    let fields = [
        Field(key: "username", label: "Username", secret: false, hint: "p1234567"),
        Field(key: "password", label: "Password", hint: "PIA password"),
    ]

    /// Unverified: where PIA shows the login; the scripts only say PIA_USER looks like p0123456.
    let help = "Your PIA login, not your email: a username like p1234567 and its password (PIA website → Account → Client Control Panel)."

    var tokenRequest: @Sendable (String, String) async throws -> String = { try await Pia.fetchToken($0, $1) }

    @concurrent func signIn(_ input: [String: String]) async throws -> String {
        let user = (input["username"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = input["password"] ?? ""
        guard !user.isEmpty, !pass.isEmpty else { throw Fail("Enter your PIA username and password") }
        let keys = WgKeys.generate()
        let generation = Self.cache.withLock { $0.generations[user, default: 0] }
        let token = try await tokenRequest(user, pass)
        let now = Self.nowMs()
        Self.storeToken(user, token, now, generation)
        return JSON.encode(Account(username: user, password: pass, token: token, tokenTime: now, privateKey: keys.privateKey, publicKey: keys.publicKey))
    }

    @concurrent func signOut(_ account: String) async -> Bool {
        // PIA registers nothing with sign-in: only the cached token needs forgetting.
        guard let user = try? Self.account(account).username else { return true }
        Self.cache.withLock {
            $0.tokens.removeValue(forKey: user)
            $0.generations[user, default: 0] &+= 1
        }
        return true
    }

    static func account(_ blob: String) throws -> Account { try JSON.decode(Account.self, Data(blob.utf8), "PIA") }

    @concurrent func countries(_ account: String) async throws -> [Country] { Self.countries(try await catalogue()) }

    @concurrent func connect(_ loc: Location, _ account: String) async throws -> Link {
        let a = try Self.account(account)
        let targets: [(Wg, Server)]
        if let p = loc.pinned {
            let wg = try Self.target(try await Catalog.unlessOutage { try await catalogue() }, p)
            var sv = p
            sv.ip = wg.ip
            targets = [(wg, sv)]
        } else {
            let r = try Self.pick(try await catalogue(), loc)
            targets = Self.targets(r.servers.wg).map { ($0, Server(name: r.name, host: $0.cn, ip: $0.ip, publicKey: "", load: 0, city: r.city)) }
        }
        var failure: Error?
        for (sv, base) in targets {
            do {
                let k = try await register(sv, a)
                var server = base
                server.publicKey = k.serverKey
                return .wg(server, Self.peer(server, k, a.privateKey))
            } catch let e as AuthError { throw e } catch { failure = error }
        }
        throw failure ?? Fail("PIA has no WireGuard server for this location")
    }

    @concurrent func servers(_ loc: Location, _ account: String, limit: Int) async throws -> [Server] {
        let list = try await catalogue()
        let rs = loc.region.map { id in list.filter { $0.id == id } }
            ?? loc.countryCode.map { c in list.filter { $0.country.caseInsensitiveCompare(c) == .orderedSame } } ?? list
        return Array(Self.geoLast(rs).lazy.flatMap { r in r.servers.wg.map { Server(name: $0.cn, host: $0.cn, ip: $0.ip, publicKey: "", load: 0, city: r.city) } }.prefix(limit))
    }

    private static func peer(_ sv: Server, _ k: AddKey, _ privateKey: String) -> WgPeer {
        WgPeer(name: sv.name, privateKey: privateKey, address: ["\(k.peerIp)/32"], publicKey: k.serverKey,
               endpoint: "\(sv.ip):\(k.serverPort)", allowedIps: ["0.0.0.0/0"], dns: k.dns)
    }

    /// The region list; tests replace it.
    var catalogue: @Sendable () async throws -> [Region] = { try Pia.parseRegions(try await Http.get(Pia.listUrl)) }

    /// Where a pinned server is now: its saved address while the list still has it under that name, else the list's
    /// current one; nil list (unreadable) = the saved one. A list without that name no longer has the server.
    static func target(_ regions: [Region]?, _ p: Server) throws -> Wg {
        var wg = Wg(ip: p.ip, cn: p.host)
        if let regions, !regions.isEmpty {
            let listed = regions.flatMap(\.servers.wg).filter { $0.cn == p.host && Catalog.Entry.publicIPv4($0.ip) }
            guard let first = listed.first else { throw Catalog.Gone(provider: "PIA", server: p.name) }
            if !listed.contains(where: { $0.ip == p.ip }) { wg = first }
        }
        guard Catalog.Entry.publicIPv4(wg.ip) else { throw Fail("\(p.name) can't be reached right now") }
        return wg
    }

    /// Regions with the ones PIA marks as geo-located (servers in a different country than advertised) last.
    private static func geoLast(_ rs: [Region]) -> [Region] { rs.filter { !$0.geo } + rs.filter(\.geo) }

    private static func pick(_ list: [Region], _ loc: Location) throws -> Region {
        if let id = loc.region {
            guard let r = list.first(where: { $0.id == id }) else { throw Fail("PIA region \(id) is no longer available") }
            return r
        }
        let pool = loc.countryCode.map { c in list.filter { $0.country.caseInsensitiveCompare(c) == .orderedSame } } ?? list
        guard let r = pool.first(where: { !$0.geo }) ?? pool.first else { throw Fail("PIA has no WireGuard server for \(loc.label)") }
        return r
    }

    /// The server list is one line of JSON, then a blank line and a signature (not checked here, as in PIA's scripts).
    /// A region whose country isn't a two-letter code is dropped: the code becomes the country's id, and a long one
    /// would overflow it.
    static func parseRegions(_ body: Data) throws -> [Region] {
        try JSON.decode(ServerList.self, Data(body.prefix { $0 != 10 }), "PIA").regions.filter {
            !$0.offline && !$0.servers.wg.isEmpty && $0.country.wholeMatch(of: /[A-Za-z]{2}/) != nil
        }
    }

    static func countries(_ regions: [Region]) -> [Country] {
        Dictionary(grouping: regions) { $0.country.uppercased() }.map { code, rs in
            Country(id: code.unicodeScalars.reduce(0) { $0 * 256 + Int($1.value) },
                    name: Locale(identifier: "en").localizedString(forRegionCode: code).flatMap { $0.isEmpty ? nil : $0 } ?? code,
                    code: code, serverCount: rs.reduce(0) { $0 + $1.servers.wg.count },
                    cities: rs.sorted { ($0.city, $0.id) < ($1.city, $1.id) }.map { City(id: stableId($0.id), name: $0.city, key: $0.id) })
        }.sorted { ($0.name, $0.code) < ($1.name, $1.code) }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static func fetchToken(_ user: String, _ pass: String) async throws -> String {
        let body: Data
        do { body = try await Http.postForm(tokenUrl, ["username": user, "password": pass], credentials: true) } catch is AuthError {
            throw AuthError("PIA refused that username or password")
        }
        guard let token = try JSON.decode(TokenReply.self, body, "PIA").token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Accepted (2xx) but no token: not a refused password, which would have the user sign in again.
            throw Fail("Unexpected reply from PIA")
        }
        return token
    }

    private static func storeToken(_ user: String, _ value: String, _ at: Int64, _ generation: UInt64) {
        cache.withLock {
            if $0.generations[user, default: 0] == generation { $0.tokens[user] = Token(value: value, at: at) }
        }
    }

    /// A token younger than ~20 h (the blob's or the newest refreshed one), else a new one. PIA tokens last 24 h.
    static func token(_ a: Account, force: Bool = false, fetch: @Sendable (String, String) async throws -> String = fetchToken) async throws -> String {
        var known = Token(value: a.token, at: a.tokenTime)
        let (cached, generation) = cache.withLock { ($0.tokens[a.username], $0.generations[a.username, default: 0]) }
        if let t = cached, t.at > known.at { known = t }
        if !force && nowMs() - known.at < tokenRefreshMs { return known.value }
        let fresh = try await fetch(a.username, a.password)
        storeToken(a.username, fresh, nowMs(), generation)
        return fresh
    }

    private func register(_ sv: Wg, _ a: Account) async throws -> AddKey {
        do { return try await Self.addKey(sv, try await Self.token(a), a.publicKey) } catch is AuthError {
            return try await Self.addKey(sv, try await Self.token(a, force: true), a.publicKey)
        }
    }

    /// `curl --connect-to cn::ip: --cacert ca.rsa.4096.crt https://cn:1337/addKey?pt=..&pubkey=..`
    static func targets(_ servers: [Wg]) -> [Wg] {
        Array(servers.lazy.filter { valid($0) }.prefix(tries))
    }

    private static func valid(_ sv: Wg) -> Bool {
        sv.cn.wholeMatch(of: /[A-Za-z0-9._-]+/) != nil && Catalog.Entry.publicIPv4(sv.ip)
    }

    private static func addKey(_ sv: Wg, _ token: String, _ pubKey: String) async throws -> AddKey {
        guard valid(sv) else { throw Fail("Unexpected PIA server \(sv.cn)") }
        let pin = Http.Pin(ca: try caCertificate(), host: sv.cn)
        return try parseAddKey(try await Http.get("https://\(sv.ip):1337/addKey?pt=\(Http.enc(token))&pubkey=\(Http.enc(pubKey))", pin: pin, credentials: true))
    }

    static func parseAddKey(_ body: Data) throws -> AddKey {
        let r = try JSON.decode(AddKeyReply.self, body, "PIA")
        guard r.status == "OK" else { throw Fail("PIA refused the key") }
        guard let key = r.serverKey, validWgKey(key) else { throw Fail("PIA's reply has no server_key") }
        guard let port = r.serverPort, (1...65535).contains(port) else { throw Fail("PIA's reply has no server_port") }
        guard let ip = r.peerIp, Catalog.Entry.octets(ip) != nil else { throw Fail("PIA's reply has no peer_ip") }
        return AddKey(serverKey: key, serverPort: port, peerIp: ip, dns: (r.dns ?? []).filter { Catalog.Entry.octets($0) != nil })
    }

    /// PIA's own CA, the only root trusted for its WireGuard API, as the scripts do with `--cacert`.
    static func caCertificate() throws -> SecCertificate {
        let der = Data(base64Encoded: caPem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined())
        guard let der, let cert = SecCertificateCreateWithData(nil, der as CFData) else { throw Fail("PIA CA certificate is missing from the app") }
        return cert
    }

    private static let caPem = """
    -----BEGIN CERTIFICATE-----
    MIIHqzCCBZOgAwIBAgIJAJ0u+vODZJntMA0GCSqGSIb3DQEBDQUAMIHoMQswCQYD
    VQQGEwJVUzELMAkGA1UECBMCQ0ExEzARBgNVBAcTCkxvc0FuZ2VsZXMxIDAeBgNV
    BAoTF1ByaXZhdGUgSW50ZXJuZXQgQWNjZXNzMSAwHgYDVQQLExdQcml2YXRlIElu
    dGVybmV0IEFjY2VzczEgMB4GA1UEAxMXUHJpdmF0ZSBJbnRlcm5ldCBBY2Nlc3Mx
    IDAeBgNVBCkTF1ByaXZhdGUgSW50ZXJuZXQgQWNjZXNzMS8wLQYJKoZIhvcNAQkB
    FiBzZWN1cmVAcHJpdmF0ZWludGVybmV0YWNjZXNzLmNvbTAeFw0xNDA0MTcxNzQw
    MzNaFw0zNDA0MTIxNzQwMzNaMIHoMQswCQYDVQQGEwJVUzELMAkGA1UECBMCQ0Ex
    EzARBgNVBAcTCkxvc0FuZ2VsZXMxIDAeBgNVBAoTF1ByaXZhdGUgSW50ZXJuZXQg
    QWNjZXNzMSAwHgYDVQQLExdQcml2YXRlIEludGVybmV0IEFjY2VzczEgMB4GA1UE
    AxMXUHJpdmF0ZSBJbnRlcm5ldCBBY2Nlc3MxIDAeBgNVBCkTF1ByaXZhdGUgSW50
    ZXJuZXQgQWNjZXNzMS8wLQYJKoZIhvcNAQkBFiBzZWN1cmVAcHJpdmF0ZWludGVy
    bmV0YWNjZXNzLmNvbTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALVk
    hjumaqBbL8aSgj6xbX1QPTfTd1qHsAZd2B97m8Vw31c/2yQgZNf5qZY0+jOIHULN
    De4R9TIvyBEbvnAg/OkPw8n/+ScgYOeH876VUXzjLDBnDb8DLr/+w9oVsuDeFJ9K
    V2UFM1OYX0SnkHnrYAN2QLF98ESK4NCSU01h5zkcgmQ+qKSfA9Ny0/UpsKPBFqsQ
    25NvjDWFhCpeqCHKUJ4Be27CDbSl7lAkBuHMPHJs8f8xPgAbHRXZOxVCpayZ2SND
    fCwsnGWpWFoMGvdMbygngCn6jA/W1VSFOlRlfLuuGe7QFfDwA0jaLCxuWt/BgZyl
    p7tAzYKR8lnWmtUCPm4+BtjyVDYtDCiGBD9Z4P13RFWvJHw5aapx/5W/CuvVyI7p
    Kwvc2IT+KPxCUhH1XI8ca5RN3C9NoPJJf6qpg4g0rJH3aaWkoMRrYvQ+5PXXYUzj
    tRHImghRGd/ydERYoAZXuGSbPkm9Y/p2X8unLcW+F0xpJD98+ZI+tzSsI99Zs5wi
    jSUGYr9/j18KHFTMQ8n+1jauc5bCCegN27dPeKXNSZ5riXFL2XX6BkY68y58UaNz
    meGMiUL9BOV1iV+PMb7B7PYs7oFLjAhh0EdyvfHkrh/ZV9BEhtFa7yXp8XR0J6vz
    1YV9R6DYJmLjOEbhU8N0gc3tZm4Qz39lIIG6w3FDAgMBAAGjggFUMIIBUDAdBgNV
    HQ4EFgQUrsRtyWJftjpdRM0+925Y6Cl08SUwggEfBgNVHSMEggEWMIIBEoAUrsRt
    yWJftjpdRM0+925Y6Cl08SWhge6kgeswgegxCzAJBgNVBAYTAlVTMQswCQYDVQQI
    EwJDQTETMBEGA1UEBxMKTG9zQW5nZWxlczEgMB4GA1UEChMXUHJpdmF0ZSBJbnRl
    cm5ldCBBY2Nlc3MxIDAeBgNVBAsTF1ByaXZhdGUgSW50ZXJuZXQgQWNjZXNzMSAw
    HgYDVQQDExdQcml2YXRlIEludGVybmV0IEFjY2VzczEgMB4GA1UEKRMXUHJpdmF0
    ZSBJbnRlcm5ldCBBY2Nlc3MxLzAtBgkqhkiG9w0BCQEWIHNlY3VyZUBwcml2YXRl
    aW50ZXJuZXRhY2Nlc3MuY29tggkAnS7684Nkme0wDAYDVR0TBAUwAwEB/zANBgkq
    hkiG9w0BAQ0FAAOCAgEAJsfhsPk3r8kLXLxY+v+vHzbr4ufNtqnL9/1Uuf8NrsCt
    pXAoyZ0YqfbkWx3NHTZ7OE9ZRhdMP/RqHQE1p4N4Sa1nZKhTKasV6KhHDqSCt/dv
    Em89xWm2MVA7nyzQxVlHa9AkcBaemcXEiyT19XdpiXOP4Vhs+J1R5m8zQOxZlV1G
    tF9vsXmJqWZpOVPmZ8f35BCsYPvv4yMewnrtAC8PFEK/bOPeYcKN50bol22QYaZu
    LfpkHfNiFTnfMh8sl/ablPyNY7DUNiP5DRcMdIwmfGQxR5WEQoHL3yPJ42LkB5zs
    6jIm26DGNXfwura/mi105+ENH1CaROtRYwkiHb08U6qLXXJz80mWJkT90nr8Asj3
    5xN2cUppg74nG3YVav/38P48T56hG1NHbYF5uOCske19F6wi9maUoto/3vEr0rnX
    JUp2KODmKdvBI7co245lHBABWikk8VfejQSlCtDBXn644ZMtAdoxKNfR2WTFVEwJ
    iyd1Fzx0yujuiXDROLhISLQDRjVVAvawrAtLZWYK31bY7KlezPlQnl/D9Asxe85l
    8jO5+0LdJ6VyOs/Hd4w52alDW/MFySDZSfQHMTIc30hLBJ8OnCEIvluVQQ2UQvoW
    +no177N9L2Y+M9TcTA62ZyMXShHQGeh20rb4kK8f+iFX8NxtdHVSkxMEFSfDDyQ=
    -----END CERTIFICATE-----
    """
}

/// "US Denver" → "Denver": compiled once, it runs inside sort comparators.
nonisolated(unsafe) private let countryPrefix = /^[A-Z]{2} (?=.)/

nonisolated extension Pia.Servers {
    init(from d: Decoder) throws { wg = try d.container(keyedBy: CodingKeys.self)(.wg, []) }
    enum CodingKeys: String, CodingKey { case wg }
}

nonisolated extension Pia.Region {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name), country: try c.decode(String.self, forKey: .country),
                  geo: c(.geo, false), portForward: c(.portForward, false), offline: c(.offline, false), servers: c(.servers, Pia.Servers()))
    }
}
