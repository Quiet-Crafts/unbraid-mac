import Foundation

/// The running route and tunnel an answer belongs to.
nonisolated struct ExitRoute: Equatable, Sendable {
    var tag: String
    var server: Server?
    var route: Route
    var owner: String

    func sameCarrier(as other: ExitRoute) -> Bool {
        tag == other.tag && server == other.server && owner == other.owner && StatsMath.idOf(route) == StatsMath.idOf(other.route)
    }
}

/// In-memory answers and the attempt budget for one engine start.
nonisolated struct ExitCheckState {
    private(set) var engine: Int?
    private var budgetEngine: Int?
    private(set) var routes: [String: ExitRoute] = [:]
    private(set) var answers: [String: String] = [:]
    private(set) var attempts = 0

    mutating func update(engine: Int?, routes: [String: ExitRoute]) {
        if self.engine != engine { answers = [:] }
        if let engine, budgetEngine != engine {
            budgetEngine = engine
            attempts = 0
        }
        self.engine = engine
        if routes.contains(where: { id, route in self.routes[id].map { $0.owner != route.owner } ?? false }) { answers = [:] }
        answers = answers.filter { id, _ in
            guard let next = routes[id], let old = self.routes[id] else { return false }
            return next.sameCarrier(as: old)
        }
        self.routes = routes
    }

    var pending: [String: ExitRoute] { routes.filter { answers[$0.key] == nil } }
    var exhausted: Bool { attempts >= 4 }

    mutating func begin() -> [String: ExitRoute] {
        guard engine != nil, !exhausted else { return [:] }
        let work = pending
        if !work.isEmpty { attempts += 1 }
        return work
    }

    mutating func cancelAttempt(engine: Int) {
        if budgetEngine == engine, attempts > 0 { attempts -= 1 }
    }

    mutating func accept(_ values: [String: String], engine: Int, routes: [String: ExitRoute]) {
        guard self.engine == engine else { return }
        for (id, route) in routes where self.routes[id]?.sameCarrier(as: route) == true {
            if let answer = values[route.tag] { answers[id] = answer }
        }
    }
}
