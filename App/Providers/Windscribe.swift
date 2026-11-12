import Foundation

/// A generated paid-plan config supplies the private key, address and preshared key shared across ordinary servers.
/// Build-a-Plan keys only work at purchased locations; Static IP configs belong under My Servers.
/// The public list uses each node's `ip3` and its group's `wg_pubkey`, as gluetun does. Allowed ports and fallback
/// 1194 come from gluetun. It is unverified that `health` is load or every ip3 accepts every port, so health only
/// orders nodes and isn't advertised as a percentage. No Windscribe account was available for a live tunnel test.
nonisolated struct Windscribe: Provider {
    let id = "windscribe"
    let name = "Windscribe"
    let fields = [Field(key: "config", label: "WireGuard config", hint: "Paste the whole file", file: true)]
    let help = "A paid plan is needed. Sign in at windscribe.com, open My Account, Config Generator, WireGuard tab, pick any location "
        + "and a port (443 if unsure), keep \"Generate new keypair\", then Download Config. Open the file in a text editor and paste all of it here. "
        + "The key works for every location your plan covers. Build-a-Plan accounts can only connect to the locations they paid for. "
        + "Static IP configs are tied to one server: import those under \"My Servers\" instead."

    struct Account: Codable, Hashable, Sendable {
        var privateKey: String
        var address: [String]
        var presharedKey: String
        var dns: [String] = []
        var mtu = 1420
        var port = 1194
        enum CodingKeys: String, CodingKey { case privateKey, address, presharedKey, dns, mtu, port }
        init(privateKey: String, address: [String], presharedKey: String, dns: [String] = [], mtu: Int = 1420, port: Int = 1194) {
            (self.privateKey, self.address, self.presharedKey, self.dns, self.mtu, self.port) = (privateKey, address, presharedKey, dns, mtu, port)
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            privateKey = try c.decode(String.self, forKey: .privateKey)
            address = try c.decode([String].self, forKey: .address)
            presharedKey = try c.decode(String.self, forKey: .presharedKey)
            dns = try c.contains(.dns) ? c.decode([String].self, forKey: .dns) : []
            mtu = try c.contains(.mtu) ? c.decode(Int.self, forKey: .mtu) : 1420
            port = try c.contains(.port) ? c.decode(Int.self, forKey: .port) : 1194
        }
    }

    struct Node: Decodable, Sendable {
        var hostname: String
        var ip3: String
        var health: Int
        enum CodingKeys: String, CodingKey { case hostname, ip3, health }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            hostname = try c.contains(.hostname) ? c.decode(String.self, forKey: .hostname) : ""
            ip3 = try c.contains(.ip3) ? c.decode(String.self, forKey: .ip3) : ""
            health = try c.contains(.health) ? c.decode(Int.self, forKey: .health) : 0
        }
    }
    struct Group: Decodable, Sendable {
        var city: String
        var publicKey: String
        var wgEndpoint: String
        var nodes: [Node]
        enum CodingKeys: String, CodingKey { case city, publicKey = "wg_pubkey", wgEndpoint = "wg_endpoint", nodes }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            city = try c.contains(.city) ? c.decode(String.self, forKey: .city) : ""
            publicKey = try c.contains(.publicKey) ? c.decode(String.self, forKey: .publicKey) : ""
            wgEndpoint = try c.contains(.wgEndpoint) ? c.decode(String.self, forKey: .wgEndpoint) : ""
            nodes = try c.contains(.nodes) ? c.decode([Node].self, forKey: .nodes) : []
        }
    }
    struct Region: Decodable, Sendable {
        var name: String
        var code: String
        var status: Int
        var groups: [Group]
        enum CodingKeys: String, CodingKey { case name, code = "country_code", status, groups }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            name = try c.contains(.name) ? c.decode(String.self, forKey: .name) : ""
            code = try c.contains(.code) ? c.decode(String.self, forKey: .code) : ""
            status = try c.contains(.status) ? c.decode(Int.self, forKey: .status) : 1
            groups = try c.contains(.groups) ? c.decode([Group].self, forKey: .groups) : []
        }
    }
    struct ServerList: Decodable, Sendable {
        var data: [Region]
        enum CodingKeys: String, CodingKey { case data }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            data = try c.contains(.data) ? c.decode([Region].self, forKey: .data) : []
        }
    }
    struct Row: Sendable {
        var region: String
        var code: String
        var city: String
        var node: Node
        var publicKey: String
    }

    /// nil means the live list is unavailable, so only the endpoint's format is checked.
    var nodeHosts: @Sendable () async -> Set<String>? = {
        try? await Self.hosts(Self.parse(Http.get("https://assets.windscribe.com/serverlist/mob-v2/1/\(Int(Date().timeIntervalSince1970))")))
    }

    static func hosts(_ list: ServerList) -> Set<String> {
        Set(list.data.flatMap { $0.groups.flatMap { [$0.wgEndpoint] + $0.nodes.map(\.hostname) } }.filter { !$0.isEmpty }.map { $0.lowercased() })
    }

    private static let ports: Set = [53, 80, 123, 443, 1194, 65142]
    nonisolated(unsafe) private static let ipv4 = /(\d{1,3}\.){3}\d{1,3}/

    private func isStatic(_ endpoint: String) async -> Bool {
        let host = String(endpoint.prefix(upTo: endpoint.lastIndex(of: ":") ?? endpoint.endIndex))
        if host.wholeMatch(of: Self.ipv4) != nil || host.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) == nil ||
            host.lowercased().contains("static") { return true }
        return await nodeHosts().map { !$0.contains(host.lowercased()) } ?? false
    }

    @concurrent func signIn(_ input: [String: String]) async throws -> String {
        let text = (input["config"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let p = try WgConf.parse(text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text, name: name)
        guard await !isStatic(p.endpoint) else {
            throw Fail("This looks like a Static IP config, which is tied to one server. Import it under \"My Servers\" instead.")
        }
        guard let psk = p.presharedKey else {
            throw Fail("This config has no PresharedKey. Generate a WireGuard config at windscribe.com and paste that")
        }
        let port = Int(p.endpoint.split(separator: ":").last ?? "") ?? 1194
        return JSON.encode(Account(privateKey: p.privateKey, address: p.address, presharedKey: psk, dns: p.dns,
                                   mtu: p.mtu, port: Self.ports.contains(port) ? port : 1194))
    }

    static func account(_ blob: String) throws -> Account { try JSON.decode(Account.self, Data(blob.utf8), "Windscribe") }
    static func parse(_ body: Data) throws -> ServerList { try JSON.decode(ServerList.self, body, "Windscribe") }

    private static func fetch() async throws -> [Row] {
        try rows(parse(await Http.get("https://assets.windscribe.com/serverlist/mob-v2/1/\(Int(Date().timeIntervalSince1970))")))
    }

    /// The usable nodes; tests replace it.
    var catalogue: @Sendable () async throws -> [Row] = { try await Windscribe.fetch() }

    @concurrent func countries(_ account: String) async throws -> [Country] { Self.countries(try await catalogue()) }
    /// A pinned node is looked up in a fresh list; the saved values stand in only when the list can't be read.
    @concurrent func connect(_ loc: Location, _ account: String) async throws -> Link {
        let rows = loc.pinned == nil ? try await catalogue() : try await Catalog.unlessOutage { try await catalogue() }
        return try Self.link(rows, loc, Self.account(account))
    }
    @concurrent func servers(_ loc: Location, _ account: String, limit: Int) async throws -> [Server] {
        Self.match(try await catalogue(), loc).sorted {
            $0.node.health == $1.node.health ? $0.node.hostname < $1.node.hostname : $0.node.health < $1.node.health
        }.prefix(limit).map(Self.server)
    }

    /// WireGuard-capable nodes in regions that are up, with a valid group key and an IPv4 address.
    static func rows(_ l: ServerList) -> [Row] {
        l.data.filter { $0.status == 1 && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.flatMap { r in
            r.groups.filter { validWgKey($0.publicKey) && !$0.city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.flatMap { g in
                g.nodes.filter { Catalog.Entry.publicIPv4($0.ip3) && !$0.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { Row(region: r.name, code: r.code.uppercased(), city: g.city, node: $0, publicKey: g.publicKey) }
            }
        }
    }

    /// Windscribe's own regions, including multiple locations sharing one country code ("US East", "US Central").
    static func countries(_ rows: [Row]) -> [Country] {
        Dictionary(grouping: rows, by: \.region).sorted { $0.key < $1.key }.map { region, rs in
            Country(id: stableId(region), name: region, code: rs[0].code, serverCount: rs.count,
                    cities: Set(rs.map(\.city)).sorted().map { City(id: stableId($0), name: $0, key: $0) })
        }
    }
    static func match(_ rows: [Row], _ loc: Location) -> [Row] {
        rows.filter { r in
            (loc.country.map { r.region == $0 } ?? loc.countryCode.map { r.code.lowercased() == $0.lowercased() } ?? true) &&
            (loc.region == nil || r.city == loc.region)
        }
    }
    static func link(_ rows: [Row]?, _ loc: Location, _ a: Account) throws -> Link {
        var sv: Server
        if let pinned = loc.pinned {
            sv = pinned
            // Its current address and group key; an empty list proves nothing.
            if let rows, !rows.isEmpty {
                guard let r = rows.first(where: { $0.node.hostname.caseInsensitiveCompare(pinned.host) == .orderedSame }) else {
                    throw Catalog.Gone(provider: "Windscribe", server: pinned.name, unavailable: true)
                }
                sv = server(r)
            }
        }
        else if let r = match(rows ?? [], loc).shuffled().min(by: { $0.node.health < $1.node.health }) { sv = server(r) }
        else { throw Fail("No Windscribe server for \(loc.label)") }
        guard Catalog.Entry.publicIPv4(sv.ip) else { throw Fail("\(sv.name) can't be reached right now") }
        return .wg(sv, WgPeer(name: sv.name, privateKey: a.privateKey, address: a.address, publicKey: sv.publicKey,
                              presharedKey: a.presharedKey, endpoint: "\(sv.ip):\(a.port)", allowedIps: ["0.0.0.0/0"], dns: a.dns, mtu: a.mtu))
    }
    private static func server(_ r: Row) -> Server {
        Server(name: String(r.node.hostname.split(separator: ".").first ?? ""), host: r.node.hostname, ip: r.node.ip3,
               publicKey: r.publicKey, load: r.node.health, city: r.city, country: r.code)
    }
}
