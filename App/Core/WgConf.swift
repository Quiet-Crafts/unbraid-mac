import Foundation
import Darwin

/// Parses a wg-quick style .conf with one peer. Throws Fail with a readable reason.
nonisolated enum WgConf {
    private static let amnezia: Set = ["jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5"]

    static func hasInterface(_ text: String) -> Bool {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        return text.split(whereSeparator: \.isNewline).contains { raw in
            raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces).lowercased() == "[interface]"
        }
    }

    static func parse(_ text: String, name: String) throws -> WgPeer {
        guard text.count <= 16_384 else { throw Fail("That file is too large for a WireGuard config") }
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var kv: [String: String] = [:]
        var section = ""
        var peers = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line.lowercased(); if section == "[peer]" { peers += 1 }; continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard !k.isEmpty else { continue }
            if amnezia.contains(k) { throw Fail("Obfuscated (AmneziaWG) configs aren't supported") }
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            kv["\(section).\(k)", default: ""] += kv["\(section).\(k)"] == nil ? v : ",\(v)"
        }
        guard peers == 1 else { throw Fail("Config must have exactly one [Peer]") }
        func need(_ k: String) throws -> String {
            guard let v = kv[k] else { throw Fail("Missing \(k.split(separator: ".").last ?? "") in the config") }
            return v
        }
        func list(_ k: String) -> [String] { (kv[k] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        func key(_ k: String) throws -> String {
            let v = try need(k)
            guard validWgKey(v) else { throw Fail("Invalid key in the config") }
            return v
        }
        let endpoint = try need("[peer].endpoint")
        guard validEndpoint(endpoint) else { throw Fail("Endpoint needs host:port (an IPv6 address in brackets: [2001:db8::1]:51820)") }
        // A bare "10.0.0.2" is a host address; the engine needs the prefix.
        let address = list("[interface].address").filter { !$0.contains(":") }.map { $0.contains("/") ? $0 : "\($0)/32" }
        guard !address.isEmpty else { throw Fail("Config has no IPv4 address") }
        // An interface address: a valid IPv4 address with a prefix of at least 1.
        for value in address where Compiler.canonical(value) == nil || value.hasSuffix("/0") {
            throw Fail("Address has an invalid value: \(value)")
        }
        let allAllowed = list("[peer].allowedips")
        for value in allAllowed {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            let valid: Bool
            if value.contains(":") {
                var address = in6_addr()
                let prefix = parts.count == 2 ? Int(parts[1]) : 128
                valid = (1...2).contains(parts.count) && parts.count > 0 && inet_pton(AF_INET6, String(parts[0]), &address) == 1
                    && (parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy { $0.isASCII && $0.isNumber }))
                    && prefix.map { (0...128).contains($0) } == true
            } else { valid = Compiler.canonical(value) != nil }
            guard valid else { throw Fail("AllowedIPs has an invalid range: \(value)") }
        }
        let allowed = allAllowed.filter { !$0.contains(":") }
        guard !allowed.isEmpty else { throw Fail("Config has no IPv4 AllowedIPs") }
        let psk = kv["[peer].presharedkey"]
        if let psk, !validWgKey(psk) { throw Fail("Invalid key in the config") }
        let keepalive: Int?
        if let value = kv["[peer].persistentkeepalive"] {
            if value.lowercased() == "off" { keepalive = 0 }
            else if let n = Int(value), (0...65535).contains(n), value.allSatisfy({ $0.isASCII && $0.isNumber }) { keepalive = n }
            else { throw Fail("Invalid PersistentKeepalive in the config") }
        } else { keepalive = nil }
        return WgPeer(
            name: name, privateKey: try key("[interface].privatekey"), address: address, publicKey: try key("[peer].publickey"),
            presharedKey: psk, endpoint: endpoint, allowedIps: allowed,
            // IPv4 servers only: IPv6 ones and search domains (which wg-quick takes here too) are left out.
            dns: list("[interface].dns").filter { Catalog.Entry.octets($0) != nil },
            mtu: Int(kv["[interface].mtu"] ?? "").map { min(max($0, 1280), 1500) } ?? 1420, keepalive: keepalive)
    }

    /// "host:port" with a port in range and a host; a host with colons (IPv6) must be bracketed, or "2001:db8::1" would
    /// read as host "2001:db8:" and port 1.
    static func validEndpoint(_ e: String) -> Bool {
        guard let colon = e.lastIndex(of: ":"), let port = Int(e[e.index(after: colon)...]), (1...65535).contains(port) else { return false }
        let host = e[..<colon]
        if host.hasPrefix("[") { return host.count > 2 && host.hasSuffix("]") && !host.dropFirst().dropLast().contains { "[]".contains($0) } }
        return !host.isEmpty && !host.contains(":") && !host.contains("]")
    }

    /// Throws unless `p` sends all IPv4 traffic through its peer, as an app's exit must; subnet-only profiles belong
    /// under Home. "All" means every public address: 0.0.0.0/0, its two halves, or the WireGuard apps' "exclude private
    /// IPs" list. An exit compiles to 0.0.0.0/0 whatever the profile says; the LAN settings decide local traffic.
    static func requireFullTunnel(_ p: WgPeer) throws {
        guard coversPublicIPv4(p.allowedIps) else {
            throw Fail("This config only reaches \(p.allowedIps.joined(separator: ", ")); import it under Settings → Home instead")
        }
    }

    /// Addresses an exit needn't carry: the ones `Catalog.Entry.publicIPv4` calls not public.
    private static let notPublic = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
                                    "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4"]

    /// Whether `cidrs` (invalid ones ignored) together with the non-public ranges cover all of IPv4. Half-open
    /// [start, end) ranges in UInt64, so 0.0.0.0/0 and 255.255.255.255/32 need no special case.
    static func coversPublicIPv4(_ cidrs: [String]) -> Bool {
        let ranges = (cidrs + notPublic).compactMap(range).sorted { $0.0 < $1.0 }
        var reached: UInt64 = 0
        for (start, end) in ranges {
            if start > reached { return false }
            reached = max(reached, end)
        }
        return reached >= 1 << 32
    }

    private static func range(_ cidr: String) -> (UInt64, UInt64)? {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let o = Catalog.Entry.octets(String(parts[0])) else { return nil }
        let len = parts.count == 2 ? Int(parts[1]) : 32
        guard let len, (0...32).contains(len), parts.count == 1 || parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let ip = o.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let size = UInt64(1) << UInt64(32 - len)
        let start = ip & ~(size - 1)
        return (start, start + size)
    }
}

/// A WireGuard key: 32 bytes in Base64.
nonisolated func validWgKey(_ k: String) -> Bool { Data(base64Encoded: k)?.count == 32 }
