import XCTest

/// When a profile is switched by itself: only while connected, once a network has settled, once per network and rules,
/// never against a profile picked by hand.
final class AutoSwitchRunTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    private var rules: NetworkRules {
        var r = NetworkRules(salt: "salt")
        r.remember("home", name: "Home network", profile: "Home", now: t0)
        r.elsewhere = "Travel"
        return r
    }

    /// Connected on `mark` since t0, settled and decided once.
    private func settled(on mark: String = "home") -> AutoSwitchRun {
        var run = AutoSwitchRun(rules: rules, now: t0)
        XCTAssertEqual(run.handle([.connected(true), .network(mark)], now: t0), .wait(at(5)))
        XCTAssertEqual(run.handle(.timer, now: at(5)), .decide(mark: mark, acted: nil))
        return run
    }

    func testANetworkMustStayTheSameForTheSettleTime() {
        var run = AutoSwitchRun(rules: rules, now: t0)
        XCTAssertEqual(run.handle(.connected(true), now: t0), .nothing, "no network known yet")
        XCTAssertEqual(run.handle(.network("home"), now: at(1)), .wait(at(6)))
        XCTAssertEqual(run.handle(.timer, now: at(2)), .wait(at(6)), "a timer early waits on")
        // A handover in between starts over, back on the first network too.
        XCTAssertEqual(run.handle(.network("cafe"), now: at(3)), .wait(at(8)))
        XCTAssertEqual(run.handle(.network("home"), now: at(4)), .wait(at(9)))
        XCTAssertEqual(run.handle(.network(nil), now: at(5)), .nothing, "no network, or a router that hasn't answered")
        XCTAssertEqual(run.handle(.network("home"), now: at(6)), .wait(at(11)))
        XCTAssertEqual(run.handle(.timer, now: at(11)), .decide(mark: "home", acted: nil))
        // Decided: nothing more on this network with these rules, whatever else comes by.
        XCTAssertEqual(run.handle(.timer, now: at(20)), .nothing)
        XCTAssertEqual(run.handle(.network("home"), now: at(21)), .nothing)
        XCTAssertEqual(run.handle([.busy(true), .busy(false)], now: at(22)), .nothing)
        XCTAssertEqual(run.acted, AutoSwitch.Acted(mark: "home", rules: rules))
    }

    func testOnlyWhileConnectedAndOnceAtEachConnect() {
        var run = AutoSwitchRun(rules: rules, now: t0)
        XCTAssertEqual(run.handle(.network("cafe"), now: t0), .nothing, "not connected")
        XCTAssertEqual(run.handle(.timer, now: at(60)), .nothing)
        // Connecting (or resuming) starts the settle time: the switch comes a few seconds after it.
        XCTAssertEqual(run.handle(.connected(true), now: at(100)), .wait(at(105)))
        XCTAssertEqual(run.handle(.connected(false), now: at(102)), .nothing, "disconnected or paused before it settled")
        XCTAssertEqual(run.handle(.timer, now: at(105)), .nothing)
        XCTAssertEqual(run.handle(.connected(true), now: at(200)), .wait(at(205)))
        XCTAssertEqual(run.handle(.timer, now: at(205)), .decide(mark: "cafe", acted: nil))
        // Off and on again on the same network with the same rules: decided already, so a hand-picked profile stays.
        _ = run.handle(.connected(false), now: at(300))
        XCTAssertEqual(run.handle(.connected(true), now: at(400)), .wait(at(405)))
        XCTAssertEqual(run.handle(.timer, now: at(405)), .nothing)
        // On another network it decides again, and says what was decided before.
        XCTAssertEqual(run.handle(.network("home"), now: at(500)), .wait(at(505)))
        XCTAssertEqual(run.handle(.timer, now: at(505)), .decide(mark: "home", acted: AutoSwitch.Acted(mark: "cafe", rules: rules)))
    }

    func testAProfilePickedByHandStaysUntilTheNetworkChanges() {
        var run = settled(on: "home")
        // Picked while the network settles: that network counts as decided.
        XCTAssertEqual(run.handle(.network("cafe"), now: at(10)), .wait(at(15)))
        XCTAssertEqual(run.handle(.pickedByHand, now: at(12)), .wait(at(15)))
        XCTAssertEqual(run.handle(.timer, now: at(15)), .nothing)
        // Another network afterwards decides again.
        XCTAssertEqual(run.handle(.network("hotel"), now: at(20)), .wait(at(25)))
        XCTAssertEqual(run.handle(.timer, now: at(25)), .decide(mark: "hotel", acted: AutoSwitch.Acted(mark: "cafe", rules: rules)))
        // Picked while no network is known: the next one seen counts as decided, and only that one.
        _ = run.handle(.network(nil), now: at(30))
        XCTAssertEqual(run.handle(.pickedByHand, now: at(31)), .nothing)
        XCTAssertTrue(run.byHand)
        XCTAssertEqual(run.handle(.network("home"), now: at(32)), .wait(at(37)))
        XCTAssertEqual(run.handle(.timer, now: at(37)), .nothing)
        XCTAssertFalse(run.byHand)
        XCTAssertEqual(run.handle(.network("cafe"), now: at(40)), .wait(at(45)))
        XCTAssertEqual(run.handle(.timer, now: at(45)), .decide(mark: "cafe", acted: AutoSwitch.Acted(mark: "home", rules: rules)))
        // Picked by hand while disconnected, on a known network: still decided for it at the next connect.
        _ = run.handle(.connected(false), now: at(50))
        XCTAssertEqual(run.handle(.network("home"), now: at(51)), .nothing)
        _ = run.handle(.pickedByHand, now: at(52))
        XCTAssertEqual(run.handle(.connected(true), now: at(60)), .wait(at(65)))
        XCTAssertEqual(run.handle(.timer, now: at(65)), .nothing)
    }

    func testAChangeToTheRulesAppliesToTheNetworkTheMacIsOn() {
        var run = settled(on: "home")
        _ = run.handle(.pickedByHand, now: at(10))
        var changed = rules
        changed.known[0].profile = "Travel"
        // Even over a profile picked by hand, a few seconds after the change.
        XCTAssertEqual(run.handle(.rules(changed), now: at(20)), .wait(at(25)))
        XCTAssertEqual(run.handle(.timer, now: at(25)), .decide(mark: "home", acted: nil))
        // The same rules again are no change.
        XCTAssertEqual(run.handle(.rules(changed), now: at(30)), .nothing)
        // A hand-pick waiting for a network is dropped by new rules.
        _ = run.handle(.network(nil), now: at(40))
        _ = run.handle(.pickedByHand, now: at(41))
        _ = run.handle(.rules(rules), now: at(42))
        XCTAssertFalse(run.byHand)
        XCTAssertEqual(run.handle(.network("home"), now: at(43)), .wait(at(48)))
        XCTAssertEqual(run.handle(.timer, now: at(48)), .decide(mark: "home", acted: nil))
        // Rules that switch nowhere: nothing to decide, nothing to wait for.
        var none = rules
        none.known[0].profile = nil; none.elsewhere = nil
        XCTAssertEqual(run.handle(.rules(none), now: at(50)), .nothing)
        XCTAssertEqual(run.handle(.timer, now: at(60)), .nothing)
    }

    func testNothingIsDecidedWhileASwitchIsPending() {
        var run = AutoSwitchRun(rules: rules, now: t0)
        XCTAssertEqual(run.handle([.connected(true), .network("cafe"), .busy(true)], now: t0), .wait(at(5)))
        XCTAssertEqual(run.handle(.timer, now: at(5)), .nothing)
        XCTAssertNil(run.acted, "not decided: it is, once the switch settles")
        XCTAssertEqual(run.handle(.busy(false), now: at(30)), .decide(mark: "cafe", acted: nil))
        // Taken in together: connected and busy at once never decides on the half seen.
        var both = AutoSwitchRun(rules: rules, now: t0)
        _ = both.handle(.network("cafe"), now: t0)
        XCTAssertEqual(both.handle([.connected(true), .busy(true)], now: at(10)), .wait(at(15)))
        XCTAssertEqual(both.handle(.timer, now: at(15)), .nothing)
    }

    func testASwitchThatAProviderLimitWouldQuestionIsNeverStartedByItself() {
        var s = Setup(routes: [Route(id: "a", loc: Location(provider: "nord", countryId: 1)), Route(id: "b", loc: Location(provider: "nord", countryId: 2))],
                      defaultRoute: "a", apps: ["x": "b"])
        let one = Limit(unit: "connection", perTunnel: true, value: 1), two = Limit(unit: "connection", perTunnel: true, value: 2)
        XCTAssertTrue(AutoSwitchRun.over(s, limits: { _ in one }), "two tunnels, one allowed")
        XCTAssertFalse(AutoSwitchRun.over(s, limits: { _ in two }))
        XCTAssertFalse(AutoSwitchRun.over(s, limits: { _ in nil }), "no limit known")
        XCTAssertFalse(AutoSwitchRun.over(s, limits: { _ in Limit(unit: "device", perTunnel: false, value: 1) }), "a device limit isn't per tunnel")
        s.apps = [:]
        XCTAssertFalse(AutoSwitchRun.over(s, limits: { _ in one }))
    }
}
