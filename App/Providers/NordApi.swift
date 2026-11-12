import Foundation

/// The handful of NordVPN endpoints unbraid needs.
nonisolated enum NordApi {
    private static let base = "https://api.nordvpn.com/v1"
    private static let dedicatedService = 11

    static func get(_ path: String, _ token: String? = nil, request: @Sendable (String, [String: String], Bool) async throws -> Data = { try await Http.get($0, headers: $1, credentials: $2) }) async throws -> Data {
        let headers = token.map { ["Authorization": "Basic " + Data("token:\($0)".utf8).base64EncodedString()] } ?? [:]
        do { return try await request(base + path, headers, token != nil) } catch is AuthError {
            throw AuthError("NordVPN rejected the token. Sign in again.")
        } catch let e as Http.Status where e.code == 429 { throw e
        } catch let e as Http.Status { throw Fail("NordVPN API \(e.code)") }
    }

    private static func unexpected() -> Fail { Fail("Unexpected reply from NordVPN") }

    private static func array(_ data: Data) throws -> [[String: Any]] {
        guard let a = try JSON.object(data, "NordVPN") as? [[String: Any]] else { throw unexpected() }
        return a
    }

    /// JSON numbers, or numerals in a string (kotlinx accepts both for `long`).
    private static func number(_ v: Any?) -> Int? { (v as? Int) ?? (v as? String).flatMap { Int($0) } }

    /// NordLynx private key plus the service username/password OpenVPN needs.
    static func credentials(_ token: String, request: @Sendable (String, [String: String], Bool) async throws -> Data = { try await Http.get($0, headers: $1, credentials: $2) }) async throws -> (key: String, user: String, pass: String) {
        guard let o = try JSON.object(try await get("/users/services/credentials", token, request: request), "NordVPN") as? [String: Any],
              let key = o["nordlynx_private_key"] as? String, let user = o["username"] as? String, let pass = o["password"] as? String
        else { throw unexpected() }
        // Checked here, at sign-in, rather than later at connect, where a bad key reads as a problem with the route.
        guard validWgKey(key) else { throw unexpected() }
        return (key, user, pass)
    }

    static func countries() async throws -> [Country] {
        struct Row: Decodable { var id: Int; var name: String; var code: String; var serverCount: Int?; var cities: [City]? }
        return try JSON.decode([Row].self, try await get("/servers/countries"), "NordVPN")
            .map { Country(id: $0.id, name: $0.name, code: $0.code, serverCount: $0.serverCount ?? 0, cities: $0.cities ?? []) }
    }

    /// Lowest-load servers for a location, best first. `tech`: wireguard_udp, openvpn_udp or openvpn_tcp.
    static func recommend(_ loc: Location, limit: Int = 3, tech: String = "wireguard_udp") async throws -> [Server] {
        var q = [("filters[servers_technologies][identifier]", tech)]
        if let id = loc.countryId { q.append(("filters[country_id]", "\(id)")) }
        if let id = loc.cityId { q.append(("filters[country_city_id]", "\(id)")) }
        if let g = loc.group { q.append(("filters[servers_groups][identifier]", g)) }
        q.append(("limit", "\(limit)"))
        let query = q.map { Http.enc($0.0) + "=" + $0.1 }.joined(separator: "&")
        return try parseServers(try await get("/servers/recommendations?\(query)"), needKey: tech == "wireguard_udp")
    }

    /// The servers named `name` (Nord's own name, "Germany #1187"): `/servers` filters by name, not host name, and
    /// answers [] for one it doesn't have.
    static func named(_ name: String, tech: String) async throws -> [Server] {
        try parseNamed(try await get("/servers?" + Http.enc("filters[servers.name]") + "=" + Http.enc(name) + "&limit=5"), needKey: tech == "wireguard_udp")
    }

    /// Only an empty answer means "no server by that name". Rows that are all skipped (no key for this technology, no
    /// public address) say nothing about the name, so that is an error, not an empty list.
    static func parseNamed(_ body: Data, needKey: Bool) throws -> [Server] {
        let rows = try array(body)
        let found = try servers(rows, needKey: needKey)
        if found.isEmpty, !rows.isEmpty { throw Fail("NordVPN listed no usable server by that name") }
        return found
    }

    /// The whole `/servers` list of a specialty `group` for `tech`, cut down to the given response `fields`.
    private static func groupServers(_ group: String, _ tech: String, _ fields: String...) async throws -> Data {
        let pairs = [("filters[servers_groups][identifier]", group), ("filters[servers_technologies][identifier]", tech), ("limit", "20000")]
        let query = pairs.map { Http.enc($0.0) + "=" + $0.1 } + fields.map { Http.enc("fields[servers.\($0)]") }
        return try await get("/servers?" + query.joined(separator: "&"))
    }

    /// Country codes with servers in a specialty `group`. `/servers/recommendations` is distance-sorted and cuts a long
    /// list short (P2P came back as 4 countries); the full `/servers` list with two fields is complete and small.
    static func groupCountries(_ group: String, _ tech: String) async throws -> Set<String> {
        try countryCodes(await groupServers(group, tech, "locations.country.code", "hostname"))
    }

    static func countryCodes(_ body: Data) throws -> Set<String> {
        Set(try array(body).flatMap { ($0["locations"] as? [[String: Any]] ?? []).compactMap { ($0["country"] as? [String: Any])?["code"] as? String } })
    }

    /// The servers of the account's active Dedicated IP services, as nordvpn-linux does it (daemon/serverpicker/dip.go):
    /// `/users/services` lists them (service id 11, `details.servers[].id`), and the ids are looked up in the Dedicated IP group.
    static func dedicated(_ token: String, _ tech: String) async throws -> [Server] {
        let ids = try dedicatedIds(try await get("/users/services", token))
        if ids.isEmpty { return [] }
        let all = try await groupServers(
            "legacy_dedicated_ip", tech, "id", "name", "hostname", "station", "load", "locations.country.code", "locations.country.city.name",
            "technologies.identifier", "technologies.metadata")
        return try withIds(all, ids, needKey: tech == "wireguard_udp")
    }

    static func withIds(_ body: Data, _ ids: Set<Int>, needKey: Bool) throws -> [Server] {
        try servers(try array(body).filter { number($0["id"]).map(ids.contains) ?? false }, needKey: needKey)
    }

    static func dedicatedIds(_ body: Data, now: Date = Date()) throws -> Set<Int> {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return Set(try array(body).filter { s in
            // An unreadable expiry counts as still active.
            number((s["service"] as? [String: Any])?["id"]) == dedicatedService && ((s["expires_at"] as? String).flatMap { f.date(from: $0) } ?? now) >= now
        }.flatMap { s in
            ((s["details"] as? [String: Any])?["servers"] as? [[String: Any]] ?? []).compactMap { number($0["id"]) }
        })
    }

    static func parseServers(_ body: Data, needKey: Bool = true) throws -> [Server] { try servers(try array(body), needKey: needKey) }

    /// A server without a name, host name or public address (an empty `station`) is skipped, not dialled.
    private static func servers(_ list: [[String: Any]], needKey: Bool) throws -> [Server] {
        list.compactMap { o in
            let wg = (o["technologies"] as? [[String: Any]])?.first { $0["identifier"] as? String == "wireguard_udp" }
            let key = (wg?["metadata"] as? [[String: Any]])?.first { $0["name"] as? String == "public_key" }?["value"] as? String
            if needKey && !(key.map(validWgKey) ?? false) { return nil }
            let place = ((o["locations"] as? [[String: Any]])?.first)?["country"] as? [String: Any]
            guard let name = o["name"] as? String, let host = o["hostname"] as? String, let ip = o["station"] as? String,
                  Catalog.Entry.publicIPv4(ip) else { return nil }
            return Server(name: name, host: host, ip: ip, publicKey: key ?? "", load: number(o["load"]) ?? 0,
                          city: (place?["city"] as? [String: Any])?["name"] as? String ?? "", country: place?["code"] as? String ?? "")
        }
    }
}
