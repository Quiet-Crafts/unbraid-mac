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
        case "userinfo": return Data(#"{"user":{"premium":true,"expiration_unix":1795348998}}"#.utf8)
        default: throw Fail("Unexpected fixture call")
        }
    }
    func returnWrongAddress() { wrongAddress = true }
    func names() -> [String] { devices.map(\.name) }
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
        XCTAssertEqual(ports, [1637, 47107]); XCTAssertEqual(entries, ["1.2.3.4", "1.2.3.5"])
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

    func testOldAccountDecodes() throws {
        let old = #"{"privateKey":"p","address":[],"dns":[],"port":1637,"mtu":1420}"#
        let a = try AirVpn().keyAccount(old)
        XCTAssertNil(a.apiKey); XCTAssertNil(a.ownDevice)
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
