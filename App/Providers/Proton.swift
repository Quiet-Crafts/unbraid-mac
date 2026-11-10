import Foundation

/// Proton's downloaded key works on every normal server. Secure Core and Tor need a plan feature and a different
/// route. Free keys work only on the catalogue's `free` entries. The port comes from gluetun, not Proton's pages;
/// 10.2.0.2 / 10.2.0.1 are the generated config's defaults (10.3.0.2 / 10.3.0.1 belong to a second tunnel).
nonisolated protocol ProtonPlan: KeyProvider {
    var free: Bool { get }
    /// gluetun's list: the bundled snapshot vouches for every key, the live copy only refreshes addresses.
    var catalogue: Catalog.Source { get }
}

nonisolated extension ProtonPlan {
    var id: String { free ? "proton-free" : "proton" }
    var listSource: String? { "protonvpn" }
    var name: String { free ? "Proton VPN Free" : "Proton VPN" }
    var fields: [Field] { [Field(key: "key", label: "WireGuard key or .conf", hint: "Paste the whole file, or the PrivateKey", file: true)] }
    var help: String {
        "Sign in at account.protonvpn.com → Downloads → WireGuard configuration. Name the config, pick any platform and server, then Create and Download. Paste the whole .conf (or just the PrivateKey value). " + (free
            ? "A Free plan's key works only on Proton's free servers (see protonvpn.com/free-vpn/server), so this list shows just those; with a paid plan choose Proton VPN."
            : "The same key works on every Proton server. A Free plan's key works only on Proton's free servers: choose Proton VPN Free for those.")
    }
    var configFacts: [String] { ["VPN Accelerator", "NetShield", "Moderate NAT", "NAT-PMP (Port Forwarding)"] }
    var configHelp: (String, String)? { ("Proton configs expire. Extend yours at account.protonvpn.com, Downloads", "https://account.protonvpn.com/downloads") }
    @concurrent func facts(_ account: String) async throws -> String? {
        guard let facts = try keyAccount(account).facts else { return "Not known" }
        let lines = configFacts.compactMap { key -> String? in
            guard let value = facts[key] else { return nil }
            if key == "NetShield" { return "NetShield " + (["0": "off", "1": "malware", "2": "malware, ads and trackers"][value] ?? value) }
            if key == "NAT-PMP (Port Forwarding)" { return "Port forwarding \(value)" }
            return "\(key) \(value)"
        }
        return lines.isEmpty ? "None in your config" : lines.joined(separator: " · ")
    }
    var defaultAddress: [String]? { ["10.2.0.2/32"] }
    var defaultDns: [String] { ["10.2.0.1"] }
    var defaultPort: Int { 51820 }

    @concurrent func entries(_ a: KeyAccount) async throws -> [Catalog.Entry] {
        try await catalogue.entries { filtered($0) }
    }

    /// Only the key the bundled snapshot lists for this host: gluetun's live list is a mutable third-party repository.
    func trustsServer(_ sv: Server, _ a: KeyAccount) -> Bool { snapshotKey(sv) }

    private func snapshotKey(_ sv: Server) -> Bool {
        guard let id = Catalog.identity(sv.host), let key = try? catalogue.pinned().keys[id] else { return false }
        return key == sv.publicKey
    }

    /// Without the account: a WireGuard tunnel to a public address, whose peer key is the one the snapshot lists.
    func vouches(_ link: Link) -> Bool {
        guard case .wg(let sv, let peer, _, _) = link, Catalog.Entry.publicIPv4(sv.ip), peer.endpoint.hasPrefix("\(sv.ip):"),
              peer.publicKey == sv.publicKey else { return false }
        return snapshotKey(sv)
    }

    func filtered(_ all: [Catalog.Entry]) -> [Catalog.Entry] {
        all.filter {
            let n = $0.serverName ?? ""
            return ($0.free || !free) && !n.contains(/^(CH|IS|SE)-[A-Z]{2}#/) && !n.hasSuffix("-TOR")
        }
    }
}

/// Paid plans can also use the free servers.
nonisolated struct Proton: ProtonPlan {
    let free = false
    var catalogue = Catalog.Source.proton
}
