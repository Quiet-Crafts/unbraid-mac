import Foundation

/// IVPN over WireGuard. Account blob: account ID, session token, WireGuard private key and the tunnel address IVPN assigned.
///
/// Sign-in follows the official client (github.com/ivpn/desktop-app, daemon/api): `POST https://api.ivpn.net/v4/session/new`
/// with `{username, force, wg_public_key}`. The reply carries its own `status` (200, 401 bad ID, 602 session limit,
/// 702 inactive account, 70001 captcha, 70011 2FA), `token` and `wireguard.ip_address`. One session and one key serve every host.
/// Server list: `GET /v5/servers.json`. Port 2049 and DNS = the host's in-tunnel `local_ip` (172.16.0.1) as in IVPN's WireGuard FAQ
/// and the client's DefaultDNS. Unverified: the success reply was not seen (no account); `ip_address` is assumed to be a bare IPv4
/// (a mask is stripped if present). Two-factor codes and captcha answers complete the same sign-in form.
///
/// Quantum-safe: every sign-in also sends a Round-3 Kyber-1024 public key (`kem_public_key1`, with IVPN's own
/// `kem_library_version`); the reply's `wireguard.kem_cipher1` decapsulates to a secret whose SHA-256 is the WireGuard
/// preshared key, as in IVPN's own apps. A reply without it ends the sign-in (the new session is signed out again):
/// the server refuses the key without the preshared key anyway, and unbraid never falls back to a plain tunnel. An
/// account from before the preshared key existed keeps its routes off until the user signs in again (`link`): never a
/// plain tunnel, never an automatic upgrade.
///
/// Sign-out frees the session: `POST /v4/session/delete {"session_token"}`. Limitation: IVPN has no API to list sessions,
/// so a `session/new` whose reply is lost in transit leaves an orphaned session (one of the account's device slots) that
/// only the user can remove in the IVPN client area; it cannot be reconciled here.
nonisolated struct Ivpn: Provider {
    struct Account: Codable, Hashable {
        var accountId: String
        var sessionToken: String
        var privateKey: String
        var ipAddress: String
        var limit: Int? = nil
        var device: String? = nil
        var createdAt: Date? = nil
        /// The quantum-safe preshared key; nil for an account signed in before it existed.
        var psk: String? = nil
        /// When the key was registered, in milliseconds since 1970 (as the Android app keeps it); nil = not kept.
        var keyAt: Int64? = nil
        /// Android's unfinished key change: read when present, never written or used here.
        var pending: Pending? = nil
    }

    struct Pending: Codable, Hashable {
        var privateKey: String
        var publicKey: String
        var kemPublic: String
        var kemPrivate: String
    }

    /// Round-3 Kyber-1024 (not ML-KEM, which IVPN's servers don't accept). The engine does the work; tests replace it.
    protocol Kyber: Sendable {
        /// A new key pair, base64.
        func keyPair() throws -> (public: String, private: String)
        /// base64(SHA-256(secret)) of `cipher` for `private`; throws on a malformed key or ciphertext.
        func psk(private: String, cipher: String) throws -> String
    }

    /// What the app has no engine for (the tests): nothing can be signed in without a quantum-safe key.
    private struct NoKyber: Kyber {
        func keyPair() throws -> (public: String, private: String) { throw Fail("Quantum-safe keys aren't available") }
        func psk(private: String, cipher: String) throws -> String { throw Fail("Quantum-safe keys aren't available") }
    }

    /// Set once at launch, before any provider is used: the app links the engine, the tests don't.
    nonisolated(unsafe) static var engine: any Kyber = NoKyber()
    var kyberOverride: (any Kyber)? = nil
    var kyber: any Kyber { kyberOverride ?? Self.engine }
    /// What IVPN's own apps send as `kem_library_version`.
    static let kemVersion = "0.10.0"

    private struct WgReply: Decodable {
        var ipAddress: String?
        var kemCipher: String?
        enum CodingKeys: String, CodingKey { case ipAddress = "ip_address", kemCipher = "kem_cipher1" }
    }

    private struct Plan: Decodable { var name: String?; var device_limit: Int? }
    private struct Service: Decodable {
        var current_plan: String?; var available_plans: [Plan]?; var limit: Int?
        var deviceLimit: Int? {
            if let limit, limit > 0 { return limit }
            return available_plans?.filter { !($0.name ?? "").isEmpty && (current_plan ?? "").localizedCaseInsensitiveContains($0.name!) }
                .max { ($0.name?.count ?? 0) < ($1.name?.count ?? 0) }?.device_limit
        }
    }
    private struct SessionReply: Decodable {
        var status: Int?
        var token: String?
        var wireguard: WgReply?
        var device_name: String?; var service_status: Service?; var data: Service?
        var captcha_id: String?; var captcha_image: String?
    }

    struct Host: Decodable, Hashable {
        let hostname: String
        let host: String
        let publicKey: String
        let localIp: String
        var load = 0.0
        /// The hosting company, shown in the server list.
        var isp: String? = nil
        enum CodingKeys: String, CodingKey { case hostname, host, publicKey = "public_key", localIp = "local_ip", load, isp }
    }

    struct Gateway: Decodable, Hashable {
        let gateway: String
        let countryCode: String
        let country: String
        let city: String
        var hosts: [Host] = []
        enum CodingKeys: String, CodingKey { case gateway, countryCode = "country_code", country, city, hosts }
    }

    struct Port: Decodable { var type: String?; var port: Int? }
    struct Ports: Decodable { var wireguard: [Port]? }
    struct Blocklist: Decodable { var Description: String?; var Normal: String?; var Hardcore: String? }
    struct AntiTracker: Decodable { var DnsServers: [Blocklist]? }
    struct Config: Decodable { var ports: Ports?; var antitracker_plus: AntiTracker? }
    struct ServerList: Decodable {
        var wireguard: [Gateway] = []
        var config: Config? = nil
        /// Hostnames IVPN's status list marks inactive or in maintenance (`Ivpn.down`): picked only when nothing else
        /// is left. Not in the server list itself.
        var down: Set<String> = []
        /// Hosts best first: up before down, then by load.
        func best(_ a: (Gateway, Host), _ b: (Gateway, Host)) -> Bool {
            let (ad, bd) = (down.contains(a.1.hostname), down.contains(b.1.hostname))
            return ad != bd ? bd : a.1.load < b.1.load
        }
        var ports: [Int] { Array(Set((config?.ports?.wireguard ?? []).compactMap { $0.type?.uppercased() == "UDP" ? $0.port : nil }.filter { (1...65535).contains($0) })).sorted() }
    }

    private static let api = "https://api.ivpn.net"
    private static let port = 2049
    /// Besides its listed ports, IVPN's WireGuard servers answer on any UDP port in these ranges (IVPN's port guide).
    static let portRanges = [5500...19999, 30000...65000]
    private static let dns = "172.16.0.1"

    let id = "ivpn"
    /// Every host in IVPN's list carries its load, and the app picks the lowest.
    let hasLoad = true
    let name = "IVPN"
    let fields = [Field(key: "account", label: "Account ID", hint: "i-XXXX-XXXX-XXXX", qr: true)]
    let help = "Your account ID (i-XXXX-XXXX-XXXX, or ivpn plus 8 characters on older accounts): in the IVPN client area, or on any device already logged in. unbraid uses one of your device sessions."

    /// A new key reaches every IVPN server within about a minute of the sign-in.
    let keySetup = 90
    let deviceURL: String? = "https://www.ivpn.net/clientarea/"
    let protection: ProviderOption? = .init(key: "protect", label: "AntiTracker", kind: .toggle, defaultValue: "off", help: "Ads and trackers")
    let defaults = ["protect": "off", "list": "10.0.254.2|10.0.254.3", "hardcore": "off", "port": "auto"]
    var statusRequest: @Sendable (String) async throws -> (Int, Data) = { token in
        try await postJSONRaw("https://api.ivpn.net/v4/session/status", JSON.encode(["session_token": token]))
    }
    @concurrent func device(_ account: String) async throws -> String? {
        let a = try Self.account(account)
        let live = try? await statusRequest(a.sessionToken)
        let reply = live.flatMap { try? JSON.decode(SessionReply.self, $0.1, "IVPN") }
        let name = (reply?.status == 200 ? reply?.device_name : nil) ?? a.device ?? ""
        return "\(name.isEmpty ? "" : "Named \(name). ")See all your devices in the IVPN client area"
    }
    @concurrent func revoked(_ account: String) async throws -> Bool {
        guard let a = try? Self.account(account), let r = try? await statusRequest(a.sessionToken) else { return false }
        let status = (try? JSON.decode(SessionReply.self, r.1, "IVPN").status) ?? r.0
        return status == 601 || status == 401
    }
    func blockingDns(_ opts: (String) -> String?) -> String? {
        let parts = (opts("list") ?? "10.0.254.2|10.0.254.3").split(separator: "|")
        let i = opts("hardcore") == "on" ? 1 : 0
        guard parts.count == 2, Self.dnsAddress(String(parts[i])) else { return "10.0.254.2" }
        return String(parts[i])
    }
    static func validList(_ value: String) -> Bool {
        let parts = value.split(separator: "|", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { dnsAddress(String($0)) }
    }
    private static func dnsAddress(_ s: String) -> Bool {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        return p.count == 4 && p.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0).map { (0...255).contains($0) } == true }
    }
    @concurrent func options(_ account: String) async throws -> [ProviderOption] { Self.options(try await catalogue()) }
    static func options(_ list: ServerList) -> [ProviderOption] {
        let choices = (list.config?.antitracker_plus?.DnsServers ?? []).compactMap { item -> ProviderOption.Choice? in
            guard let n = item.Normal, let h = item.Hardcore, let label = item.Description, !label.isEmpty, dnsAddress(n), dnsAddress(h) else { return nil }
            return .init(value: "\(n)|\(h)", label: label)
        }
        var out: [ProviderOption] = []
        if !choices.isEmpty { out.append(.init(key: "list", label: "Block list", kind: .choice(choices), defaultValue: "10.0.254.2|10.0.254.3", help: "What AntiTracker blocks, from IVPN's own lists")) }
        out.append(.init(key: "hardcore", label: "Hardcore mode", kind: .toggle, defaultValue: "off", advanced: true, help: "Also blocks Google and Facebook, and sites that need them"))
        out.append(.init(key: "port", label: "Port", kind: .choice([.init(value: "auto", label: "Automatic")] + list.ports.map { .init(value: String($0), label: "UDP \($0)") }), defaultValue: "auto", advanced: true, help: "Automatic tries 2049 first, then other ports when a network blocks it", custom: Self.portRanges))
        return out
    }

    @concurrent func limit(_ account: String) async throws -> Limit? {
        let value = (try? Self.account(account).limit).flatMap { $0 > 0 ? $0 : nil }
        return Limit(unit: "device", perTunnel: false, value: value)
    }

    var newSession: @Sendable (String) async throws -> (Int, Data) = { try await postJSONRaw("\(Self.api)/v4/session/new", $0) }
    var deleteSession: @Sendable (String) async throws -> (Int, Data) = { try await postJSONRaw("\(Self.api)/v4/session/delete", JSON.encode(["session_token": $0])) }

    @concurrent func signIn(_ input: [String: String]) async throws -> String {
        let acct = (input["account"] ?? "").filter { !$0.isWhitespace }
        guard acct.wholeMatch(of: /i-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}|ivpn[A-Za-z0-9]{7,8}/) != nil else {
            throw Fail("Account ID must look like i-XXXX-XXXX-XXXX or ivpnXXXXXXXX")
        }
        let keys = WgKeys.generate()
        let kem: (public: String, private: String)
        do { kem = try kyber.keyPair() } catch { throw Fail("unbraid couldn't make a quantum-safe key. Try again") }
        var body: [String: Any] = ["username": acct, "force": false, "wg_public_key": keys.publicKey,
                                   "kem_public_key1": kem.public, "kem_library_version": Self.kemVersion]
        for key in ["confirmation", "captcha", "captcha_id"] { if let v = input[key], !v.isEmpty { body[key] = v.filter { !$0.isWhitespace } } }
        let data = try JSONSerialization.data(withJSONObject: body)
        let reply = try await newSession(String(decoding: data, as: UTF8.self))
        do { return try Self.session(reply, acct, keys.privateKey, kemPrivate: kem.private, kyber: kyber) }
        catch {
            guard let token = Self.sessionToken(reply) else { throw error }
            // The session IVPN just opened is of no use: freed, or the user is told it still holds one of the account's devices.
            if let freed = try? await deleteSession(token), Self.released(freed) { throw error }
            let said = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            throw Fail("\(said). IVPN's new session couldn't be released either: remove it in the IVPN client area")
        }
    }

    @concurrent func signOut(_ account: String) async -> Bool {
        guard let a = try? Self.account(account),
              let reply = try? await deleteSession(a.sessionToken) else { return false }
        return Self.released(reply)
    }

    static func released(_ reply: (Int, Data)) -> Bool {
        // IVPN's own status says more than the HTTP answer (as in `session`): a 2xx whose reply says otherwise is no release.
        // Read on its own, so the rest of the reply can't hide it; one that isn't a number counts as a failure.
        let body = (try? JSON.object(reply.1, "IVPN")) as? [String: Any]
        let status = body?["status"].map { $0 as? Int ?? 0 } ?? reply.0
        return (200..<300).contains(reply.0) && (200..<300).contains(status) || status == 401 || status == 601
    }

    private struct TokenReply: Decodable { let token: String? }
    static func sessionToken(_ reply: (Int, Data)) -> String? {
        guard let token = (try? JSONDecoder().decode(TokenReply.self, from: reply.1))?.token, !token.isEmpty else { return nil }
        return token
    }

    /// The preshared key `cipher` gives for `kemPrivate`: nil unless it is a 32-byte base64 key.
    static func presharedKey(_ cipher: String?, _ kemPrivate: String, _ kyber: any Kyber) -> String? {
        guard let cipher, !cipher.isEmpty, let psk = try? kyber.psk(private: kemPrivate, cipher: cipher), validWgKey(psk) else { return nil }
        return psk
    }

    static let noQuantumKey = "IVPN didn't send a quantum-safe key, so unbraid didn't finish signing in. Try again later"

    static func session(_ reply: (Int, Data), _ account: String, _ privateKey: String, kemPrivate: String, kyber: any Kyber) throws -> String {
        let (code, body) = reply
        if code == 429 { throw Http.Status(code: code) }
        // An outage answers with a page, not IVPN's JSON: its status says more than "unexpected reply".
        guard let o = try? JSON.decode(SessionReply.self, body, "IVPN") else {
            if code == 401 { throw AuthError("IVPN doesn't recognise that account ID") }
            if (200..<300).contains(code) { throw Fail("Unexpected reply from IVPN") }
            throw Http.Status(code: code)
        }
        // IVPN's own status says why a sign-in failed; a session only counts when the HTTP answer was a success too.
        switch o.status ?? code {
        case 200 where !(200..<300).contains(code): throw Http.Status(code: code)
        case 200: break
        case 401: throw AuthError("IVPN doesn't recognise that account ID")
        case 602: throw AuthError(Limits.full("IVPN", o.data?.deviceLimit, "device"), url: "https://www.ivpn.net/clientarea/")
        case 702: throw AuthError("This IVPN account isn't active. Renew it first.")
        case 70001, 70002:
            guard let id = o.captcha_id, id.wholeMatch(of: /[A-Za-z0-9_-]{1,128}/) != nil else { throw AuthError("IVPN is asking for a captcha. Log in once on ivpn.net or in the IVPN app, then try again.") }
            let encoded = o.captcha_image ?? ""
            let image = Data(base64Encoded: encoded.components(separatedBy: "base64,").last ?? "", options: .ignoreUnknownCharacters)
            throw Challenge(message: o.status == 70002 ? "That didn't match. Try this picture." : "Type the characters in the picture.", field: Field(key: "captcha", label: "Characters in the picture", secret: false), image: image, state: ["captcha_id": id])
        case 70011, 70012:
            throw Challenge(message: o.status == 70012 ? "That code didn't work. Enter the current one." : "Enter the code from your authenticator app.", field: Field(key: "confirmation", label: "Two-factor code", secret: false, hint: "6 digits"))
        case let status: throw Fail("IVPN error \(status)")
        }
        guard let ip = o.wireguard?.ipAddress, !ip.isEmpty, !ip.prefix(while: { $0 != "/" }).isEmpty else { throw Fail("IVPN didn't assign a WireGuard address") }
        // It becomes the tunnel's own address: four plain numbers, or the reply isn't one to trust.
        guard Catalog.Entry.octets(String(ip.prefix { $0 != "/" })) != nil else { throw Fail("Unexpected reply from IVPN") }
        guard let token = o.token, !token.isEmpty else { throw Fail("IVPN didn't return a session") }
        guard let psk = presharedKey(o.wireguard?.kemCipher, kemPrivate, kyber) else { throw Fail(noQuantumKey) }
        return JSON.encode(Account(accountId: account, sessionToken: token, privateKey: privateKey, ipAddress: String(ip.prefix { $0 != "/" }), limit: o.service_status?.deviceLimit, device: o.device_name.map { String($0.prefix(64)) }, createdAt: Date(),
                                   psk: psk, keyAt: Int64(Date().timeIntervalSince1970 * 1000)))
    }

    func quantumSafe(_ account: String) -> Bool? { (try? Self.account(account)).map { $0.psk != nil } ?? false }

    /// A saved tunnel stands in only if it was made for this sign-in: its key and its quantum-safe key both match, and
    /// an account without a quantum-safe key trusts none (never a plain tunnel).
    func trusts(_ link: Link, _ account: String) -> Bool {
        guard case .wg(_, let peer, _, _) = link else { return true }
        guard let a = try? Self.account(account), let psk = a.psk else { return false }
        return peer.privateKey == a.privateKey && peer.presharedKey == psk
    }

    static func account(_ blob: String) throws -> Account { try JSON.decode(Account.self, Data(blob.utf8), "IVPN") }

    @concurrent func countries(_ account: String) async throws -> [Country] { Self.countries(try await catalogue()) }

    /// A pinned server is looked up in a fresh list (moved or re-keyed, or gone); the saved values stand in only when
    /// the list can't be read.
    @concurrent func connect(_ loc: Location, _ account: String) async throws -> Link {
        let list: ServerList?
        if loc.pinned == nil { list = try await withStatus() } else { list = try await Catalog.unlessOutage { try await catalogue() } }
        return try Self.link(list, loc, try Self.account(account))
    }

    @concurrent func servers(_ loc: Location, _ account: String, limit: Int) async throws -> [Server] {
        let list = try await withStatus()
        return Self.listed(list, loc, limit: limit)
    }

    /// `loc`'s servers best first, each with its note: out of service (inactive or in maintenance), and the hosting company.
    static func listed(_ list: ServerList, _ loc: Location, limit: Int) -> [Server] {
        list.match(loc).enumerated().sorted { a, b in
            list.best(a.element, b.element) || !list.best(b.element, a.element) && a.offset < b.offset
        }.prefix(limit).map { item in
            let (g, h) = item.element
            var sv = server(g, h)
            let down = list.down.contains(h.hostname)
            let isp = (h.isp ?? "").trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isNewline }
            let note = [down ? "Out of service" : nil, isp.isEmpty ? nil : String(isp.prefix(40))].compactMap { $0 }.joined(separator: " · ")
            (sv.note, sv.flagged) = (note.isEmpty ? nil : note, down)
            return sv
        }
    }

    /// The server list; tests replace it.
    var catalogue: @Sendable () async throws -> ServerList = { try Ivpn.parse(try await Http.get("\(Ivpn.api)/v5/servers.json")) }
    /// Which hosts IVPN's public status list says are inactive or in maintenance; empty when it can't be read, so
    /// nothing changes then. Tests replace it.
    var status: @Sendable () async -> Set<String> = { (try? Ivpn.down(try await Http.get("\(Ivpn.api)/v5/servers/stats"))) ?? [] }

    /// The server list with the hosts that are down, both asked at once. The status list gets three seconds at most: a
    /// slow one never holds a connection back, it only leaves the order as the load gives it.
    private func withStatus() async throws -> ServerList {
        let status = self.status
        async let down = withTaskGroup(of: Set<String>?.self) { group -> Set<String> in
            group.addTask { await status() }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
        var list = try await catalogue()
        list.down = await down
        return list
    }

    private struct StatHost: Decodable { var hostname: String? }
    private struct StatHosts: Decodable { var wireguard: StatHost? }
    private struct StatServer: Decodable {
        var active: Bool?; var maintenance: Bool?; var hosts: StatHosts?
        enum CodingKeys: String, CodingKey { case active = "is_active", maintenance = "in_maintenance", hosts }
    }
    private struct Stats: Decodable { var servers: [StatServer]? }

    /// WireGuard hostnames IVPN's status list marks inactive or in maintenance.
    static func down(_ body: Data) throws -> Set<String> {
        Set(try JSON.decode(Stats.self, body, "IVPN").servers?.filter { $0.active == false || $0.maintenance == true }
            .compactMap { $0.hosts?.wireguard?.hostname?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? [])
    }

    static func parse(_ body: Data) throws -> ServerList { try JSON.decode(ServerList.self, body, "IVPN") }

    static func countries(_ l: ServerList) -> [Country] {
        Dictionary(grouping: l.wireguard.filter { !$0.hosts.isEmpty }, by: \.countryCode).values
            .sorted { ($0[0].country, $0[0].countryCode) < ($1[0].country, $1[0].countryCode) }.map { gs in
                let cities = gs.sorted { ($0.city, $0.gateway) < ($1.city, $1.gateway) }.map { City(id: stableId($0.gateway), name: $0.city, key: $0.gateway) }
                return Country(id: stableId(gs[0].countryCode), name: gs[0].country, code: gs[0].countryCode.uppercased(),
                               serverCount: gs.reduce(0) { $0 + $1.hosts.count }, cities: cities)
            }
    }

    static func link(_ l: ServerList?, _ loc: Location, _ a: Account) throws -> Link {
        // No quantum-safe key (signed in before it existed): the route stays off, never a plain tunnel.
        guard let psk = a.psk else { throw KeyNotReady("Sign in to IVPN again to get its quantum-safe key: until then this route stays off.") }
        var sv: Server, dns: String
        if let pinned = loc.pinned {
            (sv, dns) = (pinned, Self.dns)
            // Found by host name anywhere in the list (its place may have changed). Not by address: another host may
            // have that one now. An empty list proves nothing.
            if let l, !l.wireguard.isEmpty {
                guard let (g, h) = l.match(Location(provider: "ivpn"), listed: true).first(where: { $0.1.hostname.caseInsensitiveCompare(pinned.host) == .orderedSame })
                else { throw Catalog.Gone(provider: "IVPN", server: pinned.name) }
                // Still listed, with a key or resolver that isn't one: worth trying again later, not gone.
                guard h.valid else { throw Fail("\(pinned.name) can't be reached right now") }
                (sv, dns) = (server(g, h), String(h.localIp.prefix { $0 != "/" }))
                sv.name = pinned.name
            }
        } else {
            guard let l, let (g, h) = l.match(loc).min(by: l.best) else { throw Fail("No IVPN server for \(loc.label)") }
            (sv, dns) = (server(g, h), String(h.localIp.prefix { $0 != "/" }))
        }
        guard Catalog.Entry.publicIPv4(sv.ip) else { throw Fail("\(sv.name) can't be reached right now") }
        return .wg(sv, WgPeer(name: sv.name, privateKey: a.privateKey, address: ["\(a.ipAddress.prefix { $0 != "/" })/32"], publicKey: sv.publicKey, presharedKey: psk,
                              endpoint: "\(sv.ip):\(port)", allowedIps: ["0.0.0.0/0"], dns: [dns]), ports: [2049, 443, 53, 80, 123, 2050, 1194, 500, 4500].filter { l?.ports.contains($0) == true })
    }

    private static func server(_ g: Gateway, _ h: Host) -> Server {
        // A percentage: anything else in the list (a huge or odd number) can't trap the conversion.
        Server(name: h.hostname, host: h.hostname, ip: h.host, publicKey: h.publicKey, load: h.load.isFinite ? Int(min(max(h.load, 0), 100).rounded()) : 0, city: g.city)
    }
}

extension Ivpn.ServerList {
    /// Hosts for `loc`: a city (gateway) if `Location.region` is set, else its country, else everything.
    /// [listed]: also hosts whose key or resolver isn't one (`Ivpn.Host.valid`), to tell those from hosts that are gone.
    nonisolated func match(_ loc: Location, listed: Bool = false) -> [(Ivpn.Gateway, Ivpn.Host)] {
        wireguard.filter { g in
            if let region = loc.region { return g.gateway == region }
            if let cc = loc.countryCode { return g.countryCode.caseInsensitiveCompare(cc) == .orderedSame }
            if let country = loc.country { return g.country == country }
            return true
        }.flatMap { g in g.hosts.filter { Catalog.Entry.publicIPv4($0.host) && (listed || $0.valid) }.map { (g, $0) } }
    }
}

nonisolated extension Ivpn.Host {
    /// Its key and resolver (`local_ip`) go into the configuration as they are: only a WireGuard key and an IPv4 address.
    var valid: Bool { validWgKey(publicKey) && Catalog.Entry.octets(String(localIp.prefix { $0 != "/" })) != nil }
}

nonisolated extension Ivpn.Host {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(hostname: try c.decode(String.self, forKey: .hostname), host: try c.decode(String.self, forKey: .host),
                  publicKey: try c.decode(String.self, forKey: .publicKey), localIp: try c.decode(String.self, forKey: .localIp), load: c(.load, 0.0),
                  isp: (try? c.decodeIfPresent(String.self, forKey: .isp)) ?? nil)
    }
}

nonisolated extension Ivpn.Gateway {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(gateway: try c.decode(String.self, forKey: .gateway), countryCode: try c.decode(String.self, forKey: .countryCode),
                  country: try c.decode(String.self, forKey: .country), city: try c.decode(String.self, forKey: .city), hosts: c(.hosts, []))
    }
}

nonisolated extension Ivpn.ServerList {
    init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); wireguard = c(.wireguard, []); config = try c.decodeIfPresent(Ivpn.Config.self, forKey: .config) }
    enum CodingKeys: String, CodingKey { case wireguard, config }
}
