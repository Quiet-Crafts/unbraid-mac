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
    /// refuses: names on the own network or in the tailnet (`ownNetwork`), and names that only end others' names.
    /// For what is typed only: a saved setup keeps what it holds (the compiler leaves out what can't work).
    static func refusal(_ raw: String, tailnet: String? = nil) -> String? {
        switch read(raw) {
        case .refused(let why): return why
        case .name(let name):
            if let why = ownNetwork(name, tailnet: tailnet) { return why }
            return sharedSuffix(name) ? "\(name) ends many websites' names: add one website under it" : nil
        }
    }

    /// Why a website rule can't work for `name`: it is on the own network or in the tailnet, whose own resolver
    /// answers it, which a website's route would skip (and `.local` names are answered by multicast, which never passes
    /// unbraid). Nil for any other name. `tailnet` is the tailnet's own domain, when there is one.
    /// One sentence per kind of name, true whatever route was chosen, Blocked included.
    static func ownNetwork(_ name: String, tailnet: String? = nil) -> String? {
        let no = "unbraid can't give it a rule"
        if let tailnet, under(name, tailnet) { return "\(name) is a name in your tailnet: \(no)" }
        if under(name, "ts.net") { return "\(name) is a Tailscale name, answered by Tailscale: \(no)" }
        if under(name, "localhost") { return "\(name) is this Mac itself: \(no)" }
        if under(name, "arpa"), !under(name, "home.arpa") { return "\(name) is a lookup of an address, not a website: \(no)" }
        return local.contains { under(name, $0) } ? "\(name) is a name on your own network: \(no)" : nil
    }

    /// The websites whose rules apply: clean names, and for a route or Direct none on the own network or in the
    /// tailnet (a setup saved before those were refused may hold one; a block of one stays a block). The compiler
    /// writes rules for these only, and statistics and every count go by the same, so a rule shown as not applied
    /// neither counts nor takes its app's traffic.
    static func applied(_ sites: [String: String], tailnet: String? = nil) -> [String: String] {
        sites.filter { isApplied($0.key, $0.value, tailnet: tailnet) }
    }

    static func isApplied(_ name: String, _ route: String, tailnet: String? = nil) -> Bool {
        isClean(name) && (route == BLOCK || ownNetwork(name, tailnet: tailnet) == nil)
    }

    /// The websites blocked in `before` that `after` opens, whole or in part: no longer blocked itself, or a name under
    /// it given a route or Direct of its own there (the most specific rule wins, Block included).
    static func opened(_ before: [String: String], _ after: [String: String]) -> [String] {
        let open = applied(after).filter { $0.value != BLOCK }.keys
        return before.filter { b in b.value == BLOCK && (after[b.key] != BLOCK || open.contains { under($0, b.key) }) }.keys.sorted()
    }

    /// Whether `name` is `suffix` or a name under it.
    static func under(_ name: String, _ suffix: String) -> Bool { name == suffix || name.hasSuffix("." + suffix) }

    private enum Read { case name(String), refused(String) }

    private static func read(_ raw: String) -> Read {
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
        while name.hasPrefix("www."), name.dropFirst(4).contains(".") { name.removeFirst(4) }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        // A last label that reads as a number (digits, or 0x and hex digits) makes it an IP address to a browser, which
        // connects to it without a lookup: nothing a rule could match, and nothing a name ends in.
        let last = labels[labels.count - 1]
        if last.allSatisfy(\.isNumber) || (last.hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit)) {
            return .refused(labels.count > 1 && !last.isEmpty ? address : notAName)
        }
        guard name.utf8.count <= 253, labels.allSatisfy(label) else { return .refused(notAName) }
        guard labels.count >= 2 else { return .refused(ownNetwork(name) ?? "Add the whole name, such as \(name).com") }
        return .name(name)
    }

    private static let notAName = "That isn't a website address"
    private static let address = "An IP address can't have a rule: add the website's name"
    /// Where names on the local network end: answered by the Mac or the router, never by a VPN's resolver.
    private static let local = ["local", "lan", "arpa", "fritz.box", "localhost", "internal"]

    /// A name that is itself a public suffix: under it are many unrelated websites (every company's "co.uk"), which a
    /// rule would all cover. The common country forms and hosting platforms where everyone gets a name of their own.
    private static func sharedSuffix(_ name: String) -> Bool {
        platforms.contains(name) || name.wholeMatch(of: /(co|com|net|org|gov|edu|ac|or|ne|go|ltd|plc|me)\.[a-z]{2}/) != nil
    }

    private static let platforms: Set = ["github.io", "gitlab.io", "blogspot.com", "herokuapp.com", "appspot.com", "netlify.app",
                                         "vercel.app", "pages.dev", "workers.dev", "web.app", "firebaseapp.com",
                                         "azurewebsites.net", "cloudfront.net", "s3.amazonaws.com"]

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
    /// Only a decoding that writes back to `name` itself is shown: anything else (a label that decodes to nothing, to
    /// letters a name can't hold, or to look-alike dots) stays in its ASCII form.
    static func shown(_ name: String) -> String {
        guard name.contains("xn--") else { return name }
        let decoded = name.split(separator: ".", omittingEmptySubsequences: false).map { l in
            l.hasPrefix("xn--") ? Punycode.decode(l.dropFirst(4)).flatMap { $0.isEmpty ? nil : $0 } ?? String(l) : String(l)
        }.joined(separator: ".")
        return decoded != name && ascii(decoded) == name ? decoded : name
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
