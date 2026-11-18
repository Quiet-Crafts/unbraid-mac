import CryptoKit
import Foundation

/// Websites with a route of their own (`Setup.sites`): how an address is written, and how many a profile holds.
nonisolated enum Sites {
    static let max = SiteMatch.max
    /// How many a saved setup may hold when read (see `Setup.readable`).
    static let readMax = 4 * max

    /// The address in `raw` as a rule keeps it, from what people type or paste ("https://www.Example.com/page" →
    /// "example.com"): the name alone, lower case, without "www.", international names in their ASCII form. A rule
    /// covers the name and every name under it. Nil when it names no website: no dot, an IP address, or characters no
    /// name has. What a saved setup may hold; what a new one may be is `refusal`'s to say.
    static func clean(_ raw: String) -> String? { if case .name(let name) = read(raw) { name } else { nil } }

    /// Whether `name` is an address exactly as `clean` writes one: what a saved rule must be.
    static func isClean(_ name: String) -> Bool { clean(name) == name }

    /// Why `raw` can't be added as a website, in the Add Website sheet's words; nil when it can. Beyond what `clean`
    /// refuses: names no rule can ever work for (`never`), and endings many websites share. For what is typed only: a
    /// saved setup keeps what it holds (the compiler leaves out what can't work). A name a rule can work for, but that
    /// its own resolver answers in this setup, is taken: `notApplied` says so.
    static func refusal(_ raw: String) -> String? {
        switch read(raw) {
        case .refused(let why): return why
        case .name(let name):
            if let why = never(name) { return why }
            guard suffixes != nil else { return damaged }
            return shared(name) ? "\(name) ends many websites' names: add one website under it" : nil
        }
    }

    /// Why no website rule can ever work for `name`, whatever the setup: no app ever connects to it by a name unbraid
    /// answers. `.local` names are answered by the devices themselves (multicast), never through unbraid.
    private static func never(_ name: String) -> String? {
        let no = "unbraid can't give it a rule"
        if under(name, "local") { return "\(name) is answered by the devices on your network themselves, never through unbraid: \(no)" }
        if under(name, "localhost") { return "\(name) is this Mac itself: \(no)" }
        if under(name, "arpa"), !under(name, "home.arpa") { return "\(name) is a lookup of an address, not a website: \(no)" }
        return nil
    }

    /// Why `setup`'s rule for `name` on `route` doesn't apply in this setup, or nil when it does: the resolver that
    /// answers the name here is one a website rule would wrongly take it from (`Compiler.answered`), so the compiler
    /// leaves the rule out. A block always applies. `tailnet`: the tailnet's domain, as the compiler is given it.
    static func notApplied(_ name: String, _ route: String, in setup: Setup, tailnet: String?) -> String? {
        guard route != BLOCK, let answered = Compiler.answered(name, setup, tailnet: tailnet) else { return nil }
        return switch answered {
        case .tailscale: "Tailscale answers ts.net names while Reach your tailnet is on"
        case .tailnet: "your tailnet answers this name while Reach your tailnet is on"
        case .tailnetClosed: "unbraid leaves your tailnet's names unanswered while Reach your tailnet is off"
        case .local: "your network answers this name while Reach devices on this network is on"
        case .reverse: "your network answers lookups of its own addresses"
        case .multicast: "the devices on your network answer .local names themselves, never through unbraid"
        case .loopback: "this name is this Mac itself, which apps reach without unbraid"
        }
    }

    /// The one decision of which of `setup`'s websites apply: clean names, a block always, a route or Direct unless
    /// `notApplied` (its own resolver answers it in this setup; with Reach your tailnet off, a Tailscale Funnel site
    /// under ts.net works like any other). The compiler writes rules for these only, and statistics, every count, the
    /// widgets, the rows and restore's comparison go by the same. `tailnet` is normalised by the compiler's own reading.
    static func applied(_ setup: Setup, tailnet: String?) -> [String: String] {
        setup.sites.filter { isClean($0.key) && notApplied($0.key, $0.value, in: setup, tailnet: tailnet) == nil }
    }

    /// `applied` with `setup`'s own tailnet domain (`tailnet(of:)`): what every part of the app but the compiler,
    /// which is handed the same domain with its input, uses.
    static func applied(_ setup: Setup) -> [String: String] { applied(setup, tailnet: tailnet(of: setup)) }

    /// Why `setup`'s saved rule for `name` doesn't apply, as the app judges it (`tailnet(of:)`); nil when it does.
    static func notApplied(_ name: String, in setup: Setup) -> String? {
        setup.sites[name].flatMap { notApplied(name, $0, in: setup, tailnet: tailnet(of: setup)) }
    }

    /// How many of `sites` (`setup`'s own or a saved profile's) don't apply in `setup` (see `applied`).
    static func notAppliedCount(_ sites: [String: String], in setup: Setup) -> Int {
        var s = setup
        s.sites = sites
        return sites.count - applied(s).count
    }

    /// Whether `setup`'s rule for `name` applies (see `applied`).
    static func isApplied(_ name: String, in setup: Setup) -> Bool { applied(setup)[name] != nil }

    /// The tailnet domain `setup`'s websites are judged by: the one the setup has accepted while Tailscale runs, as
    /// `Store.tsSuffix` reads it and the engine is given it.
    static func tailnet(of setup: Setup) -> String? { setup.tailnetCounts ? Compiler.tsSuffix(Compiler.trustedStoredSuffix(setup.home)) : nil }

    /// The websites blocked in `before` that `after` opens, whole or in part: no longer blocked itself, or a name under
    /// it given a route or Direct of its own there (the most specific rule wins, Block included). A name under it that
    /// was open before already opens nothing new.
    /// Given websites alone, judged without a tailnet domain; `opened(_:_:)` with the setups judges them as the app does.
    static func opened(_ before: [String: String], _ after: [String: String]) -> [String] {
        opened(Setup(routes: [], defaultRoute: DIRECT, apps: [:], sites: before), Setup(routes: [], defaultRoute: DIRECT, apps: [:], sites: after))
    }

    static func opened(_ before: Setup, _ after: Setup) -> [String] {
        func gets(_ name: String, _ rules: [String: String]) -> String? { rules.filter { under(name, $0.key) }.max { $0.key.count < $1.key.count }?.value }
        let was = applied(before), now = applied(after)
        let holes = now.filter { $0.value != BLOCK && gets($0.key, was) == BLOCK }.keys
        return before.sites.filter { b in b.value == BLOCK && (gets(b.key, now) != BLOCK || holes.contains { under($0, b.key) }) }.keys.sorted()
    }

    /// Whether `name` is `suffix` or a name under it.
    static func under(_ name: String, _ suffix: String) -> Bool { name == suffix || name.hasSuffix("." + suffix) }

    private enum Read { case name(String), refused(String) }

    /// The longest text read as an address: longer is refused whole, never cut into another address.
    static let paste = 2000

    private static func read(_ raw: String) -> Read {
        if raw.count > paste { return .refused("That is too long for an address: paste the link alone") }
        // Read as a browser reads a web address: tabs and line breaks anywhere are dropped and a backslash is a slash,
        // so "example.com\\@evil.com" opens example.com (the rest is its path), and is saved as that.
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines).filter { !"\t\n\r".contains($0) }.replacingOccurrences(of: "\\", with: "/")
        var host = typed[...]
        if let scheme = host.prefixMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*:\/+/) { host = host[scheme.range.upperBound...] }
        // The host ends where the path, query or fragment starts; only an "@" before that ends a user name.
        for end in ["/", "?", "#"] { if let r = host.range(of: end) { host = host[..<r.lowerBound] } }
        if let at = host.range(of: "@", options: .backwards) { host = host[at.upperBound...] }
        // An IPv6 address, bracketed in a link or bare: two colons or more, or a bracket.
        if host.hasPrefix("[") || host.filter({ $0 == ":" }).count > 1 { return .refused(address) }
        if let port = host.range(of: ":") { host = host[..<port.lowerBound] }
        guard var name = ascii(String(host).trimmingCharacters(in: CharacterSet(charactersIn: "."))) else { return .refused(notAName) }
        // Every leading "www." goes while a name is left, so what is kept reads back as itself.
        // A leading "www." stays when what is left would be a shared ending: www.gob.mx is a website, gob.mx all of Mexico's.
        while name.hasPrefix("www."), name.dropFirst(4).contains("."), !shared(String(name.dropFirst(4))) { name.removeFirst(4) }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        // A last label that reads as a number (digits, or 0x and hex digits) makes it an IP address to a browser, which
        // connects to it without a lookup: nothing a rule could match, and nothing a name ends in.
        let last = labels[labels.count - 1]
        if last.allSatisfy(\.isNumber) || (last.hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit)) {
            return .refused(labels.count > 1 && !last.isEmpty ? address : notAName)
        }
        guard name.utf8.count <= 253, labels.allSatisfy(label) else { return .refused(notAName) }
        guard labels.count >= 2 else { return .refused(never(name) ?? "Add the whole name, such as \(name).com") }
        return .name(name)
    }

    private static let notAName = "That isn't a website address"
    private static let address = "An IP address can't have a rule: add the website's name"
    /// A name that is itself an ending many unrelated websites share ("co.uk"), or the base of one ("sch.uk", above
    /// every "*.sch.uk"): a rule would cover them all. The Public Suffix List's ICANN section as
    /// `Resources/shared_suffixes.txt` holds it (its wildcard and exception rules included), and hosting platforms where
    /// everyone gets a name of their own (the list's private section, kept short). Without a sound list only those.
    static func shared(_ name: String) -> Bool {
        if platforms.contains(name) { return true }
        guard let suffixes else { return false }
        let parent = name.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        return suffixes.contains(name) || suffixes.contains("*." + name) || suffixes.contains("*." + parent) && !suffixes.contains("!" + name)
    }

    /// The bundled list's rules, read once; nil when the file isn't the one this build ships (missing, cut short or
    /// changed): Add Website then takes no new website (`damaged`), rather than one a sound list would refuse.
    static let suffixes: Set<String>? = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "shared_suffixes", withExtension: "txt"),
              let data = try? Data(contentsOf: url), SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == suffixesDigest,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }()

    /// SHA-256 of `Resources/shared_suffixes.txt` as shipped.
    static let suffixesDigest = "f29b2747d562a0eaa907af6fee2b35805789121f9a19dfad9d6b3561be465e47"

    /// Why no website can be added while the list is unsound.
    static let damaged = "unbraid's list of shared name endings is damaged, so no website can be added: install unbraid again"

    private final class BundleToken {}

    private static let platforms: Set = ["github.io", "gitlab.io", "blogspot.com", "herokuapp.com", "appspot.com", "netlify.app",
                                         "vercel.app", "pages.dev", "workers.dev", "web.app", "firebaseapp.com",
                                         "azurewebsites.net", "cloudfront.net", "s3.amazonaws.com", "ts.net"]

    /// `sites`, most specific first (a name under another comes before it), as runs that share a route: the route's id
    /// and its addresses. The engine takes the first rule that matches, so a longer name must come before a shorter one
    /// that covers it.
    static func runs(_ sites: [String: String]) -> [(id: String, names: [String])] {
        let ordered = sites.sorted { a, b in
            let da = a.key.filter { $0 == "." }.count, db = b.key.filter { $0 == "." }.count
            return (db, a.value, a.key) < (da, b.value, b.key)
        }
        var runs: [(id: String, names: [String])] = []
        for (site, id) in ordered {
            if runs.last?.id == id { runs[runs.count - 1].names.append(site) } else { runs.append((id, [site])) }
        }
        return runs
    }

    /// `name` as people read it: an international name in its own letters ("xn--mnchen-3ya.de" → "münchen.de").
    /// Only a decoding that writes back to `name` itself, and, as browsers show names, only when no label mixes scripts
    /// or is made of letters that look like Latin ones ("xn--pple-43d.example" stays, not "аpple.example"): anything
    /// else stays in its ASCII form.
    static func shown(_ name: String) -> String {
        guard let decoded = decoded(name), decoded.split(separator: ".").allSatisfy({ plain($0) }) else { return name }
        return decoded
    }

    /// What a search of the list matches `name` by: the name, its own letters, and those letters read as the Latin
    /// ones they look like.
    static func readings(_ name: String) -> [String] {
        guard let decoded = decoded(name) else { return [name] }
        return [name, decoded, String(decoded.map { lookalike[$0] ?? $0 })]
    }

    /// `name`'s labels in their own letters, when that writes back to `name` itself (nil for any other).
    private static func decoded(_ name: String) -> String? {
        guard name.contains("xn--") else { return nil }
        let decoded = name.split(separator: ".", omittingEmptySubsequences: false).map { l in
            l.hasPrefix("xn--") ? Punycode.decode(l.dropFirst(4)).flatMap { $0.isEmpty ? nil : $0 } ?? String(l) : String(l)
        }.joined(separator: ".")
        return decoded != name && ascii(decoded) == name ? decoded : nil
    }

    /// Letters of other scripts that look like Latin ones, with the Latin letter each looks like.
    private static let lookalike: [Character: Character] = Dictionary(uniqueKeysWithValues: zip("асԁеһіјӏорԛѕԝхуαικνορτυχօսհոց", "acdehijlopqswxyaikvoptuxouhng"))

    /// A label browsers show in its own letters: of one script (Latin may go with Chinese, Japanese or Korean, as they
    /// allow), and, in a script other than Latin, not made only of letters that look like Latin ones.
    private static func plain(_ label: Substring) -> Bool {
        let scripts = Set(label.unicodeScalars.compactMap(script))
        let mixes: [Set<String>] = [["latin", "han", "hiragana", "katakana"], ["latin", "han", "bopomofo"], ["latin", "han", "hangul"]]
        if scripts.count > 1 && !mixes.contains(where: { scripts.isSubset(of: $0) }) { return false }
        return scripts.isEmpty || scripts == ["latin"] || !label.allSatisfy { lookalike[$0] != nil || $0.isNumber || $0 == "-" }
    }

    private static let blocks: [(ClosedRange<UInt32>, String)] = [
        (0x41...0x24F, "latin"), (0x1E00...0x1EFF, "latin"), (0x2C60...0x2C7F, "latin"), (0xA720...0xA7FF, "latin"), (0xAB30...0xAB6F, "latin"),
        (0x370...0x3FF, "greek"), (0x1F00...0x1FFF, "greek"),
        (0x400...0x52F, "cyrillic"), (0x1C80...0x1C8F, "cyrillic"), (0x2DE0...0x2DFF, "cyrillic"), (0xA640...0xA69F, "cyrillic"),
        (0x530...0x58F, "armenian"), (0x590...0x5FF, "hebrew"), (0xFB1D...0xFB4F, "hebrew"),
        (0x600...0x6FF, "arabic"), (0x750...0x77F, "arabic"), (0x870...0x8FF, "arabic"), (0xFB50...0xFDFF, "arabic"), (0xFE70...0xFEFF, "arabic"),
        (0x1100...0x11FF, "hangul"), (0x3130...0x318F, "hangul"), (0xA960...0xA97F, "hangul"), (0xAC00...0xD7FF, "hangul"),
        (0x3040...0x309F, "hiragana"), (0x30A0...0x30FF, "katakana"), (0x31F0...0x31FF, "katakana"), (0xFF66...0xFF9F, "katakana"),
        (0x3100...0x312F, "bopomofo"), (0x31A0...0x31BF, "bopomofo"),
        (0x2E80...0x2FDF, "han"), (0x3005...0x3007, "han"), (0x3021...0x3029, "han"), (0x3400...0x4DBF, "han"), (0x4E00...0x9FFF, "han"),
        (0xF900...0xFAFF, "han"), (0x20000...0x3FFFF, "han"),
    ]

    /// The script of a letter, by its block; nil for digits, the hyphen and marks, which go with any script. Foundation
    /// has no script property: blocks it doesn't name stand for a script of their own, so two of them read as a mix
    /// (shown in ASCII, the safe side).
    private static func script(_ c: Unicode.Scalar) -> String? {
        let v = c.value
        switch c.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber: return nil
        default: break
        }
        if v == 0x2D || v == 0x30FC { return nil }
        return blocks.first { $0.0.contains(v) }?.1 ?? "block-\(v >> 7)"
    }

    /// A label of a name: letters, digits and hyphens, neither first nor last a hyphen, at most 63.
    private static func label(_ l: Substring) -> Bool {
        let u = Array(l.utf8)
        func alnum(_ c: UInt8) -> Bool { (c >= 97 && c <= 122) || (c >= 48 && c <= 57) }
        return (1...63).contains(u.count) && alnum(u[0]) && alnum(u[u.count - 1]) && u.allSatisfy { alnum($0) || $0 == 45 }
    }

    /// `host` in lower case, an international name in its ASCII (punycode) form; nil when it can't be one.
    private static func ascii(_ host: String) -> String? {
        let lower = host.lowercased()
        if lower.utf8.allSatisfy({ $0 < 128 }) { return lower }
        // Foundation writes an international host in its ASCII form; anything it can't is no name.
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = lower
        guard let encoded = parts.encodedHost?.lowercased(), !encoded.isEmpty, encoded.utf8.allSatisfy({ $0 < 128 }), !encoded.contains("%") else { return nil }
        return encoded
    }
}

/// Punycode (RFC 3492) decoding, for showing an international name's label in its own letters. Foundation encodes
/// hosts but gives nothing back to read them.
nonisolated enum Punycode {
    static func decode(_ s: Substring) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        var out: [Unicode.Scalar] = []
        var input = Array(s.unicodeScalars)
        if let dash = input.lastIndex(of: "-") {
            out = Array(input[..<dash])
            guard out.allSatisfy(\.isASCII) else { return nil }
            input = Array(input[(dash + 1)...])
        }
        func digit(_ c: Unicode.Scalar) -> Int? {
            switch c.value {
            case 48...57: Int(c.value) - 22
            case 65...90: Int(c.value) - 65
            case 97...122: Int(c.value) - 97
            default: nil
            }
        }
        func adapt(_ delta: Int, _ count: Int, _ first: Bool) -> Int {
            var d = first ? delta / damp : delta / 2
            d += d / count
            var k = 0
            while d > ((base - tMin) * tMax) / 2 { d /= base - tMin; k += base }
            return k + (base - tMin + 1) * d / (d + skew)
        }
        var n = 128, i = 0, bias = 72, pos = 0
        while pos < input.count {
            let old = i
            var w = 1, k = base
            while true {
                guard pos < input.count, let d = digit(input[pos]) else { return nil }
                pos += 1
                let (m, o1) = d.multipliedReportingOverflow(by: w)
                let (sum, o2) = i.addingReportingOverflow(m)
                guard !o1, !o2 else { return nil }
                i = sum
                let t = k <= bias ? tMin : k >= bias + tMax ? tMax : k - bias
                if d < t { break }
                let (nw, o3) = w.multipliedReportingOverflow(by: base - t)
                guard !o3 else { return nil }
                w = nw; k += base
            }
            bias = adapt(i - old, out.count + 1, old == 0)
            // Checked before it is added: a crafted label can carry an increment near Int.max.
            let step = i / (out.count + 1)
            guard step <= 0x10FFFF - n else { return nil }
            n += step
            i %= out.count + 1
            guard let scalar = Unicode.Scalar(UInt32(n)) else { return nil }
            out.insert(scalar, at: i)
            i += 1
        }
        return String(String.UnicodeScalarView(out))
    }
}
