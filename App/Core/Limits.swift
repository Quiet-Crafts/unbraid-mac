import Foundation

/// A newer edit supersedes an older one only where their targets overlap. Moves keep their remaining apps.
nonisolated struct RouteEdits {
    enum Target: Hashable, Sendable { case app(String), defaultRoute, location(String), profile }
    struct Ticket: Hashable, Sendable { fileprivate var order: UInt64 }
    private var order: UInt64 = 0
    private var latest: [Target: UInt64] = [:]
    private var pending: [Ticket: Set<Target>] = [:]
    private var moves: Set<Ticket> = []

    mutating func begin(_ targets: Set<Target>, preserving: Set<Ticket> = [], move: Bool = false) -> Ticket {
        order += 1
        let ticket = Ticket(order: order)
        for (old, current) in pending where !preserving.contains(old) && Self.overlap(current, targets) {
            let remaining = current.subtracting(targets)
            if moves.contains(old), !targets.contains(.profile),
               current.intersection(targets).allSatisfy({ if case .app = $0 { return true }; return false }),
               remaining.contains(where: { if case .app = $0 { return true }; return false }) {
                pending[old] = remaining
            } else { finish(old) }
        }
        for target in targets { latest[target] = order }
        pending[ticket] = targets
        if move { moves.insert(ticket) }
        return ticket
    }

    private static func overlap(_ a: Set<Target>, _ b: Set<Target>) -> Bool {
        func assignments(_ targets: Set<Target>) -> Bool {
            targets.contains { if case .location = $0 { return false }; return true }
        }
        return !a.isDisjoint(with: b) || (a.contains(.profile) && assignments(b)) || (b.contains(.profile) && assignments(a))
    }

    func contains(_ ticket: Ticket) -> Bool { pending[ticket] != nil }
    func targets(_ ticket: Ticket) -> Set<Target> { pending[ticket] ?? [] }
    func remaining(_ change: AppMove.Assignments, in ticket: Ticket) -> AppMove.Assignments {
        let targets = targets(ticket)
        return change.filter { targets.contains(.app($0.key)) }
    }

    mutating func clearProfiles() {
        for (ticket, targets) in pending where targets.contains(.profile) { finish(ticket) }
    }

    /// Sharing a server also edits route locations. It cannot overwrite a location chosen since submission.
    mutating func include(_ targets: Set<Target>, in ticket: Ticket) -> Bool {
        guard let current = pending[ticket], targets.allSatisfy({ latest[$0, default: 0] <= ticket.order }) else { return false }
        for (other, current) in pending where other != ticket && !current.isDisjoint(with: targets) { finish(other) }
        for target in targets { latest[target] = ticket.order }
        pending[ticket] = current.union(targets)
        return true
    }

    mutating func finish(_ ticket: Ticket) { pending[ticket] = nil; moves.remove(ticket) }
    mutating func clear() { pending = [:]; moves = [] }
}

/// Undo and redo replay in submission order, including overlapping batches waiting for a limit answer.
@MainActor
final class MoveReplays {
    private var queue: [(ticket: RouteEdits.Ticket, start: (@escaping () -> Void) -> Void)] = []
    var tickets: Set<RouteEdits.Ticket> { Set(queue.map(\.ticket)) }

    func append(_ ticket: RouteEdits.Ticket, start: @escaping (@escaping () -> Void) -> Void) {
        queue.append((ticket, start))
        if queue.count == 1 { run() }
    }

    private func run() {
        guard let first = queue.first else { return }
        first.start { [weak self] in
            guard let self, self.queue.first?.ticket == first.ticket else { return }
            self.queue.removeFirst()
            self.run()
        }
    }
}

nonisolated enum AppMove {
    typealias Assignments = [String: String?]

    static func assignments(_ keys: some Sequence<String>, in setup: Setup) -> Assignments {
        Dictionary(uniqueKeysWithValues: Set(keys).map { ($0, setup.apps[$0]) })
    }

    static func apply(_ change: Assignments, to setup: inout Setup) {
        for (app, route) in change {
            // Undo may outlive a removed route. Resolve the default at commit, not at submission.
            let gone = route.map { $0 != DIRECT && $0 != BLOCK && setup.route($0) == nil } ?? false
            setup.apps[app] = gone ? nil : route
        }
        setup.requireKillSwitchForBlocks()
    }
}

/// Created only for an accepted move. Native undo/redo exchanges the history entry synchronously; the edit itself
/// can wait for a limit answer. Both snapshots belong to the accepted move.
@MainActor
final class MoveHistory {
    typealias Submit = (AppMove.Assignments, @escaping (Bool) -> Void) -> Void
    private let before: AppMove.Assignments
    private let after: AppMove.Assignments
    private weak var undo: UndoManager?
    private let name: String
    private let submit: Submit
    private var replayID = UUID()
    private static let replayKey = UndoManager.UserInfoKey("app.unbraid.moveReplay")
    private var restoring = false

    init(before: AppMove.Assignments, after: AppMove.Assignments, undo: UndoManager, name: String, submit: @escaping Submit) {
        self.before = before; self.after = after; self.undo = undo; self.name = name; self.submit = submit
        register(back: true)
    }

    private func register(back: Bool) {
        guard let undo else { return }
        let automatic = undo.groupsByEvent
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { [self] _ in
            MainActor.assumeIsolated {
                if restoring { register(back: !back) } else { replay(back: back) }
            }
        }
        undo.setActionName(name)
        undo.setActionUserInfoValue(replayID, forKey: Self.replayKey)
        undo.endUndoGrouping()
        undo.groupsByEvent = automatic
    }

    private func replay(back: Bool) {
        let id = UUID()
        replayID = id
        register(back: !back)
        submit(back ? before : after) { [self] applied in
            guard !applied, replayID == id, let undo else { return }
            if undo.isUndoing || undo.isRedoing {
                Task { @MainActor [self] in restore(back: back, id: id) }
            } else { restore(back: back, id: id) }
        }
    }

    private func restore(back: Bool, id: UUID) {
        guard replayID == id, let undo else { return }
        restoring = true
        defer { restoring = false }
        // Reverse only this replay's entry. Registering outside undo/redo would discard other moves' redo.
        let top = back ? undo.redoActionUserInfoValue(forKey: Self.replayKey) : undo.undoActionUserInfoValue(forKey: Self.replayKey)
        if top as? UUID == id {
            if back { undo.redo() } else { undo.undo() }
            return
        }
        undo.removeAllActions(withTarget: self)
        register(back: true)
        if !back {
            // Put a cancelled redo back on the redo stack without submitting another route change.
            undo.undoNestedGroup()
        }
    }
}

nonisolated struct Limit: Equatable, Sendable {
    var unit: String
    var perTunnel: Bool
    var value: Int?
}

nonisolated enum Limits {
    struct Over: Equatable, Sendable {
        var provider: String
        var limit: Int
        var count: Int
        var unit: String
    }

    static func units(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s")" }

    static func line(_ name: String, _ limit: Int?, _ unit: String, _ n: Int, all: Int? = nil) -> String {
        if let limit, let all {
            return "\(name) allows \(units(limit, unit)). \(all == 1 ? "1 is" : "\(all) are") in use, \(all == n ? "" : "\(n) of them ")by unbraid."
        }
        if let limit { return "\(name) allows \(units(limit, unit)). unbraid is using \(n). Your other devices aren't counted." }
        return "unbraid is using \(n) \(name) \(unit)\(n == 1 ? "" : "s"). Check how many your plan allows: over the limit, routes can stop working without an error."
    }

    static func warning(_ name: String, _ limit: Int, _ unit: String, _ n: Int) -> String {
        "\(name) allows \(units(limit, unit)). This would make it \(n). Over the limit, routes can stop working without an error."
    }
    static func full(_ name: String, _ limit: Int?, _ unit: String) -> String {
        "All \(limit.map { "\($0) " } ?? "")\(name) \(unit)s are in use. Sign out another device, then try again."
    }
    static func dropping(_ route: String, _ name: String, _ unit: String) -> String {
        "\(route) keeps dropping. \(name) may be over its \(unit) limit."
    }
    static func effective(_ limit: Limit, _ own: String?) -> Int? {
        if let own, let n = Int(own), (1...999).contains(n) { return n }
        return limit.value
    }

    /// Unpinned routes may pick different servers. A pin shares only when its complete saved identity and protocol match.
    static func tunnels(_ setup: Setup, _ provider: String, links: [String: Link] = [:]) -> Int {
        let routes = setup.activeRoutes.filter { !$0.imported && $0.loc.provider == provider }
        if routes.allSatisfy({ links[$0.id] != nil }) {
            return Set(routes.compactMap { r in links[r.id].map { Compiler.linkKey(r, $0) } }).count
        }
        struct Identity: Hashable { var server: String?; var proto: String?; var route: String? }
        return Set(routes.map { r in
            Identity(server: r.loc.pinned.map { $0.host.isEmpty ? $0.name.lowercased() : $0.host.lowercased() }, proto: r.loc.proto, route: r.loc.pinned == nil ? r.id : nil)
        }).count
    }

    static func shareAnchor(_ setup: Setup, running: Setup?, servers: [String: Server], provider: String) -> (Route, Server)? {
        let running = running?.activeRoutes ?? []
        let routes = setup.activeRoutes.filter { r in
            !r.imported && r.loc.provider == provider &&
            running.contains(where: { $0.id == r.id && $0.loc == r.loc }) && servers[r.id] != nil
        }
        guard routes.count == 1, let route = routes.first, let server = servers[route.id] else { return nil }
        return (route, server)
    }

    static func over(_ old: Setup, _ new: Setup, oldLinks: [String: Link] = [:], newLinks: [String: Link] = [:], limits: (String) -> Limit?) -> Over? {
        var seen: Set<String> = []
        for route in new.activeRoutes where !route.imported {
            let p = route.loc.provider
            guard seen.insert(p).inserted, let l = limits(p), l.perTunnel, let max = effective(l, new.opt(p, "limit")) else { continue }
            let count = tunnels(new, p, links: newLinks)
            if count > max && count > tunnels(old, p, links: oldLinks) { return Over(provider: p, limit: max, count: count, unit: l.unit) }
        }
        return nil
    }
}

/// Temporary routes belong to one run, even if another run starts before cleanup finishes.
nonisolated struct TestingOwner: Sendable {
    private(set) var token: UUID?
    private(set) var routes: Set<String> = []
    mutating func begin(_ routes: Set<String>) -> UUID {
        let id = UUID(); token = id; self.routes = routes; return id
    }
    mutating func end(_ id: UUID) -> Bool {
        guard token == id else { return false }
        clear(); return true
    }
    mutating func clear() { token = nil; routes = [] }
}

nonisolated enum TestingRoutes {
    struct Selection { var routes: Set<String> = []; var errors: [String: String] = [:] }
    static func choose(_ ids: [String], setup: Setup, limits: (String) -> Limit?) -> Selection {
        var result = Selection()
        let active = Set(setup.activeRoutes.map(\.id))
        for id in ids {
            guard let route = setup.route(id), !active.contains(id) else { continue }
            var old = setup; old.testing = result.routes
            var next = old; next.testing.insert(id)
            if let node = route.tsExit, let used = old.tsExit, node != used {
                result.errors[id] = "Tailscale has one exit node at a time, and another route uses it."
            } else if let over = Limits.over(old, next, limits: limits) {
                let name = Providers.get(over.provider)?.name ?? over.provider
                result.errors[id] = "\(name) allows \(Limits.units(over.limit, over.unit)), all in use."
            } else { result.routes.insert(id) }
        }
        return result
    }
}
