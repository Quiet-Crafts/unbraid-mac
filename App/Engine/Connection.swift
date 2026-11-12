import Foundation
import AppKit
import Network
import NetworkExtension
import Observation

/// A Tailscale peer offering itself as an exit node.
nonisolated struct TsNode: Hashable, Sendable {
    var name: String
    var ip: String
    var online: Bool
    var id = ""
}

/// What the UI shows about the connection.
nonisolated struct VpnState: Equatable, Sendable {
    typealias Phase = Snapshot.Phase
    var phase = Phase.off
    var since = Date.distantPast
    var servers: [String: Server] = [:]
    var blocked: [String: String] = [:]
    var retryAt: [String: Date] = [:]
    var dropping: [String] = []
    var error: String?
    var tsLoginUrl: String?
    var tsState: String?
    var tsExitNodes: [TsNode] = []
    /// While paused: when the connection comes back; nil = only when resumed by hand.
    var pausedUntil: Date?
    var pausedAt = Date.distantPast
    var runState = RunState()
}

/// The brain of the VPN: picks a server for every route, compiles the engine config, starts the tunnel, applies
/// every later change without dropping it, pauses and resumes, and moves a route whose server stopped answering.
/// The engine runs in the tunnel extension; this object lives in the app (a menu bar agent started at login).
@Observable
final class Connection {
    static let shared = Connection()

    @ObservationIgnored private var runIdentity = RunState()
    private var refusedAccounts: [String: (account: String, reason: LinkPicker.Blocked)] = [:]
    private var removedPins = LinkPicker.RemovedPins()

    /// A new sign-in to [provider] is a fresh chance, even with the same credentials (signed out and in again before any
    /// connection noticed): its refusal and removed pins are forgotten.
    func forgetRefusal(_ provider: String) {
        refusedAccounts[provider] = nil
        removedPins.forget(provider)
    }
    private(set) var state = VpnState() {
        // Writing `state` here runs this again (Observation), so each write happens only when it changes something.
        didSet {
            if state.runState != runIdentity { state.runState = runIdentity }
            if state.phase != .on {
                routeWake?.cancel(); routeWake = nil
                if !state.dropping.isEmpty { state.dropping = [] }
            }
            if state.phase == .off || state.phase == .paused {
                routeRetry.clear(); blockedReasons = [:]
                if !state.retryAt.isEmpty { state.retryAt = [:] }
            }
            if state.phase == .off { removedPins = LinkPicker.RemovedPins() }
        }
    }

    #if DEBUG
    /// The smoothness matrix: a change of state like those a connected tunnel makes, with nothing connected.
    func perfPoke() { state.tsState = state.tsState == nil ? "Running" : nil }
    func perfConnected() {
        state.phase = .on; state.since = .now
        perfTags = Dictionary(uniqueKeysWithValues: store.setup.routes.map { ($0.id, "perf-\($0.id)") })
    }
    #endif

    private func recordRun(_ change: (inout RunState) -> Void) {
        let before = runIdentity
        change(&runIdentity)
        if runIdentity != before { state.runState = runIdentity }
    }
    /// Route id → engine tunnel tag of the running setup (stats and speed tests dial through it).
    var tags: [String: String] {
        #if DEBUG
        if let perfTags { return perfTags }
        #endif
        return committed?.tags ?? [:]
    }
    #if DEBUG
    private var perfTags: [String: String]?
    #endif
    /// The setup the engine runs (not the one being edited): stats attribute traffic against it.
    var running: Setup? { committed?.input.setup }
    /// Loopback port and password of the app's own way into each exit; nil until an engine runs with it.
    var probe: (port: Int, password: String)? { committed?.input.probe }

    let tunnel = TunnelControl()
    private let store = Store.shared
    /// One accepted engine configuration. Nil accounts means an adopted tunnel still needs reconciliation.
    private struct Committed {
        var input: Compiler.Input
        var json: String
        var accounts: [String: String]?
        var tags: [String: String]
        var probeDNS: [String: String]
        /// What it was built from: reconciliation compares the store with this.
        var revision: Revision
        /// A deny-all left by a change that failed twice (`Compiler.denyAll`): put back as one if a later change fails.
        var blocking = false
        /// Local app rules installed while providers are still being asked for the final configuration.
        var interim = false
        /// The search domain it runs with (`search`).
        var search = ""
    }
    private var committed: Committed?
    private var committedEngine: String?
    /// The extension revision is useful only when it still names the setup this app committed.
    var profileSwitchEngine: String? {
        guard state.phase == .on, state.runState.standIn == .none, committed?.interim == false,
              let revision = committedEngine, tunnel.applied == revision else { return nil }
        return revision
    }
    private var links: [String: Link] { committed?.input.links ?? [:] }
    private var applied: Setup? { committed?.accounts == nil ? nil : running }
    private var appliedAccounts: [String: String] { committed?.accounts ?? [:] }
    /// Everything an engine config is built from: a change in any part needs a reload.
    nonisolated private struct Revision: Equatable, Sendable {
        var setup: Setup
        var accounts: [String: String]
        var suffix: String?
        var apps: [String: [String]]
        /// An app installed again where it was remembered keeps its patterns but needs a reload (see `Compiler.Input`).
        var remembered: Set<String>
        var tsLoginPending: Bool

        init(setup: Setup, accounts: [String: String], suffix: String?, apps: [String: [String]], remembered: Set<String>, tsLoginPending: Bool) {
            self.setup = setup; self.accounts = accounts; self.suffix = suffix; self.apps = apps; self.remembered = remembered; self.tsLoginPending = tsLoginPending
        }
        init(_ input: Compiler.Input, _ accounts: [String: String]) {
            self.init(setup: input.setup, accounts: accounts, suffix: input.tsSuffix, apps: input.apps, remembered: input.remembered, tsLoginPending: input.tsLoginPending)
        }
    }
    /// The store's revision now, with the app paths of its setup as the catalog knows them.
    private var testingOwner = TestingOwner()
    private var testingBase: Setup?
    private var testingAccounts: [String: String]?
    private var testingCleanup: Task<Void, Never>?
    private(set) var testingFailures = 0

    private func revision() -> Revision {
        let keys = Array(store.setup.apps.keys), apps = AppCatalog.shared
        var setup = store.setup
        if !Lifecycle.endTesting(base: testingBase, accounts: testingAccounts, setup: setup, currentAccounts: store.accounts) { setup.testing = testingOwner.routes }
        return Revision(setup: setup, accounts: store.accounts, suffix: store.tsSuffix, apps: apps.patterns(for: apps.routingKeys(setup)), remembered: apps.remembered(keys), tsLoginPending: tsLoginPending)
    }
    /// What the committed config was built from.
    private var appliedRevision: Revision? { committed?.interim == true ? nil : committed?.revision }
    /// Edits the engine didn't take, and when they are tried again (see `Retry`): kept through automatic recovery,
    /// cleared by the user's own Connect and Disconnect.
    private var retry = Retry<Revision>()
    private var routeRetry = RouteRetry<Revision>()
    private var blockedReasons: [String: LinkPicker.Blocked] = [:]
    private var routeWake: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    /// A usable network outside the tunnel, as macOS reports it: satisfied, with an interface that isn't a tunnel's.
    private var networkUp = true
    private var networkChanges = NetworkChanges<NetworkIdentity>()
    private var networkWake: Task<Void, Never>?
    /// Later health and port policies can discard observations from the previous network.
    var onNetworkChange: (() -> Void)?
    private var healthReset = 0
    private var portStep: [String: Int] = [:]
    private var failing: Set<String> = []
    private var wakeObserver: NSObjectProtocol?

    private struct NetworkIdentity: Equatable, Sendable {
        var interfaces: [String]
        var status: String
        var expensive: Bool
        var constrained: Bool
        var gateways: [String]
    }

    private func observeNetwork(_ identity: NetworkIdentity) {
        networkChanges.observe(identity, now: .now)
        armNetworkWake()
    }

    private func armNetworkWake() {
        networkWake?.cancel()
        guard let deadline = networkChanges.deadline else { return }
        networkWake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            // The wall clock behind the sleep's own (a correction after wake): waited out again, never dropped.
            guard self.networkChanges.take(now: .now) else { return self.armNetworkWake() }
            // Taken: a later change must not cancel the reloads this wake is about to start (one may have stopped the tunnel).
            self.networkWake = nil
            self.healthReset += 1
            let resetPorts = !self.portStep.isEmpty
            self.portStep.removeAll()
            self.failing.removeAll()
            if !self.state.dropping.isEmpty { self.state.dropping = [] }
            self.onNetworkChange?()
            guard self.state.phase == .on else { return }
            if resetPorts { await self.reload(checked: self.commits, healthAction: true) }
            let routes = Set(self.routeRetry.dates.keys)
            if !routes.isEmpty { await self.reload(retrying: routes) }
        }
    }

    private func scheduleRoutes(_ blocked: [String: LinkPicker.Blocked], revision: Revision, attempted: Set<String> = []) {
        blockedReasons = blocked
        routeRetry.update(blocked, setup: revision.setup, removedPins: removedPins, revision: revision, attempted: attempted, now: .now)
        state.retryAt = routeRetry.dates
        armRouteRetry()
    }

    private func armRouteRetry() {
        routeWake?.cancel()
        guard let next = routeRetry.dates.values.min(), state.phase == .on else { routeWake = nil; return }
        let g = generation
        routeWake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.generation == g, self.state.phase == .on else { return }
            // Rearming after lookup must not cancel the reload this timer is about to start.
            self.routeWake = nil
            // A reload owns these routes until its final apply or recovery finishes.
            if self.reloadFlight.skipRetry(for: self.revision()) { return }
            let due = self.routeRetry.due(now: .now)
            // None due by the wall clock (behind the sleep's own): waited out again, never dropped.
            if !due.isEmpty { await self.reload(retrying: due) } else { self.armRouteRetry() }
        }
    }
    private var pauseRetry = Retry<PauseKey>()
    /// Resuming an expired timed pause that failed, keyed by its deadline (`armResume`).
    private var resumeRetry = Retry<Date>()
    /// Wakes reconciliation when a failed change is due again.
    private var wake: Task<Void, Never>?
    /// Taking over a running tunnel failed: tried again later rather than stopping a tunnel macOS would start again.
    private var adopting = false
    private var adoptionObserved = false
    private var adoptRetry = Retry<Int>()
    private var adoptWake: Task<Void, Never>?
    /// Looks again once the keychain may have opened (see `wakeWhenHeld`).
    private var heldWake: Task<Void, Never>?
    private var heldWakeId: UUID?
    /// Counts accepted configurations: a health check begun under an older one says nothing about this one.
    private(set) var commits = 0
    /// Changes whenever what the engine runs may have: any operation (a pause, Disconnect), a change about to be applied,
    /// an accepted configuration, or the running one given up (stopped by macOS).
    var engineEpoch: [Int] { [generation, commits, engineChanges] }
    private var engineChanges = 0
    private var lastGood: String? { committed?.json }
    private var lastInput: Compiler.Input? { committed?.input }
    private var healthWatch: Task<Void, Never>?
    @ObservationIgnored private lazy var changes = ChangeObserver(read: { [weak self] in
        guard let self else { return }
        _ = (store.setup, store.accounts, store.tsSuffix, AppCatalog.shared.patternRevision, state.phase, tunnel.status)
    }, reconcile: { [weak self] in await self?.reconcile() })
    private var resume: Task<Void, Never>?
    private var tsWatch: EngineLink.Stream?
    /// Serialises connect, reload and pause: one engine change at a time.
    private var busy = false
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    /// Bumped by every user operation: what an older one scheduled no longer runs (a wake waiting for the keychain goes).
    private var generation = 0 { didSet { cancelHeldWake(); outside.operation(); reloadFlight.clear(); reloadWork?.cancel(); lookup?.task.cancel(); if state.phase == .on { armRouteRetry() } } }

    /// Reconciliation returns after installing its offline policy, so observation can process edits during the lookup.
    private var reloadWork: Task<Void, Never>?
    private var reloadFlight = ReloadFlight<Revision>()
    /// A newer health move can supersede a lookup without changing the setup or having committed anything yet.
    private var reloadRequest = 0
    /// The provider lookups of a connect or reload under way, and the setup they are for. A newer operation (a pause, a
    /// disconnect, a stop from outside) or an edit for another setup cancels them instead of waiting behind slow providers:
    /// their answers would be for a setup that no longer counts, and the newest change then runs at once.
    /// [wanted] nil: a connect's, which only a newer operation cancels (an edit meanwhile is applied once it is up).
    private var lookup: (task: Task<LinkPicker.Result, Error>, wanted: Revision?)?

    private func lookUp(_ wanted: Revision?, _ pick: @escaping @MainActor () async throws -> LinkPicker.Result) async throws -> LinkPicker.Result {
        lookup?.task.cancel()
        let task = Task { @MainActor in
            let result = try await pick()
            try Task.checkCancellation()
            return result
        }
        lookup = (task, wanted)
        defer {
            if lookup?.task == task {
                lookup = nil
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    /// A stop of the tunnel nobody here asked for, noted when its status came (`OutsideStop`).
    private var outside = OutsideStop()
    private var resumeGeneration = 0
    /// Bumped by every erase request (see `eraseExtension`).
    private var eraseRequest = 0
    /// The erase request the "unbraid is off" notification of an interrupted sign-out was posted for: once per request.
    private var interruptedNotified: Int?
    /// An interrupted sign-out's erase left to the owed settling (`eraseOwed`): it failed (`extensionReady`,
    /// `adoptRunningTunnel`), or waited for the fallback to stop. Set only once the launch's own erase was tried, which
    /// decides whether it reconnects; a relaunch tries again itself.
    private var eraseLeft = false
    private var tsGeneration = 0
    private var tsRetry: Task<Void, Never>?
    /// Subscriptions lost in a row since the last status arrived.
    private var tsLost = 0
    private var pausedInput: Compiler.Input? { didSet { pausedJSON = nil; pausedRevision = nil } }
    /// The search domain `pausedInput` was applied with.
    private var pausedSearch = ""
    private var pausedProfile: TunnelControl.Profile?
    /// The configuration the paused engine was given for `pausedInput`, and its revision (nil = not known): while the
    /// engine still runs that, an input that compiles to the same needs no reload, which would restart the blocking
    /// engine's connections.
    private var pausedJSON: String?
    private var pausedRevision: String?
    /// Asks again what the paused engine runs (`Lifecycle.pauseCheck`): a restart nothing here saw is noticed without
    /// waiting for another change. After no answer, a converged pause isn't asked again before [pauseAskAt].
    private var pauseProbe: Task<Void, Never>?
    private var pauseAskAt: ContinuousClock.Instant?

    private init() {
        // Set this before the tunnel's initial status callback can adopt a paused engine as a protected one.
        if let pause = store.pause { state = VpnState(phase: .paused, pausedUntil: pause.until, pausedAt: pause.since) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.healthReset += 1
                if self?.state.dropping.isEmpty == false { self?.state.dropping = [] }
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let identity = NetworkIdentity(
                interfaces: path.availableInterfaces.map { "\($0.name)|\($0.type)" }.sorted(),
                status: String(describing: path.status), expensive: path.isExpensive,
                constrained: path.isConstrained, gateways: path.gateways.map { String(describing: $0) }.sorted())
            let up = path.status == .satisfied && path.availableInterfaces.contains { $0.type != .other }
            Task { @MainActor in self?.networkUp = up; self?.observeNetwork(identity) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "app.unbraid.network"))
        tunnel.onStatusChange = { [weak self] in
            // Before anything queued reads the status again: it reads what shows by then (`ReplacedReady.observe`).
            if let self { replacedReady.observe(Self.status(tunnel.status), replacement: tunnel.replacements) }
            self?.noteStop()
            Task { await self?.statusChanged() }
        }
        tunnel.onReady = { [weak self] replaced in Task { await self?.extensionReady(replaced: replaced) } }
        // Drops a quit (or an extension that didn't answer) interrupted are made now, and retried until they are. So is
        // turning Connect on Demand off when that wasn't saved before the quit: no arm happens before this is read
        // (`armOnDemand` waits for it), and it comes first when settling.
        let load = Task {
            let owed = await Running.owed(), off = await Running.onDemandOwed()
            owedDrops.formUnion(owed.keys)
            // Named in an earlier session: a seal this session confirms was asked after it, but the account it signed out
            // isn't known any more (`sealed`).
            for (p, name) in owed where !name.isEmpty && owedNames[p] == nil { owedNames[p] = name }
            onDemandNoted = off
            onDemandLoaded = true
            switch off {
            // Unless the user connected (or turned the setting on) before it was read: that supersedes their Off.
            // One the user made since launching is theirs now, not one from before.
            case .off? where !offSuperseded: offWanted = true; offIntent = true; offFromBefore = !offThisSession
            case .off?, .hold?: disarmPending = true
            case nil: noteOnDemandOwed()
            }
        }
        owedLoad = load
        Task {
            await load.value
            if !owedDrops.isEmpty || disarmPending || offWanted { await settleOwed() }
        }
        launched = Task { await Running.launched() }
    }

    /// The build launched before this one (`Running.launched`), noted once at launch: nil when none that notes it ran.
    /// Read at a reseal check only: launched is set at init, before any check can run.
    private var launched: Task<String?, Never>?

    // MARK: Actions

    /// Rebuild the blocking subset on launch; an expired timed pause resumes immediately.
    func restorePause() async {
        guard state.phase == .paused else { return }
        let g = generation
        // A sign-out a quit interrupted (its erase still pending) may have left its accounts behind: the blocking pause is
        // rebuilt (it holds no account, and rebuilding erases first), but nothing resumes on its own.
        let interrupted = store.extensionWipePending
        if interrupted {
            store.pause = (nil, state.pausedAt, nil, nil)
            state.pausedUntil = nil
            // Its record may hold the accounts the sign-out left behind: never sealed again for this pause's blocked apps,
            // also if deleting it fails (marked first, until a connect writes a new one).
            if !(await Running.taint()) { Log.error("pause: the running record couldn't be marked unusable") }
            Running.save(nil)
        }
        if let pause = store.pause, let until = pause.until, Self.remaining(pause, until: until) <= 0 { await connect(); return }
        await reconcilePause(launch: true)
        guard g == generation else { return }
        // Said once the pause is rebuilt (which clears the error line), and only if it was.
        if interrupted, state.phase == .paused {
            state.error = "A sign-out was interrupted, so unbraid doesn't resume the VPN on its own. Resume when you're ready."
        }
        startWatching()
        armResume()
    }

    /// A timed pause cannot keep its deadline after the app quits. Resume through the normal, verified apply path.
    /// A timeout or a newer operation still lets the user quit, without disconnecting or discarding the pause.
    func resumeBeforeQuit() async {
        guard store.pause?.until != nil, state.phase == .paused || state.phase == .connecting || state.phase == .on else { return }
        let before = generation
        var expected = before, started = false
        let attempt = Task {
            while !Task.isCancelled {
                switch Lifecycle.quitPause(phase: state.phase, timed: store.pause?.until != nil, current: generation, expected: before) {
                case .wait:
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                case .resume:
                    expected = before + 1
                    started = true
                    await connect()
                    return
                case .done: return
                }
            }
        }
        let finished = await bounded(7) { await attempt.value }
        if !finished {
            attempt.cancel()
            // Prevent a late provider or staging answer from starting this resume after the quit stopped waiting.
            if started, generation == expected, store.pause != nil { generation += 1; cancelResume() }
        }
        guard finished, generation == expected, state.phase == .on, store.pause == nil,
              tunnel.status == .connected, committedEngine != nil, tunnel.applied == committedEngine else {
            Log.info("quit: timed pause could not be resumed")
            return
        }
    }

    func connect() async {
        if let token = testingOwner.token { endTesting(token) }
        // What shows is a stand-in until the keychain opens the real setup: never connected (nor sealed) with it. Refused
        // before anything is overtaken (a takeover waiting for the keychain carries on); a timed resume tries again.
        store.reloadHeld()
        if store.isHeld {
            state.error = Self.locked
            if store.pause != nil, resume == nil { armResume(retry: true) }
            return
        }
        generation += 1
        let g = generation
        defer { Task { await self.removeTestingIfNeeded(g) } }
        cancelResume()
        // The user's Connect (or Resume) supersedes an Off of theirs that couldn't be saved.
        offWanted = false; offIntent = false; offSuperseded = true; offCleared += 1
        // Done, whatever it left (also when it gave way, or was cancelled waiting): a stop from now on isn't its own.
        defer { settle(g) }
        // A pause that survives a failure or cancellation keeps its deadline (a teardown ends it). An expired one retries
        // after a wait that grows with each failure (`Retry`), without a busy loop.
        defer { if g == generation, store.pause != nil { armResume(retry: true, growing: true) } }
        var reconcileOn = false
        do {
            try await exclusive {
                guard g == generation else { return }
                if state.phase == .on {
                    reconcileOn = true
                    return
                }
                let paused = state
                var applying = false
                // A blocking pause this session applied, still standing: one never applied (at launch) or a pause that
                // stopped the tunnel is always restored.
                let standing = paused.phase == .paused && pausedJSON != nil
                // A launch-time resume may fail before the blocking pause has been rebuilt.
                if paused.phase == .paused, pausedInput == nil {
                    let input = makePausedInput()
                    if !input.setup.apps.isEmpty { pausedInput = input; pausedSearch = search(input); pausedProfile = profile(input) }
                }
                state = VpnState(phase: .connecting)
                do {
                    // Provider calls suspend: an edit during preparation must be picked up before admission to the engine.
                    while true {
                        let s = store.setup, accounts = store.accounts
                        let picked = try await lookUp(nil) { try await self.pickLinks(s, accounts: accounts) }
                        let links = picked.links
                        try Task.checkCancellation()
                        guard g == generation else { throw CancellationError() }
                        guard s == store.setup, accounts == store.accounts else { continue }
                        let input = makeInput(s, links, blocked: Set(picked.blocked.keys), probe: newProbe())
                        let compiled = await Self.compile(input)
                        try Task.checkCancellation()
                        guard g == generation else { throw CancellationError() }
                        guard current(input, accounts) else { continue }
                        let json = try compiled.get()
                        applying = true
                        try await apply(input, json, g)
                        // Overtaken while applying: the newer operation (a Disconnect stops what just started, a newer
                        // Connect applies again) owns the outcome, so nothing is recorded or shown from here.
                        guard g == generation else { throw CancellationError() }
                        commit(input, json, accounts)
                        retry.clear(); pauseRetry.clear(); stopAdopting()
                        pausedInput = nil; pausedProfile = nil
                        store.pause = nil
                        state = VpnState(phase: .on, since: .now, servers: links.mapValues(\.server), blocked: picked.blocked.mapValues(\.text))
                        scheduleRoutes(picked.blocked, revision: revision())
                        startWatching()
                        break
                    }
                } catch {
                    // Overtaken by a disconnect or a newer connect: that one owns the state now; no error, no teardown.
                    // A pause it interrupted is put back, so the newer one still sees (and can restore) it. Any error
                    // counts: Disconnect stops the tunnel at once, so an apply under way fails with its own message.
                    if g != generation {
                        if paused.phase == .paused && state.phase == .connecting { state = paused }
                        return
                    }
                    let failure = message(error, "Could not connect")
                    // Another user's tunnel runs: nothing here changed, and it isn't this app's to stop. Their fallback is
                    // no VPN: said as it is.
                    if (error as? TunnelControl.Unstaged)?.foreign == true {
                        let fallback = await tunnel.revisions(timeout: 5)?.foreignFallback == true
                        guard g == generation else { return }
                        recordRun { $0.foreign() }
                        let shown = fallback ? Self.othersFallbackRuns : failure
                        // A pause stays what it is (its record stays too): Off here would leave a record nothing clears.
                        if paused.phase == .paused { state = paused; state.error = shown; startWatching() } else { state = VpnState(error: shown) }
                        return
                    }
                    if paused.phase == .paused {
                        do {
                            // Restore both forms of pause, even if the failed start already closed the old engine. One that
                            // failed before reaching the engine (a provider, the compiler) left a standing pause as it ran.
                            if applying || !standing {
                                try await Task {
                                    if let input = self.pausedInput {
                                        let json = try await Self.compile(input, validate: false).get()
                                        try await self.apply(input, json, g, persist: false, profile: self.pausedProfile, search: self.pausedSearch)
                                        self.recordRun { $0.pausedBlocking() }
                                        (self.pausedJSON, self.pausedRevision) = (json, self.tunnel.applied)
                                    } else {
                                        // Its own stop, after a start that may have come up.
                                        self.outside.restartOver()
                                        try await self.tunnel.stop(userInitiated: true)
                                        self.recordRun { $0.stopped() }
                                    }
                                }.value
                            }
                            guard g == generation else { return }
                            state = paused
                            state.error = failure
                            startWatching()
                        } catch {
                            // Overtaken meanwhile (Disconnect, an erase request): that one owns the state, and the tunnel.
                            guard g == generation else { return }
                            await teardown(error: "Could not restore pause: \(message(error, failure))", g)
                        }
                    } else { await teardown(error: failure, g) }
                }
            }
            // Already On: this Connect cancelled any change being applied, so look again, apart from this call (a reload
            // can take a while, and this call's own settle must not wait for it).
            if reconcileOn, g == generation, state.phase == .on {
                Task { [weak self] in
                    guard let self, g == self.generation, self.state.phase == .on else { return }
                    await self.reconcile()
                }
            }
        } catch is CancellationError {} catch { state.error = message(error, "Could not connect") }
    }

    /// [still]: as for `eraseExtension`; the VPN stops only if it holds once the queue is ours.
    func disconnect(while still: (() -> Bool)? = nil) async {
        // A failure is shown by `stopAndClear` itself, for as long as nothing newer owns the outcome.
        try? await stopAndClear(while: still)
    }

    enum EraseOutcome { case erased, deferred, failed }

    /// Stops the VPN (macOS alone does that) and erases what the extension keeps: its sealed copy of the setup and the
    /// Tailscale identity. The erase needs the extension: until it confirms, `store.extensionWipePending` stays set, every
    /// start erases first and a tunnel left running isn't taken over. `deferred`: there's no VPN configuration, so nothing
    /// is sent and none is created; nothing can start from the extension's copy until a start, which erases first.
    /// [still]: for a caller that already requested the erase (`requestErase`). Nothing is stopped before the queue is
    /// ours, and once it is, nothing is stopped or erased unless [still] holds: something set up and started meanwhile
    /// stays (the request stays pending, so the next start erases first unless that one already did). `deferred` then.
    func eraseExtension(while still: (() -> Bool)? = nil) async -> EraseOutcome {
        if still == nil {
            // Before the first await: a start under way either erases first or is cancelled by the new generation.
            requestErase()
            cancelResume()
            changes.stop()
            _ = try? await tunnel.stop(userInitiated: true)
        }
        do {
            return try await exclusive {
                if let still, !still() {
                    giveUpConnecting()
                    // Given way: what shows is what the last operation left.
                    settle(generation)
                    return .deferred
                }
                cancelResume()
                // Stop and erase in one turn of the queue: no connect gets in between. An operation admitted before this
                // turn may have erased and then written a config of its own: this turn erases again whatever happened.
                store.extensionWipePending = true
                eraseRequest += 1
                outside.operation()
                // Another user's tunnel (fast user switching) is theirs: neither stopped nor waited for. A stop that
                // failed (an on-demand save) still stopped, so it is waited for, and Connect on Demand is turned off again
                // until that is saved: what it would start is being erased.
                let stopped: Bool?
                do { stopped = try await tunnel.stop(userInitiated: true) } catch { stopped = nil; offLater() }
                if stopped != false { try? await tunnel.waitStopped() }
                clearRunning()
                recordRun { if stopped == false { $0.foreign() } else { $0.stopped() } }
                retry.clear(); pauseRetry.clear(); stopAdopting()
                pausedInput = nil; pausedProfile = nil
                store.pause = nil
                state = VpnState()
                return try await erasePendingNoted()
            }
        } catch { return .failed }
    }

    /// Records, before the caller's first wait, that the extension's copy must go: whatever happens next (a quit, a
    /// crash), the next start erases first, and an erase already under way doesn't count for this request.
    /// A connect under way gives way (see `apply`): it must not start what it read before the request.
    func requestErase() {
        store.extensionWipePending = true
        eraseRequest += 1
        generation += 1
    }

    /// Inside `exclusive` only, for a stop or erase that turned out not to be wanted: a connect its generation bump
    /// overtook left "connecting" behind, and nothing else will (no operation runs while the queue is ours). The real
    /// status is read again once the queue is free.
    private func giveUpConnecting() {
        guard state.phase == .connecting else { return }
        state = VpnState()
        Task { await statusChanged() }
    }

    static let interruptedSignOut = "unbraid stopped the VPN to finish erasing a signed-out setup. Connect again."
    private static let stopUnconfirmed = "The VPN hasn't confirmed that it stopped. Check System Settings, VPN."
    private static let fallbackRuns = "Connect on Demand couldn't be turned off, so macOS keeps the VPN running with nothing on it: "
        + "everything goes direct, outside any VPN. unbraid turns it off as soon as it can."
    /// Another user's fallback (`sealFallbackIfStuck`) runs: their engine, never stopped from here, and no VPN.
    private static let othersFallbackRuns = "unbraid's direct fallback is running for another user on this Mac: everything goes "
        + "direct, outside any VPN. unbraid can connect once it stops."
    private static let erasingSignedOut = "unbraid has to stop the VPN to finish erasing a signed-out setup, but its extension "
        + "hasn't answered yet. Trying again shortly."

    /// Sends the pending erase; a live Tailscale store must have stopped first, or it would write the old identity back.
    /// A confirmation clears only the request it answers, never a newer one: a request made meanwhile is erased again.
    private func erasePending() async throws -> EraseOutcome {
        for _ in 0..<3 {
            guard store.extensionWipePending else { return .erased }
            guard try await tunnel.hasProfile() else { return .deferred }
            let request = eraseRequest
            // Off before anything of this user's goes (the reset drops their sealed copy too): a quit or a crash after
            // that must not leave Connect on Demand on with nothing to start. One that couldn't be saved stays owed, also
            // across a relaunch.
            _ = await disarmBeforeDrop()
            // Another user's tunnel never stops for this app, and the extension's reset leaves it running anyway.
            if !(await tunnel.runsForAnotherUser()) { try await tunnel.waitStopped() }
            try await tunnel.resetTailscale()
            // While another user's engine runs, the reset removes only this user's Tailscale identity and leaves the sealed
            // copy, which may be this user's: dropped on its own (the extension checks whose it is). That answers every drop
            // a sign-out owed until now (a later one stays owed). Named as it is now: whatever of this user's is there goes.
            let owed = owedDrops, requests = owedRequests
            guard let named = await tunnel.sealing() else { return .failed }
            switch await tunnel.forgetSealed(named.seal ?? "none") {
            // Not one a sign-out made since the erase asked: its own drop decides.
            case .cleared, .foreign:
                for p in owed where owedRequests[p] == requests[p] { await settled(p) }
            case .superseded: return .failed
            case .suppressed, .failed:
                // As in `dropSeal`: Connect on Demand left on mustn't wait for the retry with nothing to start.
                await sealFallbackIfStuck()
                return .failed
            }
            // Connect on Demand couldn't be turned off before the copy went: what it starts from now keeps the Mac online.
            await sealFallbackIfStuck()
            // Whatever the record said was sealed is gone (or another user's): unknown from now on.
            Running.sealed(nil)
            pauseSealed = nil
            if request == eraseRequest { store.extensionWipePending = false; return .erased }
        }
        return .failed
    }

    /// `erasePending`, a failure recorded for Copy Diagnostics (a sign-out's, or one finished later on its own).
    private func erasePendingNoted() async throws -> EraseOutcome {
        do {
            let outcome = try await erasePending()
            if outcome == .failed { Diagnostics.noteFailure("Could not erase the extension's copy", facts: "not confirmed") }
            return outcome
        } catch {
            if !(error is CancellationError) { Diagnostics.noteFailure("Could not erase the extension's copy", error) }
            throw error
        }
    }

    /// User stops serialize with engine changes.
    private func stopAndClear(while still: (() -> Bool)? = nil) async throws {
        testingOwner.clear(); testingBase = nil; testingAccounts = nil
        generation += 1
        let g = generation
        // Connect on Demand turned back on in Settings while this runs supersedes this Off (`offCleared`).
        let cleared = offCleared
        defer { Task { await self.removeTestingIfNeeded(g) } }
        cancelResume()
        defer { if g == generation, store.pause != nil { armResume(retry: true) } }
        // Whatever it leaves (also nothing, when it gives way), its own stop is behind it.
        defer { settle(g) }
        // Stop at once, not after whatever holds the queue (a connect waiting on a provider can take a minute); the stop
        // inside the queue then also covers a tunnel that operation started meanwhile. Another user's tunnel (fast user
        // switching) is theirs: this app neither stops it nor waits for it to stop (asked again once queued).
        if still == nil {
            // Not once a Connect made right after this took over: it would stop the tunnel that Connect brings up.
            do { try await tunnel.stop(userInitiated: true, while: { g == self.generation }) }
            catch is TunnelControl.Overtaken {
                // Connect on Demand went off for this stop: the newer operation may leave what runs as it is (a Connect
                // while connected), so it comes back as it was armed.
                _ = try? await exclusive { if state.phase == .on { await rearmOnDemand() } }
            } catch {}
        }
        try await exclusive {
            // A Connect made after this Disconnect, queued first while this one was stopping, is the newer wish.
            guard g == generation else { return }
            if let still, !still() { giveUpConnecting(); return }
            // What a Disconnect leaves: nothing running, nothing to retry or resume.
            @MainActor func off(forget: Bool = true) {
                clearRunning(forget: forget)
                recordRun { $0.stopped() }
                if !forget { Running.stopped(true) }
                retry.clear(); pauseRetry.clear(); stopAdopting()
                pausedInput = nil; pausedProfile = nil
                store.pause = nil
                state = VpnState()
            }
            let stopped: Bool
            do { stopped = try await tunnel.stop(userInitiated: true) } catch {
                // Recorded even if a newer operation arrived meanwhile, as for a confirmed stop: that one starts from this state.
                // Connect on Demand couldn't be turned off (the stop is still asked for): turned off again until saved, unless a
                // newer operation or the Settings toggle owns it by now.
                if g == generation, cleared == offCleared { offLater() }
                let failure = message(error, "Could not stop the VPN")
                // Off as with any Disconnect, once the stop is through, with the reason: a pause ends (nothing reconciling it
                // starts its blocking engine again, and none stays behind with nothing to resume it), and the stop isn't
                // then taken for one from outside ("turned off by macOS"). The record stays, marked stopped: Connect on
                // Demand may start the tunnel again, and a takeover then knows which accounts it runs.
                try? await tunnel.waitStopped()
                off(forget: false)
                state.error = failure
                // The tunnel's real status is read again once the queue is free, so one still up is taken over.
                Task { await statusChanged() }
                return
            }
            // "Off" only once macOS says so: a status update in between would otherwise see a live tunnel while the
            // state says off, adopt it, and a setup change right after would start it again.
            if stopped {
                do { try await tunnel.waitStopped() } catch is CancellationError {} catch {
                    // Never confirmed: no clean Off. Nothing is restarted; the record stays, as after a failed stop, and the
                    // real status is read again once the queue is free. Recorded even if a newer operation arrived meanwhile, as
                    // for a confirmed stop: that one starts from this state.
                    // The user's Off, still: the tunnel that may be up when the status is read again must not bring Connect on
                    // Demand back (only a newer operation of theirs, which owns it, may).
                    if g == generation, cleared == offCleared { offLater() }
                    off(forget: false)
                    state.error = Self.stopUnconfirmed
                    Task { await statusChanged() }
                    return
                }
            }
            off()
            if !stopped { recordRun { $0.foreign() } }
            // Connect on Demand is off: a fallback left from before goes.
            if stopped { await retireFallback() }
        }
    }

    /// Traffic leaves without the VPN until resumed, by hand (minutes = 0) or after `minutes`. Blocked apps stay blocked:
    /// with any, the engine keeps running with every other app direct; without, the tunnel stops.
    func pause(minutes: Int) async {
        guard state.phase == .on else { return }
        testingOwner.clear(); testingBase = nil; testingAccounts = nil
        generation += 1
        let g = generation
        defer { Task { await self.removeTestingIfNeeded(g) } }
        cancelResume()
        defer { settle(g) }
        do {
            try await exclusive {
                // A reload this pause overtook may have left the phase at connecting: what counts is that a full
                // configuration runs.
                guard g == generation, committed != nil, state.phase == .on || state.phase == .connecting else { return }
                var input = makePausedInput()
                let old = lastInput, accounts = committed?.accounts, blocking = committed?.blocking == true, interim = committed?.interim == true
                let since = Date.now, until = minutes > 0 ? Date.now.addingTimeInterval(Double(minutes) * 60) : nil
                // Record intent before changing traffic, so a crash during the transition still has a deadline.
                store.pause = (until, since, until.map { _ in Self.uptime() + Double(minutes) * 60 }, Self.bootID())
                // The sealed copy is the full configuration again (connect sealed it): nothing sealed for a pause yet.
                pauseSealed = nil; sealRetry.clear(); sealWarning = nil
                Running.pauseBaseline(old?.setup)
                var stopFailure: String?
                do {
                    while true {
                        if !input.setup.apps.isEmpty { state.phase = .connecting }
                        let compiled: Result<String, Error> = input.setup.apps.isEmpty ? .success("") : await Self.compile(input)
                        try Task.checkCancellation()
                        guard g == generation else { return }
                        let latest = makePausedInput()
                        if input.setup != latest.setup || input.apps != latest.apps || input.remembered != latest.remembered { input = latest; continue }
                        if !input.setup.apps.isEmpty {
                            let json = try compiled.get(), searched = search(input)
                            try await apply(input, json, g, persist: false, search: searched)
                            pausedInput = input; pausedSearch = searched; pausedProfile = tunnel.profile
                            (pausedJSON, pausedRevision) = (json, tunnel.applied)
                        } else {
                            do { try await tunnel.stop(userInitiated: true) }
                            catch is CancellationError { throw CancellationError() }
                            catch is TunnelControl.Overtaken { throw TunnelControl.Overtaken() }
                            catch {
                                guard g == generation else { return }
                                // A failed save still stops the tunnel: then the pause stands, with the reason. One that
                                // never stopped (the profile couldn't be read) is a failed pause, as before.
                                let original = error
                                do { try await tunnel.waitStopped() } catch { throw original }
                                guard g == generation else { return }
                                offLater()
                                stopFailure = message(error, "Could not stop the VPN")
                            }
                            pausedInput = nil; pausedProfile = nil
                        }
                        break
                    }
                } catch {
                    // Disconnected meanwhile: restoring the old engine would restart the tunnel just stopped.
                    guard g == generation else { return }
                    store.pause = nil
                    if revokes() { await teardown(error: Self.signedOut, revoke: true, g) }
                    else if !input.setup.apps.isEmpty {
                        // Blocking: the setup is tried again as after any failed change (this pause's own retry wake went
                        // with the generation it bumped).
                        if await recover(old, accounts, blocking: blocking, interim: interim, error: error, g) == .blocking, g == generation, state.phase == .on {
                            failed(revision(), error, disrupted: true, quiet: false)
                        }
                    }
                    else { state.error = message(error, "Could not pause") }
                    if state.phase == .on { armRouteRetry() }
                    return
                }
                // Recorded even when overtaken: a queued resume reads the paused state to put it back if it fails.
                clearRunning(forget: false)
                recordRun { if input.setup.apps.isEmpty { $0.stopped() } else { $0.pausedBlocking() } }
                state = VpnState(phase: .paused, pausedUntil: until, pausedAt: since)
                state.error = stopFailure
                if g == generation { startWatching(); armResume() }
            }
        } catch is CancellationError {} catch { state.error = message(error, "Could not pause") }
    }

    // MARK: Engine changes

    /// Only blocking changes while paused. Keep the original deadline and protected on-demand configuration.
    /// [launch]: from `restorePause`; see the guard below.
    private func reconcilePause(launch: Bool = false) async {
        let g = generation
        do {
            try await exclusive {
                // A pending erase in-session means a sign-out or server change is tearing down: its own disconnect or erase
                // follows. At launch it is one a quit interrupted, and rebuilding the pause (no accounts) erases first.
                // A stop nobody here asked for ends the pause (`statusChanged`): its blocking engine is never started again.
                // Older work gave up with the generation it started; this guards what began after it.
                guard g == generation, state.phase == .paused, launch || !store.extensionWipePending, !outside.pending else { return }
                // Stand-ins for a setup the keychain wouldn't open yet would drop the blocked apps: the pause stays as it is,
                // and is looked at again every 30 s until the keychain opens (nothing else changes while it is held).
                store.reloadHeld()
                guard !store.isHeld else { return wakeWhenHeld(g) { await self.reconcilePause(launch: launch) } }
                cancelHeldWake()
                let input = makePausedInput(), key = PauseKey(input, search: search(input))
                let previous = state
                var step = Lifecycle.pauseStep(wanted: key, running: pausedInput.map { PauseKey($0, search: pausedSearch) }, connected: tunnel.status == .connected,
                                               retry: pauseRetry, now: .now)
                // Converged on what the pause applied, as far as the app saw: the extension says whether that still runs.
                // Applied again when it doesn't, keeping pausedInput, so what an unattended start runs is sealed first.
                var stale = false
                if case .converged = step {
                    // No answer a moment ago: asked again then, not at every change meanwhile (each would wait 5 s). The
                    // probe keeps that time, also for a pause made again since (an older one's probe is gone with it).
                    if let wait = Lifecycle.pauseAskWait(until: pauseAskAt, now: .now) { return probePause(g, after: wait) }
                    let runs = await tunnel.revisions(timeout: 5)
                    try Task.checkCancellation()
                    guard g == generation, state.phase == .paused, launch || !store.extensionWipePending else { return }
                    store.reloadHeld()
                    guard !store.isHeld else { return wakeWhenHeld(g) { await self.reconcilePause(launch: launch) } }
                    // Changed meanwhile: the reconciliation that change started decides.
                    guard pauseKey() == key, tunnel.status == .connected else { return }
                    pauseAskAt = runs == nil ? .now + Self.probe : nil
                    switch Lifecycle.pauseCheck(applied: pausedRevision, engine: runs.map { Lifecycle.Engine(running: $0.running, durable: $0.durable, foreign: $0.foreign) }) {
                    case .runs: probePause(g)
                    // Kept as it is, and nothing cleared: a failure or a retry from earlier still stands. Not sealed either:
                    // the extension seals only for this user's engine while it runs.
                    case .ask: return probePause(g)
                    case .leave:
                        recordRun { $0.foreign() }
                        return probePause(g)
                    case .reapply:
                        stale = true
                        step = Lifecycle.pauseStep(wanted: key, running: nil, connected: true, retry: pauseRetry, now: .now)
                    }
                }
                var stopFailure: String?
                do {
                    switch step {
                    case .converged(let clear), .idle(let clear):
                        // Back to what runs (or applied by a retry): an earlier failure no longer applies.
                        if clear { pauseRetry.clear() }
                        if clear, state.error != sealWarning { state.error = sealWarning }
                        if case .converged = step { await sealPause(g, arm: true) }
                        return
                    case .wait:
                        // Looked at again in a while: the retry's own wake may belong to an operation since overtaken (a
                        // Resume that failed and put the pause back).
                        probePause(g)
                        await sealPause(g, arm: true)
                        return
                    case .apply:
                        let compiled = await Self.compile(input, validate: false)
                        try Task.checkCancellation()
                        guard g == generation, state.phase == .paused, pauseKey() == key else { return }
                        let json: String
                        // Not checked, or not staged: nothing touched the engine, and the pause keeps blocking what it
                        // blocked. Only a failure that may have changed the engine stops it.
                        do { json = try compiled.get() } catch { return holdPause(key, error) }
                        // Most changes of the apps' patterns (another app's copy found) change nothing the pause runs:
                        // no check, and no reload restarting the blocking engine's connections, once the extension
                        // says that is still what runs (not a copy started since, by Connect on Demand). What an
                        // unattended start runs may still change (it holds every app's patterns): sealed as when converged.
                        if !stale, json == pausedJSON, key.search == pausedSearch, let revision = pausedRevision, tunnel.status == .connected,
                           tunnel.profile?.routing == profile(input).routing {
                            let runs = await tunnel.revisions(timeout: 5)
                            try Task.checkCancellation()
                            guard g == generation, state.phase == .paused, pauseKey() == key else { return }
                            if Lifecycle.pauseRuns(json, applied: (json, revision), running: runs.map { ($0.running, $0.durable, $0.foreign) }), tunnel.status == .connected {
                                pausedInput = input; pausedSearch = key.search; (pausedJSON, pausedRevision) = (json, revision)
                                pauseRetry.clear()
                                await sealPause(g, arm: true)
                                break
                            }
                        }
                        let rejected: Error?
                        do { try await Self.check(json); rejected = nil } catch { rejected = error }
                        try Task.checkCancellation()
                        guard g == generation, state.phase == .paused, pauseKey() == key else { return }
                        if let rejected { return holdPause(key, rejected) }
                        // What an unattended start runs gets the new blocked apps first, then the pause: the extension seals
                        // only for an engine of this user's that runs, so a pause that had none starts it first.
                        let running = pausedInput != nil && tunnel.status == .connected
                        if running {
                            await sealPause(g, arm: true)
                            // Blocked apps changed while sealing: the reconciliation that change started applies them.
                            guard g == generation, state.phase == .paused, pauseKey() == key else { return }
                        }
                        do { try await apply(input, json, g, persist: false, search: key.search) } catch let u as TunnelControl.Unstaged {
                            guard g == generation, pauseKey() == key else { return }
                            return holdPause(key, u)
                        }
                        recordRun { $0.pausedBlocking() }
                        pausedInput = input; pausedSearch = key.search; pausedProfile = tunnel.profile
                        (pausedJSON, pausedRevision) = (json, tunnel.applied)
                        pauseAskAt = nil
                        if !stale { pauseRetry.clear() }
                        else if g == generation, pauseKey() == key, let wait = pauseRetry.failed(key, disrupted: false, now: .now) {
                            // Applied again because something else ran: until the extension says the pause runs, doing
                            // that again waits longer each time, so an engine that keeps reporting another revision isn't
                            // reloaded at every change. The wake asks it.
                            wakeAfter(wait)
                        }
                        if !running { await sealPause(g, arm: true) }
                        if g == generation { probePause(g) }
                    case .stop:
                        // Sealed while the engine still runs; Connect on Demand stays off (the pause stops the tunnel).
                        await sealPause(g, arm: false)
                        // An app blocked again while sealing: the tunnel isn't stopped after all.
                        guard g == generation, state.phase == .paused, pauseKey() == key else { return }
                        state.phase = .connecting
                        do { try await tunnel.stop(userInitiated: true) }
                        catch is CancellationError { throw CancellationError() }
                        catch is TunnelControl.Overtaken { throw TunnelControl.Overtaken() }
                        catch {
                            guard g == generation else { return }
                            // As for a pause: only a stop that happened counts as one.
                            let original = error
                            do { try await tunnel.waitStopped() } catch { throw original }
                            guard g == generation else { return }
                            offLater()
                            stopFailure = message(error, "Could not stop the VPN")
                        }
                        pausedInput = nil; pausedProfile = nil
                        pauseRetry.clear()
                        recordRun { $0.stopped() }
                    }
                    // Recorded even when overtaken: a queued resume reads the paused state to put it back if it fails.
                    state = previous
                    state.error = stopFailure ?? sealWarning
                } catch is CancellationError {} catch {
                    // A failed reload can close the old engine. Reported, and the pause ends with it (`teardown`).
                    guard g == generation else { return }
                    await teardown(error: message(error, "Could not update blocked apps"), g)
                }
            }
        } catch is CancellationError {} catch { state.error = message(error, "Could not update blocked apps") }
    }

    /// Asks again in a while what the paused engine runs (`reconcilePause`), unless a newer operation took over meanwhile.
    private func probePause(_ g: Int, after wait: Duration = Connection.probe) {
        pauseProbe?.cancel()
        pauseProbe = Task {
            do { try await Task.sleep(for: wait) } catch { return }
            guard !Task.isCancelled, g == generation, state.phase == .paused else { return }
            pauseProbe = nil
            await reconcilePause()
        }
    }

    /// Runs [f] again in 30 s, unless a newer operation took over meanwhile: for what waits for the keychain to open
    /// (only the app's own activation or a write would reload it otherwise). One at a time.
    private func wakeWhenHeld(_ g: Int, _ f: @escaping () async -> Void) {
        // One already set keeps its time: asking again while held doesn't put it off.
        guard heldWake == nil else { return }
        let id = UUID()
        heldWakeId = id
        heldWake = Task {
            try? await Task.sleep(for: .seconds(30))
            // A cancelled one never clears its replacement.
            guard heldWakeId == id else { return }
            heldWake = nil; heldWakeId = nil
            guard !Task.isCancelled, g == generation else { return }
            await f()
        }
    }

    private func cancelHeldWake() { heldWake?.cancel(); heldWake = nil; heldWakeId = nil }

    /// What was last sealed for an unattended start during this pause (`sealPause`); nil: not known (the pre-pause copy, or
    /// an attempt with no answer).
    nonisolated private struct SealKey: Equatable, Sendable {
        var setup: Setup
        var apps: [String: [String]]
        var search: String
    }
    private var pauseSealed: SealKey?
    /// Seal attempts that may pass are tried again by this wake (not by a change's retry, which may replace its own).
    private var sealWake: Task<Void, Never>?
    private var sealRetry = Retry<SealKey>()
    /// Why the blocked apps aren't in what an unattended start runs; shown with the pause until a seal succeeds.
    private var sealWarning: String?

    /// Seals what an unattended start should run while paused (`Lifecycle.protected`), so apps blocked meanwhile stay
    /// blocked if macOS restarts the tunnel before unbraid runs. Built from the record of what ran before the pause, never
    /// from anything a provider would have to be asked for, and only while every account it holds is still the one signed
    /// in (checked last, right before sealing). Only while this user's engine runs: the extension seals for its owner only.
    /// [arm]: Connect on Demand comes back on once sealed (not when the pause is about to stop the tunnel). A failure never
    /// holds up the pause itself: it is shown, and retried when it may pass. Inside `exclusive` only.
    private func sealPause(_ g: Int, arm: Bool) async {
        let request = eraseRequest
        func still() -> Bool {
            g == generation && request == eraseRequest && store.pause != nil && !store.extensionWipePending && !store.isHeld
                && tunnel.status == .connected
        }
        func notSealed(_ why: String, retry key: SealKey? = nil, after: Duration? = nil) {
            if let wait = key.flatMap({ sealRetry.failed($0, disrupted: false, now: .now) }) ?? after {
                sealWake?.cancel()
                sealWake = Task {
                    do { try await Task.sleep(for: wait) } catch { return }
                    guard g == generation else { return }
                    await reconcile()
                }
            }
            Log.info("pause: blocked apps not sealed", detail: why)
            warnSeal("Blocked apps aren't saved for when macOS restarts the VPN on its own: \(why)")
        }
        guard still() else { return }
        let read = await Running.read(), tainted = await Running.tainted(), baseline = await Running.pauseBaseline()
        guard still() else { return }
        var record: Running.State?, locked = false
        switch read {
        case .locked: locked = true
        case .none: break
        case .record(let r): record = r
        }
        func protected() -> (key: SealKey, input: Compiler.Input)? {
            guard let record else { return nil }
            let blocked = Set(record.setup.activeRoutes.filter { !$0.imported && record.links[$0.id] == nil && store.accounts[$0.loc.provider] == nil }.map(\.id))
            guard let setup = Lifecycle.protected(record: record.setup, linked: Set(record.links.keys), store: store.setup, blockedRoutes: blocked) else { return nil }
            let ids = Set(setup.activeRoutes.map(\.id))
            let input = Compiler.Input(setup: setup, links: record.links.filter { ids.contains($0.key) }, blocked: blocked.intersection(ids), apps: AppCatalog.shared.patterns(for: AppCatalog.shared.routingKeys(setup)),
                                       selfPattern: Compiler.pattern(forPath: Bundle.main.executablePath ?? Bundle.main.bundlePath),
                                       tsSuffix: setup.tailscale ? Compiler.trustedStoredSuffix(setup.home) : nil, probe: nil, ownerless: .refusedWhileSplit)
            return (SealKey(setup: setup, apps: input.apps, search: Compiler.searchDomain(input)), input)
        }
        // What holds now (`Lifecycle.sealAdmission`): the record read above, the setup and the accounts as they are.
        func admitted(_ p: (key: SealKey, input: Compiler.Input)?) -> Bool {
            switch Lifecycle.sealAdmission(locked: locked, record: record != nil, tainted: tainted, baseline: baseline,
                                           digest: record.map { Running.digest($0.setup) }, built: p != nil, sealed: p?.key == pauseSealed,
                                           due: p.map { sealRetry.allows($0.key, now: .now) } ?? true, provenance: provenance(record)) {
            case .seal: return true
            case .skip: return false
            case .locked: notSealed("unbraid can't read its keychain right now.", after: .seconds(30))
            case .unusable: notSealed("unbraid has no usable record of the connection the pause replaced. Resume, then pause again.")
            case .noServer: notSealed("a route the pause replaced has no server on record.")
            case .accountChanged: notSealed("an account it used was signed out or changed. Resume to connect with this one.")
            }
            return false
        }
        let first = protected()
        guard admitted(first), let (key, input) = first else { return }
        let json: String
        do { json = try Compiler.compile(input) } catch {
            sealRetry.refuse(key)
            return notSealed(message(error, "unbraid couldn't build it."))
        }
        guard await Running.unsealed() else { return notSealed("unbraid couldn't save the connection state.", retry: key) }
        // Checked again right before sealing, against the setup and the accounts as they are now: never sealed for an
        // account signed out or replaced since the pause began (a sign-out drops the sealed copy and must not find a new
        // one with it), nor with blocked apps changed meanwhile (the change that came reconciles again).
        guard still(), let now = protected(), now.key == key, admitted(now) else { return }
        do {
            _ = try await tunnel.seal(json, search: key.search)
            // Recorded before anything else suspends: a sign-out's drop queued behind this reads it.
            sealed(key.setup, linked: Set(input.links.keys))
            pauseSealed = key
            sealRetry.clear()
            warnSeal(nil)
            if arm, still() { await armOnDemand(store.setup.prefs.alwaysOn, durable: true, g) }
        } catch {
            let u = error as? TunnelControl.Unsealed
            pauseSealed = nil
            // Withdrawn: nothing is left for Connect on Demand to start, so it goes off also when this pause was overtaken
            // meanwhile (a stop it didn't ask for ends it, and a stop never turns it off). Refused otherwise: the copy from
            // before stays.
            if u?.withdrawn == true {
                if still() { await armOnDemand(store.setup.prefs.alwaysOn, durable: false, g) } else { await disarmOnDemand() }
            }
            if u?.foreign == true { return notSealed(Ownership.otherUser) }
            notSealed(u?.unanswered == true ? "the tunnel didn't answer (it may have been). Trying again."
                      : "\(message(error, "the tunnel couldn't save them")) Trying again.", retry: key)
        }
    }

    /// The line shown while the blocked apps aren't sealed; it goes once they are, unless something else replaced it.
    private func warnSeal(_ text: String?) {
        if state.error == nil || state.error == sealWarning { state.error = text }
        sealWarning = text
    }

    /// A Block change the engine didn't take during a pause: retried when due, or once the blocked apps change again.
    private func holdPause(_ key: PauseKey, _ error: Error) {
        if error is Refused { pauseRetry.refuse(key) }
        else if let wait = pauseRetry.failed(key, disrupted: false, now: .now) { wakeAfter(wait) }
        state.error = "Blocked-app changes not applied: \(message(error, "the engine didn't take them"))"
    }

    /// Applies the store's setup without dropping the tunnel unless its NetworkExtension profile also changed.
    /// Adds routes only to the running configuration, owned by the test that asked for them.
    func beginTesting(_ routes: Set<String>) async -> UUID? {
        guard state.phase == .on, testingOwner.token == nil, appliedRevision == revision(), !routes.isEmpty else { return nil }
        testingBase = store.setup
        testingAccounts = store.accounts
        let token = testingOwner.begin(routes)
        let work = Task { await self.reload() }
        return await withTaskCancellationHandler {
            await work.value
            guard !Task.isCancelled, testingOwner.token == token, state.phase == .on, running?.testing == routes else {
                endTesting(token)
                return nil
            }
            return token
        } onCancel: {
            Task { @MainActor in self.endTesting(token) }
        }
    }

    @discardableResult
    func endTesting(_ token: UUID) -> Task<Void, Never>? {
        guard testingOwner.end(token) else { return testingCleanup }
        testingBase = nil; testingAccounts = nil
        lookup?.task.cancel()
        let g = generation
        let work = Task {
            await self.reload()
            await self.removeTestingIfNeeded(g)
        }
        testingCleanup = work
        return work
    }

    func endTesting() { if let token = testingOwner.token { endTesting(token) } }
    func waitForTestingCleanup() async { await testingCleanup?.value }

    private func removeTestingIfNeeded(_ g: Int) async {
        try? await exclusive {
            guard g == generation, state.phase == .on, testingOwner.token == nil, !reloadFlight.contains(revision()),
                  let old = committed, !old.input.setup.testing.isEmpty else { return }
            let shown = state.error
            testingFailures += 1
            Log.error("speed test", detail: "Could not remove test routes")
            let error = Fail("Could not remove test routes")
            let recovered = await recover(old.input, old.accounts, blocking: old.blocking, interim: old.interim, error: error, g)
            guard g == generation, state.phase == .on else { return }
            // Everything blocked is never quiet: said, and the setup tried again.
            if recovered == .blocking { failed(revision(), error, disrupted: true, quiet: false) } else { state.error = shown }
        }
    }

    /// Health failover passes the routes to move ([dead]: route id → the server found dead) and [avoid]; while the edited
    /// setup may not be tried (refused, or not yet due again), those routes move within the running setup instead, and
    /// the edit stays pending.
    private func reload(dead: [String: String] = [:], avoid: Set<String> = [], checked: Int? = nil, retrying: Set<String> = [], healthAction: Bool = false, revokedAction: Bool = false, waitForProviders: Bool = true) async {
        let g = generation
        var flight: UUID?
        var handedOff = false
        defer { if !handedOff, let flight { finishReload(flight, g) } }
        do {
            let lookupWork: (@MainActor () async -> Void)? = try await exclusive {
                // [checked]: the configuration the failed checks ran under; another one since may well answer.
                // An erase pending with the VPN on: a sign-out or server change is tearing down, and its own disconnect or
                // erase follows. Applying the old setup now would restart it, and use up that erase.
                guard g == generation, state.phase == .on, let old = committed, checked.map({ $0 == commits }) ?? true,
                      !store.extensionWipePending, !outside.pending else { return nil }
                let wanted = revision()
                if !waitForProviders && reloadFlight.contains(wanted) { return nil }
                let testChange = Lifecycle.testTransition(from: old.input.setup, to: wanted.setup, sameAccounts: old.accounts == store.accounts)
                let health = !dead.isEmpty || healthAction
                let pending = wanted != old.revision || old.interim
                let due = Lifecycle.retryEdit(interim: old.interim, health: health, allowed: retry.allows(wanted, now: .now))
                guard Lifecycle.mayRetryCommitted(interim: old.interim, allowed: due) else { return nil }
                if !retrying.isEmpty && pending && !due && old.accounts != store.accounts { return nil }
                // Only routes still on the server found dead: an earlier move may have replaced it already.
                let moving = dead.filter { id, key in old.input.setup.route(id).flatMap { r in old.input.links[id].map { LinkPicker.serverKey(r, $0) } } == key }
                if health { guard !moving.isEmpty || healthAction else { return nil } } else { guard (pending && due) || !retrying.isEmpty else { return nil } }
                reloadRequest += 1
                let request = reloadRequest
                let fallback = (health || !retrying.isEmpty) && pending && !due
                let token = reloadFlight.begin(wanted, fallback: fallback ? old.revision : nil)
                flight = token
                // A health move the user didn't ask for, or a route retry within the running setup: its failure is logged,
                // never shown as a change not applied, and never counted against an edit (none is pending, or the pending
                // one isn't due, so wasn't tried).
                let quiet = (health && (!pending || !due)) || fallback
                let s = fallback ? old.input.setup : wanted.setup, accounts = store.accounts
                // Inputs read after a suspension must still be the ones this attempt was built from.
                @MainActor func fits(_ input: Compiler.Input) -> Bool {
                    guard g == generation, request == reloadRequest, state.phase == .on, revision() == wanted, accounts == store.accounts,
                          !store.extensionWipePending else { return false }
                    return fallback ? input.apps == AppCatalog.shared.patterns(for: AppCatalog.shared.routingKeys(s)) && input.remembered == AppCatalog.shared.remembered(Array(s.apps.keys))
                                    : Revision(input, accounts) == wanted
                }
                let signOut = Lifecycle.signOutChange(running: running, linked: Set(old.input.links.keys), applied: committed?.accounts, accounts: accounts)
                if signOut == .teardown { await teardown(error: Self.signedOut, revoke: true, g); return nil }
                let signOutRequests = owedRequests
                let keep = old.input.links.filter { moving[$0.key] == nil }
                let deferred = !retrying.isEmpty && (!pending || fallback) ? blockedReasons.filter { !retrying.contains($0.key) } : [:]
                let applied = self.applied, appliedAccounts = self.appliedAccounts
                let last = await store.lastLinks(), avoided = avoid.union(failing), ports = portStep
                let refused = refusedAccounts.filter { accounts[$0.key] == $0.value.account }.mapValues(\.reason)
                removedPins.update(store.setup, accounts: store.accounts)
                let gone = removedPins
                var installed = false
                var recovery = old
                var sealedInterim = false
                @MainActor func install(_ result: Result<LinkPicker.Result, Error>, interim: Bool) async {
                    installed = false
                    do {
                        let picked = try result.get()
                        let links = picked.links
                        try Task.checkCancellation()
                        var input = makeInput(s, links, blocked: Set(picked.blocked.keys), probe: probe)
                        guard fits(input) else { return }
                        let compiled = await Self.compile(input, validate: false)
                        try Task.checkCancellation()
                        guard fits(input) else { return }
                        var json = try compiled.get()
                        // A favourite, a rename or another sign-in changes the setup, not what the engine runs.
                        if Lifecycle.needsApply(signOut: signOut, sealedInterim: sealedInterim, changed: json != lastGood || tunnel.profile != profile(input)) {
                            input.probe = newProbe()
                            let checked = await Self.compile(input)
                            try Task.checkCancellation()
                            guard fits(input) else { return }
                            json = try checked.get()
                            let persist = input.setup.testing.isEmpty
                            do { try await apply(input, json, g, persist: persist, requireDurable: Lifecycle.requiresDurable(signOut) || (revokedAction)) } catch {
                                // Refused before anything changed: the engine still runs the committed config.
                                if error is TunnelControl.Unstaged || error is CancellationError { throw error }
                                if revokedAction { return await teardown(error: message(error, "Sign in again"), revoke: true, g) }
                                guard g == generation else { return }
                                if TunnelControl.foreign(error) { throw error }
                                if Lifecycle.revokeAfterApplyFailure(signOut, revokes: revokes()) { return await teardown(error: Self.signedOut, revoke: true, g) }
                                if !retrying.isEmpty {
                                    routeRetry.failed(attempted: retrying, now: .now)
                                    state.retryAt = routeRetry.dates
                                }
                                let shown = state.error
                                let recovered = await recover(recovery.input, recovery.accounts, blocking: recovery.blocking, interim: recovery.interim, error: error, g)
                                guard g == generation, state.phase == .on else { return }
                                // Everything blocked is never quiet: whoever asked, it is said.
                                if !testChange && !fallback && (recovered == .restored || recovered == .blocking) { recordRun { $0.refused(revision: RunState.revision(wanted.setup), setup: wanted.setup) } }
                                // A test's own failure stays the test's, unless it left everything blocked: that is said, and the
                                // setup itself (without the test's routes) is tried again.
                                if testChange && recovered != .blocking { state.error = shown; return failed(wanted, error, disrupted: true, quiet: true, testChange: true) }
                                if recovered == .blocking { return failed(testChange ? revision() : wanted, error, disrupted: true, quiet: false, charged: !fallback) }
                                // A failed failover leaves the reason already on screen (a pending edit's, or none).
                                if quiet { state.error = shown }
                                return failed(wanted, error, disrupted: true, quiet: quiet, charged: !fallback)
                            }
                            if signOut == .replace && persist {
                                if interim { sealedInterim = true }
                                // The applied, sealed configuration has no links for the signed-out providers.
                                for p in Array(owedDrops) {
                                    if Lifecycle.signOutSettled(provider: p, requested: signOutRequests[p], current: owedRequests[p],
                                                                accounts: store.accounts, setup: input.setup, links: Set(input.links.keys), fits: fits(input), persisted: persist) {
                                        await settled(p)
                                    }
                                }
                                if fits(input) { await armOnDemand(input.setup.prefs.alwaysOn, durable: true, g) }
                            }
                        }
                        // What runs is recorded even when overtaken: the operation that overtook this one reads it.
                        commit(input, json, accounts, interim: interim)
                        guard g == generation else { return }
                        state.phase = .on
                        state.servers = links.mapValues(\.server)
                        state.blocked = picked.blocked.mapValues(\.text)
                        scheduleRoutes(picked.blocked, revision: fallback ? old.revision : wanted, attempted: retrying)
                        if !interim && !fallback && !testChange { retry.clear(); state.error = nil }
                        watchTailscale()
                        installed = true
                    } catch is CancellationError {} catch {
                        // Nothing changed in the engine (preparing, checking or staging failed). A failure that belongs to
                        // inputs changed meanwhile is the next attempt's business.
                        guard g == generation, state.phase == .on, revision() == wanted else { return }
                        // A route lost its account: never keep running a config holding those credentials, and never let
                        // on-demand bring it back from the extension's sealed copy.
                        if revokedAction { return await teardown(error: message(error, "Sign in again"), revoke: true, g) }
                        if revokes(), TunnelControl.foreign(error) { return await teardown(error: Ownership.otherUser, stop: false, g) }
                        if revokes() { return await teardown(error: error is AuthError ? message(error, "Sign in again") : Self.signedOut, revoke: true, g) }
                        if !retrying.isEmpty, !pending || fallback, let blocked = error as? BlockedPick {
                            let stillBlocked = blocked.blocked.filter { state.blocked[$0.key] != nil }
                            state.blocked = stillBlocked.mapValues(\.text)
                            scheduleRoutes(stillBlocked, revision: fallback ? old.revision : wanted, attempted: retrying)
                        }
                        // Still blocking: which apps go Direct is the setup's as it is now, even when the rest can't apply.
                        // Not while another user's engine runs: nothing of this user's to block.
                        var reblocked: Recovered?
                        let shown = state.error
                        if !TunnelControl.foreign(error) {
                            reblocked = await reblock(recovery, error, g)
                            guard reblocked != .off, g == generation, state.phase == .on, revision() == wanted else { return }
                        }
                        if testChange { state.error = shown }
                        if !retrying.isEmpty && !(error is BlockedPick) {
                            routeRetry.failed(attempted: retrying, now: .now)
                            state.retryAt = routeRetry.dates
                            armRouteRetry()
                        }
                        failed(wanted, error, disrupted: reblocked != nil, quiet: quiet, testChange: testChange, charged: !fallback)
                    }
                }
                // Install the new app rules from local links before asking any provider. Missing routes reject traffic.
                if LinkPicker.needsInterim(from: old.input.setup, to: s, revoking: signOut == .replace || revokedAction) {
                    do {
                        let ready = try await LinkPicker.pick(s, keep: keep, applied: applied, appliedAccounts: appliedAccounts,
                            accounts: accounts, last: last, avoid: avoided, refused: refused, gone: gone, deferred: deferred, portStep: ports,
                            offline: true, providers: Providers.get)
                        await install(.success(ready), interim: true)
                    } catch { await install(.failure(error), interim: true) }
                    guard installed, let committed else { return nil }
                    // A failed final reload must restore this policy, never the earlier Direct rules.
                    recovery = committed
                }
                let prepared = makeInput(s, keep, probe: probe)
                guard fits(prepared) else { return nil }
                let expectedCommits = commits
                return {
                    defer { self.finishReload(token, g) }
                    guard fits(prepared), self.commits == expectedCommits, !Task.isCancelled else { return }
                    // Only immutable picker inputs cross the queue boundary. Even a provider that ignores cancellation
                    // cannot hold up a pause, sign-out or newer app rule, and its late answer cannot replace one.
                    let result: Result<LinkPicker.Result, Error>
                    do {
                        result = .success(try await self.lookUp(wanted) {
                            try await LinkPicker.pick(s, keep: keep, applied: applied, appliedAccounts: appliedAccounts,
                                accounts: accounts, last: last, avoid: avoided, refused: refused, gone: gone, deferred: deferred,
                                portStep: ports, providers: Providers.get)
                        })
                    } catch { result = .failure(error) }
                    do {
                        try await self.exclusive {
                            guard fits(prepared), self.commits == expectedCommits, !self.outside.pending else { return }
                            let accepted = result.flatMap { picked in
                                Result { try self.acceptPick(picked, setup: s, accounts: accounts, allowBlocked: revokedAction) }
                            }
                            await install(accepted, interim: false)
                        }
                    } catch is CancellationError {} catch { self.state.error = self.message(error, "Change not applied") }
                }
            }
            if lookupWork != nil { handedOff = true }
            if waitForProviders { await lookupWork?() }
            else if let lookupWork {
                reloadWork?.cancel()
                reloadWork = Task { await lookupWork() }
            }
        } catch is CancellationError {} catch { state.error = message(error, "Change not applied") }
    }

    private func finishReload(_ token: UUID, _ g: Int) {
        guard reloadFlight.owns(token) else { return }
        if reloadFlight.finish(token), state.phase == .on { armRouteRetry() }
        let wanted = revision()
        let testChange = committed.map { Lifecycle.testTransition(from: $0.input.setup, to: wanted.setup, sameAccounts: $0.accounts == store.accounts) } ?? false
        // A wake may have been spent during this lookup, or its cancelled result discarded with the edit still due.
        // Test-only failures have no edit backoff; their caller and cleanup below handle them without replaying.
        // Not while the extension's copy waits to be erased: every reload stops short of it, so it would only ask again.
        if g == generation, state.phase == .on, !store.extensionWipePending,
           reloadFlight.needsReconcile(wanted, applied: appliedRevision, allowed: retry.allows(wanted, now: .now), testChange: testChange) {
            Task {
                guard g == self.generation, self.state.phase == .on else { return }
                await self.reconcile()
            }
        }
        // A reload that ended a test gets the first chance to remove its routes before cleanup tries recovery.
        if testingOwner.token == nil, running?.testing.isEmpty == false {
            Task { await self.removeTestingIfNeeded(g) }
        }
    }

    /// An edit the engine didn't take: it keeps running what it ran (or was put back on). A refusal (or a sign-in the
    /// provider refused) waits for different inputs; anything else is tried again after a growing wait, and given up
    /// after interrupting the tunnel a few times. [quiet]: a failover nobody asked for, only logged; what is shown stays.
    /// [charged] false: [wanted] wasn't what ran (a move within the running setup): said when blocking, never counted.
    private func failed(_ wanted: Revision, _ error: Error, disrupted: Bool, quiet: Bool, testChange: Bool = false, charged: Bool = true) {
        // apply() closed the Tailscale status before failing: the engine that still runs needs it again.
        watchTailscale()
        // Still blocking after a change failed twice: said with every later failure until a change goes through.
        var text = message(error, "Change not applied") + (committed?.blocking == true ? " " + Self.blocking : "")
        if testChange { testingFailures += 1; return Log.error("speed test", detail: text) }
        guard !quiet || committed?.blocking == true else { return Log.error("health", detail: text) }
        guard charged else { state.error = text; return }
        if error is Refused || error is AuthError { retry.refuse(wanted); recordRun { $0.refused(revision: RunState.revision(wanted.setup), setup: wanted.setup) } }
        else if let wait = retry.failed(wanted, disrupted: disrupted, now: .now) { wakeAfter(wait) }
        else { recordRun { $0.refused(revision: RunState.revision(wanted.setup), setup: wanted.setup) }; text += " Not tried again until the setup changes." }
        state.error = text
    }

    /// The running configuration holds an account that is no longer signed in (see `Lifecycle.revokes`).
    private func revokes() -> Bool { Lifecycle.revokes(running: running, linked: Set(links.keys), applied: committed?.accounts, accounts: store.accounts) }
    private static let signedOut = "An account in use was signed out. Sign in again."
    private static let locked = "unbraid can't read its keychain right now, so it can't use your setup yet. Unlock the keychain, then try again."

    /// Reconciliation again once a failed change is due.
    private func wakeAfter(_ wait: Duration) {
        wake?.cancel()
        let g = generation
        wake = Task {
            do { try await Task.sleep(for: wait) } catch { return }
            guard g == generation else { return }
            wake = nil
            await reconcile()
        }
    }

    /// Worker inputs are snapshots: recheck after each off-actor preparation before admitting an engine change.
    private func current(_ input: Compiler.Input, _ accounts: [String: String]) -> Bool {
        Revision(input, accounts) == revision()
    }

    /// The tailnet's search domain [input] runs with (`Compiler.searchDomain`). A pause or a deny-all runs without the home:
    /// the user's setup says whether the domain stays.
    private func search(_ input: Compiler.Input) -> String {
        Compiler.searchDomain(input, tailnet: input.setup.home.tailscale || store.setup.home.tailscale)
    }

    private func profile(_ input: Compiler.Input) -> TunnelControl.Profile {
        let s = input.setup
        // With the kill switch on, the home network goes through the tunnel and the engine sends it direct (macOS drops it
        // otherwise, see Compiler); who may reach it is the engine's rule, not the profile's. A blocked app keeps the kill
        // switch on (Store.edited), so the home network never bypasses the tunnel then: only a first block made while
        // the kill switch was off changes the profile, by turning it on.
        return .init(killSwitch: s.prefs.killSwitch, lan: s.lanBypassesTunnel, onDemand: s.prefs.alwaysOn)
    }

    /// A takeover's `apply` found the tunnel no longer running.
    private struct StoppedMeanwhile: Error {}

    /// [g]: the generation of the operation applying it. Once a newer one took over, nothing more is started.
    /// `since`: the erase request the caller's operation began under, when it waited before getting here.
    /// [staged]: told the revision the extension staged it as, before it can run. [search]: the search domain, when the
    /// caller records what it applied (otherwise `search(input)`).
    private func apply(_ input: Compiler.Input, _ json: String, _ g: Int, persist: Bool = true, requireDurable: Bool = false, profile override: TunnelControl.Profile? = nil,
                       since: Int? = nil, search searched: String? = nil, takeover: Bool = false, staged told: (String) -> Void = { _ in }) async throws {
        if !Lifecycle.mayApply(persist: persist, requireDurable: requireDurable) { throw Fail("The tunnel couldn't save its configuration") }
        engineChanges += 1
        #if DEBUG
        let json = DebugHooks.engineConfig(json)
        #endif
        // An erase requested after this point (a sign-out) wasn't meant for this config: it is never started after one.
        let request = since ?? eraseRequest
        // Checked right before each step that starts or swaps an engine (staging and the erase wait).
        let wanted = { g == self.generation && request == self.eraseRequest }
        // Its status callback runs first: a stop since an earlier change's restart came up (one this change is about to
        // recover from) is noted then, and this change is overtaken. Noted so until this change's own stop below.
        try await tunnel.initialize()
        guard g == generation else { throw CancellationError() }
        let search = searched ?? search(input)
        var unattended = input
        unattended.tsLoginPending = false
        let safeSeal = persist && input.tsLoginPending ? try Compiler.compile(unattended) : nil
        let stagePersist = persist && safeSeal == nil
        func durableSeal(_ durable: Bool) async -> Bool {
            guard let safeSeal else { return durable }
            guard wanted() else { return false }
            do { _ = try await tunnel.seal(safeSeal, search: search); return wanted() } catch { return false }
        }
        let target = override ?? profile(input), previous = tunnel.profile
        // This change's own start came up: a stop from then on is nobody's here (`OutsideStop.up`).
        var reached = false
        closeTailscaleWatch()
        // Unknown until the extension confirms the new seal: a lost answer (or a crash) must not leave an older setup on
        // record, so the record is gone before anything is staged.
        // A persisting change replaces whatever a pause sealed (or withdraws it, if it fails).
        if persist { pauseSealed = nil }
        if persist, !(await Running.unsealed()) { throw TunnelControl.Unstaged(errorDescription: "Could not save the connection state") }
        // A takeover found the tunnel running; stopped since (from System Settings) during the wait above, it is not started
        // again: the stop stands.
        if takeover, [.disconnecting, .disconnected, .invalid].contains(tunnel.refreshStatus()) { throw StoppedMeanwhile() }
        // Connect on Demand isn't part of the running tunnel: a change to it alone needs no restart (a pause leaves it).
        // An erase still pending: never reload the running engine in place, restart it so the erase comes first.
        if tunnel.status == .connected, previous?.routing == target.routing, !store.extensionWipePending {
            // Seamless: the phase stays as it is, so statistics keep their session and the dock doesn't flash Cancel.
            let appliedDurable = try await tunnel.reload(config: json, persist: stagePersist, search: search, while: wanted) { told($0.revision) }
            let durable = await durableSeal(appliedDurable)
            if json != (persist ? lastGood : (pausedJSON ?? lastGood)) { recordRun { $0.freshEngine() } }
            if persist { sealed(durable ? input.setup : nil, linked: Set(input.links.keys)) }
            if persist { await armOnDemand(target.onDemand, durable: durable, g) }
            if requireDurable && !durable { throw Fail("The tunnel couldn't save its configuration") }
        } else {
            // Checked and held by the extension before anything stops: one that can't be reached (not approved, being
            // replaced) leaves the running tunnel alone.
            let staged = try await tunnel.stage(json, persist: stagePersist, search: search)
            guard g == generation else { throw CancellationError() }
            told(staged.revision)
            // Staging waits too: a takeover whose tunnel was stopped meanwhile starts nothing.
            if takeover, [.disconnecting, .disconnected, .invalid].contains(tunnel.refreshStatus()) { throw StoppedMeanwhile() }
            state.phase = .connecting
            do {
                // Keep the old routing flags until stopped; prevent on-demand racing the controlled restart.
                try await tunnel.setOnDemand(false)
                // Right before the stop that is this change's own, nothing awaited in between: a stop from outside since an
                // earlier restart came up (this one recovers from it) is noted by now, its status read again.
                try await tunnel.stop(while: {
                    _ = self.tunnel.refreshStatus()
                    guard g == self.generation else { return false }
                    self.outside.restartOver()
                    return true
                })
                try await tunnel.waitStopped()
                // Overtaken while stopping (a Disconnect): the newer operation owns the tunnel, nothing is started again.
                guard wanted() else { throw CancellationError() }
                var staging = target; staging.onDemand = false
                try await tunnel.configure(staging)
                // A sign-out's erase the extension never confirmed: done now, or nothing starts. The erase drops every
                // staged config, so one was staged before it (checked, and the tunnel left alone if the extension can't
                // take it) is staged again after it: a start never uses a token staged before an erase.
                let erasing = store.extensionWipePending
                guard try await erasePendingNoted() == .erased else { throw Fail("unbraid couldn't erase its old VPN state. Try again.") }
                guard wanted() else { throw CancellationError() }
                var staged = staged
                if erasing {
                    // The tunnel has stopped by now: a failure here is no longer "nothing changed".
                    do { staged = try await tunnel.stage(json, persist: stagePersist, search: search) } catch let u as TunnelControl.Unstaged {
                        throw u.foreign ? TunnelControl.Foreign() : Fail(u.errorDescription ?? "")
                    }
                }
                // Checked again right before the start (staging waits): an erase or a stop requested meanwhile wins.
                let started = try await tunnel.start(staged, while: wanted)
                try await waitConnected()
                reached = true
                recordRun { $0.freshEngine() }
                outside.restartUp(g)
                // Connected proves neither which config runs nor that it was sealed: the extension says both, and
                // automatic starts are enabled only for a sealed copy.
                let appliedDurable = try await tunnel.confirm(started, while: wanted)
                let durable = await durableSeal(appliedDurable)
                if persist { sealed(durable ? input.setup : nil, linked: Set(input.links.keys)) }
                await armOnDemand(target.onDemand, durable: durable, g)
                if requireDurable && !durable { throw Fail("The tunnel couldn't save its configuration") }
            } catch {
                // The status as macOS has it now, in case it hasn't been told yet: a stop since the start came up is noted.
                if reached { _ = tunnel.refreshStatus() }
                // Only with the routing flags the sealed copy was made for, only while the extension still has one (a
                // failed start may have invalidated it), never after a newer operation (Disconnect, a stop noted) took
                // over, and never to a sealed copy that is still waiting to be erased.
                if previous?.onDemand == true, g == generation {
                    await owedLoad?.value
                    await tunnel.restoreOnDemand {
                        g == generation && tunnel.profile?.routing == previous?.routing && !store.extensionWipePending && store.setup.prefs.alwaysOn
                            && !onDemandHeld
                    }
                }
                throw error
            }
        }
        guard tunnel.status == .connected else {
            if reached { _ = tunnel.refreshStatus() }
            throw Fail("The VPN stopped while applying the change")
        }
    }

    /// Never after a newer operation took over: a Disconnect meanwhile turned Connect on Demand off for good. The engine
    /// took the configuration either way, so neither that nor a preference that couldn't be saved fails the change: the
    /// caller still records what runs.
    /// While a drop of the sealed copy is still owed (it may hold a signed-out account), or turning it off couldn't be
    /// saved, it stays off: back on once that is settled (`settleOwed`).
    private func armOnDemand(_ wanted: Bool, durable: Bool, _ g: Int) async {
        guard g == generation else { return }
        await owedLoad?.value
        guard g == generation else { return }
        let on = wanted && !onDemandHeld
        do {
            try await tunnel.armOnDemand(on, durable: durable)
        } catch {
            Log.error("on-demand not saved", error: error)
            // Off was what had to be saved (nothing sealed to start, or a drop still owed): tried again until it is.
            if !(on && durable) { disarmLater() }
        }
    }

    /// Runs [f] between engine changes, given the setup the engine runs then (nil when none): a Tailscale exit-node switch
    /// made meanwhile could land on a configuration other than the one it was meant for. Nil when cancelled while waiting.
    func steady<T>(_ f: (Setup?) async -> T) async -> T? {
        try? await exclusive { await f(running) }
    }

    /// A signed-out account's credentials must not stay in the extension's sealed copy, which Connect on Demand (or
    /// anyone with scutil) starts: it is dropped unless the configuration it holds uses no route of that provider. Noted
    /// for the disk first, before the sign-out returns (written in order, and drained at quit), so a quit before the
    /// extension answers still drops it at the next launch. Queued with engine changes, so the decision and the drop see
    /// the same sealed copy. [provider] "" drops whatever of this user's is sealed.
    func forgetSealed(_ provider: String) {
        Running.owe(provider, true)
        owedDrops.insert(provider)
        // Named afresh: a copy sealed since an earlier sign-out of this provider may hold the account signed out now. A
        // drop of the earlier one still under way no longer settles or names this one.
        owedNames[provider] = ""
        owedRequests[provider, default: 0] += 1
        // Still in the store here (the sign-out removes it after): a copy sealed while it is counts for nothing.
        owedAccounts[provider] = store.accounts[provider].map(Running.fingerprint)
        Task {
            do {
                try await exclusive {
                    if owedDrops.contains(provider) { await dropSeal(provider) }
                    // A takeover waiting to be retried mustn't keep the signed-out account running meanwhile.
                    if adopting { _ = await revokeAdopted() }
                }
            } catch { Log.error("sign-out: the sealed configuration was not dropped") }
        }
    }

    /// Owed drops, recorded before anything suspends: [provider] "" drops whatever is sealed (a revoked login). The
    /// debt is cleared only once the copy is gone or known not to use that provider. Connect on Demand goes off with a
    /// dropped copy (it would have nothing of this user's to start, and macOS would keep trying) and stays off while the
    /// drop is owed; one that failed is tried again in this session (`settleOwed`). Inside `exclusive` only.
    /// A drop is named by the copy it is meant for (`TunnelControl.forgetSealed`), so one that lands late never drops a
    /// newer copy.
    private func dropSeal(_ provider: String) async {
        let request = owedRequests[provider]
        let held = await Running.sealedState().map { Lifecycle.holds(provider, setup: $0.setup, linked: $0.linked) } ?? true
        // A sign-out of this provider made meanwhile has its own drop queued: it decides.
        guard request == owedRequests[provider] else { return }
        guard held else { return await settled(provider) }
        // Off first, when the copy may be this user's: once it is gone, a quit or a crash before the profile is saved must
        // not leave Connect on Demand on with nothing to start. Back on with the next copy sealed (a connect, or a change
        // while connected), or once the drop turns out not to be needed (`settleOwed`).
        let named = await disarmBeforeDrop()
        // Nothing is sent without the extension's word on what is sealed: asked again shortly.
        guard let named else {
            Log.error("the sealed configuration was not dropped", detail: "the extension didn't answer")
            return settleLater()
        }
        // There was no copy of this user's: Connect on Demand was left as it was, and stays on only for one to start,
        // whatever the drop's answer (one that got lost may have gone through). Another user's copy: theirs to start.
        let answer = await drop(provider, named, request)
        if answer == .foreign || named.seal == nil { await holdOnDemandNow() }
        // Dropped (or a drop that failed, or was only set aside: nothing of this user's starts either way) while Connect on
        // Demand couldn't be turned off first: what it starts from now keeps the Mac online. Over a copy whose drop is
        // still owed, the fallback also replaces the account it holds.
        else if answer == .cleared || answer == .suppressed || answer == .failed { await sealFallbackIfStuck() }
    }

    /// `dropSeal`'s request to the extension, naming the copy as [named] did the first time for this sign-out; its answer
    /// (nil when a newer sign-out of [provider] took over meanwhile, [request] being this one's).
    private func drop(_ provider: String, _ named: TunnelControl.Sealing, _ request: Int?) async -> TunnelControl.Forgot? {
        guard request == owedRequests[provider] else { return nil }
        // The sealing the first answer named, kept with the debt: a retry never drops a copy sealed after it (a sign-in
        // again since, and a connect).
        let expected: String
        if let kept = owedNames[provider], !kept.isEmpty { expected = kept } else {
            expected = named.seal ?? "none"
            owedNames[provider] = expected
            owedSealedSince.remove(provider)
            Running.owe(provider, named: expected)
        }
        let answer = await tunnel.forgetSealed(expected)
        // A sign-out of this provider made meanwhile has its own drop queued: it settles or names nothing of this one.
        guard request == owedRequests[provider] else { return nil }
        switch answer {
        case .cleared, .foreign:
            // Foreign: another user's copy, nothing of this user's in it.
            await settled(provider)
            Running.sealed(nil)
            pauseSealed = nil
        case .superseded:
            // Sealed again since the sign-out named it: the copy it named is gone once a sealing since finished.
            let sealing = await tunnel.sealing()
            guard request == owedRequests[provider] else { return nil }
            switch Lifecycle.supersededDrop(now: sealing.map { ($0.seal, $0.durable) }, sealedSince: owedSealedSince.contains(provider),
                                            fallback: sealing?.fallback == true) {
            case .settled: await settled(provider)
            case .renamed(let now):
                owedNames[provider] = now
                owedSealedSince.remove(provider)
                Running.owe(provider, named: now)
                settleLater()
            case .later: settleLater()
            }
        case .suppressed, .failed:
            // Suppressed: not started as this user's meanwhile, but the file still holds the account until it is removed.
            Log.error("the sealed configuration was not dropped")
            settleLater()
        }
        return answer
    }

    private func settled(_ provider: String) async {
        let request = owedRequests[provider], account = owedAccounts[provider]
        let pruned = await Running.prune(provider, account: account)
        guard request == owedRequests[provider] else { return }
        guard pruned else { settleLater(); return }
        Running.owe(provider, false)
        owedDrops.remove(provider)
        owedNames[provider] = nil
        owedSealedSince.remove(provider)
        owedAccounts[provider] = nil
    }

    /// The extension confirmed sealing [s] (nil: what it sealed isn't this setup, or nothing), for this app's own request.
    /// For each owed drop, a copy sealed with the store's accounts as they are now: one made once the signed-out account
    /// was gone from them (`Lifecycle.supersededDrop`).
    private func sealed(_ s: Setup?, linked: Set<String>) {
        Running.sealed(s, linked: linked)
        // The fallback, if any, was replaced (or withdrawn with the copy).
        fallbackHint = false
        guard s != nil else { return }
        for p in owedDrops {
            // Signed in again with another account, or not at all (nothing of theirs to seal with); a debt from before a
            // relaunch, whose account isn't known, only the latter.
            let now = store.accounts[p].map(Running.fingerprint)
            if p.isEmpty || now == nil || owedAccounts[p].map({ $0 != now }) == true { owedSealedSince.insert(p) }
        }
    }

    /// Owed drops whose copy this app sealed again, without the signed-out account, since the drop named the old copy.
    private var owedSealedSince: Set<String> = []
    /// The fingerprint of the account each sign-out this session signed out (nil: not known, a debt from before).
    private var owedAccounts: [String: String] = [:]

    /// Sign-outs whose drop of the sealed copy is still owed (`Running.owe`), as known in this session; complete once
    /// [owedLoad] has read the ones left from before.
    private var owedDrops: Set<String> = []
    /// The sealing each owed drop names (`dropSeal`); "" not named yet.
    private var owedNames: [String: String] = [:]
    /// Counts each provider's sign-outs this session: a drop answered for an earlier one leaves a newer one as it is.
    private var owedRequests: [String: Int] = [:]
    private var owedLoad: Task<Void, Never>?
    /// Turning Connect on Demand off was needed but couldn't be saved, or had to wait for another user's engine to stop:
    /// decided again with the owed drops.
    private var disarmPending = false { didSet { noteOnDemandOwed() } }
    /// The user turned it off (Disconnect, Settings, a sign-out's erase) and that couldn't be saved: off whatever is
    /// sealed, saved again until it is. [offIntent] stays after that: a tunnel Connect on Demand started meanwhile is
    /// taken over without turning it back on, until the user's next Connect or Resume (or the setting turned on).
    private var offWanted = false {
        didSet {
            if !offWanted { offFromBefore = false }
            noteOnDemandOwed()
        }
    }
    private var offIntent = false
    /// [offWanted] was read from before this launch, and no Off of the user's was made since: decided again once another
    /// user's copy or engine is what Connect on Demand would start (`Lifecycle.loadedOff`).
    private var offFromBefore = false
    /// The user turned Connect on Demand off this session (Disconnect, Settings, a sign-out's erase).
    private var offThisSession = false
    /// Bumped whenever the user's Connect (or Resume, or the setting turned on) supersedes their Off: a disarm under way
    /// then never brings that Off back when it fails.
    private var offCleared = 0
    /// What the disk says is owed of the two above (`Running.onDemandOwed`), so a quit before the save still turns it off
    /// at the next launch. Written only once the launch read what was owed before.
    private var onDemandNoted: Lifecycle.OnDemandOwed?
    private var onDemandLoaded = false
    private var onDemandUnsaved = false
    /// The user connected, or turned the setting on, this session: an Off of theirs read from before is no longer theirs
    /// to keep (it is decided again instead, as `hold`).
    private var offSuperseded = false

    private func noteOnDemandOwed() {
        let owed = Lifecycle.OnDemandOwed(offWanted: offWanted, disarmPending: disarmPending)
        guard onDemandLoaded, owed != onDemandNoted || onDemandUnsaved else { return }
        onDemandNoted = owed
        onDemandUnsaved = false
        Running.onDemandOwed(owed) { [weak self] written in
            // Written again with the next settling (`settleOwed`), unless a newer value was written meanwhile.
            guard let self, !written, self.onDemandNoted == owed else { return }
            self.onDemandUnsaved = true
            self.settleLater()
        }
    }
    private var settleWake: Task<Void, Never>?
    private var settleRetry = Retry<Int>()
    private var settling = false
    /// Connect on Demand is kept off for now (see `armOnDemand`).
    private var onDemandHeld: Bool { !owedDrops.isEmpty || disarmPending || offWanted || offIntent }

    /// Turns Connect on Demand off, so macOS doesn't keep starting a copy the extension won't run (with the kill switch,
    /// that keeps the Mac offline). Not while another user's engine runs: the profile is the Mac's, and that is theirs.
    /// One that can't be saved is tried again (`settleOwed`).
    /// [user]: the user's own Off (Settings), kept until saved whatever is sealed.
    /// [cleared]: `offCleared` when the user's Off was decided (now when nil).
    private func disarmOnDemand(user: Bool = false, cleared: Int? = nil) async {
        let cleared = cleared ?? offCleared
        // The user's Off, turned back on while this waited for the system: nothing of it is left to save.
        func superseded() -> Bool { user && cleared != offCleared && store.setup.prefs.alwaysOn }
        // Read again from the system: one still loading, or changed by another process, isn't taken for off.
        guard await tunnel.onDemandOn() != false else {
            disarmPending = false; offWanted = false
            await retireFallback()
            return
        }
        // Kept as an obligation, looked at again: once their engine stops, Connect on Demand may have nothing to start.
        guard !(await tunnel.runsForAnotherUser()) else { return user ? offAgain(cleared) : disarmLater() }
        if superseded() { return }
        do {
            try await tunnel.setOnDemand(false)
            disarmPending = false; offWanted = false
            Log.info("on-demand: turned off")
            // Turned on again while it was saved: back on the usual way.
            if superseded() { return await rearmOnDemand() }
            await retireFallback()
        } catch {
            Diagnostics.noteFailure("Could not turn Connect on Demand off", error)
            if user { offAgain(cleared) } else { disarmLater() }
            // Not saved: with nothing left to start, what it starts meanwhile has to keep the Mac online.
            await sealFallbackIfStuck()
        }
    }

    private func disarmLater() {
        disarmPending = true
        settleLater()
    }

    /// The user's Off that is still owed (`offWanted`). One read from before this launch is theirs only while what
    /// Connect on Demand would start isn't another user's (`Lifecycle.loadedOff`): otherwise decided again as a hold,
    /// which leaves it to them. Inside `exclusive` only.
    private func settleOff() async {
        let cleared = offCleared
        if offFromBefore, await tunnel.onDemandOn() != false {
            let engine = await tunnel.revisions(timeout: 5).map(Self.engine)
            // The user connected (or turned the setting on) meanwhile: nothing of the Off is left.
            guard offWanted else { return }
            if offFromBefore, Lifecycle.loadedOff(engine: engine) == .hold {
                Log.info("on-demand: an Off from before is left to another user's copy")
                disarmPending = true
                offWanted = false
                _ = await hold(engine, pending: true)
                return
            }
        }
        guard offWanted, cleared == offCleared else { return }
        await disarmOnDemand(user: true, cleared: cleared)
    }

    /// The user's Off tried again (`disarmOnDemand`), unless their Connect superseded it meanwhile ([cleared]).
    private func offAgain(_ cleared: Int) {
        guard cleared == offCleared else { return }
        offLater(again: true)
    }

    /// The user's own Off that couldn't be saved. [again]: the same Off, tried again (one from before this launch still is).
    private func offLater(again: Bool = false) {
        offWanted = true; offIntent = true
        if !again { offFromBefore = false; offThisSession = true }
        settleLater()
    }

    /// Connect on Demand off when nothing it would start runs (`Lifecycle.onDemandHold`), as the extension says now.
    /// Inside `exclusive` only.
    /// [pending]: deciding a disarm owed from before (`disarmPending`), which stands until this decision is made (also on
    /// disk), and isn't itself a reason to turn it off.
    @discardableResult
    private func holdOnDemandNow(pending: Bool = false) async -> Bool {
        guard await tunnel.onDemandOn() != false else {
            if pending { disarmPending = false }
            return false
        }
        let engine = await tunnel.revisions(timeout: 5).map(Self.engine)
        return await hold(engine, pending: pending)
    }

    /// Acts on `Lifecycle.onDemandHold`; true when Connect on Demand went off. While another user's engine runs it is
    /// theirs, and looked at again later (`settleOwed`). A sign-out's erase still pending counts as an owed drop: the copy
    /// goes.
    private func hold(_ engine: Lifecycle.Engine?, pending: Bool = false) async -> Bool {
        if engine?.foreign == true { disarmLater(); return false }
        let owed = !owedDrops.isEmpty || offWanted || offIntent || disarmPending && !pending || store.extensionWipePending
        guard Lifecycle.onDemandHold(engine: engine, owed: owed) == .disarm else {
            if pending { disarmPending = false }
            return false
        }
        await disarmOnDemand()
        return await tunnel.onDemandOn() == false
    }

    /// Before the sealed copy is dropped (`dropSeal`, `erasePending`): Connect on Demand off first when the copy may be
    /// this user's, or nobody answered (`Lifecycle.disarmFirst`). Another user's copy is theirs to start. Inside
    /// `exclusive` only. What the extension said, nil when it didn't answer.
    private func disarmBeforeDrop() async -> TunnelControl.Sealing? {
        let named = await tunnel.sealing()
        if Lifecycle.disarmFirst(answered: named != nil, seal: named?.seal) { await disarmOnDemand() }
        return named
    }

    private static func engine(_ r: TunnelControl.Revisions) -> Lifecycle.Engine {
        Lifecycle.Engine(running: r.running, durable: r.durable, foreign: r.foreign, startable: r.startable, fallback: r.fallback,
                         fallbackRunning: r.fallbackRunning, othersFallback: r.othersFallback)
    }

    /// Connect on Demand had to go off (a drop or an erase removed the sealed copy, or nothing is left to start) and that
    /// couldn't be saved: the extension seals the credential-free fallback in its place (`Lifecycle.fallbackNeeded`,
    /// `Compiler.fallback`), so what macOS starts meanwhile sends everything direct instead of failing again and again,
    /// which with the kill switch keeps the Mac offline. Dropped once the off is saved (`retireFallback`). Inside
    /// `exclusive` only.
    private func sealFallbackIfStuck() async {
        let on = await tunnel.onDemandOn()
        guard on != false else { return }
        let engine = await tunnel.revisions(timeout: 5).map(Self.engine)
        guard Lifecycle.fallbackNeeded(onDemand: on, engine: engine) else { return }
        let json: String
        do {
            json = try Compiler.fallback(prefs: store.setup.prefs, selfPattern: Compiler.pattern(forPath: Bundle.main.executablePath ?? Bundle.main.bundlePath))
        } catch { return Log.error("fallback not built", error: error) }
        // Before it is sent: one whose answer is lost may still be sealed.
        fallbackHint = true
        guard await tunnel.sealFallback(json) != nil else { return Log.error("on-demand: no fallback sealed") }
        Log.info("on-demand: sealed a fallback that lets traffic out as Direct does")
    }

    /// Once Connect on Demand is off, the fallback (`sealFallbackIfStuck`) has nothing left to do: its tunnel is stopped
    /// while this app is off (nothing starts it again), and the copy is dropped like any other, named, so a copy sealed
    /// since stays (`Lifecycle.fallbackRetire`). False when that has to be tried again. Inside `exclusive` only.
    @discardableResult
    private func retireFallback() async -> Bool {
        guard fallbackHint else { return true }
        let on = await tunnel.onDemandOn()
        let engine = await tunnel.revisions(timeout: 5).map(Self.engine)
        switch Lifecycle.fallbackRetire(onDemand: on, engine: engine, off: state.phase == .off && store.pause == nil) {
        case .none:
            fallbackHint = false
            return true
        case .keep: return true
        case .later:
            settleLater()
            return false
        case .drop(let stop):
            // Stopped first, and asked about again until macOS says it has.
            var stopped = true
            if stop, tunnel.status == .connected {
                Log.info("on-demand: stopping the fallback")
                do {
                    try await tunnel.stop()
                    try await tunnel.waitStopped()
                } catch { stopped = false }
            }
            var dropped = true
            if engine?.fallback == true {
                // Named as it is now: only that very fallback goes, never a copy sealed since (`Ownership.dropsFallback`).
                if let named = await tunnel.sealing() {
                    if named.fallback, let seal = named.seal { dropped = await tunnel.dropFallback(seal) }
                } else { dropped = false }
            }
            guard stopped, dropped else { settleLater(); return false }
            if stop { recordRun { $0.stopped() } }
            fallbackHint = false
            return true
        }
    }

    /// The erase `adoptRunningTunnel` left (`eraseLeft`: an interrupted sign-out's that failed, or that waited for the
    /// fallback to stop, `Lifecycle.eraseStop`), tried again with the owed settling: true once it went through, or isn't
    /// this to do (paused or connected: those erase first themselves; no VPN configuration: nothing to erase it from). Not
    /// while the tunnel runs: the fallback stops once Connect on Demand is off (`retireFallback`). Inside `exclusive` only.
    private func eraseOwed() async -> Bool {
        guard eraseLeft, store.extensionWipePending, state.phase == .off, !adopting else {
            eraseLeft = false
            return true
        }
        guard tunnel.status == .disconnected || tunnel.status == .invalid else { return false }
        let outcome = try? await erasePendingNoted()
        // On only with something left to start, whatever the erase did (also one that failed after the copy went: a
        // disarm that isn't saved then seals the fallback).
        await holdOnDemandNow()
        guard outcome == .erased || outcome == .deferred else { return false }
        eraseLeft = false
        return true
    }

    /// A fallback may be sealed or running (`sealFallbackIfStuck`): asked about when Connect on Demand goes off. Unknown at
    /// launch, so asked once then.
    private var fallbackHint = true

    /// Tries owed drops (and a disarm that wasn't saved) again after a growing wait: 10 s, 30 s, ... every 10 minutes.
    private func settleLater() {
        guard settleWake == nil, let wait = settleRetry.failed(0, disrupted: false, now: .now) else { return }
        settleWake = Task {
            do { try await Task.sleep(for: wait) } catch { return }
            settleWake = nil
            await settleOwed()
        }
    }

    /// One drop per turn of the queue, so a Connect waits for at most one unanswered call. Once nothing is owed, Connect
    /// on Demand comes back for what runs, as it would have been armed.
    private func settleOwed() async {
        // One at a time: a wake and a launch's settling never send the same drops twice.
        guard !settling else { return }
        settling = true
        defer { settling = false }
        await owedLoad?.value
        noteOnDemandOwed()
        // So is an owed drop the disk didn't take: a drop left unanswered changes nothing that would write it again.
        Running.retryOwed()
        // First, a disarm that wasn't saved (or waited for another user's engine), also one owed from before a relaunch:
        // what the user turned off stays off; otherwise decided again on what holds now.
        if disarmPending || offWanted {
            _ = try? await exclusive {
                if offWanted { await settleOff() } else if disarmPending { await holdOnDemandNow(pending: true) }
            }
        }
        for p in owedDrops.sorted() { _ = try? await exclusive { if owedDrops.contains(p) { await dropSeal(p) } } }
        // A fallback left once Connect on Demand is off goes too.
        let retired = fallbackHint ? (try? await exclusive { await retireFallback() }) ?? false : true
        // So does an interrupted sign-out's erase that failed, or waited for the fallback, once nothing runs.
        let erased = eraseLeft ? (try? await exclusive { await eraseOwed() }) ?? false : true
        // The user's own Off stays (offIntent): only their next Connect turns Connect on Demand back on.
        guard !onDemandHeld || offIntent && owedDrops.isEmpty && !disarmPending && !offWanted else { return settleLater() }
        guard retired, erased else { return settleLater() }
        settleRetry.clear()
        _ = try? await exclusive { await rearmOnDemand() }
    }

    /// Connect on Demand back on, when the user wants it, for what runs: while connected, only if the extension still
    /// has this user's copy to start (and it was sealed for what runs); while paused, by sealing the pause's copy again,
    /// which arms it (a pause that stopped the tunnel seals nothing). Inside `exclusive` only.
    private func rearmOnDemand() async {
        guard store.setup.prefs.alwaysOn, !onDemandHeld, !store.extensionWipePending else { return }
        let g = generation
        switch state.phase {
        case .on where !tunnel.onDemandUnavailable && tunnel.profile?.onDemand == false:
            await tunnel.restoreOnDemand {
                g == generation && state.phase == .on && store.setup.prefs.alwaysOn && !onDemandHeld && !store.extensionWipePending
            }
        case .paused:
            pauseSealed = nil
            Task { await reconcile() }
        default: return
        }
    }

    /// Settings turned Connect on Demand off: the profile follows now, whatever the state (Off has nothing else that would
    /// write it, and a pause that sealed already wouldn't either). Turned on, it is written by the next change while
    /// connected, by sealing a pause again, or by the next connect: never while off, which would let macOS start a VPN the
    /// user has off.
    func onDemandChanged(_ on: Bool) {
        if on {
            offWanted = false; offIntent = false; offSuperseded = true; offCleared += 1
            // A pause that sealed already is sealed again, which arms it (`rearmOnDemand`): no change of its would.
            if state.phase == .paused { Task { _ = try? await exclusive { await rearmOnDemand() } } }
            return
        }
        // The user's Off now, whatever one from before was.
        offFromBefore = false; offThisSession = true
        Task { _ = try? await exclusive { if !store.setup.prefs.alwaysOn { await disarmOnDemand(user: true) } } }
    }

    /// After a stop unbraid didn't ask for, or one its own change ended in (`teardown`): Connect on Demand stays on only
    /// for a copy of this user's to start (`Lifecycle.onDemandHold`). [g]: the operation that stopped; a newer one owns it.
    private func holdOnDemand(_ g: Int) async {
        guard await tunnel.onDemandOn() != false else { return }
        let engine = await tunnel.revisions(timeout: 5).map(Self.engine)
        guard g == generation, state.phase == .off else { return }
        _ = await hold(engine)
    }

    enum Recovered { case restored, blocking, off }

    /// Recovery is part of the same transaction and must finish even if its caller was cancelled, but not once a newer
    /// operation (a Disconnect) took over. [accounts]: those [old] was built with; nil = not known. [blocking]: [old] is
    /// a deny-all, put back as one.
    /// When the old configuration can't be restored either, apps that would use a VPN are blocked (`Compiler.denyAll`)
    /// rather than let out without one, and the setup is tried again as any failed change is; only if that fails too does
    /// the tunnel stop.
    @discardableResult
    private func recover(_ old: Compiler.Input?, _ accounts: [String: String]?, blocking: Bool = false, interim: Bool = false, error: Error, _ g: Int) async -> Recovered {
        let failure = message(error, "Change not applied")
        // Compiling waits: a sign-out's erase requested meanwhile must not be consumed by restoring the old config.
        let request = eraseRequest
        do {
            guard var input = old else { throw Fail("No previous configuration") }
            // A deny-all put back is built from the setup as it is now: an app moved from Direct to a VPN route since the
            // last one is blocked too. From what ran only while the keychain won't open the setup.
            if blocking { return try await block(store.isHeld ? input : makeInput(store.setup, [:], probe: nil), failure, request, g) }
            if !input.setup.testing.isEmpty {
                input.setup.testing = []
                let active = Set(input.setup.activeRoutes.map(\.id))
                input.links = input.links.filter { active.contains($0.key) }
                input.blocked = input.blocked.intersection(active)
            }
            input.probe = newProbe()
            input.tsLoginPending = input.tsLoginPending && tsLoginPending
            let json = try await Self.compile(input).get()
            guard g == generation else { return .off }
            // Never sealed again with accounts that were signed out or changed meanwhile, or never checked: it runs until
            // the next change, and no longer.
            let current = accounts.map { $0.allSatisfy { store.accounts[$0.key] == $0.value } } ?? false
            try await Task { try await self.apply(input, json, g, persist: current, since: request) }.value
            commit(input, json, accounts, interim: interim)
            guard g == generation else { return .restored }
            state.phase = .on
            state.servers = input.links.mapValues(\.server)
            state.error = failure
            armRouteRetry()
            watchTailscale()
            return .restored
        } catch {
            guard g == generation else { return .off }
            var reason = message(error, failure)
            // Another user's engine runs now: theirs, never stopped from here (the stop's own check gives up after seconds).
            if TunnelControl.foreign(error) {
                await teardown(error: reason, stop: false, g)
                return .off
            }
            // Another user's engine runs now: nothing of this user's to block, nor to stop. Built from the setup as it is
            // now (which apps go direct), never from stand-ins for one the keychain won't open. A deny-all that failed to
            // go back was built the same way: not tried twice.
            if !blocking, !TunnelControl.foreign(error), !store.isHeld {
                do { return try await block(makeInput(store.setup, [:], probe: nil), failure, request, g) } catch {
                    guard g == generation else { return .off }
                    reason = message(error, "Could not block VPN apps")
                    if TunnelControl.foreign(error) {
                        await teardown(error: reason, stop: false, g)
                        return .off
                    }
                }
            }
            await teardown(error: "Change failed and the previous connection could not be restored: \(reason)", g)
            return .off
        }
    }

    /// Runs the deny-all of [input] in place of what failed (part of `recover`). Not sealed: Connect on Demand keeps
    /// whatever copy the extension still has, and is turned off if it has none.
    private func block(_ input: Compiler.Input, _ failure: String, _ request: Int, _ g: Int) async throws -> Recovered {
        let blocking = Compiler.denyAllInput(input), already = committed?.blocking == true
        let json = try Compiler.denyAll(blocking), searched = search(blocking)
        guard g == generation else { return .off }
        // Named before it can run, for a takeover after a relaunch: that must never stop it for the accounts of the record it
        // stands in for (it holds none, and stopping it would let the apps it blocks out).
        try await Task {
            try await self.apply(blocking, json, g, persist: false, profile: self.tunnel.profile, since: request, search: searched) { Running.blocker($0) }
        }.value
        // No route and no account: nothing to revoke, and the store's setup differs, so it is tried again.
        commit(blocking, json, [:], blocking: true, search: searched)
        let r = await tunnel.revisions()
        guard g == generation else { return .blocking }
        if let r, !r.foreign, r.durable == nil { await armOnDemand(store.setup.prefs.alwaysOn, durable: false, g) }
        guard g == generation else { return .blocking }
        state.phase = .on
        state.servers = [:]
        state.error = "\(failure) \(Self.blocking)"
        armRouteRetry()
        // Once: a deny-all put back after another failure, or changed with the setup, says nothing new.
        if !already { Notifier.post(title: "unbraid is blocking VPN apps", body: Self.blocking) }
        watchTailscale()
        return .blocking
    }

    /// While a deny-all runs (`recover`) and a change can't be applied: the deny-all of the setup as it is now, when it
    /// differs from the one that runs (`Lifecycle.reblock`). Refused before anything changed: the one that runs stays. Any
    /// other failure is recovered from as a failed change is (a deny-all again, or the tunnel stops). Inside `exclusive`.
    private func reblock(_ old: Committed, _ error: Error, _ g: Int) async -> Recovered? {
        let input = makeInput(store.setup, [:], probe: nil)
        let fresh = old.blocking && !store.isHeld
            ? (try? Compiler.denyAll(input)).map { (json: $0, search: search(Compiler.denyAllInput(input))) } : nil
        guard Lifecycle.reblock(blocking: old.blocking, held: store.isHeld, running: (old.json, old.search), fresh: fresh) else { return nil }
        do { return try await block(input, message(error, "Change not applied"), eraseRequest, g) }
        catch is CancellationError { return nil }
        catch let e where e is TunnelControl.Unstaged || TunnelControl.foreign(e) {
            // Nothing changed, or another user's engine runs: the deny-all that ran is left as it is.
            Log.error("deny-all not updated", error: e)
            return nil
        } catch {
            guard g == generation else { return .off }
            return await recover(old.input, old.accounts, blocking: true, error: error, g)
        }
    }

    private static let blocking = "unbraid couldn't put the previous connection back either, so apps that use a VPN are blocked until "
        + "it can apply your setup. Disconnect to let them out without the VPN."

    /// Records what the engine runs. [accounts]: those its links were made with; nil = not known.
    /// [blocking]: a deny-all (see `recover`). Its record isn't kept: the one of the configuration it stands in for still
    /// says best what an unattended start would run (its sealed copy) and which accounts that holds. An interim records
    /// only what runs now: the user's applied setup waits for the final configuration, including after recovery.
    private func commit(_ input: Compiler.Input, _ json: String, _ accounts: [String: String]?, blocking: Bool = false, interim: Bool = false, search searched: String? = nil) {
        let s = input.setup, links = input.links
        committedEngine = tunnel.applied
        let tags = ((try? Compiler.shared(s, links, blocked: input.blocked)) ?? [:]).merging(
            s.activeRoutes.filter { $0.tsExit != nil && !input.blocked.contains($0.id) }.map { ($0.id, Compiler.tsTag) }) { $1 }
        committed = Committed(input: input, json: json, accounts: accounts, tags: tags, probeDNS: (try? Compiler.probeDNS(input)) ?? [:], revision: Revision(input, accounts ?? store.accounts),
                              blocking: blocking, interim: interim, search: searched ?? search(input))
        commits += 1
        if blocking { recordRun { $0.deniedAll() } }
        else if Revision(input, accounts ?? store.accounts) == revision() {
            recordRun { $0.committed(revision: RunState.revision(s), setup: s, fresh: true, interim: interim) }
        }
        if !blocking && !interim && input.setup.testing.isEmpty {
            Running.save(.init(setup: s, links: links, accounts: accounts.map(Running.fingerprints))) { [weak self] in
                Task { await self?.settleOwed() }
            }
            Running.blocker(nil)
        }
    }

    /// Return errors as values so callers can discard stale inputs before surfacing their validation failure. What the
    /// compiler can't build, or the engine rejects, is `Refused`: asking again with the same inputs gets the same answer.
    @concurrent private static func compile(_ input: Compiler.Input, validate: Bool = true) async -> Result<String, Error> {
        let json: String
        do { json = try Compiler.compile(input) } catch {
            return .failure(Refused((error as? Fail)?.errorDescription ?? (error as NSError).localizedDescription))
        }
        do {
            if validate { try await check(json) }
            return .success(json)
        } catch { return .failure(error) }
    }

    /// The engine checks it in the extension (launched for the asking, tunnel running or not). Engine errors can quote
    /// the config, keys included: never shown or logged unredacted (the extension redacts them too).
    private nonisolated static func check(_ json: String) async throws {
        switch await EngineLink.call(timeout: 30, { $0.checkConfig(json, reply: $1) }) {
        case .none: throw Fail("The connection engine didn't answer. Check that unbraid is allowed in System Settings › General › Login Items & Extensions.")
        case .some(nil): return
        case .some(let error?):
            Log.error("check", detail: Redact.clean(error))
            Diagnostics.noteRejection(error, config: json)
            throw Refused("The connection engine rejected this setup.")
        }
    }

    /// The engine no longer runs what was committed. Edits still pending keep their retry state (see `retry`).
    private func clearRunning(forget: Bool = true) {
        engineChanges += 1
        changes.stop()
        healthWatch?.cancel(); healthWatch = nil
        closeTailscaleWatch()
        wake?.cancel(); wake = nil
        committed = nil
        if forget { Running.save(nil); Running.blocker(nil) }
    }

    /// Called only after admission; failure recovery leaves on-demand enabled, unless the credentials were revoked:
    /// then it stops like the user would (on-demand off) and forgets the running state. [g]: the caller's generation;
    /// once a newer operation took over, it owns the state, and the tunnel unless this revokes. Ends a pause too: Off
    /// is what shows, so nothing resumes at its deadline or pauses again at the next launch, and a tunnel Connect on
    /// Demand starts again is taken over.
    /// [stop] false: another user's engine runs now, theirs to stop; only this app's state of it ends.
    private func teardown(error: String?, revoke: Bool = false, stop: Bool = true, _ g: Int? = nil) async {
        // Overtaken: the newer operation owns the tunnel too. A revocation still stops and drops the seal (inside the
        // queue no newer engine runs yet, and a signed-out account must not keep running).
        if let g, g != generation, !revoke { return }
        // Its own stop is no stop from outside.
        outside.operation()
        // A revoked login's credentials leave the sealed copy too: anyone could start that. Owed before anything suspends.
        if revoke { Running.owe("", true); owedDrops.insert(""); owedNames[""] = ""; owedRequests["", default: 0] += 1 }
        if stop { _ = try? await tunnel.stop(userInitiated: revoke) }
        if revoke { await dropSeal("") }
        if let g, g != generation { return }
        clearRunning(forget: revoke)
        recordRun { if stop { $0.stopped() } else { $0.foreign() } }
        // Kept for a takeover of what Connect on Demand starts again, but no longer a connection an update reconnects.
        if !revoke { Running.stopped(true) }
        cancelResume()
        stopAdopting()
        pausedInput = nil; pausedProfile = nil
        store.pause = nil
        pauseRetry.clear()
        state = VpnState(error: error)
        if let error { Notifier.post(title: "unbraid is off", body: error) }
        // Connect on Demand stays on only with something of this user's to start. A revocation turned it off already;
        // another user's engine is theirs.
        // Unstructured: this teardown may run inside the task `clearRunning` just cancelled (the health watch, the change
        // observer), and a cancelled lookup would wrongly answer "nothing to start" and turn Connect on Demand off.
        if !revoke, stop { let hold = g ?? generation; await Task { await self.holdOnDemand(hold) }.value }
    }

    private func cancelResume() { resumeGeneration += 1; resume?.cancel(); resume = nil }

    private nonisolated static func uptime() -> TimeInterval { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }

    private nonisolated static func bootID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size < 256 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private nonisolated static func remaining(_ pause: (until: Date?, since: Date, uptime: TimeInterval?, boot: String?), until: Date) -> TimeInterval {
        PauseDeadline(wall: until, uptime: pause.uptime, boot: pause.boot).remaining(wallNow: .now, uptimeNow: uptime(), bootNow: bootID())
    }

    /// [growing]: a failed resume of an expired pause (each attempt asks the providers and may apply the paused engine
    /// again) waits longer each time, per pause deadline.
    private func armResume(retry: Bool = false, growing: Bool = false) {
        cancelResume()
        guard let pause = store.pause, let until = pause.until else { return }
        let timer = resumeGeneration
        let wait = growing && Self.remaining(pause, until: until) <= 0 ? resumeRetry.failed(until, disrupted: false, now: .now) ?? .seconds(15) : .seconds(15)
        resume = Task {
            do {
                if retry, Self.remaining(pause, until: until) <= 0 { try await Task.sleep(for: wait) }
                while Self.remaining(pause, until: until) > 0 {
                    try await Task.sleep(for: .seconds(min(15, max(1, Self.remaining(pause, until: until)))))
                }
                try Task.checkCancellation()
                guard timer == resumeGeneration, store.pause != nil else { return }
                resume = nil
                await connect()
            } catch {}
        }
    }

    /// One engine change at a time; cancelled waiters leave the queue without running their operation.
    private func exclusive<T>(_ f: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let id = UUID()
        if busy {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { c.resume(throwing: CancellationError()) }
                    else { waiting.append((id, c)) }
                }
            } onCancel: {
                Task { @MainActor in
                    if let i = self.waiting.firstIndex(where: { $0.0 == id }) {
                        self.waiting.remove(at: i).1.resume(throwing: CancellationError())
                    }
                }
            }
        } else { busy = true }
        defer {
            // A restart that came up in this turn is no longer the reason a stop counts (`OutsideStop.up`).
            outside.restartOver()
            if waiting.isEmpty { busy = false }
            else { waiting.removeFirst().1.resume() }
        }
        try Task.checkCancellation()
        return try await f()
    }

    // MARK: Watching

    private func startWatching() {
        healthWatch?.cancel(); healthWatch = nil
        changes.start()
        healthWatch = Task { await watchHealth() }
        watchTailscale()
    }

    /// Compare with the committed inputs immediately, including edits made while connect or reload was suspended.
    /// `reload` and `reconcilePause` retain their generation checks, share the engine's exclusive queue, and decide again
    /// there whether a change is still due.
    private func reconcile() async {
        removedPins.update(store.setup, accounts: store.accounts)
        let endedTesting = testingOwner.token != nil && Lifecycle.endTesting(base: testingBase, accounts: testingAccounts, setup: store.setup, currentAccounts: store.accounts)
        if endedTesting { testingOwner.clear(); testingBase = nil; testingAccounts = nil }
        let g = generation
        let wanted = revision()
        recordRun { $0.storeMoved(to: RunState.revision(wanted.setup)) }
        // Lookups for a setup that changed since are no longer worth waiting for.
        if let l = lookup, let w = l.wanted, w != wanted { l.task.cancel() }
        if state.phase == .on, reloadFlight.needsReconcile(wanted, applied: appliedRevision, allowed: retry.allows(wanted, now: .now)) { await reload(waitForProviders: false) }
        if endedTesting { await removeTestingIfNeeded(g) }
        if state.phase == .paused, !Task.isCancelled { await reconcilePause() }
        if !Task.isCancelled { watchTailscale() }
    }

    /// Notes a stop nobody here asked for before anything else runs (`OutsideStop`): every older operation gives up, and a
    /// timed resume with them. On the main actor, from the status callback itself.
    @discardableResult
    private func noteStop() -> Bool {
        guard outside.observe(phase: state.phase, applied: pausedInput != nil, status: Self.status(tunnel.status), current: generation) else { return false }
        generation += 1
        outside.latch(generation)
        cancelResume()
        Log.info("tunnel: stopped from outside")
        return true
    }

    /// Operation [g] is done (`OutsideStop.settle`). A stop that came while it was under way, which it didn't end (it gave
    /// way, or left what shows as it was), is noted now, before anything queued can act on it: no status change may
    /// follow it.
    private func settle(_ g: Int) {
        outside.settle(g, current: generation)
        guard g == generation, noteStop() else { return }
        Task { await statusChanged() }
    }

    private static func status(_ s: NEVPNStatus) -> Lifecycle.Status {
        switch s {
        case .connected: .connected
        case .disconnecting: .stopping
        case .disconnected, .invalid: .stopped
        default: .connecting
        }
    }

    private func statusChanged() async {
        do {
            try await exclusive {
                let g = generation
                // A stop nobody here asked for ends what it stopped, a pause included, whatever the status is now: the
                // user's stop (System Settings, scutil) or macOS's is never undone here. An operation made since owns it.
                switch outside.take(current: g) {
                case .current:
                    // Taken before the wait, so an operation made meanwhile can't leave the stop latched; the reason
                    // (macOS's last disconnect error) arrives just after the status, so it is waited for, briefly.
                    let error = await tunnel.disconnectError()
                    guard g == generation else { return }
                    return await teardown(error: error ?? "The VPN was turned off by macOS", g)
                case .superseded: return
                case .none: break
                }
                if tunnel.status == .connected, state.phase == .off || adopting { await adoptRunningTunnel() }
                else if adopting, tunnel.status == .disconnected || tunnel.status == .invalid {
                    let error = await tunnel.disconnectError()
                    guard g == generation else { return }
                    // Stopped while waiting to be taken over: nothing left to take over.
                    stopAdopting()
                    recordRun { $0.stopped() }
                    state = VpnState(error: error)
                } else if (state.phase == .on || state.phase == .paused && pausedInput != nil), outside.settled,
                        tunnel.status == .disconnected || tunnel.status == .invalid {
                    let error = await tunnel.disconnectError()
                    guard g == generation else { return }
                    // Not while an operation is under way (one queued, or a Disconnect stopping): it owns the outcome.
                    await teardown(error: error ?? "The VPN was turned off by macOS", g)
                }
                if tunnel.status == .disconnected || tunnel.status == .invalid {
                    adoptionObserved = false
                    // An update's reconnect put off until the old tunnel is down (`extensionReady`), once the queue is free.
                    let g = generation, r = tunnel.replacements
                    if replacedReady.due(adopting: adopting, phase: state.phase, status: .stopped, current: g, replacement: r) {
                        Log.info("update: the old tunnel is down, deciding the reconnect")
                        Task { await self.extensionReady(replaced: true, since: g, replacement: r) }
                    }
                }
                // Off (also just now), and the tunnel down: an unattended start that ended, or never came up. One the
                // extension refuses fails again and again. Whatever this app last saved of Connect on Demand: another
                // process may have turned it on.
                if state.phase == .off, tunnel.status == .disconnected {
                    // What was said about a fallback running is over with it.
                    if state.error == Self.fallbackRuns || state.error == Self.othersFallbackRuns || state.error == Self.stopUnconfirmed { state = VpnState() }
                    holdOnDemandSoon()
                }
            }
        } catch {}
    }

    /// While off, Connect on Demand stays on only with something to start (`holdOnDemandIdle`), looked at a moment after
    /// the tunnel went down and at most once a minute (`Lifecycle.idleHoldWait`): another user's failed seal, or a drop,
    /// can leave nothing startable without anything of this app's changing. One for the generation now (an older one is
    /// replaced).
    private func holdOnDemandSoon() {
        let g = generation
        guard idleHold == nil || idleHoldGeneration != g else { return }
        idleHold?.cancel()
        let id = UUID()
        (idleHoldId, idleHoldGeneration) = (id, g)
        // The launch's own check comes first, for a minute at most (the extension may never get ready: not approved, a
        // restart needed, failed).
        let wait = Lifecycle.idleHoldWait(last: idleHoldAt, now: .now, ready: readyChecked ? nil : launchedAt + .seconds(60))
        idleHold = Task {
            let slept: Void? = try? await Task.sleep(for: wait)
            // A cancelled one never clears its replacement.
            guard idleHoldId == id else { return }
            idleHold = nil; idleHoldId = nil
            guard slept != nil, g == generation, state.phase == .off else { return }
            idleHoldAt = .now
            await holdOnDemandIdle(g)
        }
    }

    private var idleHold: Task<Void, Never>?
    private var idleHoldId: UUID?
    private var idleHoldGeneration = 0
    private var idleHoldAt: ContinuousClock.Instant?
    private let launchedAt = ContinuousClock.now

    /// Checks provider tunnels in rounds; only results from the same engine and network count.
    private func watchHealth() async {
        var plan = HealthSchedule()
        var basis = (runIdentity.engineStarts, healthReset)
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            let current = (runIdentity.engineStarts, healthReset)
            if current != basis {
                basis = current
                plan.restart(now: .now)
                if !state.dropping.isEmpty { state.dropping = [] }
                failing.removeAll()
            }
            guard state.phase == .on, !SpeedTest.shared.testing, let setup = running else { continue }
            let exits = healthExits()
            let eligible = Set(exits.keys.filter { id in
                guard let exit = exits[id] else { return false }
                return exit.keys.allSatisfy { route in
                    guard let p = setup.route(route)?.loc.provider, let provider = Providers.get(p) else { return true }
                    return !ProviderStatus.settingUp(signedIn: AppModel.shared.signedInAt[p], seconds: provider.keySetup)
                }
            })
            let (checked, regular) = plan.checks(eligible, now: .now)
            if checked.isEmpty {
                if regular { _ = plan.finish([:], regular: true, now: .now, draw: Double.random(in: HealthSchedule.every)) }
                continue
            }
            let c = commits, t = SpeedTest.shared.tests, epoch = engineEpoch, reset = healthReset
            let endpoint = probe, dns = committed?.probeDNS ?? [:]
            var answers: [String: Bool] = [:]
            // In a random order, each after a random wait: checks of different exits don't go out together, so whoever
            // answers them (the STUN servers, the HTTPS site) can't line exits up by their timing. Spread over up to 15 s
            // in a regular round, 3 s for a quick re-check.
            let ids = checked.shuffled(), spread = regular ? 15.0 : 3.0
            for offset in stride(from: 0, to: ids.count, by: 4) {
                await withTaskGroup(of: (String, Bool).self) { group in
                    for id in ids[offset..<min(offset + 4, ids.count)] {
                        guard exits[id] != nil else { continue }
                        let wait = Double.random(in: 0..<spread)
                        group.addTask {
                            try? await Task.sleep(for: .seconds(wait))
                            return (id, await Health.reachable(id, probe: endpoint, dns: dns[id]))
                        }
                    }
                    for await (id, ok) in group { answers[id] = ok }
                }
            }
            guard !Task.isCancelled, state.phase == .on, commits == c, engineEpoch == epoch, healthReset == reset,
                  SpeedTest.shared.tests == t, !SpeedTest.shared.testing else { continue }
            if answers.values.contains(false) {
                let engine = await tunnel.revisions(timeout: 3)
                guard commits == c, engineEpoch == epoch, healthReset == reset, state.phase == .on,
                      let engine, !engine.foreign, engine.running != nil else { continue }
            }
            let deadTags = plan.finish(answers, regular: regular, now: .now, draw: Double.random(in: HealthSchedule.every), networkUp: networkUp)
            failing = Set(plan.streaks.keys.flatMap { exits[$0]?.values.map { $0 } ?? [] })
            let dropping = exits.filter { plan.dropping($0.key) }.values.flatMap { $0.keys }.sorted()
            if dropping != state.dropping { state.dropping = dropping }
            guard !deadTags.isEmpty else { continue }
            let dead = deadTags.compactMap { exits[$0] }
            let routeIds = Set(dead.flatMap { $0.keys })
            let accounts = store.accounts
            var revoked: [String: String] = [:]
            for p in Set(routeIds.compactMap { setup.route($0)?.loc.provider }) {
                guard let account = accounts[p], let provider = Providers.get(p) else { continue }
                let removed = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                    group.addTask { (try? await provider.revoked(account)) == true }
                    group.addTask { try? await Task.sleep(for: .seconds(8)); return false }
                    let result = await group.next() ?? false
                    group.cancelAll()
                    return result
                }
                if removed { revoked[p] = account }
            }
            guard !Task.isCancelled, state.phase == .on, commits == c, engineEpoch == epoch, healthReset == reset,
                  store.accounts == accounts else { continue }
            for (p, account) in revoked {
                let name = Providers.get(p)?.name ?? p
                refusedAccounts[p] = (account, .removed(name))
            }
            var moved: [String: String] = [:]
            var stepped: Set<String> = []
            for id in routeIds {
                guard let route = setup.route(id), let link = links[id] else { continue }
                let p = route.loc.provider
                if case .wg(_, _, let ports, _) = link, ports.count > 1, Int(setup.opt(p, "port") ?? "") == nil { stepped.insert(p) }
                if route.loc.pinned == nil && route.loc.group != Nord.dedicatedIp { moved[id] = LinkPicker.serverKey(route, link) }
            }
            for p in stepped { portStep[p, default: 0] += 1 }
            if !moved.isEmpty || !stepped.isEmpty || !revoked.isEmpty {
                await reload(dead: moved, avoid: Set(moved.values), checked: c, healthAction: true, revokedAction: !revoked.isEmpty)
            }
        }
    }

    /// Provider tunnels, including pins and dedicated IPs, grouped by their current engine tag.
    private func healthExits() -> [String: [String: String]] {
        guard let s = running else { return [:] }
        var byTag: [String: [String: String]] = [:]
        for (id, link) in links {
            guard let route = s.route(id), !route.imported, let tag = tags[id], !tag.isEmpty, tag != Compiler.tsTag else { continue }
            byTag[tag, default: [:]][id] = LinkPicker.serverKey(route, link)
        }
        return byTag
    }

    private func closeTailscaleWatch() {
        tsStatus = nil
        tsRepair?.cancel(); tsRepair = nil
        enrolment.clear()
        enrolmentChecks.forEach { $0.cancel() }
        enrolmentChecks = []
        tsGeneration += 1
        tsRetry?.cancel(); tsRetry = nil
        tsWatch?.close(); tsWatch = nil
    }

    /// Failed subscriptions get one cancellable retry, independent of configuration observation.
    private func retryTailscale() {
        let g = tsGeneration
        tsRetry = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard g == tsGeneration else { return }
            tsRetry = nil
            watchTailscale()
        }
    }

    private func watchTailscale() {
        guard state.phase == .on, running?.tailscale == true else {
            if tsWatch != nil || tsRetry != nil { closeTailscaleWatch() }
            forgetTailscaleState()
            return
        }
        guard tsWatch == nil, tsRetry == nil else { return }
        tsGeneration += 1
        let g = tsGeneration
        // Refused, unanswered or dropped (the connection, or the extension's own subscription to the engine): closed and
        // retried. Opening and closing never wait on the extension.
        let lost: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, g == self.tsGeneration else { return }
                self.closeTailscaleWatch()
                // One drop can be a blip; once the retry fails too, what is on screen is no longer Tailscale's state.
                self.tsLost += 1
                if self.tsLost >= 2 { self.forgetTailscaleState() }
                self.retryTailscale()
            }
        }
        let handler = TailscaleHandler({ [weak self] u in
            Task { @MainActor in
                guard let self, g == self.tsGeneration, self.state.phase == .on else { return }
                self.tailscale(u)
            }
        }, lost: lost)
        tsWatch = EngineLink.subscribe(handler, lost: lost) { $0.subscribeTailscale(reply: $1) }
    }

    /// Tailscale's last status as received: its state, the exit node in use (stable id, nil for none) and when it came.
    /// Nil while there is none to go by (the watch closed or lost).
    private(set) var tsStatus: (state: String, exitNode: String?, at: ContinuousClock.Instant)?
    private var tsRepairedAt: ContinuousClock.Instant?
    private var tsRepair: Task<Void, Never>?

    /// Whether Tailscale's last status shows exit node [id] ("" = none) in use; nil without a Running status received
    /// after [after] (one from before a change says nothing about it).
    func tsShows(_ id: String, after: ContinuousClock.Instant?) -> Bool? {
        guard let s = tsStatus, s.state == "Running", after.map({ s.at > $0 }) ?? true else { return nil }
        return (s.exitNode ?? "") == id
    }

    /// The status shows an exit node the running configuration doesn't route through (a speed test's switch that landed
    /// late, after the switch back, or after a relaunch): put back, at most every 10 s (one held back then is looked at
    /// again when that has passed: an unchanged status isn't sent again). When the routed node isn't listed, only a node
    /// that is listed under another address is known to be wrong.
    private func offRoute(_ u: TailscaleUpdate) -> Bool {
        guard let s = running else { return false }
        switch Lifecycle.offRoute(tailscale: s.tailscale, exit: s.tsExit, used: u.exitNode, nodes: u.nodes.map { ($0.id, $0.ip) },
                                  repairedAt: tsRepairedAt, now: .now) {
        case .fine: return false
        case .repair:
            tsRepairedAt = .now
            return true
        case .later(let wait):
            let g = tsGeneration
            tsRepair?.cancel()
            tsRepair = Task {
                do { try await Task.sleep(for: wait) } catch { return }
                guard g == tsGeneration, state.phase == .on, tsStatus?.state == "Running", !SpeedTest.shared.testingNode else { return }
                tsRepairedAt = .now
                await SpeedTest.shared.restoreNode()
            }
            return false
        }
    }

    /// What the statuses say about the node's sealed identity (`TsEnrolment`), and the checks it asked for.
    private var enrolment = TsEnrolment()
    private var enrolmentChecks: [Task<Void, Never>] = []

    /// Every status, whether or not it changes what shows: the auth key leaves the configuration once the node is
    /// enrolled, and setup.bin once that held up; enrolment is forgotten when the identity stops working.
    private func enrol(_ u: TailscaleUpdate) {
        let h = store.setup.home
        let control = h.tsControlUrl.map { TsLogin.controlUrl($0) ?? "" }
        let g = tsGeneration, op = generation
        for action in enrolment.update(state: u.backendState, sealed: u.sealed, enrolled: h.tsEnrolled, hasKey: h.tsAuthKey != nil,
                                       control: control, now: .now) {
            switch action {
            case .enrol(let id):
                // A configuration without the key follows (a reload, sealed again), and the identity is read back with it.
                Log.info("tailscale: node enrolled, the auth key leaves the configuration")
                store.update { $0.home.tsEnrolled = id }
            case .checkKey: enrolmentChecks.append(Task { await dropKeyLater(g, op) })
            case .checkLogin: enrolmentChecks.append(Task { await loginLater(g, op) })
            }
        }
    }

    /// The key goes once the enrolled identity, read back from the seal, has held for `TsEnrolment.keep`, and the copy
    /// Connect on Demand starts was made without it (an unattended start never needs it then).
    /// [g], [op]: the status watch and the operation it was seen under (a sign-out or server change bumps the latter at once).
    private func dropKeyLater(_ g: Int, _ op: Int, tries: Int = 0) async {
        do { try await Task.sleep(for: TsEnrolment.keep) } catch { return }
        let id = store.setup.home.tsEnrolled
        func still() -> Bool {
            g == tsGeneration && op == generation && store.setup.home.tsEnrolled == id && enrolment.mayDropKey(id, now: .now)
                && store.setup.home.tsAuthKey != nil
        }
        guard still() else { return }
        // The copy Connect on Demand starts must be one made for this enrolment (so without the key). Not known (no record,
        // or it couldn't be read): asked again a few times; another identity on record: the key stays.
        let sealed = await Running.sealed()
        guard still() else { return }
        guard let sealed else {
            if tries < 3 { enrolmentChecks.append(Task { await dropKeyLater(g, op, tries: tries + 1) }) }
            return
        }
        guard sealed.home.tsEnrolled == id else { return }
        Log.info("tailscale: enrolment held, the auth key is no longer kept")
        store.update { $0.home.tsAuthKey = nil }
    }

    /// A login wanted for `TsEnrolment.lost` while enrolled: the sealed identity doesn't work any more. Forgotten, so a key
    /// still kept enrols the node again (looked at again in as long); without one, or if that didn't help either, the user
    /// signs in (told once).
    private func loginLater(_ g: Int, _ op: Int) async {
        do { try await Task.sleep(for: TsEnrolment.lost) } catch { return }
        guard g == tsGeneration, op == generation else { return }
        let (lost, tell) = enrolment.isLost(now: .now)
        guard lost else { return }
        if store.setup.home.tsEnrolled != nil {
            Log.info("tailscale: the enrolled identity wants a login, enrolment forgotten")
            store.update { $0.home.tsEnrolled = nil }
            if store.setup.home.tsAuthKey != nil {
                enrolment.retry(now: .now)
                enrolmentChecks.append(Task { await loginLater(g, op) })
                return
            }
        }
        if tell { Notifier.post(title: "Tailscale needs you to sign in again", body: "Open unbraid to sign this Mac in to its tailnet.") }
    }

    /// Shown only while it is current: a status nothing updates any more is no status.
    private func forgetTailscaleState() {
        tsStatus = nil
        if state.phase != .on || running?.tailscale != true { tsLoginPending = false }
        tsLost = 0
        guard state.tsState != nil || state.tsLoginUrl != nil || !state.tsExitNodes.isEmpty else { return }
        state.tsState = nil; state.tsLoginUrl = nil; state.tsExitNodes = []
    }

    private var tsLoginPending = false

    private func tailscale(_ u: TailscaleUpdate) {
        let pending = TsLogin.pending(authURL: u.authURL, backend: u.backendState, was: tsLoginPending)
        if pending != tsLoginPending {
            tsLoginPending = pending
            if state.phase == .on { Task { await reconcile() } }
        }
        tsLost = 0
        tsStatus = (u.backendState, u.exitNode, .now)
        enrol(u)
        // Status arrives often with only peer counters changed: write the state, and so redraw, only when it differs.
        var t = state
        t.tsLoginUrl = u.authURL
        t.tsState = u.backendState
        t.tsExitNodes = u.nodes
        if t != state { state = t }
        if u.backendState == "Running", !SpeedTest.shared.testingNode, store.tsTestNode || offRoute(u) { Task { await SpeedTest.shared.restoreNode() } }
        // The tailnet's own domain is only known once signed in: reload once so DNS routes it to Tailscale.
        // A domain the check now refuses (saved before it existed, or reported by a server) is dropped, not kept.
        let suffix = Compiler.tsSuffix(u.suffix)
        if suffix != store.tsSuffix, suffix != nil || Compiler.tsSuffix(store.tsSuffix) == nil { store.tsSuffix = suffix }
    }

    // MARK: Helpers

    private struct BlockedPick: LocalizedError {
        var blocked: [String: LinkPicker.Blocked]
        var errorDescription: String? { blocked.values.first?.text ?? "Could not connect" }
    }

    private func pickLinks(_ s: Setup, accounts: [String: String]) async throws -> LinkPicker.Result {
        refusedAccounts = refusedAccounts.filter { accounts[$0.key] == $0.value.account }
        let refused = refusedAccounts.mapValues(\.reason)
        removedPins.update(store.setup, accounts: store.accounts)
        let r = try await LinkPicker.pick(s, keep: [:], applied: applied, appliedAccounts: appliedAccounts, accounts: accounts,
                                          last: await store.lastLinks(), avoid: failing, refused: refused, gone: removedPins, portStep: portStep, providers: Providers.get)
        return try acceptPick(r, setup: s, accounts: accounts, allowBlocked: false)
    }

    private func acceptPick(_ r: LinkPicker.Result, setup s: Setup, accounts: [String: String], allowBlocked: Bool) throws -> LinkPicker.Result {
        removedPins.remember(r.blocked, setup: s, accounts: accounts)
        removedPins.update(store.setup, accounts: store.accounts)
        for (id, reason) in r.blocked {
            guard case .refused = reason, let route = s.route(id), let account = accounts[route.loc.provider],
                  store.accounts[route.loc.provider] == account else { continue }
            refusedAccounts[route.loc.provider] = (account, reason)
        }
        if !allowBlocked && !s.activeRoutes.isEmpty && r.blocked.count == s.activeRoutes.count {
            throw BlockedPick(blocked: r.blocked)
        }
        store.rememberLinks(r.remember, from: accounts)
        return r
    }

    private func makeInput(_ s: Setup, _ links: [String: Link], blocked: Set<String> = [], probe: (port: Int, password: String)?) -> Compiler.Input {
        Compiler.Input(setup: s, links: links, portStep: portStep, blocked: blocked, apps: AppCatalog.shared.patterns(for: AppCatalog.shared.routingKeys(s)), remembered: AppCatalog.shared.remembered(Array(s.apps.keys)),
                       // The app's own executable, not its bundle: anything else placed inside it doesn't go direct.
                       selfPattern: Compiler.pattern(forPath: Bundle.main.executablePath ?? Bundle.main.bundlePath), tsSuffix: store.tsSuffix, probe: probe, ownerless: .refusedWhileSplit, tsLoginPending: tsLoginPending)
    }

    /// What the paused engine is built from now (`PauseKey`).
    private func pauseKey() -> PauseKey {
        let input = makePausedInput()
        return PauseKey(input, search: search(input))
    }

    private func makePausedInput() -> Compiler.Input {
        let s = store.setup
        var prefs = s.prefs
        // The pause drops the home tunnels, so the engine can't tell a remote home's subnets from this network: blocked apps
        // get no LAN allowance meanwhile (the profile is the same at both levels, so this needs no restart).
        if s.home.wg != nil || (s.home.tailscale && !s.home.subnets.isEmpty), prefs.killLevel == .internet { prefs.killSwitchHome = true }
        let paused = Setup(routes: [], defaultRoute: DIRECT, apps: s.apps.filter { $0.value == BLOCK }, favorites: [], prefs: prefs)
        var input = makeInput(paused, [:], probe: nil)
        // Every app's patterns, though only blocks are routed: an app here inside a blocked bundle that is only remembered
        // is refused by that bundle's rule, so the pause keeps the guards of a block (see `Compiler.Input.remembered`).
        let keys = Array(s.apps.keys)
        (input.apps, input.remembered) = (AppCatalog.shared.patterns(for: keys), AppCatalog.shared.remembered(keys))
        return input
    }

    /// A free loopback port and a 24-byte random password for the app's own way into each exit.
    private func newProbe() -> (port: Int, password: String) {
        let port = Self.freePort(from: Int.random(in: 20_000..<60_000))
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let password = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return (port, password)
    }

    /// The first loopback TCP port at or after `start` that is free to listen on, as libbox's AvailablePort found it (0 if
    /// none is, as it left it then).
    private nonisolated static func freePort(from start: Int) -> Int {
        for port in start...65_535 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return 0 }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            } == 0
            if bound && listen(fd, 1) == 0 { return port }
            if errno != EADDRINUSE { return 0 }
        }
        return 0
    }

    /// Up to 15 s for the tunnel to come up. Right after the start request it still reads "disconnected", so only a
    /// drop after it began connecting counts as a failure (with the extension's reason).
    private func waitConnected() async throws {
        var began = false
        for _ in 0..<150 {
            switch tunnel.status {
            case .connected: return
            case .connecting, .reasserting: began = true
            case .disconnected where began, .invalid where began:
                let error = await tunnel.disconnectError()
                try Task.checkCancellation()
                throw Fail(error ?? "Could not connect")
            default: break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Fail("The VPN didn't come up. Check that unbraid is allowed in System Settings › General › Login Items & Extensions.")
    }

    /// The app was restarted while the tunnel kept running: take over what it runs, so later changes keep its servers.
    /// The extension is active: take over a tunnel that kept running, or, after an update stopped it, reconnect if the
    /// user had been connected (the running record survives every stop except the user's own).
    /// [since]: asked again (put off after an update, `ReplacedReady`, or waiting for the keychain) under that generation:
    /// an operation made since owns it, and it isn't put off again. [replacement]: the one it was asked for, if not now's.
    private func extensionReady(replaced: Bool, since: Int? = nil, replacement: Int? = nil) async {
        // Whatever it decides, Connect on Demand is looked at while off without waiting for it from now on
        // (`holdOnDemandSoon`).
        defer { readyChecked = true }
        if let since, since != generation { return }
        let r = tunnel.replacements
        if let replacement, replacement != r { return }
        // After an update, only once the tunnel macOS stops for it is down and a takeover of it over (`ReplacedReady`):
        // asked again then (`statusChanged`).
        if replaced, since == nil, !replacedReady.ready(adopting: adopting, status: Self.status(tunnel.status), generation,
                                                                replacement: r) {
            Log.info("update: reconnect decided once the old tunnel is down")
            if tunnel.status == .connected { await statusChanged() }
            return
        }
        if tunnel.status == .connected { await statusChanged(); return }
        // A fallback a previous session left, once Connect on Demand is off.
        if fallbackHint { _ = try? await exclusive { await retireFallback() } }
        // The extension is reachable again: finish an erase a sign-out couldn't, checked again once the queue is ours.
        // Pending at this point, it may be a sign-out a quit interrupted, which can have left its accounts behind: no
        // automatic reconnect then, even once erased.
        let interrupted = store.extensionWipePending
        if interrupted {
            let g = generation
            // The erase turns Connect on Demand off before the copy goes (`erasePending`).
            _ = try? await exclusive {
                guard store.extensionWipePending, state.phase == .off, tunnel.status != .connected else { return }
                // One that fails is tried again with the owed settling (this launch's reconnect stays off either way).
                let outcome = try? await erasePendingNoted()
                if outcome != .erased, outcome != .deferred { eraseLeft = true; settleLater() }
            }
            // Whatever the erase did: on only with something left to start (`holdOnDemandIdle` queues itself).
            await holdOnDemandIdle(g)
        }
        let g = generation
        if let since, since != g { return }
        // Connect on Demand's state is read from the VPN profile, which may still be loading.
        if !replaced { try? await tunnel.initialize() }
        // Reconnected after an update replaced the extension, or checked for a sealed copy it no longer starts.
        guard g == generation, !interrupted, state.phase == .off, store.pause == nil, !store.extensionWipePending,
              replaced || !resealChecked && tunnel.profile?.onDemand == true else { return }
        // A record the keychain won't open yet may be perfectly fine: asked again every 30 s until it opens (Connect
        // refuses stand-ins anyway).
        store.reloadHeld()
        let read = await Running.read()
        guard g == generation, state.phase == .off, store.pause == nil, !store.extensionWipePending, tunnel.status != .connected else { return }
        var record: Running.State?, kind = Lifecycle.RecordRead.none
        switch read {
        case .none: break
        case .locked: kind = .locked
        case .record(let r): record = r; kind = .record
        }
        let recorded = await Running.stopped()
        guard g == generation, state.phase == .off, store.pause == nil, !store.extensionWipePending, tunnel.status != .connected,
              tunnel.replacements == r else { return }
        // An update whose recovery ended (`ReplacedReady`: a tunnel after it came up and stopped, or the new extension runs
        // one): stopped, however this is asked (at once, put off, or once the keychain opens).
        let stopped = recorded || replaced && replacedReady.ended(r)
        switch Lifecycle.ready(replaced: replaced, read: kind, held: store.isHeld, provenance: record.map(provenance), stopped: stopped) {
        case .wake:
            // Whether Connect on Demand has anything to start needs no keychain: not left on with nothing meanwhile (and
            // said, since the reseal check that would have said so needs it on).
            if await holdOnDemandIdle(g), g == generation, state.phase == .off {
                state.error = "Connect on Demand is off until you connect once: " + Self.resealNone
            }
            wakeWhenHeld(g) { await self.extensionReady(replaced: replaced, since: g, replacement: r) }
        case .connect: await connect()
        case .reseal: await resealIfRefused(record, stopped: stopped, g)
        }
    }

    /// An update can make the extension refuse the copy an older version sealed (it runs only what this version writes):
    /// Connect on Demand then has nothing to start. Once per launch, while off with Connect on Demand on and no sealed copy
    /// left, connect (which seals again) when that is safe; otherwise turn it off, so macOS doesn't keep trying a start the
    /// extension refuses, and say how to get it back.
    private func resealIfRefused(_ record: Running.State?, stopped: Bool, _ g: Int) async {
        // Read from the system: after an update the profile may still be loading, and unknown isn't off.
        guard !resealChecked, await tunnel.onDemandOn() != false else { return }
        // Read before the extension is asked, so its answer is the latest thing known when deciding.
        let sealedBy = await Running.sealedBy(), previous = await launched?.value
        let engine = await tunnel.revisions().map(Self.engine)
        guard g == generation, state.phase == .off, store.pause == nil, !store.extensionWipePending, tunnel.status != .connected else { return }
        // No answer settles nothing: asked again a few times.
        resealTries += 1
        guard engine != nil || resealTries >= 3 else { return wakeWhenHeld(g) { await self.extensionReady(replaced: false) } }
        resealChecked = true
        // Connect on Demand is the Mac's, not this user's: another user may have left it on.
        let said: String?
        switch Lifecycle.reseal(engine: engine, ready: !store.isHeld, provenance: record.map(provenance), sealedBy: sealedBy, previous: previous,
                                build: Running.build, wanted: store.setup.prefs.alwaysOn, stopped: stopped) {
        case .none: said = nil
        case .connect: return await connect()
        case .tell(let updated): said = updated ? Self.resealRefused : Self.resealNone
        case .unknown: said = Self.resealUnknown
        }
        await holdOnDemandIdle(g)
        guard let said, g == generation, state.phase == .off else { return }
        state.error = (tunnel.profile?.onDemand == true ? "Connect on Demand can't start the VPN until you connect once: "
                       : "Connect on Demand is off until you connect once: ") + said
    }

    /// Off, with Connect on Demand on: left on, macOS would keep starting what the extension refuses (with the kill switch,
    /// keeping the Mac offline), so it goes off unless there is a copy to start (`Lifecycle.onDemandHold`), whoever's
    /// setting it is; a connect seals a copy and turns it on again. Decided in the queue, on what the extension says then.
    @discardableResult
    private func holdOnDemandIdle(_ g: Int) async -> Bool {
        (try? await exclusive {
            @MainActor func idle() -> Bool { g == generation && state.phase == .off && store.pause == nil && tunnel.status != .connected }
            guard idle(), await tunnel.onDemandOn() != false else { return false }
            let engine = await tunnel.revisions(timeout: 5).map(Self.engine)
            // A Connect made meanwhile decides it itself.
            guard idle() else { return false }
            return await hold(engine)
        }) ?? false
    }

    private var replacedReady = ReplacedReady()
    private var resealChecked = false
    private var resealTries = 0
    /// The extension was ready once this launch, and `extensionReady` looked at what it may reconnect or reseal.
    private var readyChecked = false
    private static let resealRefused = "the connection saved by the previous version of unbraid can't be used any more."
    private static let resealNone = "it has no saved connection of yours to start."
    private static let resealUnknown = "unbraid couldn't check its saved connection (the VPN extension didn't answer)."

    /// Takes over a tunnel that runs without this app having started it (a relaunch, Connect on Demand), with the
    /// setup as it is now: the record of what ran supplies its servers, kept where the route is unchanged, the account
    /// they were made with is still the one signed in, and the provider still vouches for them, so taking over moves no
    /// exit. Inside `exclusive` only. A failure stops the tunnel only if nothing would start it again; otherwise it keeps
    /// running and taking over is tried again later.
    private func adoptRunningTunnel() async {
        let g = generation
        // A sign-out asked the extension to erase what it runs: never take that over; stop it instead, once the extension
        // says the engine is this user's (`Lifecycle.interruptedSignOut`). Another user's tunnel (fast user switching) is
        // theirs: neither stopped nor taken over from here. The extension just proved reachable: erase now rather than at
        // the next start (we hold the queue here).
        if store.extensionWipePending, tunnel.ext == .ready || tunnel.ext == .unknown, tunnel.status == .connected,
           state.phase == .off || adopting {
            let r = await tunnel.revisions()
            let engine = r.map { Lifecycle.Engine(running: $0.running, durable: $0.durable, foreign: $0.foreign) }
            let on = r?.fallbackRunning == true ? await tunnel.onDemandOn() : false
            guard g == generation, store.extensionWipePending, tunnel.status == .connected, state.phase == .off || adopting else { return }
            // This user's fallback runs and Connect on Demand is (or may be) on: stopping it for the erase would only have
            // macOS start it again, offline meanwhile (`Lifecycle.eraseStop`). Left to the fallback's own handling below;
            // the erase follows with the owed settling, once it has stopped.
            if !Lifecycle.eraseStop(fallbackRunning: r?.fallbackRunning == true, durable: r?.durable != nil, onDemand: on) {
                eraseLeft = true
                settleLater()
            } else {
                switch Lifecycle.interruptedSignOut(engine: engine) {
                case .stop:
                    // Asked once more by the stop itself: another user's engine that took over meanwhile is left running. A
                    // stop whose Connect on Demand save failed still stopped: turning it off stays owed (the erase tries
                    // first).
                    let stopped: Bool?
                    do { stopped = try await tunnel.stop(userInitiated: true) } catch { stopped = nil; offLater() }
                    guard stopped != false else {
                        if adopting { stopAdopting(); state = VpnState() }
                        return
                    }
                    clearRunning()
                    recordRun { $0.stopped() }
                    stopAdopting()
                    let request = eraseRequest
                    // Tried again with the owed settling when it doesn't go through (`eraseOwed`).
                    if (try? await erasePendingNoted()) != .erased { eraseLeft = true; settleLater() }
                    guard g == generation else { return }
                    // Never silent: with the kill switch on, traffic now leaves outside the VPN. Notified once per
                    // request.
                    state = VpnState(error: Self.interruptedSignOut)
                    if interruptedNotified != request {
                        interruptedNotified = request
                        Notifier.post(title: "unbraid is off", body: Self.interruptedSignOut)
                    }
                    // On only with something left to start, whatever the erase did (inside the queue already).
                    await holdOnDemandNow()
                    return
                case .foreign:
                    recordRun { $0.foreign() }
                    // Another user's tunnel: theirs, never taken over or stopped from here; a takeover waiting is
                    // over. Their fallback is no VPN, and said so.
                    if adopting { stopAdopting(); state = VpnState() }
                    if r?.foreignFallback == true, state != VpnState(error: Self.othersFallbackRuns, runState: state.runState) { state = VpnState(error: Self.othersFallbackRuns) }
                    return
                case .wait:
                    // Kept running for want of the extension's word, never taken over: asked again in a minute at the
                    // latest.
                    adopting = true
                    let waiting = VpnState(phase: .connecting, error: Self.erasingSignedOut, runState: state.runState)
                    if state != waiting { state = waiting }
                    if adoptWake == nil { wakeAdoption(after: Self.probe, g) }
                    return
                }
            }
        }
        // The fallback runs (`sealFallbackIfStuck`): nothing of the user's, never taken over (a revocation would stop it, and
        // Connect on Demand start it again). Stopped once Connect on Demand is off; until then left running, and said.
        let classified = await tunnel.revisions(timeout: 5)
        guard g == generation, tunnel.status == .connected, state.phase == .off || adopting, store.pause == nil else { return }
        // Not known: never taken over (that would reload the user's setup, or revoke a fallback Connect on Demand only starts
        // again), asked again shortly.
        guard let classified else {
            adopting = true
            if state != VpnState(phase: .connecting, runState: state.runState) { state = VpnState(phase: .connecting) }
            return wakeAdoption(after: .seconds(30), g)
        }
        // The new extension runs it: what an update stopped is over (`ReplacedReady`).
        if classified.running != nil { replacedReady.over(replacement: tunnel.replacements) }
        if !adoptionObserved && !classified.foreign {
            adoptionObserved = true
            recordRun { $0.freshEngine() }
        }
        if classified.fallbackRunning {
            let on = await tunnel.onDemandOn()
            guard g == generation, tunnel.status == .connected, state.phase == .off || adopting, store.pause == nil else { return }
            stopAdopting()
            fallbackHint = true
            recordRun { $0.fallback() }
            switch Lifecycle.fallbackAdoption(onDemand: on) {
            case .stop:
                state = VpnState()
                await retireFallback()
            case .show:
                state = VpnState(error: Self.fallbackRuns)
                // Turning it off is owed (also when a record of that was lost): tried again until saved, which stops it.
                if !disarmPending && !offWanted { disarmLater() }
            }
            return
        }
        // Everything below reads the setup, the accounts and the record of what runs: stand-ins for files the keychain
        // wouldn't open yet (locked at launch) read as nothing set up and every account signed out. Until they open,
        // the tunnel is left as it is.
        store.reloadHeld()
        let read = await Running.read()
        guard g == generation else { return }
        var locked = store.isHeld, record: Running.State?
        switch read {
        case .locked: locked = true
        case .none: break
        case .record(let r): record = r
        }
        // Mid-update the old extension is going away: wait for the new one (`extensionReady`) instead of failing.
        guard tunnel.ext == .ready || tunnel.ext == .unknown, tunnel.status == .connected, state.phase == .off || adopting,
              store.pause == nil else { return }
        let foreign = await tunnel.runsForAnotherUser()
        guard g == generation, tunnel.status == .connected, state.phase == .off || adopting, store.pause == nil else { return }
        // Another user's tunnel (fast user switching): theirs, never taken over or stopped from here; a takeover this app
        // was waiting for is over.
        if foreign {
            recordRun { $0.foreign() }
            if adopting { stopAdopting(); state = VpnState() }
            // Their fallback: no VPN, and said so while it runs.
            if classified.foreignFallback, state != VpnState(error: Self.othersFallbackRuns, runState: state.runState) { state = VpnState(error: Self.othersFallbackRuns) }
            return
        }
        // Whenever asked, whether or not a retry is due: a waiting takeover never keeps a signed-out account running.
        if adopting, !locked, await revokeAdopted() { return }
        guard g == generation, locked || adoptRetry.allows(0, now: .now) else {
            // Given up: one that must not keep running is still looked at now and then, until the extension answers.
            if adopting, !locked, adoptWake == nil, revocation(record) != nil { wakeAdoption(after: Self.probe, g) }
            return
        }
        adopting = true
        if locked {
            // Not a failure: no error, no notification, no retry used up. Disconnect works meanwhile.
            if state != VpnState(phase: .connecting, runState: state.runState) { state = VpnState(phase: .connecting) }
            return wakeAdoption(after: .seconds(30), g)
        }
        state = VpnState(phase: .connecting)
        var admitted = false
        do {
            while true {
                let s = store.setup, accounts = store.accounts
                let made = record?.accounts.map { made in accounts.filter { made[$0.key] == Running.fingerprint($0.value) } } ?? [:]
                // No fallback to the last good tunnels: they aren't tied to an account, and these are sealed as the current
                // account's. A provider that can't be reached leaves the tunnel as it is, and taking over is retried.
                removedPins.update(store.setup, accounts: store.accounts)
                // Through `lookUp`: a newer operation (a Disconnect) cancels slow providers instead of waiting behind them.
                let r = try await lookUp(nil) {
                    try await LinkPicker.pick(s, keep: record?.links ?? [:], applied: record?.setup, appliedAccounts: made, accounts: accounts,
                                              last: [:], gone: self.removedPins, providers: Providers.get)
                }
                try Task.checkCancellation()
                guard g == generation else { return }
                guard s == store.setup, accounts == store.accounts else { continue }
                removedPins.remember(r.blocked, setup: s, accounts: accounts)
                // Adoption keeps its existing retry behavior when a route cannot be established.
                if !Lifecycle.acceptsTakeover(r.blocked, activeRoutes: s.activeRoutes.count) {
                    let reason = r.blocked.values.first(where: { if case .signedOut = $0 { return false }; return true }) ?? r.blocked.values.first
                    throw Fail(reason?.text ?? "Could not connect")
                }
                store.rememberLinks(r.remember, from: accounts)
                try Task.checkCancellation()
                guard g == generation else { return }
                guard s == store.setup, accounts == store.accounts else { continue }
                let input = makeInput(s, r.links, blocked: Set(r.blocked.keys), probe: newProbe())
                let compiled = await Self.compile(input)
                try Task.checkCancellation()
                guard g == generation else { return }
                guard current(input, accounts) else { continue }
                guard tunnel.status == .connected else {
                    let error = await tunnel.disconnectError()
                    guard g == generation else { return }
                    stopAdopting(); state = VpnState(error: error)
                    return
                }
                let json = try compiled.get()
                admitted = true
                try await apply(input, json, g, takeover: true)
                commit(input, json, accounts)
                guard g == generation else { return }
                stopAdopting()
                retry.clear()
                cancelResume()
                state = VpnState(phase: .on, since: tunnel.connectedSince ?? .now, servers: r.links.mapValues(\.server), blocked: r.blocked.mapValues(\.text))
                scheduleRoutes(r.blocked, revision: revision())
                settle(g)
                startWatching()
                return
            }
        } catch is StoppedMeanwhile {
            // The tunnel was stopped from outside while being taken over: ended as any stop from outside.
            guard g == generation else { return }
            let error = await tunnel.disconnectError()
            guard g == generation else { return }
            stopAdopting()
            await teardown(error: error ?? "The VPN was turned off by macOS", g)
        } catch {
            guard g == generation else { return }
            let failure = message(error, "Could not take over the running VPN")
            let foreign = TunnelControl.foreign(error)
            // Nothing is stopped below without the extension's word that the engine is this user's (see
            // `Lifecycle.takeoverFailure`): asked on the engine's own queue, after the failure.
            let engine = foreign ? nil : await tunnel.revisions().map { Lifecycle.Engine(running: $0.running, durable: $0.durable, foreign: $0.foreign, fallbackRunning: $0.fallbackRunning) }
            let blocker = await Running.blocker()
            guard g == generation else { return }
            // A switch can be refused during takeover. The earlier engine is usable for rollback only when the
            // extension confirms the exact user engine recorded at the switch and its accounts are still vouched for.
            if error is Refused, let pending = store.setup.pendingSwitch, let previous = pending.previous,
               let engine, pending.confirmsPrevious(engine: engine.running, foreign: engine.foreign, fallback: engine.fallbackRunning,
                    trusted: provenance(record) == .same && unvouched(record) == nil && !store.isHeld) {
                var ran = store.setup
                ran.profile = previous.name.isEmpty ? nil : previous.name
                ran.defaultRoute = previous.defaultRoute
                ran.apps = previous.apps
                recordRun { $0.committed(revision: RunState.revision(ran), setup: ran, fresh: true) }
                recordRun { $0.refused(revision: RunState.revision(store.setup), setup: store.setup) }
            }
            switch Lifecycle.takeoverFailure(foreign: foreign, provenance: provenance(record), unvouched: unvouched(record) != nil, admitted: admitted,
                                             unstaged: error is TunnelControl.Unstaged, onDemand: tunnel.profile?.onDemand == true, engine: engine,
                                             blocker: blocker) {
            case .leave:
                // Another user's tunnel: theirs, not this app's to take over or stop.
                stopAdopting()
                state = VpnState()
            case .revoke(let why):
                stopAdopting()
                // Never left running (nor sealed for on-demand): it may run an account signed out or replaced since, a
                // server its provider no longer vouches for (a Proton key the bundled snapshot dropped, an address without
                // a public IP), or nothing says which account it runs (no record, or an older version's without
                // fingerprints).
                await teardown(error: revoked(why, record, failure: failure), revoke: true, g)
            case .stop:
                stopAdopting()
                await teardown(error: failure, g)
            case .retry(let disrupted):
                let first = adoptRetry.key == nil
                adoptWake?.cancel(); adoptWake = nil
                // An attempt that may have stopped and restarted the tunnel counts towards giving up: after a few, the
                // tunnel is left as it runs (a sign-out still ends it) rather than interrupted every few minutes for good.
                guard let wait = adoptRetry.failed(0, disrupted: disrupted, now: .now) else {
                    state = VpnState(phase: .connecting, error: "\(failure) Not tried again: Disconnect, then connect again.")
                    // Kept only for want of the extension's answer: asked again until it comes (`revokeAdopted`).
                    if revocation(record) != nil { wakeAdoption(after: Self.probe, g) }
                    return
                }
                state = VpnState(phase: .connecting, error: "\(failure) Trying again shortly.")
                if first { Notifier.post(title: "unbraid couldn't take over the VPN", body: failure) }
                wakeAdoption(after: wait, g)
            }
        }
    }

    /// How often a given-up takeover of a tunnel that must not keep running asks the extension again.
    private static let probe: Duration = .seconds(60)

    /// Asks again later whether to take over (a retry, or the keychain opening): one wake at a time.
    private func wakeAdoption(after wait: Duration, _ g: Int) {
        adoptWake?.cancel()
        adoptWake = Task {
            do { try await Task.sleep(for: wait) } catch { return }
            guard g == generation else { return }
            adoptWake = nil
            await statusChanged()
        }
    }

    /// Which accounts a running tunnel uses, as far as its record says (see `Lifecycle.provenance`).
    private func provenance(_ record: Running.State?) -> Lifecycle.Provenance {
        Lifecycle.provenance(record.map { ($0.setup, Set($0.links.keys), $0.accounts) }, accounts: store.accounts, fingerprint: Running.fingerprint)
    }

    /// The name of a provider route in [record] whose server its provider doesn't vouch for any more; nil when none.
    private func unvouched(_ record: Running.State?) -> String? {
        guard let record else { return nil }
        return record.setup.activeRoutes.first { route in
            guard !route.imported, let l = record.links[route.id] else { return false }
            guard let p = Providers.get(route.loc.provider), LinkPicker.dialable(l), p.vouches(l) else { return true }
            guard let account = store.accounts[p.id] else { return false }
            return !p.trusts(l, account)
        }?.name
    }

    /// Why a tunnel waiting to be taken over must not keep running, as its record says now (see `Lifecycle.revocation`).
    private func revocation(_ record: Running.State?) -> Lifecycle.Revocation? {
        Lifecycle.revocation(provenance: provenance(record), unvouched: unvouched(record) != nil, failed: adoptRetry.key != nil)
    }

    private func revoked(_ why: Lifecycle.Revocation, _ record: Running.State?, failure: String) -> String {
        switch why {
        case .signedOut: Self.signedOut
        case .unvouched: "\(unvouched(record) ?? "A route"): this version of unbraid can't vouch for its server. Connect again."
        case .unknown: "\(failure) unbraid can't tell which account the running VPN uses, so it asked macOS to turn it off. Connect again."
        }
    }

    /// While a takeover waits: a tunnel that must not keep running (`revocation`) ends now, once the extension confirms
    /// it runs this user's engine; another user's ends the wait. True when the takeover is over. Never on stand-ins for
    /// files the keychain wouldn't open yet. Inside `exclusive` only.
    private func revokeAdopted() async -> Bool {
        let g = generation
        // Nothing to go by while the keychain won't open the setup or the record: looked at again later.
        func later() -> Bool {
            if adoptWake == nil { wakeAdoption(after: Self.probe, g) }
            return false
        }
        store.reloadHeld()
        guard adopting else { return false }
        guard !store.isHeld else { return later() }
        let read = await Running.read()
        var record: Running.State?
        switch read {
        case .locked: return g == generation && adopting ? later() : false
        case .none: break
        case .record(let r): record = r
        }
        guard adopting, g == generation else { return false }
        guard !store.isHeld else { return later() }
        guard revocation(record) != nil else { return false }
        // Only once the extension says the engine is this user's: its ownership check gives up after seconds, and another
        // user's tunnel is never stopped from here. Until it answers, the takeover keeps waiting and this is asked again,
        // in a minute at the latest (nothing else may ask: a sign-out, say, while the takeover was given up).
        let engine = await tunnel.revisions().map { Lifecycle.Engine(running: $0.running, durable: $0.durable, foreign: $0.foreign) }
        guard g == generation, adopting else { return false }
        // Asked again after the wait: an account signed in again meanwhile may have settled it.
        store.reloadHeld()
        // The deny-all a failed change left running holds no account: nothing to revoke while it runs.
        let blocker = engine?.running == nil ? nil : await Running.blocker()
        guard g == generation, adopting else { return false }
        switch Lifecycle.adoptedRevocation(engine: engine, held: store.isHeld, blocker: blocker, revocation: revocation(record)) {
        case .wait: return false
        case .probe: return later()
        case .leave:
            stopAdopting()
            state = VpnState()
            return true
        case .revoke(let why):
            stopAdopting()
            await teardown(error: revoked(why, record, failure: "unbraid couldn't take over the running VPN."), revoke: true, g)
            return true
        }
    }

    private func stopAdopting() {
        adopting = false
        adoptRetry.clear()
        adoptWake?.cancel(); adoptWake = nil
    }

    private func message(_ e: Error, _ fallback: String) -> String {
        // For support, only the app's own words (see `Diagnostics.failureKind`).
        Diagnostics.noteFailure(Diagnostics.failureKind(fallback), e)
        return switch e {
        case let f as Fail: Redact.clean(f.errorDescription).nilIfEmpty ?? fallback
        case let a as AuthError: a.errorDescription ?? fallback
        case is URLError: "Couldn't reach the server. Check the connection."
        default: Redact.clean((e as NSError).localizedDescription).nilIfEmpty ?? fallback
        }
    }
}

struct TailscaleUpdate: Sendable {
    var authURL: String?
    var backendState: String
    var suffix: String
    var nodes: [TsNode]
    /// The exit node in use (stable id), also when it isn't among `nodes`; nil for none.
    var exitNode: String?
    var sealed: EngineWire.Tailscale.SealedIdentity?
}

/// Receives the engine's Tailscale status from the extension, on XPC's queue, and hands a plain value over.
nonisolated final class TailscaleHandler: NSObject, EngineEventsProtocol, @unchecked Sendable {
    private let onUpdate: @Sendable (TailscaleUpdate) -> Void
    private let onLost: @Sendable () -> Void
    init(_ onUpdate: @escaping @Sendable (TailscaleUpdate) -> Void, lost: @escaping @Sendable () -> Void) { self.onUpdate = onUpdate; onLost = lost }

    func tailscale(_ data: Data) {
        guard let u = try? JSONDecoder().decode(EngineWire.Tailscale.self, from: data) else { return }
        onUpdate(TailscaleUpdate(authURL: u.authURL, backendState: u.backendState, suffix: u.suffix,
                                 nodes: u.nodes.map { TsNode(name: $0.name, ip: $0.ip, online: $0.online, id: $0.id) }, exitNode: u.exitNode, sealed: u.sealed))
    }

    func connectionEvents(_ data: Data) {}
    func status() {}
    func logs(_ lines: [String]) {}
    func lost() { onLost() }
}
