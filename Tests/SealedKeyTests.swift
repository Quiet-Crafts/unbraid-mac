import CryptoKit
import Security
import XCTest

/// Where the app's sealing key comes from, in release and in development builds.
final class SealedKeyTests: XCTestCase {
    private let planted = SymmetricKey(size: .bits256)
    private let own = SymmetricKey(size: .bits256)

    private func key(_ c: Sealed.Choice) -> SymmetricKey? {
        switch c {
        case .use(let k), .adopt(let k): k
        default: nil
        }
    }

    func testAReleaseNeverAdoptsAKeyFromTheFileBasedKeychain() {
        // Any process running as the user can put one there: a release creates its own instead, without even looking.
        var looked = false
        let c = Sealed.choose(modern: .missing, legacy: { looked = true; return .found(planted) }(), developmentKeys: false)
        guard case .create = c else { return XCTFail("\(c)") }
        XCTAssertFalse(looked)
    }

    func testAReleaseWithoutItsAppGroupHasNoKey() {
        var looked = false
        let c = Sealed.choose(modern: .failed(errSecMissingEntitlement), legacy: { looked = true; return .found(planted) }(), developmentKeys: false)
        guard case .none = c else { return XCTFail("\(c)") }
        XCTAssertFalse(looked)
    }

    func testTheDataProtectionKeyIsUsedWhenThere() {
        for dev in [false, true] {
            XCTAssertEqual(key(Sealed.choose(modern: .found(own), legacy: .found(planted), developmentKeys: dev)).map(raw), raw(own))
        }
    }

    func testAnUnreadableKeyIsNeverReplaced() {
        for dev in [false, true] {
            guard case .none = Sealed.choose(modern: .failed(errSecInteractionNotAllowed), legacy: .missing, developmentKeys: dev) else { return XCTFail() }
        }
        guard case .none = Sealed.choose(modern: .missing, legacy: .failed(errSecInteractionNotAllowed), developmentKeys: true) else { return XCTFail() }
    }

    func testDevelopmentBuildsKeepTheirOldKeyAndTestRunsTheFileBasedKeychain() {
        guard case .adopt(let k) = Sealed.choose(modern: .missing, legacy: .found(own), developmentKeys: true) else { return XCTFail() }
        XCTAssertEqual(raw(k), raw(own))
        guard case .create = Sealed.choose(modern: .missing, legacy: .missing, developmentKeys: true) else { return XCTFail() }
        // The unsigned test runs have no app group: the file-based keychain.
        guard case .fileBased = Sealed.choose(modern: .failed(errSecMissingEntitlement), legacy: .missing, developmentKeys: true) else { return XCTFail() }
    }

    private func raw(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }
}

/// Telling "no file" apart from "can't open it now": only the first may count as no state.
final class SealedOpenTests: XCTestCase {
    private var dir: URL!

    override func setUp() { dir = FileManager.default.temporaryDirectory.appending(path: "sealed-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testSweepKeepsRecentAndUnrelatedFiles() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date(), old = ".config.\(UUID().uuidString).tmp"
        let fresh = ".tailscale-501.\(UUID().uuidString).tmp", unrelated = ".config.not-a-uuid.tmp"
        for name in [old, fresh, unrelated] {
            try Data("sealed".utf8).write(to: dir.appending(path: name))
        }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-61)], ofItemAtPath: dir.appending(path: old).path)
        XCTAssertTrue(Sealed.sweepTemps(dir, now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: old).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: fresh).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: unrelated).path))
    }

    func testOnlyAMissingFileIsNoState() throws {
        let key = SymmetricKey(size: .bits256)
        let vault = Sealed(dir: dir, key: { key })
        XCTAssertNil(try vault.open("tailscale"))
        XCTAssertTrue(vault.write("tailscale", Data("{}".utf8)))
        XCTAssertEqual(try vault.open("tailscale"), Data("{}".utf8))
        // Damaged, or sealed under another key: an error, never "nothing there".
        try Data("not sealed".utf8).write(to: dir.appending(path: "tailscale"))
        XCTAssertThrowsError(try vault.open("tailscale"))
        XCTAssertNil(vault.read("tailscale"))
        let otherKey = SymmetricKey(size: .bits256)
        let other = Sealed(dir: dir, key: { otherKey })
        XCTAssertTrue(other.write("tailscale", Data("{}".utf8)))
        XCTAssertThrowsError(try vault.open("tailscale"))
        // A file that is there but can't be read now is not "no state" either.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.appending(path: "tailscale").path)
        XCTAssertThrowsError(try vault.open("tailscale"))
        XCTAssertNil(try Sealed(dir: dir.appending(path: "gone"), key: { key }).open("x"))
    }
}
