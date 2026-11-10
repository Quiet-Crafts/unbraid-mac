import Foundation
@preconcurrency import Libbox
import Synchronization

/// Serves the extension's mach service (NEMachServiceName) to unbraid itself only, checked by code signature, and, while
/// an engine runs, to the user whose app started it (see `Ownership`). Up from launch, tunnel running or not: launchd
/// starts the extension for it, so a configuration can be checked before a start.
/// The app links no engine: every command runs here, against the engine's own command server.
final class CommandXPC: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener = NSXPCListener(machServiceName: AppGroup.machService)

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    deinit { listener.invalidate() }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.setCodeSigningRequirement(AppGroup.appRequirement)
        c.exportedInterface = NSXPCInterface(with: CommandXPCProtocol.self)
        c.remoteObjectInterface = NSXPCInterface(with: EngineEventsProtocol.self)
        let session = CommandSession(events: c.remoteObjectProxy as? EngineEventsProtocol, uid: c.effectiveUserIdentifier)
        session.connection = c
        c.exportedObject = session
        // The app closing its end (or dying) stops what this connection started.
        c.invalidationHandler = { session.close() }
        c.interruptionHandler = { session.close() }
        c.resume()
        return true
    }
}

/// One app connection: the subscriptions and tests it started, closed with it.
private final class CommandSession: NSObject, CommandXPCProtocol, @unchecked Sendable {
    /// libbox calls block on IPC with the engine: never on XPC's queue, so a closing connection is always heard.
    private static let queue = DispatchQueue(label: "app.unbraid.commands", qos: .utility, attributes: .concurrent)
    /// Tailscale changes (exit node, logout) run one at a time, in the order they came, whichever connection sent them:
    /// one still waiting for the engine is never overtaken by a later one.
    private static let tailscale = DispatchQueue(label: "app.unbraid.tailscale", qos: .utility)
    private let lock = NSLock()
    private var events: EngineEventsProtocol?
    private var closers: [@Sendable () -> Void] = []
    private var closed = false
    /// Ended from here for a stale stream or a change that got no answer in time (see `change`).
    weak var connection: NSXPCConnection?
    /// The user whose app this is: the owner of what it stages, and the only one served while their engine runs.
    fileprivate let uid: uid_t
    /// Checked right before each use of the engine: the owner can change between calls.
    private var owns: Bool { Ownership.mayUse(uid, running: PacketTunnelProvider.owner) }

    init(events: EngineEventsProtocol?, uid: uid_t) {
        self.events = events
        self.uid = uid
    }

    /// Never from another engine, even if its owner is the same: a stale stream ends so the app can subscribe again.
    /// Every start and stop makes a new engine, so the owner checks below only back that up.
    @discardableResult
    func send(engine: Int, data: Bool = true, _ f: (EngineEventsProtocol) -> Void) -> Bool {
        let current = PacketTunnelProvider.subscription
        guard current.engine == engine else { end(); return false }
        switch current.owner {
        case uid?: break
        case nil: if data { return false }
        case _?: end(); return false
        }
        guard let e = lock.withLock({ closed ? nil : events }) else { return false }
        f(e)
        return true
    }

    /// Invalidation wakes the app's retry even when the old engine never sends another stream-end callback.
    func end() {
        close()
        connection?.invalidate()
    }

    /// Keeps `closer` for when the connection ends; false (and run now) if it already has.
    @discardableResult
    private func adopt(_ closer: @escaping @Sendable () -> Void) -> Bool {
        let kept = lock.withLock {
            if !closed { closers.append(closer) }
            return !closed
        }
        if !kept { Self.queue.async(execute: closer) }
        return kept
    }

    private var isOpen: Bool { lock.withLock { !closed } }

    func close() {
        let all = lock.withLock {
            defer { closers = []; closed = true; events = nil }
            return closers
        }
        // Callbacks only hand values over: closing a stream from inside one of its callbacks would wait for itself.
        for c in all { Self.queue.async(execute: c) }
    }

    func checkConfig(_ json: String, reply: @escaping (String?) -> Void) {
        nonisolated(unsafe) let reply = reply
        Self.queue.async {
            // The engine builds plugins and TLS clients while checking: only a config of the compiler's shape gets that far.
            guard let checked = try? ConfigVet.check(json) else { return reply("The configuration was refused") }
            var error: NSError?
            LibboxCheckConfig(checked, &error)
            reply(error.map { Redact.clean($0.localizedDescription) })
        }
    }

    func stageConfig(_ json: String, search: String?, persist: Bool, reply: @escaping ([String: String]) -> Void) {
        nonisolated(unsafe) let reply = reply
        let uid = self.uid, epoch = Staging.shared.epoch(for: uid)
        Self.queue.async {
            // Another user's running engine is theirs to change (checked again where the reload runs).
            guard Ownership.mayStage(uid, running: PacketTunnelProvider.owner) else { return reply(["error": Ownership.otherUser, "foreign": "1"]) }
            guard let checked = Self.check(json, search: search, reply) else { return }
            // Kept by the process, not this connection: the app closes it as soon as it has the token.
            guard let staged = try? Staging.shared.stage(checked, search: search, persist: persist, uid: uid, epoch: epoch) else {
                return reply(["error": "Could not stage the configuration"])
            }
            reply(["token": staged.token, "revision": staged.revision])
        }
    }

    func sealConfig(_ json: String, search: String?, reply: @escaping ([String: String]) -> Void) {
        nonisolated(unsafe) let reply = reply
        let uid = self.uid, asked = (epoch: Staging.shared.epoch(for: uid), engine: PacketTunnelProvider.engine, seals: PacketTunnelProvider.sealCount)
        Self.queue.async {
            guard let checked = Self.check(json, search: search, reply) else { return }
            reply(PacketTunnelProvider.seal(checked, search: search, for: uid, asked: asked))
        }
    }

    func dropFallback(_ expected: String, reply: @escaping ([String: String]) -> Void) {
        nonisolated(unsafe) let reply = reply
        let uid = self.uid
        Self.queue.async { reply(["result": PacketTunnelProvider.dropFallback(uid, expected: expected)]) }
    }

    func sealFallback(_ json: String, before deadline: UInt64, reply: @escaping ([String: String]) -> Void) {
        nonisolated(unsafe) let reply = reply
        let uid = self.uid
        Self.queue.async {
            guard let checked = Self.check(json, search: "", reply) else { return }
            // Never anything that holds an account or reaches a server: this path needs no running engine of theirs.
            guard ConfigVet.isFallback(checked) else { return reply(["error": "The configuration was refused"]) }
            reply(PacketTunnelProvider.sealFallback(checked, for: uid, before: deadline))
        }
    }

    /// Checked before anything changes: a configuration the engine refuses never invalidates the sealed one. Nil once
    /// the refusal was replied.
    private static func check(_ json: String, search: String?, _ reply: ([String: String]) -> Void) -> String? {
        if let search, !search.isEmpty, !Staging.isSearchDomain(search) { reply(["error": "The search domain was refused"]); return nil }
        guard let checked = try? ConfigVet.check(json) else { reply(["error": "The configuration was refused"]); return nil }
        var error: NSError?
        LibboxCheckConfig(checked, &error)
        if let error { reply(["error": Redact.clean(error.localizedDescription)]); return nil }
        return checked
    }

    func revisions(reply: @escaping ([String: String]) -> Void) {
        nonisolated(unsafe) let reply = reply
        let uid = self.uid
        Self.queue.async { reply(PacketTunnelProvider.revisions(for: uid)) }
    }

    func ownership(reply: @escaping ([String: String]) -> Void) {
        // A lock read: Disconnect asks before stopping, and must not wait for a start or reload holding the engine.
        reply(Ownership.mayStage(uid, running: PacketTunnelProvider.owner) ? [:] : ["foreign": "1"])
    }

    func authorizeReset(reply: @escaping ([String: String]) -> Void) {
        nonisolated(unsafe) let reply = reply
        let uid = self.uid, epoch = Staging.shared.epoch(for: uid)
        Self.queue.async {
            // While another user's engine runs, this user's own identity is all a reset may remove: done here, without a
            // token in the pool or a message to their tunnel.
            switch Result(catching: { try PacketTunnelProvider.resetIdentity(uid) }) {
            case .success(true): return reply(["done": "1"])
            case .success(false): break
            case .failure: return reply([:])
            }
            // What it may remove is decided when it runs, against whoever owns the engine and the sealed copy then.
            guard let t = try? Staging.shared.stage("", persist: false, uid: uid, epoch: epoch, for: .reset) else { return reply([:]) }
            reply(["token": t.token])
        }
    }

    func forgetSealed(_ expected: String, reply: @escaping ([String: String]) -> Void) {
        nonisolated(unsafe) let reply = reply
        let uid = self.uid
        Self.queue.async { reply(["result": PacketTunnelProvider.forget(uid, expected: expected)]) }
    }

    func subscribeStats(interval: Int64, logs: Bool, reply: @escaping (Bool) -> Void) {
        nonisolated(unsafe) let reply = reply
        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandStatus)
        options.addCommand(LibboxCommandConnections)
        #if DEBUG
        if logs { options.addCommand(LibboxCommandLog) }
        #endif
        options.statusInterval = min(max(interval, 1_000_000_000), 60_000_000_000)
        // Connect first, then hand over the cleanup: a close racing a queued connect would otherwise disconnect a client
        // that connect() then brings up for good, streaming into a closed session as root.
        Self.queue.async {
            let asked = PacketTunnelProvider.subscription
            guard asked.owner == self.uid,
                  let client = LibboxNewCommandClient(StatsRelay(self, engine: asked.engine), options) else { return reply(false) }
            let box = Unchecked(value: client)
            do { try box.value.connect() } catch { Log.error("stats: no engine connection"); return reply(false) }
            // connect() waits for a server: even if the owner came back, it must still be the same engine.
            guard PacketTunnelProvider.subscription == asked else { try? box.value.disconnect(); return reply(false) }
            reply(self.adopt { try? box.value.disconnect() })
        }
    }

    func subscribeTailscale(reply: @escaping (Bool) -> Void) {
        nonisolated(unsafe) let reply = reply
        Self.queue.async {
            // The client's cancellation first: a connection closed while the subscription is set up cancels that too.
            let asked = PacketTunnelProvider.subscription
            guard asked.owner == self.uid, let client = LibboxNewStandaloneCommandClient() else { return reply(false) }
            let c = Unchecked(value: client)
            guard self.adopt({ try? c.value.disconnect() }) else { return reply(false) }
            guard let watch = try? client.subscribeTailscaleStatus(TailscaleRelay(self, uid: self.uid, engine: asked.engine)) else {
                try? client.disconnect()
                return reply(false)
            }
            guard PacketTunnelProvider.subscription == asked else {
                _ = try? watch.close()
                try? client.disconnect()
                return reply(false)
            }
            let box = Unchecked(value: watch)
            reply(self.adopt { _ = try? box.value.close() })
        }
    }

    func stunTest(_ server: String, outboundTag: String, reply: @escaping (Bool) -> Void) {
        let answer = Once(reply)
        Self.queue.async {
            // As for statistics: the answer counts only if it came from the very engine that was theirs when asked.
            let asked = PacketTunnelProvider.subscription
            guard asked.owner == self.uid, let session = try? LibboxNewStandaloneCommandClient()?.startSTUNTest(
                server, outboundTag: outboundTag, handler: STUNRelay(answer, still: { PacketTunnelProvider.subscription == asked })) else {
                return answer.finish(false)
            }
            let box = Unchecked(value: session)
            self.adopt { _ = try? box.value.close() }
        }
    }

    /// Logging out asks the control server, which can take long: it isn't held against stops (Disconnect would wait for
    /// it), so the engine is checked just before, and no start creates another engine's server until it is answered. One
    /// the engine hasn't answered within 8 seconds is cancelled, so it ends before a start waiting for it gives up (10
    /// seconds) and doesn't keep an engine being stopped waiting as long; the app then gets no answer, as it may still
    /// have been made in part.
    func tailscaleLogout(_ endpointTag: String, reply: @escaping (Bool) -> Void) {
        change(reply) { engine, client in
            PacketTunnelProvider.loggingOut {
                guard PacketTunnelProvider.engine == engine && self.owns else { return false }
                let box = Unchecked(value: client)
                return Deadline.run(8, cancel: { try? box.value.disconnect() }) { (try? client.tailscaleLogout(endpointTag)) != nil }
            }
        }
    }

    /// The exit node is the engine's own setting, changed at once: made with engine work held, so it reaches exactly the
    /// engine it was asked of.
    func setTailscaleExitNode(_ endpointTag: String, stableID: String, reply: @escaping (Bool) -> Void) {
        let uid = self.uid
        change(reply) { engine, client in
            PacketTunnelProvider.whileRunning(engine, for: uid) {
                // The connection may have closed while engine work held this up.
                guard self.isOpen else { return false }
                // A stop waits for engine work: an engine that doesn't answer in time is cut off, and the app is given no
                // answer (it stopped waiting long before), as the change may still be made after that.
                let box = Unchecked(value: client)
                return Deadline.run(5, cancel: { try? box.value.disconnect() }) {
                    (try? client.setTailscaleExitNode(endpointTag, stableID: stableID)) != nil
                }
            }
        }
    }

    /// One Tailscale change, in turn (see `tailscale`), for the engine that ran when it was asked (`PacketTunnelProvider.engine`
    /// then), and only while that connection is open. Not cancelled once sent: the engine finishes a change even for a
    /// caller that left, so only waiting for its answer keeps the next one from landing first; only one that holds engine
    /// work or a logout too long is cut off, and its app then gets no answer. An app that gave up waiting reads the status instead.
    private func change(_ reply: @escaping (Bool) -> Void, _ f: @escaping @Sendable (Int, LibboxCommandClient) -> Bool?) {
        nonisolated(unsafe) let reply = reply
        let engine = PacketTunnelProvider.engine
        Self.tailscale.async {
            guard self.isOpen, let client = LibboxNewStandaloneCommandClient() else { return reply(false) }
            if let answer = f(engine, client) { return reply(answer) }
            // Cut off: the app gets no answer (nil), never a refusal, as the change may still be made. The connection is
            // ended first, so the reply every call is owed goes nowhere.
            self.connection?.invalidate()
            reply(false)
        }
    }
}

/// An XPC reply block may run only once: the first answer wins.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Bool) -> Void)?
    init(_ reply: @escaping (Bool) -> Void) { self.reply = reply }
    func finish(_ v: Bool) { lock.withLock { defer { reply = nil }; return reply }?(v) }
}

/// Engine values aren't Sendable; each is used by one closure at a time.
private struct Unchecked<T>: @unchecked Sendable { let value: T }

/// gomobile calls back on its own threads: copy the values out and send them on.
private final class StatsRelay: NSObject, LibboxCommandClientHandlerProtocol, @unchecked Sendable {
    private weak var session: CommandSession?
    private let engine: Int
    init(_ session: CommandSession, engine: Int) { self.session = session; self.engine = engine }

    func write(_ events: LibboxConnectionEvents?) {
        guard let events, let it = events.iterator() else { return }
        var list: [EngineWire.Event] = []
        while it.hasNext() {
            guard let e = it.next() else { continue }
            let kind: EngineWire.Event.Kind
            switch Int64(e.type) {
            case LibboxConnectionEventNew: kind = .new
            case LibboxConnectionEventUpdate: kind = .update
            case LibboxConnectionEventClosed: kind = .closed
            default: continue
            }
            let connection = e.connection.map { c in
                var trace: String?
                #if DEBUG
                if kind == .new { trace = "\(c.network) \(c.destination) \(c.domain) rule=\(c.rule) out=\(c.outbound)" }
                #endif
                return EngineWire.Connection(up: c.uplinkTotal, down: c.downlinkTotal, path: c.processInfo?.processPath ?? "",
                                             chain: Self.strings(c.chain()), inbound: c.inbound, createdAt: c.createdAt,
                                             closedAt: c.closedAt, trace: trace)
            }
            list.append(EngineWire.Event(kind: kind, id: e.id_, deltaUp: e.uplinkDelta, deltaDown: e.downlinkDelta, connection: connection))
        }
        guard let data = try? JSONEncoder().encode(EngineWire.Events(reset: events.reset, list: list)) else { return }
        session?.send(engine: engine) { $0.connectionEvents(data) }
    }

    func writeStatus(_ message: LibboxStatusMessage?) { session?.send(engine: engine) { $0.status() } }
    func disconnected(_ message: String?) { session?.send(engine: engine, data: false) { $0.lost() } }
    func connected() {}
    func clearLogs() {}
    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode: String?) {}
    func setDefaultLogLevel(_ level: Int32) {}
    func updateClashMode(_ newMode: String?) {}
    func writeGroups(_ message: (any LibboxOutboundGroupIteratorProtocol)?) {}
    func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {
        #if DEBUG
        var lines: [String] = []
        while let it = messageList, it.hasNext() { if let e = it.next() { lines.append("log \(e.level) \(e.message)") } }
        if !lines.isEmpty { session?.send(engine: engine) { $0.logs(lines) } }
        #endif
    }
    func writeOutbounds(_ message: (any LibboxOutboundGroupItemIteratorProtocol)?) {}

    private static func strings(_ s: (any LibboxStringIteratorProtocol)?) -> [String] {
        var out: [String] = []
        while let s, s.hasNext() { out.append(s.next()) }
        return out
    }
}

/// Sends Tailscale status again when only the sealed identity changed: the engine's own updates follow its events, and
/// sealing the state isn't one.
enum TailscaleWatch {
    private struct Weak: @unchecked Sendable { weak var relay: TailscaleRelay? }
    private static let relays = Mutex<[ObjectIdentifier: Weak]>([:])

    fileprivate static func add(_ r: TailscaleRelay) { relays.withLock { $0 = $0.filter { $0.value.relay != nil }; $0[ObjectIdentifier(r)] = Weak(relay: r) } }

    /// Asynchronous: called from under the platform's locks and engine work.
    static func refresh() {
        DispatchQueue.global(qos: .utility).async {
            for r in relays.withLock({ $0.values.compactMap(\.relay) }) { r.resend() }
        }
    }
}

/// Reads the engine's Tailscale status on libbox's thread and sends the exit nodes on.
fileprivate final class TailscaleRelay: NSObject, LibboxTailscaleStatusHandlerProtocol, @unchecked Sendable {
    private weak var session: CommandSession?
    private let uid: uid_t
    private let engine: Int
    /// The last update sent: the engine pushes on every peer counter change, the app needs only what it shows. `base`:
    /// the last status without the identity and the node it was for, to send again when only the
    /// identity changes. One send at a time, so an update read before the identity changed can't follow the one after.
    private let lock = NSLock()
    private var last: Data?
    private var base: (status: EngineWire.Tailscale, node: String)?
    init(_ session: CommandSession, uid: uid_t, engine: Int) {
        self.session = session
        self.uid = uid
        self.engine = engine
        super.init()
        TailscaleWatch.add(self)
    }

    func resend() { send(nil) }

    /// Under `lock`, before accepting or repeating any status. A stopped or replaced engine leaves nothing to resend.
    private func isCurrent() -> Bool {
        guard PacketTunnelProvider.subscription == (uid, engine) else {
            base = nil; last = nil
            session?.end()
            return false
        }
        return true
    }

    /// The identity only with status of the engine that read or sealed it, once that engine runs (not halfway through
    /// its start or reload), and for the node it runs as: the sealed state can lag behind it.
    private func send(_ new: (status: EngineWire.Tailscale, node: String)?) {
        lock.withLock {
            guard isCurrent() else { return }
            if let new { base = new }
            guard let b = base else { return }
            var update = b.status
            update.sealed = PacketTunnelProvider.runningEngine == engine ? Platform.sealedIdentity(for: uid, engine: engine, node: b.node) : nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let data = try? encoder.encode(update), data != last else { return }
            if session?.send(engine: engine, { $0.tailscale(data) }) == true { last = data }
            else { base = nil; last = nil }
        }
    }

    func onError(_ message: String?) {
        guard lock.withLock({ isCurrent() }) else { return }
        Log.error("tailscale", detail: Redact.clean(message))
        session?.send(engine: engine, data: false) { $0.lost() }
    }

    func onStatusUpdate(_ status: LibboxTailscaleStatusUpdate?) {
        guard lock.withLock({ isCurrent() }) else { return }
        guard let endpoints = status?.endpoints(), endpoints.hasNext(), let ep = endpoints.next() else { return }
        var nodes: [EngineWire.Tailscale.Node] = []
        if let groups = ep.userGroups() {
            while groups.hasNext() {
                guard let peers = groups.next()?.peers() else { continue }
                while peers.hasNext() {
                    guard let p = peers.next(), p.exitNodeOption, let ips = p.tailscaleIPs(), ips.hasNext() else { continue }
                    let name = p.hostName.isEmpty ? String(p.dnsName.split(separator: ".").first ?? "") : p.hostName
                    nodes.append(.init(name: name, ip: ips.next(), online: p.online, id: p.stableID, exit: p.exitNode))
                }
            }
        }
        let exit = ep.exitNode?.stableID ?? ""
        let status = EngineWire.Tailscale(authURL: ep.authURL.isEmpty ? nil : ep.authURL, backendState: ep.backendState, suffix: ep.magicDNSSuffix,
                                          nodes: nodes.sorted { $0.name.lowercased() < $1.name.lowercased() }, exitNode: exit.isEmpty ? nil : exit)
        send((status, ep.self_?.stableID ?? ""))
    }
}

/// The NAT-type phases after the external address aren't needed.
private final class STUNRelay: NSObject, LibboxSTUNTestHandlerProtocol, @unchecked Sendable {
    private let answer: Once
    /// Whether the engine and its owner are still those the test was asked of.
    private let still: @Sendable () -> Bool
    init(_ answer: Once, still: @escaping @Sendable () -> Bool) { self.answer = answer; self.still = still }

    func onProgress(_ progress: LibboxSTUNTestProgress?) { if let p = progress, !p.externalAddr.isEmpty { answer.finish(still()) } }
    func onResult(_ result: LibboxSTUNTestResult?) { answer.finish(still()) }
    func onError(_ message: String?) { answer.finish(false) }
}
