import Foundation

/// Engine and library errors can quote the configuration they choked on, private keys included. Nothing from them
/// reaches the log or the screen without passing through here.
///
/// Scans of the original text, character by character as `Character`s (what the patterns this replaced matched on),
/// rather than patterns applied in turn: every kind of secret is found in the text as it came, and all of it is hidden
/// at once, so hiding one kind never removes what another is found by. Where a secret's end is uncertain, the rest of
/// the text goes. Each scan also covers at least what the earlier patterns covered (see `earlierEnd`), so nothing they
/// hid is shown. Every scan reads each character a bounded number of times, or looks it up in a table built once.
nonisolated enum Redact {
    static func clean(_ s: String?) -> String {
        String(hiding(s ?? "").replacingOccurrences(of: "\n", with: " ").prefix(160))
    }

    /// What `clean` hides, without the cut: also how a value looks once cleaned, to find it again (see Diagnostics).
    static func hiding(_ s: String) -> String {
        var scan = Scan(Array(s))
        let logins = scan.logins()
        let found = Scan.merged(scan.assignments(logins: logins) + logins.map(\.all))
        let spans = Scan.merged(found + scan.spaced(around: found) + scan.blobs() + scan.invalidPorts())
        guard !spans.isEmpty else { return s }
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count)
        func copy(_ part: ArraySlice<Character>) { for c in part { out.append(contentsOf: c.utf8) } }
        var at = 0
        for r in spans {
            copy(scan.t[at..<r.lowerBound])
            out.append(contentsOf: "[hidden]".utf8)
            at = r.upperBound
        }
        copy(scan.t[at...])
        return String(decoding: out, as: UTF8.self)
    }

    /// A secret's name (any case; `_` where it may be left out), in the order the earlier pattern tried them.
    private static let names: [[Character]] = [
        "private_key", "privatekey", "pre_shared_key", "pre_sharedkey", "preshared_key", "presharedkey", "psk", "auth_key",
        "authkey", "api_key", "apikey", "credentials", "credential", "password", "passwd", "secret", "token",
    ].map { Array($0) }

    /// More names, which the earlier pattern did not know: the account and header fields of the providers. A short one
    /// counts only as a whole word (not inside `public_key` or `bypass`).
    private static let moreNames: [(name: [Character], whole: Bool)] = [
        ("authorization", false), ("account_number", false), ("account_id", false), ("secret_key", false), ("secretkey", false),
        ("client_key", false), ("clientkey", false), ("access_key", false), ("accesskey", false), ("passphrase", false),
        ("pt", true), ("key", true), ("pass", true), ("uuid", true),
    ].map { (Array($0.0), $0.1) }

    private static let authorization = Array("authorization")
    private static let key = Array("key")
    /// Names whose unquoted value, written after `:` or `=`, may hold blanks: it goes to the end of the line.
    private static let wholeLine: [[Character]] = ["password", "passwd", "secret", "passphrase"].map { Array($0) }

    /// One character as the text may quote it: itself, or escaped by a run of backslashes (at any depth of quoting).
    private enum Read: Equatable {
        /// Not escaped; or a `\uXXXX` or `\/` escape, decoded.
        case plain(Character), decoded(Character)
        /// `\n`, `\r`, `\t`, `\f`, `\v`: a blank once decoded.
        case blank
        /// A quote after [depth] backslashes (0: not escaped).
        case quote(Character, depth: Int)
    }

    /// A URL's login: [all] to the last `@` of its host part; [earlier], what the earlier pattern took of it, if anything.
    private struct Login {
        let all: Range<Int>
        let earlier: Range<Int>?
    }

    private struct Scan {
        let t: [Character]
        let n: Int
        /// Each character's ASCII code, 0 for any other (faster to compare than characters).
        private let a: [UInt8]
        /// Each character is a blank.
        private let w: [Bool]
        /// From each place: where its run of backslashes ends (itself if it isn't one).
        private let runEnd: [Int]
        /// From each place: where the next blank is.
        private var blanks: [Int]?
        /// From each place: where text that isn't quoted ends, at a blank but not at a line break escaped by a backslash.
        private var unquotedEnds: [Int]?
        /// From each place: where its line ends.
        private var lineEnds: [Int]?
        /// Each quote character's places, the backslashes right before each, and a tree of their least.
        private var quotes: [Character: Quotes] = [:]

        init(_ t: [Character]) {
            self.t = t
            n = t.count
            // (Not asciiValue: it reads the whole character, which can be long.)
            let a = t.map { c in c.utf8.count == 1 ? c.utf8.first! : c.utf8.count == 2 && c == "\r\n" ? 10 : 0 }
            self.a = a
            w = zip(t, a).map { c, b in b == 0 ? c.isWhitespace : b == 32 || (9...13).contains(b) }
            var ends = [Int](repeating: t.count, count: t.count + 1)
            var k = t.count - 1
            while k >= 0 { ends[k] = a[k] == 92 ? ends[k + 1] : k; k -= 1 }
            runEnd = ends
        }

        static func merged(_ spans: [Range<Int>]) -> [Range<Int>] {
            var out: [Range<Int>] = []
            for r in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) where !r.isEmpty {
                if let last = out.last, r.lowerBound < last.upperBound {
                    out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
                } else {
                    out.append(r)
                }
            }
            return out
        }

        /// The first index in sorted [values] at or after [i].
        static func lowerBound(_ i: Int, in values: [Int]) -> Int {
            var lo = 0, hi = values.count
            while lo < hi { let mid = (lo + hi) / 2; if values[mid] < i { lo = mid + 1 } else { hi = mid } }
            return lo
        }

        /// The span in sorted, disjoint [spans] that holds [i].
        static func index(of i: Int, in spans: [Range<Int>]) -> Int? {
            var lo = 0, hi = spans.count
            while lo < hi { let mid = (lo + hi) / 2; if spans[mid].upperBound <= i { lo = mid + 1 } else { hi = mid } }
            return lo < spans.count && spans[lo].contains(i) ? lo : nil
        }

        /// One of a-z in lower case, from that letter in any case, with marks on it or not, or a character that folds to it
        /// (the Kelvin sign, ſ, İ).
        static func fold(_ c: Character) -> Character? {
            // By its first scalar: the marks on it change nothing, and a character can be long.
            guard let first = c.unicodeScalars.first else { return nil }
            if first.isASCII {
                switch first.value {
                case 65...90: return Character(Unicode.Scalar(first.value + 32)!)
                case 97...122: return Character(first)
                default: return nil
                }
            }
            let p = first.properties
            for f in [p.lowercaseMapping, String(p.uppercaseMapping.unicodeScalars.first.map(Character.init) ?? " ").lowercased()] {
                if let l = f.unicodeScalars.first, ("a"..."z").contains(l) { return Character(l) }
            }
            return nil
        }

        /// [c] is [want] (a lower-case letter or `_`), in any case.
        static func same(_ c: Character, _ want: Character) -> Bool { want == "_" ? c == "_" : fold(c) == want }

        mutating func blank(from i: Int) -> Int {
            if blanks == nil {
                var at = [Int](repeating: n, count: n + 1)
                var k = n - 1
                while k >= 0 { at[k] = w[k] ? k : at[k + 1]; k -= 1 }
                blanks = at
            }
            return blanks![i]
        }

        mutating func unquotedEnd(_ v: Int) -> Int {
            if unquotedEnds == nil {
                var ends = [Int](repeating: n, count: n + 1)
                var k = n - 1
                while k >= 0 {
                    if w[k] {
                        ends[k] = k
                    } else if a[k] == 92, k + 1 < n, t[k + 1].isNewline {
                        ends[k] = ends[k + 2]  // A line continued with a backslash goes on.
                    } else {
                        ends[k] = ends[k + 1]
                    }
                    k -= 1
                }
                unquotedEnds = ends
            }
            return unquotedEnds![v]
        }

        /// The character at [i] and where the next starts.
        func read(_ i: Int) -> (Read, Int)? {
            guard i < n else { return nil }
            guard a[i] == 92 else { return (a[i] == 34 || a[i] == 39 ? .quote(t[i], depth: 0) : .plain(t[i]), i + 1) }
            let k = runEnd[i]
            guard k < n else { return (.plain("\\"), k) }
            switch a[k] {
            case 34, 39: return (.quote(t[k], depth: k - i), k + 1)
            case 110, 114, 116, 102, 118: return (.blank, k + 1)  // n r t f v
            case 47: return (.decoded("/"), k + 1)
            case 117:  // u
                guard k + 4 < n, a[(k + 1)...(k + 4)].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let v = UInt32(String(decoding: a[(k + 1)...(k + 4)], as: UTF8.self), radix: 16), let c = Unicode.Scalar(v) else {
                    return (.plain("\\"), k)
                }
                return (.decoded(Character(c)), k + 5)
            default: return (.plain("\\"), k)
            }
        }

        private func isBlank(_ r: Read) -> Bool {
            switch r {
            case .blank: return true
            case .plain(let c), .decoded(let c): return c.isWhitespace
            default: return false
            }
        }

        private func decodes(_ r: Read, to c: Character) -> Bool { r == .plain(c) || r == .decoded(c) }

        // MARK: name: value

        /// `name: value`, `"name":"value"` and the like, at any depth of quoting: from the name to the value's end. A value
        /// without quotes in a URL's login ("https://user:token=…@host") is that login's, hidden with it up to its `@`.
        mutating func assignments(logins: [Login]) -> [Range<Int>] {
            var out: [Range<Int>] = []
            let earlier = logins.compactMap(\.earlier)
            var l = 0
            for i in 0..<n {
                while l < logins.count, logins[l].all.upperBound <= i { l += 1 }
                let earlierLogin = l < logins.count && logins[l].earlier?.contains(i) == true
                guard let (end, quoted) = assignment(at: i) else { continue }
                if !quoted, earlierLogin { continue }
                var e = end
                // Never less than the earlier pattern took. It didn't see a name inside a login it had hidden first, and
                // saw logins as hidden: their characters never ended its value.
                if !earlierLogin, let b = earlierValueStart(i) { e = max(e, earlierEnd(b, earlier)) }
                // An Authorization header keeps its name: "Authorization: [hidden]".
                out.append((matches(Redact.authorization, at: i).flatMap { separator(after: $0) } ?? i)..<e)
                if e >= n { break }
            }
            return out
        }

        private mutating func assignment(at i: Int) -> (Int, quoted: Bool)? {
            // Most places start no name: only a-z, A-Z, a character beyond ASCII, or the first of a run of backslashes (an
            // escaped letter; read from inside the run it is the same letter, already found) can.
            switch a[i] {
            case 0, 65...90, 97...122: break
            case 92 where i == 0 || a[i - 1] != 92: break
            default: return nil
            }
            guard let (first, _) = read(i), let c = letter(first), c == "p" || c == "a" || c == "c" || c == "s" || c == "t" || c == "k" || c == "u" else { return nil }
            for name in Redact.names where name[0] == c {
                if let j = matches(name, at: i), let v = separator(after: j) {
                    let (end, quoted) = valueEnd(v)
                    return Redact.wholeLine.contains(name) && !quoted ? (lineEnd(v), false) : (end, quoted)
                }
            }
            for (name, whole) in Redact.moreNames where name[0] == c {
                guard let j = matches(name, at: i), !whole || !wordCharacter(before: i), let v = separator(after: j) else { continue }
                let (end, quoted) = valueEnd(v)
                // "key" is also an ordinary word ("invalid key: x"): only a value long enough to be a key counts.
                if name == Redact.key, end - v < 16 { continue }
                return (name == Redact.authorization || Redact.wholeLine.contains(name)) && !quoted ? (lineEnd(v), false) : (end, quoted)
            }
            return nil
        }

        /// Where [name] written from [i] ends (nil if it isn't there).
        private func matches(_ name: [Character], at i: Int) -> Int? {
            var j = i
            for want in name {
                guard let (r, next) = read(j), letter(r) == want else { return nil }
                j = next
            }
            return j
        }

        /// A letter, digit or `_` is right before [i] (the character itself, or the end of an escape).
        private func wordCharacter(before i: Int) -> Bool {
            guard i > 0 else { return false }
            var c = t[i - 1]
            // The end of an escape is that character, decoded: a blank after `\n`, `\t`; a `\uXXXX` as what it stands for.
            if i >= 2, a[i - 2] == 92, [110, 114, 116, 102, 118].contains(a[i - 1]) { return false }
            if i >= 6, a[i - 6] == 92, a[i - 5] == 117, let (r, _) = read(i - 6), case .decoded(let d) = r { c = d }
            return c == "_" || c == "-" || c.isLetter || c.isNumber
        }

        /// Where the line that holds [v] ends: at a line break, written plainly or as an escape (`\n`, `\r`).
        private mutating func lineEnd(_ v: Int) -> Int {
            if lineEnds == nil {
                var ends = [Int](repeating: n, count: n + 1)
                var k = n - 1
                while k >= 0 {
                    let continued = k > 0 && a[k - 1] == 92  // A line break after a backslash goes on.
                    ends[k] = (t[k].isNewline && !continued) || (a[k] == 92 && k + 1 < n && (a[k + 1] == 110 || a[k + 1] == 114)) ? k : ends[k + 1]
                    k -= 1
                }
                lineEnds = ends
            }
            return lineEnds![v]
        }

        /// A name's letter (or `_`), in lower case, written plainly or as an escape.
        private func letter(_ r: Read) -> Character? {
            switch r {
            case .plain(let c), .decoded(let c): return c.utf8.count == 1 && (c.utf8.first == 95 || c.utf8.first == 45) ? "_" : Scan.fold(c)
            default: return nil
            }
        }

        /// After a name: its closing quote if any, blanks, `:` or `=`, blanks. Where the value starts.
        private func separator(after e: Int) -> Int? {
            var j = e
            if let (r, next) = read(j) {
                switch r {
                case .quote, .decoded("\""), .decoded("'"): j = next
                default: break
                }
            }
            j = blanks(from: j)
            guard let (r, next) = read(j), decodes(r, to: ":") || decodes(r, to: "=") || decodes(r, to: "\u{FF1A}") else { return nil }
            return blanks(from: next)
        }

        private func blanks(from j: Int) -> Int {
            var j = j
            while let (r, next) = read(j), isBlank(r) { j = next }
            return j
        }

        /// A quoted value to its closing quote; an empty list or object to its end; any other list or object, or a value
        /// opened by an escape other than a quote's, to the end of the text (where those end isn't certain); anything else
        /// to the next blank. [quoted]: not the last kind.
        private mutating func valueEnd(_ v: Int) -> (Int, quoted: Bool) {
            guard let (r, next) = read(v) else { return (n, false) }
            switch r {
            case .quote(let q, let depth): return (quoted(from: next, q, depth), true)
            case .plain("["), .plain("{"):
                let close: Character = r == .plain("[") ? "]" : "}"
                if let (c, after) = read(blanks(from: next)), c == .plain(close) { return (after, true) }
                return (n, true)
            case .decoded: return (n, true)
            default: return (unquotedEnd(v), false)
            }
        }

        /// The end of a value opened by [q] after [depth] backslashes. Opened by a plain double quote: a backslash escapes
        /// the next character, whatever it is (a line break too), and the next quote not escaped ends it. Otherwise it ends
        /// at a quote after exactly [depth] backslashes; one after more is part of it; one after fewer leaves its end
        /// uncertain (the text isn't quoted as it started), so the rest goes. A plain single quote is one after none: a
        /// JSON string around it doubles the backslashes of an escaped one inside but adds none to it.
        private mutating func quoted(from start: Int, _ q: Character, _ depth: Int) -> Int {
            if q == "\"" && depth == 0 {
                var j = start
                while j < n {
                    if a[j] == 92 { j += 2 } else if a[j] == 34 { return j + 1 } else { j += 1 }
                }
                return n
            }
            if quotes[q] == nil { quotes[q] = Quotes(q.asciiValue!, a, runEnd) }
            guard let (at, run) = quotes[q]!.first(from: start, atMost: depth) else { return n }
            return run == depth ? at + 1 : n
        }

        /// Where the earlier pattern, `(?i)(name)["']?\s*[:=]\s*`, started the value of a name at [i]; nil if it took none.
        private func earlierValueStart(_ i: Int) -> Int? {
            let c = Scan.fold(t[i])
            for name in Redact.names where name[0] == c {
                guard i + name.count <= n, zip(t[i..<(i + name.count)], name).allSatisfy(Scan.same) else { continue }
                var j = i + name.count
                if j < n, a[j] == 34 || a[j] == 39 { j += 1 }
                while j < n, w[j] { j += 1 }
                guard j < n, a[j] == 58 || a[j] == 61 else { continue }
                j += 1
                while j < n, w[j] { j += 1 }
                return j
            }
            return nil
        }

        /// How far the earlier pattern took a value from [b]: a plainly quoted one to its quote (it saw logins already
        /// hidden, so the characters of [logins] it had hidden are skipped), anything else to the next blank.
        private mutating func earlierEnd(_ b: Int, _ logins: [Range<Int>]) -> Int {
            guard b < n, a[b] == 34 || a[b] == 39 else { return blank(from: b) }
            let q = a[b]
            var l = 0, hi = logins.count
            while l < hi { let mid = (l + hi) / 2; if logins[mid].upperBound <= b + 1 { l = mid + 1 } else { hi = mid } }
            var j = b + 1
            while j < n {
                while l < logins.count, logins[l].upperBound <= j { l += 1 }
                if l < logins.count, logins[l].contains(j) { j = logins[l].upperBound; continue }
                if a[j] == 92 { j += 2; continue }
                if a[j] == q { return j + 1 }
                j += 1
            }
            return n
        }

        // MARK: password hunter2

        /// "password hunter2": a password word, a blank, then what follows up to the next blank. A secret [found] in that
        /// counts as one word, as it did when it was hidden before this was looked for.
        mutating func spaced(around found: [Range<Int>]) -> [Range<Int>] {
            // From each found span: where the word it is part of ends.
            var wordEnds = [Int](repeating: n, count: found.count)
            for s in found.indices.reversed() {
                let e = blank(from: found[s].upperBound)
                wordEnds[s] = Scan.index(of: e, in: found).map { wordEnds[$0] } ?? e
            }
            var out: [Range<Int>] = []
            for i in 0..<n where a[i] == 112 || a[i] == 80 || a[i] == 98 || a[i] == 66 || a[i] == 0 && (Scan.fold(t[i]) == "p" || Scan.fold(t[i]) == "b") {
                for name in Scan.passwords {
                    guard i + name.count < n, zip(t[i..<(i + name.count)], name).allSatisfy(Scan.same), w[i + name.count] else { continue }
                    var k = i + name.count
                    while k < n, w[k] { k += 1 }
                    guard k < n else { continue }
                    var e = blank(from: k)
                    // "password is hunter2": the word after "is" is the password.
                    if e - k == 2, e < n, Scan.same(t[k], "i"), Scan.same(t[k + 1], "s") {
                        var m = e
                        while m < n, w[m] { m += 1 }
                        if m < n { e = valueEnd(m).0 }
                    }
                    out.append(i..<(Scan.index(of: e, in: found).map { wordEnds[$0] } ?? e))
                    break
                }
            }
            return out
        }

        private static let passwords: [[Character]] = [Array("password"), Array("passwd"), Array("bearer")]

        // MARK: Go's URL errors

        /// `invalid port ":abc" after host`: Go quotes what follows the host's colon, which is the start of a password
        /// that holds a "/".
        mutating func invalidPorts() -> [Range<Int>] {
            let phrase = Array("invalid port ".utf8)
            var out: [Range<Int>] = []
            let count = phrase.count
            for i in 0..<n {
                guard a[i] == 105 || a[i] == 73, i + count < n, a[i + count] == 34 else { continue }
                var same = true
                for k in 0..<count where a[i + k] != phrase[k] && a[i + k] != phrase[k] &- 32 { same = false; break }
                guard same else { continue }
                let q = i + count
                out.append(q..<quoted(from: q + 1, "\"", 0))
            }
            return out
        }

        // MARK: URL logins

        /// The login in a URL ("ss://method:pass@host", "https://user:pass@host", "https:\/\/…" or with `\u` escapes, as
        /// a string quotes it): from after `//` to the last `@` before the host part ends (at a blank or a `/`), so an `@`
        /// in a password hides it whole.
        mutating func logins() -> [Login] {
            // Where the host part ends, from each place; where the "@"s (plain, or escaped as "@") and ":"s are.
            var stops = [Int](repeating: n, count: n + 1)
            var k = n - 1
            while k >= 0 { stops[k] = w[k] || a[k] == 47 ? k : stops[k + 1]; k -= 1 }
            // From each place: the last ":" before it, the last "." or ":" before it, and where its run of digits ends.
            var colonBefore = [Int](repeating: -1, count: n + 1), dotBefore = [Int](repeating: -1, count: n + 1)
            for q in 0..<n {
                colonBefore[q + 1] = a[q] == 58 ? q : colonBefore[q]
                dotBefore[q + 1] = a[q] == 58 || a[q] == 46 ? q : dotBefore[q]
            }
            var digitsEnd = [Int](repeating: n, count: n + 1)
            k = n - 1
            while k >= 0 { digitsEnd[k] = (48...57).contains(a[k]) ? digitsEnd[k + 1] : k; k -= 1 }
            var ats: [Int] = [], atEnds: [Int] = [], plainAts: [Int] = []
            for i in 0..<n {
                if a[i] == 64 { ats.append(i); atEnds.append(i + 1); plainAts.append(i) }
                if a[i] == 92, i == 0 || a[i - 1] != 92, let (r, next) = read(i), r == .decoded("@") { ats.append(i); atEnds.append(next) }
            }
            var out: [Login] = []
            for i in 0..<n where a[i] == 58 || a[i] == 92 && (i == 0 || a[i - 1] != 92) {
                guard let (r, next) = read(i), decodes(r, to: ":"), i > 0, let s = slash(next), let a = slash(s) else { continue }
                var k = i
                var letter = false, ascii = false, asciiRun = true
                while k > 0, scheme(t[k - 1]) {
                    k -= 1
                    letter = letter || Scan.fold(t[k]) != nil
                    asciiRun = asciiRun && t[k].isASCII
                    ascii = ascii || asciiRun && Scan.fold(t[k]) != nil
                }
                guard letter else { continue }
                let hostEnd = stops[a]
                // A "/" in the password ("user:pa/ss@host"): what comes before the first "/" can't be a host and port (what
                // follows its last ":" isn't a number), so the login goes on to the next blank.
                var stop = hostEnd
                if hostEnd < n, self.a[hostEnd] == 47, self.a[a] != 91, !(ats[Scan.lowerBound(a, in: ats)..<ats.count].first.map { $0 < hostEnd } ?? false), case let colon = colonBefore[hostEnd], colon >= a,
                   colon + 1 < hostEnd, digitsEnd[colon + 1] < hostEnd {
                    stop = blank(from: hostEnd)
                } else if hostEnd < n, self.a[hostEnd] == 47, i - k == 2, zip(t[k..<i], "ss").allSatisfy({ Scan.same($0, $1) }),
                          !(ats[Scan.lowerBound(a, in: ats)..<ats.count].first.map { $0 < hostEnd } ?? false),
                          dotBefore[hostEnd] < a {
                    // A Shadowsocks link's login is Base64, which holds "/" too.
                    stop = blank(from: hostEnd)
                }
                let firstAt = Scan.lowerBound(a, in: ats)
                let lastAt = Scan.lowerBound(stop, in: ats) - 1
                guard firstAt <= lastAt, ats[lastAt] > a else {
                    // Cut off (a truncated message) before an "@": a login can't be told from a host name, so it goes
                    // unless it is an IP address.
                    if stop == n, !address(a) { out.append(Login(all: a..<n, earlier: nil)) }
                    continue
                }
                // The earlier pattern: "scheme://" in plain ASCII, then up to the first plain "@".
                let plain = Scan.lowerBound(a, in: plainAts)
                let literal = ascii && t[i] == ":" && a == i + 3
                let earlier = literal && plain < plainAts.count && plainAts[plain] < hostEnd && plainAts[plain] > a ? a..<plainAts[plain] : nil
                // Cut off after an "@", what follows may still be the password's (after an "@" in it), even if it looks
                // like a host name: it goes too, unless it is an IP address.
                let end = stop == n && !address(atEnds[lastAt]) ? n : ats[lastAt]
                out.append(Login(all: a..<end, earlier: earlier))
            }
            return out
        }

        /// Past a `/`, plain or escaped (`\/`, `/`, at any depth).
        private func slash(_ i: Int) -> Int? {
            guard let (r, next) = read(i), decodes(r, to: "/") else { return nil }
            return next
        }

        private func scheme(_ c: Character) -> Bool { Scan.fold(c) != nil || (c.isASCII && (c.isNumber || "+.-".contains(c))) }

        /// The text from [i] to the end is an IP address (IPv4, or IPv6 in brackets) and maybe a port, nothing else. Reads
        /// at most an address's length.
        private func address(_ i: Int) -> Bool {
            var j = i
            if j < n, a[j] == 91 {
                // "[" IPv6 "]": eight groups of 1-4 hex digits, or fewer with one "::".
                var text: [UInt8] = []
                j += 1
                while j < n, a[j] != 93 { guard text.count < 39 else { return false }; text.append(a[j]); j += 1 }
                guard j < n, Scan.ipv6(text) else { return false }
                j += 1
            } else {
                // Four numbers of 0-255.
                var parts = 0, digits = 0, value = 0
                while j < n, a[j] != 58 {
                    if a[j] == 46 {
                        guard digits > 0, parts < 3 else { return false }
                        parts += 1; digits = 0; value = 0
                    } else if (48...57).contains(a[j]), digits < 3 {
                        value = value * 10 + Int(a[j] - 48); digits += 1
                        guard value <= 255 else { return false }
                    } else {
                        return false
                    }
                    j += 1
                }
                guard parts == 3, digits > 0 else { return false }
            }
            if j < n, a[j] == 58 {
                // ":port", 1 to 65535.
                var port = 0, digits = 0
                j += 1
                while j < n, (48...57).contains(a[j]) { guard digits < 5 else { return false }; port = port * 10 + Int(a[j] - 48); digits += 1; j += 1 }
                guard (1...5).contains(digits), (1...65535).contains(port) else { return false }
            }
            return j == n
        }

        static func ipv6(_ s: [UInt8]) -> Bool {
            func groups(_ part: ArraySlice<UInt8>) -> Int? {
                if part.isEmpty { return 0 }
                var count = 0
                for g in part.split(separator: 58, omittingEmptySubsequences: false) {
                    guard (1...4).contains(g.count), g.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
                    count += 1
                }
                return count
            }
            var double: Int?
            for k in s.indices.dropLast() where s[k] == 58 && s[k + 1] == 58 {
                guard double == nil else { return false }
                double = k
            }
            guard let d = double else { return groups(s[...]) == 8 }
            guard let left = groups(s[..<d]), let right = groups(s[(d + 2)...]) else { return false }
            return left + right <= 7
        }

        // MARK: keys

        /// Runs of 40 or more Base64 (or URL-safe Base64) characters, with up to two `=` after: keys, whatever their name.
        /// A character may be written as an escape (`\/`, `\u002b`) or carry a combining mark. A key wrapped over lines
        /// goes whole: the lines after a full one (the last is shorter), or lines of 16 or more characters that hold a
        /// digit, `+` or `=` and add up to 40 (a key split in two).
        func blobs() -> [Range<Int>] {
            var out: [Range<Int>] = []
            var i = 0
            while i < n {
                guard a[i] == 92 || a[i] == 0 || base64(a[i]), let first = piece(at: i) else { i += 1; continue }
                var end = first.end, total = first.count, last = first.count
                var keylike = first.keylike
                let start = first.count >= 16
                var next = first.count < 16 ? nil : lineBreak(after: end).flatMap { piece(at: $0) }
                var closed = false  // A line shorter than the one before it is a key's last.
                while let p = next, (!closed && total >= 40 && p.count <= last && (p.padded || p.count >= 8 && p.keylike))
                        || (p.count >= 16 && (start || total >= 40) && (keylike || p.keylike)) {
                    keylike = keylike || p.keylike
                    closed = closed || p.count < last
                    end = p.end; total += p.count; last = p.count
                    next = lineBreak(after: end).flatMap { piece(at: $0) }
                }
                if total >= 40 {
                    out.append(i..<end)
                    i = end
                } else {
                    i = first.end
                }
            }
            return out
        }

        /// The run of Base64 characters that starts at [i], with the `=` after it (up to two); nil if there is none.
        private func piece(at i: Int) -> (end: Int, count: Int, keylike: Bool, padded: Bool)? {
            var j = i, count = 0, keylike = false
            while j < n {
                let plain = a[j]
                if plain != 92 && plain != 0 {  // (The usual case, quickly.)
                    guard base64(plain) else { break }
                    count += 1
                    keylike = keylike || plain == 43 || (48...57).contains(plain)
                    j += 1
                    continue
                }
                guard let (c, next) = base64(at: j) else { break }
                count += 1
                keylike = keylike || c == 43 || (48...57).contains(c)
                j = next
            }
            guard count > 0 else { return nil }
            var pad = 0
            while pad < 2, let (c, next) = base64(at: j, padding: true), c == 61 { j = next; pad += 1; keylike = true }
            return (j, count + pad, keylike, pad > 0)
        }

        /// A line break (one, or a carriage return and a line feed), written plainly or as an escape: where the next line starts.
        private func lineBreak(after i: Int) -> Int? {
            var j = i, breaks = 0
            while breaks < 2, let (r, next) = read(j) {
                switch r {
                case .blank: break
                case .plain(let c) where c.isNewline, .decoded(let c) where c.isNewline: break
                default: return breaks > 0 ? j : nil
                }
                j = next; breaks += 1
            }
            return breaks > 0 ? j : nil
        }

        /// The Base64 character (ASCII code) at [i], as it is written plainly, as an escape, or with combining marks after
        /// it; and where the next starts. [padding]: `=` counts, nothing else does.
        private func base64(at i: Int, padding: Bool = false) -> (UInt8, Int)? {
            guard i < n else { return nil }
            var code = a[i], next = i + 1
            if code == 92 {
                guard let (r, after) = read(i), case .decoded(let c) = r, c.utf8.count == 1 else { return nil }
                code = c.utf8.first!; next = after
            } else if code == 0 {
                guard let s = t[i].unicodeScalars.first, s.isASCII, t[i].unicodeScalars.dropFirst().allSatisfy({ $0.properties.generalCategory == .nonspacingMark }) else { return nil }
                code = UInt8(s.value)
            }
            return padding ? (code == 61 ? (code, next) : nil) : (base64(code) ? (code, next) : nil)
        }

        private func base64(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) || b == 43 || b == 47 || b == 95 || b == 45 }
    }

    /// One quote character's places in the text, with the backslashes right before each, to find in logarithmic time the
    /// first at or after a place with at most so many.
    private struct Quotes {
        let at: [Int]
        private var tree: [Int]
        private let size: Int

        init(_ q: UInt8, _ t: [UInt8], _ runEnd: [Int]) {
            var at: [Int] = [], runs: [Int] = []
            var i = 0
            while i < t.count {
                if t[i] == 92 {
                    let k = runEnd[i]
                    if k < t.count, t[k] == q { at.append(k); runs.append(k - i) }
                    i = k + (k < t.count && t[k] == q ? 1 : 0)
                } else {
                    if t[i] == q { at.append(i); runs.append(0) }
                    i += 1
                }
            }
            self.at = at
            var size = 1
            while size < max(runs.count, 1) { size *= 2 }
            self.size = size
            tree = [Int](repeating: .max, count: 2 * size)
            for (k, r) in runs.enumerated() { tree[size + k] = r }
            var k = size - 1
            while k >= 1 { tree[k] = min(tree[2 * k], tree[2 * k + 1]); k -= 1 }
        }

        /// The first quote at or after [start] with at most [limit] backslashes before it: where, and how many.
        func first(from start: Int, atMost limit: Int) -> (Int, Int)? {
            let lo = Scan.lowerBound(start, in: at)
            guard lo < at.count, let k = find(1, 0, size, lo, limit) else { return nil }
            return (at[k], tree[size + k])
        }

        private func find(_ node: Int, _ l: Int, _ r: Int, _ lo: Int, _ limit: Int) -> Int? {
            if r <= lo || tree[node] > limit { return nil }
            if r - l == 1 { return l }
            let mid = (l + r) / 2
            return find(2 * node, l, mid, lo, limit) ?? find(2 * node + 1, mid, r, lo, limit)
        }
    }
}
