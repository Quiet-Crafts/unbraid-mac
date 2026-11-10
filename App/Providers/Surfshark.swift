import Foundation
import Synchronization

/// One registered key works on every location. Keys only come from Surfshark's own HTTPS list or its last good
/// copy. gluetun supplies addresses for those same hosts, never keys, and excludes Static IP servers.
/// Bare-key defaults come from Surfshark's manual Linux guide; gluetun says addresses are per key, so a whole
/// downloaded .conf is safer. Hostnames are never looked up on the local network.
nonisolated struct Surfshark: KeyProvider {
    let id = "surfshark"
    let name = "Surfshark"
    let fields = [Field(key: "key", label: "WireGuard key or .conf", hint: "Paste the whole file, or the private key", file: true)]
    let help = "Sign in at my.surfshark.com → VPN → Manual setup → Desktop or mobile → WireGuard → \"I don't have a key pair\" → name it → Generate a new key pair. The private key is shown only once, so also pick any location and Download the .conf, then paste that whole file here (it carries your private key and address). The same key works on every Surfshark location."
    let hasLoad = true
    let defaultAddress: [String]? = ["10.14.0.2/16"]
    let defaultDns = ["162.252.172.57", "149.154.159.92"]
    let defaultPort = 51820
    let defaultMtu = 1280

    var catalogue: @Sendable () async throws -> [Catalog.Entry] = { try await Catalog.fetch("surfshark", vpn: "wireguard") }
    var live: @Sendable () async throws -> Data = { try await Http.get("https://api.surfshark.com/v4/server/clusters/generic") }
    var snapshot = Snapshot.file()
    var addressBook = AddressBook(snapshot: .file("addresses-surfshark.bin"))

    private struct Cluster: Decodable {
        var country: String
        var region: String?
        var location: String?
        var connectionName: String
        var pubKey: String?
        var load: Int?
        enum CodingKeys: String, CodingKey { case country, region, location, connectionName, pubKey, load }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            country = try c.contains(.country) ? c.decode(String.self, forKey: .country) : ""
            region = try c.decodeIfPresent(String.self, forKey: .region)
            location = try c.decodeIfPresent(String.self, forKey: .location)
            connectionName = try c.contains(.connectionName) ? c.decode(String.self, forKey: .connectionName) : ""
            pubKey = try c.decodeIfPresent(String.self, forKey: .pubKey)
            load = try c.decodeIfPresent(Int.self, forKey: .load)
        }
    }

    static func parse(_ body: Data) throws -> [Catalog.Entry] {
        try JSON.decode([Cluster].self, body, "Surfshark").filter {
            !$0.country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.connectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.pubKey?.wholeMatch(of: /[A-Za-z0-9+\/]{42}[AEIMQUYcgkosw048]=/) != nil
        }.map {
            Catalog.Entry(vpn: "wireguard", country: $0.country, region: $0.region,
                          city: $0.location.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
                          hostname: $0.connectionName, wgpubkey: $0.pubKey, load: $0.load.map { min(max($0, 0), 100) } ?? -1)
        }
    }

    static func fallback(_ all: [Catalog.Entry]) -> [Catalog.Entry] { all.filter { !$0.hostname.contains(/-st\d+\./) } }

    /// Saved or pinned keys need either our own list or the user's downloaded .conf to vouch for them.
    func trustsKey(_ key: String, _ a: KeyAccount) -> Bool {
        key == a.publicKey || snapshot.read().flatMap { try? Self.parse($0) }?.contains { $0.wgpubkey == key } == true
    }

    @concurrent func entries(_ a: KeyAccount) async throws -> [Catalog.Entry] {
        do {
            let body = try await live()
            let all = try Self.parse(body)
            if !all.isEmpty { snapshot.write(body); return all }
        } catch { /* Keep the last good provider list when its API is unavailable. */ }
        // Marked as not live: a pin keeps its saved address, and the countries aren't cached as today's.
        if let body = snapshot.read(), let all = try? Self.parse(body), !all.isEmpty { return all.map { var e = $0; e.bundled = true; return e } }
        throw Fail("Surfshark's server list can't be reached right now")
    }

    @concurrent func usable(_ all: [Catalog.Entry], _ loc: Location) async -> [Catalog.Entry] {
        await usable(all, loc, limit: 1)
    }

    @concurrent func servers(_ loc: Location, _ account: String, limit: Int) async throws -> [Server] {
        await usable(try await entries(try keyAccount(account)), loc, limit: limit).compactMap { try? Catalog.server($0) }
    }

    private func usable(_ all: [Catalog.Entry], _ loc: Location, limit: Int) async -> [Catalog.Entry] {
        guard limit > 0 else { return [] }
        let picked = Catalog.pick(all, loc)
        if all.contains(where: { $0.ipv4 != nil }) { return Array(picked.prefix(limit)) }
        let addresses = await addressBook.read(catalogue)
        return Array(picked.compactMap { entry in
            guard let ips = addresses[entry.hostname.lowercased()] else { return nil }
            var e = entry; e.ips = ips; return e
        }.prefix(limit))
    }

    /// The last catalogue addresses are sealed separately from Surfshark's trusted keys.
    actor AddressBook {
        struct Saved: Codable { var date: Date; var addresses: [String: [String]] }
        private let snapshot: Snapshot
        private var saved: Saved?
        private var loaded = false
        private var nextTry = Date.distantPast
        private var pending: Task<[Catalog.Entry]?, Never>?
        init(snapshot: Snapshot) { self.snapshot = snapshot }

        func read(_ catalogue: @escaping @Sendable () async throws -> [Catalog.Entry]) async -> [String: [String]] {
            let now = Date()
            if !loaded {
                loaded = true
                if let data = snapshot.read(), let value = try? JSONDecoder().decode(Saved.self, from: data) {
                    let addresses = Self.literal(value.addresses)
                    if !addresses.isEmpty { saved = Saved(date: value.date, addresses: addresses) }
                }
            }
            if let saved, now.timeIntervalSince(saved.date) < 86400 { return saved.addresses }
            if now < nextTry { return saved?.addresses ?? [:] }
            let task: Task<[Catalog.Entry]?, Never>
            if let pending { task = pending } else {
                task = Task { try? await catalogue() }; pending = task
            }
            let entries = await task.value
            pending = nil
            if let entries {
                let pairs = Surfshark.fallback(entries).map { ($0.hostname.lowercased(), $0.ips) }
                let addresses = Self.literal(Dictionary(pairs, uniquingKeysWith: +))
                if !addresses.isEmpty {
                    let value = Saved(date: now, addresses: addresses)
                    saved = value
                    if let data = try? JSONEncoder().encode(value) { snapshot.write(data) }
                    return addresses
                }
            }
            nextTry = now.addingTimeInterval(900)
            return saved?.addresses ?? [:]
        }

        private static func literal(_ addresses: [String: [String]]) -> [String: [String]] {
            var result: [String: [String]] = [:]
            for (host, ips) in addresses where !host.lowercased().contains(/-st\d+\./) {
                let valid = ips.filter(Catalog.Entry.publicIPv4)
                if !valid.isEmpty { result[host.lowercased(), default: []].append(contentsOf: valid) }
            }
            return result
        }
    }

    /// The last good HTTPS list. Keep a memory copy even if storage is full; atomic replacement prevents partial lists.
    /// Kept here because the assigned provider owns this cache, not the app/widget snapshot in Shared.
    /// It decides which saved keys are Surfshark's, so on disk it is sealed like the accounts: another process running as
    /// the user can't plant a list of its own.
    final class Snapshot: Sendable {
        private let held = Mutex<Data?>(nil)
        private let load: @Sendable () throws -> Data?
        private let save: @Sendable (Data) throws -> Void
        init(load: @escaping @Sendable () throws -> Data?, save: @escaping @Sendable (Data) throws -> Void) {
            self.load = load; self.save = save
        }
        func read() -> Data? { held.withLock { $0 ?? (try? load()) } }
        func write(_ body: Data) { held.withLock { $0 = body; try? save(body) } }
        static func memory(_ initial: Data? = nil) -> Snapshot { Snapshot(load: { initial }, save: { _ in }) }
        static func file(_ name: String = "servers-surfshark.bin") -> Snapshot {
            let dir = URL.applicationSupportDirectory.appending(path: "unbraid", directoryHint: .isDirectory)
            let vault = Sealed(dir: dir)
            return Snapshot(load: { vault.read(name) }, save: {
                guard vault.write(name, $0) else { return }
                // Earlier versions kept it in the clear; that copy is never read.
                if name == "servers-surfshark.bin" { try? FileManager.default.removeItem(at: dir.appending(path: "servers-surfshark.json")) }
            })
        }
    }
}
