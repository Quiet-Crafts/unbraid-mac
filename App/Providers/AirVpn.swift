import Foundation
import Synchronization

/// AirVPN issues an address and preshared key per device. Sign-in accepts an API key or the whole .conf. All servers share its
/// [Peer] PublicKey: neither a live list nor a catalogue or pin can replace it. Status supplies healthy `ip_v4_in1`
/// entries; gluetun is an address-only fallback. Port/DNS defaults rest on gluetun and generated forum configs
/// (AirVPN's pages were behind a bot wall). Simultaneous tunnels to the same server need separate devices' keys.
nonisolated struct AirVpn: KeyProvider {
    let id = "airvpn"
    let name = "AirVPN"
    let fields = [Field(key: "key", label: "API key or WireGuard .conf", hint: "The API key, or the whole generated file", file: true)]
    let help = "In the AirVPN Client Area open API (airvpn.org/apisettings), add an API key and paste it here. unbraid adds a device of its own and removes it when you sign out. Or open Config Generator, choose WireGuard, a device and any server, then generate the .conf and paste the whole file."
    let hasLoad = true
    let deviceURL: String? = "https://airvpn.org/devices/"
    let blockingUrl: String? = "https://airvpn.org/dns/"
    let configHelp: (String, String)? = ("Forwarded ports and dynamic DNS are set in the AirVPN Client Area and apply on their own", "https://airvpn.org/ports/")
    let defaultAddress: [String]? = nil
    let defaultDns = ["10.128.0.1"]
    let defaultPort = 1637
    let presharedRequired = true

    var catalogue: @Sendable () async throws -> [Catalog.Entry] = { try await Catalog.fetch("airvpn", vpn: "wireguard") }
    var status: @Sendable () async throws -> Data = { try await Http.get("https://airvpn.org/api/status/") }

    /// AmneziaWG lines would otherwise be silently dropped by the engine.
    @concurrent func signIn(_ input: [String: String]) async throws -> String {
        let key = (input["key"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if key.wholeMatch(of: /[0-9a-fA-F]{64}/) != nil { return try await fromAPI(key, input["device"]) }
        guard !(input["key"] ?? "").contains(/(?im)^\s*(jc|jmin|jmax|s[1-4]|h[1-4]|i[1-5])\s*=/) else {
            throw Fail("This config uses Amnezia obfuscation (Jc, S1, H1 and similar lines), which unbraid can't apply. Generate a standard WireGuard config in the AirVPN Config Generator.")
        }
        return try parseKey(input)
    }

    @concurrent func entries(_ a: KeyAccount) async throws -> [Catalog.Entry] {
        do {
            let all = try Self.parse(try await status(), serverKey: a.publicKey ?? "")
            guard !all.isEmpty else { throw Fail("Empty AirVPN server list") }
            return all
        } catch {
            guard let key = a.publicKey else { throw error }
            return try await catalogue().map { var e = $0; e.wgpubkey = key; e.ips = e.ipv4.map { [$0] } ?? []; return e }
        }
    }

    func trusts(_ link: Link, _ account: String) -> Bool {
        // An OpenVPN profile was checked when it was made; a saved one must still dial a single public address on 443 with its
        // own transport and wrapper, and the standard entry's is the server's address.
        if case .ovpn(let server, let profile) = link {
            guard let a = try? keyAccount(account), a.apiKey != nil else { return false }
            for kind in Self.openVpn.values {
                guard let host = Self.dialled(profile, at: nil, kind) else { continue }
                return kind.entry != 1 || host == server.ip
            }
            return false
        }
        guard case .wg(let server, let peer, let ports, let entries) = link, let a = try? keyAccount(account),
              Catalog.Entry.publicIPv4(server.ip), let colon = peer.endpoint.lastIndex(of: ":"),
              let port = Int(peer.endpoint[peer.endpoint.index(after: colon)...]) else { return false }
        let host = String(peer.endpoint[..<colon])
        guard host == server.ip || (entries.contains(host) && Catalog.Entry.publicIPv4(host)) else { return false }
        // 51820 only on the alternative entry, the one AirVPN's servers take it on.
        let onAlternative = entries.count == 2 && host == entries[1]
        guard port == a.port || ([1637, 47107].contains(port) && ports.contains(port)) || (port == 51820 && ports.contains(port) && onAlternative) else { return false }
        return peer.publicKey == peerKey(server, a)
    }

    /// Every server shares the account's [Peer] key, including pinned and previously saved servers.
    func peerKey(_ sv: Server, _ a: KeyAccount) -> String { a.publicKey ?? sv.publicKey }


    struct DeviceInfo: Decodable, Sendable {
        var id: String; var name: String; var status: String
        var key: String?; var ipv4: String?
        enum CodingKeys: String, CodingKey { case id, name, status, key = "wireguard_public_key", ipv4 = "wireguard_ipv4" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
            key = try c.decodeIfPresent(String.self, forKey: .key)
            ipv4 = try c.decodeIfPresent(String.self, forKey: .ipv4)
        }
    }
    struct Reply: Decodable { var devices: [DeviceInfo]?; var id: String?; var error: String? }
    /// The open connections of the account, every app's: only how many is read, whatever each one holds.
    struct Sessions: Decodable {
        var count: Int?
        init(from decoder: Decoder) throws { count = (try? decoder.unkeyedContainer())?.count }
    }
    struct UserInfo: Decodable { struct User: Decodable { var premium: Bool?; var expiration_unix: Int64? }; var user: User?; var sessions: Sessions?; var error: String? }
    var api: @Sendable (String, String, [String: String]) async throws -> Data = { service, key, query in
        let q = query.sorted { $0.key < $1.key }.map { "\(Http.enc($0.key))=\(Http.enc($0.value))" }.joined(separator: "&")
        return try await Http.get("https://airvpn.org/api/\(service)/" + (q.isEmpty ? "" : "?" + q), headers: ["API-KEY": key])
    }
    var pause: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }
    var journal: AirCleanup = .shared
    static let cleanupRefused = Notification.Name("AirVpnCleanupRefused")
    var cleanupWarning: @Sendable () -> Void = { NotificationCenter.default.post(name: cleanupRefused, object: nil) }

    private func checked(_ data: Data) throws -> Reply {
        let r = try JSON.decode(Reply.self, data, "AirVPN")
        if let error = r.error, error.localizedCaseInsensitiveContains("authoriz") { throw AuthError("AirVPN didn't accept that API key. Check it in the Client Area under API", url: "https://airvpn.org/apisettings/") }
        return r
    }
    private func devices(_ key: String) async throws -> [DeviceInfo] { Self.named(try await allDevices(key)) }
    private static func named(_ rows: [DeviceInfo]) -> [DeviceInfo] {
        rows.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    /// Every row, including one not named yet: a removal must find its device even before it was given a name.
    private func allDevices(_ key: String) async throws -> [DeviceInfo] {
        let r = try checked(await api("devices", key, [:]))
        if r.error != nil { throw Fail("AirVPN couldn't answer right now. Try again later") }
        guard let devices = r.devices else { throw Fail("Unexpected reply from AirVPN") }
        return devices
    }
    private enum Removal { case removed, refused, failed }
    private func remove(_ key: String, _ id: String) async -> Removal {
        do {
            for _ in 0..<30 {
                guard let d = try await allDevices(key).first(where: { $0.id == id }) else { return .removed }
                if d.status == "deleted" { return .removed }
                if d.status != "create" {
                    let r = try checked(await api("devices", key, ["action": "delete", "id": id]))
                    if r.error?.localizedCaseInsensitiveContains("unknown") == true { return .removed }
                    if r.error != nil { return .failed }
                }
                try await pause()
            }
        } catch is AuthError { return .refused }
        catch { return .failed }
        return .failed
    }
    /// Removes devices unbraid added whose removal was still owed (Sign Out of Everything, after their record is gone).
    /// False when any of them couldn't be removed.
    @concurrent func removeOwed(_ items: [AirCleanup.Record]) async -> Bool {
        var all = true
        for item in items where await remove(item.key, item.id) != .removed { all = false }
        return all
    }
    @concurrent func retryCleanup(excluding: Set<AirCleanup.Record> = []) async {
        let items: [AirCleanup.Record]
        do { items = try await journal.owed(excluding: excluding) }
        catch { Log.error("AirVPN: couldn't read cleanup journal"); return }
        for item in items {
            let result = await remove(item.key, item.id)
            if result == .failed { Log.error("AirVPN: couldn't remove owed device") }
            else {
                do {
                    try await journal.remove(item)
                    if result == .refused { cleanupWarning() }
                } catch { Log.error("AirVPN: couldn't update cleanup journal") }
            }
            await journal.finishedRetry(item)
        }
    }
    private func fromAPI(_ key: String, _ wanted: String?) async throws -> String {
        await retryCleanup()
        let rows = try await allDevices(key)
        let all = Self.named(rows)
        if wanted == nil {
            let result: Reply
            do { result = try checked(await api("devices", key, ["action": "add"])) }
            catch is AuthError { throw AuthError("AirVPN didn't accept that API key. Check it in the Client Area under API", url: "https://airvpn.org/apisettings/") }
            catch {
                // The reply may have been lost after AirVPN made the device: look for it rather than leave it behind.
                if await removeStray(key, before: rows) { throw Fail("AirVPN didn't answer while adding a device, and the one it may have added was removed. Try again") }
                throw Fail("AirVPN didn't answer while adding a device. If a new device appeared in the Client Area, remove it, then try again")
            }
            if result.error == nil {
                guard let id = result.id, !id.isEmpty else {
                    if await removeStray(key, before: rows) { throw Fail("AirVPN didn't identify the new device, and it was removed. Try again") }
                    throw Fail("AirVPN didn't identify the new device. Check the Client Area, then try again")
                }
                let item = AirCleanup.Record(key: key, id: id)
                do { try await journal.add(item) } catch {
                    let removed = await remove(key, id) == .removed
                    throw Fail(removed ? "Couldn't save the new device. Try again." : "Couldn't save or remove the new device. Check the AirVPN Client Area.")
                }
                var name = "New device"
                do {
                    var n = 1
                    while all.contains(where: { $0.name.caseInsensitiveCompare(n == 1 ? "unbraid" : "unbraid \(n)") == .orderedSame }) { n += 1 }
                    let requestedName = n == 1 ? "unbraid" : "unbraid \(n)"
                    let modified = try checked(await api("devices", key, ["action": "modify", "id": id, "name": requestedName, "description": "Removed when you sign out of unbraid"]))
                    if modified.error != nil { throw Fail("AirVPN couldn't name the device. Try again later") }
                    name = requestedName
                    let d = try await readyDevice(key, id, name)
                    return try await signed(key, d, own: true)
                } catch {
                    if await remove(key, id) == .removed {
                        do { try await journal.remove(item) }
                        catch { await journal.release(item); Log.error("AirVPN: couldn't update cleanup journal") }
                        throw error
                    }
                    await journal.release(item)
                    throw Fail("Signing in didn't finish, and unbraid couldn't remove the device it added, \(name). Remove it in the AirVPN Client Area, then try again")
                }
            }
        }
        let d: DeviceInfo
        if let wanted, !wanted.isEmpty, let found = all.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) { d = found }
        else if wanted == nil, all.count == 1 { d = all[0] }
        else if all.isEmpty { throw AuthError("AirVPN didn't add a device for unbraid and your account has none. Add one in the Client Area, then try again", url: "https://airvpn.org/devices/") }
        else if let wanted, !wanted.isEmpty {
            throw Challenge(message: "None of your AirVPN devices is named \u{201C}\(String(wanted.prefix(40)))\u{201D}. Choose one of: \(all.map { String($0.name.prefix(40)) }.joined(separator: ", ")).", field: Field(key: "device", label: "Device name", secret: false))
        }
        else { throw Challenge(message: "AirVPN didn't add a device for unbraid. Choose one of yours: \(all.map { String($0.name.prefix(40)) }.joined(separator: ", ")).", field: Field(key: "device", label: "Device name", secret: false)) }
        return try await signed(key, d, own: false)
    }
    /// After an add whose answer was lost or unusable: removes the device it may have made, but only when it can be told
    /// from anything else: exactly one device is new, it has no name yet (or AirVPN's default one), and every other
    /// device is exactly as it was. Anything less certain is left alone (a device made at the same moment by the user
    /// or another app must never be deleted), and the user is told to look. True when that one device was removed.
    private func removeStray(_ key: String, before: [DeviceInfo]) async -> Bool {
        guard let now = try? await allDevices(key) else { return false }
        let known = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let added = now.filter { known[$0.id] == nil }
        guard added.count == 1, let d = added.first, !d.id.isEmpty, now.count == before.count + 1 else { return false }
        let name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty || name.caseInsensitiveCompare("New device") == .orderedSame else { return false }
        guard now.allSatisfy({ n in n.id == d.id || known[n.id].map { $0.name == n.name && $0.key == n.key } == true }) else { return false }
        let item = AirCleanup.Record(key: key, id: d.id)
        do { try await journal.add(item) } catch { return false }
        if await remove(key, d.id) == .removed {
            do { try await journal.remove(item) } catch { await journal.release(item) }
            return true
        }
        // Still owed: kept in the journal, and free to be retried.
        await journal.release(item)
        return false
    }
    private func readyDevice(_ key: String, _ id: String, _ name: String) async throws -> DeviceInfo {
        try await withThrowingTaskGroup(of: DeviceInfo.self) { group in
            group.addTask {
                for _ in 0..<30 {
                    try await pause()
                    if let device = try await devices(key).first(where: { $0.id == id && $0.name == name && $0.status == "ready" && !($0.key ?? "").isEmpty }) { return device }
                }
                throw Fail("AirVPN is still setting up the new device. Try again in a minute")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw Fail("AirVPN is still setting up the new device. Try again in a minute")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw Fail("AirVPN didn't return a device") }
            return result
        }
    }
    private func signed(_ key: String, _ d: DeviceInfo, own: Bool) async throws -> String {
        guard let ip = d.ipv4, !ip.isEmpty, let deviceKey = d.key, !deviceKey.isEmpty else { throw Fail("AirVPN is still setting up this device. Try again later") }
        let servers = try Self.parse(await status(), serverKey: "")
        guard let server = servers.min(by: { $0.load < $1.load })?.serverName else { throw Fail("Empty AirVPN server list") }
        let data = try await api("generator", key, ["protocols": "wireguard_1_udp_1637", "servers": server, "device": d.name, "system": "linux", "resolve": "on", "iplayer_entry": "ipv4", "iplayer_exit": "ipv4"])
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            let r = try checked(data)
            if r.error != nil { throw Fail("AirVPN didn't make a config for this device. Try again later") }
        }
        var a = try keyAccount(parseKey(["key": String(decoding: data, as: UTF8.self)]))
        guard a.address.contains(where: { $0.split(separator: "/").first.map(String.init) == ip }) else { throw Fail("AirVPN sent another device's config. Try again") }
        a.apiKey = key; a.device = d.name; a.deviceKey = deviceKey; a.deviceId = d.id; a.ownDevice = own
        return JSON.encode(a)
    }

    @concurrent func signOut(_ account: String) async -> Bool {
        guard let a = try? keyAccount(account), a.ownDevice == true, let key = a.apiKey, let id = a.deviceId else { return true }
        let item = AirCleanup.Record(key: key, id: id)
        let result = await remove(key, id)
        guard result != .failed else { await journal.release(item); return false }
        do { try await journal.remove(item); return result == .removed }
        catch { await journal.release(item); Log.error("AirVPN: couldn't update cleanup journal"); return false }
    }
    @concurrent func revoked(_ account: String) async throws -> Bool {
        guard let a = try? keyAccount(account), let key = a.apiKey, let id = a.deviceId, let old = a.deviceKey,
              let all = try? await devices(key) else { return false }
        return !all.contains { $0.id == id && $0.key == old }
    }
    @concurrent func device(_ account: String) async throws -> String? {
        let a = try keyAccount(account)
        guard let d = a.device else { return nil }
        return "\(a.ownDevice == true ? "Its own device, \(d), removed when you sign out" : "Uses your device \(d)"). See all your devices in the AirVPN Client Area"
    }
    @concurrent func plan(_ account: String) async throws -> String? {
        guard let key = try keyAccount(account).apiKey else { return nil }
        let data = try await api("userinfo", key, [:]); let info = try JSON.decode(UserInfo.self, data, "AirVPN")
        if info.error != nil { _ = try checked(data); throw Fail("AirVPN couldn't answer right now. Try again later") }
        guard let u = info.user, u.premium == true, let expiration = u.expiration_unix, expiration > 0 else { return "No active plan" }
        return "\(Date().timeIntervalSince1970 > Double(expiration) ? "Ended on" : "Paid until") \(ProviderStatus.publishedOn(expiration))"
    }
    /// The connections the account has open now, every app's, as AirVPN counts them. Nil when it can't say: no API key
    /// (a pasted config), AirVPN refusing or failing. An error reply is never read as none in use.
    @concurrent func inUse(_ account: String) async throws -> Int? {
        guard let key = try keyAccount(account).apiKey else { return nil }
        guard let info = try? JSON.decode(UserInfo.self, try await api("userinfo", key, [:]), "AirVPN"), info.error == nil else { return nil }
        return info.sessions?.count
    }

    /// WireGuard on 1637 and 47107, and 51820 on the alternative entry. OpenVPN comes from AirVPN's generator, made for this device when a route connects: UDP
    /// 443 on the standard entry (tls-auth), TCP 443 on the alternative one (tls-crypt, which hides even the OpenVPN
    /// start). It needs the API key. Automatic is WireGuard, and OpenVPN TCP once a network blocks it (`AutoProtocol`).
    var protocols: [ProtocolChoice] {
        [ProtocolChoice(key: nil, label: "WireGuard", note: "Fastest"),
         ProtocolChoice(key: "openvpn_udp", label: "OpenVPN UDP", note: "Wider compatibility. Needs the API key sign-in"),
         ProtocolChoice(key: "openvpn_tcp", label: "OpenVPN TCP", note: "For networks that block VPNs. Much slower than the others. Needs the API key sign-in"),
         ProtocolChoice(key: AutoProtocol.key, label: "Automatic", note: "WireGuard, then the slower OpenVPN TCP when a network blocks it. TCP needs the API key sign-in")]
    }

    /// The generator's protocol for a route protocol, the entry it dials (1 standard, 2 alternative, in the order of the
    /// server's addresses), its transport and its wrapper.
    struct OpenVpnKind: Sendable {
        let generator: String
        let entry: Int
        let transport: String
        let wrap: String
    }
    static let openVpn: [String: OpenVpnKind] = [
        "openvpn_udp": OpenVpnKind(generator: "openvpn_1_udp_443", entry: 1, transport: "udp", wrap: "tls-auth"),
        "openvpn_tcp": OpenVpnKind(generator: "openvpn_3_tcp_443", entry: 2, transport: "tcp", wrap: "tls-crypt"),
    ]
    /// A port the servers take on one entry address only, with that entry's number (1 standard, 2 alternative, in the order
    /// of the server's addresses). A tunnel that doesn't know that entry takes another port instead.
    static let portEntry: [Int: Int] = [51820: 2]
    static let noKey = "AirVPN's OpenVPN needs a sign-in with an API key. Sign in again with one, or choose WireGuard for this route"

    /// Whether the signed-in account can ask for OpenVPN profiles: it has an API key and a device.
    static func canOpenVpn(_ account: String) -> Bool {
        guard let a = try? AirVpn().keyAccount(account) else { return false }
        return a.apiKey != nil && a.device != nil
    }

    /// A WireGuard route as `KeyProvider` has it; an OpenVPN one takes the same server, with a profile the generator makes
    /// for this device.
    @concurrent func connect(_ loc: Location, _ account: String) async throws -> Link {
        let a = try keyAccount(account)
        // Automatic is resolved per route before connecting (`AutoProtocol.of`): anything else asking for it gets WireGuard.
        var loc = loc
        let choice = loc.proto == AutoProtocol.key ? nil : loc.proto
        loc.proto = nil
        var kind: OpenVpnKind?
        if let choice {
            guard let k = Self.openVpn[choice] else { throw Unsupported("AirVPN doesn't offer that protocol. Choose another in the route") }
            guard a.apiKey != nil, a.device != nil else { throw Unsupported(Self.noKey) }
            kind = k
        }
        let all: [Catalog.Entry]?
        if loc.pinned == nil { all = try await entries(a) } else { all = try? await entries(a) }
        let link = try await link(loc, a) { if let all { return all }; throw Fail("AirVPN server list unavailable") }
        guard case .wg(let sv, let peer, _, _) = link else { return link }
        let offered: [Int] = (a.port == 47107 ? [47107, 1637] : [1637, 47107]) + [51820]
        let found = all?.first { $0.ips.contains(sv.ip) && $0.serverName == sv.name }
        let addresses = found?.ips.count == 2 ? found!.ips : []
        guard let kind, let key = a.apiKey else { return .wg(sv, peer, ports: offered, entries: addresses) }
        return try await openVpnLink(sv, a, key, kind, addresses)
    }

    private func openVpnLink(_ sv: Server, _ a: KeyAccount, _ key: String, _ kind: OpenVpnKind, _ addresses: [String]) async throws -> Link {
        // The device by its id (or name and key): a renamed one gets its new name, and the generator never falls back to Default.
        guard let d = try await devices(key).first(where: { ($0.id == a.deviceId || (a.deviceId == nil && $0.name == a.device)) && $0.key == a.deviceKey }) else {
            throw AuthError("unbraid's AirVPN device is gone or was renewed. Sign in to AirVPN again", url: deviceURL)
        }
        let at = kind.entry == 1 ? addresses.first ?? sv.ip : addresses.dropFirst().first
        guard let at else { throw Fail("AirVPN's server list can't be read right now, and OpenVPN TCP needs it to check \(sv.name). Try again later") }
        guard Catalog.Entry.publicIPv4(at) else { throw Fail("\(sv.name) can't be reached right now") }
        let data = try await api("generator", key, ["protocols": kind.generator, "servers": sv.name, "device": d.name, "system": "linux",
                                                    "resolve": "on", "iplayer_entry": "ipv4", "iplayer_exit": "ipv4"])
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            _ = try checked(data)
            throw Fail("AirVPN didn't make an OpenVPN profile for \(sv.name). Try again later")
        }
        let mismatch = Fail("AirVPN's OpenVPN profile doesn't match \(sv.name). Try again")
        guard let profile = try? Manual.parseOvpn(text, name: sv.name, username: "", password: "") else { throw mismatch }
        guard Self.dialled(profile, at: at, kind) != nil else { throw mismatch }
        return .ovpn(sv, profile)
    }

    // MARK: Server history

    var reportsQuality: Bool { true }
    /// AirVPN's public history of one server, no login: delay and packet loss, hourly, over a week.
    var history: @Sendable (String) async throws -> Data = { name in
        try await Http.get("https://airvpn.org/api/server/?name=\(Http.enc(name))&range=week&window=3600&panels=ploss,rtt&format=json")
    }
    private static let qualities = Mutex<[String: (at: Date, quality: Quality)]>([:])
    static let qualityKept: TimeInterval = 600

    /// The server's last week as AirVPN measured it. Kept ten minutes per server; nil when the name is odd or AirVPN can't say.
    @concurrent func quality(_ server: String) async -> Quality? {
        guard server.wholeMatch(of: /[A-Za-z][A-Za-z0-9]{1,30}/) != nil else { return nil }
        if let kept = Self.qualities.withLock({ $0[server] }), Date().timeIntervalSince(kept.at) < Self.qualityKept { return kept.quality }
        guard let data = try? await history(server), let found = try? Self.parseQuality(data) else { return nil }
        Self.qualities.withLock { $0[server] = (Date(), found) }
        return found
    }

    /// The two series as values, oldest first; a missing or non-numeric sample is NaN (a gap, not zero). Nil on an error
    /// reply, or when neither series has a sample.
    static func parseQuality(_ body: Data) throws -> Quality? {
        guard let root = try JSON.object(body, "AirVPN") as? [String: Any] else { throw Fail("Unexpected reply from AirVPN") }
        if root["error"] != nil { return nil }
        func values(_ panel: String, _ series: String) -> [Float] {
            let rows = (((root["panels"] as? [String: Any])?[panel] as? [String: Any])?["series"] as? [String: Any])?[series] as? [Any] ?? []
            return rows.map { row in
                guard let pair = row as? [Any], pair.count > 1 else { return .nan }
                let v: Double?
                if let n = pair[1] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { v = n.doubleValue }
                else if let t = pair[1] as? String { v = Double(t) }
                else { v = nil }
                return v.flatMap { $0.isFinite && $0 >= 0 ? Float($0) : nil } ?? .nan
            }
        }
        let delay = values("rtt", "rtt"), loss = values("ploss", "ploss")
        return delay.isEmpty && loss.isEmpty ? nil : Quality(delay: delay, loss: loss, days: 7)
    }

    /// The one address a profile dials, read from what the engine will run (the parsed profile, never the text): a single
    /// remote, public, on port 443, over the kind's transport, with its wrapper, and nothing the import check calls weak.
    /// `at`: the address it has to be (any public one when nil). Nil when anything differs.
    static func dialled(_ p: OvpnProfile, at: String?, _ kind: OpenVpnKind) -> String? {
        guard let endpoint = try? Manual.ovpnEndpoint("check", p) else { return nil }
        // A profile the import would warn about is refused here: nobody is asked about one unbraid made itself.
        do { guard try Manual.weakness(p) == nil else { return nil } } catch { return nil }
        let rows = endpoint["servers"]?.list ?? [endpoint]
        guard rows.count == 1, let host = rows[0]["server"]?.str, rows[0]["server_port"]?.int == 443,
              rows[0]["network"]?.str?.hasPrefix(kind.transport) == true, Catalog.Entry.publicIPv4(host), at.map({ $0 == host }) ?? true,
              endpoint["tls"]?["control_wrap"]?["type"]?.str == kind.wrap.replacingOccurrences(of: "-", with: "_") else { return nil }
        return host
    }

    private struct Node: Decodable {
        var name: String
        var country: String
        var code: String
        var location: String
        var continent: String
        var ip: String
        var ip3: String
        var health: String
        /// Why a server isn't `ok`, such as "Low packet loss".
        var warning: String
        var load: Int?
        enum CodingKeys: String, CodingKey {
            case name = "public_name", country = "country_name", code = "country_code", location, continent
            case ip = "ip_v4_in1", ip3 = "ip_v4_in3", health, warning, load = "currentload"
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            name = try c.contains(.name) ? c.decode(String.self, forKey: .name) : ""
            country = try c.contains(.country) ? c.decode(String.self, forKey: .country) : ""
            code = try c.contains(.code) ? c.decode(String.self, forKey: .code) : ""
            location = try c.contains(.location) ? c.decode(String.self, forKey: .location) : ""
            continent = try c.contains(.continent) ? c.decode(String.self, forKey: .continent) : ""
            ip = try c.contains(.ip) ? c.decode(String.self, forKey: .ip) : ""
            ip3 = try c.decodeIfPresent(String.self, forKey: .ip3) ?? ""
            health = try c.contains(.health) ? c.decode(String.self, forKey: .health) : ""
            warning = (try? c.decodeIfPresent(String.self, forKey: .warning)) ?? ""
            load = try c.decodeIfPresent(Int.self, forKey: .load)
        }
    }

    private struct Status: Decodable {
        var servers: [Node]
        enum CodingKeys: String, CodingKey { case servers }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            servers = try c.contains(.servers) ? c.decode([Node].self, forKey: .servers) : []
        }
    }

    static func parse(_ body: Data, serverKey: String) throws -> [Catalog.Entry] {
        // `error` refuses connections; `warning` works, with a problem it names: kept, picked after the healthy ones.
        try JSON.decode(Status.self, body, "AirVPN").servers.filter {
            ($0.health == "ok" || $0.health == "warning") && $0.ip.contains(".") &&
            !$0.country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map { node -> Catalog.Entry in
            var entry = entry(node, serverKey)
            if node.health == "warning" {
                let why = node.warning.trimmingCharacters(in: .whitespacesAndNewlines)
                entry.warning = why.isEmpty ? "Warning" : String(why.prefix(80))
            }
            return entry
        }
    }

    private static func entry(_ n: Node, _ serverKey: String) -> Catalog.Entry {
        // Only public addresses: the second is dialled as the "Entry address" option, so it must be as safe as the first.
        let ips = [n.ip] + (n.ip3 != n.ip ? [n.ip3] : [])
        let city = n.location.replacingOccurrences(of: ", ", with: " ").replacingOccurrences(of: ",", with: "")
        return Catalog.Entry(vpn: "wireguard", country: n.country, region: n.continent,
                             city: city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : city,
                             serverName: n.name, hostname: "\(n.code).vpn.airdns.org", wgpubkey: serverKey, ips: ips.filter(Catalog.Entry.publicIPv4),
                             load: n.load.map { min(max($0, 0), 100) } ?? -1)
    }
}
