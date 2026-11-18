import Foundation

/// Adding, moving and removing websites with a route of their own (`Setup.sites`): what the Add Website sheet says
/// about an address, and how a change applies when it is committed.
nonisolated enum SiteEdits {
    /// Websites and where each goes: a route's id, DIRECT or BLOCK; nil takes its rule away (it follows its app again).
    typealias Assignments = [String: String?]

    /// What the address field holds: nothing yet, an address to save (as `Sites.clean` writes it), or why it can't be.
    enum Check: Equatable { case empty, valid(String), refused(String) }

    /// `tailnet`: the tailnet's own domain, when there is one (its names can't have a rule). At the limit nothing can be
    /// added, so that is said before anything is typed; only an address already there says so instead.
    static func check(_ raw: String, in sites: [String: String], tailnet: String? = nil) -> Check {
        let atLimit = sites.count >= Sites.max
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return atLimit ? .refused(full) : .empty }
        if let name = Sites.clean(raw), sites[name] != nil { return .refused("\(Sites.shown(name)) already has a route") }
        if atLimit { return .refused(full) }
        if let why = Sites.refusal(raw, tailnet: tailnet) { return .refused(why) }
        guard let name = Sites.clean(raw) else { return .refused("That isn't a website address") }
        return .valid(name)
    }

    /// Why no website can be added at the limit, in the sheet and on the buttons that open it.
    static let full = "A profile holds up to \(Sites.max) websites"

    /// An address under `name`, to show what "every address under it" means: "www.netflix.com".
    static func also(_ name: String) -> String { "www." + name }

    static func assignments(_ keys: some Sequence<String>, in setup: Setup) -> Assignments {
        Dictionary(uniqueKeysWithValues: Set(keys).map { ($0, setup.sites[$0]) })
    }

    /// Why `change` can't be committed to `setup` as it is now, or nil; checked again right before it is (a limit
    /// question or a provider lookup can come in between). `typed`: an Add's address as typed, checked in full again, as
    /// a domain accepted meanwhile can make it a private name. `faithful`: Undo or Redo putting back exactly what was
    /// there, which may be a rule on an own-network name (a restored Block); anything else can't give such a name one.
    /// Removing a rule is never refused, and one whose route has gone follows its app again (`apply`).
    static func refusal(_ change: Assignments, in setup: Setup, typed: String? = nil, faithful: Bool = false) -> String? {
        let tailnet = Sites.tailnet(of: setup)
        if let typed, case .refused(let why) = check(typed, in: setup.sites, tailnet: tailnet) { return why }
        var count = setup.sites.count
        for (site, route) in change.sorted(by: { $0.key < $1.key }) where Sites.isClean(site) {
            guard let route, route == DIRECT || route == BLOCK || setup.route(route) != nil else { continue }
            if !faithful, let kind = Sites.ownNetwork(site, tailnet: tailnet) { return kind.refusal(site) }
            if setup.sites[site] == nil { count += 1; if count > Sites.max { return full } }
        }
        return nil
    }

    /// Applies `change` as it is committed, which can be long after it was asked for (a limit question, an undo): a
    /// website whose route has gone since follows its app again, as removing the route did, and one more than a profile
    /// holds is not added. A name on the own network or in a Tailscale network (`Sites.ownNetwork`, by the domain the
    /// setup holds now) is neither added nor moved, Block included, as Add Website refuses it, unless `faithful` (Undo or
    /// Redo putting back what was there); one saved can be removed. `refusal` says beforehand what this would skip.
    static func apply(_ change: Assignments, to setup: inout Setup, faithful: Bool = false) {
        let tailnet = Sites.tailnet(of: setup)
        for (site, route) in change.sorted(by: { $0.key < $1.key }) where Sites.isClean(site) {
            guard let route, route == DIRECT || route == BLOCK || setup.route(route) != nil else { setup.sites[site] = nil; continue }
            if !faithful, Sites.ownNetwork(site, tailnet: tailnet) != nil { continue }
            if setup.sites[site] == nil, setup.sites.count >= Sites.max { continue }
            setup.sites[site] = route
        }
    }

    /// The websites on `route` (a route's id, DIRECT or BLOCK), A to Z.
    static func on(_ route: String, in setup: Setup) -> [String] { setup.sites.filter { $0.value == route }.keys.sorted() }

    /// The websites whose rules put them on `route` (`Sites.applied`): what its counts and its page list. One saved for a
    /// name on the own network is listed on the Websites page only, as not applied.
    static func applied(_ route: String, in setup: Setup) -> [String] {
        Sites.applied(setup).filter { $0.value == route }.keys.sorted()
    }

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
