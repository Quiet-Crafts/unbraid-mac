import Foundation

/// When the profile for the network the Mac is on is decided, as a plain state machine the watcher feeds. What it
/// follows:
///
/// - The Mac stays on one network until it has been offline for more than a moment while awake, or reaches a network
///   through another interface or IPv4 router (an arrival). Sleep is not a change by itself: after a wake the network
///   is read again and compared.
/// - On the same network nothing switches, except for a new rule for it or a profile picked by hand. Its routers
///   coming and going within what a remembered network holds keep it that network.
/// - A network that gives no acceptable reading within `AutoSwitch.unrecognisedAfter` (20 s) counts as one unbraid can't
///   recognise (the profile for any other network): one wait, for every case.
/// - A remembered network read after that (a router that answered late) is a decision like any other: its rule's
///   profile. A hand pick made before ended when the network was counted as changed.
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
        /// The switch asked for decision `generation` wasn't made (the connection or the network changed meanwhile).
        case unapplied(Int)
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
    /// Where the Mac is: its interface and the last IPv4 router seen on it on this network (a router not known yet
    /// never stands in for a different one).
    struct Place: Equatable, Sendable {
        var interface: String
        var router: String?
        /// Whether a reading at `p` may be this place.
        func admits(_ p: String) -> Bool {
            let (i, r) = Self.split(p)
            return i == interface && (r == nil || router == nil || r == router)
        }
        static func split(_ p: String) -> (String, String?) {
            let parts = p.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let r = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            return (parts.first ?? "", r)
        }
    }
    private(set) var place: Place?
    /// While offline: when the Mac went, and whether it slept since.
    private(set) var offlineAt: Instant?
    private(set) var slept = false
    /// The Mac went to sleep while online: the next reading is compared, not taken as an arrival.
    private(set) var asleep = false
    /// This network has given an acceptable reading since it was reached.
    private(set) var read = false
    /// The remembered network a fresh reading on this network named on its own: a reading that two remembered networks
    /// would fit (a shared router, the other away) stays this one. Needs a reading again after more than a moment
    /// offline.
    private(set) var resolved: String?
    /// What was last decided on for this network (nil after an arrival: nothing yet).
    private(set) var acted: AutoSwitch.Acted?
    /// Counts decisions and hand picks: a report of a switch not made is about the decision it names only.
    private(set) var generation = 0
    /// A profile was picked by hand while this network was still being read.
    private(set) var byHand = false
    /// That pick was taken when the reading counted as unrecognised: it holds for the network's late answer too.
    private(set) var held = false

    init(rules: NetworkRules, now: Instant = .now) { self.rules = rules; since = now; waiting = now }

    /// The network decisions are about: a remembered network by its own name (the one a fresh reading here named, while
    /// its routers come and go), else the reading, `AutoSwitch.unrecognised` once a reading has waited too long; nil
    /// while offline or still waiting.
    func here(at now: Instant) -> String? {
        switch reading {
        case .offline: nil
        case .mark(let m, _): rules.identity(m, preferring: resolved)
        case .reading: now >= waiting + AutoSwitch.unrecognisedAfter ? AutoSwitch.unrecognised : nil
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
                if s, offlineAt != nil { slept = true }
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
                byHand = false; held = false
            case .pickedByHand:
                generation += 1; held = false
                if let here = here(at: now) { acted = AutoSwitch.Acted(mark: here, rules: rules) } else { byHand = reading != .offline }
            case .unapplied(let g):
                // Owed again, after the settle time, unless something newer was decided or picked meanwhile.
                if g == generation, acted != nil { acted = nil; since = now }
            case .busy(let b): busy = b
            case .profiles(let p): profiles = p
            case .timer: break
            }
            take(now)
        }
        return next(now)
    }

    /// A reading (see the type's principles): the same network or an arrival, and how long a missing reading may wait.
    private mutating func network(_ r: Reading, _ now: Instant) {
        guard r != reading else { return }
        let before = reading
        // Still waiting on the same network, only its router address now known: the same wait goes on.
        if case .reading = before, case .reading(let p) = r, let at = place, at.admits(p) {
            reading = r
            if let router = Place.split(p).1 { place?.router = router }
            return
        }
        reading = r
        since = now
        guard let p = r.place else {
            if before != .offline { offlineAt = now; slept = asleep }
            return
        }
        // A network decided on by its routers is compared by them after any time offline; one without is left by it.
        let identified = acted.map { $0.mark != AutoSwitch.unrecognised } ?? false
        let gap = offlineAt.map { now - $0 }
        let moment = gap.map { $0 <= AutoSwitch.blip } ?? true
        let same = place.map { $0.admits(p) && (moment || slept || asleep || identified) } ?? false
        offlineAt = nil; slept = false
        let (interface, router) = Place.split(p)
        if !same {
            acted = nil; byHand = false; held = false; read = false; resolved = nil
            place = Place(interface: interface, router: router)
        } else if let router { place?.router = router }
        // Back after more than a moment: what was decided stays to compare with, but which remembered network this is
        // takes a fresh reading.
        if !moment { resolved = nil; read = false }
        switch r {
        case .mark(let m, _):
            read = true
            // The network this one is already resolved as stays while the reading fits it.
            if let n = rules.network(m, preferring: resolved) { resolved = n.id }
            // Taken for a network unbraid couldn't recognise, and its routers answer at last for none remembered: the
            // same network still, by its own reading now.
            let id = rules.identity(m, preferring: resolved)
            if same, case .reading = before, acted?.mark == AutoSwitch.unrecognised, !rules.known.contains(where: { $0.id == id }) { acted?.mark = id }
        // The one wait for an acceptable reading.
        case .reading: waiting = now
        case .offline: break
        }
    }


    /// A pick made while the network was being read counts as decided for the network being read: taken at the reading's
    /// first result, and held if that was "unrecognised" for whatever the routers answer later on this network.
    private mutating func take(_ now: Instant) {
        guard byHand, let here = here(at: now) else { return }
        byHand = false
        held = here == AutoSwitch.unrecognised
        acted = AutoSwitch.Acted(mark: here, rules: rules)
    }

    private mutating func next(_ now: Instant) -> Action {
        guard connected, !rules.isEmpty else { return .nothing }
        let due: Instant
        switch reading {
        case .offline: return .nothing
        case .mark: due = since + AutoSwitch.settle
        case .reading: due = max(since + AutoSwitch.settle, waiting + AutoSwitch.unrecognisedAfter)
        }
        if now < due { return .wait(due) }
        // Decided once it settles (`busy(false)` comes back here).
        guard !busy, let here = here(at: now) else { return .nothing }
        // A pick made while this network was read holds whatever its routers turned out to be.
        if held, here != AutoSwitch.unrecognised, acted?.mark == AutoSwitch.unrecognised {
            held = false
            acted = AutoSwitch.Acted(mark: here, rules: rules)
            return .nothing
        }
        // What was decided here was not a remembered network: this network read again without an answer is still it.
        if here == AutoSwitch.unrecognised, let a = acted, !rules.known.contains(where: { $0.id == a.mark }),
           a.profile == rules.profile(on: here) { return .nothing }
        let decided = AutoSwitch.Acted(mark: here, rules: rules), was = acted
        acted = decided
        guard was != decided else { return .nothing }
        held = false
        generation += 1
        return .decide(mark: here, acted: was)
    }
}

extension AutoSwitchRun {
    /// Whether the setup after a switch needs more connections than a provider allows, counted against nothing in use:
    /// a switch the app would ask about (its limit question) is never started by itself, where no one is there to answer.
    static func over(_ next: Setup, limits: (String) -> Limit?) -> Bool {
        Limits.over(Setup(routes: [], defaultRoute: DIRECT), next, limits: limits) != nil
    }
}
