import Foundation

// The address an exit has on the internet, read from Cloudflare's trace page fetched through that exit (ExitCheck),
// accepted only when it is a well-formed IPv4 or IPv6 address.

nonisolated enum ExitAddress {
    static func parse(_ trace: String) -> String? {
        guard let line = trace.split(separator: "\n", omittingEmptySubsequences: false).first(where: { $0.hasPrefix("ip=") }) else { return nil }
        let address = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return ipv4(address) || ipv6(address) ? address : nil
    }

    static func ipv4(_ address: String) -> Bool {
        let groups = address.split(separator: ".", omittingEmptySubsequences: false)
        return groups.count == 4 && groups.allSatisfy { group in
            (1...3).contains(group.count) && (group.count == 1 || group.first != "0") && group.utf8.allSatisfy { (48...57).contains($0) } && (Int(group).map { $0 <= 255 } ?? false)
        }
    }

    static func ipv6(_ address: String) -> Bool {
        guard address.utf8.count <= 39, address.filter({ $0 == ":" }).count >= 2, !address.contains(":::") else { return false }
        let parts = address.components(separatedBy: "::")
        guard parts.count <= 2 else { return false }
        let groups = parts.flatMap { $0.isEmpty ? [] : $0.split(separator: ":", omittingEmptySubsequences: false) }
        guard groups.allSatisfy({ (1...4).contains($0.utf8.count) && $0.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }) else { return false }
        return parts.count == 2 ? groups.count <= 7 : groups.count == 8
    }
}
