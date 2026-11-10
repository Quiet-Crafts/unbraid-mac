import Foundation

// The hand-over from the engine's callback thread to the statistics writer: a bounded mailbox that keeps every
// traffic delta and drops only stale or repeated control messages.

nonisolated enum StatsMessage: Sendable {
    case events(gen: Int, [Ledger.Ev], reset: Bool)
    case status(gen: Int)
    case lost(gen: Int)
    case retry(gen: Int)

    var generation: Int {
        switch self { case .events(let g, _, _), .status(let g), .lost(let g), .retry(let g): g }
    }
    var control: Int? {
        switch self { case .events: nil; case .status: 0; case .lost: 1; case .retry: 2 }
    }
}

/// Bounded callback-thread mailbox. Traffic batches keep every delta and their reset/sample boundaries; a slow
/// consumer backpressures callbacks instead of dropping bytes. Only redundant control messages are coalesced.
/// Advancing the subscription generation releases blocked producers and discards only stale messages.
nonisolated final class StatsInbox: @unchecked Sendable {
    let wakeups: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation
    private let lock = NSCondition()
    private let capacity: Int
    private var queue: [StatsMessage] = []
    private var generation = 0

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
        (wakeups, wake) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func advance(to generation: Int) {
        lock.lock()
        self.generation = generation
        queue.removeAll(keepingCapacity: true)
        lock.broadcast()
        lock.unlock()
    }

    func send(_ message: StatsMessage) {
        lock.lock()
        defer { lock.unlock() }
        // At most three control messages may sit beside the bounded traffic batches. Controls never block the writer.
        while message.control == nil, queue.count >= capacity, message.generation == generation { lock.wait() }
        guard message.generation == generation else { return }
        if let kind = message.control, queue.contains(where: { $0.control == kind }) { return }
        queue.append(message)
        wake.yield(())
    }

    func next() -> StatsMessage? {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else { return nil }
        let message = queue.removeFirst()
        lock.signal()
        return message
    }
}
