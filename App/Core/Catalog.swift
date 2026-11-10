import Foundation
import CryptoKit
import Synchronization

/// Server catalogues for providers without a public server API (or as a fallback), from gluetun's monthly updated,
/// MIT-licensed data: https://github.com/qdm12/gluetun-servers. Proton's and ExpressVPN's lists also ship inside the
/// app at one reviewed commit (`Pinned`); the live copy on `main` only refreshes addresses.
nonisolated enum Catalog {
    private static let base = "https://raw.githubusercontent.com/qdm12/gluetun-servers/main/pkg/servers/"

    struct Entry: Codable, Hashable, Sendable {
        var vpn = ""
        var country: String?
        var region: String?
        var city: String?
        var serverName: String?
        var hostname = ""
        var wgpubkey: String?
        var ips: [String] = []
        var udp = false
        var tcp = false
        /// Proton: usable on the free plan.
        var free = false
        /// Live load in percent from a provider's own list; -1 = none (the gluetun catalogue has no load figures).
        var load = -1
        /// Not read live just now: from the snapshot inside the app, or from the last good live list kept on disk. Its
        /// addresses may be older than a pinned server's. Never stored.
        var bundled = false
        var published: Int64? = nil
        var refreshFailed = false

        enum CodingKeys: String, CodingKey { case vpn, country, region, city, serverName = "server_name", hostname, wgpubkey, ips, udp, tcp, free, load, published }

        init(vpn: String = "", country: String? = nil, region: String? = nil, city: String? = nil, serverName: String? = nil, hostname: String = "",
             wgpubkey: String? = nil, ips: [String] = [], udp: Bool = false, tcp: Bool = false, free: Bool = false, load: Int = -1) {
            (self.vpn, self.country, self.region, self.city, self.serverName, self.hostname) = (vpn, country, region, city, serverName, hostname)
            (self.wgpubkey, self.ips, self.udp, self.tcp, self.free, self.load) = (wgpubkey, ips, udp, tcp, free, load)
        }

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            self.init(vpn: c(.vpn, ""), country: c(.country, nil), region: c(.region, nil), city: c(.city, nil), serverName: c(.serverName, nil),
                      hostname: c(.hostname, ""), wgpubkey: c(.wgpubkey, nil), ips: c(.ips, []), udp: c(.udp, false), tcp: c(.tcp, false),
                      free: c(.free, false), load: c(.load, -1))
            published = c(.published, nil)
        }

        /// Some providers (Windscribe) only fill `region` with the country.
        var place: String { country ?? region ?? "" }
        /// A public IPv4 literal only: a hostname or a private address in a third-party list is never dialled.
        var ipv4: String? { ips.first(where: Self.publicIPv4) }

        static func publicIPv4(_ s: String) -> Bool {
            guard let p = octets(s) else { return false }
            return !(p[0] == 0 || p[0] == 10 || p[0] == 127 || p[0] >= 224 || (p[0] == 169 && p[1] == 254)
                || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168) || (p[0] == 100 && (64...127).contains(p[1]))
                // The engine's fake addresses: what the system resolver answers while unbraid runs.
                || (p[0] == 198 && (18...19).contains(p[1])))
        }

        /// Exactly four decimal octets: no empty part, sign, leading zero (some resolvers read those as octal) or value
        /// over 255, so "1.2.3.4." or "1.2.3..4" are not addresses.
        static func octets(_ s: String) -> [UInt8]? {
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var out: [UInt8] = []
            for part in parts {
                guard (1...3).contains(part.count), part.allSatisfy({ ("0"..."9").contains($0) }), part.count == 1 || part.first != "0",
                      let v = UInt8(part) else { return nil }
                out.append(v)
            }
            return out
        }
    }

    private struct File: Decodable { var timestamp: Int64?; var servers: [Entry] = [] }

    /// Publication time in the source, distinct from when it was fetched.
    static func timestamp(_ body: Data) -> Int64? {
        guard let n = (try? JSONDecoder().decode(File.self, from: body))?.timestamp, n > 0 else { return nil }
        return n
    }

    /// `name` is the gluetun file name, e.g. "protonvpn"; `vpn` keeps "wireguard" or "openvpn" servers with an IPv4.
    @concurrent static func fetch(_ name: String, vpn: String) async throws -> [Entry] {
        let body = try await Http.get(base + Http.enc(name) + ".json")
        let date = timestamp(body)
        return try parse(body, vpn: vpn).map { var e = $0; e.published = date; return e }
    }

    static func parse(_ body: Data, vpn: String) throws -> [Entry] {
        let file = try JSON.decode(File.self, body, "the server catalogue")
        return usable(file.servers, vpn: vpn).map { var entry = $0; entry.published = file.timestamp; return entry }
    }

    private static func usable(_ rows: [Entry], vpn: String) -> [Entry] {
        rows.filter { $0.vpn == vpn && $0.ipv4 != nil && !$0.place.isEmpty && (vpn != "wireguard" || !($0.wgpubkey ?? "").isEmpty) }
    }

    // MARK: Bundled snapshot

    /// The bundled lists can't be read or don't match the digests compiled into the app.
    struct Damaged: LocalizedError {
        var errorDescription: String? { "unbraid's built-in server list is damaged. Reinstall unbraid." }
    }

    /// For a pinned server: the list, or nil when it can't be read right now (then the saved values stand in). Refused
    /// credentials and cancellation are never an outage.
    static func unlessOutage<T: Sendable>(_ read: () async throws -> T) async throws -> T? {
        do { return try await read() } catch let e as AuthError { throw e } catch is CancellationError { throw CancellationError() } catch let e as Damaged { throw e } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    /// A pinned server that a list read just now no longer has: an answer, not an outage, so no saved tunnel stands in.
    struct Gone: LocalizedError {
        let provider: String, server: String
        /// Only usable servers are listed (Windscribe): one missing may just be down.
        var unavailable = false
        var errorDescription: String? {
            unavailable ? "\(provider) doesn't offer \(server) right now. Pick another server." : "\(provider) no longer lists \(server). Pick another server."
        }
    }

    /// A list shipped inside the app at one reviewed gluetun-servers commit (Resources/Catalog, written by
    /// tools/update-catalog.sh with `Pin`). Proton's WireGuard keys are trusted only from here: a live list may move a
    /// server or drop one, never change a key or add a host, so a new key arrives only with an app update.
    final class Pinned: Sendable {
        let entries: [Entry]
        let published: Int64?
        /// Normalised host name → its WireGuard key. A host listed with two keys, or a malformed one, has none.
        let keys: [String: String]
        /// The first listed entry per host, server name and protocol: what a live row may only refresh the address of.
        private let listed: [Slot: Entry]

        init(_ rows: [Entry], vpn: String, published: Int64? = nil) {
            self.published = published
            var keys: [String: String] = [:], doubtful = Set<String>()
            for r in rows where r.vpn == "wireguard" {
                guard let id = Catalog.identity(r.hostname), let k = r.wgpubkey else { continue }
                if !Catalog.validKey(k) || keys[id].map({ $0 != k }) == true { doubtful.insert(id) } else { keys[id] = k }
            }
            for id in doubtful { keys[id] = nil }
            self.keys = keys
            let entries = Catalog.usable(rows, vpn: vpn).filter { e in
                e.vpn != "wireguard" || Catalog.identity(e.hostname).flatMap { keys[$0] } == e.wgpubkey
            }
            self.entries = entries
            listed = Dictionary(entries.compactMap { e in Catalog.identity(e.hostname).map { (Slot($0, e.serverName, e.vpn), e) } },
                                uniquingKeysWith: { first, _ in first })
        }

        /// The live list where this snapshot vouches for it, as fresh addresses for servers it already lists: a row whose
        /// host and server name it doesn't list, or (WireGuard) whose key differs, is left out. Everything else about a
        /// server (country, city, name, plan, protocols) is the snapshot's: a live list could otherwise relabel a genuine
        /// server, so "Netherlands" exits elsewhere. `keep` narrows to what the provider can use. With nothing usable live
        /// (unreachable, blocked, or all of it refused), the snapshot itself, marked `bundled`, less the hosts the live
        /// list just contradicted.
        func refresh(_ live: [Entry]?, _ keep: ([Entry]) -> [Entry]) -> [Entry] {
            let contradicted = contradicted(live ?? [])
            let agreed: [Entry] = (live ?? []).compactMap { e in
                guard let id = Catalog.identity(e.hostname) else { return nil }
                if e.vpn == "wireguard" {
                    guard let k = keys[id], e.wgpubkey == k else { return nil }
                }
                guard var known = listed[Slot(id, e.serverName, e.vpn)] else { return nil }
                known.ips = e.ips
                known.load = e.load
                known.published = e.published
                return known
            }
            let fresh = keep(agreed)
            if !fresh.isEmpty { return fresh }
            return keep(entries.filter { e in Catalog.identity(e.hostname).map { !contradicted.contains($0) } ?? false })
                .map { var e = $0; e.bundled = true; e.published = published ?? e.published; return e }
        }

        /// Hosts a live list gives another WireGuard key than this snapshot's.
        func contradicted(_ live: [Entry]) -> Set<String> {
            Set(live.compactMap { e in
                guard e.vpn == "wireguard", let id = Catalog.identity(e.hostname), let k = keys[id], e.wgpubkey != k else { return nil }
                return id
            })
        }

        private struct Slot: Hashable {
            let host: String, name: String?, vpn: String
            init(_ host: String, _ name: String?, _ vpn: String) { (self.host, self.name, self.vpn) = (host, name, vpn) }
        }
    }

    /// Where a provider's list comes from: the live copy, and the bundled one that vouches for it; `saved` keeps the
    /// last good live copy for when GitHub can't be reached. Tests replace them.
    struct Source: Sendable {
        var live: @Sendable () async throws -> [Entry]
        var pinned: @Sendable () throws -> Pinned
        var saved: Saved? = nil

        static let proton = Source(live: { try await within(10) { try await fetch("protonvpn", vpn: "wireguard") } },
                                   pinned: { try protonSnapshot.get() }, saved: .file("catalog-protonvpn.bin"))
        static let express = Source(live: { try await within(10) { try await fetch("expressvpn", vpn: "openvpn") } },
                                    pinned: { try expressSnapshot.get() }, saved: .file("catalog-expressvpn.bin"))

        /// The live list as the snapshot allows it, else the last good live list (checked against the snapshot the same
        /// way, and marked `bundled`: not live now), else the snapshot (see `Pinned.refresh`). Only a damaged snapshot
        /// or cancellation fails: a blocked GitHub never stops the provider.
        func entries(_ keep: ([Entry]) -> [Entry]) async throws -> [Entry] {
            let snapshot = try pinned()
            var list: [Entry]?, kept = false, failed = false
            do { list = try await live() } catch {
                try Task.checkCancellation()
                failed = true
                list = saved?.read()
                kept = list != nil
            }
            let out = snapshot.refresh(list, keep).map { var e = $0; e.refreshFailed = failed; return e }
            if kept { return out.map { var e = $0; e.bundled = true; return e } }
            // Kept only once the snapshot accepted it: a list it refused (unknown hosts, changed keys) never replaces a
            // good one. Hosts it contradicted leave the kept list too, so an outage later can't bring them back.
            if let list {
                if !out.isEmpty, !out.contains(where: \.bundled) { saved?.write(list) }
                else { saved?.drop(snapshot.contradicted(list)) }
            }
            return out
        }
    }

    /// The last good live list, sealed like the accounts (another process running as the user can't plant one), with a
    /// memory copy. It only refreshes addresses: every use passes the bundled snapshot's checks again.
    final class Saved: Sendable {
        /// `version` counts the lists handed to `save`, in order; `stored` is the last one confirmed on disk.
        private struct State { var entries: [Entry]?; var version = 0 }
        private let held = Mutex(State())
        private let stored = Mutex(0)
        private let load: @Sendable () -> Data?
        private let save: @Sendable (Data, @escaping @Sendable (Bool) -> Void) -> Void
        init(load: @escaping @Sendable () -> Data?, save: @escaping @Sendable (Data, @escaping @Sendable (Bool) -> Void) -> Void) {
            self.load = load; self.save = save
        }

        func read() -> [Entry]? {
            held.withLock { s in
                if s.entries == nil { s.entries = load().flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } }
                return s.entries
            }
        }

        /// Written to disk only when it changed or the last write didn't make it: connects read the list often. Handed to
        /// `save` under the lock, so writes reach the disk in the order they were made.
        func write(_ entries: [Entry]) {
            held.withLock { s in
                guard s.entries != entries || stored.withLock({ $0 }) != s.version else { return }
                s.entries = entries
                s.version += 1
                let v = s.version
                guard let data = try? JSONEncoder().encode(entries) else { return }
                save(data) { [weak self] ok in if ok { self?.stored.withLock { $0 = max($0, v) } } }
            }
        }

        /// The kept list less `hosts` (normalised names).
        func drop(_ hosts: Set<String>) {
            guard !hosts.isEmpty, let all = read() else { return }
            let left = all.filter { Catalog.identity($0.hostname).map { !hosts.contains($0) } ?? true }
            if left.count != all.count { write(left) }
        }

        static func memory() -> Saved { Saved(load: { nil }, save: { $1(true) }) }
        static func file(_ name: String) -> Saved {
            let vault = Sealed(dir: URL.applicationSupportDirectory.appending(path: "unbraid", directoryHint: .isDirectory))
            return Saved(load: { vault.read(name) }, save: { data, done in FileWork.shared.submit { done(vault.write(name, data)) } })
        }
    }

    private static let protonSnapshot = Result { try bundled("protonvpn", vpn: "wireguard") }
    private static let expressSnapshot = Result { try bundled("expressvpn", vpn: "openvpn") }

    /// The bundled lists' folder: the app's resources, or the test bundle's for host-less tests.
    nonisolated private final class Token {}
    static var folder: URL? { Bundle(for: Token.self).resourceURL?.appending(path: "Catalog", directoryHint: .isDirectory) }

    struct Manifest: Codable, Equatable, Sendable {
        var source = "https://github.com/qdm12/gluetun-servers"
        var commit: String
        var files: [String: String]
    }

    /// Reads `name`.json from `dir` only if its bytes match the digest compiled into the app (`pin`), and the shipped
    /// manifest names the same commit and digests.
    static func bundled(_ name: String, vpn: String, dir: URL? = folder, pin: Manifest = Catalog.pin) throws -> Pinned {
        guard let dir, let expected = pin.files["\(name).json"],
              let data = try? Data(contentsOf: dir.appending(path: "\(name).json")),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appending(path: "manifest.json"))),
              manifest.commit == pin.commit, manifest.files == pin.files,
              let file = try? JSONDecoder().decode(File.self, from: data) else { throw Damaged() }
        let rows = file.servers.map { var row = $0; row.published = file.timestamp; return row }
        let snapshot = Pinned(rows, vpn: vpn, published: timestamp(data))
        guard !snapshot.entries.isEmpty else { throw Damaged() }
        return snapshot
    }

    /// Host names compare without case or a final dot; an empty one is no identity.
    static func identity(_ host: String) -> String? {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        return h.isEmpty ? nil : h
    }

    /// A WireGuard public key: exactly 32 bytes, in canonical Base64.
    static func validKey(_ k: String) -> Bool {
        guard let d = Data(base64Encoded: k), d.count == 32 else { return false }
        return d.base64EncodedString() == k
    }

    /// The live list must not hold a connect up for long when the bundled one can stand in.
    static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await work() }
            g.addTask { try await Task.sleep(for: .seconds(seconds)); throw Fail("The server list took too long") }
            defer { g.cancelAll() }
            return try await g.next()!
        }
    }

    /// Countries with their cities; ids are stable, City.key = city name.
    static func countries(_ entries: [Entry]) -> [Country] {
        Dictionary(grouping: entries, by: \.place).sorted { $0.key < $1.key }.map { place, list in
            let cities = Set(list.compactMap(\.city)).sorted()
            return Country(id: stableId(place), name: place, code: code(place), serverCount: list.count,
                           cities: cities.map { City(id: stableId($0), name: $0, key: $0) })
        }
    }

    /// Servers for a location, shuffled so equals share the traffic; entries with a live load come lowest first.
    static func pick(_ entries: [Entry], _ loc: Location) -> [Entry] {
        entries.filter { e in
            (loc.country.map { $0 == e.place } ?? loc.countryCode.map { $0 == code(e.place) } ?? true) && (loc.region == nil || e.city == loc.region)
        }.shuffled().sorted { ($0.load < 0 ? .max : $0.load) < ($1.load < 0 ? .max : $1.load) }
    }

    /// English names, normalised ("Hong Kong SAR China" → "hong kong", "Myanmar (Burma)" → "myanmar").
    private static func norm(_ name: String) -> String {
        var n = name.lowercased().replacingOccurrences(of: " & ", with: " and ").replacingOccurrences(of: "ô", with: "o")
        n = String(n.split(separator: " (", maxSplits: 1).first ?? "")
        n = n.components(separatedBy: ", ").first ?? n
        for s in [" sar china", " darussalam"] where n.hasSuffix(s) { n.removeLast(s.count) }
        if n.hasPrefix("the ") { n.removeFirst(4) }
        return n.trimmingCharacters(in: .whitespaces)
    }

    private static let codes: [String: String] = {
        let en = Locale(identifier: "en_US")
        return Dictionary(Locale.Region.isoRegions.filter { $0.identifier.count == 2 }.compactMap { r in
            en.localizedString(forRegionCode: r.identifier).map { (norm($0), r.identifier) }
        }, uniquingKeysWith: { a, _ in a })
    }()

    private static let aliases = [
        "usa": "US", "united states of america": "US", "uk": "GB", "great britain": "GB", "south korea": "KR", "turkey": "TR",
        "czech republic": "CZ", "macau": "MO", "macedonia": "MK", "ivory coast": "CI", "russia": "RU", "vietnam": "VN", "uae": "AE",
        "bosnia": "BA", "cape verde": "CV", "eswatini": "SZ", "democratic republic of the congo": "CD", "dr congo": "CD",
        "republic of the congo": "CG", "cote d'ivoire": "CI", "palestine": "PS", "brunei": "BN", "marocco": "MA", "north korea": "KP",
        "syria": "SY", "iran": "IR", "laos": "LA",
    ]

    /// ISO code for a catalogue country name; "··" when unknown rather than a plausible-looking wrong code.
    static func code(_ country: String) -> String { let n = norm(country); return codes[n] ?? aliases[n] ?? "··" }

    /// Throws rather than leave a server without an address: an entry's only addresses may be private or fake ones.
    static func server(_ e: Entry, name: String? = nil) throws -> Server {
        guard let ip = e.ipv4 else { throw Fail("No usable address for \(e.hostname)") }
        return Server(name: name ?? e.serverName ?? String(e.hostname.split(separator: ".").first ?? ""), host: e.hostname, ip: ip,
                      publicKey: e.wgpubkey ?? "", load: e.load, city: e.city ?? "", country: code(e.place))
    }
}
