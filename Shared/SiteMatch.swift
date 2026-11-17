import Foundation

/// Which website rule a connection belongs to. Shared by the app and the tunnel extension: statistics count a routed
/// website's traffic under the rule's own address, matched where the engine runs, so no other name ever leaves it.
nonisolated enum SiteMatch {
    /// The most websites a profile holds, and the longest list the extension takes.
    static let max = 50

    /// The website among `sites` that `host` belongs to (the name itself or one under it), the most specific one: an
    /// element of `sites`, never `host`.
    static func match(_ host: String, _ sites: some Collection<String>) -> String? {
        var h = host.lowercased()[...]
        while h.hasSuffix(".") { h = h.dropLast() }
        return sites.filter { h == $0 || h.hasSuffix("." + $0) }.max { $0.count < $1.count }
    }

    /// The name a connection goes to, as the engine's own rules read it: the name the engine found for it (sniffed, or
    /// mapped back from an address) when there is one, else its destination when that is a name. A connection to a
    /// stand-in address is the second kind: the engine puts the name it answered in the destination and leaves the
    /// first empty. `destination` is "host:port", or "[address]:port" for IPv6; an address gives nothing to match.
    static func name(domain: String, destination: String) -> String {
        if !domain.isEmpty { return domain }
        guard !destination.hasPrefix("["), let colon = destination.lastIndex(of: ":") else { return destination.hasPrefix("[") ? "" : destination }
        return String(destination[..<colon])
    }

    /// `list` when it can be the websites of a setup: at most `max`, each a name of ASCII lower-case letters, digits,
    /// hyphens and dots, at most 253 bytes, of two or more labels of 1 to 63 that neither start nor end with a hyphen.
    /// Nil otherwise: the extension takes the list as data from another process, and refuses rather than repairs it.
    static func accepted(_ list: [String]) -> [String]? {
        guard list.count <= max else { return nil }
        for name in list {
            let labels = Array(name.utf8).split(separator: 46, omittingEmptySubsequences: false)
            guard name.utf8.count <= 253, labels.count >= 2, labels.allSatisfy(label) else { return nil }
        }
        return list
    }

    private static func label(_ l: ArraySlice<UInt8>) -> Bool {
        func alnum(_ c: UInt8) -> Bool { (c >= 97 && c <= 122) || (c >= 48 && c <= 57) }
        guard (1...63).contains(l.count), let first = l.first, let last = l.last else { return false }
        return alnum(first) && alnum(last) && l.allSatisfy { alnum($0) || $0 == 45 }
    }
}
