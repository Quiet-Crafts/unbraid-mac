import Foundation

/// Waits for `work`, or `seconds` at most; true when the work finished in time. The work isn't cancelled at the
/// deadline: the caller just stops waiting (quitting must never hang on it).
nonisolated func bounded(_ seconds: Double, _ work: @escaping @Sendable () async -> Void) async -> Bool {
    let done = Flag()
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        let once = ResumeOnce(c)
        Task { await work(); done.set(); once.resume() }
        Task { try? await Task.sleep(for: .seconds(seconds)); once.resume() }
    }
    return done.value
}

/// Resumes a continuation at most once (a change, a completion and a timeout race).
nonisolated final class ResumeOnce: @unchecked Sendable {
    private var c: CheckedContinuation<Void, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<Void, Never>) { self.c = c }
    func resume() { lock.lock(); let k = c; c = nil; lock.unlock(); k?.resume() }
}

private nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.withLock { v = true } }
    var value: Bool { lock.withLock { v } }
}
