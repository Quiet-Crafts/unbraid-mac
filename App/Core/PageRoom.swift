import Foundation

/// How a route's page shares its height between its apps and its websites. When the room holds two whole rows of each
/// list (or all a list has) under what sits above them, the lists are fitted into it; when it doesn't, there is no plan
/// and the page scrolls as one, each part at its natural height.
nonisolated enum PageRoom {
    struct Plan: Equatable {
        /// Rows each list shows.
        var apps: Int
        var sites: Int
    }

    /// `room`: the page's height. `top`: what sits above the lists (header, cards, live strip). `chrome`: everything of
    /// the lists that isn't a row. `apps` and `sites`: the rows each list wants. Past the two rows each, the websites
    /// get the rest of theirs, then the apps.
    static func plan(room: Double, top: Double, chrome: Double, row: Double, apps: Int, sites: Int) -> Plan? {
        let apps = max(0, apps), sites = max(0, sites)
        guard room > 0, row > 0 else { return Plan(apps: apps, sites: sites) }
        let fits = ((room - top - chrome) / row).rounded(.down)
        let a = min(apps, 2), s = min(sites, 2)
        guard fits >= Double(a + s) else { return nil }
        var n = Int(min(fits, Double(apps + sites))) - a - s
        let more = min(sites - s, n); n -= more
        return Plan(apps: a + min(apps - a, n), sites: s + more)
    }
}
