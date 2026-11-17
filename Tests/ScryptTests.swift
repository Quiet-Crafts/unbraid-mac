import Foundation
import XCTest

final class ScryptTests: XCTestCase {
    private func hex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    private func scrypt(_ pass: String, _ salt: String, logN: Int, r: Int, p: Int) throws -> Data {
        try Scrypt.derive(passphrase: Data(pass.utf8), salt: Data(salt.utf8), logN: logN, r: r, p: p, length: 64)
    }

    /// RFC 7914 section 12. The fourth vector (N = 2^20, r = 8: 1 GiB) is left out, as it is far past what a backup
    /// may ask for.
    func testRfc7914Vectors() throws {
        XCTAssertEqual(try scrypt("", "", logN: 4, r: 1, p: 1),
                       hex("77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906"))
        XCTAssertEqual(try scrypt("password", "NaCl", logN: 10, r: 8, p: 16),
                       hex("fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640"))
        XCTAssertEqual(try scrypt("pleaseletmein", "SodiumChloride", logN: 14, r: 8, p: 1),
                       hex("7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887"))
    }

    /// RFC 7914 section 11: PBKDF2-HMAC-SHA256.
    func testPbkdf2Vectors() {
        XCTAssertEqual(Scrypt.pbkdf2(Data("passwd".utf8), salt: Data("salt".utf8), iterations: 1, length: 64),
                       hex("55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783"))
        XCTAssertEqual(Scrypt.pbkdf2(Data("Password".utf8), salt: Data("NaCl".utf8), iterations: 80000, length: 64),
                       hex("4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d"))
        // A length that isn't a whole number of blocks is the start of the longer output.
        XCTAssertEqual(Scrypt.pbkdf2(Data("passwd".utf8), salt: Data("salt".utf8), iterations: 1, length: 40), hex("55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645"))
    }

    func testOutputLengthIsTheStartOfALongerOne() throws {
        let long = try Scrypt.derive(passphrase: Data("p".utf8), salt: Data("s".utf8), logN: 4, r: 1, p: 1, length: 100)
        let short = try Scrypt.derive(passphrase: Data("p".utf8), salt: Data("s".utf8), logN: 4, r: 1, p: 1, length: 33)
        XCTAssertEqual(long.count, 100)
        XCTAssertEqual(short, long.prefix(33))
    }

    func testSettingsScryptDoesNotDefineAreRefused() {
        for (logN, r, p, len) in [(0, 8, 1, 64), (32, 8, 1, 64), (10, 0, 1, 64), (10, 8, 0, 64), (10, 8, 1, 0), (10, 1 << 24, 1, 64), (10, 1 << 15, 1 << 15, 64)] {
            XCTAssertThrowsError(try Scrypt.derive(passphrase: Data(), salt: Data(), logN: logN, r: r, p: p, length: len), "\(logN) \(r) \(p) \(len)") {
                XCTAssertEqual($0 as? Scrypt.Failure, .settings)
            }
        }
    }

    /// Memory that can't be had (2^61 bytes here) is said plainly instead of trapping.
    func testMemoryThatCannotBeHadIsAnError() {
        let t = Date()
        XCTAssertThrowsError(try Scrypt.derive(passphrase: Data(), salt: Data(), logN: 31, r: 1 << 23, p: 1, length: 64)) {
            XCTAssertEqual($0 as? Scrypt.Failure, .memory)
        }
        XCTAssertLessThan(Date().timeIntervalSince(t), 1)
    }

    /// The backup's own setting (64 MiB, two passes); the time is printed for the record.
    func testDefaultSettingTime() throws {
        let t = Date()
        let k = try Scrypt.derive(passphrase: Data("correct horse".utf8), salt: Data(count: 16), logN: 16, r: 8, p: 2, length: 64)
        print("scrypt N=2^16 r=8 p=2: \(Int(Date().timeIntervalSince(t) * 1000)) ms")
        XCTAssertEqual(k.count, 64)
    }
}
