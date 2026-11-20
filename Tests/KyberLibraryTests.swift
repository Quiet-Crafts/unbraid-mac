import XCTest

/// The real Kyber library the app links for IVPN's quantum-safe key (the other tests use a fake). The library's own
/// round trip, with a real encapsulation, is the Go test in tools/kyber; this checks that it works from Swift.
final class KyberLibraryTests: XCTestCase {
    private let kyber = KyberLibrary()
    private func size(_ base64: String) -> Int { Data(base64Encoded: base64)?.count ?? -1 }

    func testKeyPairsHaveKyber1024Sizes() throws {
        let a = try kyber.keyPair(), b = try kyber.keyPair()
        XCTAssertEqual(size(a.public), 1568)
        XCTAssertEqual(size(a.private), 3168)
        XCTAssertNotEqual(a.private, b.private, "each call makes a fresh key")
        XCTAssertNotEqual(a.public, b.public)
    }

    /// A key, a ciphertext made for it by an independent Kyber-1024 encapsulation, and the preshared key that gives (a
    /// throwaway test key made only for this file).
    func testDecapsulatesARealCiphertextToTheExpectedKey() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/kyber-vector.json")
        let vector = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let psk = try kyber.psk(private: try XCTUnwrap(vector["private"]), cipher: try XCTUnwrap(vector["cipher"]))
        XCTAssertEqual(psk, vector["psk"])
    }

    func testPresharedKeyIsAStableSHA256() throws {
        let a = try kyber.keyPair(), b = try kyber.keyPair()
        // Kyber answers any well-formed ciphertext (a wrong one gives an unrelated secret), so the sizes can be checked
        // without the server's encapsulation: the answer is 32 bytes, the same each time, and depends on the key.
        let cipher = Data(repeating: 9, count: 1568).base64EncodedString()
        let first = try kyber.psk(private: a.private, cipher: cipher)
        XCTAssertEqual(size(first), 32)
        XCTAssertEqual(try kyber.psk(private: a.private, cipher: cipher), first)
        XCTAssertEqual(try kyber.psk(private: a.private, cipher: "\n" + cipher.prefix(40) + " " + cipher.dropFirst(40) + "\n"), first,
                       "white space inside the ciphertext is ignored")
        XCTAssertNotEqual(try kyber.psk(private: b.private, cipher: cipher), first)
    }

    func testBadInputIsRefusedWithAMessage() throws {
        let key = try kyber.keyPair().private
        let cipher = Data(repeating: 9, count: 1568).base64EncodedString()
        XCTAssertThrowsError(try kyber.psk(private: key, cipher: "AAAA")) { XCTAssertTrue("\($0)".contains("ciphertext"), "\($0)") }
        XCTAssertThrowsError(try kyber.psk(private: key, cipher: "not base64!")) { XCTAssertTrue("\($0)".contains("ciphertext"), "\($0)") }
        XCTAssertThrowsError(try kyber.psk(private: "AAAA", cipher: cipher)) { XCTAssertTrue("\($0)".contains("private key"), "\($0)") }
    }
}
