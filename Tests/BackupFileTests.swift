import CryptoKit
import Foundation
import XCTest

final class BackupFileTests: XCTestCase {
    private typealias F = BackupFile.Failure
    private let pass = "correct horse"

    /// 1 MiB, one pass: the format is the same, the tests just don't wait for the real setting.
    private func fast(_ plain: Data, _ pass: String = "correct horse", salt: Data? = nil, nonce: Data? = nil) throws -> Data {
        try BackupFile.seal(plain, passphrase: pass, salt: salt, nonce: nonce, logN: 10, r: 8, p: 1)
    }

    private func failure(_ file: Data, _ pass: String = "correct horse") -> F? {
        do { _ = try BackupFile.open(file, passphrase: pass); return nil } catch { return error as? F }
    }

    private func refreshSum(_ d: inout Data) {
        d.replaceSubrange((d.count - 32)..., with: Data(SHA256.hash(data: d.prefix(d.count - 32))))
    }

    private func bytes(_ from: Int, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: from + $0) }) }

    // ---- made by the Android app (its own Backup.seal, with fixed salt and nonce) ----

    private let androidPlain = Data(#"{"format":1,"app":"0.0.0-fixture","created":0,"setup":{"note":"made-up test data, nothing real"}}"#.utf8)

    func testFilesMadeOnAndroidOpen() throws {
        XCTAssertEqual(try BackupFile.open(Fixture.data("backup/default.unbraidbackup"), passphrase: "correct horse battery staple"), androidPlain)
        // Typed there with a decomposed accent, here with the composed one.
        XCTAssertEqual(try BackupFile.open(Fixture.data("backup/nfd.unbraidbackup"), passphrase: "caf\u{E9}"), Data("x".utf8))
        XCTAssertEqual(try BackupFile.open(Fixture.data("backup/empty.unbraidbackup"), passphrase: ""), Data())
        XCTAssertEqual(failure(Fixture.data("backup/default.unbraidbackup"), "correct horse battery stapler"), .wrongPassphrase)
    }

    /// Same input, same salt and nonce: the very bytes the Android app wrote, at the default settings too.
    func testSealingMatchesAndroidByteForByte() throws {
        XCTAssertEqual(try BackupFile.seal(androidPlain, passphrase: "correct horse battery staple", salt: bytes(0, 16), nonce: bytes(16, 12)),
                       Fixture.data("backup/default.unbraidbackup"))
        XCTAssertEqual(try fast(Data("x".utf8), "caf\u{E9}", salt: bytes(100, 16), nonce: bytes(116, 12)), Fixture.data("backup/nfd.unbraidbackup"))
        XCTAssertEqual(try fast(Data(), "", salt: bytes(200, 16), nonce: bytes(216, 12)), Fixture.data("backup/empty.unbraidbackup"))
    }

    func testHeaderLayout() throws {
        let f = try fast(Data("abc".utf8), salt: bytes(0, 16), nonce: bytes(16, 12))
        XCTAssertEqual(f.prefix(15), Data("UNBRAID-BACKUP\n".utf8))
        XCTAssertEqual(Array(f[15..<20]), [1, 1, 10, 8, 1])
        XCTAssertEqual(f[20..<36], bytes(0, 16))
        XCTAssertEqual(f[36..<48], bytes(16, 12))
        XCTAssertEqual(Array(f[64..<68]), [0, 0, 0, 19])
        XCTAssertEqual(f.count, 68 + 3 + 16 + 32)
    }

    // ---- round trips ----

    func testRoundTripWithTheDefaultSettings() throws {
        let plain = Data("{\"setup\":{}}".utf8)
        let t = Date()
        let file = try BackupFile.seal(plain, passphrase: "correct horse battery staple")
        let back = try BackupFile.open(file, passphrase: "correct horse battery staple")
        print("seal + open at the default settings: \(Int(Date().timeIntervalSince(t) * 1000)) ms")
        XCTAssertEqual(back, plain)
        XCTAssertEqual(Array(file[17..<20]), [16, 8, 2])
    }

    func testEachSaveIsDifferent() throws {
        let a = try fast(Data("same".utf8)), b = try fast(Data("same".utf8))
        XCTAssertNotEqual(a[20..<48], b[20..<48])
        XCTAssertNotEqual(a, b)
    }

    func testEmptyPassphraseAndEmptyPlaintext() throws {
        XCTAssertEqual(try BackupFile.open(try fast(Data("x".utf8), ""), passphrase: ""), Data("x".utf8))
        XCTAssertEqual(try BackupFile.open(try fast(Data()), passphrase: pass), Data())
        XCTAssertEqual(failure(try fast(Data("x".utf8), ""), " "), .wrongPassphrase)
    }

    func testComposedAndDecomposedPassphrasesOpenTheSameFile() throws {
        let composed = "caf\u{E9}", decomposed = "cafe\u{301}"
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        XCTAssertEqual(try BackupFile.open(try fast(Data("x".utf8), composed), passphrase: decomposed), Data("x".utf8))
        XCTAssertEqual(try BackupFile.open(try fast(Data("x".utf8), decomposed), passphrase: composed), Data("x".utf8))
    }

    func testWrongPassphraseIsToldApart() throws {
        let f = try fast(Data("x".utf8))
        XCTAssertEqual(failure(f, "correct horsE"), .wrongPassphrase)
        XCTAssertEqual(failure(f, ""), .wrongPassphrase)
        XCTAssertEqual(failure(f, "correct horse "), .wrongPassphrase)
    }

    // ---- damage ----

    /// Any one byte changed, the checksum left as it was: caught before any key work. The magic: not a backup; the
    /// format byte made larger: newer; made smaller, or anything else: damaged.
    func testEveryByteFlipped() throws {
        let f = try fast(Data(#"{"made-up":"setup","n":12345}"#.utf8))
        let t = Date()
        for i in 0..<f.count {
            for bits: UInt8 in [0x01, 0x80, 0xFF] {
                var d = f
                d[i] ^= bits
                let want: F = i < 15 ? .notABackup : i == 15 ? (d[15] > 1 ? .newer : .damaged) : .damaged
                XCTAssertEqual(failure(d), want, "byte \(i) ^ \(bits)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(t), 2, "no key should have been derived")
    }

    /// Any one byte changed and the checksum made right again: still never the plaintext. Settings: damaged when outside
    /// the caps, else another key (wrong passphrase); salt and check value: wrong passphrase; nonce, length, ciphertext
    /// and tag: damaged.
    func testEveryByteFlippedWithTheChecksumFixed() throws {
        let f = try fast(Data(#"{"made-up":"setup","n":12345}"#.utf8))
        for i in 0..<(f.count - 32) {
            var d = f
            d[i] ^= 0x01
            refreshSum(&d)
            let want: F
            switch i {
            case 0..<15: want = .notABackup
            case 15: want = .damaged  // 1 ^ 1 = 0
            case 16: want = .damaged  // no such key derivation
            case 17..<20: want = BackupFile.allowed(logN: Int(d[17]), r: Int(d[18]), p: Int(d[19])) ? .wrongPassphrase : .damaged
            case 20..<36: want = .wrongPassphrase
            case 36..<48: want = .damaged
            case 48..<64: want = .wrongPassphrase
            default: want = .damaged
            }
            XCTAssertEqual(failure(d), want, "byte \(i)")
        }
    }

    func testEveryTruncationAndATrailingByte() throws {
        let f = try fast(Data("some made-up contents".utf8))
        for n in 0..<f.count {
            XCTAssertEqual(failure(f.prefix(n)), n < 15 ? .notABackup : .damaged, "cut at \(n)")
        }
        XCTAssertEqual(failure(f + [0]), .damaged)
        XCTAssertEqual(failure(Data("[Interface]\nPrivateKey = x".utf8)), .notABackup)
    }

    func testASliceOfALargerBufferOpens() throws {
        let f = try fast(Data("x".utf8))
        let inside = (Data([9, 9, 9]) + f + Data([7]))
        XCTAssertEqual(try BackupFile.open(inside[3..<(3 + f.count)], passphrase: pass), Data("x".utf8))
    }

    func testANewerFormatIsRefusedPlainly() throws {
        var f = try fast(Data("x".utf8))
        f[15] = 2
        refreshSum(&f)
        XCTAssertEqual(failure(f), .newer)
        f[15] = 0
        refreshSum(&f)
        XCTAssertEqual(failure(f), .damaged)
    }

    /// Settings asking for gigabytes or hours are refused before any key is derived.
    func testHostileSettingsAreRefusedWithoutKeyWork() throws {
        let f = try fast(Data("x".utf8))
        let hostile: [(kdf: UInt8, logN: UInt8, r: UInt8, p: UInt8, why: String)] = [
            (1, 21, 8, 1, "log2 N 21"), (1, 9, 8, 1, "log2 N 9"), (1, 255, 255, 255, "everything at its largest"),
            (1, 10, 17, 1, "r 17"), (1, 10, 0, 1, "r 0"), (1, 10, 8, 5, "p 5"), (1, 10, 8, 0, "p 0"),
            (1, 20, 2, 1, "256 MiB"), (1, 18, 16, 1, "512 MiB"),
            (1, 17, 8, 3, "three times the default's work"), (1, 17, 8, 4, "four times the default's work"),
            (2, 16, 8, 2, "another key derivation"), (0, 16, 8, 2, "no key derivation"),
        ]
        for h in hostile {
            var d = f
            d[16] = h.kdf; d[17] = h.logN; d[18] = h.r; d[19] = h.p
            refreshSum(&d)
            let t = Date()
            XCTAssertEqual(failure(d), .damaged, h.why)
            XCTAssertLessThan(Date().timeIntervalSince(t), 0.05, h.why)
        }
        // The edges that are allowed: 128 MiB at one pass, and exactly twice the default's work.
        XCTAssertTrue(BackupFile.allowed(logN: 20, r: 1, p: 2))
        XCTAssertTrue(BackupFile.allowed(logN: 17, r: 8, p: 2))
        XCTAssertTrue(BackupFile.allowed(logN: 10, r: 16, p: 4))
        XCTAssertFalse(BackupFile.allowed(logN: 20, r: 1, p: 3))
        XCTAssertTrue(BackupFile.allowed(logN: BackupFile.defaultLogN, r: BackupFile.defaultR, p: BackupFile.defaultP))
    }

    // ---- size ----

    func testTheFourMiBLimit() throws {
        let largest = BackupFile.maxSize - 68 - 16 - 32
        let plain = Data(repeating: 0x61, count: largest)
        let f = try fast(plain)
        XCTAssertEqual(f.count, BackupFile.maxSize)
        XCTAssertEqual(try BackupFile.open(f, passphrase: pass), plain)
        // Saving never makes a file that opening would refuse, and says so before any key work.
        XCTAssertThrowsError(try fast(plain + [0x61])) { XCTAssertEqual($0 as? F, .tooLarge) }
        XCTAssertEqual(failure(f + [0]), .tooLarge)
        XCTAssertEqual(failure(Data(count: BackupFile.maxSize + 1)), .tooLarge)
    }

    func testLooksLikeBackup() throws {
        XCTAssertTrue(BackupFile.looksLikeBackup(try fast(Data())))
        XCTAssertTrue(BackupFile.looksLikeBackup(Data("UNBRAID-BACKUP\n".utf8)))
        XCTAssertFalse(BackupFile.looksLikeBackup(Data("UNBRAID-BACKUP".utf8)))
        XCTAssertFalse(BackupFile.looksLikeBackup(Data("unbraid-backup\n".utf8)))
        XCTAssertFalse(BackupFile.looksLikeBackup(Data()))
        XCTAssertEqual(BackupFile.fileExtension, "unbraidbackup")
    }
}
