import XCTest

final class RetryTests: XCTestCase {
    private let t0 = ContinuousClock.now

    func testRefusedWaitsForOtherInputs() {
        var r = Retry<Int>()
        XCTAssertTrue(r.allows(1, now: t0))
        r.refuse(1)
        XCTAssertFalse(r.allows(1, now: t0 + .seconds(3600)))
        XCTAssertTrue(r.refuses(1))
        XCTAssertTrue(r.allows(2, now: t0))
        r.clear()
        XCTAssertTrue(r.allows(1, now: t0))
    }

    func testPassingFailureRetriesWithGrowingWaits() {
        var r = Retry<Int>()
        var now = t0
        var waits: [Duration] = []
        for _ in 0..<8 {
            guard let w = r.failed(1, disrupted: false, now: now) else { return XCTFail("a passing failure is never refused") }
            XCTAssertFalse(r.allows(1, now: now))
            XCTAssertFalse(r.allows(1, now: now + w - .milliseconds(1)))
            XCTAssertTrue(r.allows(1, now: now + w))
            XCTAssertTrue(r.allows(2, now: now), "other inputs are never held back")
            waits.append(w)
            now = now + w
        }
        XCTAssertEqual(waits.first, .seconds(10))
        XCTAssertEqual(waits.last, .seconds(600))
        XCTAssertEqual(waits, waits.sorted())
    }

    func testNewInputsStartOver() {
        var r = Retry<Int>()
        _ = r.failed(1, disrupted: false, now: t0)
        _ = r.failed(1, disrupted: false, now: t0)
        XCTAssertEqual(r.failed(2, disrupted: false, now: t0), .seconds(10))
        r.refuse(2)
        XCTAssertEqual(r.failed(2, disrupted: false, now: t0), .seconds(10), "a passing failure of refused inputs is tried again")
    }

    func testFailuresThatInterruptedTheTunnelAreGivenUp() {
        var r = Retry<Int>()
        XCTAssertNotNil(r.failed(1, disrupted: true, now: t0))
        XCTAssertNotNil(r.failed(1, disrupted: false, now: t0))
        XCTAssertNotNil(r.failed(1, disrupted: true, now: t0))
        XCTAssertNil(r.failed(1, disrupted: true, now: t0))
        XCTAssertTrue(r.refuses(1))
        XCTAssertFalse(r.allows(1, now: t0 + .seconds(86_400)))
        XCTAssertTrue(r.allows(3, now: t0))
    }
}

final class RevokeTests: XCTestCase {
    private func setup(_ routes: [Route], apps: [String: String] = [:]) -> Setup {
        Setup(routes: routes, defaultRoute: routes.first?.id ?? DIRECT, apps: apps)
    }
    private let mullvad = Route(id: "m", loc: Location(provider: "mullvad", countryCode: "NL"))
    private let nord = Route(id: "n", loc: Location(provider: "nord", countryCode: "DE"))
    private let own = Route(id: "w", wg: WgPeer(name: "home", privateKey: "k", address: ["10.0.0.2/32"], publicKey: "p", endpoint: "1.2.3.4:51820", allowedIps: ["0.0.0.0/0"]))

    func testSignedInAccountsNeverRevoke() {
        let s = setup([mullvad, nord], apps: ["a": "n"])
        let acc = ["mullvad": "1", "nord": "2"]
        XCTAssertFalse(Lifecycle.revokes(running: s, linked: Set(s.activeRoutes.map(\.id)), applied: acc, accounts: acc))
        XCTAssertFalse(Lifecycle.revokes(running: s, linked: Set(s.activeRoutes.map(\.id)), applied: nil, accounts: acc))
    }

    func testSignedOutAccountOfARunningRouteRevokes() {
        let s = setup([mullvad, nord], apps: ["a": "n"])
        XCTAssertTrue(Lifecycle.revokes(running: s, linked: Set(s.activeRoutes.map(\.id)), applied: ["mullvad": "1", "nord": "2"], accounts: ["mullvad": "1"]))
        XCTAssertTrue(Lifecycle.revokes(running: s, linked: Set(s.activeRoutes.map(\.id)), applied: nil, accounts: ["mullvad": "1"]))
    }

    func testReplacedAccountRevokesOnlyWhenKnown() {
        let s = setup([mullvad])
        XCTAssertTrue(Lifecycle.revokes(running: s, linked: Set(s.activeRoutes.map(\.id)), applied: ["mullvad": "1"], accounts: ["mullvad": "9"]))
        XCTAssertFalse(Lifecycle.revokes(running: s, linked: Set(s.activeRoutes.map(\.id)), applied: nil, accounts: ["mullvad": "9"]))
    }

    func testAccountsTheRunningConfigDoesntUseDontRevoke() {
        // Nord's route carries no app, so the engine runs no Nord tunnel; imported servers have no account.
        let s = setup([mullvad, nord, own], apps: ["a": "w"])
        XCTAssertFalse(Lifecycle.revokes(running: s, linked: Set(s.activeRoutes.map(\.id)), applied: ["mullvad": "1", "nord": "2"], accounts: ["mullvad": "1"]))
        XCTAssertFalse(Lifecycle.revokes(running: setup([own]), linked: ["w"], applied: [:], accounts: [:]))
        XCTAssertFalse(Lifecycle.revokes(running: nil, linked: [], applied: nil, accounts: [:]))
    }

    func testPartialSignOutRequiresSafeSeal() {
        let s = setup([mullvad, nord], apps: ["a": "n"])
        let applied = ["mullvad": "1", "nord": "2"]
        let remaining = ["mullvad": "1"]
        let change = Lifecycle.signOutChange(running: s, linked: Set(s.activeRoutes.map(\.id)), applied: applied, accounts: remaining)
        XCTAssertEqual(change, .replace)
        XCTAssertTrue(Lifecycle.requiresDurable(change))
        XCTAssertFalse(Lifecycle.mayApply(persist: false, requireDurable: true))
        XCTAssertTrue(Lifecycle.mayApply(persist: true, requireDurable: true))
        XCTAssertTrue(Lifecycle.mayApply(persist: false, requireDurable: false))
        XCTAssertTrue(Lifecycle.revokeAfterApplyFailure(change, revokes: false))
        XCTAssertFalse(Lifecycle.requiresDurable(.unchanged))
        XCTAssertFalse(Lifecycle.revokeAfterApplyFailure(.unchanged, revokes: false))
        XCTAssertTrue(Lifecycle.revokeAfterApplyFailure(.unchanged, revokes: true))
        XCTAssertEqual(Lifecycle.signOutChange(running: setup([nord]), linked: ["n"], applied: applied, accounts: remaining), .teardown)
        XCTAssertEqual(Lifecycle.signOutChange(running: s, linked: Set(s.activeRoutes.map(\.id)), applied: applied, accounts: [:]), .teardown)
        XCTAssertEqual(Lifecycle.signOutChange(running: s, linked: Set(s.activeRoutes.map(\.id)), applied: applied, accounts: ["mullvad": "9"]), .teardown)
    }

    func testLastProviderSignOutKeepsAnActiveImportedOrTailscaleLink() {
        for independent in [own, Route(id: "t", tsExit: "100.64.0.1")] {
            let s = setup([mullvad, independent], apps: ["app": independent.id])
            for applied: [String: String]? in [["mullvad": "1"], nil] {
                let change = Lifecycle.signOutChange(running: s, linked: ["m", independent.id], applied: applied, accounts: [:])
                XCTAssertEqual(change, .replace)
                XCTAssertTrue(Lifecycle.requiresDurable(change))
                XCTAssertTrue(Lifecycle.revokeAfterApplyFailure(change, revokes: false))
                XCTAssertEqual(Lifecycle.signOutChange(running: s, linked: ["m"], applied: applied, accounts: [:]), .teardown)
            }
            let inactive = setup([mullvad, independent])
            XCTAssertEqual(Lifecycle.signOutChange(running: inactive, linked: ["m", independent.id], applied: ["mullvad": "1"], accounts: [:]), .teardown)
            XCTAssertEqual(Lifecycle.signOutChange(running: s, linked: ["m", independent.id], applied: ["mullvad": "1"], accounts: ["mullvad": "new"]), .teardown)
        }
    }

    func testSafeResealSettlesOnlyItsOwnSignOut() {
        let s = setup([mullvad, nord], apps: ["a": "n"])
        func settled(requested: Int? = 1, current: Int? = 1, accounts: [String: String] = ["mullvad": "1"],
                     links: Set<String> = ["m"], fits: Bool = true, persisted: Bool = true) -> Bool {
            Lifecycle.signOutSettled(provider: "nord", requested: requested, current: current, accounts: accounts,
                                     setup: s, links: links, fits: fits, persisted: persisted)
        }
        XCTAssertTrue(settled())
        XCTAssertFalse(settled(current: 2))
        XCTAssertFalse(settled(requested: nil))
        XCTAssertFalse(settled(accounts: ["nord": "new"]))
        XCTAssertFalse(settled(links: ["m", "n"]))
        XCTAssertFalse(settled(fits: false))
        XCTAssertFalse(settled(persisted: false))
    }

    func testTemporaryRouteTransitionsDoNotIncludeRealEdits() {
        let base = setup([mullvad, nord])
        var testing = base; testing.testing = ["n"]
        XCTAssertTrue(Lifecycle.testTransition(from: base, to: testing, sameAccounts: true))
        XCTAssertTrue(Lifecycle.testTransition(from: testing, to: base, sameAccounts: true))
        XCTAssertFalse(Lifecycle.testTransition(from: base, to: testing, sameAccounts: false))
        var edited = testing; edited.apps["app"] = "n"
        XCTAssertFalse(Lifecycle.testTransition(from: base, to: edited, sameAccounts: true))
        XCTAssertFalse(Lifecycle.testTransition(from: base, to: base, sameAccounts: true))
        let accounts = ["nord": "account"]
        XCTAssertFalse(Lifecycle.endTesting(base: base, accounts: accounts, setup: base, currentAccounts: accounts))
        XCTAssertTrue(Lifecycle.endTesting(base: base, accounts: accounts, setup: base, currentAccounts: [:]))
        XCTAssertTrue(Lifecycle.endTesting(base: base, accounts: accounts, setup: base, currentAccounts: ["nord": "new"]))
        XCTAssertTrue(Lifecycle.endTesting(base: base, accounts: accounts, setup: edited, currentAccounts: accounts))
    }
    func testBlockedSignedOutRouteIsNotHeld() {
        let s = setup([mullvad, nord], apps: ["a": "n"])
        let accounts = ["mullvad": "1"]
        XCTAssertFalse(Lifecycle.revokes(running: s, linked: ["m"], applied: accounts, accounts: accounts))
        XCTAssertEqual(Lifecycle.signOutChange(running: s, linked: ["m"], applied: accounts, accounts: accounts), .unchanged)
        XCTAssertFalse(Lifecycle.holds("nord", setup: s, linked: ["m"]))
        XCTAssertTrue(Lifecycle.holds("nord", setup: s, linked: nil))
        XCTAssertTrue(Lifecycle.acceptsTakeover(["n": .signedOut("Nord")], activeRoutes: 2))
        XCTAssertFalse(Lifecycle.acceptsTakeover(["n": .signedOut("Nord")], activeRoutes: 1))
        XCTAssertFalse(Lifecycle.acceptsTakeover(["n": .unreachable("offline")], activeRoutes: 2))
        XCTAssertTrue(Lifecycle.acceptsTakeover([:], activeRoutes: 0))
        let protected = Lifecycle.protected(record: s, linked: ["m"], store: s, blockedRoutes: ["n"])
        XCTAssertNotNil(protected)
        XCTAssertEqual(Lifecycle.sealAdmission(locked: false, record: true, tainted: false, baseline: "d", digest: "d", built: protected != nil, sealed: false, due: true, provenance: .same), .seal)
    }

}

final class HealthScheduleTests: XCTestCase {
    private let t = ContinuousClock.now

    func testQuickRecoverAndCooldown() {
        var s = HealthSchedule.Streak()
        XCTAssertNil(s.due())
        for (i, seconds) in [0, 10, 20, 60].enumerated() {
            s.record(false, now: t + .seconds(seconds))
            if i < 3 { XCTAssertEqual(s.due(), t + .seconds([10, 20, 60][i])) }
        }
        XCTAssertFalse(s.dead(now: t + .seconds(59)))
        XCTAssertTrue(s.dead(now: t + .seconds(60)))
        XCTAssertFalse(s.dead(now: t + .seconds(70), hold: t + .seconds(180)))
        XCTAssertEqual(s.due(hold: t + .seconds(180)), t + .seconds(180))
        s.record(true, now: t + .seconds(61))
        XCTAssertEqual(s, HealthSchedule.Streak())
    }

    func testQuickChecksUseAnotherTunnelToBlameFailures() {
        var p = HealthSchedule(now: t)
        let eligible: Set<String> = ["a", "b"]
        for seconds in [48, 58, 68, 108] {
            let now = t + .seconds(seconds)
            let (checked, regular) = p.checks(eligible, now: now)
            XCTAssertEqual(checked, eligible)
            let dead = p.finish(["a": false, "b": true], regular: regular, now: now, draw: 72)
            XCTAssertEqual(dead, seconds == 108 ? ["a"] : [])
        }
        XCTAssertEqual(p.streaks["a"]?.due(), t + .seconds(108))
        XCTAssertTrue(p.checks(eligible, now: t + .seconds(118)).0.isEmpty)
    }

    func testRegularFailuresDoNotShortenRecovery() {
        var s = HealthSchedule.Streak()
        for seconds in [0, 10, 20, 48] { s.record(false, now: t + .seconds(seconds)) }
        XCTAssertFalse(s.dead(now: t + .seconds(48)))
        XCTAssertEqual(s.due(), t + .seconds(60))
        s.record(false, now: t + .seconds(60))
        XCTAssertTrue(s.dead(now: t + .seconds(60)))
    }

    /// With the network up, a single tunnel that stops answering is counted: one route alone can still fail over.
    func testAllFailCountsWhenTheNetworkIsUp() {
        var p = HealthSchedule(now: t, draw: 48)
        p.restart(now: t)
        _ = p.finish(["a": false], regular: true, now: t + .seconds(30), draw: 48, networkUp: true)
        XCTAssertEqual(p.slow, 1)
        XCTAssertNotNil(p.streaks["a"])
    }

    func testGraceAndAllFailBackoff() {
        var p = HealthSchedule(now: t, draw: 48)
        p.restart(now: t)
        XCTAssertTrue(p.checks(["a"], now: t + .seconds(29)).0.isEmpty)
        XCTAssertEqual(p.checks(["a"], now: t + .seconds(30)).0, ["a"])
        _ = p.finish(["a": false], regular: true, now: t + .seconds(30), draw: 48)
        XCTAssertEqual(p.slow, 2)
        XCTAssertTrue(p.streaks.isEmpty)
        XCTAssertEqual(p.round, t + .seconds(126))
        _ = p.finish(["a": true], regular: true, now: t + .seconds(126), draw: 48)
        XCTAssertEqual(p.slow, 1)
    }

    func testDroppingUsesOnlyRegularResultsAndClears() {
        var p = HealthSchedule(now: t)
        for (i, ok) in [false, true, false, true, false].enumerated() {
            _ = p.finish(["a": ok, "b": true], regular: true, now: t + .seconds(i * 50), draw: 48)
        }
        XCTAssertTrue(p.dropping("a"))
        for i in 0..<3 { _ = p.finish(["a": true, "b": true], regular: true, now: t + .seconds(300 + i), draw: 48) }
        XCTAssertFalse(p.dropping("a"))
        p.restart(now: t + .seconds(400))
        XCTAssertFalse(p.dropping("a"))
    }
}

final class ProvenanceTests: XCTestCase {
    private let mullvad = Route(id: "m", loc: Location(provider: "mullvad", countryCode: "NL"))
    private let nord = Route(id: "n", loc: Location(provider: "nord", countryCode: "DE"))
    private let own = Route(id: "w", wg: WgPeer(name: "home", privateKey: "k", address: ["10.0.0.2/32"], publicKey: "p", endpoint: "1.2.3.4:51820", allowedIps: ["0.0.0.0/0"]))
    private let fp: (String) -> String = { "fp-" + $0 }
    private func running(_ routes: [Route], apps: [String: String] = [:]) -> Setup {
        Setup(routes: routes, defaultRoute: routes.first?.id ?? DIRECT, apps: apps)
    }
    private func provenance(_ s: Setup?, _ made: [String: String]?, _ accounts: [String: String]) -> Lifecycle.Provenance {
        Lifecycle.provenance(s.map { ($0, Set($0.activeRoutes.map(\.id)), made) }, accounts: accounts, fingerprint: fp)
    }

    func testTheAccountsTheRecordNamesAreStillSignedIn() {
        let s = running([mullvad, nord], apps: ["a": "n"])
        XCTAssertEqual(provenance(s, ["mullvad": "fp-1", "nord": "fp-2"], ["mullvad": "1", "nord": "2"]), .same)
        // Imported servers and routes the engine doesn't run have no account to check.
        XCTAssertEqual(provenance(running([own]), nil, [:]), .same)
        XCTAssertEqual(provenance(running([mullvad, nord], apps: ["a": "m"]), ["mullvad": "fp-1"], ["mullvad": "1"]), .same)
    }

    func testBlockedSignedOutRouteHasSameProvenance() {
        let s = running([mullvad, nord], apps: ["a": "n"])
        XCTAssertEqual(Lifecycle.provenance((s, ["m"], ["mullvad": "fp-1"]), accounts: ["mullvad": "1"], fingerprint: fp), .same)
    }

    func testASignedOutOrReplacedAccountRevokes() {
        let s = running([mullvad])
        XCTAssertEqual(provenance(s, ["mullvad": "fp-1"], [:]), .signedOut)
        XCTAssertEqual(provenance(s, ["mullvad": "fp-1"], ["mullvad": "2"]), .replaced)
        // A missing account counts before a missing fingerprint.
        XCTAssertEqual(provenance(s, nil, [:]), .signedOut)
        XCTAssertEqual(provenance(running([mullvad, nord], apps: ["a": "n"]), ["mullvad": "fp-1"], ["mullvad": "1"]), .signedOut)
    }

    /// An older version's record (no fingerprints), one without that provider's, or none at all: an account switched
    /// meanwhile can't be told from the same one, so nothing about it is trusted.
    func testNothingToGoByIsUnknown() {
        let s = running([mullvad])
        XCTAssertEqual(provenance(s, nil, ["mullvad": "2"]), .unknown)
        XCTAssertEqual(provenance(running([mullvad, nord], apps: ["a": "n"]), ["mullvad": "fp-1"], ["mullvad": "1", "nord": "2"]), .unknown)
        XCTAssertEqual(provenance(nil, nil, ["mullvad": "1"]), .unknown)
        XCTAssertEqual(provenance(nil, nil, [:]), .unknown)
        // The worst route decides.
        XCTAssertEqual(provenance(running([mullvad, nord], apps: ["a": "n"]), ["nord": "fp-2"], ["mullvad": "1", "nord": "9"]), .replaced)
    }
}

final class TakeoverFailureTests: XCTestCase {
    private typealias E = Lifecycle.Engine
    private let ours = E(running: "r1", durable: "r1", foreign: false)
    private func decide(_ provenance: Lifecycle.Provenance, _ engine: E?, foreign: Bool = false, unvouched: Bool = false, admitted: Bool = true,
                        unstaged: Bool = false, onDemand: Bool = false) -> Lifecycle.TakeoverFailure {
        Lifecycle.takeoverFailure(foreign: foreign, provenance: provenance, unvouched: unvouched, admitted: admitted, unstaged: unstaged,
                                  onDemand: onDemand, engine: engine)
    }

    /// Another user's tunnel is theirs, whatever else is known: never stopped, never retried.
    func testAnotherUsersTunnelIsLeftAlone() {
        XCTAssertEqual(decide(.signedOut, ours, foreign: true), .leave)
        XCTAssertEqual(decide(.unknown, E(running: nil, durable: nil, foreign: true)), .leave)
        XCTAssertEqual(decide(.unknown, nil, foreign: true), .leave)
    }

    /// Revoked only on the extension's word that the engine is this user's; in the order signed out, unvouched, unknown.
    func testRevokedOnlyWhenTheEngineIsThisUsers() {
        XCTAssertEqual(decide(.signedOut, ours, unvouched: true), .revoke(.signedOut))
        XCTAssertEqual(decide(.replaced, ours), .revoke(.signedOut))
        XCTAssertEqual(decide(.same, ours, unvouched: true), .revoke(.unvouched))
        XCTAssertEqual(decide(.unknown, ours, unvouched: true), .revoke(.unvouched))
        XCTAssertEqual(decide(.unknown, ours), .revoke(.unknown))
        // Also when the tunnel would come back by itself, or nothing was touched: the account must not keep running.
        XCTAssertEqual(decide(.unknown, ours, admitted: false, onDemand: true), .revoke(.unknown))
        // No answer (the ownership check gives up after seconds), or no engine of this user's: kept and retried.
        for p in [Lifecycle.Provenance.signedOut, .replaced, .unknown] {
            XCTAssertEqual(decide(p, nil), .retry(disrupted: true))
            XCTAssertEqual(decide(p, E(running: nil, durable: "d", foreign: false)), .retry(disrupted: true))
        }
        XCTAssertEqual(decide(.same, nil, unvouched: true), .retry(disrupted: true))
    }

    /// The deny-all a failed change left running holds no account: never stopped, whatever the record says.
    func testTheBlockerIsNeverStopped() {
        let blocker = E(running: "deny", durable: "old", foreign: false)
        for p in [Lifecycle.Provenance.same, .unknown, .replaced, .signedOut] {
            XCTAssertEqual(Lifecycle.takeoverFailure(foreign: false, provenance: p, unvouched: true, admitted: true, unstaged: false, onDemand: false,
                                                     engine: blocker, blocker: "deny"), .retry(disrupted: true))
        }
        // Once something else runs (an unattended start of the sealed copy), the record counts again.
        XCTAssertEqual(Lifecycle.takeoverFailure(foreign: false, provenance: .signedOut, unvouched: false, admitted: true, unstaged: false, onDemand: false,
                                                 engine: E(running: "old", durable: "old", foreign: false), blocker: "deny"), .revoke(.signedOut))
    }

    /// While a takeover waits: a signed-out or replaced account always counts; an unvouched server or an unknown account only
    /// once a takeover of it failed (until then, taking it over may well succeed).
    func testWhatAWaitingTakeoverRevokes() {
        XCTAssertEqual(Lifecycle.revocation(provenance: .signedOut, unvouched: false, failed: false), .signedOut)
        XCTAssertEqual(Lifecycle.revocation(provenance: .replaced, unvouched: true, failed: true), .signedOut)
        XCTAssertNil(Lifecycle.revocation(provenance: .unknown, unvouched: true, failed: false))
        XCTAssertEqual(Lifecycle.revocation(provenance: .unknown, unvouched: true, failed: true), .unvouched)
        XCTAssertEqual(Lifecycle.revocation(provenance: .unknown, unvouched: false, failed: true), .unknown)
        XCTAssertNil(Lifecycle.revocation(provenance: .same, unvouched: false, failed: true))
    }

    /// Whatever the inputs, nothing is stopped or revoked without a running engine of this user's.
    func testNothingStopsWithoutThisUsersEngine() {
        let engines: [E?] = [nil, E(running: nil, durable: nil, foreign: false), E(running: nil, durable: "d", foreign: false),
                             E(running: "a", durable: "a", foreign: true), ours, E(running: "a", durable: "b", foreign: false)]
        for p in [Lifecycle.Provenance.same, .unknown, .replaced, .signedOut] { for e in engines { for bits in 0..<32 {
            let f = bits & 1 != 0, u = bits & 2 != 0, a = bits & 4 != 0, st = bits & 8 != 0, od = bits & 16 != 0
            switch decide(p, e, foreign: f, unvouched: u, admitted: a, unstaged: st, onDemand: od) {
            case .stop, .revoke: XCTAssertTrue(!f && e?.foreign == false && e?.running != nil)
            case .leave: XCTAssertTrue(f || e?.foreign == true)
            case .retry(let d): XCTAssertEqual(d, a && !st)
            }
        } } }
    }

    /// Known accounts: kept unless the attempt changed the engine, nothing starts it again, and it runs something other
    /// than its sealed copy.
    func testAKnownTunnelIsStoppedOnlyWhenNothingBringsItBack() {
        XCTAssertEqual(decide(.same, ours, admitted: false), .retry(disrupted: false))
        XCTAssertEqual(decide(.same, ours, unstaged: true), .retry(disrupted: false))
        XCTAssertEqual(decide(.same, E(running: "a", durable: "b", foreign: false), onDemand: true), .retry(disrupted: true))
        XCTAssertEqual(decide(.same, ours), .retry(disrupted: true))
        XCTAssertEqual(decide(.same, E(running: "a", durable: "b", foreign: false)), .stop)
        XCTAssertEqual(decide(.same, E(running: "a", durable: nil, foreign: false)), .stop)
        // Nothing known: nothing stopped.
        XCTAssertEqual(decide(.same, nil), .retry(disrupted: true))
        XCTAssertEqual(decide(.same, E(running: nil, durable: nil, foreign: false)), .retry(disrupted: true))
    }
}

final class ProtectedTests: XCTestCase {
    private let nl = Route(id: "nl", loc: Location(provider: "mullvad", countryCode: "NL"))
    private let us = Route(id: "us", loc: Location(provider: "mullvad", countryCode: "US"))
    private let de = Route(id: "de", loc: Location(provider: "mullvad", countryCode: "DE"))
    private var record: Setup { Setup(routes: [nl, us, de], defaultRoute: "nl", apps: ["a": "us", "b": BLOCK, "c": DIRECT, "d": BLOCK, "e": BLOCK]) }

    /// Blocks added and removed during the pause reach the protected setup; nothing else of the edited one does.
    func testOnlyBlocksChange() throws {
        var store = record
        store.apps = ["a": BLOCK, "b": "us", "c": "de", "d": "de", "e": DIRECT, "f": BLOCK]
        store.routes.append(Route(id: "it", loc: Location(provider: "mullvad", countryCode: "IT")))
        store.defaultRoute = "it"
        store.prefs.killSwitch = true
        store.prefs.threatProtection = false
        let p = try XCTUnwrap(Lifecycle.protected(record: record, linked: ["nl", "us"], store: store))
        // a and f newly blocked; b back on its route (it ran); d's route didn't run before: the default; e Direct; c untouched.
        XCTAssertEqual(p.apps, ["a": BLOCK, "b": "us", "c": DIRECT, "e": DIRECT, "f": BLOCK])
        XCTAssertEqual(p.routes, record.routes)
        XCTAssertEqual(p.defaultRoute, "nl")
        XCTAssertTrue(p.prefs.killSwitch)
        XCTAssertTrue(p.prefs.threatProtection)
    }

    /// The pause's baseline is compared with the record read back: the same setup gives the same digest after a round trip.
    func testTheBaselineDigestSurvivesTheRecord() throws {
        var s = record
        s.home = Home(tailscale: true, tsAuthKey: "k", tsSuffix: "tail1.ts.net", subnets: ["192.168.1.0/24"])
        s.prefs.customDns = ["9.9.9.9"]
        let back = try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(Running.digest(back), Running.digest(s))
        s.defaultRoute = "us"
        XCTAssertNotEqual(Running.digest(back), Running.digest(s))
    }

    /// A route the result runs without a server in the record: nothing to seal without asking a provider.
    func testARouteWithoutAServerIsNotSealed() {
        var store = record
        store.apps["b"] = "us"
        XCTAssertNil(Lifecycle.protected(record: record, linked: ["nl"], store: store))
        XCTAssertEqual(Lifecycle.protected(record: record, linked: ["nl", "us"], store: record), record)
    }
}

final class ResealTests: XCTestCase {
    private typealias E = Lifecycle.Engine
    private let none = E(running: nil, durable: nil, foreign: false)
    private func reseal(_ engine: E?, ready: Bool = true, provenance: Lifecycle.Provenance? = .same, sealedBy: String? = "7",
                        previous: String? = "7", wanted: Bool = true, stopped: Bool = false) -> Lifecycle.Reseal {
        Lifecycle.reseal(engine: engine, ready: ready, provenance: provenance, sealedBy: sealedBy, previous: previous, build: "8", wanted: wanted,
                         stopped: stopped)
    }

    /// No sealed copy left for Connect on Demand after an update: connect again when it's safe, otherwise say so.
    func testARefusedCopyIsSealedAgainOnlyWhenSafe() {
        XCTAssertEqual(reseal(none), .connect)
        XCTAssertEqual(reseal(none, ready: false), .tell(updated: true))
        for p in [Lifecycle.Provenance.unknown, .replaced, .signedOut] { XCTAssertEqual(reseal(none, provenance: p), .tell(updated: true)) }
        XCTAssertEqual(reseal(none, provenance: nil), .tell(updated: true))
    }

    /// Only on the first launch after an update since this user's own copy was sealed: no update, no copy of theirs ever
    /// sealed (another user's copy is the one the extension has), or a later launch, and the user is told, never connected.
    func testOnlyTheFirstLaunchAfterAnUpdateSinceThisUsersSealConnects() {
        XCTAssertEqual(reseal(none, sealedBy: "8", previous: "8"), .tell(updated: false))
        XCTAssertEqual(reseal(none, sealedBy: nil), .tell(updated: false))
        XCTAssertEqual(reseal(none, sealedBy: nil, previous: "8"), .tell(updated: false))
        // A later launch of the same build: said, not connected (a connect that failed isn't tried at every launch).
        XCTAssertEqual(reseal(none, sealedBy: "7", previous: "8"), .tell(updated: true))
        // A note that couldn't be read is a build that noted it: not the legacy case.
        XCTAssertEqual(reseal(none, sealedBy: nil, previous: ""), .tell(updated: false))
        XCTAssertEqual(reseal(none, sealedBy: "7", previous: ""), .connect)
        // No build before this one said: what an older version sealed may be the one refused.
        XCTAssertEqual(reseal(none, sealedBy: nil, previous: nil), .connect)
        XCTAssertEqual(reseal(none, sealedBy: "8", previous: nil), .tell(updated: false))
    }

    /// Another user's copy is what Connect on Demand starts: never replaced by a connect nobody asked for.
    func testAnotherUsersCopyIsNeverReplacedUnasked() {
        let theirs = E(running: nil, durable: nil, foreign: false, startable: true)
        XCTAssertEqual(reseal(theirs), .tell(updated: true))
        XCTAssertEqual(reseal(theirs, sealedBy: nil, previous: nil), .tell(updated: true))
    }

    /// Connect on Demand left on by another user (the profile is the Mac's): nothing to do with this user.
    func testAnotherUsersConnectOnDemandIsNotThisUsers() {
        XCTAssertEqual(reseal(none, wanted: false), .none)
        XCTAssertEqual(reseal(none, sealedBy: nil, previous: nil, wanted: false), .none)
    }

    /// A copy to start, an engine that runs, or another user's: nothing to do. No answer at all: not known (the caller asks a
    /// few times first), unless Connect on Demand is another user's.
    func testNothingWhileThereIsACopyOrNoAnswer() {
        XCTAssertEqual(reseal(E(running: nil, durable: "d", foreign: false)), .none)
        XCTAssertEqual(reseal(E(running: "r", durable: nil, foreign: false)), .none)
        XCTAssertEqual(reseal(E(running: nil, durable: nil, foreign: true)), .none)
        XCTAssertEqual(reseal(nil), .unknown)
        XCTAssertEqual(reseal(nil, wanted: false), .none)
    }

    /// The extension became ready while off: the keychain first, then a reconnect after an update, else the reseal check.
    func testWhatAReadyExtensionLeadsTo() {
        for replaced in [false, true] {
            XCTAssertEqual(Lifecycle.ready(replaced: replaced, read: .locked, held: false), .wake)
            for read in [Lifecycle.RecordRead.none, .locked, .record] { XCTAssertEqual(Lifecycle.ready(replaced: replaced, read: read, held: true), .wake) }
            XCTAssertEqual(Lifecycle.ready(replaced: replaced, read: .none, held: false), .reseal)
        }
        XCTAssertEqual(Lifecycle.ready(replaced: true, read: .record, held: false, provenance: .same), .connect)
        XCTAssertEqual(Lifecycle.ready(replaced: false, read: .record, held: false, provenance: .same), .reseal)
    }

    /// An update connects again only for a record of the accounts signed in now, whose connection was last seen running.
    func testAnUpdateReconnectsOnlyWhatRanForTheseAccounts() {
        for p in [Lifecycle.Provenance.unknown, .replaced, .signedOut] {
            XCTAssertEqual(Lifecycle.ready(replaced: true, read: .record, held: false, provenance: p), .reseal)
        }
        XCTAssertEqual(Lifecycle.ready(replaced: true, read: .record, held: false, provenance: nil), .reseal)
        // macOS or the user turned it off, another user's start replaced it, or a change failed: an update doesn't turn it on.
        XCTAssertEqual(Lifecycle.ready(replaced: true, read: .record, held: false, provenance: .same, stopped: true), .reseal)
        XCTAssertEqual(reseal(none, stopped: true), .tell(updated: true))
    }
}

final class OnDemandHoldTests: XCTestCase {
    private typealias E = Lifecycle.Engine

    /// Connect on Demand stays on only for a copy of this user's to start; no answer or no copy turns it off.
    func testItStaysOnOnlyForACopyToStart() {
        XCTAssertEqual(Lifecycle.onDemandHold(engine: E(running: nil, durable: "d", foreign: false, startable: true), owed: false), .keep)
        XCTAssertEqual(Lifecycle.onDemandHold(engine: E(running: "r", durable: "d", foreign: false, startable: true), owed: false), .keep)
        XCTAssertEqual(Lifecycle.onDemandHold(engine: E(running: nil, durable: nil, foreign: false), owed: false), .disarm)
        // Running, but nothing sealed to start once it stops.
        XCTAssertEqual(Lifecycle.onDemandHold(engine: E(running: "r", durable: nil, foreign: false), owed: false), .disarm)
        XCTAssertEqual(Lifecycle.onDemandHold(engine: nil, owed: false), .disarm)
    }

    /// A drop a sign-out still owes: off, even with a copy of this user's (it may hold the signed-out account).
    func testAnOwedDropKeepsItOff() {
        XCTAssertEqual(Lifecycle.onDemandHold(engine: E(running: nil, durable: "d", foreign: false, startable: true), owed: true), .disarm)
        XCTAssertEqual(Lifecycle.onDemandHold(engine: nil, owed: true), .disarm)
    }

    /// Another user's engine, or another user's copy to start (Connect on Demand isn't left with nothing): theirs.
    func testAnotherUsersIsLeftAlone() {
        XCTAssertEqual(Lifecycle.onDemandHold(engine: E(running: nil, durable: nil, foreign: true), owed: false), .leave)
        XCTAssertEqual(Lifecycle.onDemandHold(engine: E(running: nil, durable: "d", foreign: true), owed: true), .leave)
        XCTAssertEqual(Lifecycle.onDemandHold(engine: E(running: nil, durable: nil, foreign: false, startable: true), owed: false), .leave)
        // Another user's copy holds no drop this user owes.
        XCTAssertEqual(Lifecycle.onDemandHold(engine: E(running: nil, durable: nil, foreign: false, startable: true), owed: true), .leave)
    }
}

final class OnDemandOffTests: XCTestCase {
    /// What has to be saved yet survives a relaunch as one value: the user's Off wins over a disarm decided again.
    func testTheOwedOffIsTheUsersFirst() {
        XCTAssertNil(Lifecycle.OnDemandOwed(offWanted: false, disarmPending: false))
        XCTAssertEqual(Lifecycle.OnDemandOwed(offWanted: false, disarmPending: true), .hold)
        XCTAssertEqual(Lifecycle.OnDemandOwed(offWanted: true, disarmPending: false), .off)
        XCTAssertEqual(Lifecycle.OnDemandOwed(offWanted: true, disarmPending: true), .off)
        XCTAssertEqual(Lifecycle.OnDemandOwed(rawValue: "off"), .off)
        XCTAssertEqual(Lifecycle.OnDemandOwed(rawValue: "hold"), .hold)
    }

    /// Off before a drop only when the copy may be this user's, or nobody answered: another user's copy (no sealing named
    /// to this user) is theirs, and decided after the drop on what is left.
    func testItGoesOffBeforeADropOnlyForACopyThatMayBeTheirs() {
        XCTAssertTrue(Lifecycle.disarmFirst(answered: false, seal: nil))
        XCTAssertTrue(Lifecycle.disarmFirst(answered: true, seal: "8C1A0F4E-4C3B-4B5E-9C55-0E7C1D2B3A49"))
        XCTAssertTrue(Lifecycle.disarmFirst(answered: true, seal: "unknown"))
        XCTAssertTrue(Lifecycle.disarmFirst(answered: true, seal: Ownership.unreadableSealing))
        XCTAssertFalse(Lifecycle.disarmFirst(answered: true, seal: nil))
    }

    /// A drop refused as superseded is settled once nothing of the user's is left, or a complete copy is that this app
    /// sealed after the drop named the old one. A copy sealed by a request from before (landed late), or a sealing that
    /// didn't finish, may hold the signed-out account: dropped as named now. No answer: asked again.
    func testASupersededDropSettlesOnlyOnACopySealedSince() {
        XCTAssertEqual(Lifecycle.supersededDrop(now: nil, sealedSince: true), .later)
        XCTAssertEqual(Lifecycle.supersededDrop(now: (seal: nil, durable: nil), sealedSince: false), .settled)
        XCTAssertEqual(Lifecycle.supersededDrop(now: (seal: "B", durable: "r2"), sealedSince: true), .settled)
        XCTAssertEqual(Lifecycle.supersededDrop(now: (seal: "B", durable: "r2"), sealedSince: false), .renamed("B"))
        XCTAssertEqual(Lifecycle.supersededDrop(now: (seal: "B", durable: nil), sealedSince: true), .renamed("B"))
        XCTAssertEqual(Lifecycle.supersededDrop(now: (seal: Ownership.unreadableSealing, durable: nil), sealedSince: false), .renamed(Ownership.unreadableSealing))
    }

    /// Off with Connect on Demand on and the tunnel down: asked a moment after, then no more than once a minute.
    func testFailingStartsAreLookedAtAtMostOnceAMinute() {
        let t0 = ContinuousClock.now
        XCTAssertEqual(Lifecycle.idleHoldWait(last: nil, now: t0), .seconds(3))
        XCTAssertEqual(Lifecycle.idleHoldWait(last: t0, now: t0 + .seconds(10)), .seconds(50))
        XCTAssertEqual(Lifecycle.idleHoldWait(last: t0, now: t0 + .seconds(58)), .seconds(3))
        XCTAssertEqual(Lifecycle.idleHoldWait(last: t0, now: t0 + .seconds(600)), .seconds(3))
        // The launch's own check of the extension first, for a bounded time.
        XCTAssertEqual(Lifecycle.idleHoldWait(last: nil, now: t0, ready: t0 + .seconds(60)), .seconds(60))
        XCTAssertEqual(Lifecycle.idleHoldWait(last: nil, now: t0 + .seconds(59), ready: t0 + .seconds(60)), .seconds(3))
        XCTAssertEqual(Lifecycle.idleHoldWait(last: nil, now: t0 + .seconds(90), ready: t0 + .seconds(60)), .seconds(3))
    }
}

final class WaitingTakeoverTests: XCTestCase {
    private typealias E = Lifecycle.Engine
    private let ours = E(running: "r1", durable: "r1", foreign: false)

    /// A sign-out's erase a quit interrupted stops the running tunnel only on the extension's word that it is this user's.
    func testAnInterruptedSignOutStopsOnlyThisUsersEngine() {
        XCTAssertEqual(Lifecycle.interruptedSignOut(engine: ours), .stop)
        XCTAssertEqual(Lifecycle.interruptedSignOut(engine: E(running: "a", durable: nil, foreign: false)), .stop)
        XCTAssertEqual(Lifecycle.interruptedSignOut(engine: nil), .wait)
        XCTAssertEqual(Lifecycle.interruptedSignOut(engine: E(running: nil, durable: "d", foreign: false)), .wait)
        XCTAssertEqual(Lifecycle.interruptedSignOut(engine: E(running: "a", durable: "a", foreign: true)), .foreign)
        XCTAssertEqual(Lifecycle.interruptedSignOut(engine: E(running: nil, durable: nil, foreign: true)), .foreign)
    }

    private func decide(_ engine: E?, held: Bool = false, blocker: String? = nil, _ why: Lifecycle.Revocation? = .signedOut) -> Lifecycle.AdoptedRevocation {
        Lifecycle.adoptedRevocation(engine: engine, held: held, blocker: blocker, revocation: why)
    }

    /// Revoked once the extension says this user's engine runs; another user's ends the wait.
    func testAWaitingTakeoverIsRevokedOnTheExtensionsWord() {
        XCTAssertEqual(decide(ours), .revoke(.signedOut))
        XCTAssertEqual(decide(ours, .unknown), .revoke(.unknown))
        XCTAssertEqual(decide(E(running: "a", durable: "a", foreign: true)), .leave)
        XCTAssertEqual(decide(E(running: "a", durable: "a", foreign: true), nil), .leave)
        // Nothing to revoke any more (signed in again meanwhile): it waits, no probe needed.
        XCTAssertEqual(decide(ours, nil), .wait)
    }

    /// Whatever leaves it open is asked again: no answer, stand-ins for the setup, or no engine of this user's right now (one
    /// may still start with the signed-out account). Only the deny-all running is positively nothing to revoke.
    func testWhatLeavesItOpenIsAskedAgain() {
        XCTAssertEqual(decide(nil), .probe)
        XCTAssertEqual(decide(nil, nil), .probe)
        XCTAssertEqual(decide(ours, held: true), .probe)
        XCTAssertEqual(decide(E(running: nil, durable: nil, foreign: false)), .probe)
        XCTAssertEqual(decide(E(running: nil, durable: "d", foreign: false)), .probe)
        XCTAssertEqual(decide(E(running: nil, durable: nil, foreign: false), blocker: nil), .probe)
        XCTAssertEqual(decide(E(running: "deny", durable: "old", foreign: false), blocker: "deny"), .wait)
        XCTAssertEqual(decide(E(running: "old", durable: "old", foreign: false), blocker: "deny"), .revoke(.signedOut))
    }

    /// Whatever the inputs: revoked only with this user's engine running that isn't the deny-all, and never left without
    /// either a probe or an answer that settles it.
    func testNothingIsRevokedWithoutThisUsersEngine() {
        let engines: [E?] = [nil, E(running: nil, durable: nil, foreign: false), E(running: nil, durable: "d", foreign: false),
                             E(running: "a", durable: "a", foreign: true), ours, E(running: "deny", durable: nil, foreign: false)]
        for e in engines { for held in [false, true] { for blocker in [nil, "deny"] {
            for why in [nil, Lifecycle.Revocation.signedOut, .unvouched, .unknown] {
                switch decide(e, held: held, blocker: blocker, why) {
                case .revoke(let w):
                    XCTAssertTrue(e?.foreign == false && e?.running != nil && e?.running != blocker && !held)
                    XCTAssertEqual(w, why)
                case .leave: XCTAssertEqual(e?.foreign, true)
                case .wait: XCTAssertTrue(why == nil || e?.running == blocker && blocker != nil)
                case .probe: XCTAssertTrue(e == nil || held || e?.running == nil)
                }
            }
        } } }
    }
}

final class OffRouteTests: XCTestCase {
    private let t0 = ContinuousClock.now
    private let nodes = [(id: "n1", ip: "100.64.0.1"), (id: "n2", ip: "100.64.0.2")]
    private func decide(_ tailscale: Bool = true, exit: String?, used: String?, nodes: [(id: String, ip: String)]? = nil,
                        repairedAt: ContinuousClock.Instant? = nil, after: Duration = .seconds(60)) -> Lifecycle.OffRoute {
        Lifecycle.offRoute(tailscale: tailscale, exit: exit, used: used, nodes: nodes ?? self.nodes, repairedAt: repairedAt, now: t0 + after)
    }

    /// The routed node in use, or none routed and none in use: nothing to do; anything else is put back.
    func testAnotherExitNodeIsPutBack() {
        XCTAssertEqual(decide(exit: "100.64.0.1", used: "n1"), .fine)
        XCTAssertEqual(decide(exit: nil, used: nil), .fine)
        XCTAssertEqual(decide(exit: nil, used: ""), .fine)
        XCTAssertEqual(decide(exit: "100.64.0.1", used: "n2"), .repair)
        XCTAssertEqual(decide(exit: "100.64.0.1", used: nil), .repair)
        XCTAssertEqual(decide(exit: nil, used: "n2"), .repair)
        // Without Tailscale in the running setup, its status says nothing.
        XCTAssertEqual(decide(false, exit: nil, used: "n2"), .fine)
    }

    /// The routed node isn't listed: only a listed node at another address is known to be wrong.
    func testAnUnlistedRoutedNodeIsOnlyRepairedFromAKnownOtherNode() {
        XCTAssertEqual(decide(exit: "100.64.0.9", used: "n2"), .repair)
        XCTAssertEqual(decide(exit: "100.64.0.9", used: "n9"), .fine)
        XCTAssertEqual(decide(exit: "100.64.0.9", used: nil), .fine)
        // A listed node without an id doesn't count as the routed one.
        XCTAssertEqual(decide(exit: "100.64.0.9", used: "n2", nodes: [(id: "", ip: "100.64.0.9"), (id: "n2", ip: "100.64.0.2")]), .repair)
    }

    /// At most one repair every 10 s: one held back is due when that has passed.
    func testRepairsAreSpacedOut() {
        XCTAssertEqual(decide(exit: "100.64.0.1", used: "n2", repairedAt: t0, after: .seconds(4)), .later(.seconds(6)))
        XCTAssertEqual(decide(exit: "100.64.0.1", used: "n2", repairedAt: t0, after: .seconds(10)), .repair)
        XCTAssertEqual(decide(exit: "100.64.0.1", used: "n1", repairedAt: t0, after: .seconds(4)), .fine)
    }
}

final class SealAdmissionTests: XCTestCase {
    private func decide(locked: Bool = false, record: Bool = true, tainted: Bool = false, baseline: String? = "d", digest: String? = "d",
                        built: Bool = true, sealed: Bool = false, due: Bool = true, provenance: Lifecycle.Provenance = .same) -> Lifecycle.SealAdmission {
        Lifecycle.sealAdmission(locked: locked, record: record, tainted: tainted, baseline: baseline, digest: digest, built: built, sealed: sealed,
                                due: due, provenance: provenance)
    }

    /// Sealed only from a usable record of what the pause replaced, with a server for every route, while every account it
    /// holds is the one signed in; in that order.
    func testWhatAPauseSeals() {
        XCTAssertEqual(decide(), .seal)
        XCTAssertEqual(decide(locked: true, record: false), .locked)
        XCTAssertEqual(decide(locked: true, provenance: .signedOut), .locked)
        XCTAssertEqual(decide(record: false), .unusable)
        XCTAssertEqual(decide(tainted: true), .unusable)
        XCTAssertEqual(decide(baseline: nil), .unusable)
        XCTAssertEqual(decide(baseline: "other"), .unusable)
        XCTAssertEqual(decide(digest: nil), .unusable)
        XCTAssertEqual(decide(tainted: true, built: false), .unusable)
        XCTAssertEqual(decide(built: false), .noServer)
        XCTAssertEqual(decide(built: false, sealed: true), .noServer)
        XCTAssertEqual(decide(sealed: true), .skip)
        XCTAssertEqual(decide(due: false), .skip)
        XCTAssertEqual(decide(sealed: true, provenance: .signedOut), .skip)
        for p in [Lifecycle.Provenance.unknown, .replaced, .signedOut] { XCTAssertEqual(decide(provenance: p), .accountChanged) }
    }

    /// Whatever the inputs, a seal needs every condition.
    func testASealNeedsEverything() {
        for bits in 0..<128 {
            let locked = bits & 1 != 0, record = bits & 2 != 0, tainted = bits & 4 != 0, match = bits & 8 != 0
            let built = bits & 16 != 0, sealed = bits & 32 != 0, due = bits & 64 != 0
            for p in [Lifecycle.Provenance.same, .unknown, .replaced, .signedOut] {
                let a = decide(locked: locked, record: record, tainted: tainted, digest: match ? "d" : "x", built: built, sealed: sealed, due: due, provenance: p)
                XCTAssertEqual(a == .seal, !locked && record && !tainted && match && built && !sealed && due && p == .same)
            }
        }
    }
}

final class TsEnrolmentTests: XCTestCase {
    private let t0 = ContinuousClock.now
    private func sealed(_ id: String, restored: Bool = false, control: String = "https://controlplane.tailscale.com") -> EngineWire.Tailscale.SealedIdentity {
        .init(id: id, control: control, restored: restored)
    }

    /// Running with an identity sealed for the configured server: enrolled. Not for another server, nor without one.
    func testEnrolsOnlyForTheConfiguredServer() {
        var e = TsEnrolment()
        XCTAssertEqual(e.update(state: "Running", sealed: sealed("a"), enrolled: nil, hasKey: true, control: nil, now: t0), [.enrol("a")])
        XCTAssertEqual(e.update(state: "Running", sealed: sealed("a"), enrolled: "a", hasKey: true, control: nil, now: t0), [])
        XCTAssertEqual(e.update(state: "Running", sealed: sealed("a", control: "https://hs.example/"), enrolled: nil, hasKey: true,
                                control: "https://hs.example", now: t0), [.enrol("a")])
        XCTAssertEqual(e.update(state: "Running", sealed: sealed("a"), enrolled: nil, hasKey: true, control: "https://hs.example", now: t0), [])
        // A configured server that isn't a valid one matches nothing, Tailscale's own included.
        XCTAssertEqual(e.update(state: "Running", sealed: sealed("a"), enrolled: nil, hasKey: true, control: "", now: t0), [])
        XCTAssertEqual(e.update(state: "Starting", sealed: sealed("a"), enrolled: nil, hasKey: true, control: nil, now: t0), [])
        XCTAssertEqual(e.update(state: "Running", sealed: nil, enrolled: nil, hasKey: true, control: nil, now: t0), [])
        // Re-enrolled as another node: that one.
        XCTAssertEqual(e.update(state: "Running", sealed: sealed("b"), enrolled: "a", hasKey: true, control: nil, now: t0), [.enrol("b")])
    }

    /// The key goes only after the identity, read back from the seal, has run for 30 s with no status saying otherwise.
    func testTheKeyGoesAfterTheIdentityHeld() {
        var e = TsEnrolment()
        XCTAssertEqual(e.update(state: "Running", sealed: sealed("a"), enrolled: "a", hasKey: true, control: nil, now: t0), [])
        XCTAssertEqual(e.update(state: "Running", sealed: sealed("a", restored: true), enrolled: "a", hasKey: true, control: nil, now: t0), [.checkKey])
        // Repeated statuses keep the first time.
        XCTAssertEqual(e.update(state: "Running", sealed: sealed("a", restored: true), enrolled: "a", hasKey: true, control: nil, now: t0 + .seconds(20)), [])
        XCTAssertFalse(e.mayDropKey("a", now: t0 + .seconds(29)))
        XCTAssertTrue(e.mayDropKey("a", now: t0 + .seconds(30)))
        XCTAssertFalse(e.mayDropKey("b", now: t0 + .seconds(30)))
        XCTAssertFalse(e.mayDropKey(nil, now: t0 + .seconds(30)))
        // Any other status starts over: another state, no identity (a transient nil), one not read back.
        for (state, s) in [("Starting", sealed("a", restored: true)), ("Running", nil), ("Running", sealed("a"))] {
            var f = e
            _ = f.update(state: state, sealed: s, enrolled: "a", hasKey: true, control: nil, now: t0 + .seconds(25))
            XCTAssertFalse(f.mayDropKey("a", now: t0 + .seconds(60)))
        }
        // No key kept: nothing to drop.
        var none = TsEnrolment()
        XCTAssertEqual(none.update(state: "Running", sealed: sealed("a", restored: true), enrolled: "a", hasKey: false, control: nil, now: t0), [])
    }

    /// A login wanted for a minute while enrolled: enrolment is forgotten, told once; a transient one isn't.
    func testAPersistentLoginForgetsEnrolment() {
        var e = TsEnrolment()
        XCTAssertEqual(e.update(state: "NeedsLogin", sealed: nil, enrolled: "a", hasKey: false, control: nil, now: t0), [.checkLogin])
        XCTAssertEqual(e.update(state: "NeedsLogin", sealed: nil, enrolled: "a", hasKey: false, control: nil, now: t0 + .seconds(10)), [])
        XCTAssertFalse(e.isLost(now: t0 + .seconds(59)).lost)
        XCTAssertTrue(e.isLost(now: t0 + .seconds(60)) == (true, true))
        XCTAssertTrue(e.isLost(now: t0 + .seconds(61)) == (true, false))
        // Running in between starts the minute over.
        var f = TsEnrolment()
        _ = f.update(state: "NeedsLogin", sealed: nil, enrolled: "a", hasKey: true, control: nil, now: t0)
        _ = f.update(state: "Running", sealed: sealed("a"), enrolled: "a", hasKey: true, control: nil, now: t0 + .seconds(30))
        XCTAssertFalse(f.isLost(now: t0 + .seconds(60)).lost)
        // Forgotten with a key kept to enrol again: still wanting a login a minute later, told.
        var r = TsEnrolment()
        _ = r.update(state: "NeedsLogin", sealed: nil, enrolled: "a", hasKey: true, control: nil, now: t0)
        XCTAssertTrue(r.isLost(now: t0 + .seconds(60)) == (true, true))
        r.retry(now: t0 + .seconds(60))
        XCTAssertFalse(r.isLost(now: t0 + .seconds(100)).lost)
        XCTAssertTrue(r.isLost(now: t0 + .seconds(120)) == (true, true))
        // Not enrolled: nothing to forget.
        var g = TsEnrolment()
        XCTAssertEqual(g.update(state: "NeedsLogin", sealed: nil, enrolled: nil, hasKey: true, control: nil, now: t0), [])
    }
}

final class PauseStepTests: XCTestCase {
    private let t0 = ContinuousClock.now
    private func key(_ apps: [String: String]) -> PauseKey {
        let s = Setup(routes: [], defaultRoute: DIRECT, apps: apps)
        return PauseKey(Compiler.Input(setup: s, links: [:], apps: apps.mapValues { [$0] }, selfPattern: "", tsSuffix: nil, probe: nil))
    }

    func testWhatRunsConverges() {
        let a = key(["x": BLOCK])
        var retry = Retry<PauseKey>()
        XCTAssertEqual(Lifecycle.pauseStep(wanted: a, running: a, connected: true, retry: retry, now: t0), .converged(clear: false))
        // Back to what runs after a failed edit: that failure no longer applies, even while its retry isn't due.
        _ = retry.failed(key(["x": BLOCK, "y": BLOCK]), disrupted: false, now: t0)
        XCTAssertEqual(Lifecycle.pauseStep(wanted: a, running: a, connected: true, retry: retry, now: t0), .converged(clear: true))
        // Not running any more: applied again.
        XCTAssertEqual(Lifecycle.pauseStep(wanted: a, running: a, connected: false, retry: Retry(), now: t0), .apply)
    }

    /// The tailnet joining or leaving the user's setup changes the paused engine's search domain only: applied again.
    func testTheSearchDomainIsPartOfWhatRuns() {
        let s = Setup(routes: [], defaultRoute: DIRECT, apps: ["x": BLOCK])
        let input = Compiler.Input(setup: s, links: [:], apps: ["x": ["x"]], selfPattern: "", tsSuffix: "tail1.ts.net", probe: nil)
        let with = PauseKey(input, search: Compiler.searchDomain(input, tailnet: true)), without = PauseKey(input, search: Compiler.searchDomain(input, tailnet: false))
        XCTAssertNotEqual(with, without)
        XCTAssertEqual(Lifecycle.pauseStep(wanted: with, running: without, connected: true, retry: Retry(), now: t0), .apply)
    }

    func testAFailedEditWaitsItsTurnAndARefusedOneOtherInputs() {
        let a = key(["x": BLOCK]), b = key(["x": BLOCK, "y": BLOCK])
        var retry = Retry<PauseKey>()
        _ = retry.failed(b, disrupted: false, now: t0)
        XCTAssertEqual(Lifecycle.pauseStep(wanted: b, running: a, connected: true, retry: retry, now: t0), .wait)
        XCTAssertEqual(Lifecycle.pauseStep(wanted: b, running: a, connected: true, retry: retry, now: t0 + .seconds(11)), .apply)
        retry.refuse(b)
        XCTAssertEqual(Lifecycle.pauseStep(wanted: b, running: a, connected: true, retry: retry, now: t0 + .seconds(999)), .wait)
        XCTAssertEqual(Lifecycle.pauseStep(wanted: key(["z": BLOCK]), running: a, connected: true, retry: retry, now: t0), .apply)
    }

    /// A blocked app back where it was remembered keeps its patterns; the paused engine still needs its guards back.
    func testABlockedAppBackWhereItWasRememberedIsApplied() {
        let s = Setup(routes: [], defaultRoute: DIRECT, apps: ["x": BLOCK])
        func key(_ remembered: Set<String>) -> PauseKey {
            PauseKey(Compiler.Input(setup: s, links: [:], apps: ["x": ["/Applications/X.app/"]], remembered: remembered,
                                    selfPattern: "", tsSuffix: nil, probe: nil))
        }
        let gone = key(["x"]), back = key([])
        XCTAssertNotEqual(gone, back)
        XCTAssertEqual(Lifecycle.pauseStep(wanted: back, running: gone, connected: true, retry: Retry(), now: t0), .apply)
        XCTAssertEqual(Lifecycle.pauseStep(wanted: gone, running: back, connected: true, retry: Retry(), now: t0), .apply)
    }

    /// Another app's copy found changes the key but not what the pause runs: no reload, while that still runs.
    func testAPauseRunningWhatItWouldApplyIsLeftAlone() {
        let applied = (json: "{\"a\":1}", revision: "r1")
        XCTAssertTrue(Lifecycle.pauseRuns("{\"a\":1}", applied: applied, running: ("r1", nil, false)))
        // Another configuration wanted, none applied yet, or no answer: applied.
        XCTAssertFalse(Lifecycle.pauseRuns("{\"a\":2}", applied: applied, running: ("r1", nil, false)))
        XCTAssertFalse(Lifecycle.pauseRuns("{\"a\":1}", applied: nil, running: ("r1", nil, false)))
        XCTAssertFalse(Lifecycle.pauseRuns("{\"a\":1}", applied: applied, running: nil))
        // Started again since (Connect on Demand's sealed copy), stopped, or another user's engine: applied.
        XCTAssertFalse(Lifecycle.pauseRuns("{\"a\":1}", applied: applied, running: ("r0", "r0", false)))
        XCTAssertFalse(Lifecycle.pauseRuns("{\"a\":1}", applied: applied, running: (nil, "r0", false)))
        XCTAssertFalse(Lifecycle.pauseRuns("{\"a\":1}", applied: applied, running: ("r1", nil, true)))
    }

    /// Converged as far as the app saw: the extension's answer decides whether the pause still runs what it applied.
    func testAConvergedPauseIsCheckedAgainstWhatRuns() {
        func engine(_ running: String?, _ durable: String? = "sealed", foreign: Bool = false) -> Lifecycle.Engine {
            Lifecycle.Engine(running: running, durable: durable, foreign: foreign)
        }
        XCTAssertEqual(Lifecycle.pauseCheck(applied: "r1", engine: engine("r1")), .runs)
        XCTAssertEqual(Lifecycle.pauseCheck(applied: "r1", engine: engine("r1", nil)), .runs)
        // Restarted without the app seeing it stop: Connect on Demand's sealed copy, or anything else of this user's.
        XCTAssertEqual(Lifecycle.pauseCheck(applied: "r1", engine: engine("sealed")), .reapply)
        XCTAssertEqual(Lifecycle.pauseCheck(applied: "r1", engine: engine("r2", nil)), .reapply)
        // Not known what the pause applied: whatever runs is never taken for it.
        XCTAssertEqual(Lifecycle.pauseCheck(applied: nil, engine: engine("r1")), .reapply)
        XCTAssertEqual(Lifecycle.pauseCheck(applied: nil, engine: engine("sealed")), .reapply)
        // No answer, or none of this user's running right now (one may be starting): kept, asked again later.
        XCTAssertEqual(Lifecycle.pauseCheck(applied: "r1", engine: nil), .ask)
        XCTAssertEqual(Lifecycle.pauseCheck(applied: nil, engine: nil), .ask)
        XCTAssertEqual(Lifecycle.pauseCheck(applied: "r1", engine: engine(nil)), .ask)
        // Another user's engine: theirs, whatever it runs.
        XCTAssertEqual(Lifecycle.pauseCheck(applied: "r1", engine: engine("r1", foreign: true)), .leave)
        XCTAssertEqual(Lifecycle.pauseCheck(applied: "r1", engine: engine(nil, foreign: true)), .leave)
    }

    /// A pause applied again because something else ran waits longer each time the extension still reports another
    /// revision; a change of the blocked apps doesn't wait, and seeing the pause run again ends the wait.
    func testApplyingAPauseAgainBacksOffUntilItIsSeenRunning() {
        let a = key(["x": BLOCK]), b = key(["x": BLOCK, "y": BLOCK])
        var retry = Retry<PauseKey>()
        // Converged as far as the app saw, but the check says otherwise: applied again (running: nil).
        XCTAssertEqual(Lifecycle.pauseStep(wanted: a, running: a, connected: true, retry: retry, now: t0), .converged(clear: false))
        XCTAssertEqual(Lifecycle.pauseStep(wanted: a, running: nil, connected: true, retry: retry, now: t0), .apply)
        var at = t0
        for wait in Retry<PauseKey>.delays + [Retry<PauseKey>.delays.last!] {
            XCTAssertEqual(retry.failed(a, disrupted: false, now: at), wait)
            // Still converged as far as the app saw, so checked again; another revision isn't applied before the wait ends.
            XCTAssertEqual(Lifecycle.pauseStep(wanted: a, running: a, connected: true, retry: retry, now: at), .converged(clear: true))
            XCTAssertEqual(Lifecycle.pauseStep(wanted: a, running: nil, connected: true, retry: retry, now: at + wait - .seconds(1)), .wait)
            XCTAssertEqual(Lifecycle.pauseStep(wanted: b, running: a, connected: true, retry: retry, now: at), .apply)
            at = at + wait
            XCTAssertEqual(Lifecycle.pauseStep(wanted: a, running: nil, connected: true, retry: retry, now: at), .apply)
        }
        // Never refused for good: the wait stays at its longest.
        XCTAssertFalse(retry.refuses(a))
        // Seen running (`.converged(clear: true)` then `.runs`): cleared, applied again at once next time.
        retry.clear()
        XCTAssertEqual(Lifecycle.pauseStep(wanted: a, running: nil, connected: true, retry: retry, now: at), .apply)
    }

    /// After no answer, changes meanwhile don't ask again (each would wait for the timeout), and the probe they arm keeps
    /// the same time, however many come: asked again once that time is reached, also by a pause made again since.
    func testAnUnansweredCheckIsAskedAgainAtItsTime() {
        XCTAssertNil(Lifecycle.pauseAskWait(until: nil, now: t0))
        let until = t0 + .seconds(60)
        XCTAssertEqual(Lifecycle.pauseAskWait(until: until, now: t0), .seconds(60))
        for s in [1, 30, 59] {
            let now = t0 + .seconds(s)
            XCTAssertEqual(now + Lifecycle.pauseAskWait(until: until, now: now)!, until)
        }
        XCTAssertNil(Lifecycle.pauseAskWait(until: until, now: until))
        XCTAssertNil(Lifecycle.pauseAskWait(until: until, now: until + .seconds(1)))
    }

    /// The last blocked app unblocked: the blocking tunnel stops; once stopped, an earlier failure no longer applies.
    func testNothingBlockedStopsAndThenConverges() {
        let none = key([:]), a = key(["x": BLOCK])
        var retry = Retry<PauseKey>()
        XCTAssertEqual(Lifecycle.pauseStep(wanted: none, running: a, connected: true, retry: retry, now: t0), .stop)
        XCTAssertEqual(Lifecycle.pauseStep(wanted: none, running: nil, connected: true, retry: retry, now: t0), .stop)
        XCTAssertEqual(Lifecycle.pauseStep(wanted: none, running: nil, connected: false, retry: retry, now: t0), .idle(clear: false))
        retry.refuse(a)
        XCTAssertEqual(Lifecycle.pauseStep(wanted: none, running: nil, connected: false, retry: retry, now: t0), .idle(clear: true))
    }
}

final class TsRestoreTests: XCTestCase {
    private let t0 = ContinuousClock.now

    func testAnAnsweredRestoreIsFinal() {
        var r = TsRestore()
        XCTAssertEqual(r.next(want: "n1", now: t0), .send("n1"))
        r.answered(true, "n1", switching: false, now: t0)
        XCTAssertEqual(r.confirmed, "n1")
        let f = r.final(ok: true, routed: true, listed: true, now: t0)
        XCTAssertTrue(f.done)
        XCTAssertFalse(f.pending)
        // Not on the routed node because it isn't listed: never final, the next status tries again.
        XCTAssertFalse(r.final(ok: true, routed: true, listed: false, now: t0).done)
        XCTAssertTrue(r.final(ok: true, routed: false, listed: false, now: t0).done)
        XCTAssertFalse(r.final(ok: false, routed: false, listed: false, now: t0).done)
    }

    /// An unanswered switch may land at any time: restores within its window are repeated a few times only, and no
    /// restore is final for the rest of the session.
    func testAnUnansweredSwitchIsNeverResolved() {
        var r = TsRestore()
        r.answered(nil, "test", switching: true, now: t0)
        XCTAssertNil(r.confirmed)
        XCTAssertTrue(r.unresolved)
        XCTAssertTrue(r.late(t0 + .seconds(29)))
        // Nothing is sent right after a call that went unanswered.
        XCTAssertEqual(r.next(want: "n1", now: t0 + .seconds(5)), .skip(ok: false))
        XCTAssertEqual(r.next(want: "n1", now: t0 + .seconds(10)), .send("n1"))
        r.answered(true, "n1", switching: false, now: t0 + .seconds(10))
        let f = r.final(ok: true, routed: true, listed: true, now: t0 + .seconds(10))
        XCTAssertFalse(f.done)
        XCTAssertTrue(f.pending)
        // Within the window the confirmed node is asked for again (the late switch may land on top of it).
        XCTAssertEqual(r.next(want: "n1", now: t0 + .seconds(11)), .send("n1"))
        XCTAssertEqual(r.again(now: t0 + .seconds(10)), .seconds(10))
        XCTAssertNotNil(r.again(now: t0 + .seconds(20)))
        XCTAssertNotNil(r.again(now: t0 + .seconds(30)))
        XCTAssertNil(r.again(now: t0 + .seconds(40)))
        // After the window: still not final; put back again from statuses, at most once a minute.
        r.answered(true, "n1", switching: false, now: t0 + .seconds(31))
        XCTAssertFalse(r.final(ok: true, routed: true, listed: true, now: t0 + .seconds(31)).done)
        XCTAssertNil(r.lateUntil)
        XCTAssertEqual(r.next(want: "n1", now: t0 + .seconds(60)), .skip(ok: true))
        XCTAssertEqual(r.next(want: "n1", now: t0 + .seconds(91)), .send("n1"))
        // Another node routed meanwhile is asked for at once.
        XCTAssertEqual(r.next(want: "n2", now: t0 + .seconds(60)), .send("n2"))
    }

    /// Calls the extension doesn't answer: each wait before the next call doubles up to five minutes, so the engine
    /// queue isn't held every few seconds for good.
    func testUnansweredCallsBackOff() {
        var r = TsRestore()
        var now = t0
        var last: Duration = .zero
        for i in 0..<10 {
            if case .skip = r.next(want: "", now: now) { XCTFail("quiet at \(i)") }
            r.answered(nil, "", switching: false, now: now)
            let quiet = r.quietUntil! - now
            XCTAssertGreaterThanOrEqual(quiet, last)
            XCTAssertLessThanOrEqual(quiet, .seconds(300))
            last = quiet
            now = r.quietUntil!
        }
        XCTAssertEqual(last, .seconds(300))
        // An answer ends the backoff (but not the uncertainty).
        r.answered(true, "", switching: false, now: now)
        XCTAssertNil(r.quietUntil)
        XCTAssertTrue(r.unresolved)
        XCTAssertEqual(r.next(want: "", now: now), .skip(ok: true))
    }

    func testOnlyThreeRestoresExtendTheWindow() {
        var r = TsRestore()
        r.answered(nil, "test", switching: true, now: t0)
        var now = t0
        for _ in 0..<3 {
            now = now + .seconds(20)
            r.answered(nil, "n1", switching: false, now: now)
            XCTAssertEqual(r.lateUntil, now + .seconds(30))
        }
        let end = r.lateUntil
        r.answered(nil, "n1", switching: false, now: now + .seconds(20))
        XCTAssertEqual(r.lateUntil, end)
        // The next test's unanswered switch opens a window again.
        r.answered(nil, "test", switching: true, now: now + .seconds(60))
        XCTAssertEqual(r.lateUntil, now + .seconds(90))
    }

    /// Tailscale's status says where it is: shown on the node, nothing is sent and the restore is final, even after an
    /// unanswered call (a late landing shows in a later status, and is undone there); shown elsewhere, it is asked for.
    func testTheStatusDecides() {
        var r = TsRestore()
        r.answered(nil, "test", switching: true, now: t0)
        XCTAssertEqual(r.next(want: "n1", shows: true, now: t0 + .seconds(5)), .skip(ok: false))
        XCTAssertEqual(r.next(want: "n1", shows: true, now: t0 + .seconds(10)), .skip(ok: true))
        let f = r.final(ok: true, routed: true, listed: true, seen: true, now: t0 + .seconds(10))
        XCTAssertTrue(f.done)
        XCTAssertFalse(f.pending)
        XCTAssertEqual(r.next(want: "n1", shows: false, now: t0 + .seconds(10)), .send("n1"))
        // Seen, but the routed node isn't listed: not final.
        XCTAssertFalse(r.final(ok: true, routed: true, listed: false, seen: true, now: t0 + .seconds(10)).done)
        // A refusal forgets what was confirmed.
        r.answered(true, "n1", switching: false, now: t0 + .seconds(11))
        r.answered(false, "n1", switching: false, now: t0 + .seconds(12))
        XCTAssertNil(r.confirmed)
        XCTAssertEqual(r.next(want: "n1", now: t0 + .seconds(13)), .send("n1"))
    }

    /// The routed node isn't listed: no exit node at all, asked for again about once a minute (never left for good).
    func testNoneIsAskedForAgainNowAndThen() {
        var r = TsRestore()
        XCTAssertEqual(r.next(want: "", now: t0), .send(""))
        r.answered(true, "", switching: false, now: t0)
        XCTAssertEqual(r.next(want: "", now: t0 + .seconds(30)), .skip(ok: true))
        XCTAssertFalse(r.final(ok: true, routed: true, listed: false, now: t0).done)
        XCTAssertEqual(r.next(want: "", now: t0 + .seconds(61)), .send(""))
        // Refused: not confirmed, asked again.
        r.answered(false, "x", switching: false, now: t0)
        XCTAssertEqual(r.next(want: "x", now: t0 + .seconds(1)), .send("x"))
    }
}

final class OutsideStopTests: XCTestCase {
    private typealias S = Lifecycle.Status

    func testStopTakenBeforeWaitingForReasonDoesNotBlockANewerOperation() async {
        var o = OutsideStop(), generation = 5
        o.latch(generation)
        let g = generation
        XCTAssertEqual(o.take(current: g), .current)
        // While macOS supplies the text, Connect, Pause or Disconnect takes ownership.
        await Task.yield()
        generation += 1
        o.operation()
        XCTAssertNotEqual(g, generation, "the old teardown must give way")
        XCTAssertFalse(o.pending, "no further status notification is needed to release the stop")
        XCTAssertEqual(o.take(current: generation), .none)
    }

    /// Stopping or stopped while connected, or paused with the blocking engine the pause applied, and nothing of the
    /// app's under way: a stop to note. Anything else isn't.
    func testWhatIsAStopFromOutside() {
        for status in [S.stopping, .stopped] {
            XCTAssertTrue(Lifecycle.stoppedOutside(phase: .on, applied: false, settled: true, status: status))
            XCTAssertTrue(Lifecycle.stoppedOutside(phase: .paused, applied: true, settled: true, status: status))
            // A pause without its engine (rebuilt at launch, or nothing blocked) is applied, not ended.
            XCTAssertFalse(Lifecycle.stoppedOutside(phase: .paused, applied: false, settled: true, status: status))
            // The app's own restarts show connecting first; its own stops are an operation's.
            XCTAssertFalse(Lifecycle.stoppedOutside(phase: .connecting, applied: true, settled: true, status: status))
            XCTAssertFalse(Lifecycle.stoppedOutside(phase: .off, applied: false, settled: true, status: status))
            XCTAssertFalse(Lifecycle.stoppedOutside(phase: .on, applied: false, settled: false, status: status))
            XCTAssertFalse(Lifecycle.stoppedOutside(phase: .paused, applied: true, settled: false, status: status))
        }
        for status in [S.connected, .connecting] {
            XCTAssertFalse(Lifecycle.stoppedOutside(phase: .on, applied: false, settled: true, status: status))
            XCTAssertFalse(Lifecycle.stoppedOutside(phase: .paused, applied: true, settled: true, status: status))
        }
    }

    /// Paused, System Settings turns the VPN off: noted once for both statuses it shows, and taken once, whatever the
    /// status is by then (the reconciliation it would otherwise lose to may have started the tunnel again).
    func testAStopIsNotedOnceAndEndsThePause() {
        var o = OutsideStop(), generation = 4
        XCTAssertTrue(o.observe(phase: .paused, applied: true, status: .stopping))
        generation += 1
        o.latch(generation)
        XCTAssertTrue(o.pending)
        XCTAssertFalse(o.observe(phase: .paused, applied: true, status: .stopped), "one stop, noted once")
        XCTAssertEqual(o.take(current: generation), .current)
        XCTAssertFalse(o.pending)
        XCTAssertEqual(o.take(current: generation), .none)
    }

    /// A Connect, Resume or Disconnect made after the stop was noted owns the outcome: the stop ends nothing, and a later
    /// status of the same stop doesn't overtake that operation.
    func testANewerOperationOwnsTheOutcome() {
        var o = OutsideStop(), generation = 4
        XCTAssertTrue(o.observe(phase: .paused, applied: true, status: .stopping))
        generation += 1
        o.latch(generation)
        // Resume pressed (a new generation): its statuses are its own until it settles.
        generation += 1
        o.operation()
        XCTAssertFalse(o.observe(phase: .paused, applied: true, status: .stopped))
        XCTAssertEqual(o.take(current: generation), .superseded)
        XCTAssertFalse(o.pending)
        XCTAssertFalse(o.settled, "nothing else acts on that stop until Resume settles")
        // Resume settled: the next stop nobody asked for is noted again; so is the old one, asked again at once when Resume
        // left what shows as it was (it gave way) and the tunnel is still down.
        o.settle(generation, current: generation)
        XCTAssertTrue(o.observe(phase: .paused, applied: true, status: .stopped))
    }

    /// A change's own restart came up, then failed with the tunnel down: stopped from outside (its connecting phase hid the
    /// status), so nothing recovers it. Failing before it came up, or with the tunnel still up, is the change's own failure.
    func testAStopAfterARestartCameUpIsFromOutside() {
        XCTAssertTrue(Lifecycle.stoppedAfterRestart(reached: true, status: .stopping))
        XCTAssertTrue(Lifecycle.stoppedAfterRestart(reached: true, status: .stopped))
        XCTAssertFalse(Lifecycle.stoppedAfterRestart(reached: true, status: .connected))
        XCTAssertFalse(Lifecycle.stoppedAfterRestart(reached: true, status: .connecting))
        for status in [S.connected, .connecting, .stopping, .stopped] {
            XCTAssertFalse(Lifecycle.stoppedAfterRestart(reached: false, status: status))
        }
    }

    /// A change's own restart came up (still connecting, maybe failing and about to put the previous configuration back):
    /// a stop then is from outside, noted once, also during a user operation. Not for an older generation, once its turn
    /// is over or the next change begins, nor after an operation (the app's own stop) took over.
    func testAStopWhileARestartIsUpIsNoted() {
        var o = OutsideStop()
        o.operation()
        o.restartUp(5)
        XCTAssertFalse(o.observe(phase: .connecting, applied: false, status: .connected, current: 5))
        XCTAssertFalse(o.observe(phase: .connecting, applied: false, status: .stopping, current: 6), "an older generation's")
        XCTAssertFalse(o.observe(phase: .on, applied: false, status: .stopping, current: 5), "not settled: an operation's")
        XCTAssertTrue(o.observe(phase: .connecting, applied: false, status: .stopping, current: 5))
        XCTAssertFalse(o.observe(phase: .connecting, applied: false, status: .stopped, current: 5), "one stop, noted once")
        o.restartUp(7)
        o.restartOver()
        XCTAssertFalse(o.observe(phase: .connecting, applied: false, status: .stopped, current: 7))
        o.restartUp(7)
        o.operation()
        XCTAssertFalse(o.observe(phase: .connecting, applied: false, status: .stopped, current: 7))
        // Without a generation, as before.
        o.restartUp(7)
        XCTAssertFalse(o.observe(phase: .connecting, applied: false, status: .stopped))
    }

    /// The app's own stops: a Disconnect, an erase or a teardown is an operation; one overtaken never settles for a newer.
    func testTheAppsOwnStopsAreNotNoted() {
        var o = OutsideStop()
        o.operation()
        XCTAssertFalse(o.observe(phase: .on, applied: false, status: .stopping))
        XCTAssertFalse(o.observe(phase: .paused, applied: true, status: .stopped))
        // An operation overtaken by a newer one (generation 2) doesn't settle on its behalf.
        o.settle(1, current: 2)
        XCTAssertFalse(o.observe(phase: .on, applied: false, status: .stopped))
        o.settle(2, current: 2)
        XCTAssertTrue(o.observe(phase: .on, applied: false, status: .stopped))
    }
}

/// An update replaced the extension: macOS stops the old tunnel for the swap, and the app hears that and "ready" in
/// either order, often while its takeover of the old tunnel still waits (a new build can't reach the old extension).
final class ReplacedReadyTests: XCTestCase {
    /// What `Connection.extensionReady` then decides, for a record of these accounts that ran and wasn't stopped.
    private func decision(stopped: Bool = false, read: Lifecycle.RecordRead = .record, provenance: Lifecycle.Provenance = .same) -> Lifecycle.Ready {
        Lifecycle.ready(replaced: true, read: read, held: false, provenance: provenance, stopped: stopped)
    }

    /// Stopped, its takeover over, then ready: decided at once, and nothing is left owed.
    func testStoppedThenReadyDecidesAtOnce() {
        var r = ReplacedReady()
        XCTAssertTrue(r.ready(adopting: false, status: .stopped, 3, replacement: 1))
        XCTAssertEqual(decision(), .connect)
        XCTAssertFalse(r.due(adopting: false, phase: .off, status: .stopped, current: 3, replacement: 1))
    }

    /// The live failure: ready while the takeover still waits (it shows connecting) and macOS is stopping the old tunnel.
    /// Decided once the takeover gave up on the stopped tunnel, once.
    func testReadyWhileTheTakeoverWaitsIsDecidedOnceItEnds() {
        for status in [Lifecycle.Status.stopping, .stopped] {
            var r = ReplacedReady()
            XCTAssertFalse(r.ready(adopting: true, status: status, 3, replacement: 1))
            // The tunnel not down yet: not yet.
            XCTAssertFalse(r.due(adopting: false, phase: .connecting, status: .stopping, current: 3, replacement: 1))
            XCTAssertFalse(r.due(adopting: false, phase: .connecting, status: .connected, current: 3, replacement: 1))
            // Down, seen by a takeover pass that still waits: the queued pass that ends it decides.
            XCTAssertFalse(r.due(adopting: true, phase: .connecting, status: .stopped, current: 3, replacement: 1))
            XCTAssertTrue(r.due(adopting: false, phase: .off, status: .stopped, current: 3, replacement: 1))
            XCTAssertEqual(decision(), .connect)
            XCTAssertFalse(r.due(adopting: false, phase: .off, status: .stopped, current: 3, replacement: 1), "decided once")
        }
    }

    /// The new extension runs an engine (Connect on Demand started it before this app saw the stop): recovery has ended,
    /// and a later stop is never taken for the swap's.
    func testAnEngineOnTheNewExtensionEndsRecovery() {
        var r = ReplacedReady()
        XCTAssertFalse(r.ready(adopting: false, status: .connected, 3, replacement: 1))
        r.over(replacement: 1)
        XCTAssertTrue(r.ended(1))
        XCTAssertFalse(r.due(adopting: false, phase: .off, status: .stopped, current: 3, replacement: 1))
        // Ready heard only after that: nothing owed, and what it decides connects nothing again.
        var late = ReplacedReady()
        late.over(replacement: 1)
        XCTAssertTrue(late.ready(adopting: true, status: .connected, 3, replacement: 1))
        XCTAssertTrue(late.ended(1))
        XCTAssertFalse(late.due(adopting: false, phase: .off, status: .stopped, current: 3, replacement: 1))
    }

    /// Put off while the old tunnel stops; Connect on Demand starts the new extension before the handlers see the stop,
    /// and the new extension refuses the copy it starts (it never comes up). That start ends nothing: the decision is
    /// still due once the tunnel is down, once.
    func testAStartThatNeverCameUpKeepsRecovery() {
        var r = ReplacedReady()
        r.observe(.stopping, replacement: 1)
        XCTAssertFalse(r.ready(adopting: true, status: .stopping, 3, replacement: 1))
        r.observe(.stopped, replacement: 1)
        r.observe(.connecting, replacement: 1)
        r.observe(.stopped, replacement: 1)
        XCTAssertNotNil(r.owed)
        XCTAssertFalse(r.ended(1))
        XCTAssertTrue(r.due(adopting: false, phase: .off, status: .stopped, current: 3, replacement: 1))
        // One attempt: its own failed start leads to nothing more.
        r.observe(.connecting, replacement: 1)
        r.observe(.stopped, replacement: 1)
        XCTAssertFalse(r.due(adopting: false, phase: .off, status: .stopped, current: 3, replacement: 1))
    }

    /// The swap stops the old tunnel, Connect on Demand brings the new one up, and the user stops it in System Settings
    /// while the takeover still shows connecting: a stop of a running tunnel, never undone, whether ready came before
    /// (put off) or comes after (decided at once), or the keychain makes it wait.
    func testAStopAfterTheNewTunnelCameUpEndsRecovery() {
        // Ready after.
        var r = ReplacedReady()
        r.observe(.stopping, replacement: 1)
        r.observe(.stopped, replacement: 1)
        r.observe(.connecting, replacement: 1)
        r.observe(.connected, replacement: 1)
        XCTAssertFalse(r.ended(1), "up, not yet stopped")
        r.observe(.stopping, replacement: 1)
        r.observe(.stopped, replacement: 1)
        XCTAssertTrue(r.ready(adopting: false, status: .stopped, 3, replacement: 1))
        XCTAssertTrue(r.ended(1))
        // Ready before (put off), the handlers never seeing the first stop.
        var p = ReplacedReady()
        p.observe(.stopping, replacement: 1)
        XCTAssertFalse(p.ready(adopting: true, status: .stopping, 3, replacement: 1))
        p.observe(.connected, replacement: 1)
        p.observe(.stopped, replacement: 1)
        XCTAssertTrue(p.ended(1))
        XCTAssertNil(p.owed)
        XCTAssertFalse(p.due(adopting: false, phase: .off, status: .stopped, current: 3, replacement: 1))
        // A stop and start seen for an earlier replacement doesn't count for this one.
        var e = ReplacedReady()
        e.observe(.stopped, replacement: 0)
        e.observe(.connected, replacement: 0)
        e.observe(.stopped, replacement: 0)
        XCTAssertFalse(e.ended(1))
        XCTAssertFalse(e.ready(adopting: true, status: .stopping, 3, replacement: 1))
    }

    /// An engine seen for one replacement (or a takeover before any) never stops a later replacement from being put off.
    func testAnEngineSeenForAnEarlierReplacementDoesNotCount() {
        var r = ReplacedReady()
        r.over(replacement: 0)
        XCTAssertFalse(r.ready(adopting: true, status: .stopping, 3, replacement: 1))
        XCTAssertTrue(r.due(adopting: false, phase: .off, status: .stopped, current: 3, replacement: 1))
        r.over(replacement: 1)
        XCTAssertTrue(r.ready(adopting: true, status: .stopping, 4, replacement: 1), "a second ready of the same one")
        XCTAssertFalse(r.ready(adopting: true, status: .stopping, 5, replacement: 2))
        XCTAssertFalse(r.ended(2))
        XCTAssertTrue(r.due(adopting: false, phase: .off, status: .stopped, current: 5, replacement: 2))
    }


    /// What was put off for one replacement is never decided during another.
    func testWhatIsOwedNeverOutlivesItsReplacement() {
        var r = ReplacedReady()
        XCTAssertFalse(r.ready(adopting: true, status: .stopping, 3, replacement: 1))
        XCTAssertFalse(r.due(adopting: false, phase: .off, status: .stopped, current: 3, replacement: 2))
        XCTAssertNil(r.owed)
    }

    /// Ready while the old tunnel still shows connected (or stopping), then stopped later: decided once it is down.
    func testReadyWhileStillConnectedIsDecidedOnceStopped() {
        for status in [Lifecycle.Status.connected, .stopping] {
            var r = ReplacedReady()
            XCTAssertFalse(r.ready(adopting: false, status: status, 3, replacement: 1))
            // The takeover it leads to waits, then the stop ends it.
            XCTAssertFalse(r.due(adopting: false, phase: .connecting, status: .stopping, current: 3, replacement: 1))
            XCTAssertTrue(r.due(adopting: false, phase: .off, status: .stopped, current: 3, replacement: 1))
        }
    }

    /// The user's Connect, Disconnect or Pause, a stop noted from outside, or a sign-out's erase, made before the decision
    /// was due, each start a generation: they own the outcome, and nothing reconnects for the update afterwards.
    func testAnOperationMadeSinceOwnsTheOutcome() {
        var r = ReplacedReady()
        XCTAssertFalse(r.ready(adopting: true, status: .stopping, 3, replacement: 1))
        XCTAssertFalse(r.due(adopting: false, phase: .off, status: .stopped, current: 4, replacement: 1))
        XCTAssertFalse(r.due(adopting: false, phase: .off, status: .stopped, current: 3, replacement: 1), "dropped, not kept for later")
        XCTAssertNil(r.owed)
    }

    /// The first stop seen after it was put off is the swap's: one that leaves something else showing (a Connect made
    /// meanwhile) ends what was owed, so a later stop, the user's in System Settings, is never taken for it.
    func testOnlyTheFirstStopSeenCounts() {
        var r = ReplacedReady()
        XCTAssertFalse(r.ready(adopting: true, status: .stopping, 3, replacement: 1))
        XCTAssertFalse(r.due(adopting: false, phase: .connecting, status: .stopped, current: 3, replacement: 1))
        XCTAssertNil(r.owed)
        XCTAssertFalse(r.due(adopting: false, phase: .off, status: .stopped, current: 3, replacement: 1))
    }

    /// Due, the decision is still the update's own: a connection the user stopped (in System Settings, or one macOS
    /// turned off before), a record a Disconnect or a revocation cleared, or another account's, is never connected again.
    func testWhatIsDueReconnectsOnlyWhatTheUserLeftOn() {
        var r = ReplacedReady()
        XCTAssertFalse(r.ready(adopting: true, status: .stopped, 3, replacement: 1))
        XCTAssertTrue(r.due(adopting: false, phase: .off, status: .stopped, current: 3, replacement: 1))
        XCTAssertEqual(decision(stopped: true), .reseal)
        XCTAssertEqual(decision(read: .none), .reseal)
        for p in [Lifecycle.Provenance.signedOut, .replaced, .unknown] { XCTAssertEqual(decision(provenance: p), .reseal) }
    }

    /// Ready again later decides afresh: what an earlier ready left owed doesn't survive one decided at once.
    func testAReadyDecidedAtOnceLeavesNothingOwed() {
        var r = ReplacedReady()
        XCTAssertFalse(r.ready(adopting: true, status: .stopping, 3, replacement: 1))
        XCTAssertTrue(r.ready(adopting: false, status: .stopped, 3, replacement: 1))
        XCTAssertFalse(r.due(adopting: false, phase: .off, status: .stopped, current: 3, replacement: 1))
    }
}

final class QuitPauseTests: XCTestCase {
    func testQuitWaitsForPauseWithoutBlockedAppsThenResumesIt() {
        XCTAssertEqual(Lifecycle.quitPause(phase: .on, timed: true, current: 7, expected: 7), .wait)
        XCTAssertEqual(Lifecycle.quitPause(phase: .paused, timed: true, current: 7, expected: 7), .resume)
    }

    func testQuitWaitsForPauseTransitionThenResumesIt() {
        XCTAssertEqual(Lifecycle.quitPause(phase: .connecting, timed: true, current: 7, expected: 7), .wait)
        XCTAssertEqual(Lifecycle.quitPause(phase: .paused, timed: true, current: 7, expected: 7), .resume)
    }

    func testQuitWaitsForExistingResumeWithoutStartingAnother() {
        XCTAssertEqual(Lifecycle.quitPause(phase: .connecting, timed: true, current: 7, expected: 7), .wait)
        XCTAssertEqual(Lifecycle.quitPause(phase: .on, timed: false, current: 7, expected: 7), .done)
    }

    func testQuitLeavesNewerOperationsAndUntimedPausesAlone() {
        for phase in [Snapshot.Phase.connecting, .paused, .on, .off] {
            XCTAssertEqual(Lifecycle.quitPause(phase: phase, timed: true, current: 8, expected: 7), .done)
            XCTAssertEqual(Lifecycle.quitPause(phase: phase, timed: false, current: 7, expected: 7), .done)
        }
        XCTAssertEqual(Lifecycle.quitPause(phase: .off, timed: true, current: 7, expected: 7), .done)
    }
}

/// The credential-free fallback sealed when Connect on Demand couldn't be turned off (`Lifecycle.fallbackNeeded`).
final class FallbackLifecycleTests: XCTestCase {
    private func engine(durable: String? = nil, foreign: Bool = false, startable: Bool = false, fallback: Bool = false, running: Bool = false,
                        othersFallback: Bool = false) -> Lifecycle.Engine {
        Lifecycle.Engine(running: nil, durable: durable, foreign: foreign, startable: startable, fallback: fallback, fallbackRunning: running,
                         othersFallback: othersFallback)
    }

    func testTheFallbackIsReadAsNothingOfTheUsersToStart() {
        let r = Lifecycle.revisions(["running": "f", "durable": "f", "startable": "1", "seal": "id", "fallback-durable": "1", "fallback-running": "1"])
        XCTAssertNil(r.durable)
        XCTAssertFalse(r.startable)
        XCTAssertTrue(r.fallback)
        XCTAssertTrue(r.fallbackRunning)
        XCTAssertEqual(r.running, "f")
        // So Connect on Demand isn't kept on for it.
        let e = Lifecycle.Engine(running: r.running, durable: r.durable, foreign: r.foreign, startable: r.startable, fallback: r.fallback)
        XCTAssertEqual(Lifecycle.onDemandHold(engine: e, owed: false), .disarm)
        // A real copy is read as before; a marker without a revision means nothing.
        let real = Lifecycle.revisions(["running": "a", "durable": "a", "startable": "1"])
        XCTAssertEqual(real.durable, "a")
        XCTAssertTrue(real.startable)
        XCTAssertFalse(real.fallback || real.fallbackRunning)
        let theirs = Lifecycle.revisions(["fallback-durable": "1", "fallback-running": "1", "startable": "1", "foreign": "1"])
        XCTAssertFalse(theirs.fallback || theirs.fallbackRunning, "another user's")
        XCTAssertNil(theirs.running)
        XCTAssertTrue(theirs.othersFallback)
        XCTAssertTrue(theirs.foreignFallback)
        XCTAssertFalse(theirs.startable, "another user's fallback is nothing to start either")
        XCTAssertFalse(real.othersFallback || real.foreignFallback)
        XCTAssertFalse(r.othersFallback || r.foreignFallback, "the user's own")
        // Another user's real copy stays theirs to start, and their engine theirs.
        let other = Lifecycle.revisions(["startable": "1", "foreign": "1"])
        XCTAssertTrue(other.startable)
        XCTAssertFalse(other.othersFallback || other.foreignFallback)
    }

    func testAnotherUsersFallbackIsNothingToKeepConnectOnDemandOnFor() {
        let r = Lifecycle.revisions(["fallback-durable": "1", "startable": "1", "seal": "id"])
        let e = Lifecycle.Engine(running: r.running, durable: r.durable, foreign: r.foreign, startable: r.startable, fallback: r.fallback,
                                 fallbackRunning: r.fallbackRunning, othersFallback: r.othersFallback)
        XCTAssertEqual(Lifecycle.onDemandHold(engine: e, owed: false), .disarm)
        XCTAssertFalse(Lifecycle.fallbackNeeded(onDemand: true, engine: e), "theirs keeps the Mac online as well")
        XCTAssertEqual(Lifecycle.reseal(engine: e, ready: true, provenance: .same, sealedBy: "1", previous: "1", build: "2", wanted: true),
                       .tell(updated: true), "never connected over it by itself")
        // Running, it is their engine: left as it is.
        XCTAssertEqual(Lifecycle.onDemandHold(engine: engine(foreign: true, othersFallback: true), owed: false), .leave)
    }

    func testAnOffFromBeforeIsLeftToAnotherUsersCopy() {
        XCTAssertEqual(Lifecycle.loadedOff(engine: engine(startable: true)), .hold, "another user's copy is sealed")
        XCTAssertEqual(Lifecycle.loadedOff(engine: engine(foreign: true)), .hold, "another user's engine runs")
        XCTAssertEqual(Lifecycle.loadedOff(engine: engine()), .off)
        XCTAssertEqual(Lifecycle.loadedOff(engine: engine(durable: "a", startable: true)), .off, "the user's own copy")
        XCTAssertEqual(Lifecycle.loadedOff(engine: engine(fallback: true)), .off, "the user's own fallback")
        XCTAssertEqual(Lifecycle.loadedOff(engine: engine(othersFallback: true)), .off, "another user's fallback is nothing to start")
        XCTAssertEqual(Lifecycle.loadedOff(engine: nil), .off, "not known: the user's Off")
    }

    func testAnInterruptedEraseNeverStopsTheFallbackWhileConnectOnDemandMayStartItAgain() {
        XCTAssertFalse(Lifecycle.eraseStop(fallbackRunning: true, durable: false, onDemand: true))
        XCTAssertFalse(Lifecycle.eraseStop(fallbackRunning: true, durable: false, onDemand: nil), "not known: on")
        XCTAssertTrue(Lifecycle.eraseStop(fallbackRunning: true, durable: false, onDemand: false), "off: nothing starts it again")
        XCTAssertTrue(Lifecycle.eraseStop(fallbackRunning: false, durable: false, onDemand: true), "anything else of the user's: stopped")
        XCTAssertTrue(Lifecycle.eraseStop(fallbackRunning: true, durable: true, onDemand: true), "a copy of theirs sealed since goes")
    }

    func testOnlyTheSealedFallbackMasksTheUsersCopy() {
        // Their fallback runs, but a real copy of theirs is sealed: it stays theirs to start.
        let both = Lifecycle.revisions(["running": "f", "durable": "a", "startable": "1", "fallback-running": "1"])
        XCTAssertEqual(both.durable, "a")
        XCTAssertTrue(both.startable)
        XCTAssertTrue(both.fallbackRunning)
        XCTAssertFalse(both.fallback || both.othersFallback || both.foreignFallback)
        // Another user's fallback runs, and nothing is sealed.
        let running = Lifecycle.revisions(["foreign": "1", "fallback-running": "1"])
        XCTAssertTrue(running.foreignFallback)
        XCTAssertFalse(running.othersFallback || running.startable || running.fallbackRunning)
        // Sealed only.
        let sealed = Lifecycle.revisions(["startable": "1", "fallback-durable": "1"])
        XCTAssertTrue(sealed.othersFallback)
        XCTAssertFalse(sealed.foreignFallback || sealed.startable || sealed.fallback)
    }

    func testAFallbackIsSealedOnlyWhenConnectOnDemandWouldStartNothing() {
        XCTAssertTrue(Lifecycle.fallbackNeeded(onDemand: true, engine: engine()))
        XCTAssertTrue(Lifecycle.fallbackNeeded(onDemand: nil, engine: engine()), "on or not known: the Mac must stay online")
        XCTAssertFalse(Lifecycle.fallbackNeeded(onDemand: false, engine: engine()), "off: nothing to start")
        XCTAssertFalse(Lifecycle.fallbackNeeded(onDemand: true, engine: nil), "no answer: nothing is known")
        XCTAssertFalse(Lifecycle.fallbackNeeded(onDemand: true, engine: engine(foreign: true)), "another user's engine runs")
        XCTAssertFalse(Lifecycle.fallbackNeeded(onDemand: true, engine: engine(startable: true)), "another user's copy is theirs to start")
        XCTAssertFalse(Lifecycle.fallbackNeeded(onDemand: true, engine: engine(durable: "a", startable: true)), "the user's own copy")
        XCTAssertFalse(Lifecycle.fallbackNeeded(onDemand: true, engine: engine(fallback: true)), "there already")
    }

    func testARunningFallbackIsStoppedOnlyOnceConnectOnDemandIsOff() {
        XCTAssertEqual(Lifecycle.fallbackAdoption(onDemand: false), .stop)
        XCTAssertEqual(Lifecycle.fallbackAdoption(onDemand: true), .show, "macOS would only start it again")
        XCTAssertEqual(Lifecycle.fallbackAdoption(onDemand: nil), .show)
    }

    func testTheFallbackIsDroppedOnceConnectOnDemandIsOff() {
        XCTAssertEqual(Lifecycle.fallbackRetire(onDemand: false, engine: engine(fallback: true), off: true), .drop(stop: false))
        XCTAssertEqual(Lifecycle.fallbackRetire(onDemand: false, engine: engine(fallback: true, running: true), off: true), .drop(stop: true))
        // Dropped already, still running while off: stopped.
        XCTAssertEqual(Lifecycle.fallbackRetire(onDemand: false, engine: engine(running: true), off: true), .drop(stop: true))
        // The user connected meanwhile: what runs is theirs, never stopped from here.
        XCTAssertEqual(Lifecycle.fallbackRetire(onDemand: false, engine: engine(fallback: true, running: true), off: false), .drop(stop: false))
        XCTAssertEqual(Lifecycle.fallbackRetire(onDemand: false, engine: engine(running: true), off: false), .none)
        XCTAssertEqual(Lifecycle.fallbackRetire(onDemand: true, engine: engine(fallback: true, running: true), off: true), .keep,
                       "still on: it is what keeps the Mac online")
        XCTAssertEqual(Lifecycle.fallbackRetire(onDemand: nil, engine: engine(fallback: true), off: true), .later)
        XCTAssertEqual(Lifecycle.fallbackRetire(onDemand: false, engine: nil, off: true), .later)
        XCTAssertEqual(Lifecycle.fallbackRetire(onDemand: false, engine: engine(durable: "a", startable: true), off: true), .none)
    }

    func testAnUpdateNeverConnectsByItselfOverTheFallback() {
        let none = Lifecycle.Engine(running: nil, durable: nil, foreign: false)
        XCTAssertEqual(Lifecycle.reseal(engine: none, ready: true, provenance: .same, sealedBy: "1", previous: "1", build: "2", wanted: true), .connect)
        XCTAssertEqual(Lifecycle.reseal(engine: engine(fallback: true), ready: true, provenance: .same, sealedBy: "1", previous: "1", build: "2", wanted: true),
                       .tell(updated: true))
    }

    func testASupersededDropSettlesOnTheFallback() {
        // It holds no account: whatever the drop named is gone.
        XCTAssertEqual(Lifecycle.supersededDrop(now: (seal: "F", durable: nil), sealedSince: false, fallback: true), .settled)
        XCTAssertEqual(Lifecycle.supersededDrop(now: (seal: "F", durable: nil), sealedSince: false), .renamed("F"))
    }
}

final class PauseDeadlineTests: XCTestCase {
    func testClockChangesSleepRelaunchAndReboot() {
        let wall = Date(timeIntervalSince1970: 1000)
        let d = PauseDeadline(wall: wall, uptime: 500, boot: "boot-a")
        XCTAssertEqual(d.remaining(wallNow: wall.addingTimeInterval(10000), uptimeNow: 450, bootNow: "boot-a"), 50)
        XCTAssertEqual(d.remaining(wallNow: wall.addingTimeInterval(-10000), uptimeNow: 501, bootNow: "boot-a"), 0)
        XCTAssertEqual(d.remaining(wallNow: wall.addingTimeInterval(-20), uptimeNow: 490, bootNow: "boot-a"), 10)
        XCTAssertEqual(d.remaining(wallNow: wall.addingTimeInterval(-20), uptimeNow: 5, bootNow: "boot-b"), 20)
        XCTAssertEqual(d.remaining(wallNow: wall.addingTimeInterval(-20), uptimeNow: nil, bootNow: nil), 20)
    }
}

final class ReloadLifecycleTests: XCTestCase {
    func testObservationAndTestingCleanupWaitForTheWholeReload() {
        var flight = ReloadFlight<String>()
        let token = flight.begin("edit")
        // Observation, test cleanup and route wakes see the same owner before, during and after provider lookup.
        for _ in ["preparing", "lookup", "applying", "recovering"] {
            XCTAssertTrue(flight.contains("edit"))
            XCTAssertFalse(flight.contains("newer edit"))
            XCTAssertTrue(flight.owns(token))
        }
        XCTAssertFalse(flight.finish(token), "no skipped wake means no extra timer")
        XCTAssertFalse(flight.contains("edit"), "cleanup may run once the edit has finished")
    }

    func testOnlyTheLatestReloadRearmsASkippedWake() {
        var flight = ReloadFlight<String>()
        let old = flight.begin("old")
        XCTAssertTrue(flight.skipRetry(for: "old"))
        let latest = flight.begin("new")
        XCTAssertFalse(flight.finish(old))
        XCTAssertTrue(flight.contains("new"))
        XCTAssertFalse(flight.skipRetry(for: "old"))
        XCTAssertTrue(flight.finish(latest))
        XCTAssertFalse(flight.finish(latest))
        let cancelled = flight.begin("new")
        XCTAssertTrue(flight.skipRetry(for: "new"))
        flight.clear()
        XCTAssertFalse(flight.finish(cancelled))
    }

    func testFallbackFlightDoesNotClaimThePendingEditsWake() {
        let now = ContinuousClock.now
        var retry = Retry<String>()
        let wait = retry.failed("edit", disrupted: false, now: now)!
        var flight = ReloadFlight<String>()
        let token = flight.begin("edit", fallback: "running")
        XCTAssertTrue(flight.contains("running"))
        XCTAssertFalse(flight.contains("edit"))
        XCTAssertFalse(flight.needsReconcile("edit", applied: "running", allowed: retry.allows("edit", now: now)))
        XCTAssertTrue(flight.needsReconcile("edit", applied: "running", allowed: retry.allows("edit", now: now + wait)))
        _ = flight.finish(token)
        XCTAssertTrue(flight.needsReconcile("edit", applied: "running", allowed: retry.allows("edit", now: now + wait)))
    }

    func testCancelledFlightReplaysTheDueEditOnlyAfterFinishing() {
        var flight = ReloadFlight<String>()
        let token = flight.begin("edit")
        XCTAssertFalse(flight.needsReconcile("edit", applied: nil, allowed: true))
        _ = flight.finish(token)
        XCTAssertTrue(flight.needsReconcile("edit", applied: nil, allowed: true))
        XCTAssertFalse(flight.needsReconcile("edit", applied: "edit", allowed: true))
        let next = flight.begin("new edit")
        _ = flight.finish(token)
        XCTAssertFalse(flight.needsReconcile("new edit", applied: "running", allowed: true))
        XCTAssertTrue(flight.owns(next))
    }

    func testFinishedFlightRespectsBackoffRefusalAndGiveUp() {
        let now = ContinuousClock.now
        var retry = Retry<String>()
        var flight = ReloadFlight<String>()
        for _ in 1...Retry<String>.limit {
            let token = flight.begin("edit")
            _ = retry.failed("edit", disrupted: true, now: now)
            _ = flight.finish(token)
            XCTAssertFalse(flight.needsReconcile("edit", applied: nil, allowed: retry.allows("edit", now: now)))
        }
        XCTAssertFalse(flight.needsReconcile("edit", applied: nil, allowed: retry.allows("edit", now: now + .seconds(3600))))
        retry.refuse("edit")
        XCTAssertFalse(flight.needsReconcile("edit", applied: nil, allowed: retry.allows("edit", now: now + .seconds(3600))))
        XCTAssertTrue(flight.needsReconcile("new edit", applied: nil, allowed: retry.allows("new edit", now: now)))
    }

    func testFinishedTestOnlyFailureDoesNotReplayWithoutBackoff() {
        var flight = ReloadFlight<String>()
        let token = flight.begin("test routes")
        _ = flight.finish(token)
        XCTAssertFalse(flight.needsReconcile("test routes", applied: "running", allowed: true, testChange: true))
        XCTAssertTrue(flight.needsReconcile("user edit", applied: "running", allowed: true, testChange: false))
    }

    func testHealthOnAnInterimRetriesTheEditAndAdvancesItsBackoff() {
        let now = ContinuousClock.now
        var retry = Retry<String>()
        XCTAssertEqual(retry.failed("edit", disrupted: true, now: now), .seconds(10))
        for expected: Duration? in [.seconds(30), nil] {
            let allowed = retry.allows("edit", now: now)
            XCTAssertFalse(allowed)
            XCTAssertFalse(Lifecycle.retryEdit(interim: true, health: false, allowed: allowed))
            XCTAssertFalse(Lifecycle.retryEdit(interim: false, health: true, allowed: allowed))
            let due = Lifecycle.retryEdit(interim: true, health: true, allowed: allowed)
            XCTAssertTrue(due, "a health move tries the edit, not the earlier setup")
            XCTAssertTrue(Lifecycle.mayRetryCommitted(interim: true, allowed: due))
            XCTAssertEqual(retry.failed("edit", disrupted: true, now: now), expected)
        }
        XCTAssertTrue(retry.refuses("edit"))
        XCTAssertTrue(Lifecycle.retryEdit(interim: true, health: true, allowed: retry.allows("edit", now: now)))
        retry.refuse("edit")
        XCTAssertTrue(Lifecycle.retryEdit(interim: true, health: true, allowed: retry.allows("edit", now: now)))
        XCTAssertFalse(Lifecycle.retryEdit(interim: true, health: false, allowed: retry.allows("edit", now: now)))
    }

    func testRestoredInterimCannotBypassEditBackoffOrGiveUp() {
        var retry = Retry<String>()
        var now = ContinuousClock.now
        for attempt in 1...Retry<String>.limit {
            let wait = retry.failed("edit", disrupted: true, now: now)
            XCTAssertFalse(Lifecycle.mayRetryCommitted(interim: true, allowed: retry.allows("edit", now: now)))
            if let wait {
                now += wait
                XCTAssertTrue(Lifecycle.mayRetryCommitted(interim: true, allowed: retry.allows("edit", now: now)))
            } else {
                XCTAssertEqual(attempt, Retry<String>.limit)
                XCTAssertFalse(Lifecycle.mayRetryCommitted(interim: true, allowed: retry.allows("edit", now: now + .seconds(3600))))
            }
        }
        XCTAssertTrue(Lifecycle.mayRetryCommitted(interim: true, allowed: retry.allows("new edit", now: now)))
        XCTAssertFalse(Lifecycle.mayRetryCommitted(interim: true, allowed: false), "ordinary route retries cannot use an interim to bypass a refused edit")
        XCTAssertTrue(Lifecycle.mayRetryCommitted(interim: false, allowed: false), "health may still move routes in a fully applied setup")
    }

    func testSealedSignOutSkipsOnlyAnIdenticalFinalApply() {
        XCTAssertTrue(Lifecycle.needsApply(signOut: .replace, sealedInterim: false, changed: false))
        XCTAssertFalse(Lifecycle.needsApply(signOut: .replace, sealedInterim: true, changed: false))
        XCTAssertTrue(Lifecycle.needsApply(signOut: .replace, sealedInterim: true, changed: true))
        XCTAssertTrue(Lifecycle.requiresDurable(.replace), "a different final configuration must still be sealed")
        XCTAssertFalse(Lifecycle.needsApply(signOut: .unchanged, sealedInterim: false, changed: false))
        XCTAssertTrue(Lifecycle.needsApply(signOut: .unchanged, sealedInterim: false, changed: true))
    }
}

final class DisconnectReasonTests: XCTestCase {
    func testAStopClearsThePreviousReasonAndAcceptsItsOwnAnswer() {
        var r = DisconnectReason()
        let first = r.begin()
        XCTAssertTrue(r.finish("old", generation: first))
        let second = r.begin()
        XCTAssertNil(r.text)
        XCTAssertTrue(r.pending)
        XCTAssertFalse(r.finish("late old", generation: first))
        XCTAssertTrue(r.finish("current", generation: second))
        XCTAssertEqual(r.text, "current")
        XCTAssertFalse(r.pending)
        XCTAssertFalse(r.finish("duplicate", generation: second))
        XCTAssertEqual(r.text, "current")
    }

    func testStartingAgainInvalidatesAnOutstandingFetch() {
        var r = DisconnectReason()
        let stopped = r.begin()
        r.invalidate()
        XCTAssertFalse(r.finish("old", generation: stopped))
        XCTAssertNil(r.text)
        XCTAssertFalse(r.pending)
    }

    func testANilAnswerCompletesTheFetchWithoutKeepingAnOldError() {
        var r = DisconnectReason()
        let old = r.begin()
        XCTAssertTrue(r.finish("old", generation: old))
        let current = r.begin()
        XCTAssertTrue(r.finish(nil, generation: current))
        XCTAssertNil(r.text)
        XCTAssertFalse(r.pending)
    }
}

@MainActor
final class ProbeResultTests: XCTestCase {
    func testCancellationBeforeRegistrationCompletesWithoutACallback() async {
        let result = ProbeResult<Void>()
        result.finish(.failure(CancellationError()))
        let done = expectation(description: "cancelled before registration")
        Task {
            do { try await result.wait(); XCTFail("cancelled probe succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
    }

    func testCancellationAfterRegistrationCompletesWithoutACallback() async {
        let result = ProbeResult<Data>()
        let done = expectation(description: "cancelled read")
        Task {
            do { _ = try await result.wait(); XCTFail("cancelled read succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            done.fulfill()
        }
        await Task.yield()
        result.finish(.failure(CancellationError()))
        result.finish(.success(Data([1])))
        await fulfillment(of: [done], timeout: 2)
    }

    func testCallbackAndCancellationRaceCompletesExactlyOnce() async {
        for _ in 0..<100 {
            let result = ProbeResult<Int>()
            let done = expectation(description: "race completed")
            Task {
                do { let value = try await result.wait(); XCTAssertEqual(value, 42) }
                catch { XCTAssertTrue(error is CancellationError) }
                done.fulfill()
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { result.finish(.success(42)) }
                group.addTask { result.finish(.failure(CancellationError())) }
            }
            await fulfillment(of: [done], timeout: 2)
        }
    }
}
