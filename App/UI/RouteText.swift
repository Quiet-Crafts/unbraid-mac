import SwiftUI

/// NordVPN server groups, as the picker and the route details name them.
let nordGroups: [(key: String?, label: String)] = [
    (nil, "Standard"), ("legacy_p2p", "P2P"), ("legacy_dedicated_ip", "Dedicated IP"), ("legacy_double_vpn", "Double VPN"), ("legacy_onion_over_vpn", "Onion"),
]

/// Where a route leaves, in words: "NordVPN · P2P · Amsterdam · OpenVPN", or the kind of own server.
func place(_ r: Route, _ live: [String: Server]) -> String {
    if r.wg != nil { return "WireGuard" }
    if r.ovpn != nil { return "OpenVPN" }
    if r.ss != nil { return "Shadowsocks" }
    if r.tsExit != nil { return "Tailscale exit" }
    let nord = r.loc.provider == "nord"
    let city = r.loc.pinned?.name ?? r.loc.city ?? live[r.id]?.city.nilIfEmpty ?? "Fastest"
    let tech: String? = nord ? ["openvpn_udp": "OpenVPN", "openvpn_tcp": "OpenVPN TCP"][Nord.tech(r.loc)] : nil
    return [r.source, nord ? nordGroups.first { $0.key != nil && $0.key == r.loc.group }?.label : nil, city, tech].compactMap { $0 }.joined(separator: " · ")
}

/// Server name and, where the provider publishes it, its load: "nl1256 · 9% load".
func serverId(_ r: Route, _ s: Server) -> String {
    let name = r.loc.provider == "nord" ? String(s.host.split(separator: ".").first ?? "") : s.name
    return [name, s.load >= 0 && Providers.get(r.loc.provider)?.hasLoad == true ? "\(s.load)% load" : nil].compactMap { $0 }.joined(separator: " · ")
}


/// Home access: the tailnet and home subnets, reached from every app.
struct HomeRow: View {
    private let model = AppModel.shared
    @State private var asking = false

    var body: some View {
        let h = model.setup.home
        let v = model.vpn.state
        // A Headscale's own tailnet domain waits for the user's yes (Store.acceptTsSuffix): asked here, where the tailnet
        // shows, as well as in Settings, so names under it don't just stop working unexplained.
        let offered = h.tailscale ? model.store.tsSuffixOffered : nil
        let via = h.tailscale ? "Tailscale" : "WireGuard · \(h.wg?.endpointHost ?? "")"
        HStack(spacing: 12) {
            Image(systemName: "house").foregroundStyle(Ink.dim).frame(width: Measure.rowIcon)
            VStack(alignment: .leading, spacing: 1) {
                Text("Home network").font(.heading)
                Text(([via] + (h.subnets.isEmpty ? [] : [h.subnets.joined(separator: ", ")]) + ["from every app"]).joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Ink.dim)
            }
            Spacer()
            if let url = v.tsLoginUrl, h.tailscale {
                TailscaleSignIn(url: url)
            } else if offered != nil {
                Button("Tailnet Domain…") { asking = true }.controlSize(.small)
            } else {
                let (text, good) = status(v, tailscale: h.tailscale)
                HStack(spacing: 6) {
                    StatusDot(color: good ? Ink.connected : Ink.off)
                    Text(text).font(.system(size: 12)).foregroundStyle(good ? Ink.successText : Ink.dim)
                }
            }
        }
        .confirmationDialog("Use “\(offered ?? "")” for tailnet names?", isPresented: $asking, titleVisibility: .visible, presenting: offered) { domain in
            Button("Use Domain") { model.store.acceptTsSuffix(domain) }
            Button("Not Now", role: .cancel) {}
        } message: { _ in
            Text("Your control server names your tailnet’s devices under this domain. Once used, every app’s lookups of names under it go to your tailnet. Use it only if the domain is your tailnet’s.")
        }
    }

    /// What Tailscale says, as the Tailscale settings say it; a WireGuard home is only "On": nothing checks the peer.
    private func status(_ v: VpnState, tailscale: Bool) -> (String, Bool) {
        guard v.phase == .on else { return ("Off", false) }
        guard tailscale else { return ("On", false) }
        switch TailscaleStatus(v.tsState) {
        case .connected: return ("Connected", true)
        case .signInNeeded: return ("Sign-in needed", false)
        case .awaitingApproval: return ("Awaiting approval", false)
        case .starting, nil: return ("Starting", false)
        case .stopped: return ("Stopped", false)
        case .unknown: return ("Status unavailable", false)
        }
    }
}

extension WgPeer {
    /// The endpoint's host for display: before the port's colon, an IPv6 address without its brackets.
    var endpointHost: String {
        String(endpoint[..<(endpoint.lastIndex(of: ":") ?? endpoint.endIndex)]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}
