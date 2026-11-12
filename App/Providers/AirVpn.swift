import Foundation

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
        guard case .wg(let server, let peer, let ports, let entries) = link, let a = try? keyAccount(account),
              Catalog.Entry.publicIPv4(server.ip), let colon = peer.endpoint.lastIndex(of: ":"),
              let port = Int(peer.endpoint[peer.endpoint.index(after: colon)...]) else { return false }
        let host = String(peer.endpoint[..<colon])
        guard host == server.ip || (entries.contains(host) && Catalog.Entry.publicIPv4(host)) else { return false }
        guard port == a.port || ([1637, 47107].contains(port) && ports.contains(port)) else { return false }
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
    struct UserInfo: Decodable { struct User: Decodable { var premium: Bool?; var expiration_unix: Int64? }; var user: User?; var error: String? }
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
    @concurrent func connect(_ loc: Location, _ account: String) async throws -> Link {
        let a = try keyAccount(account)
        let all: [Catalog.Entry]?
        if loc.pinned == nil { all = try await entries(a) } else { all = try? await entries(a) }
        let link = try await link(loc, a) { if let all { return all }; throw Fail("AirVPN server list unavailable") }
        guard case .wg(let sv, let peer, _, _) = link else { return link }
        let offered = a.port == 47107 ? [47107, 1637] : [1637, 47107]
        let found = all?.first { $0.ips.contains(sv.ip) && $0.serverName == sv.name }
        let addresses = found?.ips.count == 2 ? found!.ips : []
        return .wg(sv, peer, ports: offered, entries: addresses)
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
        var load: Int?
        enum CodingKeys: String, CodingKey {
            case name = "public_name", country = "country_name", code = "country_code", location, continent
            case ip = "ip_v4_in1", ip3 = "ip_v4_in3", health, load = "currentload"
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
        try JSON.decode(Status.self, body, "AirVPN").servers.filter {
            $0.health == "ok" && $0.ip.contains(".") &&
            !$0.country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map {
            // Only public addresses: the second is dialled as the "Entry address" option, so it must be as safe as the first.
            let ips = [$0.ip] + ($0.ip3 != $0.ip ? [$0.ip3] : [])
            let city = $0.location.replacingOccurrences(of: ", ", with: " ").replacingOccurrences(of: ",", with: "")
            return Catalog.Entry(vpn: "wireguard", country: $0.country, region: $0.continent,
                                 city: city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : city,
                                 serverName: $0.name, hostname: "\($0.code).vpn.airdns.org", wgpubkey: serverKey, ips: ips.filter(Catalog.Entry.publicIPv4),
                                 load: $0.load.map { min(max($0, 0), 100) } ?? -1)
        }
    }
}
