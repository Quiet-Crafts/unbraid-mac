import CryptoKit
import Foundation

/// scrypt (RFC 7914), memory-hard key derivation: the backup file format the Android app writes uses it, and the system
/// has no scrypt of its own. PBKDF2 sits on CryptoKit's HMAC so this file needs nothing else.
nonisolated enum Scrypt {
    enum Failure: Error, Equatable {
        /// Settings scrypt itself doesn't define (N not a power of two above 1, r or p zero, sizes past what fits).
        case settings
        /// The working memory (128·r·N bytes) couldn't be had.
        case memory
    }

    static func derive(passphrase: Data, salt: Data, logN: Int, r: Int, p: Int, length: Int) throws -> Data {
        // RFC 7914 asks r·p < 2^30; the bounds on each first keep the products below from wrapping around.
        guard (1...31).contains(logN), (1..<1 << 24).contains(r), (1..<1 << 24).contains(p), r * p < 1 << 30, length > 0 else { throw Failure.settings }
        let n = 1 << logN
        let words = 32 * r
        // V is the memory-hard part: N blocks of 128·r bytes. Checked so a huge N·r can't wrap around.
        let (vWords, o1) = words.multipliedReportingOverflow(by: n)
        let (vBytes, o2) = vWords.multipliedReportingOverflow(by: 4)
        guard !o1, !o2 else { throw Failure.memory }
        // malloc, not UnsafeMutablePointer.allocate: that one traps when memory can't be had, this one says so.
        guard let vRaw = malloc(vBytes) else { throw Failure.memory }
        // X and Y (one block each) and a 16-word scratch for Salsa20/8.
        let xyBytes = (2 * words + 16) * 4
        guard let xyRaw = malloc(xyBytes) else { wipe(vRaw, vBytes); free(vRaw); throw Failure.memory }
        var b = pbkdf2(passphrase, salt: salt, iterations: 1, length: p * 128 * r)
        defer {
            wipe(vRaw, vBytes); free(vRaw)
            wipe(xyRaw, xyBytes); free(xyRaw)
            b.withUnsafeMutableBytes { wipe($0.baseAddress!, $0.count) }
        }
        let v = vRaw.bindMemory(to: UInt32.self, capacity: vWords)
        let xy = xyRaw.bindMemory(to: UInt32.self, capacity: 2 * words + 16)
        b.withUnsafeMutableBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            for i in 0..<p { smix(base + i * 128 * r, r: r, n: n, v: v, xy: xy) }
        }
        return pbkdf2(passphrase, salt: b, iterations: 1, length: length)
    }

    /// PBKDF2-HMAC-SHA256 (RFC 8018). scrypt uses one iteration; more are here for the RFC's own test vectors.
    static func pbkdf2(_ passphrase: Data, salt: Data, iterations: Int, length: Int) -> Data {
        // HMAC pads a short key with zeros, so an empty key is the same as one zero byte; CryptoKit then never sees a
        // key of size zero.
        let key = SymmetricKey(data: passphrase.isEmpty ? Data([0]) : passphrase)
        var out = Data(capacity: length)
        var block: UInt32 = 1
        while out.count < length {
            var mac = HMAC<SHA256>(key: key)
            mac.update(data: salt)
            mac.update(data: withUnsafeBytes(of: block.bigEndian) { Data($0) })
            var u = Data(mac.finalize())
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for k in 0..<32 { t[k] ^= u[k] }
                }
            }
            out.append(t.prefix(length - out.count))
            t.withUnsafeMutableBytes { wipe($0.baseAddress!, $0.count) }
            u.withUnsafeMutableBytes { wipe($0.baseAddress!, $0.count) }
            block += 1
        }
        return out
    }

    /// Zeroes memory in a way the compiler may not drop as a dead store.
    private static func wipe(_ p: UnsafeMutableRawPointer, _ count: Int) { _ = memset_s(p, count, 0, count) }

    /// ROMix on one 128·r-byte block of B, in place. Words are little-endian, as the RFC reads them.
    private static func smix(_ b: UnsafeMutablePointer<UInt8>, r: Int, n: Int, v: UnsafeMutablePointer<UInt32>, xy: UnsafeMutablePointer<UInt32>) {
        let words = 32 * r
        let x = xy, y = xy + words, t = xy + 2 * words
        UnsafeMutableRawPointer(x).copyMemory(from: b, byteCount: 4 * words)
        for k in 0..<words { x[k] = UInt32(littleEndian: x[k]) }
        let mask = n - 1
        // Two steps per turn so X and Y swap roles without a copy; N is a power of two above 1, so even.
        var i = 0
        while i < n {
            (v + i * words).update(from: x, count: words)
            blockMix(x, nil, into: y, r: r, t: t)
            (v + (i + 1) * words).update(from: y, count: words)
            blockMix(y, nil, into: x, r: r, t: t)
            i += 2
        }
        i = 0
        while i < n {
            // Integerify: the first word of the last 64-byte block; N below 2^32 needs no more of it.
            blockMix(x, v + (Int(x[words - 16]) & mask) * words, into: y, r: r, t: t)
            blockMix(y, v + (Int(y[words - 16]) & mask) * words, into: x, r: r, t: t)
            i += 2
        }
        for k in 0..<words { x[k] = x[k].littleEndian }
        UnsafeMutableRawPointer(b).copyMemory(from: x, byteCount: 4 * words)
    }

    private static func xor(_ a: UnsafeMutablePointer<UInt32>, _ b: UnsafeMutablePointer<UInt32>, _ count: Int) {
        for k in 0..<count { a[k] ^= b[k] }
    }

    /// BlockMix of `a` (XOR `b`, when given: ROMix's second loop): out's even sub-blocks first, then the odd ones,
    /// written straight into place. The XOR is folded in here rather than run as a pass of its own.
    private static func blockMix(_ a: UnsafeMutablePointer<UInt32>, _ b: UnsafeMutablePointer<UInt32>?, into out: UnsafeMutablePointer<UInt32>, r: Int, t: UnsafeMutablePointer<UInt32>) {
        let last = (2 * r - 1) * 16
        t.update(from: a + last, count: 16)
        if let b { xor(t, b + last, 16) }
        var i = 0
        while i < 2 * r {
            salsa(t, a + i * 16, b.map { $0 + i * 16 })
            (out + ((i & 1) * r + i / 2) * 16).update(from: t, count: 16)
            i += 1
        }
    }

    /// Salsa20/8 core on t XOR a (XOR b), into t. Everything is written out (no loops over ranges, no helper for the
    /// rotations) and the rounds run on locals: that keeps a Debug build within several times a Release one, where loops
    /// and calls made it about a hundred times slower.
    private static func salsa(_ t: UnsafeMutablePointer<UInt32>, _ a: UnsafeMutablePointer<UInt32>, _ b: UnsafeMutablePointer<UInt32>?) {
        if let b {
            t[0] ^= b[0]; t[1] ^= b[1]; t[2] ^= b[2]; t[3] ^= b[3]; t[4] ^= b[4]; t[5] ^= b[5]; t[6] ^= b[6]; t[7] ^= b[7]
            t[8] ^= b[8]; t[9] ^= b[9]; t[10] ^= b[10]; t[11] ^= b[11]; t[12] ^= b[12]; t[13] ^= b[13]; t[14] ^= b[14]; t[15] ^= b[15]
        }
        t[0] ^= a[0]; t[1] ^= a[1]; t[2] ^= a[2]; t[3] ^= a[3]; t[4] ^= a[4]; t[5] ^= a[5]; t[6] ^= a[6]; t[7] ^= a[7]
        t[8] ^= a[8]; t[9] ^= a[9]; t[10] ^= a[10]; t[11] ^= a[11]; t[12] ^= a[12]; t[13] ^= a[13]; t[14] ^= a[14]; t[15] ^= a[15]
        var x0 = t[0], x1 = t[1], x2 = t[2], x3 = t[3], x4 = t[4], x5 = t[5], x6 = t[6], x7 = t[7]
        var x8 = t[8], x9 = t[9], x10 = t[10], x11 = t[11], x12 = t[12], x13 = t[13], x14 = t[14], x15 = t[15]
        var q: UInt32
        var round = 0
        while round < 4 {
            round += 1
            q = x0 &+ x12; x4 ^= q &<< 7 | q &>> 25; q = x4 &+ x0; x8 ^= q &<< 9 | q &>> 23; q = x8 &+ x4; x12 ^= q &<< 13 | q &>> 19; q = x12 &+ x8; x0 ^= q &<< 18 | q &>> 14
            q = x5 &+ x1; x9 ^= q &<< 7 | q &>> 25; q = x9 &+ x5; x13 ^= q &<< 9 | q &>> 23; q = x13 &+ x9; x1 ^= q &<< 13 | q &>> 19; q = x1 &+ x13; x5 ^= q &<< 18 | q &>> 14
            q = x10 &+ x6; x14 ^= q &<< 7 | q &>> 25; q = x14 &+ x10; x2 ^= q &<< 9 | q &>> 23; q = x2 &+ x14; x6 ^= q &<< 13 | q &>> 19; q = x6 &+ x2; x10 ^= q &<< 18 | q &>> 14
            q = x15 &+ x11; x3 ^= q &<< 7 | q &>> 25; q = x3 &+ x15; x7 ^= q &<< 9 | q &>> 23; q = x7 &+ x3; x11 ^= q &<< 13 | q &>> 19; q = x11 &+ x7; x15 ^= q &<< 18 | q &>> 14
            q = x0 &+ x3; x1 ^= q &<< 7 | q &>> 25; q = x1 &+ x0; x2 ^= q &<< 9 | q &>> 23; q = x2 &+ x1; x3 ^= q &<< 13 | q &>> 19; q = x3 &+ x2; x0 ^= q &<< 18 | q &>> 14
            q = x5 &+ x4; x6 ^= q &<< 7 | q &>> 25; q = x6 &+ x5; x7 ^= q &<< 9 | q &>> 23; q = x7 &+ x6; x4 ^= q &<< 13 | q &>> 19; q = x4 &+ x7; x5 ^= q &<< 18 | q &>> 14
            q = x10 &+ x9; x11 ^= q &<< 7 | q &>> 25; q = x11 &+ x10; x8 ^= q &<< 9 | q &>> 23; q = x8 &+ x11; x9 ^= q &<< 13 | q &>> 19; q = x9 &+ x8; x10 ^= q &<< 18 | q &>> 14
            q = x15 &+ x14; x12 ^= q &<< 7 | q &>> 25; q = x12 &+ x15; x13 ^= q &<< 9 | q &>> 23; q = x13 &+ x12; x14 ^= q &<< 13 | q &>> 19; q = x14 &+ x13; x15 ^= q &<< 18 | q &>> 14
        }
        t[0] &+= x0; t[1] &+= x1; t[2] &+= x2; t[3] &+= x3; t[4] &+= x4; t[5] &+= x5; t[6] &+= x6; t[7] &+= x7
        t[8] &+= x8; t[9] &+= x9; t[10] &+= x10; t[11] &+= x11; t[12] &+= x12; t[13] &+= x13; t[14] &+= x14; t[15] &+= x15
    }
}
