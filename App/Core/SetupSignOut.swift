import Foundation

// Setup edits for signing out: what goes and what stays when one provider, Tailscale, or everything is signed out.

nonisolated extension Setup {
    /// Whether there is anything to route through: a signed-in provider, an imported route or saved server, Tailscale,
    /// or the Home WireGuard. Without, the first-run screen shows; the setup itself stays.
    func hasExit(signedIn: Bool) -> Bool {
        signedIn || routes.contains(where: \.imported) || !servers.isEmpty || home.tailscale || home.wg != nil
    }

    /// Tailscale is set up (on for the home network, or with an exit route, used or not), so this Mac may have a node in
    /// a tailnet. Unlike `tailscale`, which decides whether the engine runs it now.
    var tailscaleConfigured: Bool { home.tailscale || routes.contains { $0.tsExit != nil } }

    /// Tailscale's sign-out: its exit routes go (their apps follow the default), with its auth key. Everything else stays.
    mutating func dropTailscale() {
        let gone = Set(routes.filter { $0.tsExit != nil }.map(\.id))
        routes.removeAll { gone.contains($0.id) }
        home.tailscale = false
        home.tsAuthKey = nil
        home.tsEnrolled = nil
        if gone.contains(defaultRoute) { defaultRoute = routes.first?.id ?? DIRECT }
        apps = apps.filter { !gone.contains($0.value) }
    }
}
