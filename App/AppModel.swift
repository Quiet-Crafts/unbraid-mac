import Accessibility
import AppKit
import Observation

/// Everything the screens do to the setup, in one place. Thin: state lives in Store and Connection.
@Observable
final class AppModel {
    static let shared = AppModel()

    let store = Store.shared
    let vpn = Connection.shared
    let apps = AppCatalog.shared

    var setup: Setup { store.setup }
    var accounts: [String: String] { store.accounts }
    /// Server catalogue per provider id.
    private(set) var countries: [String: [Country]] = [:]
    private(set) var catalogDates: [String: Int64] = [:]
    private(set) var catalogFailures: Set<String> = []
    private(set) var signedInAt: [String: Date] = [:]
    /// Provider ids with a sign-in in flight, and the last error per provider.
    private(set) var signing: Set<String> = []
    var formError: [String: String] = [:]
    var formErrorURL: [String: String] = [:]
    var challenges: [String: Challenge] = [:]
    private var forms = SignInForms()

    func providerFormVersion(_ id: String) -> Int { forms.version(id) }

    #if DEBUG
    func acceptDisclosureForPerf() { disclosure = false; refreshApps() }
    func refreshAppsForPerf() { refreshApps(changed: true) }
    /// The test copy's made-up server lists: it never asks a provider for one.
    func seedCountriesForPerf(_ provider: String, _ list: [Country]) { countries[provider] = list }
    #endif

    func closeProviderForm(_ id: String) {
        forms.close(id)
        formError[id] = nil
        formErrorURL[id] = nil
        challenges[id] = nil
    }
    /// Something sign-out couldn't finish and the user must do by hand; shown in Settings.
    var notice: String?
    var disclosure = false
    private var connectAfterDisclosure = false
    private var refreshing: Set<String> = []
    @ObservationIgnored private var rescans = Rescans()
    @ObservationIgnored private var appsSoon: Task<Void, Never>?
    @ObservationIgnored private var retries = Retries()
    /// The scan a bundle the last one couldn't read is waiting for.
    @ObservationIgnored private var retry: (due: Date, task: Task<Void, Never>)?
    @ObservationIgnored private var running: NSKeyValueObservation?
    /// Bumped by Sign Out of Everything: a sign-in still waiting on its provider is then dropped, not stored.
    @ObservationIgnored private var signOutEpoch = 0
    /// Bumped by every sign-out or Tailscale server change: one still waiting on the VPN gives way to a newer one
    /// instead of writing its old values back after it.
    @ObservationIgnored private var identityEpoch = 0
    @ObservationIgnored private var signingOutAll = false
    /// The last account went while another sign-in was under way: the reset waits for its outcome.
    @ObservationIgnored private var resetWaiting = false
    /// Releases started (provider and digest of the account blob): a second caller waits for the first's outcome.
    @ObservationIgnored private var releases: [String: Task<Bool, Never>] = [:]
    /// Accounts (their blobs) whose sign-out is under way.
    @ObservationIgnored private var signingOut: Set<String> = []

    /// Signed in to at least one provider, or holding something else to route through (Home WireGuard included).
    var signedIn: Bool { setup.hasExit(signedIn: !accounts.isEmpty) }

    private init() {
        for p in Providers.all { countries[p.id] = store.countries(p.id); catalogDates[p.id] = store.catalogDate(p.id) }
        // The bundled lists are hashed and parsed once, on first use: done here off the main thread, so a first use on it
        // at launch (taking over a running tunnel) rarely waits for that. Best effort.
        Task.detached(priority: .utility) { _ = try? Catalog.Source.proton.pinned(); _ = try? Catalog.Source.express.pinned() }
        disclosure = !store.disclosed || !store.termsAccepted
        NotificationCenter.default.addObserver(forName: AirVpn.cleanupRefused, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.warn("AirVPN didn't accept the API key for a device unbraid added. Remove it in the AirVPN Client Area.") }
        }
        retryAirCleanup()
        refreshApps()
        watchProfileSwitch()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            // Also where a setup saved with apps blocked and no kill switch gets its question, once, when the user is here.
            MainActor.assumeIsolated { AppModel.shared.store.reloadHeld(); AppModel.shared.refreshApps(); AppModel.shared.askBlockScope() }
        }
        // A menu bar app can go days without being activated. A routed app started from a copy its patterns miss
        // (agents and background apps included, which launch notifications leave out), an app installed, removed or
        // moved, or a disk mounted or ejected, is picked up when it happens.
        // Not isolated to the main actor: the list changes on the main run loop, but KVO calls on whichever thread made a
        // change, so this mustn't trap if one ever comes from elsewhere. Only plain values cross to main, in order.
        running = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { @Sendable _, change in
            let started = (change.newValue ?? []).compactMap { a in a.bundleIdentifier.flatMap { id in a.bundleURL.map { (id, $0, a.executableURL) } } }
            DispatchQueue.main.async { MainActor.assumeIsolated { for (id, url, exe) in started { AppModel.shared.launched(id, url, exe) } } }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.appsChanged() }
            }
        }
        apps.onChange = { AppModel.shared.appsChanged() }
        // A menu bar app can stay open for days; check the daily catalogue cache each hour.
        Task {
            while !Task.isCancelled {
                for id in accounts.keys where !store.countriesFresh(id) { refreshCountries(id) }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    // MARK: Providers

    /// Signs in with `input` as typed (secrets are never trimmed). The outcome lands in `formError` or `accounts`.
    func signIn(_ provider: any Provider, _ input: [String: String], formVersion: Int? = nil, clipboardImageChangeCount: Int? = nil) async {
        let id = provider.id
        let formVersion = formVersion ?? forms.version(id)
        func showError(_ error: String?, url: String? = nil) {
            if forms.version(id) == formVersion { formError[id] = error; formErrorURL[id] = url }
        }
        guard !signing.contains(id) else { return }
        // Sign Out of Everything lists the accounts as it starts: one added meanwhile would be deleted but never released.
        if signingOutAll { showError("Signing out of everything. Try again in a moment."); return }
        // The keychain wouldn't open at launch, so what shows is a stand-in that the real accounts replace once it does:
        // a sign-in now would register a device slot and then be lost without being released. The real accounts come
        // first if the keychain answers now, so one already signed in is found below.
        store.reloadHeld()
        if store.isHeld {
            showError("unbraid can't read its keychain right now, so this sign-in couldn't be saved. Unlock the keychain, then try again.")
            return
        }
        if accounts[id] != nil { showError("Already signed in to \(provider.name)"); return }
        showError(nil)
        signing.insert(id)
        defer {
            signing.remove(id)
            if resetWaiting, signing.isEmpty { resetWaiting = false; resetIfEmpty() }
        }
        do {
            var clean = Dictionary(uniqueKeysWithValues: provider.fields.map { f in
                (f.key, f.secret ? input[f.key] ?? "" : (input[f.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            })
            if let challenge = challenges[id] {
                clean.merge(challenge.state) { _, new in new }
                clean[challenge.field.key] = challengeAnswer(challenge.field, input[challenge.field.key] ?? "")
            }
            let epoch = signOutEpoch
            let blob = try await provider.signIn(clean)
            // Sign Out of Everything ran meanwhile: this session is released, never stored behind it, and the user is told.
            guard epoch == signOutEpoch else {
                let undone = "You signed out of everything while signing in to \(provider.name), so that sign-in was undone. Sign in again to use it."
                showError(undone)
                warn(undone)
                if !(await release(provider, blob)) { unreleased([provider.name]) }
                return
            }
            challenges[id] = nil
            guard forms.version(id) == formVersion else {
                if !(await release(provider, blob)) { unreleased([provider.name]) }
                return
            }
            store.afterSave("accounts") { [weak self] in
                input.values.forEach { self?.clearClipboardIf($0) }
                if let count = clipboardImageChangeCount, NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
            }
            store.account(id, blob)
            signedInAt[id] = .now
            releases[releaseKey(id, blob)] = nil
            vpn.forgetRefusal(id)
            // First provider on a fresh install: point the default route at it. A default whose provider is signed out, or
            // being signed out right now (its sign-out waits on the VPN), moves to this one.
            let leaving = { (p: String) in self.accounts[p].map { self.signingOut.contains($0) } ?? true }
            store.update { s in
                if s.routes.isEmpty { s.routes = [Route(id: "main", loc: Location(provider: id))]; s.defaultRoute = "main" }
                else if let d = s.route(s.defaultRoute), !d.imported, leaving(d.loc.provider),
                        let i = s.routes.firstIndex(where: { $0.id == d.id }) { s.routes[i].loc = Location(provider: id) }
            }
            refreshCountries(id)
        } catch let challenge as Challenge {
            if forms.version(id) == formVersion { challenges[id] = challenge }
        } catch {
            if forms.version(id) == formVersion { challenges[id] = nil }
            showError(signInFailure(error, provider.name), url: (error as? AuthError)?.url)
        }
    }

    /// Forgets one provider's account; routes and app choices stay (its routes wait for a sign-in). The last way out:
    /// the VPN stops first, so the running engine isn't torn down with a "sign in again" alert.
    /// The last way out also erases the extension's sealed copy, which still holds this account's keys.
    func signOut(_ provider: String) {
        // A second click while the first waits on the VPN does nothing.
        guard let blob = accounts[provider], signingOut.insert(blob).inserted else { return }
        routeEdits.clearProfiles()
        store.update { $0.profileSalt = UUID().uuidString }
        nextLimitAsk()
        vpn.endTesting()
        // The extension's sealed copy drops this provider's account, connected or not. Owed before the account goes, so
        // no quit in between leaves its credentials sealed.
        vpn.forgetSealed(provider)
        let last = signing.isEmpty && !setup.hasExit(signedIn: accounts.keys.contains { $0 != provider })
        // Recorded before any wait, so a quit meanwhile still erases before the next start.
        if last { vpn.requestErase() }
        Task {
            defer { signingOut.remove(blob) }
            if last { await vpn.disconnect() }
            // Only the account this sign-out was for: one signed in again meanwhile stays.
            if accounts[provider] == blob { store.account(provider, nil) }
            // Released alongside the extension's erase (which can take a minute), not after it.
            let released = Task {
                guard let p = Providers.get(provider) else { return true }
                return await release(p, blob)
            }
            resetIfEmpty()
            if !(await released.value) {
                unreleased([Providers.get(provider)?.name ?? provider])
                if provider == "airvpn" {
                    Task { try? await Task.sleep(for: .seconds(60)); retryAirCleanup() }
                }
            }
        }
    }

    /// Signs out of everything and forgets every route: back to the first-run screen. The app's own credentials go
    /// whatever happens; the extension's copy goes as soon as it answers.
    func signOutAll() async {
        guard !signingOutAll else { return }
        routeEdits.clear()
        store.update { $0.profileSalt = UUID().uuidString }
        nextLimitAsk()
        vpn.endTesting()
        // Recorded before any wait: a quit or crash from here on still erases the extension's copy before the next start.
        vpn.requestErase()
        signOutEpoch += 1
        identityEpoch += 1
        signingOutAll = true
        defer { signingOutAll = false }
        let all = accounts
        // Devices AirVPN added for unbraid whose removal is still owed: read before the files go (the record holds the
        // API key that removes them, so it is deleted with the other credentials), then removed with the releases.
        let airOwed = (try? await AirCleanup.shared.beginForgetting()) ?? []
        let loggedOut = await leaveTailnet()
        // Stopped before the accounts go, so the running engine isn't torn down with a "sign in again" alert.
        await vpn.disconnect()
        if !(await store.forgetAll()) {
            warn("Some of unbraid's files couldn't be deleted. They are deleted the next time unbraid opens.")
        }
        store.tsTestNode = false
        tailscaleLeft(loggedOut)
        // Device slots are released now, not after the extension's erase, which can take a minute when it doesn't
        // answer: the sessions exist only in memory by now, and a quit meanwhile would lose them for good.
        let releases = Task {
            var failed: [String] = []
            for (id, blob) in all { if let p = Providers.get(id), !(await release(p, blob)) { failed.append(p.name) } }
            if !airOwed.isEmpty, !(await AirVpn().removeOwed(airOwed)), !failed.contains("AirVPN") { failed.append("AirVPN") }
            return failed
        }
        // The erase answers every sealed-copy drop a sign-out still owed (`Connection.erasePending` settles them).
        _ = await eraseExtension()
        let failed = await releases.value
        await AirCleanup.shared.resumeWrites()
        if !failed.isEmpty { unreleased(failed) }
    }

    func refreshCountries(_ provider: String) {
        #if DEBUG
        if PerfHost.active { return }
        #endif
        guard !refreshing.contains(provider), let p = Providers.get(provider), let acc = accounts[provider] else { return }
        refreshing.insert(provider)
        let opts = setup.opts[provider] ?? [:]
        Task {
            defer {
                refreshing.remove(provider)
                // A new sign-in or new options asked for a refresh while this one ran (signed out: the call does nothing).
                if (setup.opts[provider] ?? [:]) != opts || accounts[provider] != acc { refreshCountries(provider) }
            }
            do {
                let result = try await p.freshCountries(acc, opts: opts)
                guard accounts[provider] == acc, (setup.opts[provider] ?? [:]) == opts else { return }
                if result.failed { catalogFailures.insert(provider) } else { catalogFailures.remove(provider) }
                catalogDates[provider] = result.published
                // From a kept or bundled list only: shown, but not cached as today's, so the next hourly check tries again.
                if result.live { store.countries(provider, result.countries, published: result.published) }
                countries[provider] = result.countries
            } catch {
                guard accounts[provider] == acc, !(error is CancellationError) else { return }
                catalogFailures.insert(provider)
            }
        }
    }

    private var groupCache: [String: Set<String>] = [:]

    /// Countries offering a Nord specialty group; nil if unknown (offline).
    func nordGroupCountries(_ group: String) async -> Set<String>? {
        if let c = groupCache[group] { return c }
        let c = try? await Nord.groupCountries(group)
        groupCache[group] = c
        return c
    }

    // MARK: Connection

    func connect() {
        // Sign Out of Everything is taking the setup apart: nothing starts from it meanwhile.
        guard !signingOutAll else { return }
        // Nothing set up yet (the stored setup is a placeholder): ⌘K, the panel and the widget all lead to setting up.
        guard signedIn else { AppDelegate.openMain(); return }
        guard store.disclosed && store.termsAccepted else {
            connectAfterDisclosure = true
            requestDisclosure()
            return
        }
        Task { await vpn.connect() }
    }

    func requestDisclosure() { disclosure = true; AppDelegate.openMain() }

    func acceptDisclosure() {
        if !store.disclosed { store.tourPending = true }
        store.disclosed = true
        store.termsAccepted = true
        disclosure = false
        refreshApps()
        let pending = connectAfterDisclosure
        connectAfterDisclosure = false
        if pending { connect() }
    }

    func cancelDisclosure() { disclosure = false; connectAfterDisclosure = false }

    func disconnect() { Task { await vpn.disconnect() } }
    func pause(_ minutes: Int) { Task { await vpn.pause(minutes: minutes) } }

    @ObservationIgnored private var routeEdits = RouteEdits()
    @ObservationIgnored private var limitQueue: [LimitAsk] = []

    @ObservationIgnored private var moveReplays = MoveReplays()

    final class LimitAsk {
        let valid: () -> Bool
        let text: String
        let server: String?
        private let accept: () -> Void
        private let sharing: (() -> Void)?
        private let cancel: () -> Void
        private let refresh: () -> Void
        private var answered = false

        init(valid: @escaping () -> Bool, text: String, server: String?, confirm: @escaping () -> Void,
             share: (() -> Void)?, refresh: @escaping () -> Void, cancel: @escaping () -> Void) {
            self.valid = valid; self.text = text; self.server = server; accept = confirm; sharing = share; self.cancel = cancel; self.refresh = refresh
        }
        var confirm: () -> Void { { guard !self.answered else { return }; self.answered = true; self.accept() } }
        var share: (() -> Void)? { sharing.map { action in { guard !self.answered else { return }; self.answered = true; action() } } }
        func dismiss() { if !answered { answered = true; cancel() } }
        func invalidate() { if !answered { answered = true; refresh() } }
    }
    var limitAsk: LimitAsk? {
        didSet {
            if let ask = limitAsk { AccessibilityNotification.Announcement("Over your plan's limit. " + ask.text).post() }
            else {
                let previous = oldValue
                Task { @MainActor [weak self] in previous?.dismiss(); self?.nextLimitAsk() }
            }
        }
    }

    private func nextLimitAsk() {
        if let ask = limitAsk, !ask.valid() { ask.invalidate(); limitAsk = nil }
        while limitAsk == nil, !limitQueue.isEmpty {
            let ask = limitQueue.removeFirst()
            if ask.valid() { limitAsk = ask; AppDelegate.openMain() }
            else { ask.invalidate() }
        }
    }

    /// Runs a setup change against the current setup, including after a question has been answered.
    private func guarded(_ change: @escaping (inout Setup) -> Void, targets: Set<RouteEdits.Target>,
                         after: @escaping (Setup, Setup) -> Void = { _, _ in }, valid: @escaping () -> Bool = { true }) {
        let ticket = routeEdits.begin(targets)
        nextLimitAsk()
        checkLimit(change, ticket: ticket, after: after, accepted: nil, valid: valid)
    }

    private func checkLimit(_ change: @escaping (inout Setup) -> Void, ticket: RouteEdits.Ticket,
                            after: @escaping (Setup, Setup) -> Void, accepted: Limits.Over?, valid: @escaping () -> Bool,
                            finished: @escaping (Bool) -> Void = { _ in }) {
        Task { @MainActor in
            var waiting = false
            var applied = false
            defer { if !waiting { routeEdits.finish(ticket); finished(applied) } }
            guard routeEdits.contains(ticket), valid() else { return }
            let record = vpn.state.phase == .on ? await Running.load() : nil
            guard routeEdits.contains(ticket), valid() else { return }
            store.reloadHeld()
            guard !store.isHeld else { return }
            let old = setup
            let currentAccounts = accounts
            let targets = routeEdits.targets(ticket)
            let new = Store.edited(old, change)
            var limits: [String: Limit] = [:]
            for p in Set(new.activeRoutes.filter { !$0.imported }.map { $0.loc.provider }) {
                if let account = currentAccounts[p], let provider = Providers.get(p), let limit = try? await provider.limit(account) {
                    limits[p] = limit
                }
                guard routeEdits.contains(ticket), valid() else { return }
            }
            // An asynchronous account lookup or record read may have raced another edit.
            guard routeEdits.contains(ticket), valid() else { return }
            guard old == setup, old.profileSalt == setup.profileSalt, currentAccounts == accounts, targets == routeEdits.targets(ticket) else {
                waiting = true
                checkLimit(change, ticket: ticket, after: after, accepted: nil, valid: valid, finished: finished); return
            }
            let live = vpn.state.phase == .on && record?.setup == vpn.running && record?.accounts == Running.fingerprints(accounts) ? record : nil
            let currentServers = vpn.state.servers
            func usable(_ s: Setup) -> [String: Link] {
                guard let live else { return [:] }
                return live.links.filter { id, link in s.route(id)?.loc == live.setup.route(id)?.loc && currentServers[id] == link.server }
            }
            let over = Limits.over(old, new, oldLinks: usable(old), newLinks: usable(new)) { limits[$0] }
            if let over, over != accepted {
                let name = Providers.get(over.provider)?.name ?? over.provider
                let candidate = live.flatMap { Limits.shareAnchor(old, running: $0.setup, servers: vpn.state.servers, provider: over.provider) }
                let anchor = candidate?.0
                let server = candidate?.1
                waiting = true
                limitQueue.append(LimitAsk(valid: { [weak self] in self?.routeEdits.targets(ticket) == targets && valid() }, text: Limits.warning(name, over.limit, over.unit, over.count), server: server?.name,
                    confirm: { [weak self] in self?.checkLimit(change, ticket: ticket, after: after, accepted: over, valid: valid, finished: finished) },
                    share: anchor.flatMap { a in server.map { sv in { [weak self] in
                        var handed = false
                        defer { if !handed { self?.routeEdits.finish(ticket); finished(false) } }
                        guard let self, self.vpn.state.phase == .on, self.setup.route(a.id)?.loc == a.loc,
                              self.vpn.running?.route(a.id)?.loc == a.loc, self.vpn.state.servers[a.id] == sv else { return }
                        var proposed = self.setup
                        change(&proposed)
                        let locations = Set(proposed.activeRoutes.filter { !$0.imported && $0.loc.provider == over.provider }.map { RouteEdits.Target.location($0.id) })
                        guard self.routeEdits.include(locations, in: ticket) else { return }
                        handed = true
                        self.checkLimit({ s in
                            change(&s)
                            let active = Set(s.activeRoutes.map(\.id))
                            for i in s.routes.indices where active.contains(s.routes[i].id) && !s.routes[i].imported && s.routes[i].loc.provider == over.provider {
                                var loc = a.loc; loc.pinned = sv; s.routes[i].loc = loc
                            }
                        }, ticket: ticket, after: after, accepted: nil, valid: { [weak self] in
                            guard let self, valid() else { return false }
                            let current = Limits.shareAnchor(self.setup, running: self.vpn.running, servers: self.vpn.state.servers, provider: over.provider)
                            return self.vpn.state.phase == .on && self.accounts[over.provider] == currentAccounts[over.provider] && current?.0.id == a.id && current?.0.loc == a.loc && current?.1 == sv
                        }, finished: finished)
                    } } }, refresh: { [weak self] in
                        self?.checkLimit(change, ticket: ticket, after: after, accepted: nil, valid: valid, finished: finished)
                    }, cancel: { [weak self] in self?.routeEdits.finish(ticket); finished(false) }))
                nextLimitAsk()
                return
            }
            store.update { $0 = new }
            applied = true
            after(old, setup)
        }
    }

    var profileGeneration: String {
        guard !store.isHeld else { return "" }
        return ProfileGeneration.value(setup, accounts: accounts)
    }

    var switchingProfile: String?
    var refusedProfile: String?
    private var profileSwitchID = UUID()

    func switchProfile(_ name: String, connectIfOff: Bool = false, offeredGeneration: String? = nil) {
        guard setup.profiles.contains(where: { $0.name == name }) else { return }
        if setup.profile == name { if connectIfOff && vpn.state.phase != .on { connect() }; return }
        let id = UUID()
        profileSwitchID = id
        refusedProfile = nil
        guarded({ [weak self] s in
            let running = self?.vpn.state.phase == .on && self?.vpn.state.runState.standIn == RunState.StandIn.none ? self?.vpn.running : nil
            let engine = running == nil ? nil : self?.vpn.profileSwitchEngine
            s.beginProfileSwitch(name, id: id, running: running, engine: engine)
        }, targets: [.profile], after: { [weak self] _, _ in
            guard let self, self.profileSwitchID == id, self.setup.pendingSwitch?.id == id else { return }
            if self.vpn.state.phase != .on, connectIfOff { self.connect() }
        }, valid: { [weak self] in
            guard let self, self.profileSwitchID == id else { return false }
            return offeredGeneration == nil || self.profileGeneration == offeredGeneration
        })
    }

    @ObservationIgnored private var profileWatcher: ChangeObserver?
    @ObservationIgnored private var lastProfileError: String?
    @ObservationIgnored private var lastProfileBlocked: [String: String] = [:]
    @ObservationIgnored private var lastProfileNotice: String?

    /// Follows a switch saved before a quit as well as one made in this session, without idle polling.
    private func watchProfileSwitch() {
        profileWatcher = ChangeObserver(read: { [weak self] in
            guard let self else { return }
            _ = self.setup
            _ = self.store.unsaved
            _ = self.vpn.state
            _ = self.vpn.tunnel.status
            _ = self.vpn.tunnel.statusLoaded
            _ = self.vpn.profileSwitchEngine
            _ = self.notice
        }, reconcile: { @MainActor [weak self] in self?.resolveProfileSwitch() })
        profileWatcher?.start()
    }

    private func resolveProfileSwitch() {
        let state = vpn.state
        if let error = state.error, error != lastProfileError { AccessibilityNotification.Announcement(error).post() }
        for id in state.blocked.keys.sorted() where state.blocked[id] != lastProfileBlocked[id] {
            if let reason = state.blocked[id] {
                let name = (state.runState.appliedSetup ?? setup).label(id)
                AccessibilityNotification.Announcement("Apps on \(name) are blocked: \(reason)").post()
            }
        }
        if let notice, notice != lastProfileNotice { AccessibilityNotification.Announcement(notice).post() }
        lastProfileError = state.error; lastProfileBlocked = state.blocked; lastProfileNotice = notice
        guard !store.isHeld, let pending = setup.pendingSwitch else { switchingProfile = nil; return }
        let status = vpn.tunnel.status
        let stopped = vpn.tunnel.statusLoaded && (status == .disconnected || status == .invalid)
            && state.phase != .connecting && state.phase != .on
        let decision = pending.decide(current: setup, running: vpn.profileSwitchEngine != nil ? state.runState.appliedSetup : nil,
            refused: state.runState.refusedSetup, standIn: state.runState.standIn, stopped: stopped)
        switchingProfile = decision == .waiting && state.phase == .on ? pending.target : nil
        switch decision {
        case .waiting: break
        case .applied, .stopped, .superseded:
            if decision == .applied || decision == .stopped {
                AccessibilityNotification.Announcement("Switched to \(pending.target)").post()
            }
            store.update { if $0.pendingSwitch?.id == pending.id { $0.pendingSwitch = nil } }
        case .refused:
            guard state.runState.standIn == .none, let ran = state.runState.appliedSetup else { return }
            store.update { s in
                guard s.pendingSwitch?.id == pending.id else { return }
                pending.rollback(&s, fallback: ran)
                s.pendingSwitch = nil
            }
            refusedProfile = pending.target
            AccessibilityNotification.Announcement("Couldn't switch to \(pending.target). \(setup.profile ?? "Your previous setup") is still in use.").post()
        }
    }

    // MARK: Routes

    /// Adds a route for `loc` (or reuses one already exiting there) and returns its id.
    @discardableResult
    func addRoute(_ loc: Location) -> String {
        if let r = setup.routes.first(where: { !$0.imported && $0.loc.ident == loc.ident }) { return r.id }
        let id = newId("r", taken: setup.routes.map(\.id))
        store.update { $0.routes.append(Route(id: id, loc: loc, hue: $0.nextHue)) }
        return id
    }

    /// Points route `id` at a provider location, dropping any imported source it had.
    func setLocation(_ id: String, _ loc: Location) {
        guarded({ s in
            guard let i = s.routes.firstIndex(where: { $0.id == id }) else { return }
            let r = s.routes[i]
            s.routes[i] = Route(id: r.id, loc: loc, hue: r.hue, filter: !r.imported && r.loc.provider == loc.provider ? r.filter : nil)
        }, targets: [.location(id)])
    }

    func renameRoute(_ id: String, _ name: String) {
        if let own = setup.route(id)?.own { renameServer(own, name); return }
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !n.isEmpty else { return }
        edit(id) { r in
            r.wg?.name = n; r.ovpn?.name = n; r.ss?.name = n
            if r.tsExit != nil { r.tsName = n }
        }
    }

    func removeRoute(_ id: String) {
        store.update { s in
            guard s.routes.count > 1 || s.defaultRoute != id else { return }
            s.routes.removeAll { $0.id == id }
            if s.defaultRoute == id { s.defaultRoute = s.routes.first?.id ?? DIRECT }
            s.apps = s.apps.filter { $0.value != id }
            s.tidyProfiles()
        }
    }

    func setDefault(_ id: String) {
        guarded({ s in
            guard id == DIRECT || id == BLOCK || s.route(id) != nil else { return }
            s.defaultRoute = id; s.apps = s.apps.filter { $0.value != id }
        }, targets: [.defaultRoute])
    }

    /// `routeId` nil or equal to the default: the app follows the default.
    func assign(_ app: String, _ routeId: String?) {
        #if DEBUG
        Log.info("assign", detail: "\(app) -> \(routeId ?? "default")") // traces unexpected changes while testing
        #endif
        guarded({ s in
            guard routeId == nil || routeId == DIRECT || routeId == BLOCK || s.route(routeId!) != nil else { return }
            s.apps[app] = routeId == nil || routeId == s.defaultRoute ? nil : routeId
            s.requireKillSwitchForBlocks()
        }, targets: [.app(app)], after: { [weak self] old, _ in
            self?.apps.reassigned([app])
            self?.askBlockScope(old.apps.values.contains(BLOCK))
        })
    }

    func addRouteForApp(_ app: String, _ loc: Location) {
        guarded({ s in
            let id = self.newId("r", taken: s.routes.map(\.id))
            let route = s.routes.first(where: { !$0.imported && $0.loc.ident == loc.ident })?.id ?? id
            if s.route(route) == nil { s.routes.append(Route(id: route, loc: loc, hue: s.nextHue)) }
            s.apps[app] = route == s.defaultRoute ? nil : route
            s.requireKillSwitchForBlocks()
        }, targets: [.app(app)], after: { [weak self] _, _ in self?.apps.reassigned([app]) })
    }

    /// Block needs the kill switch (an app could otherwise bind to Wi-Fi itself and get round it). The first app blocked
    /// without it, or before the user has chosen its reach, asks: Internet, or Internet and home network. The window
    /// hosting the question opens if the block came from the menu bar panel; the choice is remembered once made.
    func askBlockScope(_ blockedBefore: Bool = false) {
        // The kill switch is already on (Internet) with any block: the question only offers the home level on top.
        guard !blockedBefore, setup.apps.values.contains(BLOCK), setup.prefs.killLevel != .home,
              !UserDefaults.standard.bool(forKey: Self.blockScopeAsked) else { return }
        Presentation.shared.blockScope = true
        AppDelegate.openMain()
    }

    /// The answer to the first-block question.
    func chooseBlockScope(_ level: KillLevel) {
        UserDefaults.standard.set(true, forKey: Self.blockScopeAsked)
        setPrefs { $0.killLevel = level }
    }

    static let blockScopeAsked = "blockScopeAsked"

    /// Moves apps to a route (nil = follow the default) in one change that Edit > Undo takes back, and Redo repeats.
    func move(_ apps: [String], to routeId: String?, undo: UndoManager?) {
        let keys = Array(Set(apps))
        guard !keys.isEmpty else { return }
        let change = Dictionary(uniqueKeysWithValues: keys.map { ($0, routeId) })
        let name = keys.count == 1 ? "Move App" : "Move \(keys.count) Apps"
        apply(change) { [weak self, weak undo] before, after, keys in
            guard let self, let undo, before.apps != after.apps else { return }
            _ = MoveHistory(before: AppMove.assignments(keys, in: before), after: AppMove.assignments(keys, in: after),
                undo: undo, name: name, submit: { [weak self] change, completed in
                    guard let self else { completed(false); return }; self.replay(change, completed: completed)
                })
        }
    }

    /// Checks the remaining apps before saving them. The undo snapshot comes from the actual commit.
    private func apply(_ change: AppMove.Assignments, after: @escaping (Setup, Setup, [String]) -> Void) {
        let ticket = routeEdits.begin(Set(change.keys.map { .app($0) }), move: true)
        nextLimitAsk()
        checkLimit({ [self] in AppMove.apply(routeEdits.remaining(change, in: ticket), to: &$0) }, ticket: ticket, after: { [weak self] old, new in
            guard let self else { return }
            let keys = Array(self.routeEdits.remaining(change, in: ticket).keys)
            self.apps.reassigned(keys)
            self.askBlockScope(old.apps.values.contains(BLOCK))
            after(old, new, keys)
        }, accepted: nil, valid: { true })
    }

    private func replay(_ change: AppMove.Assignments, completed: @escaping (Bool) -> Void) {
        let ticket = routeEdits.begin(Set(change.keys.map { .app($0) }), preserving: moveReplays.tickets)
        nextLimitAsk()
        moveReplays.append(ticket) { [weak self] finished in
            guard let self else { completed(false); finished(); return }
            self.checkLimit({ [self] in AppMove.apply(routeEdits.remaining(change, in: ticket), to: &$0) }, ticket: ticket, after: { [weak self] old, _ in
                guard let self else { return }
                self.apps.reassigned(Array(self.routeEdits.remaining(change, in: ticket).keys))
                self.askBlockScope(old.apps.values.contains(BLOCK))
            }, accepted: nil, valid: { true }, finished: { applied in completed(applied); finished() })
        }
    }

    func setFilter(_ id: String, _ on: Bool?) { edit(id) { $0.filter = on } }

    func setOpt(_ provider: String, _ key: String, _ value: String, offered: ProviderOption? = nil) {
        guard let option = offered ?? Providers.get(provider)?.option(key), option.key == key, option.accepts(value) else { return }
        store.update { $0.opts[provider, default: [:]][key] = value }
        if option.affectsCountries { refreshCountries(provider) }
    }

    func toggleFavorite(_ loc: Location) {
        store.update { s in
            // Matched by identity, so favourites saved with older ids are found (and dropped) too.
            let key = loc.favKey
            if s.favorites.contains(where: { $0.favKey == key }) { s.favorites.removeAll { $0.favKey == key } }
            else {
                var saved = key
                saved.pinned = loc.pinned
                s.favorites.append(saved)
            }
        }
    }

    func setPrefs(_ f: (inout Prefs) -> Void) { store.update { f(&$0.prefs) } }
    func setHome(_ f: (inout Home) -> Void) { store.update { f(&$0.home) } }

    /// Statistics on or off; while off nothing is recorded.
    func setStats(_ on: Bool) { setPrefs { $0.stats = on } }

    private func edit(_ id: String, _ f: (inout Route) -> Void) {
        store.update { s in if let i = s.routes.firstIndex(where: { $0.id == id }) { f(&s.routes[i]) } }
    }

    // MARK: Own servers

    /// Saves one of the user's own servers; with a target ("" new route, "app:<key>" or a route id) that route uses it too.
    func importServer(_ target: String?, _ server: OwnServer, secrets: [String] = []) {
        var s = server
        s.id = newId("s", taken: setup.servers.map(\.id))
        store.update { $0.servers.append(s) }
        if let target { useServer(target, s) }
        if !secrets.isEmpty { clearClipboardAfterSave(secrets) }
    }

    /// Route `target` exits through saved server `s`; returns the route id.
    @discardableResult
    func useServer(_ target: String, _ s: OwnServer) -> String {
        addImported(target) { $0.wg = s.wg; $0.ovpn = s.ovpn; $0.ss = s.ss; $0.own = s.id }
    }

    /// Renames a saved server and every route using it.
    func renameServer(_ id: String, _ name: String) {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !n.isEmpty else { return }
        store.update { s in
            for i in s.servers.indices where s.servers[i].id == id { s.servers[i].wg?.name = n; s.servers[i].ovpn?.name = n; s.servers[i].ss?.name = n }
            for i in s.routes.indices where s.routes[i].own == id { s.routes[i].wg?.name = n; s.routes[i].ovpn?.name = n; s.routes[i].ss?.name = n }
        }
    }

    /// Removes a saved server and the routes using it; their apps follow the default route.
    func removeServer(_ id: String) {
        store.update { s in
            let gone = Set(s.routes.filter { $0.own == id }.map(\.id))
            s.servers.removeAll { $0.id == id }
            s.routes.removeAll { gone.contains($0.id) }
            if gone.contains(s.defaultRoute) { s.defaultRoute = s.routes.first?.id ?? DIRECT }
            s.apps = s.apps.filter { !gone.contains($0.value) }
        }
        resetIfEmpty()
    }

    /// Gives an imported source to a route and returns its id: see `Setup.addImported`, which also decides whether the
    /// new route becomes the default.
    @discardableResult
    func addImported(_ target: String, _ source: (inout Route) -> Void) -> String {
        let fresh = newId("r", taken: setup.routes.map(\.id))
        let signedIn = Set(accounts.keys)
        var id = fresh
        store.update { s in id = s.addImported(target, id: fresh, signedIn: signedIn, source) }
        return id
    }

    /// Tailscale runs one exit node at a time: an existing exit route is retargeted instead of adding another. True if
    /// one was. `ip` is the node's tailnet address; `name` is only for display.
    @discardableResult
    func addTsExit(_ target: String, ip: String, name: String?) -> Bool {
        let old = setup.routes.first { $0.tsExit != nil }
        store.update { s in for i in s.routes.indices where s.routes[i].tsExit != nil { s.routes[i].tsExit = ip; s.routes[i].tsName = name } }
        if let t = setup.route(target), t.tsExit == nil { addImported(target) { $0.tsExit = ip; $0.tsName = name } }
        else if let old { if target.hasPrefix("app:") { assign(String(target.dropFirst(4)), old.id) } }
        else { addImported(target) { $0.tsExit = ip; $0.tsName = name } }
        return old != nil
    }

    /// Skips providers: Tailscale becomes the only network feature.
    func useTailscaleOnly() {
        let noProviders = accounts.isEmpty
        store.update { s in
            if noProviders { s.routes.removeAll { !$0.imported } }
            s.home.tailscale = true
            if s.route(s.defaultRoute) == nil { s.defaultRoute = s.routes.first?.id ?? DIRECT }
            s.apps = s.apps.filter { $0.value == DIRECT || $0.value == BLOCK || s.route($0.value) != nil }
        }
    }

    // MARK: Tailscale

    /// A new control server or auth key means a new node: the old one logs out of its tailnet if it can (the engine must
    /// be running for that), then the engine stops before its Tailscale state goes. `url` is normalised (`TsLogin.controlUrl`).
    func setTailscaleServer(_ url: String?, authKey: String?) async {
        guard !signingOutAll, let (url, key) = TsLogin.change(url: setup.home.tsControlUrl, key: setup.home.tsAuthKey, to: url, authKey: authKey)
        else { return }
        await changeTailscale(to: (url, key), pastedKey: authKey)
    }

    /// Turns Tailscale off, drops its exit routes (their apps follow the default) and logs this Mac out of the tailnet.
    func signOutTailscale() async {
        guard !signingOutAll else { return }
        await changeTailscale(to: nil)
    }

    private func changeTailscale(to credentials: (url: String?, key: String?)?, pastedKey: String? = nil) async {
        // Recorded before any wait: a quit from here on still erases the old identity before the next start.
        vpn.requestErase()
        let reconnect = vpn.state.phase == .on || vpn.state.phase == .connecting
        identityEpoch += 1
        let epoch = identityEpoch
        let loggedOut = await leaveTailnet()
        // Overtaken while leaving the tailnet: never stop the newer operation's connection.
        guard epoch == identityEpoch else { return }
        await vpn.disconnect()
        // Overtaken (Sign Out of Everything, another change) while stopping: its values win.
        guard epoch == identityEpoch else { return }
        if let credentials {
            tailscaleLeft(loggedOut)
            store.tsSuffix = nil
            store.tsTestNode = false
            // A new server or key: a new node, enrolled again.
            store.update { s in s.home.tsAuthKey = credentials.key; s.home.tsControlUrl = credentials.url; s.home.tsEnrolled = nil }
            if let pastedKey { clearClipboardAfterSave([pastedKey]) }
        } else {
            // The app's own copy goes whatever the extension does.
            store.update { $0.dropTailscale() }
            store.tsSuffix = nil
            store.tsTestNode = false
            tailscaleLeft(loggedOut)
        }
        // The old node's identity: erased now, or before the VPN next starts, so the new server never sees it.
        await eraseExtension()
        if reconnect, credentials != nil || signedIn, epoch == identityEpoch { await vpn.connect() }
        if credentials == nil { resetIfEmpty(erase: false) }
    }

    func importHomeWireGuard(_ text: String) -> String? {
        do {
            var p = try WgConf.parse(text, name: "Home")
            p.allowedIps = p.allowedIps.compactMap(Compiler.canonical)
            setHome { $0.wg = p }
            clearClipboardAfterSave([text])
            return nil
        } catch { return (error as? Fail)?.errorDescription ?? "Not a WireGuard config" }
    }

    // MARK: Helpers

    /// Activation can come many times a minute (the menu bar panel, ⌘Tab): a rescan every 30 s at most is enough.
    /// - Parameter changed: a folder, a disk or a launch said something changed: rescan even if one ran moments ago.
    private func refreshApps(changed: Bool = false) {
        guard store.disclosed, rescans.start(changed: changed, now: .now) else { return }
        Task {
            dropUninstalled(await apps.load())
            scanAgain(retries.scanned(apps.pending, now: .now))
            if rescans.finished() { refreshApps(changed: true) }
        }
    }

    /// A bundle being copied in raises no further event once its folder entry is there: scanned again at `due`.
    private func scanAgain(_ due: Date?) {
        guard due != retry?.due else { return }
        retry?.task.cancel()
        retry = due.map { due in
            (due, Task {
                // Cancelled: a later scan set another time (or none). Not run now.
                do { try await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow))) } catch { return }
                guard !Task.isCancelled else { return }
                retry = nil
                refreshApps(changed: true)
            })
        }
    }

    /// Changes come in bursts (an installer, a disk image opening): one rescan shortly after the first, not one each.
    private func appsChanged() {
        guard appsSoon == nil else { return }
        appsSoon = Task {
            try? await Task.sleep(for: .seconds(rescans.delay(now: .now)))
            appsSoon = nil
            refreshApps(changed: true)
        }
    }

    /// A routed app's start from a copy its patterns miss, and any app's start at a place a routed app is remembered at
    /// (it has taken that place), rescan: the rest cost a dictionary lookup or two.
    private func launched(_ id: String, _ bundle: URL, _ executable: URL?) {
        let displaced = apps.started(id, bundle: bundle)
        let routed = setup.apps[id] != nil && apps.launched(id, bundle: bundle, executable: executable)
        if displaced || routed { appsChanged() }
    }

    /// With Tailscale set up, the node leaves its tailnet (only possible while the engine runs it). Nil = not asked;
    /// false = couldn't, so the device lingers in the admin console. An exit route no app uses counts too: the engine
    /// then runs no Tailscale, but the identity stays.
    private func leaveTailnet() async -> Bool? {
        guard setup.tailscaleConfigured else { return nil }
        guard vpn.state.phase == .on else { return false }
        return await EngineLink.call(timeout: 15) { $0.tailscaleLogout(Compiler.tsTag, reply: $1) } ?? false
    }

    /// The extension's copy of the setup and its Tailscale identity; the app's own are already gone.
    @discardableResult
    private func eraseExtension(while still: (() -> Bool)? = nil) async -> Connection.EraseOutcome {
        let outcome = await vpn.eraseExtension(while: still)
        if outcome == .failed {
            warn("unbraid's network extension didn't answer, so the copy of your setup it keeps isn't erased yet. unbraid erases it before it starts another connection.")
        }
        return outcome
    }

    private func tailscaleLeft(_ loggedOut: Bool?) {
        if loggedOut == false { warn("Couldn't log this Mac out of its tailnet (that needs the VPN on). If it was signed in, remove it in the tailnet's admin console.") }
    }

    /// Releases what a sign-in registered, once: a provider sign-out that ran while Sign Out of Everything waited on the
    /// VPN has already released that session, and a second release would fail and warn for nothing.
    /// Claimed before the first wait, so of two overlapping releases only the first calls the provider and warns; the
    /// other waits for its outcome.
    private func release(_ p: any Provider, _ blob: String) async -> Bool {
        let digest = releaseKey(p.id, blob)
        if let running = releases[digest] { _ = await running.value; return true }
        let task = Task { await p.signOut(blob) }
        releases[digest] = task
        return await task.value
    }

    /// Remembered per session, not per account: one stored again by a sign-in (a provider whose sign-in gives the same
    /// session twice) is forgotten then, so its next sign-out releases it again.
    private func releaseKey(_ provider: String, _ blob: String) -> String { provider + ":" + Running.fingerprint(blob) }

    private func unreleased(_ names: [String]) {
        let list = names.joined(separator: ", ")
        warn("Couldn't release this Mac's device slot at \(list). Remove it in your \(list) account\(names.count > 1 ? "s" : "").")
    }

    private func retryAirCleanup() {
        guard !store.isHeld, !signingOutAll else { return }
        var active: Set<AirCleanup.Record> = []
        if let blob = accounts["airvpn"], let account = try? AirVpn().keyAccount(blob), account.ownDevice == true,
           let key = account.apiKey, let id = account.deviceId { active.insert(.init(key: key, id: id)) }
        Task.detached(priority: .utility) { await AirVpn().retryCleanup(excluding: active) }
    }

    private func warn(_ text: String) { notice = [notice, text].compactMap { $0 }.joined(separator: "\n") }

    /// Nothing left to route through: the VPN stops, the extension's sealed copy (which holds the keys just signed out
    /// of) is erased, and the first-run screen shows. The setup stays (routes, app choices, Home WireGuard) for the next
    /// sign-in; only Sign Out of Everything forgets it. However it got empty: the last sign-out, two at once, a removed
    /// server, a sign-in that was waited for and failed.
    /// A sign-in under way is never cancelled by another provider's sign-out: the stop waits for it, and only happens if
    /// it fails too.
    private func resetIfEmpty(erase: Bool = true) {
        let nothing = { [weak self] () -> Bool in
            guard let self, !self.signedIn else { return false }
            guard self.signing.isEmpty else { self.resetWaiting = true; return false }
            return true
        }
        guard nothing() else { return }
        // Checked again when it runs, and once more when the VPN's queue is ours: a sign-in may have started in between.
        // Something set up and started meanwhile keeps its connection; the erase then waits for the next start, which
        // does it first.
        Task {
            guard nothing() else { return }
            // Recorded before any wait (a quit still erases before the next start), and only once the reset is going
            // ahead: the request makes a connect under way give way, and nothing would take over its state otherwise.
            if erase { vpn.requestErase() }
            await store.forgetBadCopies()
            if erase { await eraseExtension(while: nothing) } else { await vpn.disconnect(while: nothing) }
        }
    }

    /// An uninstalled app must not keep its route (and a tunnel) alive for good: `gone` are those missing long enough,
    /// with the route they had (never Block; see `AppPresence`). One moved meanwhile keeps its new route.
    private func dropUninstalled(_ gone: [String: String]) {
        guard gone.contains(where: { setup.apps[$0.key] == $0.value }) else { return }
        store.update { s in
            for (id, route) in gone where route != BLOCK && s.apps[id] == route { s.apps[id] = nil }
        }
    }

    private func clearClipboardAfterSave(_ secrets: [String]) {
        store.afterSave("setup") { [weak self] in secrets.forEach { self?.clearClipboardIf($0) } }
        store.confirmSetup { _ in }
    }

    /// Don't leave a secret on the clipboard for the next app to read: cleared only if the clip is exactly `secret`.
    func clearClipboardIf(_ secret: String) {
        let pb = NSPasteboard.general
        if clipboardContains(pb.string(forType: .string), secret: secret) { pb.clearContents() }
    }

    /// An app as statistics name it: its catalogue name, "unbraid", "Unknown app" (no owner found), or a tool's last
    /// identifier component ("com.example.sync-tool" becomes "sync-tool").
    func appName(_ key: String) -> String {
        key == "?" ? "Unknown app" : key == Bundle.main.bundleIdentifier ? "unbraid" : apps.app(key)?.name ?? String(key.split(separator: ".").last ?? "")
    }

    private func newId(_ prefix: String, taken: [String]) -> String {
        while true {
            let id = prefix + UUID().uuidString.prefix(8).lowercased()
            if !taken.contains(id) { return id }
        }
    }
}
