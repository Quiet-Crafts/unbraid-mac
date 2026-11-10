import Foundation

/// Tailscale sign-in links come from the control server, so a malicious or compromised one could send any URL: a custom
/// scheme into another app, or a phishing page. Only an HTTPS link to the control server itself (or to Tailscale's own
/// servers when none is set) opens straight away; another web address is shown first; anything else never opens.
nonisolated enum TsLogin {
    enum Verdict: Sendable { case open, ask, refuse }

    /// `url` is the cleaned link to launch (lowercase scheme, no surrounding space); nil when refused.
    struct Result: Equatable, Sendable {
        var verdict: Verdict
        var url: String?
        var host: String?
    }

    private static let tailscaleControl: Set = ["controlplane.tailscale.com", "login.tailscale.com"]

    static func pending(authURL: String?, backend: String?, was: Bool) -> Bool {
        if let authURL, !authURL.isEmpty { return true }
        if backend == "Running" { return false }
        return was
    }

    static func check(_ url: String, controlUrl: String?) -> Result {
        let refuse = Result(verdict: .refuse, url: nil, host: nil)
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // `encodedHost` is the punycode form. A host written with non-ASCII letters fails closed (its punycode form
        // works): no look-alike letters. Nor a percent escape (outside an IPv6 literal's zone), which decodes to a
        // delimiter (\ / @ #) elsewhere.
        guard let u = URLComponents(string: trimmed), let scheme = u.scheme, scheme.lowercased() == "https",
              let host = normalized(u.encodedHost), !host.isEmpty, host.hasPrefix("[") || !host.contains("%"), u.user == nil, u.password == nil,
              trimmed.dropFirst(scheme.count + 3).prefix(while: { !"/?#".contains($0) }).allSatisfy(\.isASCII) else { return refuse }
        if let port = u.port, !(1...65535).contains(port) { return refuse }
        let clean = "https" + trimmed.dropFirst(scheme.count)
        // No control server set, or Tailscale's own: Tailscale's hosts are trusted. A custom server (even one that
        // can't be parsed) trusts only its own host, so a typo never widens trust to Tailscale.
        let custom = controlUrl?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map { normalized(URLComponents(string: $0)?.encodedHost) ?? "" }
        let trusted = custom.map { tailscaleControl.contains($0) ? isTailscale(host) : host == $0 } ?? isTailscale(host)
        return Result(verdict: trusted ? .open : .ask, url: clean, host: host)
    }

    /// A Headscale control server as it is saved and given to the engine: https only (in any case as typed), a host, no
    /// login in it, a valid port; scheme and host lowercased, the rest as typed. Nil if it isn't one.
    static func controlUrl(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: trimmed), c.scheme?.lowercased() == "https", let host = c.encodedHost, !host.isEmpty, host.hasPrefix("[") || !host.contains("%"),
              c.user == nil, c.password == nil, c.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        c.scheme = "https"
        c.encodedHost = host.lowercased()
        return c.string
    }

    /// What a control-server change saves, or nil when nothing changes. The same server (however it is spelled) keeps
    /// its auth key unless a new one is given; another server never inherits it.
    static func change(url old: String?, key oldKey: String?, to url: String?, authKey: String?) -> (url: String?, key: String?)? {
        let same = old.map { controlUrl($0) ?? $0 } == url
        let key = authKey ?? (same ? oldKey : nil)
        guard !same || key != oldKey else { return nil }
        return (url, key)
    }

    private static func normalized(_ host: String?) -> String? {
        host.map { h in
            var h = h.lowercased()
            while h.hasSuffix(".") { h.removeLast() }
            return h
        }
    }

    private static func isTailscale(_ host: String) -> Bool { host == "tailscale.com" || host.hasSuffix(".tailscale.com") }
}
