import Foundation

/// Retry dates belong to the inputs that produced a blocked route, not to an engine start.
nonisolated struct RouteRetry<Key: Equatable> {
    private struct Entry {
        var key: Key
        var attempts: Int
        var next: Date
    }
    private var entries: [String: Entry] = [:]
    private let delays: [TimeInterval] = [5, 15, 30, 60, 300]

    mutating func update(_ blocked: [String: LinkPicker.Blocked], setup: Setup, removedPins: LinkPicker.RemovedPins,
                         revision: Key, attempted: Set<String>, now: Date) {
        let eligible = blocked.filter { id, reason in
            guard let route = setup.route(id), removedPins.reason(for: route) == nil else { return false }
            switch reason { case .signedOut, .refused, .removed: return false; default: return true }
        }.mapValues { _ in revision }
        update(eligible, attempted: attempted, now: now)
    }

    mutating func update(_ blocked: [String: Key], attempted: Set<String>, now: Date) {
        entries = entries.filter { blocked[$0.key] == $0.value.key }
        for (id, key) in blocked {
            if entries[id] == nil { entries[id] = Entry(key: key, attempts: 0, next: now.addingTimeInterval(delays[0])); continue }
            guard attempted.contains(id), var entry = entries[id] else { continue }
            entry.attempts += 1
            entry.next = now.addingTimeInterval(delays[min(entry.attempts, delays.count - 1)])
            entries[id] = entry
        }
    }

    /// A failed retry keeps the inputs it was scheduled for, even while another setup is pending.
    mutating func failed(attempted: Set<String>, now: Date) {
        update(entries.mapValues(\.key), attempted: attempted, now: now)
    }

    var dates: [String: Date] { entries.mapValues(\.next) }
    func due(now: Date) -> Set<String> { Set(entries.filter { $0.value.next <= now }.map(\.key)) }
    mutating func clear() { entries.removeAll() }
}

/// Suppresses the initial observation and coalesces a burst to its final identity.
nonisolated struct NetworkChanges<Identity: Equatable> {
    private var delivered: Identity?
    private var pending: Identity?
    private(set) var deadline: Date?

    mutating func observe(_ identity: Identity, now: Date) {
        guard let delivered else { self.delivered = identity; return }
        if identity == delivered { pending = nil; deadline = nil; return }
        guard pending != identity else { return }
        pending = identity
        deadline = now.addingTimeInterval(2)
    }

    mutating func take(now: Date) -> Bool {
        guard let deadline, deadline <= now, let pending else { return false }
        delivered = pending
        self.pending = nil
        self.deadline = nil
        return true
    }
}
