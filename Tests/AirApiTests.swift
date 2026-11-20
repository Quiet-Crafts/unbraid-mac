import CryptoKit
import Foundation
import Synchronization
import XCTest

private actor FakeAir {
    var devices: [(id: String, name: String, ip: String, key: String)] = [("old", "Default", "10.0.0.1", "oldkey")]
    var refuse = false
    var generatorFails = false
    var deleteFails = false
    var wrongAddress = false
    var added = 0
    var refusedKey: String?
    /// Open connections `userinfo` lists (nil: none listed at all); an error reply when `userinfoFails`.
    var sessions: Int? = 3
    var userinfoFails = false
    func configure(refuse: Bool = false, generatorFails: Bool = false, deleteFails: Bool = false) {
        self.refuse = refuse; self.generatorFails = generatorFails; self.deleteFails = deleteFails
    }
    func call(_ service: String, _ key: String, _ query: [String: String]) throws -> Data {
        if service == "devices", key == refusedKey { return Data(#"{"error":"Not authorized"}"#.utf8) }
        switch service {
        case "devices":
            switch query["action"] {
            case "add":
                if refuse { return Data(#"{"error":"Too many devices"}"#.utf8) }
                added += 1; devices.append(("new", "New device", "10.0.0.2", "newkey"))
                return Data(#"{"id":"new"}"#.utf8)
            case "modify":
                if let i = devices.firstIndex(where: { $0.id == query["id"] }) { devices[i].name = query["name"] ?? "" }
                return Data(#"{}"#.utf8)
            case "delete":
                if deleteFails { return Data(#"{"error":"Try later"}"#.utf8) }
                devices.removeAll { $0.id == query["id"] }
                return Data(#"{}"#.utf8)
            default:
                let rows = devices.map { ["id": $0.id, "name": $0.name, "status": "ready", "wireguard_public_key": $0.key, "wireguard_ipv4": $0.ip] }
                return try JSONSerialization.data(withJSONObject: ["devices": rows])
            }
        case "generator":
            if generatorFails { return Data(#"{"error":"failed"}"#.utf8) }
            let ip = wrongAddress ? "10.99.0.1" : (devices.first { $0.name == query["device"] }?.ip ?? "10.0.0.1")
            return Data(ProviderFixtures.conf("\(ip)/32", endpoint: "1.2.3.4:1637", preshared: true).utf8)
        case "userinfo":
            if userinfoFails { return Data(#"{"error":"Try later"}"#.utf8) }
            let list = sessions.map { n in #","sessions":[\#((0..<n).map { #"{"id":\#($0),"server":"Alpha"}"# }.joined(separator: ","))]"# } ?? ""
            return Data(#"{"user":{"premium":true,"expiration_unix":1795348998}\#(list)}"#.utf8)
        default: throw Fail("Unexpected fixture call")
        }
    }
    func returnWrongAddress() { wrongAddress = true }
    func setUp(sessions: Int?? = nil, userinfoFails: Bool? = nil) {
        if let sessions { self.sessions = sessions }
        if let userinfoFails { self.userinfoFails = userinfoFails }
    }
    func names() -> [String] { devices.map(\.name) }
    func addAnonymousDevice() { devices.append(("other", "New device", "10.0.0.9", "otherkey")) }
    func addUserDevice() { devices.append(("phone", "Phone", "10.0.0.3", "phonekey")) }
    func rekey() { if devices.count > 1 { devices[devices.count - 1].key = "changed" } }
    func reject(_ key: String) { refusedKey = key }
}

final class AirApiTests: XCTestCase {
    private let key = String(repeating: "a", count: 64)
    private func provider(_ fake: FakeAir) throws -> (AirVpn, AirCleanup, URL) {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "build/air-test-\(UUID().uuidString)")
        let journal = AirCleanup(vault: Sealed(dir: dir, key: { SymmetricKey(data: Data(repeating: 1, count: 32)) }))
        var p = AirVpn(); p.journal = journal
        p.api = { service, key, query in try await fake.call(service, key, query) }
        p.pause = {}
        p.status = { Data(#"{"servers":[{"public_name":"Alpha","country_name":"Netherlands","country_code":"NL","location":"Amsterdam","continent":"Europe","ip_v4_in1":"1.2.3.4","ip_v4_in3":"1.2.3.5","health":"ok","currentload":1}]}"#.utf8) }
        return (p, journal, dir)
    }
    func testCreatedDeviceRecordedAndRemoved() async throws {
        let fake = FakeAir(); let (p, journal, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try await p.signIn(["key": key]); let a = try p.keyAccount(blob)
        XCTAssertEqual(a.device, "unbraid"); XCTAssertEqual(a.address, ["10.0.0.2/32"])
        let records = try await journal.records(); XCTAssertEqual(records.count, 1)
        let revoked = try await p.revoked(blob); XCTAssertFalse(revoked)
        let link = try await p.connect(Location(provider: "airvpn"), blob)
        guard case .wg(_, _, let ports, let entries) = link else { return XCTFail("not WireGuard") }
        XCTAssertEqual(ports, [1637, 47107, 51820]); XCTAssertEqual(entries, ["1.2.3.4", "1.2.3.5"])
        let removed = await p.signOut(blob); XCTAssertTrue(removed)
        let names = await fake.names(); XCTAssertEqual(names, ["Default"])
        let left = try await journal.records(); XCTAssertTrue(left.isEmpty)
    }
    func testFailedSignInRetainsDeviceWhenRemovalFailsAndRetries() async throws {
        let fake = FakeAir(); await fake.configure(generatorFails: true, deleteFails: true)
        let (p, journal, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        do { _ = try await p.signIn(["key": key]); XCTFail("accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("Client Area")) }
        let pending = try await journal.records(); XCTAssertEqual(pending.count, 1)
        await fake.configure(refuse: true)
        _ = try await p.signIn(["key": key])
        let left = try await journal.records(); XCTAssertTrue(left.isEmpty)
        let names = await fake.names(); XCTAssertEqual(names, ["Default"])
    }
    func testRefusedSignOutIsNotRetried() async throws {
        let fake = FakeAir(); var (p, journal, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try await p.signIn(["key": key])
        await fake.reject(key)
        let warnings = Mutex(0)
        p.cleanupWarning = { warnings.withLock { $0 += 1 } }
        let removed = await p.signOut(blob)
        XCTAssertFalse(removed)
        let records = try await journal.records()
        XCTAssertTrue(records.isEmpty)
        await p.retryCleanup()
        XCTAssertEqual(warnings.withLock { $0 }, 0)
    }

    func testMalformedDeviceRowsAreIgnored() async throws {
        let fake = FakeAir(); var (p, _, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        p.api = { service, key, query in
            if service == "devices" && query.isEmpty { return Data(#"{"devices":[{}, {"id":"", "name":"bad"}, {"id":"bad", "name":"", "wireguard_public_key":"badkey"}, {"id":"old","name":"Default","wireguard_public_key":"oldkey"}]}"#.utf8) }
            return try await fake.call(service, key, query)
        }
        let decoded = try JSONDecoder().decode(AirVpn.DeviceInfo.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.status, "")
        var account = try p.keyAccount(p.parseKey(["key": ProviderFixtures.conf("10.0.0.1/32", endpoint: "1.2.3.4:1637", preshared: true)]))
        account.apiKey = key; account.deviceId = "old"; account.deviceKey = "oldkey"
        let revoked = try await p.revoked(JSON.encode(account))
        XCTAssertFalse(revoked)
        account.deviceId = "bad"; account.deviceKey = "badkey"
        let invalidRevoked = try await p.revoked(JSON.encode(account))
        XCTAssertTrue(invalidRevoked)
    }

    /// Servers share one host name per country: a pin is found by host and name, and one whose name is gone is not
    /// matched to another server that now has its address.
    func testPinOnASharedHostIsNotFoundByAddressAlone() async throws {
        let key = String(repeating: "A", count: 43) + "="
        let nl = ["Alpha": "203.0.113.1", "Beta": "203.0.113.2"].map { name, ip in
            Catalog.Entry(vpn: "wireguard", country: "Netherlands", serverName: name, hostname: "nl.example.net", wgpubkey: key, ips: [ip])
        }
        let account = KeyAccount(privateKey: key, address: ["10.0.0.2/32"], dns: ["10.0.0.1"], port: 1637, mtu: 1420)
        let p = AirVpn()
        func pinned(_ name: String, ip: String) -> Location {
            Location(provider: "airvpn", pinned: Server(name: name, host: "nl.example.net", ip: ip, publicKey: key, load: 0))
        }
        let found = try await p.link(pinned("Beta", ip: "203.0.113.9"), account) { nl }
        XCTAssertEqual(found.server.name, "Beta")
        await ProviderFixtures.rejects { _ = try await p.link(pinned("Gamma", ip: "203.0.113.2"), account) { nl } }
    }

    func testOldAccountDecodes() throws {
        let old = #"{"privateKey":"p","address":[],"dns":[],"port":1637,"mtu":1420}"#
        let a = try AirVpn().keyAccount(old)
        XCTAssertNil(a.apiKey); XCTAssertNil(a.ownDevice)
    }
    func testAddWhoseReplyWasLostIsFoundAndRemoved() async throws {
        let fake = FakeAir(); var (p, journal, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        p.api = { service, key, query in
            let reply = try await fake.call(service, key, query)
            if query["action"] == "add" { throw URLError(.networkConnectionLost) }
            return reply
        }
        do { _ = try await p.signIn(["key": key]); XCTFail("accepted") } catch {
            XCTAssertFalse(error.localizedDescription.contains("remove it"), error.localizedDescription)
        }
        let names = await fake.names(); XCTAssertEqual(names, ["Default"])
        let left = try await journal.records(); XCTAssertTrue(left.isEmpty)
    }

    /// Two new unnamed devices after a lost reply: one is ours, one is not, and nothing says which. Neither is deleted.
    func testLostAddWithAnotherNewDeviceDeletesNothing() async throws {
        let fake = FakeAir(); var (p, journal, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        p.api = { service, key, query in
            let reply = try await fake.call(service, key, query)
            if query["action"] == "add" { await fake.addAnonymousDevice(); throw URLError(.networkConnectionLost) }
            return reply
        }
        do { _ = try await p.signIn(["key": key]); XCTFail("accepted") } catch {
            XCTAssertTrue(error.localizedDescription.contains("Client Area"), error.localizedDescription)
        }
        let names = await fake.names(); XCTAssertEqual(names, ["Default", "New device", "New device"])
        let left = try await journal.records(); XCTAssertTrue(left.isEmpty)
    }

    /// A device of the user's that appeared (or changed) during the add makes the picture ambiguous: nothing is deleted.
    func testLostAddWithAUserDeviceAppearingDeletesNothing() async throws {
        let fake = FakeAir(); var (p, journal, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        p.api = { service, key, query in
            let reply = try await fake.call(service, key, query)
            if query["action"] == "add" { await fake.addUserDevice(); throw URLError(.networkConnectionLost) }
            return reply
        }
        do { _ = try await p.signIn(["key": key]); XCTFail("accepted") } catch {
            XCTAssertTrue(error.localizedDescription.contains("Client Area"), error.localizedDescription)
        }
        let names = await fake.names(); XCTAssertEqual(names, ["Default", "New device", "Phone"])
        let left = try await journal.records(); XCTAssertTrue(left.isEmpty)
    }

    func testLostAddWhoseDeviceCannotBeRemovedStaysJournaled() async throws {
        let fake = FakeAir(); var (p, journal, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        p.api = { service, key, query in
            let reply = try await fake.call(service, key, query)
            if query["action"] == "add" { await fake.configure(deleteFails: true); throw URLError(.timedOut) }
            return reply
        }
        do { _ = try await p.signIn(["key": key]); XCTFail("accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("Client Area")) }
        let pending = try await journal.records(); XCTAssertEqual(pending.count, 1)
    }

    func testNameThatMatchesNoDeviceSaysSo() async throws {
        let fake = FakeAir(); await fake.addUserDevice(); await fake.configure(refuse: true)
        let (p, _, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        do { _ = try await p.signIn(["key": key, "device": "Fone"]); XCTFail("expected challenge") }
        catch let c as Challenge {
            XCTAssertTrue(c.message.hasPrefix("None of your AirVPN devices is named \u{201C}Fone\u{201D}."), c.message)
            XCTAssertTrue(c.message.contains("Phone"))
        }
    }

    func testRefusedAddAsksAndUsesOnlyListedDevice() async throws {
        let fake = FakeAir(); await fake.addUserDevice(); await fake.configure(refuse: true)
        let (p, _, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        do { _ = try await p.signIn(["key": key]); XCTFail("expected challenge") }
        catch let c as Challenge { XCTAssertEqual(c.field.label, "Device name") }
        let blob = try await p.signIn(["key": key, "device": "phone"])
        XCTAssertEqual(try p.keyAccount(blob).device, "Phone")
        let removed = await p.signOut(blob); XCTAssertTrue(removed)
        let names = await fake.names(); XCTAssertEqual(names, ["Default", "Phone"])
        await fake.rekey()
        let revoked = try await p.revoked(blob); XCTAssertTrue(revoked)
    }
    func testUnreadableJournalIsPreservedAndSignInContinues() async throws {
        let fake = FakeAir(); let (p, journal, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("damaged".utf8).write(to: dir.appending(path: "airvpn-devices.bin"))
        _ = try await p.signIn(["key": key])
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "airvpn-devices.bin.bad")), Data("damaged".utf8))
        let records = try await journal.records(); XCTAssertEqual(records.count, 1)
        XCTAssertTrue(Store.credentialFiles.contains("airvpn-devices.bin.bad"))
    }

    func testUnavailableKeyKeepsJournalInPlace() async throws {
        let (_, _, dir) = try provider(FakeAir()); defer { try? FileManager.default.removeItem(at: dir) }
        let original = Data("sealed".utf8)
        try original.write(to: dir.appending(path: "airvpn-devices.bin"))
        let journal = AirCleanup(vault: Sealed(dir: dir, key: { nil }))
        do { _ = try await journal.records(); XCTFail("expected unavailable key") } catch { }
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "airvpn-devices.bin")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "airvpn-devices.bin.bad").path))
    }

    func testJournalSealedWithOldKeyIsMovedAside() async throws {
        let (_, journal, dir) = try provider(FakeAir()); defer { try? FileManager.default.removeItem(at: dir) }
        let old = Sealed(dir: dir, key: { SymmetricKey(data: Data(repeating: 2, count: 32)) })
        XCTAssertTrue(old.write("airvpn-devices.bin", Data("[]".utf8)))
        let original = try Data(contentsOf: dir.appending(path: "airvpn-devices.bin"))
        let records = try await journal.records(); XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "airvpn-devices.bin.bad")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "airvpn-devices.bin").path))
    }

    func testRetryGivesUpRefusedKeyAndKeepsActiveDevice() async throws {
        let fake = FakeAir(); var (p, journal, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        let rejected = AirCleanup.Record(key: "rejected", id: "old")
        let active = AirCleanup.Record(key: key, id: "old")
        try await journal.add(rejected); try await journal.add(active)
        await journal.release(rejected); await journal.release(active)
        await fake.reject("rejected")
        let warnings = Mutex(0)
        p.cleanupWarning = { warnings.withLock { $0 += 1 } }
        await p.retryCleanup(excluding: [active])
        XCTAssertEqual(warnings.withLock { $0 }, 1)
        let left = try await journal.records(); XCTAssertEqual(left, [active])
        await p.retryCleanup(excluding: [active])
        let names = await fake.names(); XCTAssertEqual(names, ["Default"])
    }

    func testNonSecretChallengeAnswerIsTrimmed() {
        XCTAssertEqual(challengeAnswer(Field(key: "device", label: "Device name", secret: false), "  Phone \n"), "Phone")
        XCTAssertEqual(challengeAnswer(Field(key: "code", label: "Code"), " 123 "), " 123 ")
    }

    func testRetryLeavesNewDeviceInUseUntilReleased() async throws {
        let fake = FakeAir(); let (p, journal, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        let item = AirCleanup.Record(key: key, id: "old")
        try await journal.add(item)
        await p.retryCleanup()
        let kept = try await journal.records(); XCTAssertEqual(kept, [item])
        let before = await fake.names(); XCTAssertEqual(before, ["Default"])
        await journal.release(item)
        await p.retryCleanup()
        let left = try await journal.records(); XCTAssertTrue(left.isEmpty)
        let after = await fake.names(); XCTAssertTrue(after.isEmpty)
    }

    func testConcurrentRetriesClaimEachRecordOnce() async throws {
        let (_, journal, dir) = try provider(FakeAir()); defer { try? FileManager.default.removeItem(at: dir) }
        let item = AirCleanup.Record(key: key, id: "old")
        try await journal.add(item); await journal.release(item)
        let first = try await journal.owed(excluding: []); XCTAssertEqual(first, [item])
        let second = try await journal.owed(excluding: []); XCTAssertTrue(second.isEmpty)
        await journal.finishedRetry(item)
        let later = try await journal.owed(excluding: []); XCTAssertEqual(later, [item])
    }

    func testRemovingForgottenRecordDoesNotRecreateJournal() async throws {
        let (_, journal, dir) = try provider(FakeAir()); defer { try? FileManager.default.removeItem(at: dir) }
        let item = AirCleanup.Record(key: key, id: "old")
        try await journal.add(item)
        _ = try await journal.beginForgetting()
        try FileManager.default.removeItem(at: dir.appending(path: "airvpn-devices.bin"))
        try await journal.remove(item)
        await journal.resumeWrites()
        try await journal.remove(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "airvpn-devices.bin").path))
    }

    func testFailedOwedRemovalDoesNotBlockSignIn() async throws {
        let fake = FakeAir(); await fake.configure(refuse: true, deleteFails: true)
        let (p, journal, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        let item = AirCleanup.Record(key: key, id: "old")
        try await journal.add(item); await journal.release(item)
        let blob = try await p.signIn(["key": key])
        XCTAssertEqual(try p.keyAccount(blob).device, "Default")
        let left = try await journal.records(); XCTAssertEqual(left, [item])
    }

    func testJournalUpdateFailureDoesNotAbortSignIn() async throws {
        let fake = FakeAir(); await fake.configure(refuse: true)
        var (p, journal, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        let item = AirCleanup.Record(key: key, id: "missing")
        try await journal.add(item); await journal.release(item)
        let locked = Mutex(false)
        p.journal = AirCleanup(vault: Sealed(dir: dir, key: { locked.withLock { $0 } ? nil : SymmetricKey(data: Data(repeating: 1, count: 32)) }))
        p.api = { service, key, query in
            let result = try await fake.call(service, key, query)
            if service == "devices", query.isEmpty { locked.withLock { $0 = true } }
            return result
        }
        let blob = try await p.signIn(["key": key])
        XCTAssertEqual(try p.keyAccount(blob).device, "Default")
    }

    func testWrongDeviceConfigIsRejectedAndCreatedDeviceRemoved() async throws {
        let fake = FakeAir(); await fake.returnWrongAddress()
        let (p, journal, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        do { _ = try await p.signIn(["key": key]); XCTFail("accepted another device's address") }
        catch { XCTAssertTrue(error.localizedDescription.contains("another device")) }
        let names = await fake.names(); XCTAssertEqual(names, ["Default"])
        let records = try await journal.records(); XCTAssertTrue(records.isEmpty)
    }

}

/// What the AirVPN API was asked for the OpenVPN tests, and what its generator answers.
private final class Spy: Sendable {
    let generator = Mutex<[[String: String]]>([])
    let calls = Mutex<Int>(0)
    /// The generator's answer to a request for the given generator protocol.
    let reply = Mutex<@Sendable (String) -> String>({ $0.contains("tcp") ? Fixture.text("ovpn/airvpn.tcp.ovpn") : Fixture.text("ovpn/airvpn.udp.ovpn") })
    var asked: [[String: String]] { generator.withLock { $0 } }
}

final class AirVpnOpenVpnTests: XCTestCase {
    private let key = String(repeating: "a", count: 64)
    private let nl = Location(provider: "airvpn", country: "Netherlands")

    override func setUp() { AutoProtocol.reset() }
    override func tearDown() { AutoProtocol.reset() }

    private func provider(_ fake: FakeAir, _ spy: Spy) -> (AirVpn, URL) {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "build/air-test-\(UUID().uuidString)")
        var p = AirVpn()
        p.journal = AirCleanup(vault: Sealed(dir: dir, key: { SymmetricKey(data: Data(repeating: 1, count: 32)) }))
        p.api = { service, key, query in
            spy.calls.withLock { $0 += 1 }
            if service == "generator", let proto = query["protocols"], proto.hasPrefix("openvpn") {
                spy.generator.withLock { $0.append(query) }
                return Data(spy.reply.withLock { $0 }(proto).utf8)
            }
            return try await fake.call(service, key, query)
        }
        p.pause = {}
        p.status = { Data(#"{"servers":[{"public_name":"Alpha","country_name":"Netherlands","country_code":"NL","location":"Amsterdam","continent":"Europe","ip_v4_in1":"1.2.3.4","ip_v4_in3":"1.2.3.5","health":"ok","currentload":1}]}"#.utf8) }
        return (p, dir)
    }

    private func signedIn() async throws -> (AirVpn, String, FakeAir, Spy, URL) {
        let fake = FakeAir(), spy = Spy()
        let (p, dir) = provider(fake, spy)
        let blob = try await p.signIn(["key": key])
        return (p, blob, fake, spy, dir)
    }

    /// The profile is made for this device and server by the generator, and checked to reach the entry its kind uses.
    func testAnOpenVpnRouteUsesAProfileMadeForTheDevice() async throws {
        let (p, blob, _, spy, dir) = try await signedIn(); defer { try? FileManager.default.removeItem(at: dir) }
        var loc = nl
        loc.proto = "openvpn_tcp"
        guard case .ovpn(let sv, let tcp) = try await p.connect(loc, blob) else { return XCTFail("not OpenVPN") }
        XCTAssertEqual(spy.asked.last?["protocols"], "openvpn_3_tcp_443")
        XCTAssertEqual(spy.asked.last?["servers"], "Alpha"); XCTAssertEqual(spy.asked.last?["device"], "unbraid")
        XCTAssertEqual(sv.name, "Alpha")
        XCTAssertTrue(tcp.config.contains("<tls-crypt>"))
        XCTAssertEqual(tcp.username, ""); XCTAssertEqual(tcp.password, "")
        loc.proto = "openvpn_udp"
        guard case .ovpn(_, let udp) = try await p.connect(loc, blob) else { return XCTFail("not OpenVPN") }
        XCTAssertEqual(spy.asked.last?["protocols"], "openvpn_1_udp_443")
        XCTAssertTrue(udp.config.contains("<tls-auth>"))
        // WireGuard, and Automatic asked for directly, stay as they were: no OpenVPN profile asked for.
        let before = spy.asked.count
        for proto in [nil, AutoProtocol.key] {
            var l = nl; l.proto = proto
            guard case .wg = try await p.connect(l, blob) else { return XCTFail("not WireGuard") }
        }
        XCTAssertEqual(spy.asked.count, before)
        // And such a profile is one the provider vouches for again, as long as it dials only what it was made for.
        let link = Link.ovpn(sv, tcp)
        XCTAssertTrue(p.trusts(link, blob))
        var tampered = tcp
        tampered.config = tcp.config.replacingOccurrences(of: "remote 1.2.3.5 443", with: "remote 1.2.3.5 443\nremote 203.0.113.99 443")
        XCTAssertFalse(p.trusts(.ovpn(sv, tampered), blob))
        tampered.config = tcp.config.replacingOccurrences(of: "remote 1.2.3.5 443", with: "remote 10.0.0.5 443")
        XCTAssertFalse(p.trusts(.ovpn(sv, tampered), blob))
        // The standard entry's profile is bound to the server's own address.
        loc.proto = "openvpn_udp"
        guard case .ovpn(let udpServer, let udpProfile) = try await p.connect(loc, blob) else { return XCTFail("not OpenVPN") }
        XCTAssertTrue(p.trusts(.ovpn(udpServer, udpProfile), blob))
        var elsewhere = udpServer; elsewhere.ip = "1.2.3.9"
        XCTAssertFalse(p.trusts(.ovpn(elsewhere, udpProfile), blob))
        var weak = tcp; weak.config = tcp.config.replacingOccurrences(of: "tls-version-min 1.2", with: "tls-version-min 1.0")
        XCTAssertFalse(p.trusts(.ovpn(sv, weak), blob))
    }

    /// A profile that would dial anything else is refused: another address, the other entry, another port or transport, a
    /// second remote, one without its wrapper.
    func testAProfileThatDialsAnythingElseIsRefused() async throws {
        let (p, blob, _, spy, dir) = try await signedIn(); defer { try? FileManager.default.removeItem(at: dir) }
        let tcp = Fixture.text("ovpn/airvpn.tcp.ovpn"), udp = Fixture.text("ovpn/airvpn.udp.ovpn")
        let bad: [(String, String)] = [
            ("openvpn_tcp", tcp.replacingOccurrences(of: "remote 1.2.3.5 443", with: "remote 203.0.113.99 443")),
            ("openvpn_tcp", udp.replacingOccurrences(of: "<tls-auth>", with: "<tls-crypt>").replacingOccurrences(of: "</tls-auth>", with: "</tls-crypt>")),  // the standard entry, not the alternative one
            ("openvpn_udp", tcp.replacingOccurrences(of: "remote 1.2.3.5 443", with: "remote 1.2.3.5 443 udp")),
            ("openvpn_tcp", tcp + "\nremote 203.0.113.99 443"),
            ("openvpn_tcp", tcp + "\n--remote 203.0.113.99 443"),
            ("openvpn_tcp", tcp.replacingOccurrences(of: "remote 1.2.3.5 443", with: "remote 1.2.3.5 1194")),
            ("openvpn_tcp", tcp.replacingOccurrences(of: "remote 1.2.3.5 443", with: "remote 1.2.3.5\n#")),  // no port: OpenVPN would use 1194
            ("openvpn_tcp", tcp.replacingOccurrences(of: "remote 1.2.3.5 443", with: "remote 1.2.3.5 443 udp")),
            ("openvpn_tcp", tcp.replacingOccurrences(of: "remote 1.2.3.5 443", with: "<connection>\nremote 203.0.113.99 443\n</connection>\nremote 1.2.3.5 443")),
            ("openvpn_tcp", tcp.replacingOccurrences(of: "tls-crypt", with: "tls-auth")),
            ("openvpn_tcp", tcp.replacingOccurrences(of: "proto tcp", with: "proto udp")),
            ("openvpn_tcp", tcp.replacingOccurrences(of: "tls-version-min 1.2", with: "tls-version-min 1.0")),  // weak TLS, as an import would warn
            ("openvpn_tcp", tcp.replacingOccurrences(of: "remote-cert-tls server", with: "")),  // doesn't check the server
            ("openvpn_tcp", tcp.replacingOccurrences(of: "<tls-crypt>", with: "key-direction 1\n<tls-auth>").replacingOccurrences(of: "</tls-crypt>", with: "</tls-auth>")),  // another wrapper
        ]
        for (proto, text) in bad {
            spy.reply.withLock { $0 = { _ in text } }
            var l = nl; l.proto = proto
            do { _ = try await p.connect(l, blob); XCTFail("accepted a profile for \(proto)") }
            catch { XCTAssertTrue(error.localizedDescription.contains("doesn't match"), error.localizedDescription) }
        }
        // The first one of them is the one the right entry would have given, for the right kind.
        spy.reply.withLock { $0 = { _ in udp } }
        var l = nl; l.proto = "openvpn_udp"
        _ = try await p.connect(l, blob)
    }

    func testOpenVpnFailuresSayWhatToDo() async throws {
        let (p, blob, _, spy, dir) = try await signedIn(); defer { try? FileManager.default.removeItem(at: dir) }
        var l = nl; l.proto = "openvpn_tcp"
        spy.reply.withLock { $0 = { _ in #"{"error":"Server unknown"}"# } }
        do { _ = try await p.connect(l, blob); XCTFail("made a profile from an error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("didn't make an OpenVPN profile"), error.localizedDescription) }
        l.proto = "openvpn_xyz"
        do { _ = try await p.connect(l, blob); XCTFail("another protocol") }
        catch let e as Unsupported { XCTAssertTrue(e.localizedDescription.contains("doesn't offer")) }
        // Its device removed or renewed on the website: sign in again, with no profile asked for.
        let removed = await p.signOut(blob); XCTAssertTrue(removed)
        l.proto = "openvpn_udp"
        let before = spy.asked.count
        do { _ = try await p.connect(l, blob); XCTFail("a profile for a device that is gone") }
        catch let e as AuthError { XCTAssertTrue(e.localizedDescription.contains("Sign in to AirVPN again")) }
        XCTAssertEqual(spy.asked.count, before)
    }

    /// A pasted config has no API key: OpenVPN is refused with a message, no other tunnel may stand in for it, and AirVPN is asked nothing.
    func testWithoutAnApiKeyOpenVpnIsRefusedAndNothingIsAsked() async throws {
        let fake = FakeAir(), spy = Spy()
        let (p, dir) = provider(fake, spy); defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try await p.signIn(["key": ProviderFixtures.conf("10.164.20.6/32", endpoint: "1.2.3.4:1637", preshared: true)])
        XCTAssertFalse(AirVpn.canOpenVpn(blob))
        let calls = spy.calls.withLock { $0 }
        var l = nl; l.proto = "openvpn_udp"
        do { _ = try await p.connect(l, blob); XCTFail("OpenVPN without a key") }
        catch let e as Unsupported { XCTAssertTrue(e.localizedDescription.contains("API key")) }
        XCTAssertEqual(spy.calls.withLock { $0 }, calls)
        // Through the picker: the route is held with that message, even with a cached WireGuard tunnel at hand.
        var route = Route(id: "r", loc: l)
        route.loc.proto = "openvpn_udp"
        let setup = Setup(routes: [route], defaultRoute: "r")
        let cached = try await p.connect(nl, blob)
        let result = try await LinkPicker.pick(setup, keep: [:], applied: nil, appliedAccounts: [:], accounts: ["airvpn": blob],
                                               last: [LinkPicker.cacheKey(route, account: blob): cached], providers: { $0 == "airvpn" ? p : nil })
        XCTAssertNil(result.links["r"])
        XCTAssertTrue(result.blocked["r"]?.text.contains("API key") == true, result.blocked["r"]?.text ?? "")
        let account = try await signedIn().1
        XCTAssertTrue(AirVpn.canOpenVpn(account))
    }

    /// What the picker offers for a route: AirVPN's four, NordVPN's three with the slower TCP said, nothing for the others.
    func testTheProtocolChoice() {
        let air = AirVpn().protocols
        XCTAssertEqual(air.map(\.key), [nil, "openvpn_udp", "openvpn_tcp", "auto"])
        XCTAssertEqual(air.map(\.label), ["WireGuard", "OpenVPN UDP", "OpenVPN TCP", "Automatic"])
        XCTAssertTrue(air[2].note.contains("Much slower than the others"))
        XCTAssertTrue(air[3].note.contains("slower OpenVPN TCP"))
        XCTAssertFalse(air[1].note.contains("slower"))
        let nord = Nord().protocols
        XCTAssertEqual(nord.map(\.key), [nil, "openvpn_udp", "openvpn_tcp"])
        XCTAssertEqual(nord.map(\.label), ["NordLynx", "OpenVPN UDP", "OpenVPN TCP"])
        XCTAssertTrue(nord[2].note.contains("Much slower than the others"))
        for provider in Providers.all where provider.id != "nord" && provider.id != "airvpn" { XCTAssertTrue(provider.protocols.isEmpty, provider.id) }
    }

    /// WireGuard first; once it has failed on every port on this network, OpenVPN TCP, until the network changes or the
    /// VPN starts again. Only an Automatic route is ever moved, and only once.
    func testAutomaticMovesToTcpOnceAndBackOnAReset() throws {
        var loc = nl; loc.proto = AutoProtocol.key
        let auto = Route(id: "a", loc: loc)
        let wg = Link.wg(Server(name: "Alpha", host: "h", ip: "1.2.3.4", publicKey: "k", load: 1), WgPeer(name: "Alpha", privateKey: "p", address: ["10.0.0.2/32"], publicKey: "k", endpoint: "1.2.3.4:1637", allowedIps: ["0.0.0.0/0"]), ports: [1637, 47107], entries: [])
        let tcp = Link.ovpn(Server(name: "Alpha", host: "h", ip: "1.2.3.4", publicKey: "", load: 1), try Manual.parseOvpn(Fixture.text("ovpn/airvpn.tcp.ovpn"), name: "Alpha", username: "", password: ""))
        XCTAssertNil(AutoProtocol.of(auto)); XCTAssertEqual(AutoProtocol.resolved(auto).proto, nil)
        XCTAssertTrue(AutoProtocol.matches(auto, wg)); XCTAssertFalse(AutoProtocol.matches(auto, tcp))
        // Two ports: the first failing is not yet "every port"; the second is. One port, or a fixed one: at once.
        XCTAssertFalse(AutoProtocol.exhausted(ports: 2, canStep: true, step: 0))
        XCTAssertTrue(AutoProtocol.exhausted(ports: 2, canStep: true, step: 1))
        XCTAssertTrue(AutoProtocol.exhausted(ports: 2, canStep: false, step: 0))
        XCTAssertTrue(AutoProtocol.exhausted(ports: 1, canStep: false, step: 0))
        XCTAssertTrue(AutoProtocol.toTcp("a"))
        XCTAssertFalse(AutoProtocol.toTcp("a"))
        XCTAssertEqual(AutoProtocol.of(auto), "openvpn_tcp"); XCTAssertEqual(AutoProtocol.resolved(auto).proto, "openvpn_tcp")
        XCTAssertFalse(AutoProtocol.matches(auto, wg), "the WireGuard tunnel that stopped answering is never kept or reused")
        XCTAssertTrue(AutoProtocol.matches(auto, tcp))
        XCTAssertEqual(AutoProtocol.routes, ["a"])
        // Other routes: their choice is theirs, whatever is in the set.
        var fixed = nl; fixed.proto = "openvpn_udp"
        let own = Route(id: "a", loc: fixed)
        XCTAssertEqual(AutoProtocol.of(own), "openvpn_udp")
        XCTAssertTrue(AutoProtocol.matches(own, wg))
        let plain = Route(id: "a", loc: nl)
        XCTAssertNil(AutoProtocol.of(plain)); XCTAssertTrue(AutoProtocol.matches(plain, wg))
        // A network change, or a new connection: WireGuard again.
        AutoProtocol.reset()
        XCTAssertNil(AutoProtocol.of(auto)); XCTAssertTrue(AutoProtocol.matches(auto, wg)); XCTAssertFalse(AutoProtocol.matches(auto, tcp))
        XCTAssertTrue(AutoProtocol.routes.isEmpty)
    }

    /// The picker follows it: a kept tunnel stays while WireGuard is the choice, gives way to a profile once the route is on
    /// TCP, and WireGuard comes back with the reset.
    func testThePickerFollowsTheAutomaticChoice() async throws {
        let (p, blob, _, spy, dir) = try await signedIn(); defer { try? FileManager.default.removeItem(at: dir) }
        var loc = nl; loc.proto = AutoProtocol.key
        let setup = Setup(routes: [Route(id: "a", loc: loc)], defaultRoute: "a")
        func pick(keep: [String: Link]) async throws -> Link {
            let r = try await LinkPicker.pick(setup, keep: keep, applied: setup, appliedAccounts: ["airvpn": blob], accounts: ["airvpn": blob], last: [:], providers: { $0 == "airvpn" ? p : nil })
            return try XCTUnwrap(r.links["a"])
        }
        let first = try await pick(keep: [:])
        guard case .wg = first else { return XCTFail("not WireGuard") }
        let kept = try await pick(keep: ["a": first])
        XCTAssertEqual(kept, first); XCTAssertTrue(spy.asked.isEmpty)
        AutoProtocol.toTcp("a")
        let over = try await pick(keep: ["a": first])
        guard case .ovpn = over else { return XCTFail("kept the WireGuard tunnel on TCP") }
        XCTAssertEqual(spy.asked.last?["protocols"], "openvpn_3_tcp_443")
        let again = try await pick(keep: ["a": over])
        XCTAssertEqual(again, over)
        AutoProtocol.reset()
        guard case .wg = try await pick(keep: ["a": over]) else { return XCTFail("did not go back to WireGuard") }
        // A profile that can't be had: the route is not recorded as on TCP, so the next round that finds it dead tries again.
        AutoProtocol.toTcp("a")
        spy.reply.withLock { $0 = { _ in #"{"error":"busy"}"# } }
        let failed = try await LinkPicker.pick(setup, keep: ["a": first], applied: setup, appliedAccounts: ["airvpn": blob], accounts: ["airvpn": blob], last: [:], providers: { $0 == "airvpn" ? p : nil })
        XCTAssertNil(failed.links["a"]); XCTAssertNotNil(failed.blocked["a"])
        XCTAssertFalse(AutoProtocol.isOnTcp("a"))
    }

    /// A route's history reads apart by protocol: "AirVPN · OpenVPN TCP".
    func testTheStatsLabelNamesTheProtocol() {
        func label(_ provider: String, _ proto: String?) -> String { StatsMath.via(Route(id: "r", loc: Location(provider: provider, country: "Netherlands", proto: proto))) }
        XCTAssertEqual(label("airvpn", nil), "AirVPN")
        XCTAssertEqual(label("airvpn", "openvpn_udp"), "AirVPN · OpenVPN")
        XCTAssertEqual(label("airvpn", "openvpn_tcp"), "AirVPN · OpenVPN TCP")
        XCTAssertEqual(label("airvpn", "auto"), "AirVPN · Automatic")
        // One account stays one provider in "By provider", whatever its protocols.
        for proto in [nil, "openvpn_udp", "openvpn_tcp", "auto"] {
            let info = ExitInfo(id: "x", code: "NL", name: "Netherlands", via: label("airvpn", proto), tone: .route(1))
            XCTAssertEqual(StatsMath.providerOf("x", info), "AirVPN")
        }
        XCTAssertEqual(label("nord", "openvpn_tcp"), "Nord · OpenVPN TCP")
        XCTAssertEqual(StatsMath.via(Route(id: "r", ss: SsProfile(name: "x", server: "h", port: 1, method: "m", password: "p"))), "Shadowsocks")
        // The route's page says the same: "Using OpenVPN TCP" only while an Automatic route is on it and running.
        var auto = nl; auto.proto = "auto"
        let r = Route(id: "a", loc: auto)
        XCTAssertNil(AutoProtocol.label(r, onTcp: [], running: true))
        XCTAssertEqual(AutoProtocol.label(r, onTcp: ["a"], running: true), "Using OpenVPN TCP")
        XCTAssertNil(AutoProtocol.label(r, onTcp: ["a"], running: false))
        for (proto, text) in [("openvpn_udp", "OpenVPN"), ("openvpn_tcp", "OpenVPN TCP")] {
            var l = nl; l.proto = proto
            XCTAssertEqual(AutoProtocol.label(Route(id: "t", loc: l), onTcp: [], running: false), text)
        }
        XCTAssertNil(AutoProtocol.label(Route(id: "t", loc: nl), onTcp: ["t"], running: true))
    }
}


// MARK: Port 51820, connections in use, server history

extension AirApiTests {
    private func airLink(entries: [String] = ["1.2.3.4", "1.2.3.5"]) -> Link {
        .wg(Server(name: "Alpha", host: "h", ip: "1.2.3.4", publicKey: "k", load: 1),
            WgPeer(name: "Alpha", privateKey: "p", address: ["10.0.0.2/32"], publicKey: "k", endpoint: "1.2.3.4:1637", allowedIps: ["0.0.0.0/0"]),
            ports: [1637, 47107, 51820], entries: entries)
    }
    private func endpoint(_ setup: Setup, _ link: Link, step: Int = 0) -> String? {
        guard case .wg(_, let peer, _, _)? = LinkPicker.ported(setup, ["r": link], step: ["airvpn": step])["r"] else { return nil }
        return peer.endpoint
    }
    private func airSetup(_ opts: [String: String]) -> Setup {
        var s = Setup(routes: [Route(id: "r", loc: Location(provider: "airvpn"))], defaultRoute: "r")
        s.opts["airvpn"] = opts
        return s
    }

    func testPort51820GoesToTheAlternativeEntryWhateverTheEntrySettingSays() {
        guard case .choice(let choices)? = Providers.get("airvpn")?.option("port")?.kind else { return XCTFail("no port choice") }
        XCTAssertTrue(choices.contains { $0.value == "51820" })
        for entry in ["1", "2"] {
            XCTAssertEqual(endpoint(airSetup(["port": "51820", "entry": entry]), airLink()), "1.2.3.5:51820")
        }
        // Other ports follow the entry setting as before.
        XCTAssertEqual(endpoint(airSetup(["port": "1637", "entry": "1"]), airLink()), "1.2.3.4:1637")
        XCTAssertEqual(endpoint(airSetup(["port": "47107", "entry": "2"]), airLink()), "1.2.3.5:47107")
        // Automatic tries it after 1637 and 47107.
        let auto = airSetup(["port": "auto", "entry": "1"])
        XCTAssertEqual([0, 1, 2, 3].map { endpoint(auto, airLink(), step: $0) },
                       ["1.2.3.4:1637", "1.2.3.4:47107", "1.2.3.5:51820", "1.2.3.4:1637"])
    }

    func testPort51820WithoutKnownEntriesFallsBackToAnotherPort() {
        for step in [0, 2] {
            XCTAssertEqual(endpoint(airSetup(["port": "auto"]), airLink(entries: []), step: step), "1.2.3.4:1637")
        }
        XCTAssertEqual(endpoint(airSetup(["port": "51820", "entry": "1"]), airLink(entries: [])), "1.2.3.4:1637")
        XCTAssertEqual(endpoint(airSetup(["port": "51820"]), airLink(entries: ["1.2.3.4"])), "1.2.3.4:1637")
    }

    func testASavedTunnelOn51820IsTrustedOnlyAtTheAlternativeEntry() async throws {
        let fake = FakeAir(); let (p, _, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try await p.signIn(["key": key])
        let link = try await p.connect(Location(provider: "airvpn"), blob)
        let ported = try XCTUnwrap(LinkPicker.ported(airSetup(["port": "51820"]), ["r": link], step: [:])["r"])
        guard case .wg(let sv, var peer, let ports, let entries) = ported else { return XCTFail("not WireGuard") }
        XCTAssertEqual(peer.endpoint, "1.2.3.5:51820")
        XCTAssertTrue(p.trusts(ported, blob))
        peer.endpoint = "1.2.3.4:51820"
        XCTAssertFalse(p.trusts(.wg(sv, peer, ports: ports, entries: entries), blob))
        peer.endpoint = "1.2.3.5:51820"
        XCTAssertFalse(p.trusts(.wg(sv, peer, ports: [1637, 47107], entries: entries), blob))
    }

    func testConnectionsInUseCountEveryAppsSessions() async throws {
        let fake = FakeAir(); let (p, _, dir) = try provider(fake); defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try await p.signIn(["key": key])
        let three = try await p.inUse(blob); XCTAssertEqual(three, 3)
        await fake.setUp(sessions: .some(0))
        let none = try await p.inUse(blob); XCTAssertEqual(none, 0)
        // An error reply is unknown, never none in use; so is a reply without the list, and a pasted config.
        await fake.setUp(userinfoFails: true)
        let failed = try await p.inUse(blob); XCTAssertNil(failed)
        await fake.setUp(sessions: .some(nil), userinfoFails: false)
        let missing = try await p.inUse(blob); XCTAssertNil(missing)
        let pasted = try p.parseKey(["key": ProviderFixtures.conf("10.0.0.1/32", endpoint: "1.2.3.4:1637", preshared: true)])
        let unknown = try await p.inUse(pasted); XCTAssertNil(unknown)
        // The plan still reads the same reply.
        let plan = try await p.plan(blob); XCTAssertNotNil(plan)
        XCTAssertEqual(Limits.line("AirVPN", 5, "connection", 1, all: 3), "AirVPN allows 5 connections. 3 are in use, 1 of them by unbraid.")
    }

    // Server history

    private var history: String { #"{"result":"ok","panels":{"rtt":{"series":{"rtt":[[1,1.8],[2,"2.0"],[3,4],[4,null],[5,-1],[6,"x"]]}},"ploss":{"series":{"ploss":[[1,0],[2,0.2],[3,null]]}}}}"# }

    func testServerHistoryIsParsedIntoDelayAndLossWithGaps() throws {
        let q = try XCTUnwrap(try AirVpn.parseQuality(Data(history.utf8)))
        XCTAssertEqual(q.days, 7)
        XCTAssertEqual(q.delay.count, 6); XCTAssertEqual(Array(q.delay.prefix(3)), [1.8, 2.0, 4.0])
        XCTAssertTrue(q.delay[3...].allSatisfy(\.isNaN))
        XCTAssertEqual(q.loss.count, 3); XCTAssertTrue(q.loss[2].isNaN)
        XCTAssertEqual(q.line, "Delay 2.6 ms on average (1.8 to 4), packet loss 0.1% (at most 0.2%)")
        XCTAssertEqual(Quality(delay: [2.1, 2.1], loss: [0, 0], days: 7).line, "Delay 2.1 ms on average (2.1 to 2.1), packet loss 0%")
        XCTAssertEqual(Quality(delay: [], loss: [], days: 7).line, "No measurements in this period")
        XCTAssertNil(try AirVpn.parseQuality(Data(#"{"error":"nope"}"#.utf8)))
        XCTAssertNil(try AirVpn.parseQuality(Data(#"{"panels":{}}"#.utf8)))
        XCTAssertThrowsError(try AirVpn.parseQuality(Data("[1]".utf8)))
    }

    func testServerHistoryIsAskedByNameCheckedAndKeptTenMinutes() async throws {
        var p = AirVpn()
        let asked = Mutex<[String]>([])
        p.history = { [history] name in asked.withLock { $0.append(name) }; return Data(history.utf8) }
        XCTAssertTrue(p.reportsQuality)
        let first = await p.quality("Chara")
        XCTAssertEqual(first?.delay.count, 6)
        let again = await p.quality("Chara")
        XCTAssertEqual(again, first)
        XCTAssertEqual(asked.withLock { $0 }, ["Chara"])
        // A name that isn't a plain server name is never sent.
        for odd in ["", "a", "Chara&x=1", "../x", "1Chara", "Cha ra", String(repeating: "a", count: 40)] {
            let none = await p.quality(odd); XCTAssertNil(none)
        }
        XCTAssertEqual(asked.withLock { $0 }, ["Chara"])
        // A failed or unreadable answer is "can't say", and isn't kept.
        p.history = { _ in throw URLError(.notConnectedToInternet) }
        let failed = await p.quality("Diadema"); XCTAssertNil(failed)
        p.history = { _ in Data("not json".utf8) }
        let bad = await p.quality("Diadema"); XCTAssertNil(bad)
        // Providers that publish nothing say so.
        XCTAssertFalse(Providers.get("mullvad")?.reportsQuality ?? true)
    }
}
