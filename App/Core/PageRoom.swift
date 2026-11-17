import Foundation

/// How a route's page shares its height between the live strip, its apps and its websites, so a short window (or a band
/// above the page) shrinks the lists instead of pushing them past the window's edge.
nonisolated enum PageRoom {
    struct Plan: Equatable {
        /// The live strip shows: it gives way first, before either list is left without two rows.
        var strip: Bool
        /// Rows each list has room for.
        var apps: Int
        var sites: Int
    }

    /// `room`: the page's height. `top`: what sits above the lists (header and cards), `strip`: the live strip's
    /// height, `chrome`: everything of the lists that isn't a row. `apps` and `sites`: the rows each list wants.
    /// The lists get one row each, then a second each, then the websites the rest of theirs, then the apps.
    static func plan(room: Double, top: Double, strip: Double, chrome: Double, row: Double, apps: Int, sites: Int) -> Plan {
        func fits(_ withStrip: Bool) -> Int { max(0, Int(((room - top - (withStrip ? strip : 0) - chrome) / row).rounded(.down))) }
        let wanted = min(apps, 2) + min(sites, 2)
        let keep = fits(true) >= wanted
        var n = fits(keep), a = 0, s = 0
        for _ in 0..<2 {
            if n > 0, a < apps { a += 1; n -= 1 }
            if n > 0, s < sites { s += 1; n -= 1 }
        }
        let more = min(sites - s, n); s += more; n -= more
        a += min(apps - a, n)
        return Plan(strip: keep, apps: a, sites: s)
    }
}
