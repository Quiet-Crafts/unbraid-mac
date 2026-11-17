import XCTest

/// Switching by network, as the state machine's own principles say (`AutoSwitchRun`): named cases from every review
/// round, then properties over random event sequences. Times come from the continuous clock the tests hand in.
final class AutoSwitchRunTests: XCTestCase {
    private typealias Run = AutoSwitchRun
    private typealias Acted = AutoSwitch.Acted
    private let t0 = ContinuousClock.now
    private func at(_ s: Double) -> ContinuousClock.Instant { t0 + .seconds(s) }
    private let unrecognised = AutoSwitch.unrecognised
    private static let home = "en0|192.168.1.1", cafe = "en0|10.0.0.1", office = "en0|10.1.0.1"
    private func on(_ mark: String, _ place: String = home) -> Run.Event { .network(.mark(mark, place: place)) }
    private func pending(_ place: String = home) -> Run.Event { .network(.reading(place: place)) }
    private let offline = Run.Event.network(.offline)

    /// Home has routers a and b (rule Home), the office b and c (rule Work), the flat d (no rule); any other: Travel.
    private var rules: NetworkRules {
        var r = NetworkRules(salt: "salt")
        r.remember("a,b", name: "Home network", profile: "Home")
        r.remember("b,c", name: "Office", profile: "Work")
        r.remember("d", name: "Flat", profile: nil)
        r.elsewhere = "Travel"
        return r
    }
    private let names = ["Home", "Work", "Travel"]

    /// Connected at `place` with reading `mark` since t0, decided once at 5 s.
    private func settled(_ mark: String = "a,b", _ place: String = home) -> Run {
        var run = Run(rules: rules, now: t0)
        XCTAssertEqual(run.handle([.profiles(names), .connected(true), on(mark, place)], now: t0), .wait(at(5)))
        XCTAssertEqual(run.handle(.timer, now: at(5)), .decide(mark: rules.identity(mark), acted: nil))
        return run
    }

    /// Feeds `steps` (seconds, events), firing the timer whenever a wait falls due before the next step, as the watcher
    /// does; returns the networks decided on, and "back to N" for a way back.
    private func drive(_ run: inout Run, _ steps: [(Double, [Run.Event])], until end: Double) -> [String] {
        var out: [String] = [], due: ContinuousClock.Instant?
        func record(_ a: Run.Action) {
            if case .decide(let m, _) = a { out.append(m) }
            if case .restore(let m) = a { out.append("back to " + m) }
            if case .wait(let w) = a { due = w } else { due = nil }
        }
        for (t, events) in steps + [(end, [Run.Event.timer])] {
            while let w = due, w <= at(t) { due = nil; record(run.handle(.timer, now: w)) }
            record(run.handle(events, now: at(t)))
        }
        return out
    }

    // MARK: Settling, connecting, busy

    func testANetworkMustStayTheSameForTheSettleTime() {
        var run = Run(rules: rules, now: t0)
        XCTAssertEqual(run.handle(.connected(true), now: t0), .nothing, "no network yet")
        XCTAssertEqual(run.handle(on("a,b"), now: at(1)), .wait(at(6)))
        XCTAssertEqual(run.handle(.timer, now: at(2)), .wait(at(6)), "a timer early waits on")
        XCTAssertEqual(run.handle(on("a"), now: at(3)), .wait(at(8)), "a router away starts the settle time over")
        XCTAssertEqual(run.handle(.timer, now: at(8)), .decide(mark: "a,b", acted: nil))
        XCTAssertEqual(run.handle(.timer, now: at(20)), .nothing, "decided once")
        XCTAssertEqual(run.handle([.busy(true), .busy(false)], now: at(22)), .nothing)
    }

    func testOnlyWhileConnectedAndNotBusy() {
        var run = Run(rules: rules, now: t0)
        XCTAssertEqual(run.handle(on("x", Self.cafe), now: t0), .nothing, "not connected")
        XCTAssertEqual(run.handle(.connected(true), now: at(100)), .wait(at(105)))
        XCTAssertEqual(run.handle(.connected(false), now: at(102)), .nothing)
        XCTAssertEqual(run.handle(.connected(true), now: at(200)), .wait(at(205)))
        XCTAssertEqual(run.handle(.busy(true), now: at(201)), .wait(at(205)))
        XCTAssertEqual(run.handle(.timer, now: at(205)), .nothing)
        XCTAssertEqual(run.handle(.busy(false), now: at(230)), .decide(mark: "x", acted: nil))
        // Off and on again on the same network: decided already.
        _ = run.handle(.connected(false), now: at(300))
        XCTAssertEqual(run.handle(.connected(true), now: at(400)), .wait(at(405)))
        XCTAssertEqual(run.handle(.timer, now: at(405)), .nothing)
    }

    // MARK: Networks without a fingerprint (P-1, X-1, O-1)

    /// P-1: a network reached afresh with no acceptable reading gets the profile for any other network after 20 s.
    func testANetworkReachedAfreshWithoutAFingerprintIsUnrecognisedAfter20s() {
        var run = settled()
        XCTAssertEqual(drive(&run, [(100, [offline]), (300, [pending(Self.cafe)])], until: 400), [unrecognised])
        XCTAssertEqual(run.acted, Acted(mark: unrecognised, rules: rules))
        XCTAssertEqual(rules.profile(on: unrecognised), "Travel")
        // Offline decides nothing, however long.
        var off = settled()
        XCTAssertEqual(drive(&off, [(10, [offline])], until: 10_000), [])
    }

    /// X-1: another network reached the same way as home (same interface and IPv4 router address) with no fingerprint
    /// gets no longer wait than any other: unrecognised after 20 s.
    func testAnotherNetworkLookingLikeHomeIsUnrecognisedInTheEnd() {
        for gap: Double in [2, 60, 600, 28_800] {
            var run = settled()
            XCTAssertEqual(drive(&run, [(10, [offline]), (10 + gap, [pending()])], until: 10 + gap + 200), [unrecognised], "\(gap)")
            XCTAssertNil(run.here(at: at(10 + gap + 19)))
            XCTAssertEqual(run.here(at: at(10 + gap + 20)), unrecognised)
        }
    }

    /// O-1: networks without a fingerprint look alike; one is left by going offline while awake, another interface or
    /// router. A sleep, a moment offline or a reconnect there keep a hand pick.
    func testAHandPickOnAnUnrecognisedNetworkEndsWhenTheMacLeavesIt() {
        func there() -> Run {
            var run = Run(rules: rules, now: t0)
            XCTAssertEqual(drive(&run, [(0, [.profiles(names), .connected(true), pending(Self.cafe)])], until: 25), [unrecognised])
            _ = run.handle(.pickedByHand, now: at(30))
            return run
        }
        var stay = there()
        XCTAssertEqual(drive(&stay, [(40, [.connected(false)]), (42, [.connected(true)]), (50, [offline]), (53, [pending(Self.cafe)]),
                                     (100, [.sleep(true), offline]), (5000, [.sleep(false)]), (5002, [pending(Self.cafe)])], until: 5200), [])
        var away = there()
        XCTAssertEqual(drive(&away, [(40, [offline]), (100, [pending(Self.cafe)])], until: 200), [unrecognised], "offline while awake")
        var other = there()
        XCTAssertEqual(drive(&other, [(40, [pending("en0|10.9.9.1")])], until: 200), [unrecognised], "another router")
        var cable = there()
        XCTAssertEqual(drive(&cable, [(40, [pending("en5|10.0.0.1")])], until: 200), [unrecognised], "another interface")
    }

    /// Taken for unrecognised, then its own routers answer for no remembered network: the same network still, so a hand
    /// pick made meanwhile stays; a remembered network answering is real news.
    func testALateFingerprintOfTheSameNetwork() {
        var run = Run(rules: rules, now: t0)
        XCTAssertEqual(drive(&run, [(0, [.profiles(names), .connected(true), pending(Self.cafe)])], until: 25), [unrecognised])
        _ = run.handle(.pickedByHand, now: at(30))
        XCTAssertEqual(drive(&run, [(40, [on("x", Self.cafe)])], until: 100), [])
        var late = Run(rules: rules, now: t0)
        XCTAssertEqual(drive(&late, [(0, [.profiles(names), .connected(true), pending()]), (40, [on("a,b")])], until: 100), [unrecognised, "a,b"])
    }

    // MARK: Late routers, sleep and wakes (T2-1, X-4, T3-1)

    /// T2-1, X-4, T3-1: at home, the Mac offline for a moment or asleep for hours, the routers answering at any of the
    /// watcher's read times. Within the one wait (20 s) nothing switches; later, the Mac counts as somewhere
    /// unrecognised, then goes back to exactly what was in use at home, the hand pick included: one switch away and
    /// one back at worst.
    func testAWakeAtHomeSwitchesAtMostAwayAndBackAndKeepsAHandPick() {
        for gap: Double in [1, 30, 119, 600, 28_800] {
            for answer: Double in [0.5, 3, 10, 19, 21, 25, 30, 45, 60, 75, 90, 105, 115, 300] {
                // After more than a moment, the reading must name home on its own: b alone fits the office too.
                for heard in gap <= 10 ? ["a", "b", "a,b"] : ["a", "a,b"] {
                    for sleeps in [false, true] {
                        var run = settled()
                        _ = run.handle(.pickedByHand, now: at(50))
                        let picked = run.acted
                        let start = 100 + gap
                        let got = drive(&run, [(100, sleeps ? [.sleep(true), offline] : [offline]), (start, sleeps ? [.sleep(false), pending()] : [pending()]),
                                               (start + answer, [on(heard)])], until: start + 400)
                        XCTAssertEqual(got, answer < 20 ? [] : [unrecognised, "back to a,b"], "offline \(gap) s, router \(heard) after \(answer) s")
                        XCTAssertEqual(run.acted, picked)
                    }
                }
            }
        }
        // The eight-hour sleep with the router at 30 s, as the test lane drives it (timers at 10, 20, 25 s).
        var night = settled()
        _ = night.handle(offline, now: at(100))
        var actions = [night.handle(pending(), now: at(100 + 8 * 3600))]
        for t in [10.0, 20, 25] { actions.append(night.handle(.timer, now: at(100 + 8 * 3600 + t))) }
        actions.append(night.handle(on("a,b"), now: at(100 + 8 * 3600 + 30)))
        actions.append(night.handle(.timer, now: at(100 + 8 * 3600 + 35)))
        XCTAssertEqual(actions.filter { if case .wait = $0 { false } else { $0 != .nothing } },
                       [.decide(mark: unrecognised, acted: Acted(mark: "a,b", rules: rules)), .restore(mark: "a,b")])
        // A tunnel reconnect with a reread in between, and a roam with no offline at all.
        var re = settled()
        XCTAssertEqual(drive(&re, [(100, [.connected(false)]), (100.5, [pending()]), (103, [.connected(true)]), (104, [on("b")])], until: 300), [])
        var roam = settled()
        XCTAssertEqual(drive(&roam, [(100, [pending()]), (110, [on("a")])], until: 300), [])
    }

    /// The way back counts only with nothing identified in between, and not over a hand pick made while away; a
    /// rule changed meanwhile applies as a decision.
    func testTheWayBackOnlyFromAShortExcursion() {
        // Home, then a café the Mac recognises: a real stay elsewhere, so home decides afresh.
        var cafe = settled()
        XCTAssertEqual(drive(&cafe, [(10, [offline]), (20, [on("x", Self.cafe)]), (60, [offline]), (100, [on("a,b")])], until: 200), ["x", "a,b"])
        // Home, then somewhere unrecognised (another place), then home: back.
        var away = settled()
        XCTAssertEqual(drive(&away, [(10, [offline]), (20, [pending(Self.cafe)]), (60, [offline]), (100, [on("a,b")])], until: 200),
                       [unrecognised, "back to a,b"])
        // A hand pick while away: the user's choice, home decides afresh.
        var picked = settled()
        XCTAssertEqual(drive(&picked, [(10, [offline]), (20, [pending(Self.cafe)]), (45, [.pickedByHand]), (60, [offline]), (100, [on("a,b")])], until: 200),
                       [unrecognised, "a,b"])
        // Home's rule changed while away: the new rule, as a decision.
        var changed = settled()
        var r = rules
        r.known[0].profile = "Work"
        XCTAssertEqual(drive(&changed, [(10, [offline]), (20, [pending(Self.cafe)]), (50, [.rules(r)]), (60, [offline]), (100, [on("a,b")])], until: 200),
                       [unrecognised, "a,b"])
        // Another network at home's place that never answers: the same 20 s as anywhere.
        var other = settled()
        XCTAssertEqual(drive(&other, [(10, [offline]), (400, [pending()])], until: 419), [])
        XCTAssertEqual(drive(&other, [(421, [.timer])], until: 430), [unrecognised])
    }

    // MARK: Routers shared by two remembered networks (R-3, R-4, X-2, T3-2)

    /// R-4, R-3: on the office, its own router away for a while: still the office, and a switch pending meanwhile is
    /// still for the same network. T3-2: arriving there, the shared router alone at the settle moment.
    func testASharedRouterKeepsTheNetworkItWasReadAs() {
        var run = settled("b,c", Self.office)
        _ = run.handle(.pickedByHand, now: at(10))
        XCTAssertEqual(drive(&run, [(20, [on("b", Self.office)]), (40, [on("b,c", Self.office)]), (60, [on("b", Self.office)])], until: 200), [])
        XCTAssertEqual(run.here(at: at(200)), "b,c")
        var arriving = Run(rules: rules, now: t0)
        XCTAssertEqual(drive(&arriving, [(0, [.profiles(names), .connected(true), pending(Self.office)]), (3, [on("b,c", Self.office)]),
                                         (4, [on("b", Self.office)]), (20, [on("b,c", Self.office)])], until: 100), ["b,c"])
        // Reached afresh with only the shared router: neither network, whichever was remembered first.
        var fresh = Run(rules: rules, now: t0)
        XCTAssertEqual(drive(&fresh, [(0, [.profiles(names), .connected(true), on("b", Self.office)])], until: 100), ["b"])
        XCTAssertEqual(rules.profile(on: "b"), "Travel")
    }

    /// X-2: after leaving home, a network reached another way whose only router is the shared one is neither home nor
    /// the office. Back at home's place after more than a moment, it takes a fresh reading that names home on its own:
    /// the shared router alone is in doubt, so any other network; home's own router keeps home.
    func testAPreferenceNeverOutlivesLeavingTheNetwork() {
        var run = settled()
        XCTAssertEqual(drive(&run, [(10, [offline]), (200, [on("b", "en0|192.168.50.1")])], until: 300), ["b"])
        var cable = settled()
        XCTAssertEqual(drive(&cable, [(10, [on("b", "en5|192.168.1.1")])], until: 300), ["b"], "another interface")
        var back = settled()
        XCTAssertEqual(drive(&back, [(10, [offline]), (200, [on("b")])], until: 300), ["b"])
        var own = settled()
        XCTAssertEqual(drive(&own, [(10, [offline]), (200, [on("a")]), (220, [on("b")])], until: 300), [])
        // A router not known yet never bridges two different ones: home's address, nothing, then another address.
        var bridge = settled()
        XCTAssertEqual(drive(&bridge, [(10, [pending("en0|")]), (12, [pending("en0|10.9.9.1")])], until: 100), [unrecognised])
    }

    // MARK: Switches the app couldn't make (X-3)

    /// X-3: the switch asked for wasn't made (a reconnect, a reread meanwhile): owed again once things settle; not over
    /// a hand pick made since.
    func testASwitchNotMadeIsOwedAgain() {
        var run = settled()
        XCTAssertEqual(run.handle(.unapplied(run.generation), now: at(7)), .wait(at(12)))
        XCTAssertEqual(run.handle(.timer, now: at(12)), .decide(mark: "a,b", acted: nil))
        // Not made while disconnected: owed once connected again.
        _ = run.handle(.connected(false), now: at(20))
        _ = run.handle(.unapplied(run.generation), now: at(21))
        XCTAssertEqual(drive(&run, [(30, [.connected(true)])], until: 100), ["a,b"])
        // A hand pick since, even one that happens to name the same network and profile: the report is stale.
        let decided = run.generation
        _ = run.handle(.pickedByHand, now: at(101))
        let picked = run.acted
        XCTAssertEqual(drive(&run, [(104, [.unapplied(decided)])], until: 200), [])
        XCTAssertEqual(run.acted, picked)
        // A report about an older decision after a newer one: ignored.
        XCTAssertEqual(drive(&run, [(210, [on("b,c", Self.office)]), (230, [.unapplied(decided)])], until: 300), ["b,c"])
    }

    // MARK: Hand picks and rules (P-2, P-5, R-5, T-3, T-4)

    func testAHandPickStaysUntilTheNetworkOrItsRuleChanges() {
        var run = settled()
        _ = run.handle(.pickedByHand, now: at(10))
        var r = rules
        r.elsewhere = nil
        r.known[1].profile = "Home"
        XCTAssertEqual(drive(&run, [(20, [.rules(r)])], until: 40), [], "rules for other networks")
        r.renamed("Home", to: "House")
        XCTAssertEqual(drive(&run, [(50, [.profiles(["House", "Work", "Travel"]), .rules(r)])], until: 70), [], "a rename")
        // A rename while the network reads nothing, or the Mac is offline for a moment, follows the pick too (R-5).
        r.renamed("House", to: "Casa")
        XCTAssertEqual(drive(&run, [(80, [pending()]), (81, [.profiles(["Casa", "Work", "Travel"]), .rules(r)]), (84, [on("a,b")])], until: 100), [])
        r.renamed("Casa", to: "Haus")
        XCTAssertEqual(drive(&run, [(110, [offline]), (111, [.profiles(["Haus", "Work", "Travel"]), .rules(r)]), (113, [on("a,b")])], until: 130), [])
        // A new profile for this network applies, over the pick (P-2).
        r.known[0].profile = "Travel"
        XCTAssertEqual(drive(&run, [(140, [.rules(r)])], until: 160), ["a,b"])
        // Another network decides again.
        XCTAssertEqual(drive(&run, [(170, [on("b,c", Self.office)])], until: 200), ["b,c"])
    }

    /// P-5, T-4: a pick made offline has no network: the next one decides. A pick made while the network is still read
    /// counts for what the reading gives, even when nothing looked at it on time.
    func testAHandPickWithoutANetwork() {
        var run = settled()
        _ = run.handle(offline, now: at(20))
        _ = run.handle(.pickedByHand, now: at(21))
        XCTAssertEqual(drive(&run, [(3600, [on("x", Self.cafe)])], until: 3700), ["x"])
        var reading = settled()
        XCTAssertEqual(drive(&reading, [(10, [offline]), (20, [pending(Self.cafe)]), (21, [.pickedByHand]), (25, [on("b,c", Self.cafe)])], until: 100), [])
        var late = settled()
        _ = late.handle(.connected(false), now: at(8))
        _ = late.handle([offline], now: at(10))
        _ = late.handle([pending(Self.cafe)], now: at(20))
        _ = late.handle(.pickedByHand, now: at(21))
        XCTAssertEqual(drive(&late, [(500, [.connected(true)])], until: 600), [])
        XCTAssertEqual(late.acted, Acted(mark: unrecognised, rules: rules))
        // A rules change drops a pick still waiting for its network.
        var dropped = settled()
        var r = rules
        r.elsewhere = "Work"
        XCTAssertEqual(drive(&dropped, [(10, [offline]), (20, [pending(Self.cafe)]), (21, [.pickedByHand]), (22, [.rules(r)]), (25, [on("x", Self.cafe)])], until: 100), ["x"])
    }

    // MARK: Properties over random sequences

    private struct Rng { var s: UInt64; mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] } }

    /// Whatever happens: a decision only while connected, not busy and on the network it names; never twice for the same
    /// network and profile unless reported not made; nothing waits for ever; and which network was remembered first
    /// never changes a decision.
    func testRandomSequencesKeepThePrinciples() {
        var g = Rng(s: 0x5eed)
        var reversed = rules
        reversed.known.reverse()
        let readings: [Run.Event] = [offline, pending(), pending(Self.cafe), pending(Self.office), on("a,b"), on("a"), on("b"), on("b,c", Self.office),
                                     on("b", Self.office), on("c", Self.office), on("x", Self.cafe), on("d", "en5|"), pending("en5|")]
        for seq in 0..<2000 {
            var run = Run(rules: rules, now: t0), mirror = Run(rules: reversed, now: t0)
            var now = 0.0, due: ContinuousClock.Instant?, last: Acted?, log: [String] = []
            func feed(_ events: [Run.Event], _ t: ContinuousClock.Instant) {
                let a = run.handle(events, now: t), b = mirror.handle(events, now: t)
                log.append("\((t - t0).components.seconds): \(events) -> \(a) acted \(String(describing: run.acted?.mark))")
                XCTAssertEqual(a, b, "seq \(seq): the order networks were remembered in changed a decision")
                // A report of a switch not made, a hand pick or an arrival makes a decision owed again.
                if events.contains(where: { $0 == .pickedByHand || { if case .unapplied = $0 { true } else { false } }($0) }) || run.acted == nil { last = nil }
                if case .restore(let m) = a {
                    XCTAssertTrue(run.connected && !run.busy && run.here(at: t) == m, "seq \(seq): went back while it may not")
                    last = run.acted
                }
                if case .decide(let m, _) = a {
                    XCTAssertTrue(run.connected && !run.busy && run.here(at: t) == m, "seq \(seq): decided while it may not")
                    let d = Acted(mark: m, rules: run.rules)
                    XCTAssertNotEqual(d, last, "seq \(seq): decided twice on \(m)\n" + log.joined(separator: "\n"))
                    last = d
                }
                if case .wait(let w) = a { due = w } else { due = nil }
            }
            for _ in 0..<(1 + g.int(30)) {
                now += g.pick([0.2, 1, 3, 5, 9, 15, 30, 90, 4000])
                while let w = due, w <= at(now) { due = nil; feed([.timer], w) }
                var events: [Run.Event] = []
                switch g.int(10) {
                case 0...4: events.append(g.pick(readings))
                case 5: events.append(.connected(g.int(4) > 0))
                case 6: events.append(.busy(g.int(3) == 0))
                case 7: events.append(.pickedByHand)
                case 8: events.append(.sleep(g.int(2) == 0))
                default: events.append(.unapplied(g.int(3) == 0 ? run.generation - 1 : run.generation))
                }
                feed(events, at(now))
            }
            // Quiet, connected, not busy: whatever waits ends, and then nothing more is asked for.
            feed([.connected(true), .busy(false)], at(now + 0.1))
            var n = 0
            while let w = due, n < 10 { due = nil; feed([.timer], w); n += 1 }
            XCTAssertNil(due, "seq \(seq): still waiting")
            if run.reading != .offline { XCTAssertNotNil(run.here(at: at(now + 1000))) }
        }
    }

    /// Staying on one network: its routers coming and going within what it holds, moments offline, sleeps of any length,
    /// reconnects and rereads never switch except away and back (a reading later than the one wait), and a hand pick
    /// stays.
    func testRandomStaysOnOneNetworkKeepTheHandPick() {
        var g = Rng(s: 0xb0b)
        for seq in 0..<1500 {
            var run = settled()
            _ = run.handle(.pickedByHand, now: at(6))
            var now = 10.0, steps: [(Double, [Run.Event])] = []
            for _ in 0..<(1 + g.int(25)) {
                switch g.int(6) {
                case 0: steps.append((now, [on(g.pick(["a", "b", "a,b"]))]))
                case 1: // A moment offline, or a sleep of any length; then a reread answered within the read times.
                    let sleeps = g.int(2) == 0, gap = sleeps ? g.pick([30.0, 600, 30_000]) : g.pick([0.5, 3, 9])
                    steps.append((now, sleeps ? [.sleep(true), offline] : [offline])); now += gap
                    steps.append((now, sleeps ? [.sleep(false), pending()] : [pending()])); now += g.pick([0.5, 10, 21, 45, 75, 105])
                    // After more than a moment the first reading must name home on its own (b alone fits the office).
                    steps.append((now, [on(g.pick(sleeps ? ["a", "a,b"] : ["a", "b", "a,b"]))]))
                case 2: steps.append((now, [.connected(false)])); now += 2; steps.append((now, [.connected(true)]))
                case 3: steps.append((now, [pending()])); now += g.pick([1.0, 30, 70, 110]); steps.append((now, [on("a,b")]))
                case 4: steps.append((now, [.busy(true)])); now += 3; steps.append((now, [.busy(false)]))
                default: steps.append((now, [.timer]))
                }
                now += g.pick([1.0, 6, 40])
            }
            // At worst away and back, in pairs, each time a reading took longer than the one wait.
            let got = drive(&run, steps, until: now + 200)
            XCTAssertEqual(got, Array(repeating: [unrecognised, "back to a,b"], count: got.count / 2).flatMap { $0 }, "seq \(seq)")
            XCTAssertEqual(run.acted, Acted(mark: "a,b", rules: rules), "seq \(seq)")
        }
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
