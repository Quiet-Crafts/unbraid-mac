import Foundation

/// When the profile for the network the Mac is on is decided, as a plain state machine the watcher feeds: only while
/// connected, once a network has stayed the same for `AutoSwitch.settle`, and once per network and the profile its rule
/// names. What was decided on is kept in memory only, so after a restart the first connect decides again. Times are on
/// the continuous clock: setting the Mac's clock never stretches or skips a wait.
nonisolated struct AutoSwitchRun: Equatable, Sendable {
    typealias Instant = ContinuousClock.Instant

    /// What is known of the network the Mac is on.
    enum Reading: Equatable, Sendable {
        /// No Wi-Fi or cable.
        case offline
        /// On a network whose fingerprint isn't read: its router hasn't answered yet, or it has nothing unbraid may tell
        /// it by. After `AutoSwitch.unrecognisedAfter` it counts as a network unbraid can't recognise.
        case reading
        /// On the network with this fingerprint.
        case mark(String)
    }

    enum Event: Equatable, Sendable {
        case network(Reading)
        case connected(Bool)
        case rules(NetworkRules)
        /// The names of the saved profiles, sent before the rules: they tell a rename from a rule set to another profile.
        case profiles([String])
        /// A profile was chosen by hand (the menu bar, the window, Control Center, Shortcuts).
        case pickedByHand
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
    /// Since when the network has read as it does.
    private(set) var heard: Instant
    private(set) var acted: AutoSwitch.Acted?
    /// When a profile was picked by hand while no network was known: the network known next counts as decided, if it
    /// is known within `AutoSwitch.unrecognisedAfter` of the pick.
    private(set) var byHand: Instant?

    init(rules: NetworkRules, now: Instant = .now) { self.rules = rules; since = now; heard = now }

    /// The network decisions are about: its fingerprint, `AutoSwitch.unrecognised` for one that gave none in time, nil
    /// while offline or still reading.
    func network(at now: Instant) -> String? {
        switch reading {
        case .offline: nil
        case .mark(let m): m
        case .reading: now >= heard + AutoSwitch.unrecognisedAfter ? AutoSwitch.unrecognised : nil
        }
    }

    mutating func handle(_ event: Event, now: Instant = .now) -> Action { handle([event], now: now) }

    /// Several things that changed together, taken in before anything is decided: a switch never starts on a state
    /// half taken in (connected, but not yet seen as busy).
    mutating func handle(_ events: [Event], now: Instant = .now) -> Action {
        for event in events {
            // A network that became one unbraid can't recognise before this event did so at that moment.
            take(now)
            switch event {
            case .network(let r):
                guard r != reading else { break }
                reading = r; heard = now; since = now
                // The network a pick was waiting for is gone.
                if r == .offline { byHand = nil }
            case .connected(let c): if c != connected { connected = c; since = now }
            case .rules(let r):
                guard r != rules else { break }
                // Only a new profile for this network is a change here: a hand pick stays through edits about others,
                // and through a rename of the profile its rule names (what was decided follows the new name).
                if let here = network(at: now), case let (old, new) = (rules.profile(on: here), r.profile(on: here)), old != new {
                    var renamed = rules
                    if let old, let new { renamed.renamed(old, to: new) }
                    if let old, let new, !profiles.contains(old), profiles.contains(new), renamed == r,
                       acted == AutoSwitch.Acted(mark: here, rules: rules) {
                        acted = AutoSwitch.Acted(mark: here, rules: r)
                    } else { since = now }
                }
                rules = r
                byHand = nil
            // Counts as decided for the network it was picked on: nothing changes it until the network or its rule does.
            case .pickedByHand:
                if let here = network(at: now) { acted = AutoSwitch.Acted(mark: here, rules: rules) } else { byHand = now }
            case .busy(let b): busy = b
            case .profiles(let p): profiles = p
            case .timer: break
            }
            take(now)
        }
        return next(now)
    }

    /// A pick waiting for the network: it counts as decided for the network once that is known, if soon enough.
    private mutating func take(_ now: Instant) {
        guard let picked = byHand, let here = network(at: now) else { return }
        byHand = nil
        // Known at the moment it read as unrecognised, or now for a fingerprint (taken as it comes in).
        let known = reading == .reading ? heard + AutoSwitch.unrecognisedAfter : now
        if known <= picked + AutoSwitch.unrecognisedAfter { acted = AutoSwitch.Acted(mark: here, rules: rules) }
    }

    private mutating func next(_ now: Instant) -> Action {
        guard connected, !rules.isEmpty else { return .nothing }
        let due: Instant
        switch reading {
        case .offline: return .nothing
        case .mark: due = since + AutoSwitch.settle
        case .reading: due = max(since + AutoSwitch.settle, heard + AutoSwitch.unrecognisedAfter)
        }
        if now < due { return .wait(due) }
        // Decided once it settles (`busy(false)` comes back here).
        guard !busy, let here = network(at: now) else { return .nothing }
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
