import Foundation

/// The engine said no to a configuration (the compiler couldn't build it, or the engine rejected it): asking again with
/// the same inputs gets the same answer, so it is retried only once they change.
nonisolated struct Refused: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// When a change that didn't take is tried again. A refused one waits for different inputs. One that failed for a
/// passing reason (the engine didn't answer, a provider was offline, a reload timed out) is tried again after a wait
/// that grows with each failure. One that failed after the tunnel had already changed (rolled back, a moment without
/// it) is given up after `limit` such failures, so a configuration the engine can't run doesn't interrupt the
/// connection every few minutes for good.
nonisolated struct Retry<Key: Equatable & Sendable>: Sendable {
    static var delays: [Duration] { [.seconds(10), .seconds(30), .seconds(60), .seconds(120), .seconds(300), .seconds(600)] }
    static var limit: Int { 3 }

    private(set) var key: Key?
    private var refused = false
    private var failures = 0
    private var disruptions = 0
    private var due: ContinuousClock.Instant?

    /// Retried only once the inputs differ.
    mutating func refuse(_ k: Key) {
        // The same inputs keep their count of disruptions: refusing does not wipe what was spent.
        let spent = k == key ? disruptions : 0
        self = Retry()
        key = k
        refused = true
        disruptions = spent
    }

    /// A passing failure of [k]: the wait before trying it again, or nil when it is refused from now on.
    mutating func failed(_ k: Key, disrupted: Bool, now: ContinuousClock.Instant) -> Duration? {
        if k != key { self = Retry(); key = k }
        else if refused { refused = false; failures = 0; due = nil }
        if disrupted { disruptions += 1 }
        if disruptions >= Self.limit { refuse(k); return nil }
        let wait = Self.delays[min(failures, Self.delays.count - 1)]
        failures += 1
        due = now + wait
        return wait
    }

    /// Whether [k] may be tried now: any other inputs always may.
    func allows(_ k: Key, now: ContinuousClock.Instant) -> Bool {
        guard k == key else { return true }
        return !refused && due.map { now >= $0 } ?? true
    }

    func refuses(_ k: Key) -> Bool { refused && k == key }

    mutating func clear() { self = Retry() }
}

/// Decisions about the running tunnel that need no tunnel, kept here so they can be tested.
nonisolated enum Lifecycle {
    enum QuitPause: Equatable { case wait, resume, done }

    /// On or connecting can be a pause still being applied. Once it settles, resume only that same timed pause.
    static func quitPause(phase: Snapshot.Phase, timed: Bool, current: Int, expected: Int) -> QuitPause {
        guard timed, current == expected else { return .done }
        switch phase {
        case .on, .connecting: return .wait
        case .paused: return .resume
        default: return .done
        }
    }

    /// A sign-in failure while changing the setup ends the connection, credentials and all, only when the running
    /// configuration holds an account the user no longer has: signed out, or replaced by another sign-in. A provider
    /// refusing an account that is still signed in (an expired session, its device limit, a captcha) changes nothing that
    /// runs: the running configuration stays, and the error is shown. [applied] nil = not known (a tunnel taken over):
    /// then only a missing account counts.
    static func revokes(running: Setup?, linked: Set<String>, applied: [String: String]?, accounts: [String: String]) -> Bool {
        guard let running else { return false }
        return running.activeRoutes.contains { r in
            guard !r.imported, linked.contains(r.id) else { return false }
            let p = r.loc.provider
            return accounts[p] == nil || applied.map { $0[p] != accounts[p] } ?? false
        }
    }

    enum SignOutChange: Equatable { case unchanged, replace, teardown }

    /// A partial sign-out may keep the tunnel only after its replacement was sealed successfully.
    static func signOutChange(running: Setup?, linked: Set<String>, applied: [String: String]?, accounts: [String: String]) -> SignOutChange {
        guard let running, revokes(running: running, linked: linked, applied: applied, accounts: accounts) else { return .unchanged }
        let routes = running.activeRoutes.filter { linked.contains($0.id) }
        let missing = routes.filter { !$0.imported && accounts[$0.loc.provider] == nil }
        // A replaced account retains the existing revocation behavior.
        guard !missing.isEmpty,
              !routes.contains(where: { r in
                  !r.imported && accounts[r.loc.provider] != nil && (applied.map { $0[r.loc.provider] != accounts[r.loc.provider] } ?? false)
              }),
              missing.count < routes.count else { return .teardown }
        return .replace
    }

    static func requiresDurable(_ change: SignOutChange) -> Bool { change == .replace }

    /// An interim may have sealed the sign-out already. A different final configuration still needs a durable apply.
    static func needsApply(signOut: SignOutChange, sealedInterim: Bool, changed: Bool) -> Bool {
        changed || (signOut == .replace && !sealedInterim)
    }

    /// Moving a dead server on an interim tries the edit itself, with any failure counted against that edit.
    static func retryEdit(interim: Bool, health: Bool, allowed: Bool) -> Bool {
        allowed || (interim && health)
    }

    /// Ordinary route retries cannot bypass an interim edit's backoff or refusal.
    static func mayRetryCommitted(interim: Bool, allowed: Bool) -> Bool {
        !interim || allowed
    }


    static func mayApply(persist: Bool, requireDurable: Bool) -> Bool { persist || !requireDurable }

    static func endTesting(base: Setup?, accounts: [String: String]?, setup: Setup, currentAccounts: [String: String]) -> Bool {
        base != setup || accounts != currentAccounts
    }

    static func revokeAfterApplyFailure(_ change: SignOutChange, revokes: Bool) -> Bool {
        requiresDurable(change) || revokes
    }

    /// A confirmed replacement settles only the sign-out it was prepared for, without a link for that provider.
    static func signOutSettled(provider: String, requested: Int?, current: Int?, accounts: [String: String],
                               setup: Setup, links: Set<String>, fits: Bool, persisted: Bool) -> Bool {
        guard persisted, fits, !provider.isEmpty, let requested, requested == current, accounts[provider] == nil else { return false }
        return !setup.activeRoutes.contains { !$0.imported && $0.loc.provider == provider && links.contains($0.id) }
    }

    static func testTransition(from old: Setup, to wanted: Setup, sameAccounts: Bool) -> Bool {
        guard sameAccounts, !old.testing.isEmpty || !wanted.testing.isEmpty else { return false }
        var a = old, b = wanted
        a.testing = []; b.testing = []
        return a == b
    }

    static func acceptsTakeover(_ blocked: [String: LinkPicker.Blocked], activeRoutes: Int) -> Bool {
        (activeRoutes == 0 || blocked.count < activeRoutes) &&
            blocked.values.allSatisfy { if case .signedOut = $0 { return true }; return false }
    }

    static func holds(_ provider: String, setup: Setup, linked: Set<String>?) -> Bool {
        provider.isEmpty || setup.activeRoutes.contains { !$0.imported && $0.loc.provider == provider && (linked?.contains($0.id) ?? true) }
    }

    /// Which accounts a running tunnel was started with, as far as its record says, against those signed in now.
    /// Ordered from fine to worst.
    enum Provenance: Int, Comparable, Sendable {
        /// Every provider route runs the account still signed in.
        case same
        /// Nothing says which account a provider route runs: no record of it, or one from an older version without
        /// fingerprints, or none for that provider.
        case unknown
        /// A provider route runs an account that was signed out, or replaced by another sign-in.
        case replaced, signedOut
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// The worst [Provenance] of the record's provider routes (imported servers and Tailscale have no account). [record]:
    /// the running record's setup and its account fingerprints (`Running.State`); nil when there is no record at all, which
    /// says nothing about what runs whatever today's setup holds. A missing account counts before a missing fingerprint.
    static func provenance(_ record: (setup: Setup, linked: Set<String>, made: [String: String]?)?, accounts: [String: String],
                           fingerprint: (String) -> String) -> Provenance {
        guard let record else { return .unknown }
        return record.setup.activeRoutes.filter { !$0.imported && record.linked.contains($0.id) }.map { r -> Provenance in
            let p = r.loc.provider
            guard let account = accounts[p] else { return .signedOut }
            guard let made = record.made?[p] else { return .unknown }
            return made == fingerprint(account) ? .same : .replaced
        }.max() ?? .same
    }

    /// What the extension says about the engine: the revision of the configuration it runs for this user (nil when none
    /// of theirs runs), of their sealed copy, and whether it runs for another user (`TunnelControl.revisions`).
    /// [startable]: the extension has a sealed copy an unattended start runs, this user's or another's.
    /// [fallback]: the sealed copy is this user's credential-free fallback (`fallbackNeeded`), which counts as nothing of
    /// theirs to start ([durable] nil, [startable] false); [fallbackRunning]: their engine runs it. [othersFallback]: the
    /// sealed copy is another user's fallback, which counts as nothing to start either ([startable] false).
    struct Engine: Equatable, Sendable {
        var running: String?
        var durable: String?
        var foreign: Bool
        var startable: Bool
        var fallback = false
        var fallbackRunning = false
        var othersFallback = false
        init(running: String?, durable: String?, foreign: Bool, startable: Bool = false, fallback: Bool = false, fallbackRunning: Bool = false,
             othersFallback: Bool = false) {
            self.running = running; self.durable = durable; self.foreign = foreign; self.startable = startable
            self.fallback = fallback; self.fallbackRunning = fallbackRunning; self.othersFallback = othersFallback
        }
    }

    typealias Revisions = (running: String?, durable: String?, foreign: Bool, startable: Bool, fallback: Bool, fallbackRunning: Bool,
                           othersFallback: Bool, foreignFallback: Bool)

    /// The extension's `revisions` answer as this app reads it (`TunnelControl.revisions`): this user's credential-free
    /// fallback ("fallback-durable", `fallbackNeeded`) isn't theirs to start, so it counts as no sealed copy and nothing
    /// startable, and is told as [fallback] instead; [fallbackRunning] while their engine runs it. Another user's fallback
    /// is nothing to start either: Connect on Demand had to go off for them, and it isn't kept on for it here
    /// ([othersFallback]); [foreignFallback] while their engine runs it (no VPN, as is said).
    static func revisions(_ r: [String: String]) -> Revisions {
        let anyFallback = r["fallback-durable"] != nil
        let fallback = anyFallback && r["durable"] != nil
        return (r["running"], fallback ? nil : r["durable"], r["foreign"] != nil, !anyFallback && r["startable"] != nil, fallback,
                r["fallback-running"] != nil && r["running"] != nil, anyFallback && r["durable"] == nil && r["startable"] != nil,
                r["fallback-running"] != nil && r["foreign"] != nil)
    }

    /// Whether Connect on Demand may stay on while nothing of this user's runs (after a stop unbraid didn't ask for, or
    /// when the copy it would start was refused or dropped): macOS starts the sealed copy whenever traffic wants out, and
    /// one the extension won't start (none, or one an older version sealed) fails every time, which with the kill switch
    /// keeps the Mac offline. So it stays on only for a copy of this user's to start ([engine], nil when the extension
    /// didn't answer: not known, so off), and never while a drop of the sealed copy a sign-out asked for is still owed
    /// ([owed]). Another user's engine, or another user's copy to start, is theirs: left as it is.
    enum OnDemandHold: Equatable, Sendable { case keep, disarm, leave }

    static func onDemandHold(engine: Engine?, owed: Bool) -> OnDemandHold {
        guard let engine else { return .disarm }
        if engine.foreign { return .leave }
        // Another user's copy is what it would start (none of this user's is sealed, so no drop of theirs is in it).
        if engine.durable == nil, engine.startable { return .leave }
        if owed { return .disarm }
        return engine.durable != nil ? .keep : .disarm
    }

    /// Why a running tunnel a takeover couldn't take over is turned off for good (stopped, on-demand off, sealed copy
    /// dropped): its account was signed out or replaced, its provider no longer vouches for a server, or nothing says which
    /// account it uses.
    enum Revocation: Equatable, Sendable { case signedOut, unvouched, unknown }

    /// Why a tunnel waiting to be taken over must not keep running: it runs an account signed out or replaced since
    /// (whenever that is found), or, once a takeover of it [failed], a server its provider no longer vouches for or an
    /// account nothing names. Nil: it may keep running while the takeover is retried.
    static func revocation(provenance: Provenance, unvouched: Bool, failed: Bool) -> Revocation? {
        if provenance >= .replaced { return .signedOut }
        guard failed else { return nil }
        if unvouched { return .unvouched }
        return provenance == .unknown ? .unknown : nil
    }

    /// What follows a failed takeover: leave it (another user's), revoke it, stop it (on-demand stays), or keep it running
    /// and try again later (`disrupted`: the attempt may have stopped and restarted the tunnel).
    enum TakeoverFailure: Equatable, Sendable { case leave, revoke(Revocation), stop, retry(disrupted: Bool) }

    /// [foreign]: the failure said another user's engine runs. [unvouched]: the record holds a server its provider no
    /// longer vouches for. [admitted]: the attempt got as far as changing the engine; [unstaged]: it failed at staging,
    /// before anything changed. [onDemand]: macOS starts the tunnel again by itself. [engine]: the extension's answer,
    /// asked after the failure; nil when it didn't answer.
    /// Nothing is stopped without the extension's word that the engine is this user's: its ownership check gives up after
    /// seconds, and a tunnel another user started (fast user switching) must never be stopped by a failure here. Without
    /// that word the tunnel keeps running and the takeover is tried again.
    /// [blocker]: the revision of the deny-all a failed change left running, if one did (`Running.blocker`): it holds no
    /// account, so whatever the record says, it is never stopped while it runs.
    static func takeoverFailure(foreign: Bool, provenance: Provenance, unvouched: Bool, admitted: Bool, unstaged: Bool,
                                onDemand: Bool, engine: Engine?, blocker: String? = nil) -> TakeoverFailure {
        if foreign || engine?.foreign == true { return .leave }
        let retry = TakeoverFailure.retry(disrupted: admitted && !unstaged)
        if let blocker, engine?.running == blocker { return retry }
        if let why = revocation(provenance: provenance, unvouched: unvouched, failed: true) { return engine?.running != nil ? .revoke(why) : retry }
        // Untouched, or something macOS starts again by itself: stopping it would only start a stop, restart, take-over
        // loop. So would stopping the sealed copy itself.
        if !admitted || unstaged || onDemand { return retry }
        guard let running = engine?.running else { return retry }
        return running == engine?.durable ? retry : .stop
    }

    /// [updated]: this user's copy was sealed by another build of unbraid, so an update may be why the extension refuses it.
    /// `unknown`: the extension never answered, so whether Connect on Demand has anything to start isn't known.
    enum Reseal: Equatable, Sendable { case none, connect, tell(updated: Bool), unknown }

    /// While off with Connect on Demand on: whether the extension has a sealed copy of this user's to start ([engine], nil
    /// when it didn't answer). The VPN profile, and so Connect on Demand, is the same for every user of the Mac: it may be
    /// another user's ([wanted]: this user's own setting), and nothing to do with this user then.
    /// None, and this user's copy was sealed by an earlier build ([sealedBy], nil when no seal of theirs is on record; [build]
    /// this one), or nothing says (no build that records it ran before: [previous], the build launched before this one, is
    /// nil): an update may be why. On the first launch after it, connect again, which seals anew, when the setup is readable
    /// ([ready]) and the record of what ran says the accounts are the ones signed in ([provenance], nil without a record).
    /// Otherwise tell the user to connect once: a user whose own copy was never sealed never connects by itself because
    /// another user's copy is the one the extension has, and a launch after that first one doesn't either.
    /// [stopped]: as for `ready`, never connected again for it.
    static func reseal(engine: Engine?, ready: Bool, provenance: Provenance?, sealedBy: String?, previous: String?, build: String,
                       wanted: Bool, stopped: Bool = false) -> Reseal {
        guard wanted else { return .none }
        guard let engine else { return .unknown }
        guard !engine.foreign, engine.running == nil, engine.durable == nil else { return .none }
        let updated = sealedBy.map { $0 != build } ?? (previous == nil)
        // Another user's copy is the one Connect on Demand starts: never replaced by a connect nobody asked for.
        // Nor while a fallback is there (this user's or another's): Connect on Demand had to go off, and that is still owed.
        return updated && previous != build && ready && provenance == .same && !engine.startable && !engine.fallback && !engine.othersFallback
            && !stopped
            ? .connect : .tell(updated: updated)
    }

    /// What a pause's blocking engine needs, given what it is built from now ([wanted]), what the paused engine runs
    /// ([running], nil = none) and whether the tunnel is up. `clear`: a failure or a retry left from earlier no longer
    /// applies (shown, or waiting).
    enum PauseStep: Equatable, Sendable { case converged(clear: Bool), wait, apply, stop, idle(clear: Bool) }

    static func pauseStep(wanted: PauseKey, running: PauseKey?, connected: Bool, retry: Retry<PauseKey>,
                          now: ContinuousClock.Instant) -> PauseStep {
        guard !wanted.setup.apps.isEmpty else { return running != nil || connected ? .stop : .idle(clear: retry.key != nil) }
        if running == wanted, connected { return .converged(clear: retry.key != nil) }
        return retry.allows(wanted, now: now) ? .apply : .wait
    }

    /// Whether a paused engine already runs [json], what a changed `PauseKey` compiles to: it is what was last applied
    /// ([applied]), and the extension says that revision still runs for this user ([running], as `revisions()` reports
    /// it; nil = no answer), not a copy started since (Connect on Demand).
    static func pauseRuns(_ json: String, applied: (json: String, revision: String)?,
                          running: (running: String?, durable: String?, foreign: Bool)?) -> Bool {
        guard let applied, applied.json == json, let running, !running.foreign else { return false }
        return running.running == applied.revision
    }

    /// A pause that looks converged (`pauseStep`) against what the extension says runs ([engine], nil = no answer): the
    /// revision the pause applied ([applied], nil = not known) still runs, or something restarted the tunnel since without
    /// the app seeing it stop (Connect on Demand starting the sealed copy) and the pause is applied again. Never stopped
    /// for want of an answer: no answer, or none of this user's engines running right now (one may be starting), is asked
    /// again later. Another user's engine is theirs: left alone. An unknown revision is never taken for the pause's own.
    enum PauseCheck: Equatable, Sendable { case runs, ask, leave, reapply }

    static func pauseCheck(applied: String?, engine: Engine?) -> PauseCheck {
        guard let engine else { return .ask }
        if engine.foreign { return .leave }
        guard let running = engine.running else { return .ask }
        return running == applied ? .runs : .reapply
    }

    /// A tunnel status, as the decisions here need it.
    enum Status: Equatable, Sendable { case connected, connecting, stopping, stopped }

    /// Whether a status change is a stop of what runs that nobody here asked for (System Settings, `scutil`, macOS, the
    /// engine ending): connected ([phase] on), or paused with the blocking engine the pause applied ([applied]), and no
    /// operation of the app's under way that may stop the tunnel itself ([settled]; its own restarts show connecting first).
    static func stoppedOutside(phase: Snapshot.Phase, applied: Bool, settled: Bool, status: Status) -> Bool {
        guard settled, status == .stopping || status == .stopped else { return false }
        return phase == .on || phase == .paused && applied
    }

    /// How long a converged pause waits before the extension is asked again, after it didn't answer: until [until] (nil:
    /// asked now). The probe is armed for that same time, so changes meanwhile never put the question off.
    static func pauseAskWait(until: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Duration? {
        guard let until, now < until else { return nil }
        return until - now
    }

    /// A change that restarts the tunnel had its own start come up ([reached]), and the tunnel is going down now: stopped
    /// by nobody here (System Settings, `scutil`, the engine ending), since nothing of the change stops it after that.
    /// Ended like any stop from outside, never recovered from: putting the previous configuration back would start the
    /// tunnel again. The change shows connecting meanwhile, which `stoppedOutside` can't tell from the app's own stops.
    static func stoppedAfterRestart(reached: Bool, status: Status) -> Bool {
        reached && (status == .stopping || status == .stopped)
    }

    /// While off, the tunnel went down again with Connect on Demand on: macOS keeps starting it, and a start the extension
    /// refuses fails each time. Whether it has anything to start is asked a moment after (`onDemandHold`), and then no
    /// more than once a minute however often it tries: [last] the time it was last asked. Not before [ready] while the
    /// launch's own check of the extension (which may connect instead) hasn't run.
    static func idleHoldWait(last: ContinuousClock.Instant?, now: ContinuousClock.Instant, ready: ContinuousClock.Instant? = nil) -> Duration {
        max(.seconds(3), last.map { $0 + .seconds(60) - now } ?? .zero, ready.map { $0 - now } ?? .zero)
    }

    /// Connect on Demand has to go off and that isn't saved yet, kept on disk so a relaunch still does it before anything
    /// is armed: `off` the user's own Off (Disconnect, Settings, a sign-out's erase), off whatever is sealed; `hold` decided
    /// again on what the extension has (`onDemandHold`). The user's Off wins.
    enum OnDemandOwed: String, Equatable, Sendable {
        case off, hold

        init?(offWanted: Bool, disarmPending: Bool) {
            if offWanted { self = .off } else if disarmPending { self = .hold } else { return nil }
        }
    }

    /// Before a drop of the sealed copy (a sign-out, an erase): Connect on Demand goes off first, so a quit or a crash
    /// once the copy is gone can't leave it on with nothing to start, but only when the copy may be this user's (the
    /// extension names its sealing, [seal]), or when the extension didn't answer ([answered]: nothing is known, so off).
    /// Another user's copy is theirs for it to start: decided after the drop, on what is left.
    static func disarmFirst(answered: Bool, seal: String?) -> Bool { !answered || seal != nil }

    /// An Off of the user's read from before this launch (`OnDemandOwed.off`): Connect on Demand is the Mac's, and another
    /// user may have turned it on since (fast user switching) for a copy of theirs, or their engine runs ([engine]: what
    /// `onDemandHold` leaves). Then it is theirs, and the Off is decided again (`hold`) instead of turning it off whatever is
    /// sealed. Otherwise, and when the extension didn't answer, it stays the user's Off. One made this session keeps its
    /// meaning (it isn't asked).
    static func loadedOff(engine: Engine?) -> OnDemandOwed { onDemandHold(engine: engine, owed: true) == .leave ? .hold : .off }

    /// A drop a sign-out still owes was refused as superseded: the copy it named was sealed again since. What the extension
    /// says now ([now]: the sealing it names, and the user's copy an unattended start runs; nil when it didn't answer)
    /// settles it once nothing of the user's is there, or a complete copy is that this app sealed itself after the drop
    /// named the old one ([sealedSince]: asked after the sign-out, with its accounts as they were then, and confirmed; only
    /// a sealing that finished leaves a complete copy). Anything else may still hold the signed-out account: a sealing asked
    /// before the sign-out that landed late, or one that didn't finish and left the old file on disk, set aside. Dropped
    /// as named now (`renamed`). No answer: asked again (`later`).
    /// A credential-free fallback sealed since ([fallback]) holds no account: settled too.
    enum SupersededDrop: Equatable, Sendable { case settled, renamed(String), later }

    static func supersededDrop(now: (seal: String?, durable: String?)?, sealedSince: Bool, fallback: Bool = false) -> SupersededDrop {
        guard let now else { return .later }
        guard let seal = now.seal, !fallback else { return .settled }
        return now.durable != nil && sealedSince ? .settled : .renamed(seal)
    }

    /// After a drop or an erase removed the sealed copy, or when Connect on Demand had to go off for want of anything to
    /// start, and turning it off couldn't be saved: left on with nothing to start, macOS keeps trying, which with the kill
    /// switch keeps the Mac offline. A credential-free fallback is sealed in its place (`Compiler.fallback`: everything
    /// direct), so what it starts keeps the Mac online: when Connect on Demand is on or can't be read ([onDemand]), the
    /// extension answered ([engine]), no other user's engine runs, nothing at all is startable (another user's copy is
    /// theirs to start) and no fallback is there yet (another user's keeps the Mac online just as well).
    static func fallbackNeeded(onDemand: Bool?, engine: Engine?) -> Bool {
        guard onDemand != false, let engine, !engine.foreign, !engine.fallback, !engine.othersFallback else { return false }
        return engine.durable == nil && !engine.startable
    }

    /// A fallback (`fallbackNeeded`) running while this app is off: stopped once Connect on Demand is off (nothing starts
    /// it again), otherwise left running, and said: stopping it would only have macOS start it again.
    enum FallbackAdoption: Equatable, Sendable { case stop, show }

    static func fallbackAdoption(onDemand: Bool?) -> FallbackAdoption { onDemand == false ? .stop : .show }

    /// What becomes of a fallback once Connect on Demand may be off: dropped like any copy once it is ([stop]: its engine
    /// runs while this app is [off], stopped first), kept while it is on (it is what keeps the Mac online), asked again when
    /// either can't be told. [engine] nil: the extension didn't answer.
    enum FallbackRetire: Equatable, Sendable { case none, keep, drop(stop: Bool), later }

    static func fallbackRetire(onDemand: Bool?, engine: Engine?, off: Bool) -> FallbackRetire {
        guard let engine else { return .later }
        guard engine.fallback || engine.fallbackRunning && off else { return .none }
        switch onDemand {
        case false?: return .drop(stop: engine.fallbackRunning && off)
        case true?: return .keep
        case nil: return .later
        }
    }
}

nonisolated extension Lifecycle {
    /// While a deny-all stands in for a change that failed ([blocking], `Connection.recover`), a change that can't be applied
    /// either still moves apps between Direct and blocked: the deny-all of the setup as it is now ([fresh] its configuration
    /// and search domain, nil when it couldn't be built) needs no server and no account. Put in place when it differs from
    /// the one [running], never from stand-ins for a setup the keychain won't open yet ([held]).
    static func reblock(blocking: Bool, held: Bool, running: (json: String, search: String), fresh: (json: String, search: String)?) -> Bool {
        guard blocking, !held, let fresh else { return false }
        return fresh != running
    }

    /// A sign-out's erase still pending while a tunnel runs (a quit interrupted it): stop that tunnel and erase, leave it
    /// (another user's), or keep it running and ask again. Stopped only on the extension's word that it runs this user's
    /// engine ([engine], nil when it didn't answer): its ownership check gives up after seconds, and another user's tunnel
    /// must never be stopped from here. The erase waits with it: it would wait for this tunnel to stop.
    enum Interrupted: Equatable, Sendable { case stop, foreign, wait }

    static func interruptedSignOut(engine: Engine?) -> Interrupted {
        guard let engine else { return .wait }
        if engine.foreign { return .foreign }
        return engine.running != nil ? .stop : .wait
    }

    /// Whether an interrupted sign-out's erase stops the tunnel now (`interruptedSignOut`): not while it runs this user's
    /// fallback ([fallbackRunning]), no copy of theirs an unattended start runs is sealed ([durable]: one sealed since
    /// still goes first), and Connect on Demand is on or can't be read ([onDemand]). The fallback holds no account, and
    /// macOS would only start it again, offline meanwhile; the erase follows once it has stopped (Connect on Demand off).
    static func eraseStop(fallbackRunning: Bool, durable: Bool, onDemand: Bool?) -> Bool {
        !(fallbackRunning && !durable && onDemand != false)
    }

    /// While a takeover waits, a tunnel that must not keep running ([revocation], as the record and the accounts say now)
    /// is revoked once the extension says it runs this user's engine ([engine], nil when it didn't answer); another user's
    /// ends the wait (`leave`). Asked again later (`probe`) whenever the answer leaves it open: no answer, stand-ins for files
    /// the keychain won't open yet ([held]), or no engine of this user's running right now (one may start: a restart, an
    /// unattended start of the sealed copy). Only the deny-all a failed change left running ([blocker]) is positively
    /// nothing to revoke: it holds no account.
    enum AdoptedRevocation: Equatable, Sendable { case wait, probe, leave, revoke(Revocation) }

    static func adoptedRevocation(engine: Engine?, held: Bool, blocker: String?, revocation: Revocation?) -> AdoptedRevocation {
        guard let engine else { return .probe }
        if engine.foreign { return .leave }
        if held { return .probe }
        guard let revocation else { return .wait }
        guard let running = engine.running else { return .probe }
        return running == blocker ? .wait : .revoke(revocation)
    }

    /// Tailscale's status against the running configuration ([tailscale] it uses Tailscale, [exit] the address of the exit
    /// node it routes through, nil for none): [used] the exit node in use (nil for none), [nodes] those listed. Another node
    /// in use is put back now, or once `repairEvery` has passed since the last repair ([repairedAt]). When the routed node
    /// isn't listed, only a node that is listed under another address is known to be wrong.
    enum OffRoute: Equatable, Sendable { case fine, repair, later(Duration) }
    static let repairEvery: Duration = .seconds(10)

    static func offRoute(tailscale: Bool, exit: String?, used: String?, nodes: [(id: String, ip: String)],
                         repairedAt: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> OffRoute {
        guard tailscale else { return .fine }
        let used = used ?? ""
        if let ip = exit {
            if let id = nodes.first(where: { $0.ip == ip && !$0.id.isEmpty })?.id {
                guard used != id else { return .fine }
            } else {
                guard !used.isEmpty, nodes.contains(where: { $0.id == used && $0.ip != ip }) else { return .fine }
            }
        } else { guard !used.isEmpty else { return .fine } }
        if let at = repairedAt, now - at < repairEvery { return .later(repairEvery - (now - at)) }
        return .repair
    }

    /// Whether a pause seals what an unattended start should run (`Connection.sealPause`), in this order: the record can't
    /// be read yet ([locked]); there is no usable record of what the pause replaced ([record] nil, [tainted] by a sign-out a
    /// quit interrupted, or not the one the pause began from: [baseline] against its [digest]); a route the result runs has
    /// no server in it ([built] false); it is sealed already ([sealed]) or a retry isn't due ([due] false): nothing to do;
    /// an account it holds isn't the one signed in now ([provenance]). Asked again right before sealing, with what holds then.
    enum SealAdmission: Equatable, Sendable { case seal, skip, locked, unusable, noServer, accountChanged }

    static func sealAdmission(locked: Bool, record: Bool, tainted: Bool, baseline: String?, digest: String?, built: Bool,
                              sealed: Bool, due: Bool, provenance: Provenance) -> SealAdmission {
        if locked { return .locked }
        guard record, !tainted, let baseline, baseline == digest else { return .unusable }
        guard built else { return .noServer }
        guard !sealed, due else { return .skip }
        return provenance == .same ? .seal : .accountChanged
    }

    /// What the running record read as when the extension became ready (`Running.Read`, without the record itself).
    enum RecordRead: Equatable, Sendable { case none, locked, record }

    /// Once the extension is ready while off: wait for the keychain (the record, or the setup, can't be read yet: [held]),
    /// connect again after an update replaced the extension and stopped the connection a record says ran ([replaced]), or
    /// check whether Connect on Demand still has a sealed copy to start (`reseal`, which needs the user's own setting).
    /// Connected again only for a record of the accounts signed in now ([provenance] `.same`) whose connection was last
    /// seen running, not stopping ([stopped]: macOS or the user in System Settings turned it off, another user's start
    /// replaced it, or a change failed): a VPN that was off isn't turned on by an update.
    enum Ready: Equatable, Sendable { case wake, connect, reseal }

    static func ready(replaced: Bool, read: RecordRead, held: Bool, provenance: Provenance? = nil, stopped: Bool = false) -> Ready {
        if read == .locked || held { return .wake }
        return read == .record && replaced && provenance == .same && !stopped ? .connect : .reseal
    }
}

nonisolated extension Lifecycle {
    /// What an unattended start should run while paused: what ran before the pause ([record], the routes with a server
    /// in it [linked]), with the apps the user blocks now blocked, an app unblocked since back on its own route when that ran
    /// before the pause (or Direct), otherwise on the default one, and the kill switch as it is now (a first Block turns it
    /// on). Nothing else of the edited setup: its other changes may need servers nobody asked for during a pause. Nil when a
    /// route the result runs has no server.
    static func protected(record: Setup, linked: Set<String>, store: Setup, blockedRoutes: Set<String> = []) -> Setup? {
        var p = record
        let blocked = Set(store.apps.filter { $0.value == BLOCK }.keys)
        let ran = Set(record.activeRoutes.map(\.id))
        for (app, route) in record.apps where route == BLOCK && !blocked.contains(app) {
            let wanted = store.apps[app]
            p.apps[app] = wanted.flatMap { $0 == DIRECT || ran.contains($0) ? $0 : nil }
        }
        for app in blocked { p.apps[app] = BLOCK }
        p.prefs.killSwitch = store.prefs.killSwitch
        p.prefs.killSwitchHome = store.prefs.killSwitchHome
        guard p.activeRoutes.allSatisfy({ $0.tsExit != nil || linked.contains($0.id) || (ran.contains($0.id) && blockedRoutes.contains($0.id)) }) else { return nil }
        return p
    }
}

/// A stop of the tunnel nobody here asked for (`Lifecycle.stoppedOutside`), noted the moment its status comes, before
/// anything queued can act on what it read: a pause's reconciliation would otherwise start the blocking engine again
/// and undo the stop. The caller starts a new generation, so whatever older work is under way gives up; nothing new
/// changes the engine while it is `pending`, and `statusChanged` takes it and ends what it stopped, unless an operation
/// made since (a Connect, Resume or Disconnect) owns the outcome. One stop is noted once, however many statuses it shows.
nonisolated struct OutsideStop: Sendable {
    /// What shows was left by the latest operation, and nothing of the app's is under way that may stop the tunnel.
    private(set) var settled = true
    /// The generation the stop was noted under, until it is taken.
    private(set) var seen: Int?
    /// The generation of a change whose own restart came up (`Lifecycle.stoppedAfterRestart`), until the turn of the queue
    /// it runs in ends, the next change begins, or an operation takes over: a stop meanwhile is nobody's here, though it
    /// shows connecting, also once the change failed and its caller is about to put the previous configuration back.
    private(set) var up: Int?

    /// An operation (or a teardown) takes over: until it settles, a stop is its own.
    mutating func operation() { settled = false; up = nil }

    /// A change's own restart came up, under generation [g].
    mutating func restartUp(_ g: Int) { up = g }

    /// Its turn of the queue is over, or another change (or the app's own stop) comes next.
    mutating func restartOver() { up = nil }

    /// Operation [g] is done; what shows is its result, if no newer one ([current]) started meanwhile.
    mutating func settle(_ g: Int, current: Int) { if g == current { settled = true } }

    /// A status change: true when it is a stop to note (the caller then starts a new generation and `latch`es it).
    /// [current]: the generation now, for a change whose restart came up.
    mutating func observe(phase: Snapshot.Phase, applied: Bool, status: Lifecycle.Status, current: Int? = nil) -> Bool {
        if let current, up == current, phase == .connecting, Lifecycle.stoppedAfterRestart(reached: true, status: status) {
            up = nil
            settled = false
            return true
        }
        guard Lifecycle.stoppedOutside(phase: phase, applied: applied, settled: settled, status: status) else { return false }
        settled = false
        return true
    }

    mutating func latch(_ g: Int) { seen = g }

    var pending: Bool { seen != nil }

    /// `current`: what the stop ended is still what shows (no operation since: [current] is the generation it was noted
    /// under), and so ends now, whatever the status is by then. `superseded`: an operation made since owns the outcome,
    /// and nothing else here acts on that stop. `none`: no stop noted.
    enum Taken: Equatable, Sendable { case none, current, superseded }

    mutating func take(current: Int) -> Taken {
        defer { seen = nil }
        guard let seen else { return .none }
        return seen == current ? .current : .superseded
    }
}

/// The extension is ready after an update replaced it (`Lifecycle.ready`), while what macOS stops for the swap isn't over
/// as this app sees it: the old tunnel still shows connected or stopping, or a takeover of it still waits (a new build
/// can't reach the old extension). Whether to connect again is then decided once it is down and nothing shows, under the
/// same generation: a Connect, Disconnect or Pause made since, a stop noted from outside or a sign-out owns the outcome.
/// Each replacement (`TunnelControl.replacements`) is followed on its own. Its recovery ends once the new extension
/// is seen running an engine (`over`), or a tunnel that came up after the swap's stop stops again (the user in System
/// Settings, or the engine ending: like any stop of a running tunnel, never undone). A start that never came up (the new
/// extension refusing the copy Connect on Demand starts) ends nothing.
nonisolated struct ReplacedReady: Sendable {
    /// The generation and the replacement the decision was put off under, until it is due.
    private(set) var owed: (generation: Int, replacement: Int)?
    /// The replacement whose recovery has ended: nothing of it is put off or connected again any more.
    private var closed: Int?
    /// The replacement the tunnel was last seen going down during, and the one a tunnel then came up again during.
    private var down: Int?
    private var up: Int?

    /// Ready after replacement [replacement], under generation [g]: true when it is decided now; false when it waits.
    mutating func ready(adopting: Bool, status: Lifecycle.Status, _ g: Int, replacement: Int) -> Bool {
        owed = closed != replacement && (adopting || status == .connected || status == .stopping) ? (g, replacement) : nil
        return owed == nil
    }

    /// A status, seen the moment it comes (the status handlers read what shows when they run), during [replacement].
    mutating func observe(_ status: Lifecycle.Status, replacement: Int) {
        switch status {
        case .stopping, .stopped:
            if up == replacement { end(replacement) }
            down = replacement
        case .connected where down == replacement: up = replacement
        default: break
        }
    }

    /// The tunnel is down ([status]), with [phase] showing: true once, when the decision put off is due now (generation
    /// [current], replacement [replacement]). The first stop seen after it was put off, once no takeover waits
    /// ([adopting]: the pass that ends it is queued), consumes it: one attempt per replacement, since only a ready
    /// (once per replacement) puts it off.
    mutating func due(adopting: Bool, phase: Snapshot.Phase, status: Lifecycle.Status, current: Int, replacement: Int) -> Bool {
        guard let o = owed, status == .stopped, !adopting else { return false }
        owed = nil
        return o.generation == current && o.replacement == replacement && closed != replacement && phase == .off
    }

    /// Whether the recovery of [replacement] has ended: an update then connects nothing again, whichever way it is asked.
    func ended(_ replacement: Int) -> Bool { closed == replacement }

    /// The new extension runs an engine during replacement [replacement]: its stop is over, whatever this app saw of it.
    mutating func over(replacement: Int) { end(replacement) }

    private mutating func end(_ replacement: Int) {
        closed = replacement
        if owed?.replacement == replacement { owed = nil }
    }
}

/// Everything the paused engine is built from.
nonisolated struct PauseKey: Equatable, Sendable {
    var setup: Setup
    var apps: [String: [String]]
    var suffix: String?
    /// The tailnet's search domain it runs with: the user's setup decides it, not the paused one (`Compiler.searchDomain`).
    var search: String
    /// A blocked app back where it was remembered takes the whole-Mac guards back with the same patterns.
    var remembered: Set<String>
    init(_ input: Compiler.Input, search: String = "") {
        setup = input.setup; apps = input.apps; suffix = input.tsSuffix; remembered = input.remembered; self.search = search
    }
}

/// Putting Tailscale back on the exit node the routes use after a speed test switched it to another one (`SpeedTest`).
/// The extension makes these changes one at a time in the order sent, but one the engine doesn't answer within 5 s is cut
/// off (the app hears nothing) and may still land later, after one sent after it. So once a call went unanswered, no
/// restore is final on its answer alone for the rest of the session (`Store.tsTestNode` stays set): it is, once Tailscale's
/// own status shows the routed node, and from then on `Connection` puts the routed node back whenever a status shows
/// another while no test runs, so a late one is undone at its next status. Until then the routed node is put back again
/// from statuses at most every `reassert`, and within `window` of the last unanswered call (a switch opens it, a restore
/// extends it at most `extensions` times after that switch) a restore is also repeated a few times on its own. After every
/// unanswered call nothing is sent for a while (10 s, doubling, at most 5 min), so an extension that doesn't answer doesn't
/// hold up engine changes every few seconds.
nonisolated struct TsRestore: Sendable {
    static let window: Duration = .seconds(30)
    static let extensions = 3
    static let repeats = 3
    static let every: Duration = .seconds(10)
    static let quietest: Duration = .seconds(300)
    static let reassert: Duration = .seconds(60)

    /// The node last confirmed ("" = none), and when; nil = not known (a call got no answer since).
    private(set) var confirmed: String?
    private var confirmedAt: ContinuousClock.Instant?
    /// A call went unanswered this session: it may still land, whenever.
    private(set) var unresolved = false
    private(set) var lateUntil: ContinuousClock.Instant?
    private(set) var quietUntil: ContinuousClock.Instant?
    private var misses = 0
    private var extended = 0
    private var repeated = 0

    enum Step: Equatable, Sendable {
        /// Ask the extension for this node ("" = no exit node).
        case send(String)
        /// Nothing sent: [ok] whether what was asked for holds as far as is known.
        case skip(ok: Bool)
    }

    func late(_ now: ContinuousClock.Instant) -> Bool { lateUntil.map { now < $0 } ?? false }

    /// Putting Tailscale back on [want] ("" = none, also when the routed node isn't listed: the routed apps then lose
    /// the internet rather than use the test node). [shows]: whether Tailscale's last status shows it (nil: no status).
    func next(want: String, shows: Bool? = nil, now: ContinuousClock.Instant) -> Step {
        if let q = quietUntil, now < q { return .skip(ok: false) }
        if let shows { return shows ? .skip(ok: true) : .send(want) }
        // Confirmed on it a moment ago, and nothing unanswered may land on top meanwhile: not asked for again yet.
        if confirmed == want, !late(now), let at = confirmedAt, now - at < Self.reassert { return .skip(ok: true) }
        return .send(want)
    }

    /// The extension's answer about [id]: true done, false refused, nil none in time (it may still land). [switching]:
    /// the speed test's switch to the node it tests, rather than a restore.
    mutating func answered(_ r: Bool?, _ id: String, switching: Bool, now: ContinuousClock.Instant) {
        guard let r else {
            confirmed = nil
            confirmedAt = nil
            unresolved = true
            misses += 1
            let wait = Self.every * (1 << min(misses - 1, 5))
            quietUntil = now + min(wait, Self.quietest)
            if switching { extended = 0 } else if extended < Self.extensions { extended += 1 } else { return }
            // A new window gets its own repeats.
            if !late(now) { repeated = 0 }
            lateUntil = max(lateUntil ?? now, now + Self.window)
            return
        }
        misses = 0
        quietUntil = nil
        // Refused: whatever was confirmed before says nothing now.
        if r { confirmed = id; confirmedAt = now } else { confirmed = nil; confirmedAt = nil }
    }

    /// After a restore that [ok] (confirmed, or not needed): final once it is on the routed node ([routed] a
    /// configuration routes through one, [listed] Tailscale offers it) and nothing unanswered can still land, or once
    /// Tailscale's status shows it ([seen]: a late landing then shows in a status too, and is undone there).
    mutating func final(ok: Bool, routed: Bool, listed: Bool, seen: Bool = false, now: ContinuousClock.Instant) -> (done: Bool, pending: Bool) {
        let pending = late(now)
        if !pending { lateUntil = nil }
        return (ok && (!routed || listed) && (seen || !pending && !unresolved), pending && !seen)
    }

    /// While a restore isn't final: how long until it is repeated, or nil when the repeats are used up.
    mutating func again(now: ContinuousClock.Instant) -> Duration? {
        guard repeated < Self.repeats else { return nil }
        repeated += 1
        return max(Self.every, quietUntil.map { $0 - now } ?? .zero)
    }
}

/// When unbraid stops putting the Tailscale auth key into the configuration, and when it forgets it. The extension
/// tells, with each status, the node identity it has sealed for this user (`EngineWire.Tailscale.SealedIdentity`). Running
/// with an identity sealed for the configured control server: the node is enrolled (`Home.tsEnrolled`), and the key leaves
/// the configuration (the node logs in with the sealed identity). The key itself is kept until that identity was read back
/// from the seal by an engine start or reload and the node then ran on it for `keep` without a status saying otherwise, and
/// the sealed copy Connect on Demand starts is one made without it. NeedsLogin for `lost` while enrolled: the identity
/// doesn't work any more, so enrolment is forgotten (the key, if still kept, comes back to enrol again).
nonisolated struct TsEnrolment: Sendable {
    static let keep: Duration = .seconds(30)
    static let lost: Duration = .seconds(60)
    static let tailscaleControl = "https://controlplane.tailscale.com"

    /// Since when the enrolled identity, read back from the seal, has run without a contrary status; nil when it isn't.
    private(set) var restoredSince: ContinuousClock.Instant?
    private(set) var restoredId: String?
    /// Since when Tailscale has wanted a login while enrolled.
    private(set) var needsLoginSince: ContinuousClock.Instant?
    /// The user was told once in this login episode.
    private(set) var told = false

    enum Action: Equatable, Sendable {
        /// Record [id] as the enrolled identity.
        case enrol(String)
        /// Look again in `keep`: the key may go then (`mayDropKey`).
        case checkKey
        /// Look again in `lost`: enrolment may be forgotten then (`isLost`).
        case checkLogin
    }

    /// A status: [state] the backend's, [sealed] the identity the extension reports, [enrolled] `Home.tsEnrolled`, [hasKey]
    /// an auth key is kept, [control] the configured control server (`TsLogin.controlUrl` of it; nil for Tailscale's own,
    /// "" when it isn't a valid one).
    mutating func update(state: String, sealed: EngineWire.Tailscale.SealedIdentity?, enrolled: String?, hasKey: Bool, control: String?,
                         now: ContinuousClock.Instant) -> [Action] {
        var out: [Action] = []
        if state != "NeedsLogin" { needsLoginSince = nil; told = false }
        guard state == "Running" else {
            restoredSince = nil; restoredId = nil
            if state == "NeedsLogin", enrolled != nil, needsLoginSince == nil { needsLoginSince = now; out.append(.checkLogin) }
            return out
        }
        guard let sealed, Self.sameControl(sealed.control, control) else { restoredSince = nil; restoredId = nil; return out }
        if sealed.id != enrolled { out.append(.enrol(sealed.id)) }
        if sealed.restored, sealed.id == enrolled, hasKey {
            // Repeated statuses keep the first time: only a contrary one starts the wait over.
            if restoredId != sealed.id { restoredId = sealed.id; restoredSince = now; out.append(.checkKey) }
        } else { restoredSince = nil; restoredId = nil }
        return out
    }

    /// The key may go: [id] (still the enrolled one) has run, read back from the seal, for `keep`.
    func mayDropKey(_ id: String?, now: ContinuousClock.Instant) -> Bool {
        guard let id, restoredId == id, let since = restoredSince else { return false }
        return now - since >= Self.keep
    }

    /// Enrolment no longer works: a login has been wanted for `lost`. Told once per episode.
    mutating func isLost(now: ContinuousClock.Instant) -> (lost: Bool, tell: Bool) {
        guard let since = needsLoginSince, now - since >= Self.lost else { return (false, false) }
        defer { told = true }
        return (true, !told)
    }

    /// Enrolment was forgotten and the kept key is to enrol the node again: still wanting a login `lost` from now on, the
    /// user is told.
    mutating func retry(now: ContinuousClock.Instant) {
        needsLoginSince = now
        told = false
    }

    /// Nothing seen counts any more (the status watch closed, the engine changed).
    mutating func clear() { self = TsEnrolment() }

    /// The control server tsnet recorded against the configured one: tsnet writes Tailscale's own when none is given, and
    /// either may end in one "/".
    static func sameControl(_ sealed: String, _ configured: String?) -> Bool {
        func trim(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }
        guard let configured = configured ?? Optional(tailscaleControl), !configured.isEmpty else { return false }
        return trim(sealed) == trim(configured)
    }
}

/// Health timing and the recent regular results for each tunnel.
nonisolated struct HealthSchedule {
    static let every = 48.0..<72.0
    static let quick: Duration = .seconds(10)
    static let recover: Duration = .seconds(60)
    static let cooldown: Duration = .seconds(120)
    static let grace: Duration = .seconds(30)

    struct Streak: Equatable {
        var fails = 0
        var since: ContinuousClock.Instant?
        var last: ContinuousClock.Instant?

        mutating func record(_ ok: Bool, now: ContinuousClock.Instant) {
            if ok { self = Streak(); return }
            if fails == 0 { since = now }
            fails += 1; last = now
        }
        func due(hold: ContinuousClock.Instant? = nil) -> ContinuousClock.Instant? {
            guard fails > 0, let since, let last else { return nil }
            let at = fails < 3 ? last + HealthSchedule.quick : since + HealthSchedule.recover
            return hold.map { max(at, $0) } ?? at
        }
        func dead(now: ContinuousClock.Instant, hold: ContinuousClock.Instant? = nil) -> Bool {
            guard fails >= 4, let since else { return false }
            return now >= since + HealthSchedule.recover && hold.map { now >= $0 } != false
        }
    }

    private(set) var streaks: [String: Streak] = [:]
    private(set) var history: [String: [Bool]] = [:]
    private(set) var slow = 1
    private var holds: [String: ContinuousClock.Instant] = [:]
    private(set) var graceUntil: ContinuousClock.Instant
    private(set) var round: ContinuousClock.Instant

    init(now: ContinuousClock.Instant = .now, draw: Double = 48) {
        graceUntil = now + Self.grace; round = now + .seconds(draw)
    }
    mutating func restart(now: ContinuousClock.Instant, resetSlow: Bool = true) {
        streaks.removeAll(); history.removeAll()
        if resetSlow { slow = 1 }
        graceUntil = now + Self.grace; round = graceUntil
    }
    func checks(_ eligible: Set<String>, now: ContinuousClock.Instant) -> (Set<String>, Bool) {
        guard now >= graceUntil else { return ([], false) }
        let regular = now >= round
        if regular { return (eligible, true) }
        var due = Set(eligible.filter { streaks[$0]?.due(hold: holds[$0]).map { $0 <= now } == true })
        // A healthy tunnel supplies a comparison without sending anything outside a tunnel.
        if !due.isEmpty, let control = eligible.subtracting(due).sorted().first(where: { streaks[$0] == nil }) { due.insert(control) }
        return (due, false)
    }
    /// [networkUp]: macOS reports a usable network outside the tunnel (a physical interface, path satisfied). unbraid
    /// never connects outside a tunnel to check, so when every tunnel fails that is what tells a network that is down
    /// (nothing is blamed, checks slow down) from servers that stopped answering (counted, even with a single tunnel).
    mutating func finish(_ answers: [String: Bool], regular: Bool, now: ContinuousClock.Instant, draw: Double, networkUp: Bool = false) -> Set<String> {
        if regular { round = now + .seconds(draw * Double(slow)) }
        guard !answers.isEmpty else { return [] }
        if answers.values.allSatisfy({ !$0 }), !networkUp {
            for id in answers.keys { streaks[id] = nil }
            if regular { slow = min(slow * 2, 8); round = now + .seconds(draw * Double(slow)) }
            return []
        }
        slow = 1
        if regular { round = now + .seconds(draw) }
        var dead: Set<String> = []
        for (id, ok) in answers {
            var streak = streaks[id] ?? Streak()
            streak.record(ok, now: now)
            streaks[id] = streak.fails == 0 ? nil : streak
            if regular { history[id] = Array(((history[id] ?? []) + [ok]).suffix(6)) }
            if streak.dead(now: now, hold: holds[id]) { dead.insert(id); holds[id] = now + Self.cooldown }
        }
        return dead
    }
    func dropping(_ id: String) -> Bool {
        let h = history[id] ?? []
        return h.filter { !$0 }.count >= 3 && !(h.count >= 3 && h.suffix(3).allSatisfy { $0 })
    }
}

/// A timed pause uses elapsed time on the same boot and its wall deadline after a restart.
nonisolated struct PauseDeadline: Sendable {
    var wall: Date
    var uptime: TimeInterval?
    var boot: String?

    func remaining(wallNow: Date, uptimeNow: TimeInterval?, bootNow: String?) -> TimeInterval {
        if let uptime, let boot, let uptimeNow, boot == bootNow { return max(0, uptime - uptimeNow) }
        return max(0, wall.timeIntervalSince(wallNow))
    }
}

/// Tracks a reload through preparation, provider lookup and final apply, including recovery.
nonisolated struct ReloadFlight<Key: Equatable> {
    private var current: (key: Key, token: UUID)?
    private var retrySkipped = false

    func contains(_ key: Key) -> Bool { current?.key == key }
    func owns(_ token: UUID) -> Bool { current?.token == token }

    mutating func begin(_ key: Key, fallback: Key? = nil) -> UUID {
        let token = UUID()
        current = (fallback ?? key, token)
        return token
    }

    func needsReconcile(_ wanted: Key, applied: Key?, allowed: Bool, testChange: Bool = false) -> Bool {
        !testChange && wanted != applied && !contains(wanted) && allowed
    }

    mutating func skipRetry(for key: Key) -> Bool {
        guard contains(key) else { return false }
        retrySkipped = true
        return true
    }

    /// Only the current reload can release its claim and rearm a wake it held back.
    mutating func finish(_ token: UUID) -> Bool {
        guard owns(token) else { return false }
        let rearm = retrySkipped
        clear()
        return rearm
    }

    mutating func clear() { current = nil; retrySkipped = false }
}

/// A disconnect error belongs to one stop. A new connection invalidates every older callback.
nonisolated struct DisconnectReason: Sendable {
    private(set) var generation = 0
    private(set) var pending = false
    private(set) var text: String?

    mutating func begin() -> Int {
        invalidate()
        pending = true
        return generation
    }

    mutating func invalidate() {
        generation += 1
        pending = false
        text = nil
    }

    @discardableResult
    mutating func finish(_ text: String?, generation: Int) -> Bool {
        guard generation == self.generation, pending else { return false }
        self.text = text
        pending = false
        return true
    }
}

/// Completion can precede continuation registration, and callbacks can race cancellation. Only the first result wins.
nonisolated final class ProbeResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { k in
            let ready: Result<Value, Error>? = lock.withLock {
                if let result { return result }
                continuation = k
                return nil as Result<Value, Error>?
            }
            if let ready { k.resume(with: ready) }
        }
    }

    func finish(_ value: Result<Value, Error>) {
        let k = lock.withLock {
            guard result == nil else { return nil as CheckedContinuation<Value, Error>? }
            result = value
            defer { continuation = nil }
            return continuation
        }
        k?.resume(with: value)
    }
}
