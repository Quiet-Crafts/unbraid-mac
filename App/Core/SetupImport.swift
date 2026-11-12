import Foundation

// Setup edits for imported sources (WireGuard, OpenVPN, Shadowsocks, saved servers): giving one to a new or an
// existing route, and choosing its colour.

nonisolated extension Setup {
    /// The lowest colour no route uses yet.
    var nextHue: Int { (0...6).first { h in !routes.contains { $0.hue == h } } ?? routes.count }

    /// Gives an imported source to a route, as one edit, and returns the route's id. `target` is "" (a new route),
    /// "app:<key>" (a new route for that app) or a route id (its source is replaced); `id` names a new route.
    /// `signedIn` holds the providers with an account.
    ///
    /// With no provider signed in, provider routes can't carry anything: they go, and their apps follow the default.
    /// When nothing could carry traffic before (a fresh install, after Sign Out of Everything, after the last server
    /// went), the new route becomes the default, even over Direct: an import made to get going must not leave a
    /// connected VPN carrying nothing. A setup that already had a working route keeps its default, Direct included,
    /// and an import for one app only moves that app. Tailscale for the home network or a Home WireGuard count as
    /// working: their Direct default was chosen (Use Tailscale Only), and an exit node added there stays an option.
    @discardableResult
    mutating func addImported(_ target: String, id newId: String, signedIn: Set<String>, _ source: (inout Route) -> Void) -> String {
        let usable = home.tailscale || home.wg != nil || routes.contains { $0.imported || signedIn.contains($0.loc.provider) }
        let id = route(target) != nil ? target : newId
        var r = route(id).map { Route(id: $0.id, hue: $0.hue) } ?? Route(id: id, hue: nextHue)
        source(&r)
        if let i = routes.firstIndex(where: { $0.id == id }) { routes[i] = r } else { routes.append(r) }
        if signedIn.isEmpty {
            let dead = Set(routes.filter { !$0.imported }.map(\.id))
            routes.removeAll { dead.contains($0.id) }
            if dead.contains(defaultRoute) || route(defaultRoute) == nil && defaultRoute != DIRECT { defaultRoute = id }
            apps = apps.filter { !dead.contains($0.value) }
        }
        let app = target.hasPrefix("app:") ? String(target.dropFirst(4)) : nil
        if !usable, app == nil { defaultRoute = id }
        if let app { apps[app] = id }
        return id
    }
}
