import Foundation

/// When the profile for the network the Mac is on is decided, as a plain state machine the watcher feeds: only while
/// connected, once a network has stayed the same for `AutoSwitch.settle`, and once per network and rules. What was
/// decided on is kept in memory only, so after a restart the first connect decides again.
nonisolated struct AutoSwitchRun: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        /// The fingerprint of the network the Mac is on now; nil with none, or while its router hasn't answered.
        case network(String?)
        case connected(Bool)
        case rules(NetworkRules)
        /// A profile was chosen by hand (the menu bar, the window, Control Center, Shortcuts).
        case pickedByHand
        /// Nothing may be decided now: a profile switch is still pending, or the setup is a stand-in.
        case busy(Bool)
        /// The settle time asked for has passed.
        case timer
    }

    enum Action: Equatable, Sendable {
        /// No timer is needed.
        case nothing
        /// Look again at that moment (the timer, replacing any other).
        case wait(Date)
        /// Decide now on network `mark`; `acted` is what was decided on before, for `AutoSwitch.decide`.
        case decide(mark: String, acted: AutoSwitch.Acted?)
    }

    private(set) var mark: String?
    private(set) var connected = false
    private(set) var rules: NetworkRules
    private(set) var busy = false
    /// Since when the network, the connection and the rules have been as they are.
    private(set) var since: Date
    private(set) var acted: AutoSwitch.Acted?
    /// Picked by hand while no network was known: the next one seen counts as decided.
    private(set) var byHand = false

    init(rules: NetworkRules, now: Date = .now) { self.rules = rules; since = now }

    mutating func handle(_ event: Event, now: Date = .now) -> Action { handle([event], now: now) }

    /// Several things that changed together, taken in before anything is decided: a switch never starts on a state
    /// half taken in (connected, but not yet seen as busy).
    mutating func handle(_ events: [Event], now: Date = .now) -> Action {
        for event in events {
            switch event {
            case .network(let m): if m != mark { mark = m; since = now }
            case .connected(let c): if c != connected { connected = c; since = now }
            // New rules apply to the network the Mac is on now, a hand-picked profile included.
            case .rules(let r): if r != rules { rules = r; acted = nil; byHand = false; since = now }
            // Counts as decided for the network it was picked on: nothing changes it until the network or the rules do.
            case .pickedByHand: if let mark { acted = AutoSwitch.Acted(mark: mark, rules: rules) } else { byHand = true }
            case .busy(let b): busy = b
            case .timer: break
            }
        }
        return next(now)
    }

    private mutating func next(_ now: Date) -> Action {
        guard connected, let mark, !rules.isEmpty else { return .nothing }
        let due = since.addingTimeInterval(Double(AutoSwitch.settle.components.seconds))
        if now < due { return .wait(due) }
        // Decided once it settles (`busy(false)` comes back here).
        guard !busy else { return .nothing }
        let here = AutoSwitch.Acted(mark: mark, rules: rules), was = acted
        acted = here
        if byHand { byHand = false; return .nothing }
        return was == here ? .nothing : .decide(mark: mark, acted: was)
    }
}

extension AutoSwitchRun {
    /// Whether the setup after a switch needs more connections than a provider allows, counted against nothing in use:
    /// a switch the app would ask about (its limit question) is never started by itself, where no one is there to answer.
    static func over(_ next: Setup, limits: (String) -> Limit?) -> Bool {
        Limits.over(Setup(routes: [], defaultRoute: DIRECT), next, limits: limits) != nil
    }
}
