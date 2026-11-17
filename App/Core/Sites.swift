import Foundation

/// Websites with a route of their own (`Setup.sites`): how an address is written, and how many a profile holds.
nonisolated enum Sites {
    static let max = 50
    /// How many a saved setup may hold when read (see `Setup.readable`).
    static let readMax = 4 * max

    /// The address in `raw` as a rule keeps it, from what people type or paste ("https://www.Example.com/page" →
    /// "example.com"): the name alone, lower case, without "www.", international names in their ASCII form. A rule
    /// covers the name and every name under it. Nil when it names no website: no dot, an IP address, or characters no
    /// name has.
    static func clean(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        if let scheme = host.range(of: "://") { host = host[scheme.upperBound...] }
        for end in ["/", "?", "#"] { if let r = host.range(of: end) { host = host[..<r.lowerBound] } }
        if let at = host.range(of: "@", options: .backwards) { host = host[at.upperBound...] }
        if let port = host.range(of: ":") { host = host[..<port.lowerBound] }
        guard var name = ascii(String(host).trimmingCharacters(in: CharacterSet(charactersIn: "."))) else { return nil }
        // Every leading "www." goes while a name is left, so what is kept reads back as itself.
        while name.hasPrefix("www."), name.dropFirst(4).contains(".") { name.removeFirst(4) }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        // A last label that reads as a number (digits, or 0x and hex digits) makes it an IP address to a browser, which
        // connects to it without a lookup: nothing a rule could match, and nothing a name ends in.
        let last = labels[labels.count - 1]
        let number = last.allSatisfy(\.isNumber) || (last.hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit))
        guard name.utf8.count <= 253, labels.count >= 2, labels.allSatisfy(label), !number else { return nil }
        return name
    }

    /// Whether `name` is an address exactly as `clean` writes one: what a saved rule must be.
    static func isClean(_ name: String) -> Bool { clean(name) == name }

    /// The website among `sites` that `host` belongs to (the name itself or one under it), the most specific one.
    static func match(_ host: String, _ sites: some Collection<String>) -> String? {
        var h = host.lowercased()[...]
        while h.hasSuffix(".") { h = h.dropLast() }
        return sites.filter { h == $0 || h.hasSuffix("." + $0) }.max { $0.count < $1.count }
    }

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
