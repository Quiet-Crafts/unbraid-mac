import Foundation

/// When the profile for the network the Mac is on is decided, as a plain state machine the watcher feeds. What it
/// follows:
///
/// - The Mac stays on one network until it has been offline for more than a moment while awake, or reaches a network
///   through another interface or IPv4 router (an arrival). Sleep is not a change by itself: after a wake the network
///   is read again and compared.
/// - On the same network nothing switches, except for a new rule for it or a profile picked by hand. Its routers
///   coming and going within what a remembered network holds keep it that network.
/// - A network that gives no acceptable reading counts as one unbraid can't recognise (the profile for any other
///   network) 20 s after an arrival, or `AutoSwitch.lateRouter` after the network the Mac was already on was read again:
///   never later, so no network keeps another's profile for good.
/// - A decision is made once per network and the profile its rule names, only while connected and not busy, once the
///   network has lasted `AutoSwitch.settle`; one the app couldn't make (`unapplied`) is owed again.
/// - A profile picked by hand counts as decided for the network it was picked on, or, while that network is still being
///   read, for the network the reading gives; going offline has no network to pick for.
///
/// Kept in memory only: after a restart the first connect decides again. Times are on the continuous clock.
nonisolated struct AutoSwitchRun: Equatable, Sendable {
    typealias Instant = ContinuousClock.Instant

    /// What the watcher knows of the network: offline (no usable Wi-Fi or cable), or reached through `place` (the
    /// interface and its IPv4 router, the only thing that tells networks without a fingerprint apart), with its
    /// routers' fingerprints or still without.
    enum Reading: Equatable, Sendable {
        case offline
        case reading(place: String = "")
        case mark(String, place: String = "")

        var place: String? {
            switch self { case .offline: nil; case .reading(let p), .mark(_, let p): p }
        }
    }

    enum Event: Equatable, Sendable {
        case network(Reading)
        /// The Mac is going to sleep (true) or woke (false).
        case sleep(Bool)
        case connected(Bool)
        case rules(NetworkRules)
        /// The names of the saved profiles, sent before the rules: they tell a rename from a rule set to another profile.
        case profiles([String])
        /// A profile was chosen by hand (the menu bar, the window, Control Center, Shortcuts).
        case pickedByHand
        /// The switch asked for this decision wasn't made (the connection or the network changed meanwhile).
        case unapplied(AutoSwitch.Acted)
        /// Nothing may be decided now: a profile switch is still pending, or the setup is a stand-in.
        case busy(Bool)
        /// The time asked for has passed.
        case timer
    }

    enum Action: Equatable, Sendable {
        /// No timer is needed.
        case nothing
        /// Look again at that moment (the timer, replacing any other).
        case wait(Instant)
        /// Decide now on network `mark`; `acted` is what was decided on before, for `AutoSwitch.decide`.
        case decide(mark: String, acted: AutoSwitch.Acted?)
    }

    private(set) var reading = Reading.offline
    private(set) var connected = false
    private(set) var rules: NetworkRules
    private(set) var busy = false
    private(set) var profiles: [String] = []
    /// Since when the network, the connection and the profile for this network have been as they are.
    private(set) var since: Instant
    /// Since when this network has been read without an acceptable reading, and how long it may last.
    private(set) var waiting: Instant
    private(set) var grace = AutoSwitch.unrecognisedAfter
    /// Where the Mac last was, while offline: when it went, and whether it slept since.
    struct Left: Equatable, Sendable { var place: String, at: Instant, slept: Bool }
    private(set) var left: Left?
    /// This network has given an acceptable reading since it was reached.
    private(set) var read = false
    /// The remembered network the last reading on this network named on its own: a reading that two remembered
    /// networks would fit (a shared router, the other away) stays this one. Forgotten on an arrival.
    private(set) var resolved: String?
    /// The Mac went to sleep while online: the next reading is compared, not taken as an arrival.
    private(set) var asleep = false
    /// What was last decided on for this network (nil after an arrival: nothing yet).
    private(set) var acted: AutoSwitch.Acted?
    /// A profile was picked by hand while this network was still being read.
    private(set) var byHand = false

    init(rules: NetworkRules, now: Instant = .now) { self.rules = rules; since = now; waiting = now }

    /// The network decisions are about: a remembered network by its own name (the one already decided on here, while its
    /// routers come and go), else the reading, `AutoSwitch.unrecognised` once a reading has waited too long; nil while
    /// offline or still waiting.
    func here(at now: Instant) -> String? {
        switch reading {
        case .offline: nil
        case .mark(let m, _): rules.identity(m, preferring: resolved)
        case .reading: now >= waiting + grace ? AutoSwitch.unrecognised : nil
        }
    }

    mutating func handle(_ event: Event, now: Instant = .now) -> Action { handle([event], now: now) }

    /// Several things that changed together, taken in before anything is decided: a switch never starts on a state
    /// half taken in (connected, but not yet seen as busy).
    mutating func handle(_ events: [Event], now: Instant = .now) -> Action {
        for event in events {
            take(now)
            switch event {
            case .network(let r): network(r, now)
            case .sleep(let s):
                asleep = s
                if s { left?.slept = true }
            case .connected(let c): if c != connected { connected = c; since = now }
            case .rules(let r):
                guard r != rules else { break }
                // A rename of the profile what was decided names: the decision follows the new name.
                if let a = acted, let old = a.profile, let new = r.profile(on: a.mark), old != new,
                   !profiles.contains(old), profiles.contains(new) {
                    var renamed = rules
                    renamed.renamed(old, to: new)
                    if renamed == r { acted?.profile = new }
                }
                // Otherwise only a new profile for this network is a change here.
                if let here = here(at: now), r.profile(on: here) != rules.profile(on: here) { since = now }
                rules = r
                byHand = false
            case .pickedByHand:
                if let here = here(at: now) { acted = AutoSwitch.Acted(mark: here, rules: rules) } else { byHand = reading != .offline }
            case .unapplied(let a):
                // Owed again, after the settle time, unless something newer was decided or picked meanwhile.
                if acted == a { acted = nil; since = now }
            case .busy(let b): busy = b
            case .profiles(let p): profiles = p
            case .timer: break
            }
            take(now)
        }
        return next(now)
    }

    /// A reading. Online throughout, the same place is the same network. Back from offline at the same place, it is the
    /// same network after a moment or a sleep, or when the last decision was on routers' fingerprints (read again and
    /// compared, waiting at most `AutoSwitch.lateRouter`): a network without a fingerprint has nothing else to tell it
    /// by, so going offline otherwise leaves it. Anything else is an arrival, which forgets what was decided.
    private mutating func network(_ r: Reading, _ now: Instant) {
        guard r != reading else { return }
        let before = reading
        reading = r
        since = now
        guard let place = r.place else {
            if let p = before.place { left = Left(place: p, at: now, slept: asleep) }
            return
        }
        // A network decided on by its routers is compared by them after any time offline; one without is left by it.
        let identified = acted.map { $0.mark != AutoSwitch.unrecognised } ?? false
        let same = if let was = before.place { Self.same(was, place) }
            else if let l = left { Self.same(l.place, place) && (l.slept || asleep || now - l.at <= AutoSwitch.blip || identified) }
            else { false }
        left = nil
        if !same { acted = nil; byHand = false; read = false; resolved = nil }
        switch r {
        case .mark(let m, _):
            read = true
            if let n = rules.network(m) { resolved = n.id }
            // Taken for a network unbraid couldn't recognise, and its routers answer at last for none remembered: the
            // same network still, by its own reading now.
            let id = rules.identity(m, preferring: resolved)
            if same, case .reading = before, acted?.mark == AutoSwitch.unrecognised, !rules.known.contains(where: { $0.id == id }) { acted?.mark = id }
        // A wait for an acceptable reading: the short one for a network just reached, the long one for this network
        // read again.
        case .reading: waiting = now; grace = same && (read || acted != nil) ? AutoSwitch.lateRouter : AutoSwitch.unrecognisedAfter
        case .offline: break
        }
    }

    /// Two places are one: the same interface, and the same IPv4 router where both have one (right after joining, the
    /// router may not be known yet).
    static func same(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: "|", omittingEmptySubsequences: false), y = b.split(separator: "|", omittingEmptySubsequences: false)
        guard x.first == y.first else { return false }
        let g = x.count > 1 ? x[1] : "", h = y.count > 1 ? y[1] : ""
        return g == h || g.isEmpty || h.isEmpty
    }

    /// A pick made while the network was being read counts as decided for the network the reading gives.
    private mutating func take(_ now: Instant) {
        guard byHand, let here = here(at: now) else { return }
        byHand = false
        acted = AutoSwitch.Acted(mark: here, rules: rules)
    }

    private mutating func next(_ now: Instant) -> Action {
        guard connected, !rules.isEmpty else { return .nothing }
        let due: Instant
        switch reading {
        case .offline: return .nothing
        case .mark: due = since + AutoSwitch.settle
        case .reading: due = max(since + AutoSwitch.settle, waiting + grace)
        }
        if now < due { return .wait(due) }
        // Decided once it settles (`busy(false)` comes back here).
        guard !busy, let here = here(at: now) else { return .nothing }
        let decided = AutoSwitch.Acted(mark: here, rules: rules), was = acted
        acted = decided
        return was == decided ? .nothing : .decide(mark: here, acted: was)
    }
}

extension AutoSwitchRun {
    /// Whether the setup after a switch needs more connections than a provider allows, counted against nothing in use:
    /// a switch the app would ask about (its limit question) is never started by itself, where no one is there to answer.
    static func over(_ next: Setup, limits: (String) -> Limit?) -> Bool {
        Limits.over(Setup(routes: [], defaultRoute: DIRECT), next, limits: limits) != nil
    }
}
