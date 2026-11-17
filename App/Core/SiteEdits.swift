import Foundation

/// Adding, moving and removing websites with a route of their own (`Setup.sites`): what the Add Website sheet says
/// about an address, and how a change applies when it is committed.
nonisolated enum SiteEdits {
    /// Websites and where each goes: a route's id, DIRECT or BLOCK; nil takes its rule away (it follows its app again).
    typealias Assignments = [String: String?]

    /// What the address field holds: nothing yet, an address to save (as `Sites.clean` writes it), or why it can't be.
    enum Check: Equatable { case empty, valid(String), refused(String) }

    static func check(_ raw: String, in sites: [String: String]) -> Check {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        guard let name = Sites.clean(raw) else { return .refused("That isn't a website address") }
        if sites[name] != nil { return .refused("\(name) already has a route") }
        if sites.count >= Sites.max { return .refused("A profile holds up to \(Sites.max) websites") }
        return .valid(name)
    }

    /// An address under `name`, to show what "every address under it" means: "www.netflix.com".
    static func also(_ name: String) -> String { "www." + name }

    static func assignments(_ keys: some Sequence<String>, in setup: Setup) -> Assignments {
        Dictionary(uniqueKeysWithValues: Set(keys).map { ($0, setup.sites[$0]) })
    }

    /// Applies `change` as it is committed, which can be long after it was asked for (a limit question, an undo): a
    /// website whose route has gone since follows its app again, as removing the route did, and one more than a profile
    /// holds is not added.
    static func apply(_ change: Assignments, to setup: inout Setup) {
        for (site, route) in change.sorted(by: { $0.key < $1.key }) where Sites.isClean(site) {
            guard let route, route == DIRECT || route == BLOCK || setup.route(route) != nil else { setup.sites[site] = nil; continue }
            if setup.sites[site] == nil, setup.sites.count >= Sites.max { continue }
            setup.sites[site] = route
        }
    }

    /// The websites on `route` (a route's id, DIRECT or BLOCK), A to Z.
    static func on(_ route: String, in setup: Setup) -> [String] { setup.sites.filter { $0.value == route }.keys.sorted() }

    /// The route an Add Website sheet starts on: the page's route when it was opened from one that still exists, else
    /// the first route that isn't the default, else Direct.
    static func preselected(_ page: String?, in setup: Setup) -> String {
        if let page, page == DIRECT || page == BLOCK || setup.route(page) != nil { return page }
        return setup.routes.first { $0.id != setup.defaultRoute }?.id ?? DIRECT
    }

    /// The remove-route confirmation's sentence on websites, nil when none use it.
    static func losing(_ n: Int) -> String? {
        n == 0 ? nil : n == 1 ? "1 website follows its app again." : "\(n) websites follow their apps again."
    }
}
