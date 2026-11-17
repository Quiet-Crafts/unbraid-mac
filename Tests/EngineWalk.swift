import XCTest

/// The engine's first-match walk over a compiled config, independent of the app's own reading (`RestoreTraffic`): a
/// lookup of a name (made through the system resolver, so with no program) and where a TCP connection to port 443 from
/// a program then goes. A field or action it doesn't know fails the test, so it never guesses.
struct EngineWalk {
    let dns: [[String: Any]], route: [[String: Any]], dnsFinal: String, routeFinal: String
    /// Every outbound, endpoint and DNS server tag the config defines.
    let tags: Set<String>, servers: Set<String>

    init(_ config: String) throws {
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let d = try XCTUnwrap(o["dns"] as? [String: Any]), r = try XCTUnwrap(o["route"] as? [String: Any])
        dns = (d["rules"] as? [[String: Any]]) ?? []; route = (r["rules"] as? [[String: Any]]) ?? []
        dnsFinal = d["final"] as? String ?? ""; routeFinal = r["final"] as? String ?? ""
        func tagsOf(_ v: Any?) -> [String] { ((v as? [[String: Any]]) ?? []).compactMap { $0["tag"] as? String } }
        tags = Set(tagsOf(o["outbounds"]) + tagsOf(o["endpoints"]))
        servers = Set(tagsOf(d["servers"]))
    }

    static let fake = "198.18.0.5", publicAddress = "203.0.113.80"

    private static func strings(_ v: Any?) -> [String] { (v as? [String]) ?? ((v as? String).map { [$0] } ?? []) }

    private static func inCidr(_ ip: String, _ cidr: String) -> Bool {
        guard !cidr.contains(":"), let n = Compiler.canonical(cidr), let bits = n.split(separator: "/").last else { return false }
        return Compiler.canonical("\(ip)/\(bits)") == n
    }

    /// Whether `r` matches.
    private func matches(_ r: [String: Any], process: String?, name: String?, ip: String?, qtype: String?) -> Bool {
        var hit = true
        if r["domain"] != nil || r["domain_suffix"] != nil {
            let exact = Self.strings(r["domain"]).contains { $0 == name }
            let suffix = Self.strings(r["domain_suffix"]).contains { s in
                name.map { n in s.hasPrefix(".") ? n.hasSuffix(s) : (n == s || n.hasSuffix("." + s)) } == true
            }
            hit = name != nil && (exact || suffix)
        }
        for (k, v) in r {
            switch k {
            case "action", "outbound", "server", "no_drop", "rewrite_ttl", "rcode", "invert", "mode", "domain", "domain_suffix": continue
            case "type": XCTAssertEqual(v as? String, "logical")
            case "rules":
                let subs = ((v as? [[String: Any]]) ?? []).map { matches($0, process: process, name: name, ip: ip, qtype: qtype) }
                hit = hit && (r["mode"] as? String == "or" ? subs.contains(true) : subs.allSatisfy { $0 })
            case "inbound": hit = hit && Self.strings(v).contains("tun")
            case "auth_user", "protocol": hit = false
            case "query_type": hit = hit && qtype.map { Self.strings(v).contains($0) } == true
            case "ip_version": hit = hit && (v as? Int) == 4
            case "network": hit = hit && Self.strings(v).contains("tcp")
            case "port": hit = hit && ((v as? [Int])?.contains(443) ?? ((v as? Int) == 443))
            case "ip_cidr": hit = hit && ip.map { ip in Self.strings(v).contains { Self.inCidr(ip, $0) } } == true
            case "process_path_regex":
                hit = hit && process.map { p in
                    Self.strings(v).contains { (try? NSRegularExpression(pattern: $0))?.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)) != nil }
                } == true
            default: XCTFail("unknown field \(k)"); return false
            }
        }
        return hit != (r["invert"] as? Bool == true)
    }

    /// Who answers a `qtype` lookup of `name`: "server:<tag>" or "rcode:<code>".
    func lookup(_ name: String, _ qtype: String) -> String {
        for r in dns where matches(r, process: nil, name: name, ip: nil, qtype: qtype) {
            if r["action"] as? String == "predefined" { return "rcode:\(r["rcode"] as? String ?? "")" }
            return "server:\(r["server"] as? String ?? "")"
        }
        return "server:\(dnsFinal)"
    }

    /// Where a connection goes: "exit:<tag> via <resolver>" or "reject".
    func connect(_ process: String?, name: String?, ip: String) -> String {
        var ip = ip, resolver = "-"
        for r in route where matches(r, process: process, name: name, ip: ip, qtype: nil) {
            if let o = r["outbound"] as? String { return "exit:\(o) via \(resolver)" }
            switch r["action"] as? String {
            case "reject": return "reject"
            case "resolve": resolver = r["server"] as? String ?? "-"; if name != nil { ip = Self.publicAddress }
            case "sniff", "route-options", "hijack-dns": continue
            default: XCTFail("unknown action \(String(describing: r["action"]))"); return "?"
            }
        }
        return "exit:\(routeFinal) via \(resolver)"
    }

    /// The whole outcome for `name` from `process`: its A and TXT answers and where the connection goes.
    func outcome(_ process: String?, _ name: String) -> String {
        let a = lookup(name, "A"), txt = lookup(name, "TXT")
        let conn = a == "server:fake" ? connect(process, name: name, ip: Self.fake)
            : a.hasPrefix("server:") ? connect(process, name: nil, ip: Self.publicAddress) : "none"
        return "A=\(a) TXT=\(txt) \(conn)"
    }
}
