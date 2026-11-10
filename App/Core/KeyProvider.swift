import Foundation

/// Providers where the user downloads one WireGuard key (or .conf) from the website and that single key serves every
/// server: sign-in is local, with no API to check it against. Tunnel settings come from the pasted .conf when there is
/// one, else from the provider's documented defaults; the server list comes from `entries`.
nonisolated struct KeyAccount: Codable, Hashable, Sendable {
    var privateKey: String
    var address: [String]
    var dns: [String]
    var port: Int
    var mtu: Int
    var presharedKey: String?
    /// The [Peer] key of a pasted .conf; only meaningful for providers whose servers all share one key.
    var publicKey: String?
    var facts: [String: String]? = nil
    var apiKey: String? = nil
    var device: String? = nil
    var deviceKey: String? = nil
    var deviceId: String? = nil
    var ownDevice: Bool? = nil
}

nonisolated protocol KeyProvider: Provider {
    /// Tunnel address when only a bare key is pasted; nil if the provider assigns it per device (the .conf is then required).
    var defaultAddress: [String]? { get }
    var defaultDns: [String] { get }
    var defaultPort: Int { get }
    var defaultMtu: Int { get }
    var presharedRequired: Bool { get }

    var configFacts: [String] { get }
    func entries(_ a: KeyAccount) async throws -> [Catalog.Entry]
    /// Whether a server key from an earlier list (a pinned or saved server) may still be used.
    func trustsKey(_ key: String, _ a: KeyAccount) -> Bool
    /// Whether this server may be dialled with its key, whatever list it came from. Providers that pin each host's key
    /// (Proton, from the bundled snapshot) refuse any other; checked on every path, new, pinned, kept or cached.
    func trustsServer(_ sv: Server, _ a: KeyAccount) -> Bool
    /// The server key a tunnel uses: the list's, unless the provider takes it from the account.
    func peerKey(_ sv: Server, _ a: KeyAccount) -> String
    /// The servers of `all` that suit `loc`, best first, each complete enough to connect to. Providers whose list lacks
    /// addresses (Surfshark's live one) resolve them here.
    func usable(_ all: [Catalog.Entry], _ loc: Location) async -> [Catalog.Entry]
}

nonisolated(unsafe) private let keyPattern = /[A-Za-z0-9+\/]{43}=/
nonisolated private let factPattern = try! NSRegularExpression(pattern: #"^\s*#\s*([A-Za-z][A-Za-z ()-]{0,40}?)\s*=\s*([A-Za-z0-9 .-]{1,40})\s*$"#)

nonisolated extension KeyProvider {
    var configFacts: [String] { [] }
    var defaultMtu: Int { 1420 }
    var presharedRequired: Bool { false }
    func trustsKey(_ key: String, _ a: KeyAccount) -> Bool { true }
    func trustsServer(_ sv: Server, _ a: KeyAccount) -> Bool { true }
    func peerKey(_ sv: Server, _ a: KeyAccount) -> String { sv.publicKey }
    @concurrent func usable(_ all: [Catalog.Entry], _ loc: Location) async -> [Catalog.Entry] { Catalog.pick(all, loc) }

    func trusts(_ link: Link, _ account: String) -> Bool {
        guard case .wg(let sv, let peer, _, _) = link, let a = try? keyAccount(account) else { return false }
        // A saved tunnel from before address checks could still dial nowhere (":51820") or the engine's fake address.
        guard Catalog.Entry.publicIPv4(sv.ip), peer.endpoint == "\(sv.ip):\(a.port)" else { return false }
        return peer.publicKey == peerKey(sv, a) && trustsKey(peer.publicKey, a) && trustsServer(sv, a)
    }

    @concurrent func signIn(_ input: [String: String]) async throws -> String { try parseKey(input) }

    /// Named separately so provider-specific checks can reuse the same parser without a forwarding adapter.
    func parseKey(_ input: [String: String]) throws -> String {
        let text = (input["key"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return JSON.encode(text.contains("[") ? try fromConf(text) : try fromKey(text.filter { !$0.isWhitespace }))
    }

    private func fromKey(_ key: String) throws -> KeyAccount {
        guard key.wholeMatch(of: keyPattern) != nil else { throw Fail("That doesn't look like a WireGuard private key") }
        guard let address = defaultAddress else {
            throw Fail("\(name) needs the whole downloaded .conf file: it holds this device's address and preshared key")
        }
        return KeyAccount(privateKey: key, address: address, dns: defaultDns, port: defaultPort, mtu: defaultMtu)
    }

    private func fromConf(_ text: String) throws -> KeyAccount {
        let p = try WgConf.parse(text, name: name)
        if presharedRequired && p.presharedKey == nil { throw Fail("That \(name) config has no PresharedKey line") }
        let mtuSet = text.contains(/(?im)^\s*mtu\s*=/)
        var facts: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = factPattern.firstMatch(in: line, range: range), let k = Range(match.range(at: 1), in: line), let v = Range(match.range(at: 2), in: line) else { continue }
            let key = line[k].trimmingCharacters(in: .whitespaces)
            if configFacts.contains(key) { facts[key] = String(line[v].trimmingCharacters(in: .whitespaces).prefix(24)) }
        }
        return KeyAccount(privateKey: p.privateKey, address: p.address, dns: p.dns.isEmpty ? defaultDns : p.dns,
                          port: Int(p.endpoint.split(separator: ":").last ?? "") ?? defaultPort, mtu: mtuSet ? p.mtu : defaultMtu,
                          presharedKey: p.presharedKey, publicKey: p.publicKey, facts: configFacts.isEmpty ? nil : facts)
    }

    func keyAccount(_ blob: String) throws -> KeyAccount { try JSON.decode(KeyAccount.self, Data(blob.utf8), "the account store") }

    @concurrent func countries(_ account: String) async throws -> [Country] { try await freshCountries(account).countries }
    @concurrent func freshCountries(_ account: String) async throws -> (countries: [Country], live: Bool, published: Int64?, failed: Bool) {
        let all = try await entries(try keyAccount(account))
        return (Catalog.countries(all), !all.isEmpty && !all.contains(where: \.bundled), all.first?.published, all.contains(where: \.refreshFailed))
    }

    @concurrent func connect(_ loc: Location, _ account: String) async throws -> Link {
        let a = try keyAccount(account)
        return try await link(loc, a) { try await entries(a) }
    }

    @concurrent func servers(_ loc: Location, _ account: String, limit: Int) async throws -> [Server] {
        let a = try keyAccount(account)
        return Array(await usable(try await entries(a), loc).compactMap { try? Catalog.server($0) }.filter { trustsServer($0, a) }.prefix(limit))
    }

    /// The current address and key of a pinned server, found by host name and name (AirVPN shares one host name per
    /// country), else by IP. The pinned values stand in only when the list can't be read; a server the list no longer
    /// has is an error rather than a stale endpoint.
    private func refreshed(_ p: Server, _ a: KeyAccount, _ entries: () async throws -> [Catalog.Entry]) async throws -> Server {
        let all: [Catalog.Entry]
        let saved = Catalog.Entry.publicIPv4(p.ip) && trustsKey(peerKey(p, a), a) && trustsServer(p, a)
        do { all = try await entries() } catch let e where !(e is AuthError) {
            if saved { return p }
            throw e
        }
        // Only the bundled snapshot answered: it has nothing newer than a pin it still vouches for.
        if saved, all.contains(where: \.bundled) { return p }
        let host = Catalog.identity(p.host)
        var found = all.filter { host != nil && Catalog.identity($0.hostname) == host && ($0.serverName ?? String($0.hostname.split(separator: ".").first ?? "")) == p.name }
        if found.isEmpty, !p.ip.isEmpty { found = all.filter { $0.ips.contains(p.ip) } }
        guard let first = found.first else { throw Catalog.Gone(provider: name, server: p.name) }
        // Unresolvable now: keep the pinned address, if it is one, but with the list's current key.
        guard let live = await usable(found, Location(provider: id)).first(where: { $0.hostname == first.hostname && $0.ipv4 != nil }) else {
            guard Catalog.Entry.publicIPv4(p.ip) else { throw Fail("\(p.name) can't be reached right now") }
            var s = p
            if let k = first.wgpubkey { s.publicKey = k }
            return s
        }
        return try Catalog.server(live, name: p.name)
    }

    func link(_ loc: Location, _ a: KeyAccount, _ entries: () async throws -> [Catalog.Entry]) async throws -> Link {
        let sv: Server
        if let p = loc.pinned { sv = try await refreshed(p, a, entries) } else if let s = await usable(try await entries(), loc).lazy
            .compactMap({ try? Catalog.server($0) }).first(where: { trustsServer($0, a) }) {
            sv = s
        } else { throw Fail("No \(name) server for \(loc.label)") }
        // Whatever the path, never an endpoint without a public address (an empty one, or the engine's fake answer).
        guard Catalog.Entry.publicIPv4(sv.ip) else { throw Fail("\(sv.name) can't be reached right now") }
        // Nor a key the provider doesn't vouch for for this host (Proton: a changed or unknown one).
        guard trustsServer(sv, a) else { throw Fail("\(name)'s list has a key for \(sv.name) that this version of unbraid doesn't trust. Update unbraid.") }
        return .wg(sv, WgPeer(name: sv.name, privateKey: a.privateKey, address: a.address, publicKey: peerKey(sv, a), presharedKey: a.presharedKey,
                              endpoint: "\(sv.ip):\(a.port)", allowedIps: ["0.0.0.0/0"], dns: a.dns, mtu: a.mtu))
    }
}
