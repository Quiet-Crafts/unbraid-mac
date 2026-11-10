import Foundation
import SystemConfiguration

/// What a user can hand to support on purpose (Settings › About › Copy Diagnostics), now that the logs keep engine and
/// system text private. Plain text for the clipboard, never sent anywhere by unbraid. Versions, states, flags, provider
/// names, what failed and the error's type and code: no route names and no error text, except the engine's reason for
/// refusing a setup, with the setup's own values, the user's and the Mac's names, keys, addresses and host names
/// masked. Masking free text can't be complete, so the header asks the user to read it before sending it.
nonisolated struct DiagnosticsReport: Equatable, Sendable {
    var app: String
    var system: String
    /// The extension's activation state (code-made), and whether this build's extension answered (nil: not asked).
    var extensionState: String
    var extensionAnswers: Bool?
    var phase: String
    var killSwitch: Bool
    var killSwitchApplied: Bool?
    var onDemand: Bool
    var onDemandApplied: Bool?
    var onDemandUnavailable: Bool
    /// Provider ids of the edited setup's active routes (own servers counted apart); only names unbraid knows are shown.
    var providers: [String]
    var imported: Int
    var home: String?
    /// The engine runs another setup than the edited one (a change wasn't applied); nil while nothing runs.
    var runningDiffers: Bool?
    var failure: Diagnostics.Failure?
    var stop: Diagnostics.Failure?
    var rejection: Diagnostics.Rejection?

    func text(now: Date, names: (String) -> String?) -> String {
        func flag(_ requested: Bool, _ applied: Bool?) -> String {
            (requested ? "on" : "off") + (applied.map { $0 == requested ? "" : " (applied: \($0 ? "on" : "off"))" } ?? " (applied: unknown)")
        }
        func ago(_ at: Date) -> String {
            let minutes = Int(now.timeIntervalSince(at) / 60)
            return minutes < 1 ? "just now" : "\(minutes) min ago"
        }
        let known = Set(providers.compactMap(names)).sorted()
        let others = providers.filter { names($0) == nil }.count
        let listed = known + (others > 0 ? ["\(others) other"] : []) + (imported > 0 ? ["\(imported) own server\(imported == 1 ? "" : "s")"] : [])
        var lines = [
            "unbraid diagnostics (redacted: unbraid masks keys, addresses, host names and your setup's own values; read it before sending)",
            "App: \(app)",
            "System: \(system)",
            "Extension: \(extensionState)" + (extensionAnswers.map { $0 ? ", answers on this build" : ", not answering" } ?? ""),
            "VPN: \(phase)" + (runningDiffers == true ? ", running an earlier setup (the last change wasn't applied)" : ""),
            "Kill switch: \(flag(killSwitch, killSwitchApplied))",
            "Connect on Demand: \(flag(onDemand, onDemandApplied))" + (onDemandUnavailable ? ", unavailable (configuration not sealed)" : ""),
            "Providers in the setup: \(listed.isEmpty ? "none" : listed.joined(separator: ", "))",
        ]
        if let home { lines.append("Home network: \(home)") }
        if let f = failure { lines.append("Last failure (\(ago(f.at))): \(f.kind), \(f.facts)") }
        if let s = stop { lines.append("Tunnel last stopped on its own (\(ago(s.at))): \(s.facts)") }
        if let r = rejection { lines.append("Engine refused a setup (\(ago(r.at))): \(r.text)") }
        return lines.joined(separator: "\n")
    }
}

nonisolated enum Diagnostics {
    struct Rejection: Equatable, Sendable {
        var at: Date
        /// Already cleaned.
        var text: String
    }

    /// What failed, in the app's own words, and the error's type and code: never its text.
    struct Failure: Equatable, Sendable {
        var at: Date
        var kind: String
        var facts: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var rejection: Rejection?
    nonisolated(unsafe) private static var failure: Failure?
    nonisolated(unsafe) private static var stop: Failure?

    /// The engine's reason for refusing `config`, kept (cleaned) for a diagnostics report; the log keeps it private.
    static func noteRejection(_ reason: String?, config: String? = nil, at: Date = .now) {
        let r = Rejection(at: at, text: clean(reason, values: values(of: config) + localNames()))
        lock.withLock { rejection = r }
    }

    /// A failure the app reported: `kind` is its own wording ("Could not connect").
    static func noteFailure(_ kind: String, _ error: Error, at: Date = .now) {
        let f = Failure(at: at, kind: kind, facts: facts(error))
        lock.withLock { failure = f }
    }

    /// A failure with no error behind it: `facts` are the app's own words.
    static func noteFailure(_ kind: String, facts: String, at: Date = .now) {
        let f = Failure(at: at, kind: kind, facts: facts)
        lock.withLock { failure = f }
    }

    /// The kind a failure `Connection.message` reports is copied as: its fallback when that is fixed wording, else a
    /// restore's (whose fallback is the earlier message, which can name a route).
    static func failureKind(_ fallback: String) -> String { failureKinds[fallback] ?? "Restoring after a failure" }

    /// The fixed fallbacks `Connection.message` is called with, and the kind each is copied as.
    static let failureKinds: [String: String] = Dictionary(uniqueKeysWithValues: [
        "Could not connect", "Could not stop the VPN", "Could not pause", "Could not update blocked apps", "Change not applied",
        "Sign in again", "Could not take over the running VPN", "Could not block VPN apps",
    ].map { ($0, $0) }).merging([
        "the engine didn't take them": "Blocked-app changes not applied",
        "unbraid couldn't build it.": "Blocked apps not saved for unattended starts",
        "the tunnel couldn't save them": "Blocked apps not saved for unattended starts",
    ]) { $1 }

    /// Why macOS last stopped the tunnel without being asked.
    static func noteStop(_ error: Error, at: Date = .now) {
        let f = Failure(at: at, kind: "stopped", facts: facts(error))
        lock.withLock { stop = f }
    }

    static var lastRejection: Rejection? { lock.withLock { rejection } }
    static var lastFailure: Failure? { lock.withLock { failure } }
    static var lastStop: Failure? { lock.withLock { stop } }

    private static let systemDomains: Set<String> = [NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSCocoaErrorDomain,
                                                     "NEVPNErrorDomain", "NEVPNConnectionErrorDomain", "NETunnelProviderErrorDomain",
                                                     "OSSystemExtensionErrorDomain"]

    /// An error's type, and its domain (the system's own only) and code: what code made, never what it says.
    static func facts(_ error: Error) -> String {
        let e = error as NSError
        let type = String(describing: Swift.type(of: error))
        let domain = systemDomains.contains(e.domain) ? e.domain : "other"
        return domain == "other" ? "\(type) \(e.code)" : "\(domain) \(e.code)"
    }

    /// Values the compiler writes itself: engine words and its own tags, kept so the engine's reason still reads
    /// ("initialize outbounds[2]: parse wireguard: …"). Anything else in a config is the user's (or a provider's).
    private static let vocabulary: Set<String> = [
        "direct", "block", "local", "resolve", "reject", "hijack-dns", "predefined", "ignore", "sniff", "route", "logical",
        "udp", "tcp", "icmp", "dns", "tun", "mixed", "fake", "fakeip", "probe", "gvisor", "system", "warn", "info", "error",
        "wireguard", "tailscale", "openvpn", "openvpn-client", "shadowsocks", "client", "server", "subject", "tls_auth",
        "tls_crypt", "ipv4_only", "ipv6_only", "prefer_ipv4", "prefer_ipv6", "AAAA", "HTTPS", "SVCB", "NOERROR", "NXDOMAIN",
        "home-ts", "home-wg", "dns-tailnet", "cache.db", "unbraid",
    ]

    /// The config's own string values (server names and addresses, user names, passwords, keys, domains, app paths),
    /// without the compiler's words and its route tags ("r-" or "dns-r-" and a generated id).
    static func values(of config: String?) -> [String] {
        guard let data = config?.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var found: Set<String> = []
        func walk(_ o: Any) {
            if let d = o as? [String: Any] {
                if d["server"] as? String == "45.90.28.0", let path = d["path"] as? String, path.hasPrefix("/") {
                    found.insert(String(path.dropFirst()))
                }
                d.values.forEach(walk)
            }
            else if let a = o as? [Any] { a.forEach(walk) }
            else if let v = o as? String, v.count >= 3, !vocabulary.contains(v),
                    v.range(of: #"^(?:dns-(?:ovpn-)?)?r-[a-z0-9]+$"#, options: .regularExpression) == nil { found.insert(v) }
        }
        walk(json)
        return Array(found)
    }

    /// Who and which Mac this is: the account name, the user's full name, the host and computer names, and their words.
    static func localNames() -> [String] {
        var mac: [String] = []
        var host = [CChar](repeating: 0, count: 256)
        if gethostname(&host, host.count) == 0 { mac.append(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
        if let n = SCDynamicStoreCopyLocalHostName(nil) { mac.append(n as String) }
        if let n = SCDynamicStoreCopyComputerName(nil, nil) { mac.append(n as String) }
        return localNames(people: [NSUserName(), NSFullUserName()], mac: mac)
    }

    /// The names whole and their words, but for the Mac's names the words that name no one: the engine's own and a
    /// model's or the local domain's ("Robin's MacBook Pro", "robins-mbp.local"), so "local server refused" still
    /// reads. A whole name stays one, and the user's own words all stay ("Anna Block": "Block" too).
    static func localNames(people: [String], mac: [String]) -> [String] {
        func words(_ names: [String]) -> [String] { names.flatMap { $0.split { !$0.isLetter && !$0.isNumber }.map(String.init) } }
        let named = words(mac).filter { !generic.contains($0.folding(options: .caseInsensitive, locale: nil)) }
        return (people + mac + words(people) + named).filter { $0.count >= 3 }
    }

    private static let generic = Set((vocabulary + ["mac", "macbook", "air", "pro", "mini", "imac", "studio", "local"])
        .map { $0.folding(options: .caseInsensitive, locale: nil) })

    /// Masked in order: URLs, bearer tokens, what Go's resolver looked up and its dialer dialled, e-mail addresses
    /// (with a password: "user:pw@host"), IPv4 (with a prefix or a port; also inside an IPv4-mapped IPv6), IPv6
    /// (compressed, scoped, with a prefix), host names (dotted labels ending in letters: "vpn.example.com",
    /// "mac.tail1234.ts.net"; the engine's config paths such as "route.rules[0]" stay), byte lists, account numbers (six
    /// digits or more, or groups of them), short keys and tokens, the user's name in a home folder path and a volume's
    /// name, quoted values and any other word with digits in it.
    /// The values go first (see `clean`), so an e-mail's name or domain may already hold a "[value]".
    private static let masks: [(NSRegularExpression, String)] = [
        (#"(?i)\b[a-z][a-z0-9+.-]{0,31}://\S+"#, "[url]"),
        (#"(?i)\bbearer\s+\S+"#, "[hidden]"),
        (#"(?i)\b(lookup\s+)[^\s:]+"#, "$1[host]"),
        (#"(?i)\b(dial\s+(?:tcp|udp)[46]?\s+)\S+"#, "$1[address]"),
        (#"(?<![A-Za-z0-9._%+:\]-])(?:\[value\]|[A-Za-z0-9._%+-]){1,64}(?::[^\s@]{1,64})?@(?:\[value\]|[A-Za-z0-9.-]){1,253}"#, "[email]"),
        (#"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,2})?(?::\d{1,5})?(?![\d.])"#, "[address]"),
        (#"(?i)(?<![0-9a-z:])(?:[0-9a-f]{0,4}:){2,7}(?:[0-9a-f]{1,4}|\[address\])?(?:%[0-9a-z]+)?(?:/\d{1,3})?(?![0-9a-z:])"#, "[address]"),
        (#"(?i)\b(?!(?:route|dns|outbounds?|inbounds?|endpoints?|experimental|log|ntp|services?|certificate)\.[a-z0-9_.-]*\[)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,24}\b"#, "[host]"),
        (#"\[\s*\d{1,3}(?:[\s,]+\d{1,3}){3,}\s*\]"#, "[bytes]"),
        (#"\b\d{6,}\b|\b\d{2,4}(?:[ -]\d{2,4}){2,}\b"#, "[number]"),
        // A short key or token: 16 characters or more of letters and digits mixed (Redact takes 40 and up).
        (#"(?<![A-Za-z0-9+/_-])(?=[A-Za-z0-9+/_-]*\d)(?=[A-Za-z0-9+/_-]*[A-Za-z])[A-Za-z0-9+/_-]{16,}={0,2}"#, "[hidden]"),
        (#"/Users/[^/\s]+"#, "/Users/[user]"),
        (#"/Volumes/[^/\n]+"#, "/Volumes/[volume]"),
        // Base64 with its padding, however short ("Ab+/Cd=="): a multiple of four characters, so "type=" stays.
        (#"(?<![A-Za-z0-9+/])(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)(?![A-Za-z0-9+/=])"#, "[hidden]"),
        // Long mixed-case runs (base64 without digits), quoted values (an imported config's own words), and names
        // with digits ("alice-pc2"); the engine's indexes ("outbounds[2]") and ipv4/ipv6 stay.
        (#"(?<![A-Za-z0-9+/_-])(?=[A-Za-z0-9+/_-]*[a-z])(?=[A-Za-z0-9+/_-]*[A-Z])[A-Za-z0-9+/_-]{16,}={0,2}"#, "[hidden]"),
        // A quote the cut left open hides everything after it.
        (#""(?:[^"\\]|\\.){0,200}"|'(?:[^'\\]|\\.){0,200}'|`[^`]{0,200}`|["'`].*$"#, "[value]"),
        (#"(?i)(?<![\w\[\]-])(?!ipv[46]\b|tcp[46]?\b|udp[46]?\b)(?=[\w-]*\d)(?=[\w-]*[a-z])[\w-]+"#, "[value]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// Free text from the engine fit for the report. Already cut by the extension (Redact keeps 160 characters), so
    /// a cut-off last word, which could be the start of an address, is dropped, and so are the words left of a value
    /// the cut went through. `values` (the config's own, the user's and the Mac's names) go wherever they appear,
    /// longest first; one shorter than 8 characters only as a word of its own, so "nas" doesn't take a piece of
    /// "dynasty". The masks then catch what no value names.
    static func clean(_ s: String?, values: [String] = []) -> String {
        var text = String((s ?? "").prefix(1000))
        let cut = text.count >= 160
        if cut, let space = text.lastIndex(where: \.isWhitespace) { text = String(text[..<space]) }
        // Each value also as the extension's Redact left it (a secret or a long run inside it hidden), when anything else is left.
        let redacted = values.map { Redact.hiding($0).replacingOccurrences(of: "\n", with: " ") }.filter { $0.replacingOccurrences(of: "[hidden]", with: "").count(where: { $0.isLetter || $0.isNumber }) >= 3 }
        let candidates = Set(values + redacted).filter { !$0.isEmpty && !["[value]", "[hidden]"].contains($0.lowercased()) }
            .sorted { $0.count > $1.count }
        if cut {
            // "ssid Acme Secret Office" cut after "Secret" left "ssid Acme": the start of a value, up to a space in it.
            values: for v in candidates {
                for space in v.indices.reversed() where v[space].isWhitespace {
                    let start = String(v[..<space])
                    guard start.count >= 3, let r = text.range(of: start, options: [.caseInsensitive, .backwards, .anchored]) else { continue }
                    if r.lowerBound > text.startIndex, case let before = text[text.index(before: r.lowerBound)], before.isLetter || before.isNumber { continue }
                    text.replaceSubrange(r, with: "[value]")
                    break values
                }
            }
        }
        if text.contains("[hidden]") { text = maskTails(text, candidates) }
        for v in candidates where text.range(of: v, options: .caseInsensitive) != nil {
            guard let re = valuePattern(v) else { continue }
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                               withTemplate: NSRegularExpression.escapedTemplate(for: "[value]"))
        }
        if cut { text += " …" }
        for (re, placeholder) in masks {
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: placeholder)
        }
        return Redact.clean(text)
    }

    /// A value wherever it appears; one shorter than 8 characters only as a word of its own.
    private static func valuePattern(_ v: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: v)
        return try? NSRegularExpression(pattern: v.count >= 8 ? escaped : #"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#,
                                        options: .caseInsensitive)
    }

    /// Redact hides a secret's key and its first word only ("password correct horse battery" → "[hidden] horse
    /// battery"): the value's later words right after it go too, the longest run of them any value has (the cut may have
    /// ended it early). Done on the text as it came, before any value is masked, so a shorter value inside the run can't
    /// break it up. Words are compared case-folded, one by one, as Redact left them; the last may run into punctuation
    /// ("battery:").
    private static func maskTails(_ text: String, _ values: [String]) -> String {
        func fold<S: StringProtocol>(_ s: S) -> String { s.folding(options: .caseInsensitive, locale: nil) }
        // Whole values too, found in the same text: a value's tail masked first would hide the whole value from its pass.
        var found: [Range<String.Index>] = values.filter { text.range(of: $0, options: .caseInsensitive) != nil }.flatMap { v in
            (valuePattern(v)?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []).compactMap { Range($0.range, in: text) }
        }
        let words = values.map { $0.split(whereSeparator: \.isWhitespace).map(fold) }
        // Where each word but a value's first is: a run starts at one of them.
        var starts: [String: [(value: Int, at: Int)]] = [:]
        for (n, w) in words.enumerated() { for at in w.indices.dropFirst() { starts[w[at], default: []].append((n, at)) } }
        var from = text.startIndex
        while let hidden = text.range(of: "[hidden]", range: from..<text.endIndex) {
            from = hidden.upperBound
            guard hidden.upperBound < text.endIndex, text[hidden.upperBound].isWhitespace else { continue }
            // The words after it, each as its folded whole and folded starts up to punctuation, with where they end.
            var tokens: [[(word: String, end: String.Index)]] = [], i = hidden.upperBound
            while i < text.endIndex {
                let start = text[i...].firstIndex { !$0.isWhitespace } ?? text.endIndex
                guard start < text.endIndex else { break }
                let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
                let cuts = text[start..<end].indices.dropFirst().filter { !text[$0].isLetter && !text[$0].isNumber }
                tokens.append([(fold(text[start..<end]), end)] + cuts.map { (fold(text[start..<$0]), $0) })
                i = end
            }
            guard let first = tokens.first else { continue }
            var longest: String.Index?
            for key in Set(first.map(\.word)) {
                for (n, at) in starts[key] ?? [] {
                    var end: String.Index?
                    for (word, token) in zip(words[n][at...], tokens) {
                        if token[0].word == word { end = token[0].end; continue }
                        end = token.dropFirst().first { $0.word == word }?.end ?? end
                        break
                    }
                    if let end, longest.map({ end > $0 }) ?? true { longest = end }
                }
            }
            if let longest, let start = text[hidden.upperBound...].firstIndex(where: { !$0.isWhitespace }) { found.append(start..<longest) }
        }
        // Overlapping matches go as one.
        var merged: [Range<String.Index>] = []
        for r in found.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, r.lowerBound <= last.upperBound { merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound) }
            else { merged.append(r) }
        }
        var masked = text
        for r in merged.reversed() { masked.replaceSubrange(r, with: "[value]") }
        return masked
    }
}
