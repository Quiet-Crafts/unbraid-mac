import XCTest

/// When a profile is switched by itself: only while connected, once a network has settled, once per network and the
/// profile its rule names, never against a profile picked by hand. Times come from the continuous clock the tests hand
/// in, never the wall clock.
final class AutoSwitchRunTests: XCTestCase {
    private typealias Run = AutoSwitchRun
    private let t0 = ContinuousClock.now
    private func at(_ s: Double) -> ContinuousClock.Instant { t0 + .seconds(s) }
    private func on(_ mark: String) -> Run.Event { .network(.mark(mark)) }
    private let unrecognised = AutoSwitch.unrecognised

    private var rules: NetworkRules {
        var r = NetworkRules(salt: "salt")
        r.remember("home", name: "Home network", profile: "Home", now: Date(timeIntervalSince1970: 1_800_000_000))
        r.elsewhere = "Travel"
        return r
    }

    /// Connected on `mark` since t0, settled and decided once.
    private func settled(on mark: String = "home") -> Run {
        var run = Run(rules: rules, now: t0)
        XCTAssertEqual(run.handle([.connected(true), on(mark)], now: t0), .wait(at(5)))
        XCTAssertEqual(run.handle(.timer, now: at(5)), .decide(mark: mark, acted: nil))
        return run
    }

    func testANetworkMustStayTheSameForTheSettleTime() {
        var run = Run(rules: rules, now: t0)
        XCTAssertEqual(run.handle(.connected(true), now: t0), .nothing, "no network yet")
        XCTAssertEqual(run.handle(on("home"), now: at(1)), .wait(at(6)))
        XCTAssertEqual(run.handle(.timer, now: at(2)), .wait(at(6)), "a timer early waits on")
        // A handover in between starts over, back on the first network too.
        XCTAssertEqual(run.handle(on("cafe"), now: at(3)), .wait(at(8)))
        XCTAssertEqual(run.handle(on("home"), now: at(4)), .wait(at(9)))
        XCTAssertEqual(run.handle(.network(.offline), now: at(5)), .nothing, "no network")
        XCTAssertEqual(run.handle(.network(.reading()), now: at(5.5)), .wait(at(25.5)), "a router that hasn't answered")
        XCTAssertEqual(run.handle(on("home"), now: at(6)), .wait(at(11)))
        XCTAssertEqual(run.handle(.timer, now: at(11)), .decide(mark: "home", acted: nil))
        // Decided: nothing more on this network with this rule, whatever else comes by.
        XCTAssertEqual(run.handle(.timer, now: at(20)), .nothing)
        XCTAssertEqual(run.handle(on("home"), now: at(21)), .nothing)
        XCTAssertEqual(run.handle([.busy(true), .busy(false)], now: at(22)), .nothing)
        XCTAssertEqual(run.acted, AutoSwitch.Acted(mark: "home", rules: rules))
    }

    /// A network the Mac is on that gives no fingerprint (no IPv6, a router called "1") gets the profile for any other
    /// network, once its router has had time enough to answer; while offline nothing is decided.
    func testANetworkWithoutAFingerprintCountsAsAnyOtherNetwork() {
        XCTAssertEqual(rules.profile(on: unrecognised), "Travel")
        var run = settled(on: "home")
        XCTAssertEqual(run.handle(.network(.offline), now: at(10)), .nothing)
        XCTAssertEqual(run.handle(.timer, now: at(100)), .nothing, "offline decides nothing, however long")
        XCTAssertNil(run.here(at: at(100)))
        // Joined a café whose router gives nothing: about 20 seconds of reading first.
        XCTAssertEqual(run.handle(.network(.reading()), now: at(200)), .wait(at(220)))
        XCTAssertNil(run.here(at: at(219)))
        XCTAssertEqual(run.handle(.timer, now: at(212)), .wait(at(220)))
        XCTAssertEqual(run.handle(.timer, now: at(220)), .decide(mark: unrecognised, acted: AutoSwitch.Acted(mark: "home", rules: rules)))
        XCTAssertEqual(run.here(at: at(220)), unrecognised)
        XCTAssertEqual(run.handle(.timer, now: at(300)), .nothing, "decided once")
        // A router that answers late after all: its own network decides again.
        XCTAssertEqual(run.handle(on("home"), now: at(330)), .wait(at(335)))
        XCTAssertEqual(run.handle(.timer, now: at(335)), .decide(mark: "home", acted: AutoSwitch.Acted(mark: unrecognised, rules: rules)))
        // Connecting on such a network waits the settle time too, never less than the reading time.
        var later = Run(rules: rules, now: t0)
        XCTAssertEqual(later.handle(.network(.reading()), now: t0), .nothing, "not connected")
        XCTAssertEqual(later.handle(.connected(true), now: at(3)), .wait(at(20)))
        XCTAssertEqual(later.handle(.connected(true), now: at(19)), .wait(at(20)))
        XCTAssertEqual(later.handle(.timer, now: at(20)), .decide(mark: unrecognised, acted: nil))
        var late = Run(rules: rules, now: t0)
        _ = late.handle(.network(.reading()), now: t0)
        XCTAssertEqual(late.handle(.connected(true), now: at(60)), .wait(at(65)))
        XCTAssertEqual(late.handle(.timer, now: at(65)), .decide(mark: unrecognised, acted: nil))
    }

    /// Waking from sleep and the tunnel reconnecting read the network again: on a remembered network whose router
    /// answers within the reading time, nothing is switched, there and back.
    func testAWakeOrAReconnectOnARememberedNetworkSwitchesNothing() {
        var run = settled(on: "home")
        // Wake: the Wi-Fi goes, comes back, the router answers after a while.
        XCTAssertEqual(run.handle(.network(.offline), now: at(100)), .nothing)
        // Reached the same way after a moment offline: waiting for home's router, never a network to switch for.
        XCTAssertEqual(run.handle(.network(.reading()), now: at(103)), .nothing)
        XCTAssertEqual(run.handle(.timer, now: at(110)), .nothing)
        XCTAssertEqual(run.handle(on("home"), now: at(118)), .wait(at(123)))
        XCTAssertEqual(run.handle(.timer, now: at(123)), .nothing)
        // The tunnel reconnecting, the path changing under it and the router read again in between.
        XCTAssertEqual(run.handle(.connected(false), now: at(200)), .nothing)
        XCTAssertEqual(run.handle(.network(.reading()), now: at(201)), .nothing)
        XCTAssertEqual(run.handle([.connected(true), on("home")], now: at(204)), .wait(at(209)))
        XCTAssertEqual(run.handle(.timer, now: at(209)), .nothing)
        // A profile picked by hand at home stays through both.
        _ = run.handle(.pickedByHand, now: at(300))
        for (i, step) in [Run.Event.network(.offline), .network(.reading()), .connected(false), .connected(true), on("home")].enumerated() {
            if case .decide = run.handle(step, now: at(301 + Double(i))) { XCTFail("switched at step \(i)") }
        }
        XCTAssertEqual(run.handle(.timer, now: at(320)), .nothing)
        XCTAssertEqual(run.acted, AutoSwitch.Acted(mark: "home", rules: rules))
    }

    /// A home with two routers, one of them away for a while, then back: still home, so a hand pick stays.
    func testARouterComingAndGoingIsTheSameNetwork() {
        var r = NetworkRules(salt: "salt")
        r.remember("h1,h2", name: "Home network", profile: "Home")
        r.elsewhere = "Travel"
        var run = Run(rules: r, now: t0)
        XCTAssertEqual(run.handle([.connected(true), on("h1,h2")], now: t0), .wait(at(5)))
        XCTAssertEqual(run.handle(.timer, now: at(5)), .decide(mark: "h1,h2", acted: nil))
        _ = run.handle(.pickedByHand, now: at(10))
        XCTAssertEqual(run.handle(on("h2"), now: at(20)), .wait(at(25)))
        XCTAssertEqual(run.handle(.timer, now: at(25)), .nothing)
        XCTAssertEqual(run.handle(on("h1,h2"), now: at(30)), .wait(at(35)))
        XCTAssertEqual(run.handle(.timer, now: at(35)), .nothing)
        // A router home doesn't have: another network.
        XCTAssertEqual(run.handle(on("h2,x"), now: at(40)), .wait(at(45)))
        XCTAssertEqual(run.handle(.timer, now: at(45)), .decide(mark: "h2,x", acted: AutoSwitch.Acted(mark: "h1", rules: r)))
    }

    /// Two remembered networks sharing a router: while the Mac is on one, its routers coming and going never move it to
    /// the other (a pending switch checks the same name); joined fresh on the shared router alone, it is neither.
    func testOverlappingNetworksNeverTakeTurns() {
        var r = NetworkRules(salt: "salt")
        r.remember("b,c", name: "Home network", profile: "Home")
        r.remember("b,x", name: "Office", profile: nil)
        r.elsewhere = "Travel"
        var run = Run(rules: r, now: t0)
        XCTAssertEqual(run.handle([.connected(true), on("b,x")], now: t0), .wait(at(5)))
        XCTAssertEqual(run.handle(.timer, now: at(5)), .decide(mark: "b,x", acted: nil))
        _ = run.handle(.pickedByHand, now: at(10))
        // The office's own router goes away: still the office, nothing decided.
        XCTAssertEqual(run.handle(on("b"), now: at(20)), .wait(at(25)))
        XCTAssertEqual(run.here(at: at(20)), "b,x")
        XCTAssertEqual(run.handle(.timer, now: at(25)), .nothing)
        XCTAssertEqual(run.handle(on("b,x"), now: at(30)), .wait(at(35)))
        XCTAssertEqual(run.handle(.timer, now: at(35)), .nothing)
        // Home the same way: a router away while a switch to Home is pending leaves it the same network.
        XCTAssertEqual(run.handle(on("b,c"), now: at(40)), .wait(at(45)))
        XCTAssertEqual(run.handle(.timer, now: at(45)), .decide(mark: "b,c", acted: AutoSwitch.Acted(mark: "b,x", rules: r)))
        _ = run.handle(on("c"), now: at(46))
        XCTAssertEqual(run.here(at: at(46)), "b,c", "what the pending switch compares with")
        _ = run.handle(on("b"), now: at(47))
        XCTAssertEqual(run.here(at: at(47)), "b,c")
        // Joined fresh with only the shared router: neither network, so any other network's profile.
        var fresh = Run(rules: r, now: t0)
        XCTAssertEqual(fresh.handle([.connected(true), on("b")], now: t0), .wait(at(5)))
        XCTAssertEqual(fresh.handle(.timer, now: at(5)), .decide(mark: "b", acted: nil))
        XCTAssertEqual(r.profile(on: "b"), "Travel")
    }

    /// A rename made while the network reads nothing (a reconnect) follows the hand pick all the same.
    func testARenameWhileTheNetworkIsUnreadKeepsAHandPick() {
        var run = pickedOnHome()
        _ = run.handle(.network(.reading()), now: at(20))
        var r = run.rules
        r.renamed("Home", to: "House")
        _ = run.handle([.profiles(["House", "Travel"]), .rules(r)], now: at(21))
        XCTAssertEqual(run.handle(on("home"), now: at(24)), .wait(at(29)))
        XCTAssertEqual(run.handle(.timer, now: at(29)), .nothing)
        // While offline too.
        _ = run.handle(.network(.offline), now: at(30))
        r.renamed("House", to: "Casa")
        _ = run.handle([.profiles(["Casa", "Travel"]), .rules(r)], now: at(31))
        XCTAssertEqual(run.handle(on("home"), now: at(32)), .wait(at(37)))
        XCTAssertEqual(run.handle(.timer, now: at(37)), .nothing)
    }

    /// Networks unbraid can't recognise all look alike: a hand pick on one stays through a reconnect there, but going
    /// offline, or another interface or router, makes the next one another network.
    func testAHandPickOnAnUnrecognisedNetworkEndsWhenTheMacMoves() {
        var run = Run(rules: rules, now: t0)
        _ = run.handle([.connected(true), .network(.reading(place: "en0|10.0.0.1"))], now: t0)
        XCTAssertEqual(run.handle(.timer, now: at(20)), .decide(mark: unrecognised, acted: nil))
        _ = run.handle(.pickedByHand, now: at(30))
        // A tunnel reconnect, the router read again: the same place, the pick stays.
        _ = run.handle([.connected(false), .connected(true)], now: at(40))
        XCTAssertEqual(run.handle(.timer, now: at(45)), .nothing)
        // A fingerprint that shows for a moment and goes again doesn't end it either.
        _ = run.handle(on("cafe"), now: at(50))
        _ = run.handle(.network(.reading(place: "en0|10.0.0.1")), now: at(51))
        XCTAssertEqual(run.handle(.timer, now: at(71)), .nothing)
        // A recognised network in between does.
        XCTAssertEqual(run.handle(on("cafe"), now: at(72)), .wait(at(77)))
        XCTAssertEqual(run.handle(.timer, now: at(77)), .decide(mark: "cafe", acted: AutoSwitch.Acted(mark: unrecognised, rules: rules)))
        _ = run.handle(.network(.reading(place: "en0|10.0.0.1")), now: at(78))
        XCTAssertEqual(run.handle(.timer, now: at(98)), .decide(mark: unrecognised, acted: AutoSwitch.Acted(mark: "cafe", rules: rules)))
        _ = run.handle(.pickedByHand, now: at(99))
        XCTAssertEqual(run.handle(.network(.reading(place: "en0|10.0.0.1")), now: at(100)), .nothing, "no change")
        // Another router: another network.
        XCTAssertEqual(run.handle(.network(.reading(place: "en0|192.168.1.1")), now: at(110)), .wait(at(130)))
        XCTAssertEqual(run.handle(.timer, now: at(130)), .decide(mark: unrecognised, acted: nil))
        _ = run.handle(.pickedByHand, now: at(131))
        // Offline (a sleep, a move), then a network that again gives nothing: decided again.
        _ = run.handle(.network(.offline), now: at(140))
        _ = run.handle(.network(.reading(place: "en0|192.168.1.1")), now: at(150))
        XCTAssertEqual(run.handle(.timer, now: at(170)), .decide(mark: unrecognised, acted: nil))
        // Another interface (a cable): another network too.
        _ = run.handle(.pickedByHand, now: at(171))
        _ = run.handle(.network(.reading(place: "en5|192.168.1.1")), now: at(180))
        XCTAssertEqual(run.handle(.timer, now: at(200)), .decide(mark: unrecognised, acted: nil))
    }

    // The case found by an adversarial run, kept here, with its mirrors. Home has two routers.
    private var twoRouters: NetworkRules {
        var r = NetworkRules(salt: "salt")
        r.remember("a,b", name: "Home network", profile: "Home")
        r.remember("c", name: "Office", profile: nil)
        r.elsewhere = "Travel"
        return r
    }
    private func atHome(_ place: String = "en0|192.168.1.1") -> Run {
        var run = Run(rules: twoRouters, now: t0)
        _ = run.handle([.profiles(["Home", "Travel", "Work"]), .connected(true), .network(.mark("a,b", place: place))], now: t0)
        XCTAssertEqual(run.handle(.timer, now: at(5)), .decide(mark: "a,b", acted: nil))
        return run
    }
    /// Feeds `steps` (seconds, events), firing the timer whenever a wait falls due before the next step, as the
    /// watcher does; returns the decisions.
    private func drive(_ run: inout Run, _ steps: [(Double, [Run.Event])], until end: Double) -> [String] {
        var out: [String] = [], pending: ContinuousClock.Instant?
        func record(_ a: Run.Action) {
            if case .decide(let m, _) = a { out.append(m) }
            if case .wait(let w) = a { pending = w } else { pending = nil }
        }
        for (t, events) in steps + [(end, [Run.Event.timer])] {
            while let w = pending, w <= at(t) { pending = nil; record(run.handle(.timer, now: w)) }
            record(run.handle(events, now: at(t)))
        }
        return out
    }

    /// A wake or a roam at home: the Wi-Fi back after a moment, the routers answering however late. Never a switch away
    /// and back, and a hand pick stays.
    func testAWakeAtHomeNeverSwitchesAwayAndBack() {
        for answer in [0.5, 3, 10, 19, 19.9, 21, 25, 30, 60, 300] {
            for heard in ["a", "b", "a,b"] {
                var run = atHome()
                _ = run.handle(.pickedByHand, now: at(50))
                let got = drive(&run, [(100, [.network(.offline)]), (102, [.network(.reading(place: "en0|192.168.1.1"))]),
                                       (102 + answer, [.network(.mark(heard, place: "en0|192.168.1.1"))])], until: 600)
                XCTAssertEqual(got, [], "router \(heard) answering \(answer) s after the Wi-Fi")
                XCTAssertEqual(run.acted, AutoSwitch.Acted(mark: "a,b", rules: twoRouters))
            }
        }
        // A roam with no offline at all, and a reading with no gateway known (IPv6 only) the same way.
        var roam = atHome("en0|")
        XCTAssertEqual(drive(&roam, [(100, [.network(.reading(place: "en0|"))]), (160, [.network(.mark("a", place: "en0|"))])], until: 300), [])
    }

    /// The mirrors: a new attachment, a long time offline, a router for another network, or a last decision that wasn't
    /// a remembered network all still give the profile for any other network after about 20 seconds.
    func testALateRouterIsWaitedForOnlyOnTheSameAttachment() {
        // Another router (a café that gives no fingerprint): about 20 s.
        var cafe = atHome()
        XCTAssertEqual(drive(&cafe, [(100, [.network(.offline)]), (102, [.network(.reading(place: "en0|10.0.0.1"))])], until: 200), [unrecognised])
        // Another interface.
        var cable = atHome()
        XCTAssertEqual(drive(&cable, [(100, [.network(.reading(place: "en5|192.168.1.1"))])], until: 200), [unrecognised])
        // Offline for longer than a moment (a night's sleep, a journey), then a router that looks like home's.
        var night = atHome()
        XCTAssertEqual(drive(&night, [(100, [.network(.offline)]), (100 + 3600, [.network(.reading(place: "en0|192.168.1.1"))])], until: 3800), [unrecognised])
        // The reading completes with routers home doesn't have: that network, at once.
        var other = atHome()
        XCTAssertEqual(drive(&other, [(100, [.network(.offline)]), (102, [.network(.reading(place: "en0|192.168.1.1"))]),
                                      (140, [.network(.mark("a,x", place: "en0|192.168.1.1"))])], until: 200), ["a,x"])
        // Last decided on a network unbraid can't recognise: nothing to wait for (and going offline there counts as
        // leaving it, so it is decided again).
        var away = Run(rules: twoRouters, now: t0)
        XCTAssertEqual(drive(&away, [(0, [.connected(true), .network(.reading(place: "en0|10.0.0.1"))]), (30, [.network(.offline)]),
                                     (32, [.network(.reading(place: "en0|10.0.0.1"))])], until: 200), [unrecognised, unrecognised])
    }

    func testOnlyWhileConnectedAndOnceAtEachConnect() {
        var run = Run(rules: rules, now: t0)
        XCTAssertEqual(run.handle(on("cafe"), now: t0), .nothing, "not connected")
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
        XCTAssertEqual(run.handle(on("home"), now: at(500)), .wait(at(505)))
        XCTAssertEqual(run.handle(.timer, now: at(505)), .decide(mark: "home", acted: AutoSwitch.Acted(mark: "cafe", rules: rules)))
    }

    func testAProfilePickedByHandStaysUntilTheNetworkChanges() {
        var run = settled(on: "home")
        // Picked while the network settles: that network counts as decided.
        XCTAssertEqual(run.handle(on("cafe"), now: at(10)), .wait(at(15)))
        XCTAssertEqual(run.handle(.pickedByHand, now: at(12)), .wait(at(15)))
        XCTAssertEqual(run.handle(.timer, now: at(15)), .nothing)
        // Another network afterwards decides again.
        XCTAssertEqual(run.handle(on("hotel"), now: at(20)), .wait(at(25)))
        XCTAssertEqual(run.handle(.timer, now: at(25)), .decide(mark: "hotel", acted: AutoSwitch.Acted(mark: "cafe", rules: rules)))
        // Picked while the router hasn't answered: the network it answers for counts as decided, and only that one.
        _ = run.handle(.network(.reading()), now: at(30))
        XCTAssertEqual(run.handle(.pickedByHand, now: at(31)), .wait(at(50)))
        XCTAssertNotNil(run.byHand)
        XCTAssertEqual(run.handle(on("home"), now: at(32)), .wait(at(37)))
        XCTAssertNil(run.byHand)
        XCTAssertEqual(run.handle(.timer, now: at(37)), .nothing)
        XCTAssertEqual(run.handle(on("cafe"), now: at(40)), .wait(at(45)))
        XCTAssertEqual(run.handle(.timer, now: at(45)), .decide(mark: "cafe", acted: AutoSwitch.Acted(mark: "home", rules: rules)))
        // Picked on a network unbraid can't recognise: it stays there, and a remembered network decides again.
        _ = run.handle(.network(.reading()), now: at(50))
        XCTAssertEqual(run.handle(.timer, now: at(70)), .decide(mark: unrecognised, acted: AutoSwitch.Acted(mark: "cafe", rules: rules)))
        _ = run.handle(.pickedByHand, now: at(80))
        XCTAssertEqual(run.handle([.connected(false), .connected(true)], now: at(90)), .wait(at(95)))
        XCTAssertEqual(run.handle(.timer, now: at(95)), .nothing)
        XCTAssertEqual(run.handle(on("home"), now: at(100)), .wait(at(105)))
        XCTAssertEqual(run.handle(.timer, now: at(105)), .decide(mark: "home", acted: AutoSwitch.Acted(mark: unrecognised, rules: rules)))
        // Picked by hand while disconnected, on a known network: still decided for it at the next connect.
        _ = run.handle(.connected(false), now: at(110))
        XCTAssertEqual(run.handle(on("cafe"), now: at(111)), .nothing)
        _ = run.handle(.pickedByHand, now: at(112))
        XCTAssertEqual(run.handle(.connected(true), now: at(120)), .wait(at(125)))
        XCTAssertEqual(run.handle(.timer, now: at(125)), .nothing)
    }

    /// A pick made before any network was known only counts for a network known soon after; going offline drops it.
    func testAHandPickWithoutANetworkExpires() {
        var run = settled(on: "home")
        _ = run.handle(.network(.offline), now: at(10))
        _ = run.handle(.pickedByHand, now: at(11))
        XCTAssertNotNil(run.byHand)
        // An hour later, a remembered network: its rule applies.
        XCTAssertEqual(run.handle(on("cafe"), now: at(3600)), .wait(at(3605)))
        XCTAssertNil(run.byHand)
        XCTAssertEqual(run.handle(.timer, now: at(3605)), .decide(mark: "cafe", acted: AutoSwitch.Acted(mark: "home", rules: rules)))
        // Picked while reading, then offline before an answer: dropped.
        _ = run.handle(.network(.reading()), now: at(4000))
        _ = run.handle(.pickedByHand, now: at(4001))
        _ = run.handle(.network(.offline), now: at(4002))
        XCTAssertNil(run.byHand)
        XCTAssertEqual(run.handle(on("home"), now: at(4003)), .wait(at(4008)))
        XCTAssertEqual(run.handle(.timer, now: at(4008)), .decide(mark: "home", acted: AutoSwitch.Acted(mark: "cafe", rules: rules)))
        // Picked offline, then a new network that never gives a fingerprint: it counts as unrecognised too late for the
        // pick.
        _ = run.handle(.network(.offline), now: at(5000))
        _ = run.handle(.pickedByHand, now: at(5001))
        _ = run.handle(.network(.reading(place: "en0|10.0.0.1")), now: at(5010))
        XCTAssertEqual(run.handle(.timer, now: at(5030)), .decide(mark: unrecognised, acted: AutoSwitch.Acted(mark: "home", rules: rules)))
        // Picked while reading, the network then unrecognised: decided, even when nothing looked at it on time.
        _ = run.handle(.connected(false), now: at(6000))
        _ = run.handle(on("cafe"), now: at(6001))
        _ = run.handle(.network(.reading(place: "en0|10.0.0.1")), now: at(6002))
        _ = run.handle(.pickedByHand, now: at(6010))
        XCTAssertEqual(run.handle(.connected(true), now: at(6100)), .wait(at(6105)))
        XCTAssertEqual(run.handle(.timer, now: at(6105)), .nothing)
        XCTAssertEqual(run.acted, AutoSwitch.Acted(mark: unrecognised, rules: rules))
    }

    func testAChangeToTheRulesAppliesToTheNetworkTheMacIsOn() {
        var run = settled(on: "home")
        _ = run.handle(.pickedByHand, now: at(10))
        // A change about another network, or a new name, keeps the profile picked by hand here.
        var other = rules
        other.remember("office", name: "Office", profile: "Travel")
        other.known[0].name = "House"
        XCTAssertEqual(run.handle(.rules(other), now: at(15)), .nothing)
        XCTAssertEqual(run.handle(.timer, now: at(30)), .nothing)
        // A new profile for this network applies, even over a profile picked by hand, a few seconds after the change.
        var changed = other
        changed.known[0].profile = "Travel"
        XCTAssertEqual(run.handle(.rules(changed), now: at(40)), .wait(at(45)))
        XCTAssertEqual(run.handle(.timer, now: at(45)), .decide(mark: "home", acted: AutoSwitch.Acted(mark: "home", rules: rules)))
        // The same rules again are no change.
        XCTAssertEqual(run.handle(.rules(changed), now: at(50)), .nothing)
        // A hand-pick waiting for a network is dropped by new rules.
        _ = run.handle(.network(.reading()), now: at(60))
        _ = run.handle(.pickedByHand, now: at(61))
        _ = run.handle(.rules(rules), now: at(62))
        XCTAssertNil(run.byHand)
        XCTAssertEqual(run.handle(on("home"), now: at(63)), .wait(at(68)))
        XCTAssertEqual(run.handle(.timer, now: at(68)), .decide(mark: "home", acted: AutoSwitch.Acted(mark: "home", rules: changed)))
        // Rules that switch nowhere: nothing to decide, nothing to wait for.
        var none = rules
        none.known[0].profile = nil; none.elsewhere = nil
        XCTAssertEqual(run.handle(.rules(none), now: at(70)), .nothing)
        XCTAssertEqual(run.handle(.timer, now: at(80)), .nothing)
    }

    // Cases found by an adversarial run, kept here: settled and decided on home, then a profile picked by hand there.
    private func pickedOnHome() -> Run {
        var r = rules
        r.remember("office", name: "Office", profile: nil)
        var run = Run(rules: r, now: t0)
        _ = run.handle([.connected(true), on("home")], now: t0)
        XCTAssertEqual(run.handle(.timer, now: at(5)), .decide(mark: "home", acted: nil))
        XCTAssertEqual(run.handle(.pickedByHand, now: at(10)), .nothing)
        return run
    }
    private func decides(_ actions: [Run.Action]) -> Bool { actions.contains { if case .decide = $0 { true } else { false } } }

    func testAHandPickStaysWhenTheRuleForAnotherNetworkChanges() {
        var run = pickedOnHome()
        var r = run.rules
        r.elsewhere = nil
        XCTAssertFalse(decides([run.handle(.rules(r), now: at(20)), run.handle(.timer, now: at(25))]))
    }

    func testAHandPickStaysWhenTheHomeRulesProfileIsRenamed() {
        var run = pickedOnHome()
        var r = run.rules
        r.renamed("Home", to: "House")
        XCTAssertFalse(decides([run.handle([.profiles(["House", "Travel"]), .rules(r)], now: at(20)), run.handle(.timer, now: at(25))]))
        XCTAssertEqual(run.acted, AutoSwitch.Acted(mark: "home", rules: r))
        // Its rule then set to another profile: that applies.
        let house = run.acted
        r.known[0].profile = "Travel"
        XCTAssertEqual(run.handle(.rules(r), now: at(30)), .wait(at(35)))
        XCTAssertEqual(run.handle(.timer, now: at(35)), .decide(mark: "home", acted: house))
    }

    func testAHandPickStaysThroughAShortDropOnTheSameNetwork() {
        var run = pickedOnHome()
        XCTAssertEqual(run.handle(.network(.offline), now: at(20)), .nothing)
        XCTAssertEqual(run.handle(on("home"), now: at(22)), .wait(at(27)))
        XCTAssertEqual(run.handle(.timer, now: at(27)), .nothing)
        XCTAssertEqual(run.handle([.connected(false)], now: at(30)), .nothing)
        XCTAssertEqual(run.handle([.connected(true)], now: at(40)), .wait(at(45)))
        XCTAssertEqual(run.handle(.timer, now: at(45)), .nothing)
    }

    /// Picked by hand with no network (the Wi-Fi off), then another network an hour later: that network decides.
    func testAHandPickWithNoNetworkAndThenAnotherNetwork() {
        var run = pickedOnHome()
        _ = run.handle(.network(.offline), now: at(20))
        _ = run.handle(.pickedByHand, now: at(21))
        XCTAssertEqual(run.handle(on("cafe"), now: at(3600)), .wait(at(3605)))
        XCTAssertEqual(run.handle(.timer, now: at(3605)), .decide(mark: "cafe", acted: AutoSwitch.Acted(mark: "home", rules: run.rules)))
    }

    func testNothingIsDecidedWhileASwitchIsPending() {
        var run = Run(rules: rules, now: t0)
        XCTAssertEqual(run.handle([.connected(true), on("cafe"), .busy(true)], now: t0), .wait(at(5)))
        XCTAssertEqual(run.handle(.timer, now: at(5)), .nothing)
        XCTAssertNil(run.acted, "not decided: it is, once the switch settles")
        XCTAssertEqual(run.handle(.busy(false), now: at(30)), .decide(mark: "cafe", acted: nil))
        // Taken in together: connected and busy at once never decides on the half seen.
        var both = Run(rules: rules, now: t0)
        _ = both.handle(on("cafe"), now: t0)
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
