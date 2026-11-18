import CryptoKit
import Foundation

/// Websites with a route of their own (`Setup.sites`): how an address is written, and how many a profile holds.
nonisolated enum Sites {
    static let max = SiteMatch.max
    /// How many a saved setup may hold when read (see `Setup.readable`).
    static let readMax = 4 * max

    /// The address in `raw` as a rule keeps it, from what people type or paste ("https://www.Example.com/page" →
    /// "example.com"): the name alone, lower case, without "www." (unless what is left is a shared ending), international
    /// names in their ASCII form. A rule covers the name and every name under it. Nil when it names no website: no dot,
    /// an IP address, or characters no name has. What a new one may be is `refusal`'s to say.
    static func clean(_ raw: String) -> String? { if case .name(let name, _) = read(raw) { name } else { nil } }

    /// Whether `name` is written as a saved rule must be: lower-case ASCII labels of letters, digits and hyphens, two or
    /// more, at most 253 bytes, the last not a number. Syntax only, never the list of shared endings, so every saved and
    /// restored rule reads the same whether that list is sound or not.
    static func isClean(_ name: String) -> Bool {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard name.utf8.count <= 253, labels.count >= 2, labels.allSatisfy(label), let last = labels.last else { return false }
        return !(last.allSatisfy(\.isNumber) || (last.hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit)))
    }

    /// Why `raw` can't be added as a website, in the Add Website sheet's words; nil when it can. Beyond what `clean`
    /// refuses: names on the own network or in a Tailscale network (`ownNetwork`), and names that are, or sit above,
    /// endings many websites share. `tailnet`: the tailnet's own domain, as the user accepted it (`tailnet(of:)`).
    /// `list`: the shared endings, the bundled list unless a test gives another (nil: missing or damaged).
    static func refusal(_ raw: String, tailnet: String?, list: Endings? = Sites.list) -> String? {
        switch read(raw) {
        case .refused(let why): return why
        case .name(let name, let full):
            // The whole name as typed first: "www.example.org" when that is the tailnet's domain must not be saved as the
            // public example.org above it.
            for n in [full, name] { if let kind = ownNetwork(n, tailnet: tailnet) { return kind.refusal(n) } }
            guard let list else { return damaged }
            return list.shared(name) ? "\(name) ends many websites' names: add one website under it" : nil
        }
    }

    /// Names on the own network or in a Tailscale network: their devices, private-network names, this Mac, the
    /// internet's own infrastructure and Tailscale's names, so a website rule never applies to one, whatever is running.
    enum Own {
        case device, privateName, thisMac, address, infrastructure, tailscale

        /// What the name is, in a sentence the refusal and the row both use.
        func sentence(_ name: String) -> String {
            switch self {
            case .device: "\(name) is a device on your own network, which Reach devices on this network in Settings › Home access looks after"
            case .privateName: "\(name) is a name for private networks, which unbraid leaves to them"
            case .thisMac: "\(name) is this Mac itself, which apps reach without unbraid"
            case .address: "\(name) is a lookup of an address, not a website"
            case .infrastructure: "\(name) is part of the internet's own infrastructure, not a website"
            case .tailscale: "\(name) belongs to a Tailscale network, which Settings › Tailscale looks after"
            }
        }

        /// Add Website's refusal.
        func refusal(_ name: String) -> String { sentence(name) + ", so it can't take a website rule" }
    }

    /// Which kind of own-network name `name` is, or nil: `.local`, `.lan`, `home.arpa`, `fritz.box`, `.internal`,
    /// `localhost`, `arpa`, all of `ts.net`, and the tailnet's own domain (`tailnet`). The same set in every setup: only
    /// the domain the user accepted is read, never which of Tailscale's switches are on.
    /// The tailnet's own domain comes first: a name under it is the tailnet's, whatever it ends in ("nas.corp.lan").
    static func ownNetwork(_ name: String, tailnet: String?) -> Own? {
        if under(name, "ts.net") || Compiler.tsSuffix(tailnet).map({ under(name, $0) }) == true { return .tailscale }
        if Compiler.localNames.contains(where: { under(name, $0) }) { return .device }
        if under(name, "internal") { return .privateName }
        if under(name, "localhost") { return .thisMac }
        if under(name, "in-addr.arpa") || under(name, "ip6.arpa") { return .address }
        if under(name, "arpa") { return .infrastructure }
        return nil
    }

    /// The tailnet's own domain, as the user accepted it and the setup keeps it, whether Tailscale runs or not: what
    /// own-network names are judged by everywhere.
    /// `s` with the tailnet domain `current` holds (accepted or not, confirmed or not), the rest as it was: an older
    /// setup run again judges its websites as the saved one does.
    static func withDomain(_ s: Setup, of current: Setup) -> Setup {
        var s = s
        s.home.tsSuffix = current.home.tsSuffix
        s.home.tsSuffixConfirmed = current.home.tsSuffixConfirmed
        return s
    }
    static func tailnet(of setup: Setup) -> String? { Compiler.tsSuffix(Compiler.trustedStoredSuffix(setup.home)) }

    /// The websites whose rules apply: a block always, a route or Direct unless its name is on the own network or in a
    /// Tailscale network (a backup or the Android app may hold one). The compiler writes rules for these only, and the
    /// routes that run, statistics, every count, the widgets and the rows go by the same.
    static func applied(_ setup: Setup, tailnet: String?) -> [String: String] {
        setup.sites.filter { isClean($0.key) && ($0.value == BLOCK || ownNetwork($0.key, tailnet: tailnet) == nil) }
    }

    /// `applied` with `setup`'s own accepted domain.
    static func applied(_ setup: Setup) -> [String: String] { applied(setup, tailnet: tailnet(of: setup)) }

    /// Why `setup`'s saved rule for `name` doesn't apply, in the same words as Add Website's refusal; nil when it does.
    static func notApplied(_ name: String, in setup: Setup) -> String? {
        guard let route = setup.sites[name], route != BLOCK, let kind = ownNetwork(name, tailnet: tailnet(of: setup)) else { return nil }
        return "Not applied: " + kind.sentence(name)
    }

    /// What `setup`'s block of `name` can't stop, or nil: `.local` names are answered by the devices themselves and
    /// `localhost` ones by this Mac, so apps reach them without unbraid. A lookup or connection that does pass unbraid is
    /// still refused.
    static func limited(_ name: String, in setup: Setup) -> String? {
        guard setup.sites[name] == BLOCK else { return nil }
        if under(name, "local") { return "Blocked only where it passes unbraid: the devices on your network answer .local names themselves" }
        if under(name, "localhost") { return "Blocked only where it passes unbraid: apps reach this Mac's own names without it" }
        return nil
    }

    /// How many of `sites` (`setup`'s own or a saved profile's) don't apply (see `applied`).
    static func notAppliedCount(_ sites: [String: String], in setup: Setup) -> Int {
        var s = setup
        s.sites = sites
        return sites.count - applied(s).count
    }

    /// Whether `setup`'s rule for `name` applies (see `applied`).
    static func isApplied(_ name: String, in setup: Setup) -> Bool { applied(setup)[name] != nil }

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

    /// A name as a rule keeps it, and the whole name as typed (before "www." went); or why there is none.
    private enum Read { case name(String, full: String), refused(String) }

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
        let full = name
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
        guard labels.count >= 2 else {
            return .refused(ownNetwork(name, tailnet: nil).map { $0.refusal(name) } ?? "Add the whole name, such as \(name).com")
        }
        return .name(name, full: full)
    }

    private static let notAName = "That isn't a website address"
    private static let address = "An IP address can't have a rule: add the website's name"
    /// Whether `name` is itself an ending many unrelated websites share ("co.uk"), the base of one ("sch.uk", above
    /// every "*.sch.uk"), or above one ("nordland.no"): a rule would cover them all. By the bundled list, and without a
    /// sound list by the platforms alone.
    static func shared(_ name: String) -> Bool { list?.shared(name) ?? (platforms.contains(name) || platformAncestors.contains(name)) }

    /// The shared endings: the Public Suffix List's ICANN section as `Resources/shared_suffixes.txt` holds it (its
    /// wildcard and exception rules included), and hosting platforms where everyone gets a name of their own (the list's
    /// private section, kept short).
    struct Endings: Sendable {
        let rules: Set<String>
        /// Every name of two or more labels above a listed ending ("nordland.no" above "bo.nordland.no", "amazonaws.com"
        /// above "s3.amazonaws.com"): a rule for one would cover all the websites under the endings below it.
        let ancestors: Set<String>

        /// The list in `data`, or nil when it isn't the one this build ships (missing, cut short or changed).
        init?(_ data: Data?) {
            guard let data, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == Sites.suffixesDigest,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            rules = Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
            ancestors = Sites.ancestors(of: Array(rules.filter { !$0.hasPrefix("!") }) + Array(Sites.platforms))
        }

        func shared(_ name: String) -> Bool {
            if Sites.platforms.contains(name) { return true }
            let parent = name.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            return rules.contains(name) || rules.contains("*." + name) || rules.contains("*." + parent) && !rules.contains("!" + name)
                || ancestors.contains(name)
        }
    }

    private static func ancestors(of rules: [String]) -> Set<String> {
        var out = Set<String>()
        for rule in rules {
            let labels = (rule.hasPrefix("*.") ? String(rule.dropFirst(2)) : rule).split(separator: ".")
            for k in stride(from: labels.count - 1, through: 2, by: -1) { out.insert(labels.suffix(k).joined(separator: ".")) }
        }
        return out
    }

    private static let platformAncestors = ancestors(of: Array(platforms))

    /// The bundled list, read once; nil when it isn't the one this build ships: Add Website then takes no new website
    /// (`damaged`), rather than one a sound list would refuse. Saved rules never depend on it (`isClean`).
    static var list: Endings? { listInTest ?? bundled }
    private static let bundled = Endings(Bundle(for: BundleToken.self).url(forResource: "shared_suffixes", withExtension: "txt").flatMap { try? Data(contentsOf: $0) })
    /// Tests only: the list as a missing or damaged file leaves it (`.some(nil)`), for the code they run within.
    @TaskLocal static var listInTest: Endings?? = nil

    /// The bundled list's rules.
    static var suffixes: Set<String>? { list?.rules }

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

    /// `name` as people read it: an international name in its own letters with its xn-- form beside it, so a name
    /// whose letters only look like others' always shows what it is ("bücher.de (xn--bcher-kva.de)"). Only a decoding
    /// that writes back to `name` itself; anything else stays in its ASCII form.
    /// A long pair shows the xn-- form first, so a cut row still shows what the name is (the whole pair is the cell's
    /// tooltip); `asciiFirst` always does, for a table column whose width can cut either.
    static func shown(_ name: String, asciiFirst: Bool = false) -> String {
        guard let d = decoded(name) else { return name }
        return asciiFirst || d.count + name.count > 50 ? "\(name) (\(d))" : "\(d) (\(name))"
    }

    /// What a search of the list matches `name` by: its xn-- form and its own letters.
    static func readings(_ name: String) -> [String] { [name] + [decoded(name)].compactMap { $0 } }

    /// `name`'s labels in their own letters, when that writes back to `name` itself (nil for any other).
    private static func decoded(_ name: String) -> String? {
        guard name.contains("xn--") else { return nil }
        let decoded = name.split(separator: ".", omittingEmptySubsequences: false).map { l in
            l.hasPrefix("xn--") ? Punycode.decode(l.dropFirst(4)).flatMap { $0.isEmpty ? nil : $0 } ?? String(l) : String(l)
        }.joined(separator: ".")
        return decoded != name && ascii(decoded) == name ? decoded : nil
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
