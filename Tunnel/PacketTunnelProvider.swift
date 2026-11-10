import Foundation
@preconcurrency import Libbox
import NetworkExtension
import Synchronization

/// The engine host. It runs sing-box with the config the app compiled and nothing else: link picking, health checks
/// and stats live in the app. It keeps the last good config sealed, so Connect On Demand can start it without the app.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private var server: LibboxCommandServer?
    private var platform: Platform?
    nonisolated(unsafe) private static var ready = false
    /// Root's container inside the sandbox; only root can read it.
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private var fakeBlock: Int?
    static let vault = Sealed(dir: home.appending(path: "Sealed"), account: "tunnel")
    private static let invalidConfig = home.appending(path: "config.invalid")
    /// Where sing-box's own Taildrop receiver kept files from tailnet peers, before the engine patch removed it.
    private static let taildrop = home.appending(path: "Working/Taildrop")
    /// The user whose app started the engine, and the revision of the configuration it runs (nil while a reload is
    /// under way or after one failed: the engine closes the old service first); nil while stopped. With it, under the same
    /// lock so the two are read as one, the count of engine starts, reloads and stops: a Tailscale change asked of one
    /// engine is never made to the next.
    private static let running = Mutex<(engine: (revision: String?, owner: uid_t)?, count: Int)>((nil, 0))
    /// The provider whose engine runs or starts, on `work` only. Should NetworkExtension start a new one before the old
    /// one's stop, the old engine is closed first and its late stop leaves the new one's state and files alone.
    nonisolated(unsafe) private static var live: PacketTunnelProvider?
    /// Users who signed out while the sealed copy couldn't be read: a copy of theirs is never started, and is dropped once
    /// they connect again (or sign out once more while it can be read).
    private static func forgotten(_ uid: uid_t) -> URL { home.appending(path: "forgotten-\(uid)") }
    /// Whose engine runs: the only user whose app may watch or change it. It stays theirs through a failed reload.
    static var owner: uid_t? { running.withLock { $0.engine?.owner } }
    static var engine: Int { running.withLock { $0.count } }
    /// One snapshot for subscriptions: an owner returning after another start is still a different engine.
    static var subscription: (owner: uid_t?, engine: Int) { running.withLock { ($0.engine?.owner, $0.count) } }
    /// The engine's count once it runs; nil halfway through a start or reload, and while stopped.
    static var runningEngine: Int? { running.withLock { $0.engine?.revision == nil ? nil : $0.count } }
    /// Held by a Tailscale logout from its check of the engine to its answer, and passed by every start before it creates
    /// its command server: a logout checked against one user's engine can't reach a server another user's start creates.
    private static let logouts = NSLock()
    /// Counts withdrawals of the sealed copy (every persisting start, reload or seal, and every drop, withdraws it first): a
    /// seal asked before one is refused (see `seal`), even when the withdrawal's own seal then failed.
    private static let seals = Mutex(0)
    static var sealCount: Int { seals.withLock { $0 } }
    /// The count (`running`) of the engine an unattended start began from the credential-free fallback (`sealFallback`):
    /// a reload or a stop counts on, so only that engine is told as the fallback.
    private static let fallbackRun = Mutex<Int?>(nil)

    // Completion-handler overrides: Swift 6.2 crashes compiling the async ObjC thunks of these.
    /// Engine work runs here, never on NetworkExtension's queue: the engine calls back into setTunnelNetworkSettings,
    /// whose completion arrives on that queue, so blocking it would deadlock the start. One for the process, so the app's
    /// question about what runs is answered between starts, reloads and stops, never halfway through one.
    private static let work = DispatchQueue(label: "app.unbraid.engine")
    private var work: DispatchQueue { Self.work }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        nonisolated(unsafe) let options = options
        nonisolated(unsafe) let completionHandler = completionHandler
        work.async { self.start(options, completionHandler) }
    }

    private func start(_ options: [String: NSObject]?, _ completionHandler: @escaping (Error?) -> Void) {
        // Start options aren't authenticated (scutil passes any): all they can do is name a configuration the app staged
        // over XPC. Every other start (Connect on Demand, System Settings, scutil, a used or expired token) runs the sealed
        // copy as it is, and never seals: one failed attempt must not block every later one.
        Self.sweepSealedTemps()
        Self.dropForgotten()
        let token = Staging.token(in: options)
        let staged = token.flatMap { Staging.shared.take($0) }
        guard let source = staged.map({ ($0.config, $0.uid, $0.search, false) }) ?? Self.sealedConfig() else {
            return completionHandler(Self.error(token == nil ? "Open unbraid to connect." : "The connection request expired. Try again."))
        }
        let (given, owner, search, fallback) = source
        let config: String
        do {
            // The engine runs (and the vault keeps) the checked copy, never the text as received.
            config = try ConfigVet.check(given)
        } catch {
            // A copy an older version sealed can lack what this one requires: the app seals a current one when it connects.
            // A Connect whose request expired fell back on that copy: trying again stages a current one.
            let message = token == nil ? "Open unbraid and connect once to update the saved connection."
                : staged == nil ? "The connection request expired. Try again." : Redact.clean(error.localizedDescription)
            return completionHandler(Self.error(message))
        }
        if let old = Self.live {
            // Another user's engine (still) runs: never replaced by a start of someone else's. One already running here (a
            // second start of this provider, or another provider's) is stopped first, its command server with it.
            guard Self.owner == nil || Self.owner == owner else { return completionHandler(Self.error(Ownership.otherUser)) }
            old.stop()
        }
        Self.live = self
        // Owned from here, before its command server is up: a stream that connects to it must already see whose it is,
        // and another user's app asking whether to stop it must already be told it isn't theirs.
        Self.running.withLock { $0 = ((nil, owner), $0.count + 1) }
        // A logout checked before this point finishes first: the server it could reach is closed by now, so it fails at
        // once. One that holds on (it never should) fails the start rather than reach this engine's server.
        guard Self.logouts.lock(before: Date(timeIntervalSinceNow: 10)) else {
            stop()
            return completionHandler(Self.error("The tunnel couldn't start. Try again."))
        }
        Self.logouts.unlock()
        do {
            let persist = staged?.persist ?? false
            if persist { try Self.invalidateConfig() }
            Self.setup()
            try Self.clearCache()
            let block = try Self.nextFakeBlock()
            let checked = try ConfigVet.fakeBlock(config, block)
            let run = try ConfigVet.owned(checked, by: owner)
            Self.dropLeftovers()
            let platform = Platform(self, owner: owner)
            platform.use(search: search ?? profileSearch)
            let server: LibboxCommandServer = try call { LibboxNewCommandServer(platform, platform, $0) }
            self.platform = platform
            self.server = server
            try server.start()
            try Data(String(block).utf8).write(to: Self.fakePending, options: .atomic)
            try server.startOrReloadService(run, options: LibboxOverrideOptions())
            try Data(String(block).utf8).write(to: Self.fakeCounter, options: .atomic)
            try Self.remove(Self.fakePending)
            fakeBlock = block
            // Before the start completes: the app reads it once the tunnel shows connected.
            let count = Self.running.withLock { $0.engine = (Staging.revision(config, search: search), owner); return $0.count }
            Self.fallbackRun.withLock { $0 = fallback && ConfigVet.isFallback(config) ? count : nil }
            TailscaleWatch.refresh()
            if persist { Self.persistOrStayInvalid(config, owner: owner, search: search) }
            completionHandler(nil)
        } catch {
            stop()
            Log.error("start", error: error)
            completionHandler(Self.error(Redact.clean(error.localizedDescription)))
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        nonisolated(unsafe) let completionHandler = completionHandler
        work.async { self.stop(); completionHandler() }
    }

    /// NE authenticates the owning app, not the user: [3] and a staging token swaps the running configuration, [2] and a
    /// reset token resets Tailscale. The token says whose app asked.
    override func handleAppMessage(_ data: Data, completionHandler: ((Data?) -> Void)?) {
        nonisolated(unsafe) let completionHandler = completionHandler
        work.async { self.reload(data, completionHandler) }
    }

    private func reload(_ data: Data, _ completionHandler: ((Data?) -> Void)?) {
        do {
            if data.first == 2 {
                guard let asked = Staging.shared.take(String(decoding: data.dropFirst(), as: UTF8.self), for: .reset) else { throw Fail("The reset expired. Try again.") }
                // Only the asker's staged changes go: another user's start waiting meanwhile is theirs.
                Staging.shared.clear(uid: asked.uid)
                // Their sealed copy (it may hold the account being reset) whether or not the engine is theirs to stop.
                let seal = Ownership.forget(asked.uid, seal: Self.seal()) ?? .keep
                switch Ownership.reset(asked.uid, running: Self.owner) {
                case .ownIdentity:
                    try Self.removeIdentity(asked.uid)
                    try Self.apply(seal, for: asked.uid)
                case .everything:
                    // A message that reached an older provider while a newer one runs: that engine isn't this one's to stop.
                    guard Self.live == nil || Self.live === self else { throw Fail("Not running") }
                    try Self.apply(seal, for: asked.uid)
                    // Stop all state writers before deleting both tsnet's directory and the sealed node identity.
                    let wasRunning = server != nil
                    stop()
                    // A tunnel started again meanwhile (System Settings, scutil) goes down with its engine: left up, it
                    // would route everything into nothing.
                    if wasRunning { cancelTunnelWithError(nil) }
                    try Self.removeIdentity(asked.uid)
                    // "tailscale": the identity an older version kept for whoever connected; nobody's now. "Working/tailscale":
                    // tsnet's folder, which older versions shared between users.
                    for url in [Self.vault.dir.appending(path: "tailscale"), Self.home.appending(path: "Working/tailscale"), Self.taildrop] { try Self.remove(url) }
                }
                completionHandler?(EngineAck.done)
            } else if data.first == 3 {
                // The configuration itself was staged over XPC; the message only names it.
                guard let staged = Staging.shared.take(String(decoding: data.dropFirst(), as: UTF8.self)) else { throw Fail("The change expired. Try again.") }
                guard Self.live === self, let server, let owner = Self.owner else { throw Fail("Not running") }
                // Checked again here, where engine changes are serialised: the owner may have changed since staging.
                guard owner == staged.uid else { throw Fail(Ownership.otherUser) }
                let config = try ConfigVet.check(staged.config)
                guard let block = fakeBlock else { throw Fail("Not running") }
                let run = try ConfigVet.owned(ConfigVet.fakeBlock(config, block), by: owner)
                if staged.persist { try Self.invalidateConfig() }
                // The engine closes the old service before building the new one: a failure leaves neither running.
                Self.running.withLock { $0.engine?.revision = nil; $0.count += 1 }
                // The new engine opens the tun again, and with it the resolver's search domain: no restart for a new one.
                // Its Tailscale identity is told again once it has read its state.
                platform?.use(search: staged.search ?? profileSearch)
                platform?.forgetIdentity()
                try server.startOrReloadService(run, options: LibboxOverrideOptions())
                Self.running.withLock { $0.engine = (Staging.revision(config, search: staged.search), owner) }
                TailscaleWatch.refresh()
                // Running but not sealed is its own answer: Connect on Demand can't start this configuration.
                let sealed = !staged.persist || Self.persistOrStayInvalid(config, owner: owner, search: staged.search)
                completionHandler?(sealed ? EngineAck.done : EngineAck.unsealed)
            } else { throw Fail("Unknown request") }
        } catch { completionHandler?(Data(Redact.clean(error.localizedDescription).utf8)) }
    }

    /// The search domain older versions of the app put into the VPN profile, for a configuration staged or sealed without
    /// one ("" for none).
    private var profileSearch: String {
        let search = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["search"] as? String ?? ""
        return Staging.isSearchDomain(search) ? search : ""
    }

    /// NetworkExtension passes only NSError text to the app: a Swift error's description would be lost.
    private static func error(_ text: String) -> NSError { NSError(domain: "app.unbraid", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    override func sleep(completionHandler: @escaping () -> Void) {
        nonisolated(unsafe) let completionHandler = completionHandler
        work.async { self.server?.pause(); completionHandler() }
    }
    override func wake() { work.async { self.server?.wake() } }

    private func stop() {
        try? server?.closeService()
        server?.close()
        server = nil
        platform?.close()
        platform = nil
        fakeBlock = nil
        // A newer provider's engine runs (see `live`): its owner, cache and files stay.
        guard Self.live == nil || Self.live === self else { return }
        Self.live = nil
        Self.running.withLock { $0 = (nil, $0.count + 1) }
        // The engine's cache names every domain looked up: it never outlives a connection.
        do { try Self.clearCache() } catch { Log.error("cache cleanup", error: error) }
        Self.dropLeftovers()
    }

    /// What older versions left: files tailnet peers sent the engine (this one takes none), and tsnet's folder they shared
    /// between users (each user's engine has its own now). Removed at every start and stop.
    private static func dropLeftovers() {
        for url in [taildrop, home.appending(path: "Working/tailscale")] {
            do { try remove(url) } catch { Log.error("cleanup", error: error) }
        }
    }

    /// A failed write must never leave an older policy available to an unattended start.
    private static func invalidateConfig() throws {
        seals.withLock { $0 += 1 }
        try Data().write(to: invalidConfig, options: .atomic)
    }

    /// The tunnel runs even when its config can't be sealed (an unreadable keychain key): the invalid marker set before
    /// it stays, so Connect on Demand refuses to start from an older copy until the app connects again. False then: the
    /// app keeps Connect on Demand off and says so.
    @discardableResult
    private static func persistOrStayInvalid(_ config: String, owner: uid_t, search: String?) -> Bool {
        do { try persist(config, owner: owner, search: search); return true } catch { Log.error("config not sealed", error: error); return false }
    }

    /// The copy an unattended start runs, whose it is, its search domain and whether it is the fallback (`sealFallback`):
    /// none while a newer one failed to seal, nor one an older version sealed without an owner, nor one of a user who
    /// signed out since.
    private static func sealedConfig() -> (String, uid_t, String?, Bool)? {
        guard !FileManager.default.fileExists(atPath: invalidConfig.path), let p = vault.read("config").flatMap(SealedPolicy.decode),
              !FileManager.default.fileExists(atPath: forgotten(p.owner).path) else { return nil }
        return (p.config, p.owner, p.search, p.fallback)
    }

    /// `sealedConfig` as checked, when the extension takes it: what an unattended start would run (`revisions` tells it).
    private static func startableConfig() -> (String, uid_t, String?, Bool)? {
        sealedConfig().flatMap { c in (try? ConfigVet.check(c.0)).map { ($0, c.1, c.2, c.3) } }
    }

    /// Runs [change] (one that only edits the engine's own state, such as Tailscale's exit node) with engine work held: only
    /// if the engine is still the one counted [asked], [uid]'s, and running (not halfway through a start or reload), so
    /// nothing can replace it between this check and the change.
    static func whileRunning(_ asked: Int, for uid: uid_t, _ change: () -> Bool?) -> Bool? {
        work.sync {
            guard running.withLock({ $0.count == asked && $0.engine?.owner == uid && $0.engine?.revision != nil }) else { return false }
            return change()
        }
    }

    /// Runs a Tailscale logout's check and request (see `logouts`).
    static func loggingOut<T>(_ logout: () -> T) -> T { logouts.withLock(logout) }

    /// A copy kept for a user who signed out while it couldn't be read, readable again now: it is theirs, so it goes, and
    /// their marker with it. Checked whenever the engine starts or the copy is asked about.
    private static func dropForgotten() {
        dispatchPrecondition(condition: .onQueue(work))
        // The copy a failed drop was for (none sealed since): removed now if it can be.
        if FileManager.default.fileExists(atPath: dropPending.path) {
            do {
                try invalidateConfig()
                try remove(vault.dir.appending(path: "config"))
                try remove(dropPending)
                sweepSealedTemps()
            } catch { Log.error("pending drop", error: error) }
        }
        guard (try? FileManager.default.contentsOfDirectory(atPath: home.path))?.contains(where: { $0.hasPrefix("forgotten-") }) == true,
              let o = Ownership.signedOut(seal(), forgotten: { FileManager.default.fileExists(atPath: forgotten($0).path) }) else { return }
        do { try apply(.drop, for: o) } catch { Log.error("signed-out copy", error: error) }
    }

    /// A drop of the sealed copy failed: it is the one to remove, until a newer one is sealed (`persist`).
    private static var dropPending: URL { home.appending(path: "config.drop-pending") }

    /// The id of the latest sealing (`persist`): a drop names it, so one that comes late never drops a newer copy.
    private static var sealId: URL { home.appending(path: "config-id") }

    /// What `uid`'s app is told names the sealed copy now (`Ownership.sealing`). An id that exists but can't be read
    /// fences nothing: a drop then stands (`Ownership.forgetStands`).
    private static func sealing(_ uid: uid_t) -> String? {
        let exists = FileManager.default.fileExists(atPath: sealId.path)
        let id = exists ? (try? Data(contentsOf: sealId)).map { String(decoding: $0, as: UTF8.self) } : nil
        return Ownership.sealing(uid, seal: seal(), id: id, unreadable: exists && id == nil)
    }

    /// Whose the sealed copy is, telling one that can't be read now from none at all.
    private static func seal() -> Ownership.Seal {
        do {
            guard let data = try vault.open("config") else { return .none }
            return SealedPolicy.decode(data).map { .owner($0.owner) } ?? .legacy
        } catch { return .unreadable }
    }

    /// After a sign-out: the sealed copy may hold the account's credentials, and anyone can start it (scutil, Connect on
    /// Demand). Dropped with everything this user staged, in one step with engine changes; another user's engine, sealed
    /// copy and staged changes are left alone (see `Ownership.forget`). A request that comes late, after [uid]'s app sealed
    /// a newer copy than the one it named ([expected]), leaves that copy (`Ownership.forgetStands`); what they staged goes
    /// either way, and seals they asked for before it are refused.
    static func forget(_ uid: uid_t, expected: String) -> String {
        work.sync {
            dropForgotten()
            Staging.shared.clear(uid: uid)
            let current = sealing(uid)
            guard Ownership.forgetStands(expected: expected, current: current) else { return "superseded" }
            let pending = FileManager.default.fileExists(atPath: dropPending.path)
            guard let step = Ownership.forget(uid, seal: seal(), dropPending: pending) else { return "foreign" }
            var applied = false
            do { try apply(step, for: uid); applied = true } catch { Log.error("forget", error: error) }
            // A drop that failed is remembered with the copy it was for: it still goes, at the next drop or start
            // (`dropForgotten`), until a newer copy is sealed.
            if step == .drop {
                if applied { try? remove(dropPending) } else { try? Data().write(to: dropPending, options: .atomic) }
            }
            // Without a readable id nothing tells this copy from a newer one: also never started as theirs, until their app
            // seals again (which lifts that).
            if applied, current == Ownership.unreadableSealing, step == .drop { try? suppress(uid) }
            // Not dropped: at least never started as theirs meanwhile, and still owed (`Ownership.forgetResult`).
            let suppressed = !applied && step == .drop && (try? suppress(uid)) != nil
            return Ownership.forgetResult(step: step, applied: applied, suppressed: suppressed)
        }
    }

    /// Drops [uid]'s fallback once Connect on Demand is off: only the one sealed as [expected], still theirs and still a
    /// fallback (`Ownership.dropsFallback`); anything else stays ("kept"). Unlike a sign-out's drop, nothing they staged goes.
    static func dropFallback(_ uid: uid_t, expected: String) -> String {
        work.sync {
            let id = (try? Data(contentsOf: sealId)).map { String(decoding: $0, as: UTF8.self) }
            let fallback = sealedConfig().map { $0.1 == uid && $0.3 && ConfigVet.isFallback($0.0) } ?? false
            guard Ownership.dropsFallback(uid, expected: expected, current: id, seal: seal(), fallback: fallback) else { return "kept" }
            do { try apply(.drop, for: uid); return "ok" } catch { Log.error("fallback not dropped", error: error); return "failed" }
        }
    }

    /// A reset by [uid] while another user's engine runs removes only [uid]'s own Tailscale identity, which isn't in use.
    /// False when no other user's engine runs: the reset then goes to the tunnel, which may stop the engine.
    static func resetIdentity(_ uid: uid_t) throws -> Bool {
        try work.sync {
            guard !Ownership.mayStage(uid, running: owner) else { return false }
            Staging.shared.clear(uid: uid)
            try removeIdentity(uid)
            try apply(Ownership.forget(uid, seal: seal()) ?? .keep, for: uid)
            return true
        }
    }

    /// The user's node identity, and tsnet's own files (tailnet lock state, certificates) kept beside the engine's.
    private static func removeIdentity(_ uid: uid_t) throws {
        try remove(vault.dir.appending(path: Platform.tailscaleState(uid)))
        try remove(home.appending(path: "Working").appending(path: ConfigVet.tailscaleDirectory(uid)))
        sweepSealedTemps()
    }

    /// What [uid]'s engine runs and what an unattended start would run for them, as revisions: `.connected` alone proves
    /// neither. See `Ownership.revisions`.
    static func revisions(for uid: uid_t) -> [String: String] {
        work.sync {
            dropForgotten()
            let sealed = startableConfig().map { (revision: Staging.revision($0.0, search: $0.2), owner: $0.1, fallback: $0.3 && ConfigVet.isFallback($0.0)) }
            let (engine, count) = running.withLock { ($0.engine.map { ($0.revision, $0.owner) }, $0.count) }
            var out = Ownership.revisions(uid, running: engine, sealed: sealed.map { ($0.revision, $0.owner) },
                                          fallback: (fallbackRun.withLock { $0 == count }, sealed?.fallback == true))
            out["seal"] = sealing(uid)
            return out
        }
    }

    /// Seals [config] for [uid]'s unattended starts without running it: a pause runs another configuration, and what
    /// Connect on Demand would start must still block what the user blocked meanwhile. Only while [uid]'s engine runs
    /// (see `Ownership.maySeal`): the same engine as when asked, no sign-out or reset by [uid] since, and no other copy
    /// withdrawn since. Once the older copy is withdrawn, a failure leaves none ("invalid"): an older policy never stays
    /// available.
    static func seal(_ config: String, search: String?, for uid: uid_t, asked: (epoch: Int, engine: Int, seals: Int)) -> [String: String] {
        work.sync {
            if let refused = Ownership.maySeal(uid, running: owner, epoch: (asked.epoch, Staging.shared.epoch(for: uid)),
                                               engine: (asked.engine, engine), seals: (asked.seals, sealCount)) { return refused }
            do { try invalidateConfig() } catch { return ["error": Redact.clean(error.localizedDescription)] }
            do {
                try persist(config, owner: uid, search: search)
                return ["durable": Staging.revision(config, search: search)]
            } catch {
                Log.error("config not sealed", error: error)
                return ["error": Redact.clean(error.localizedDescription), "invalid": "1"]
            }
        }
    }

    /// Returns the new sealing's id.
    @discardableResult
    private static func persist(_ config: String, owner: uid_t, search: String?, fallback: Bool = false) throws -> String {
        // A new id for every sealing, written first: a copy written after it never carries an older one (`sealing`).
        let id = UUID().uuidString
        let previous = try? Data(contentsOf: sealId)
        try Data(id.utf8).write(to: sealId, options: .atomic)
        // One sealed file for all of it: a crash can't pair one user's configuration with another's ownership.
        guard let data = SealedPolicy.encode(config, owner: owner, search: search, fallback: fallback), vault.write("config", data) else {
            // Nothing was sealed (a failed write never replaces the file): the copy there is still the one the previous id
            // names, so a drop naming it must still stand. Without that id, none: a drop then stands (`forgetStands`).
            if previous.map({ (try? $0.write(to: sealId, options: .atomic)) == nil }) ?? true { try? remove(sealId) }
            throw Fail("Tunnel configuration not saved")
        }
        // Sealed by their app since they signed out: this copy holds what they use now. Until both markers are gone,
        // nothing starts it, and the app is told it isn't sealed. A drop still pending was for the copy this replaced.
        try remove(forgotten(owner))
        try remove(dropPending)
        try remove(invalidConfig)
        return id
    }

    /// Seals [config], which can use no account and lets traffic out as Direct does (`ConfigVet.isFallback`, checked by the
    /// caller), as [uid]'s copy in place of one a sign-out or erase removed while Connect on Demand couldn't be turned off:
    /// it then starts a tunnel that keeps the Mac online (with the kill switch, nothing else would) rather than fail again
    /// and again. Only where nothing an unattended start runs is sealed, and never over another user's copy
    /// (`Ownership.mayFallback`: "kept"), nor while another user's engine runs ("foreign"). Needs no running engine.
    /// "durable" and "seal": its revision and sealing; "error" otherwise. Not once [deadline] (system uptime) has passed.
    static func sealFallback(_ config: String, for uid: uid_t, before deadline: UInt64) -> [String: String] {
        work.sync {
            // Checked once the queue is ours (nothing below waits): the app stops waiting 5 s later than this.
            guard DispatchTime.now().uptimeNanoseconds < deadline else { return ["error": "The request expired"] }
            dropForgotten()
            guard Ownership.mayStage(uid, running: owner) else { return ["error": Ownership.otherUser, "foreign": "1"] }
            guard Ownership.mayFallback(uid, seal: seal(), startable: startableConfig() != nil,
                                        dropPending: FileManager.default.fileExists(atPath: dropPending.path)) else { return ["kept": "1"] }
            do {
                let id = try persist(config, owner: uid, search: "", fallback: true)
                return ["durable": Staging.revision(config, search: ""), "seal": id]
            } catch {
                Log.error("fallback not sealed", error: error)
                return ["error": Redact.clean(error.localizedDescription)]
            }
        }
    }

    private static func suppress(_ uid: uid_t) throws { try Data().write(to: forgotten(uid), options: .atomic) }

    /// What a sign-out or reset by [uid] does to the sealed copy (see `Ownership.SealStep`).
    private static func apply(_ step: Ownership.SealStep, for uid: uid_t) throws {
        switch step {
        case .keep: break
        case .suppress: try suppress(uid)
        case .drop:
            try invalidateConfig()
            try remove(vault.dir.appending(path: "config"))
            try remove(forgotten(uid))
            sweepSealedTemps()
        }
    }

    private static func sweepSealedTemps() {
        if !Sealed.sweepTemps(vault.dir) { Log.error("sealed: temp cleanup failed") }
    }

    private static func remove(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Fail("Could not delete \(url.lastPathComponent)") }
    }

    private static var fakeCounter: URL { home.appending(path: "fake-ip-block") }
    private static var fakePending: URL { home.appending(path: "fake-ip-pending") }

    private static func nextFakeBlock() throws -> Int {
        // A start interrupted after the engine was asked to run may already have handed out addresses.
        let source = FileManager.default.fileExists(atPath: fakePending.path) ? fakePending : fakeCounter
        guard FileManager.default.fileExists(atPath: source.path) else { return 0 }
        // A counter that can't be read (damaged, or from a version with other blocks) must never stop every start, which
        // with the kill switch on would keep the Mac offline: any block is then as good as the next, so one is drawn.
        guard let data = try? Data(contentsOf: source), let last = Int(String(decoding: data, as: UTF8.self)),
              ConfigVet.fakeRanges.indices.contains(last) else {
            Log.error("fake addresses: counter unreadable, drawing a block")
            return ConfigVet.fakeRanges.indices.randomElement() ?? 0
        }
        return ConfigVet.nextFakeBlock(last)
    }

    private static func clearCache() throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try remove(home.appending(path: "Working/\(ConfigVet.cacheFile)\(suffix)"))
            try remove(home.appending(path: "\(ConfigVet.cacheFile)\(suffix)"))
        }
    }

    /// Engine paths and logging, once per process (at launch, see main.swift). The log keeps no lines: they could name
    /// sites and servers.
    static func setup() {
        guard !ready else { return }
        // libbox resolves relative state and cache paths against workingPath.
        for d in ["Working", "Temp"] { try? FileManager.default.createDirectory(at: home.appending(path: d), withIntermediateDirectories: true) }
        FileManager.default.changeCurrentDirectoryPath(home.path)
        let o = LibboxSetupOptions()
        o.basePath = home.path
        o.workingPath = home.appending(path: "Working").path
        o.tempPath = home.appending(path: "Temp").path
        #if DEBUG
        o.logMaxLines = 2000 // read by the app's debug trace only
        #else
        o.logMaxLines = 0
        #endif
        o.appMarketingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        // Go writes a crash's trace (which can name hosts and addresses) to Working/CrashReport-*.log, and libbox files
        // the last run's under Working/crash_reports at every launch: a crash loop under Connect on Demand would add one
        // a launch. Debug builds keep only what the last run left, release builds nothing filed (the running process's
        // own report file stays: a crash is written there, and filed away and deleted at the next launch).
        let reports = home.appending(path: "Working/crash_reports")
        func dropReports() { do { try remove(reports) } catch { Log.error("crash reports", error: error) } }
        dropReports()
        var error: NSError?
        LibboxSetup(o, &error)
        #if !DEBUG
        dropReports()
        #endif
        ready = error == nil
    }
}

/// Calls a gomobile constructor that reports failure through an NSError out-parameter.
func call<T>(_ f: (NSErrorPointer) -> T?) throws -> T {
    var error: NSError?
    let value = f(&error)
    if let error { throw error }
    guard let value else { throw Fail("Engine error") }
    return value
}
