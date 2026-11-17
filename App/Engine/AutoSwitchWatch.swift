import AppKit
import Foundation
import Network
import Observation

/// Switches profile by network: watches which network the Mac is on with a path monitor of its own, reads that
/// network's fingerprint (`NetworkMark`), lets `AutoSwitchRun` say when and `AutoSwitch.decide` what, and switches
/// through `AppModel.switchProfile` as the menu bar does, so a switch the engine refuses rolls back the same way.
/// Never connects or disconnects.
@MainActor @Observable
final class AutoSwitchWatch {
    /// The fingerprint of the network the Mac is on now, for the Profiles page; nil with none, while its router hasn't
    /// answered, or on a network unbraid can't recognise.
    private(set) var mark: String?
    /// The network switching goes by now (`AutoSwitchRun.here`): a remembered network's own name, a reading, or
    /// `AutoSwitch.unrecognised`; nil while offline or still reading.
    private(set) var here: String?
    /// The Mac is on a network (Wi-Fi or a cable, with a usable path), whether or not it can be told apart from others.
    private(set) var online = false

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var run = AutoSwitchRun(rules: NetworkRules())
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var path: (interface: String?, key: String)?
    @ObservationIgnored private var probe: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var observer: ChangeObserver?
    @ObservationIgnored private var sleepers: [NSObjectProtocol] = []
    /// The remembered network the Mac was last on, and the profile in use there.
    @ObservationIgnored private var inUse: (mark: String, profile: String?)?
    /// Provider limits, read ahead for the accounts they were read for: deciding never waits.
    @ObservationIgnored private var limits: [String: Limit] = [:]
    @ObservationIgnored private var limitsFor: [String: String]?
    @ObservationIgnored private var names: [String]?
    @ObservationIgnored private var salt: String?
    /// Set while this watcher's own switch is being asked for: not a profile picked by hand.
    @ObservationIgnored private var switching = false
    /// The profile this watcher switched to, until the switch is through or refused.
    @ObservationIgnored private var own: String?
    /// What was said, and on which network and rules: each only once.
    @ObservationIgnored private var told: [(AutoSwitch.Acted?, String)] = []

    func start(_ model: AppModel) {
        self.model = model
        // The test copy never reads this Mac's network (`perfShow` gives it one).
        guard getenv("UNBRAID_PERF") == nil else { return }
        observer = ChangeObserver(read: { [weak self] in
            guard let m = self?.model else { return }
            _ = m.vpn.state.phase; _ = m.store.networks; _ = m.store.setupStandIn; _ = m.setup.pendingSwitch
            _ = m.setup.profiles; _ = m.setup.profile; _ = m.refusedProfile; _ = m.accounts; _ = m.limitAsk
        }, reconcile: { @MainActor [weak self] in self?.reconcile() })
        observer?.start()
        monitor.pathUpdateHandler = { [weak self] path in
            // The Wi-Fi or cable macOS prefers, never a tunnel's, while the path is usable (a network still joining is
            // none yet); the rest of the path only says that something changed.
            let interface = path.status == .satisfied ? path.availableInterfaces.first { $0.type == .wifi || $0.type == .wiredEthernet }?.name : nil
            let key = "\(interface ?? "")|\(path.status)|\(path.gateways.map { "\($0)" }.sorted())"
            Task { @MainActor in self?.pathChanged(interface, key) }
        }
        monitor.start(queue: DispatchQueue(label: "app.unbraid.autoswitch"))
        // Sleep is no network change by itself: the network is read again after a wake and compared.
        let center = NSWorkspace.shared.notificationCenter
        sleepers = [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)].map { name, asleep in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.apply(self.run.handle(.sleep(asleep)))
                    if !asleep { self.read() }
                }
            }
        }
        // The connection's own network watch: one more reason to read the router again (a same-looking path).
        let previous = model.vpn.onNetworkChange
        model.vpn.onNetworkChange = { [weak self] in previous?(); self?.read() }
    }

    /// Any switch not made here: it counts as decided for the network it was picked on.
    func pickedByHand() {
        guard !switching else { return }
        own = nil
        apply(run.handle(.pickedByHand))
    }

    private func reconcile() {
        guard let m = model else { return }
        let store = m.store
        // A rule never names a profile that isn't there (a restore, a file from another version). Not from a stand-in,
        // whose profiles aren't the user's.
        let profiles = m.setup.profiles.map(\.name)
        if !store.setupStandIn, profiles != names { names = profiles; store.updateNetworks { $0.tidy(profiles: profiles) } }
        if m.accounts != limitsFor { readLimits(m.accounts) }
        if store.networks.salt != salt { salt = store.networks.salt; read() }
        follow(m)
        // Busy also while a change waits for the user's answer about a provider's limit: a switch now would take that
        // question away with the change it was about.
        apply(run.handle([.connected(m.vpn.state.phase == .on), .profiles(profiles), .rules(store.networks),
                          .busy(store.setupStandIn || m.setup.pendingSwitch != nil || m.limitAsk != nil)]))
    }

    private func readLimits(_ accounts: [String: String]) {
        limitsFor = accounts
        Task { [weak self] in
            var read: [String: Limit] = [:]
            for (p, a) in accounts { if let l = try? await Providers.get(p)?.limit(a) { read[p] = l } }
            if self?.limitsFor == accounts { self?.limits = read }
        }
    }

    private func pathChanged(_ interface: String?, _ key: String) {
        guard key != path?.key else { return }
        path = (interface, key)
        if online != (interface != nil) { online = interface != nil }
        read()
    }

    /// When the fingerprint is read again while the router hasn't answered: each second through the settle time, every
    /// few seconds until the network counts as unrecognised (20 s), then every 15 s until 105 s and once at 115 s, so a
    /// remembered network whose router answers late is found and gets back what was in use there; then nothing until the
    /// next change or wake.
    private static let readings: [Duration] = [0, 1, 1, 1, 1, 1, 3, 3, 3, 3, 3, 10, 15, 15, 15, 15, 15, 10].map { .seconds($0) }

    private func read() {
        probe?.cancel()
        guard let interface = path?.interface, let salt = model?.store.networks.salt else { probe = nil; seen(.offline); return }
        probe = Task { [weak self] in
            for wait in Self.readings {
                if wait > .zero { try? await Task.sleep(for: wait) }
                guard !Task.isCancelled else { return }
                let m = await NetworkMark.current(salt: salt, interface: interface)
                guard !Task.isCancelled, let self else { return }
                // Where the network is reached (never kept): two networks without a fingerprint differ only by it, and it
                // tells a remembered network's late router from a new network.
                let place = interface + "|" + (NetworkMark.gateway(on: interface, routes: NetworkMark.routes()) ?? "")
                self.seen(m.map { .mark($0, place: place) } ?? .reading(place: place))
                if m != nil { return }
            }
        }
    }

    private func seen(_ reading: AutoSwitchRun.Reading) {
        let m: String? = if case .mark(let m, _) = reading { m } else { nil }
        if mark != m { mark = m }
        apply(run.handle(.network(reading)))
    }

    private func apply(_ action: AutoSwitchRun.Action) {
        let h = run.here(at: .now)
        if here != h { here = h }
        // The profile in use (or on its way) while the Mac is on a remembered network: what the way back restores (read
        // before it is replaced, so not on the way back itself).
        let back = if case .restore = action { true } else { false }
        if !back, let h, let m = model, !switching, m.store.networks.known.contains(where: { $0.id == h }) {
            let p = m.setup.pendingSwitch?.target ?? m.setup.profile
            if inUse?.mark != h || inUse?.profile != p { inUse = (h, p) }
        }
        timer?.cancel(); timer = nil
        switch action {
        case .nothing: break
        case .wait(let due):
            timer = Task { [weak self] in
                try? await Task.sleep(until: due, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                // What is busy is read again now: a question that opened while this waited must be seen before
                // anything is decided, or the switch would take it away.
                self.reconcile()
                self.apply(self.run.handle(.timer))
            }
        case .decide(let mark, let acted): decide(mark, acted)
        case .restore(let mark):
            // The profile that was in use on this network before the Mac counted as somewhere else, a hand pick included.
            guard let m = model, let back = inUse, back.mark == mark, let name = back.profile, m.setup.profile != name,
                  m.setup.profiles.contains(where: { $0.name == name }) else { return }
            make(name, for: mark, rule: false)
        }
    }

    private func decide(_ mark: String, _ acted: AutoSwitch.Acted?) {
        guard let m = model else { return }
        let step = AutoSwitch.decide(m.setup, rules: run.rules, mark: mark, acted: acted) { [limits] in AutoSwitchRun.over($0) { limits[$0] } }
        switch step {
        case .none: break
        case .to(let name): make(name, for: mark, rule: true)
        case .blocked(let why): tell(why, inWindow: true)
        }
    }

    /// Switches to `name` for network `mark`, if it is still right when the change is made: still connected, still the
    /// user's own setup, still on that network, and (`rule`) still what its rule names.
    private func make(_ name: String, for mark: String, rule: Bool) {
        guard let m = model else { return }
        own = name
        switching = true
        let decided = run.generation
        m.switchProfile(name, wanted: { [weak self, weak m] in
            guard let self, let m else { return false }
            return m.vpn.state.phase == .on && !m.store.setupStandIn && self.run.here(at: .now) == mark
                && (!rule || m.store.networks.profile(on: mark) == name)
        }, finished: { [weak self] made in
            // Not made (the connection or the network changed while it waited): owed again once they settle. Not when a
            // profile picked by hand took its place (`own` cleared); the run also ignores a report about anything but
            // its latest decision.
            guard !made, let self, self.own == name else { return }
            self.own = nil
            self.apply(self.run.handle(.unapplied(decided)))
        })
        switching = false
    }

    /// The engine refused this watcher's switch: the rollback has put back what it still runs (the window says so too).
    /// The network stays decided, so it isn't tried again in a loop.
    private func follow(_ m: AppModel) {
        guard let name = own else { return }
        if m.refusedProfile == name {
            own = nil
            tell("Couldn't switch to \(name). \(m.setup.profile ?? "Your previous setup") is still in use.", inWindow: false)
        } else if m.setup.pendingSwitch == nil, m.setup.profile == name { own = nil }
    }

    /// One notification, and the same in the window, whether or not the notification shows (a refusal already shows
    /// there).
    private func tell(_ text: String, inWindow: Bool) {
        let key = run.acted
        guard !told.contains(where: { $0.0 == key && $0.1 == text }) else { return }
        told = Array((told + [(key, text)]).suffix(20))
        Notifier.post(title: "Profile not switched", body: text)
        guard inWindow, let m = model else { return }
        m.notice = [m.notice, text].compactMap { $0 }.joined(separator: "\n")
    }

    #if DEBUG
    /// The test copy's pictures: a made-up network to be on.
    func perfShow(_ mark: String?) { self.mark = mark; here = mark }
    #endif
}
