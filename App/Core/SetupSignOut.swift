import Foundation

// Setup edits for signing out and removing routes: what goes and what stays when one provider, Tailscale, or everything
// is signed out, or a route or saved server is removed.

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
        if gone.contains(defaultRoute) { defaultRoute = nextDefault }
        apps = apps.filter { !gone.contains($0.value) }
    }

    // Removing routes. Websites on a removed route follow their apps again wherever routes go (see `routes`).

    /// One route goes (never the last while it is the default); its apps follow the default.
    mutating func removeRoute(_ id: String) {
        guard routes.count > 1 || defaultRoute != id else { return }
        routes.removeAll { $0.id == id }
        if defaultRoute == id { defaultRoute = nextDefault }
        apps = apps.filter { $0.value != id }
    }

    /// The default after the default route went: the first route left, never a proxy on this Mac still waiting for
    /// its app (it would carry nothing), else Direct.
    var nextDefault: String { routes.first { !asksProxyApp($0.id) }?.id ?? DIRECT }

    /// A saved server goes with the routes using it; their apps follow the default.
    mutating func removeServer(_ id: String) {
        let gone = Set(routes.filter { $0.own == id }.map(\.id))
        servers.removeAll { $0.id == id }
        routes.removeAll { gone.contains($0.id) }
        if gone.contains(defaultRoute) { defaultRoute = nextDefault }
        apps = apps.filter { !gone.contains($0.value) }
    }

    /// Use Tailscale Only: Tailscale for the home network; without a provider account, provider routes go.
    mutating func useTailscaleOnly(noProviders: Bool) {
        if noProviders { routes.removeAll { !$0.imported } }
        home.tailscale = true
        if route(defaultRoute) == nil { defaultRoute = nextDefault }
        apps = apps.filter { $0.value == DIRECT || $0.value == BLOCK || route($0.value) != nil }
    }
}
