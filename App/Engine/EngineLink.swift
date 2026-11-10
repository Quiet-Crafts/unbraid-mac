import Foundation

/// The app's way to the engine, which runs in the tunnel extension (the app links no engine): an XPC connection to the
/// extension's service, which checks unbraid's signature while this side checks the extension's. One connection per
/// call or subscription: closing it stops, in the extension, whatever it started.
/// Nonisolated: XPC calls back on its own queues.
nonisolated enum EngineLink {
    /// One request, one answer. Nil when the extension didn't answer in time (not approved, being replaced, interrupted)
    /// or the caller was cancelled.
    static func call<T: Sendable>(timeout: Double = 10, _ send: @escaping @Sendable (CommandXPCProtocol, @escaping @Sendable (T) -> Void) -> Void) async -> T? {
        let answer = Answer<T>()
        let c = connection(events: nil) { answer.finish(nil) }
        defer { c.invalidate() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { k in
                answer.wait(k)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { answer.finish(nil) }
                guard let proxy = c.remoteObjectProxyWithErrorHandler({ _ in answer.finish(nil) }) as? CommandXPCProtocol else { return answer.finish(nil) }
                #if DEBUG
                // A slow extension, for live checks (`DebugHooks.slowReplies`): every answer arrives that much later, and
                // one later than the call's timeout is none (the extension still did what it was asked).
                if DebugHooks.slowReplies > 0 {
                    let slow = DebugHooks.slowReplies
                    return send(proxy) { r in DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + slow) { answer.finish(r) } }
                }
                #endif
                send(proxy) { answer.finish($0) }
            }
        } onCancel: { answer.finish(nil) }
    }

    /// A stream into `events` until `close()`. `lost` runs at most once, if the extension refused it, didn't answer, or
    /// it ended otherwise; never after `close()`.
    static func subscribe(_ events: EngineEventsProtocol, lost: @escaping @Sendable () -> Void,
                          _ start: (CommandXPCProtocol, @escaping @Sendable (Bool) -> Void) -> Void) -> Stream {
        let stream = Stream(lost)
        let c = connection(events: events) { stream.end() }
        stream.connection = c
        guard let proxy = c.remoteObjectProxyWithErrorHandler({ _ in stream.end() }) as? CommandXPCProtocol else { stream.end(); return stream }
        start(proxy) { if $0 { stream.started() } else { stream.end() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak stream] in stream?.timeout() }
        return stream
    }

    final class Stream: @unchecked Sendable {
        private let lock = NSLock()
        private var lost: (@Sendable () -> Void)?
        private var isStarted = false
        fileprivate var connection: NSXPCConnection?

        fileprivate init(_ lost: @escaping @Sendable () -> Void) { self.lost = lost }

        func close() {
            let c = lock.withLock { defer { lost = nil; connection = nil }; return connection }
            c?.invalidate()
        }

        fileprivate func started() { lock.withLock { isStarted = true } }
        fileprivate func timeout() { if !lock.withLock({ isStarted }) { end() } }

        fileprivate func end() {
            let (f, c) = lock.withLock { defer { lost = nil; connection = nil }; return (lost, connection) }
            c?.invalidate()
            f?()
        }
    }

    private static func connection(events: EngineEventsProtocol?, ended: @escaping @Sendable () -> Void) -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: AppGroup.machService, options: .privileged)
        c.setCodeSigningRequirement(AppGroup.tunnelRequirement)
        c.remoteObjectInterface = NSXPCInterface(with: CommandXPCProtocol.self)
        if let events {
            c.exportedInterface = NSXPCInterface(with: EngineEventsProtocol.self)
            c.exportedObject = events
        }
        c.invalidationHandler = ended
        c.interruptionHandler = ended
        c.resume()
        return c
    }

    /// The first of an answer, a timeout, an invalidation or a cancellation wins.
    private final class Answer<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: T??
        private var waiter: CheckedContinuation<T?, Never>?

        func finish(_ v: T?) {
            let k: CheckedContinuation<T?, Never>? = lock.withLock {
                guard result == nil else { return nil }
                result = .some(v)
                defer { waiter = nil }
                return waiter
            }
            k?.resume(returning: v)
        }

        func wait(_ k: CheckedContinuation<T?, Never>) {
            let done: T?? = lock.withLock {
                if result == nil { waiter = k }
                return result
            }
            if let done { k.resume(returning: done) }
        }
    }
}
