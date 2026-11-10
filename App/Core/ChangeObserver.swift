import Observation

/// Rearms observation before running work, so changes during an await are reconciled afterwards. One worker drains
/// each burst; stopping invalidates both queued observation callbacks and an older worker's completion.
@MainActor
final class ChangeObserver {
    private let read: () -> Void
    private let reconcile: () async -> Void
    private var generation = 0
    private var dirty = false
    private var task: Task<Void, Never>?

    init(read: @escaping () -> Void, reconcile: @escaping () async -> Void) {
        self.read = read; self.reconcile = reconcile
    }

    func start() { stop(); track(generation) }
    func stop() { generation += 1; task?.cancel(); task = nil; dirty = false }

    private func track(_ g: Int) {
        guard g == generation else { return }
        withObservationTracking(read) { [weak self] in
            // Observation fires before the mutation. Read its completed value on the next main-actor turn.
            Task { @MainActor in self?.track(g) }
        }
        dirty = true
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while g == generation, dirty, !Task.isCancelled {
                dirty = false
                await reconcile()
            }
            if g == generation { task = nil }
        }
    }
}
