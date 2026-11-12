import Foundation
import Observation

/// Exit addresses are kept only while the app runs. A visible page or panel starts the checks.
@MainActor @Observable final class ExitCheck {
    static let shared = ExitCheck()
    private(set) var state = ExitCheckState()
    private(set) var checking = false
    @ObservationIgnored private var nextAttempt = Date.distantPast
    @ObservationIgnored private var visible = Set<UUID>()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var checkingEngine: Int?
    @ObservationIgnored private lazy var changes = ChangeObserver(read: { [weak self] in
        guard let self else { return }
        _ = (self.vpn.state, self.vpn.tags, self.vpn.running, self.vpn.probe?.port, Store.shared.accounts)
    }, reconcile: { @MainActor [weak self] in self?.refresh() })
    private let vpn = Connection.shared

    private init() { changes.start() }

    #if DEBUG
    /// How many views say they show exit addresses (tools/debug.sh watchers).
    var visibleCount: Int { visible.count }
    #endif

    func watch(_ id: UUID, visible: Bool) {
        let wasVisible = !self.visible.isEmpty
        if visible { self.visible.insert(id) } else { self.visible.remove(id) }
        if wasVisible != !self.visible.isEmpty { refresh(force: true) }
    }

    private func refresh(force: Bool = false) {
        let v = vpn.state
        let engine = v.phase == .on && vpn.probe != nil ? v.runState.engineStarts : nil
        let accounts = Running.fingerprints(Store.shared.accounts)
        let routes: [String: ExitRoute] = engine == nil ? [:] : (vpn.running?.activeRoutes ?? []).reduce(into: [:]) { out, route in
            guard route.id != DIRECT, route.id != BLOCK, v.blocked[route.id] == nil,
                  let tag = vpn.tags[route.id], tag != "direct", tag != "block" else { return }
            out[route.id] = ExitRoute(tag: tag, server: v.servers[route.id], route: route, owner: accounts[route.loc.provider] ?? "")
        }
        let changed = state.engine != engine || state.routes != routes
        guard changed || force else { return }
        if let checkingEngine { state.cancelAttempt(engine: checkingEngine); self.checkingEngine = nil }
        if changed {
            state.update(engine: engine, routes: routes)
            nextAttempt = Date().addingTimeInterval(3)
        }
        revision += 1
        task?.cancel(); task = nil; checking = false
        guard !visible.isEmpty, engine != nil, !state.pending.isEmpty, !state.exhausted else { return }
        let current = revision
        task = Task { [weak self] in await self?.run(current) }
    }

    private func run(_ revision: Int) async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(max(0, nextAttempt.timeIntervalSinceNow))) } catch { return }
            guard revision == self.revision, let engine = state.engine, let endpoint = vpn.probe else { return }
            let routes = state.begin()
            guard !routes.isEmpty else { return }
            // A speed test of another Tailscale exit node switches the one Tailscale tag's exit for its length: what comes
            // back through it is that node's address, not the route's.
            var tags = Set(routes.values.map(\.tag))
            if Store.shared.tsTestNode { tags.remove(Compiler.tsTag) }
            guard !tags.isEmpty else {
                state.cancelAttempt(engine: engine)
                nextAttempt = Date().addingTimeInterval(10)
                continue
            }
            checkingEngine = engine
            checking = true
            var answers = await Self.ask(tags, probe: endpoint)
            guard !Task.isCancelled, revision == self.revision else { return }
            if Store.shared.tsTestNode { answers[Compiler.tsTag] = nil }
            checkingEngine = nil
            checking = false
            state.accept(answers, engine: engine, routes: routes)
            nextAttempt = Date().addingTimeInterval(Double([10, 20, 40, 40][min(state.attempts - 1, 3)]))
            if state.pending.isEmpty || state.exhausted { return }
        }
    }

    /// Requests stay inside the engine's authenticated tunnel proxy.
    nonisolated static func ask(_ tags: Set<String>, probe: Probe.Endpoint) async -> [String: String] {
        await ExitProbe.ask(tags) { tag, host in
            guard let data = try? await Probe.get(tag: tag, host: host, path: "/cdn-cgi/trace", probe: probe, max: 4096),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return ExitAddress.parse(text)
        }
    }
}
