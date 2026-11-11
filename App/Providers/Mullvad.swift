import CryptoKit
import Foundation

/// Curve25519 key pairs in WireGuard's base64 form, for providers that register our own public key.
nonisolated enum WgKeys {
    struct Keys: Equatable {
        let privateKey: String
        let publicKey: String
    }

    static func generate() -> Keys {
        var raw = [UInt8](Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        raw[0] &= 248
        raw[31] = (raw[31] & 127) | 64
        let key = (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)) ?? Curve25519.KeyAgreement.PrivateKey()
        return Keys(privateKey: key.rawRepresentation.base64EncodedString(), publicKey: key.publicKey.rawRepresentation.base64EncodedString())
    }
}

/// Not private: a test checks that it keeps refusing redirects.
nonisolated let rawSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 15
    // A server that trickles bytes can't hold a sign-in open for ever.
    c.timeoutIntervalForResource = 60
    c.httpCookieStorage = nil
    c.urlCache = nil
    return URLSession(configuration: c, delegate: Http.NoRedirect(), delegateQueue: nil)
}()

/// POSTs JSON and returns status + body without throwing on 4xx: Mullvad and IVPN report why a sign-in failed in the
/// error body, which [Http] discards. A URLError therefore means no HTTP status was seen.
@concurrent nonisolated func postJSONRaw(_ url: String, _ body: String, headers: [String: String] = [:]) async throws -> (Int, Data) {
    #if DEBUG
    try PerfFake.offline()
    #endif
    guard let u = URL(string: url), u.scheme == "https" else { throw Fail("HTTPS only") }
    var r = URLRequest(url: u)
    r.httpMethod = "POST"
    r.setValue("application/json", forHTTPHeaderField: "Accept")
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
    r.httpBody = Data(body.utf8)
    let (bytes, response) = try await rawSession.bytes(for: r)
    // Stop at 1 MiB while reading, as Http does, rather than reading everything and cutting it afterwards.
    var data = Data()
    for try await b in bytes {
        data.append(b)
        if data.count > 1 << 20 { throw Fail("Response too large") }
    }
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
}

/// Mullvad over WireGuard. Account blob: account number, WireGuard private key, assigned tunnel address and device id.
///
/// Sign-in follows mullvad-api (github.com/mullvad/mullvadvpn-app): `POST auth/v1/token {account_number}` gives an
/// `access_token`; `POST accounts/v1/devices {pubkey, hijack_dns}` with `Authorization: Bearer` returns 201 with the
/// device `id` and `ipv4_address`. One device (one of the account's 5) serves every relay.
/// Server list: `GET /public/relays/wireguard/v2`; port 51820 and DNS 10.64.0.1 as in Mullvad's own mullvad-wg.sh.
/// Sign-out frees the slot: `DELETE accounts/v1/devices/{id}` (204) with a fresh token. A device reply lost in transit
/// would orphan a slot, so any failure on the POST but a refusal is reconciled by listing `GET accounts/v1/devices` and adopting
/// the entry with our public key.
/// Unverified: the HTTP status codes that go with INVALID_ACCOUNT / MAX_DEVICES_REACHED are matched on the body only
/// (INVALID_ACCOUNT arrives as 400, observed); no real account was available, so token and device calls were not run.
nonisolated struct Mullvad: Provider {
    let deviceURL: String? = "https://mullvad.net/account/devices"
    struct Account: Codable, Hashable {
        var account: String
        var privateKey: String
        var ipv4Address: String
        var deviceId: String
        var deviceName: String? = nil
    }

    private struct TokenReply: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    struct DeviceReply: Decodable {
        let id: String
        var pubkey: String?
        var name: String?
        let ipv4Address: String
        enum CodingKeys: String, CodingKey { case id, pubkey, name, ipv4Address = "ipv4_address" }
    }

    struct Loc: Decodable, Hashable {
        let country: String
        let city: String
    }

    struct Relay: Decodable, Hashable {
        let hostname: String
        let location: String
        var active = true
        let ip: String
        let publicKey: String
        var inCountry = true
        var weight = 0
        var owned = false
        enum CodingKeys: String, CodingKey { case hostname, location, active, ip = "ipv4_addr_in", publicKey = "public_key", inCountry = "include_in_country", weight, owned }
    }

    struct Wireguard: Decodable {
        var relays: [Relay] = []
    }

    struct RelayList: Decodable {
        var locations: [String: Loc] = [:]
        var wireguard = Wireguard()
        /// Active relays whose location is known, at a public address.
        var listed: [Relay] { wireguard.relays.filter { $0.active && locations[$0.location] != nil && Catalog.Entry.publicIPv4($0.ip) } }
        /// Those with a WireGuard key: the ones picked.
        var usable: [Relay] { listed.filter { validWgKey($0.publicKey) } }
    }

    private static let api = "https://api.mullvad.net"
    private static let dns = "10.64.0.1"
    private static let port = 51820

    let id = "mullvad"
    let name = "Mullvad"
    let fields = [Field(key: "account", label: "Account number", hint: "16 digits")]
    let help = "Your 16-digit account number: shown when you created the account, and at mullvad.net/account after logging in. Each account has 5 device slots; unbraid uses one."

    @concurrent func signIn(_ input: [String: String]) async throws -> String {
        let n = (input["account"] ?? "").filter { !$0.isWhitespace && $0 != "-" }
        guard n.wholeMatch(of: /[0-9]{16}/) != nil else { throw Fail("A Mullvad account number has 16 digits") }
        let token = try await accessToken(n)
        let keys = WgKeys.generate()
        do {
            let reply = try await postJSONRaw("\(Self.api)/accounts/v1/devices", #"{"pubkey":"\#(keys.publicKey)","hijack_dns":false}"#, headers: bearer(token))
            return try Self.device(reply, n, keys.privateKey)
        } catch let e as AuthError {
            throw e
        } catch {
            // Lost in transit, too large, or not as expected: Mullvad may have registered the device all the same.
            guard let blob = await adopted(token, n, keys) else { throw error }
            return blob
        }
    }

    @concurrent func signOut(_ account: String) async -> Bool {
        do {
            let a = try Self.account(account)
            _ = try await Http.delete("\(Self.api)/accounts/v1/devices/\(Http.enc(a.deviceId))", headers: bearer(try await accessToken(a.account)), credentials: true)
            return true
        } catch { return Self.released(despite: error) }
    }

    /// No such device (404): it was already removed, on mullvad.net or by another sign-out, so the slot is free.
    static func released(despite error: Error) -> Bool { (error as? Http.Status)?.code == 404 }

    private func bearer(_ token: String) -> [String: String] { ["Authorization": "Bearer \(token)"] }

    private func accessToken(_ account: String) async throws -> String {
        try Self.token(try await postJSONRaw("\(Self.api)/auth/v1/token", #"{"account_number":"\#(account)"}"#))
    }

    /// The device Mullvad registered for `keys` although its reply never arrived, if the account lists one.
    private func adopted(_ token: String, _ account: String, _ keys: WgKeys.Keys) async -> String? {
        guard let list = try? await Http.get("\(Self.api)/accounts/v1/devices", headers: bearer(token), credentials: true) else { return nil }
        return (try? Self.adopt(list, account, keys)) ?? nil
    }

    static func adopt(_ list: Data, _ account: String, _ keys: WgKeys.Keys) throws -> String? {
        try JSON.decode([DeviceReply].self, list, "Mullvad").first { $0.pubkey == keys.publicKey }.map { blob(account, keys.privateKey, $0) }
    }

    static func token(_ reply: (Int, Data)) throws -> String {
        let (code, body) = reply
        if code == 400 && String(decoding: body, as: UTF8.self).contains("INVALID_ACCOUNT") || code == 401 {
            throw AuthError("Mullvad doesn't recognise that account number")
        }
        // Only a 429 is passed on as a status: a 404 here is the token endpoint's, not "this device is gone" (`revoked`).
        if code == 429 { throw Http.Status(code: code) }
        guard (200..<300).contains(code) else { throw Fail("Mullvad answered with an error (HTTP \(code)). Try again later.") }
        return try JSON.decode(TokenReply.self, body, "Mullvad").accessToken
    }

    static func device(_ reply: (Int, Data), _ account: String, _ privateKey: String) throws -> String {
        let (code, body) = reply
        if String(decoding: body, as: UTF8.self).contains("MAX_DEVICES_REACHED") {
            throw AuthError(Limits.full("Mullvad", 5, "device"), url: "https://mullvad.net/account/devices")
        }
        if code == 401 || code == 403 { throw AuthError("Mullvad refused the device registration") }
        guard code == 201 else { throw Http.Status(code: code) }
        return blob(account, privateKey, try JSON.decode(DeviceReply.self, body, "Mullvad"))
    }

    private static func blob(_ account: String, _ privateKey: String, _ d: DeviceReply) -> String {
        JSON.encode(Account(account: account, privateKey: privateKey, ipv4Address: d.ipv4Address, deviceId: d.id, deviceName: d.name))
    }

    static func account(_ blob: String) throws -> Account { try JSON.decode(Account.self, Data(blob.utf8), "Mullvad") }


    @concurrent func device(_ account: String) async throws -> String? {
        let a = try Self.account(account)
        let list = try? await devices(a)
        let name = list?.first(where: { $0.id == a.deviceId })?.name ?? a.deviceName ?? ""
        let display = name.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        return "Its own device\(display.isEmpty ? "" : ", \(display)"), removed when you sign out"
    }

    @concurrent func deviceCount(_ account: String) async throws -> Int? { try await devices(Self.account(account)).count }

    private func devices(_ account: Account) async throws -> [DeviceReply] {
        let token = try await accessToken(account.account)
        return try JSON.decode([DeviceReply].self, try await Http.get("\(Self.api)/accounts/v1/devices", headers: bearer(token), credentials: true), "Mullvad")
    }

    @concurrent func revoked(_ account: String) async throws -> Bool {
        do {
            let a = try Self.account(account)
            _ = try await Http.get("\(Self.api)/accounts/v1/devices/\(Http.enc(a.deviceId))", headers: bearer(try await accessToken(a.account)), credentials: true)
            return false
        } catch is CancellationError { throw CancellationError() }
        catch { return Self.revoked(despite: error) }
    }

    static func revoked(despite error: Error) -> Bool {
        if error is AuthError { return true }
        return (error as? Http.Status)?.code == 404
    }

    static func expiry(_ data: Data, now: Date = Date()) throws -> String? {
        struct Reply: Decodable { var expiry: String? }
        guard let value = try JSON.decode(Reply.self, data, "Mullvad").expiry else { return nil }
        let parser = ISO8601DateFormatter()
        let date = parser.date(from: value) ?? {
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return parser.date(from: value)
        }()
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d MMM yyyy"
        return "\(date > now ? "Paid until" : "Ended on") \(formatter.string(from: date))"
    }

    @concurrent func plan(_ account: String) async throws -> String? {
        let a = try Self.account(account)
        return try Self.expiry(await Http.get("\(Self.api)/accounts/v1/accounts/me", headers: bearer(try await accessToken(a.account)), credentials: true))
    }

    @concurrent func countries(_ account: String) async throws -> [Country] { Self.countries(try await fetch()) }

    /// A pinned server is looked up in the fresh list so a changed IP or key is picked up; if the list is unreachable the pinned values are used.
    @concurrent func connect(_ loc: Location, _ account: String) async throws -> Link {
        let list: RelayList?
        if loc.pinned == nil { list = try await fetch() } else { list = try? await fetch() }
        return try Self.link(list, loc, try Self.account(account))
    }

    @concurrent func servers(_ loc: Location, _ account: String, limit: Int) async throws -> [Server] {
        let l = try await fetch()
        return l.match(loc).sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.hostname < $1.hostname }.prefix(limit).map { Self.server($0, l) }
    }

    @concurrent func freshCountries(_ account: String, opts: [String: String]) async throws -> (countries: [Country], live: Bool, published: Int64?, failed: Bool) {
        (Self.countries(try await fetch(), ownedOnly: opts["owned"] == "on"), true, nil, false)
    }

    @concurrent func connect(_ loc: Location, _ account: String, opts: [String: String]) async throws -> Link {
        let list: RelayList? = loc.pinned == nil ? try await fetch() : try? await fetch()
        return try Self.link(list, loc, try Self.account(account), ownedOnly: opts["owned"] == "on")
    }

    @concurrent func servers(_ loc: Location, _ account: String, limit: Int, opts: [String: String]) async throws -> [Server] {
        let l = try await fetch()
        return l.match(loc, ownedOnly: opts["owned"] == "on").sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.hostname < $1.hostname }.prefix(limit).map { Self.server($0, l) }
    }

    var catalogue: @Sendable () async throws -> RelayList = { try Self.parse(try await Http.get("\(Self.api)/public/relays/wireguard/v2")) }
    private func fetch() async throws -> RelayList { try await catalogue() }

    static func parse(_ body: Data) throws -> RelayList { try JSON.decode(RelayList.self, body, "Mullvad") }

    static func countries(_ l: RelayList, ownedOnly: Bool = false) -> [Country] {
        let groups = Dictionary(grouping: l.usable.filter { !ownedOnly || $0.owned }) { String($0.location.prefix { $0 != "-" }) }
            .sorted { (l.locations[$0.value[0].location]!.country, $0.key) < (l.locations[$1.value[0].location]!.country, $1.key) }
        return groups.map { cc, rs in
            var seen = Set<String>()
            let cities = rs.map(\.location).filter { seen.insert($0).inserted }.map { ($0, l.locations[$0]!.city) }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            return Country(id: stableId(cc), name: l.locations[rs[0].location]!.country, code: cc.uppercased(), serverCount: rs.count,
                           cities: cities.map { City(id: stableId($0), name: $1, key: $0) })
        }
    }

    static func link(_ l: RelayList?, _ loc: Location, _ a: Account, ownedOnly: Bool = false) throws -> Link {
        var rng = SystemRandomNumberGenerator()
        return try link(l, loc, a, using: &rng, ownedOnly: ownedOnly)
    }

    static func link<G: RandomNumberGenerator>(_ l: RelayList?, _ loc: Location, _ a: Account, using rng: inout G, ownedOnly: Bool = false) throws -> Link {
        let sv: Server
        if let p = loc.pinned {
            sv = try l.map { try current($0, p) } ?? p
        } else {
            guard let l, case let rs = l.match(loc, ownedOnly: ownedOnly), !rs.isEmpty else { throw Fail("No active Mullvad server for \(loc.label)") }
            sv = server(pick(rs, &rng), l)
        }
        // Whichever path: a public address, never a pin or list entry that would dial a LAN or nothing.
        guard Catalog.Entry.publicIPv4(sv.ip) else { throw Fail("\(sv.name) can't be reached right now") }
        return .wg(sv, WgPeer(name: sv.name, privateKey: a.privateKey, address: [String(a.ipv4Address.prefix { $0 != "/" }) + "/32"], publicKey: sv.publicKey,
                              endpoint: "\(sv.ip):\(port)", allowedIps: ["0.0.0.0/0"], dns: [dns]), ports: [51820, 53, 123, 4500])
    }

    /// `p` as the fresh list has it, found by host name, else by IP. An empty list proves nothing: the pin stands.
    private static func current(_ l: RelayList, _ p: Server) throws -> Server {
        if l.listed.isEmpty { return p }
        guard let r = l.listed.first(where: { $0.hostname == p.host }) ?? l.listed.first(where: { $0.ip == p.ip }) else {
            throw Catalog.Gone(provider: "Mullvad", server: p.name)
        }
        // Still listed, with a key that isn't one: worth trying again later, not gone.
        guard validWgKey(r.publicKey) else { throw Fail("\(p.name) can't be reached right now") }
        return server(r, l)
    }

    /// Mullvad's `weight` is a selection weight (higher = preferred), not a load; the app picks weighted at random.
    private static func pick<G: RandomNumberGenerator>(_ rs: [Relay], _ rng: inout G) -> Relay {
        // Bounded, so no list (however odd its numbers) can overflow the sum.
        let weights = rs.map { Int64(min(max($0.weight, 0), maxWeight)) }
        let total = weights.reduce(0, +)
        if total <= 0 { return rs.randomElement(using: &rng)! }
        var t = Int64.random(in: 0..<total, using: &rng)
        return zip(rs, weights).first { t -= $1; return t < 0 }!.0
    }

    private static let maxWeight = 1_000_000

    private static func server(_ r: Relay, _ l: RelayList) -> Server {
        Server(name: r.hostname, host: r.hostname, ip: r.ip, publicKey: r.publicKey, load: 0, city: l.locations[r.location]?.city ?? "")
    }
}

extension Mullvad.RelayList {
    /// Relays for `loc`: a city if `Location.region` is set, else its country; `include_in_country = false` relays only by city.
    nonisolated func match(_ loc: Location, ownedOnly: Bool = false) -> [Mullvad.Relay] {
        usable.filter { r in
            if ownedOnly && !r.owned { return false }
            if let region = loc.region { return r.location == region }
            if let cc = loc.countryCode { return r.inCountry && r.location.prefix { $0 != "-" }.caseInsensitiveCompare(cc) == .orderedSame }
            if let country = loc.country { return r.inCountry && locations[r.location]?.country == country }
            return r.inCountry
        }
    }
}

nonisolated extension Mullvad.Relay {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(hostname: try c.decode(String.self, forKey: .hostname), location: try c.decode(String.self, forKey: .location), active: c(.active, true),
                  ip: try c.decode(String.self, forKey: .ip), publicKey: try c.decode(String.self, forKey: .publicKey), inCountry: c(.inCountry, true), weight: c(.weight, 0), owned: c(.owned, false))
    }
}

nonisolated extension Mullvad.Wireguard {
    init(from d: Decoder) throws { relays = try d.container(keyedBy: CodingKeys.self)(.relays, []) }
    enum CodingKeys: String, CodingKey { case relays }
}

nonisolated extension Mullvad.RelayList {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        locations = c(.locations, [:]); wireguard = c(.wireguard, Mullvad.Wireguard())
    }
    enum CodingKeys: String, CodingKey { case locations, wireguard }
}
