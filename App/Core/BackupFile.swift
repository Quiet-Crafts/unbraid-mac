import CryptoKit
import Foundation
import Security

/// A backup file: bytes sealed under a passphrase, in the container the Android app writes, so a setup can move between
/// the two. Layout (format 1), all integers big-endian:
///
///     magic "UNBRAID-BACKUP\n" (15) | format 1 (1) | kdf 1 = scrypt (1) | log2 N, r, p (1 each) | salt (16) |
///     nonce (12) | check (16) | length of what follows (4) | AES-256-GCM ciphertext + tag | SHA-256 of all before (32)
///
/// scrypt turns the passphrase (NFC, UTF-8) into 64 bytes: the first 32 are the AES key, the last 32 key an HMAC whose
/// first 16 bytes are the check, so a wrong passphrase is told apart from a damaged file. Every header byte is the
/// cipher's additional data. The plain SHA-256 at the end tells a damaged or cut file apart before any key is derived.
/// What is inside is opaque here.
nonisolated enum BackupFile {
    static let fileExtension = "unbraidbackup"

    /// Why a file won't open (or a backup can't be made), told apart in this order: too large, not a backup, newer,
    /// damaged (checksum, cut, settings outside the caps), wrong passphrase (check value), damaged (tag).
    enum Failure: Error, Equatable { case tooLarge, notABackup, newer, damaged, wrongPassphrase, memory }

    static let format: UInt8 = 1
    /// 64 MiB and two passes: an OWASP-listed scrypt setting, the same the Android app uses.
    static let defaultLogN = 16, defaultR = 8, defaultP = 2
    /// No setup comes near this; a larger file is refused before anything else is read.
    static let maxSize = 4 << 20

    private static let magic = Data("UNBRAID-BACKUP\n".utf8)
    private static let scrypt: UInt8 = 1
    private static let saltSize = 16, nonceSize = 12, checkSize = 16, tagSize = 16, sumSize = 32
    private static let headSize = 15 + 5 + saltSize + nonceSize + checkSize + 4
    private static let checkLabel = Data("unbraid backup check".utf8)

    /// Starts like a backup: worth asking for its passphrase.
    static func looksLikeBackup(_ data: Data) -> Bool { data.count >= magic.count && data.prefix(magic.count).elementsEqual(magic) }

    /// Settings a file may ask for: log2 N 10 to 20, r 1 to 16, p 1 to 4, at most 128 MiB and twice the default's work,
    /// so a hostile file can't exhaust memory or time.
    static func allowed(logN: Int, r: Int, p: Int) -> Bool {
        (10...20).contains(logN) && (1...16).contains(r) && (1...4).contains(p)
            && (r << logN) * 128 <= 128 << 20 && p * (r << logN) <= 1 << 21
    }

    /// `plaintext` sealed under `passphrase`. Salt and nonce are fresh random bytes and the settings the default unless
    /// given (tests).
    static func seal(_ plaintext: Data, passphrase: String, salt: Data? = nil, nonce: Data? = nil,
                     logN: Int = defaultLogN, r: Int = defaultR, p: Int = defaultP) throws -> Data {
        precondition(allowed(logN: logN, r: r, p: p) && salt.map { $0.count == saltSize } != false && nonce.map { $0.count == nonceSize } != false)
        // Never a file that opening would refuse; known before any key work.
        guard headSize + plaintext.count + tagSize + sumSize <= maxSize else { throw Failure.tooLarge }
        let salt = try salt ?? random(saltSize)
        let nonce = try nonce ?? random(nonceSize)
        var key = try derive(passphrase, salt: salt, logN: logN, r: r, p: p)
        defer { clear(&key) }
        var head = magic
        head.append(contentsOf: [format, scrypt, UInt8(logN), UInt8(r), UInt8(p)])
        head.append(salt)
        head.append(nonce)
        head.append(check(key))
        head.append(contentsOf: withUnsafeBytes(of: UInt32(plaintext.count + tagSize).bigEndian, Array.init))
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key.prefix(32)), nonce: AES.GCM.Nonce(data: nonce), authenticating: head)
        var file = head
        file.append(box.ciphertext)
        file.append(box.tag)
        file.append(contentsOf: SHA256.hash(data: file))
        return file
    }

    /// The plaintext of backup `file`; throws `Failure` with why it won't open.
    static func open(_ file: Data, passphrase: String) throws -> Data {
        // Offsets below count from zero; a slice of a larger Data doesn't.
        let b = file.startIndex == 0 ? file : Data(file)
        if b.count > maxSize { throw Failure.tooLarge }
        if !looksLikeBackup(b) { throw Failure.notABackup }
        if b.count <= magic.count { throw Failure.damaged }
        if b[15] > format { throw Failure.newer }
        if b[15] != format || b.count < headSize + tagSize + sumSize { throw Failure.damaged }
        // Not secret: a plain comparison is fine.
        if Data(SHA256.hash(data: b.prefix(b.count - sumSize))) != b.suffix(sumSize) { throw Failure.damaged }
        let logN = Int(b[17]), r = Int(b[18]), p = Int(b[19])
        // Checked before any key work: a hostile file never gets to ask for gigabytes or hours.
        if b[16] != scrypt || !allowed(logN: logN, r: r, p: p) { throw Failure.damaged }
        let salt = b[20..<36], nonce = b[36..<48], stored = b[48..<64]
        let length = Int(b[64]) << 24 | Int(b[65]) << 16 | Int(b[66]) << 8 | Int(b[67])
        if length != b.count - sumSize - headSize { throw Failure.damaged }
        var key = try derive(passphrase, salt: Data(salt), logN: logN, r: r, p: p)
        defer { clear(&key) }
        if !constantTimeEqual(check(key), stored) { throw Failure.wrongPassphrase }
        let sealed = b[headSize..<(headSize + length)]
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(tagSize), tag: sealed.suffix(tagSize))
            return try AES.GCM.open(box, using: SymmetricKey(data: key.prefix(32)), authenticating: b.prefix(headSize))
        } catch { throw Failure.damaged }
    }

    /// The 64 key bytes. The passphrase's own String and its UTF-8 copy inside Foundation can't be cleared from here;
    /// the copy made for scrypt is.
    private static func derive(_ passphrase: String, salt: Data, logN: Int, r: Int, p: Int) throws -> Data {
        var pass = Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
        defer { clear(&pass) }
        do { return try Scrypt.derive(passphrase: pass, salt: salt, logN: logN, r: r, p: p, length: 64) }
        catch Scrypt.Failure.memory { throw Failure.memory }
        catch { throw Failure.damaged }
    }

    /// First 16 bytes of HMAC-SHA256(key2, label).
    private static func check(_ key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: checkLabel, using: SymmetricKey(data: key.suffix(32)))).prefix(checkSize)
    }

    /// Takes as long whatever the bytes are, so the check value can't be learned a byte at a time.
    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    private static func random(_ count: Int) throws -> Data {
        var d = Data(count: count)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) } == errSecSuccess
        // A backup without a fresh salt and nonce is never made.
        guard ok else { throw Fail("The system's random number generator didn't answer") }
        return d
    }

    /// Zeroes `d` in place. SymmetricKey keeps copies of its own that CryptoKit manages (and frees) itself, and Data may
    /// have left earlier copies when it grew, so this narrows how long the key stays in memory rather than promising
    /// that no copy is left.
    private static func clear(_ d: inout Data) {
        d.withUnsafeMutableBytes { if let p = $0.baseAddress { _ = memset_s(p, $0.count, 0, $0.count) } }
    }
}
