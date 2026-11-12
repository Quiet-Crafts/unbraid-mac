import XCTest

final class SnapshotTests: XCTestCase {
    func testConfirmedProtectionUsesAppliedRoutesAndBlockedRoutes() {
        let nl = Route(id: "nl", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands"))
        let direct = Setup(routes: [nl], defaultRoute: DIRECT, apps: [:])
        XCTAssertTrue(direct.allAppsUseDefault)
        XCTAssertTrue(Setup(routes: [nl], defaultRoute: DIRECT, apps: ["app": DIRECT]).allAppsUseDefault)
        XCTAssertFalse(Setup(routes: [nl], defaultRoute: DIRECT, apps: ["app": "nl"]).allAppsUseDefault)
        XCTAssertFalse(Setup(routes: [nl], defaultRoute: DIRECT, apps: ["app": BLOCK]).allAppsUseDefault)
        let vpn = Setup(routes: [nl], defaultRoute: DIRECT, apps: ["app": "nl"])
        var state = RunState()
        XCTAssertNil(state.protection(blocked: []))
        state.committed(revision: "direct", setup: direct, fresh: true)
        XCTAssertEqual(state.protection(blocked: []), false)
        state.refused(revision: "vpn", setup: vpn)
        XCTAssertEqual(state.protection(blocked: []), false)
        state.committed(revision: "vpn", setup: vpn, fresh: true)
        XCTAssertEqual(state.protection(blocked: []), true)
        XCTAssertEqual(state.protection(blocked: ["nl"]), false)
        let us = Route(id: "us", loc: Location(countryId: 228, countryCode: "US", country: "United States"))
        let mixed = Setup(routes: [nl, us], defaultRoute: "nl", apps: ["app": "us", "blocked": BLOCK])
        state.committed(revision: "mixed", setup: mixed, fresh: true)
        XCTAssertEqual(state.protection(blocked: ["nl"]), true)
        XCTAssertEqual(state.protection(blocked: ["nl", "us"]), false)
        state.deniedAll()
        XCTAssertNil(state.protection(blocked: []))
        state.pausedBlocking()
        XCTAssertNil(state.protection(blocked: []))
        state.fallback()
        XCTAssertNil(state.protection(blocked: []))
        state.foreign()
        XCTAssertNil(state.protection(blocked: []))
    }

    func testSnapshotStatusAndOldFormat() throws {
        let old = try JSONDecoder().decode(Snapshot.self, from: Data(#"{"phase":"on","exits":1,"routes":[],"direct":0,"blocked":0,"week":[],"updated":0}"#.utf8))
        XCTAssertNil(old.protected)
        XCTAssertEqual(old.connectionTitle, "Connected")
        XCTAssertEqual(Snapshot(phase: .on, protected: true).connectionTitle, "Protected")
        XCTAssertEqual(Snapshot(phase: .on, protected: false).connectionTitle, "Connected")
        XCTAssertEqual(Snapshot(phase: .paused, protected: true).connectionTitle, "Paused")
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(Snapshot(phase: .on, protected: true))).protected, true)
    }

    func testOldSnapshotDecodesWithoutCountry() throws {
        let data = Data(#"{"phase":"off","exits":1,"routes":[{"id":"ss","name":"Own Server","code":"SS","hue":0,"apps":1,"isDefault":true}],"direct":0,"blocked":0,"week":[],"updated":0}"#.utf8)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        XCTAssertEqual(snapshot.routes.first?.code, "SS")
        XCTAssertNil(snapshot.routes.first?.country)
        XCTAssertNil(countryFlag(snapshot.routes.first?.country))
    }

    func testSnapshotCountryRoundTrip() throws {
        let route = Snapshot.Route(id: "nl", name: "Netherlands", code: "NL", hue: 0, apps: 1, isDefault: true, country: "NL")
        let snapshot = Snapshot(routes: [route])
        let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(countryFlag(decoded.routes.first?.country), "🇳🇱")
    }

    func testCountryFlagsRequireISOCountryCodes() {
        XCTAssertEqual(countryFlag("nl"), "🇳🇱")
        XCTAssertEqual(countryFlag("SS"), "🇸🇸")
        for code in [nil, "", "ZZ", "WG", "1A", "NLD", "éé", "ß", "ſs", "ＵＳ"] as [String?] {
            XCTAssertNil(countryFlag(code), "\(code ?? "nil") must not produce a flag")
        }
    }

    // MARK: What the widgets show

    private let nl = Route(id: "nl", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands"))
    private let us = Route(id: "us", loc: Location(countryId: 228, countryCode: "US", country: "United States"), hue: 1)

    private func make(_ phase: Snapshot.Phase, failed: Bool = false, edited: Setup, running: Setup?) -> Snapshot {
        Snapshot.make(phase: phase, since: nil, pausedUntil: nil, failed: failed, edited: edited, running: running, exits: 1, week: [])
    }

    func testConnectedShowsWhatTheTunnelRunsNotARefusedEdit() {
        // Running: Direct by default, one app on NL. The edit (refused by the engine) moved the default to a new US route.
        var running = Setup(routes: [nl], defaultRoute: DIRECT, apps: ["a": "nl", "b": DIRECT])
        running.favorites = []
        var edited = running
        edited.routes.append(us)
        edited.defaultRoute = "us"
        edited.apps["c"] = "us"
        let s = make(.on, failed: true, edited: edited, running: running)
        XCTAssertEqual(s.routes.map(\.id), ["nl"])
        XCTAssertEqual(s.routes.first?.isDefault, false)
        XCTAssertEqual(s.routes.first?.apps, 1)
        XCTAssertEqual(s.direct, 1)
        XCTAssertEqual(s.defaultRoute, DIRECT, "Direct is the default the tunnel runs")
        XCTAssertEqual(s.failed, true)
        // Once applied, the same edit shows.
        let applied = make(.on, edited: edited, running: edited)
        XCTAssertEqual(applied.routes.filter(\.isDefault).map(\.id), ["us"])
        XCTAssertNil(applied.defaultRoute)
        XCTAssertNil(applied.failed)
    }

    func testOffPausedAndConnectingShowTheEditedSetup() {
        let running = Setup(routes: [nl], defaultRoute: "nl")
        let edited = Setup(routes: [nl, us], defaultRoute: "us")
        for phase in [Snapshot.Phase.off, .paused, .connecting] {
            XCTAssertEqual(make(phase, edited: edited, running: running).routes.filter(\.isDefault).map(\.id), ["us"], "\(phase)")
        }
        // Connected with nothing committed yet: the edited setup.
        XCTAssertEqual(make(.on, edited: edited, running: nil).routes.filter(\.isDefault).map(\.id), ["us"])
    }

    func testFailureIsAFlagNotTheErrorText() throws {
        let s = make(.off, failed: true, edited: Setup(routes: [nl], defaultRoute: "nl"), running: nil)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(s), encoding: .utf8))
        XCTAssertTrue(json.contains(#""failed":true"#))
        // Older snapshots have neither field.
        let old = try JSONDecoder().decode(Snapshot.self, from: Data(#"{"phase":"on","exits":1,"routes":[],"direct":0,"blocked":0,"week":[],"updated":0}"#.utf8))
        XCTAssertNil(old.failed)
        XCTAssertNil(old.defaultRoute)
    }

    // MARK: Timeline

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testTimelineTurnsStaleWhenTheAppStopsVouching() {
        let s = Snapshot(phase: .on, updated: t0)
        let now = t0.addingTimeInterval(74 * 60)
        let entries = s.timeline(now: now)
        XCTAssertEqual(entries.map(\.date), [now, t0.addingTimeInterval(75 * 60)])
        XCTAssertTrue(entries[0].snapshot.fresh(at: entries[0].date))
        XCTAssertFalse(entries[1].snapshot.fresh(at: entries[1].date))
        // Already stale: one entry, rendered stale.
        let late = s.timeline(now: t0.addingTimeInterval(76 * 60))
        XCTAssertEqual(late.count, 1)
        XCTAssertFalse(late[0].snapshot.fresh(at: late[0].date))
        // After a quit the snapshot is marked stale: no future entry.
        XCTAssertEqual(Snapshot(phase: .on).timeline(now: t0).count, 1)
    }

    func testPauseEndsAsConnectingOnlyWhileTheAppVouches() {
        var s = Snapshot(phase: .paused, pausedUntil: t0.addingTimeInterval(15 * 60), updated: t0)
        s.failed = true
        let entries = s.timeline(now: t0.addingTimeInterval(60))
        XCTAssertEqual(entries.map(\.date), [t0.addingTimeInterval(60), t0.addingTimeInterval(15 * 60), t0.addingTimeInterval(75 * 60)])
        XCTAssertEqual(entries.map(\.snapshot.phase), [.paused, .connecting, .connecting])
        XCTAssertNil(entries[1].snapshot.failed)
        // A pause that ends after the app stopped vouching (it quit): nothing resumes it, so no "Connecting".
        let long = Snapshot(phase: .paused, pausedUntil: t0.addingTimeInterval(90 * 60), updated: t0)
        XCTAssertEqual(long.timeline(now: t0).map(\.snapshot.phase), [.paused, .paused])
        XCTAssertEqual(long.timeline(now: t0).map(\.date), [t0, t0.addingTimeInterval(75 * 60)])
        // A pause ending exactly when the app stops vouching doesn't turn into "Connecting".
        let edge = Snapshot(phase: .paused, pausedUntil: t0.addingTimeInterval(Snapshot.trusted), updated: t0)
        XCTAssertEqual(edge.timeline(now: t0).map(\.snapshot.phase), [.paused, .paused])
        // Only a pause resumes; a deadline already passed adds nothing.
        XCTAssertEqual(Snapshot(phase: .on, pausedUntil: t0.addingTimeInterval(60), updated: t0).timeline(now: t0).count, 2)
        XCTAssertEqual(Snapshot(phase: .paused, pausedUntil: t0, updated: t0).timeline(now: t0.addingTimeInterval(60)).map(\.snapshot.phase), [.paused, .paused])
    }

    // MARK: Writing and reloading

    func testRewriteAfterStaleSnapshotReloadsEvenWithSameContent() {
        let s = Snapshot(phase: .off, routes: [Snapshot.Route(id: "nl", name: "Netherlands", code: "NL", hue: 0, apps: 1, isDefault: true)])
        var old = s
        old.updated = t0
        // The widgets were reloaded with the snapshot written at t0.
        func change(_ new: Snapshot, _ minutes: Double) -> (Bool, Bool) {
            let c = new.change(from: old, now: t0.addingTimeInterval(minutes * 60), lastReload: t0)
            return (c.write, c.reload)
        }
        // Same content, fresh: nothing to do; after 15 minutes a quiet rewrite, no reload.
        XCTAssertFalse(change(s, 1).0)
        XCTAssertTrue(change(s, 16) == (true, false))
        // The first heartbeat (a little over half an hour) leaves time for the next one to reload.
        XCTAssertTrue(change(s, 30.1) == (true, false))
        // From 35 minutes the next heartbeat could come too late: rewrite and reload, content unchanged or not.
        XCTAssertTrue(change(s, 35) == (true, true))
        XCTAssertTrue(s.change(from: old, now: t0.addingTimeInterval(35 * 60 - 1), lastReload: t0) == (true, false))
        old.updated = t0.addingTimeInterval(34 * 60)
        XCTAssertTrue(change(s, 35) == (true, true))
        // Same content but the widgets stopped vouching (quit, then relaunched): rewrite and reload.
        old.updated = t0
        XCTAssertTrue(s.change(from: old, now: t0.addingTimeInterval(76 * 60), lastReload: t0.addingTimeInterval(76 * 60)) == (true, true))
        old.updated = .distantPast
        XCTAssertTrue(s.change(from: old, now: t0, lastReload: t0) == (true, true))
        // A launch has never reloaded them: the first write does.
        old.updated = t0
        XCTAssertTrue(s.change(from: old, now: t0.addingTimeInterval(16 * 60), lastReload: .distantPast) == (true, true))
        // Only the week's totals changed: written, no reload.
        var weekly = s
        weekly.week = [Snapshot.Day(date: t0, bytes: ["nl": 1])]
        var withWeek = s
        withWeek.week = [Snapshot.Day(date: t0, bytes: ["nl": 2])]
        withWeek.updated = t0
        XCTAssertTrue(weekly.change(from: withWeek, now: t0.addingTimeInterval(60), lastReload: t0) == (true, false))
    }

    func testWidgetsReadAgainWhenTheyStopVouchingThenHourly() {
        XCTAssertEqual(Snapshot(updated: t0).nextRead(now: t0.addingTimeInterval(60)), t0.addingTimeInterval(Snapshot.trusted))
        XCTAssertEqual(Snapshot(updated: t0).nextRead(now: t0.addingTimeInterval(Snapshot.trusted - 1)), t0.addingTimeInterval(Snapshot.trusted))
        XCTAssertEqual(Snapshot(updated: t0).nextRead(now: t0.addingTimeInterval(Snapshot.trusted)), t0.addingTimeInterval(Snapshot.trusted + 3600))
        XCTAssertEqual(Snapshot().nextRead(now: t0), t0.addingTimeInterval(3600))
    }

    // MARK: A running app against the widgets' reloads

    /// The publishing loop and WidgetKit, simulated: the app writes at launch, on every heartbeat (each a little late,
    /// as the loop's coalescing and the totals' query make it) and on visible changes; the widgets read the snapshot
    /// when the app asks (`delay` later) and, if `ownReads`, when their timeline policy says. Returns, for every 30 s
    /// step, whether the widget's current entry still vouches for the app, while it runs and after it stops at `stop`.
    private func simulate(changeAt: [TimeInterval], late: TimeInterval, delay: TimeInterval, ownReads: Bool,
                          hours: Double = 8, stop: TimeInterval? = nil) -> [(t: TimeInterval, live: Bool)] {
        var stored = Snapshot()
        var lastReload = Date.distantPast
        var pendingReads: [TimeInterval] = []
        var timeline: [(date: Date, snapshot: Snapshot)] = []
        var ownRead: TimeInterval?
        var on = Snapshot(phase: .on, since: t0)
        func date(_ t: TimeInterval) -> Date { t0.addingTimeInterval(t) }
        func publish(_ t: TimeInterval) {
            let c = on.change(from: stored, now: date(t), lastReload: lastReload)
            guard c.write else { return }
            stored = on
            stored.updated = date(t)
            if c.reload { lastReload = date(t); pendingReads.append(t + delay) }
        }
        func read(_ t: TimeInterval) {
            timeline = stored.timeline(now: date(t))
            ownRead = ownReads ? stored.nextRead(now: date(t)).timeIntervalSince(t0) : nil
        }
        // App events in time order: launch, heartbeats, visible changes.
        var appEvents: [(TimeInterval, Bool)] = [(0, false)] // (time, visible change)
        var beat: TimeInterval = 0
        while beat < hours * 3600 { beat += Snapshot.heartbeat + late; appEvents.append((beat, false)) }
        appEvents += changeAt.map { ($0, true) }
        appEvents.sort { $0.0 < $1.0 }
        var next = 0
        var out: [(TimeInterval, Bool)] = []
        // Every entry of the installed timeline that becomes current before `end`, checked at its own date: a stale
        // entry shown for half a second between two samples counts.
        var checked: TimeInterval = -1
        func entries(before end: TimeInterval) {
            for e in timeline where e.date.timeIntervalSince(t0) > checked && e.date.timeIntervalSince(t0) < end {
                out.append((e.date.timeIntervalSince(t0), e.snapshot.fresh(at: e.date)))
            }
            checked = max(checked, end - 0.001)
        }
        var t: TimeInterval = 0
        while t <= hours * 3600 {
            // Everything due by t, in order: the app's writes and the widgets' reads.
            while true {
                let app = next < appEvents.count && (stop.map { appEvents[next].0 < $0 } ?? true) ? appEvents[next].0 : .infinity
                let asked = pendingReads.min() ?? .infinity
                let own = ownRead ?? .infinity
                let first = min(app, asked, own)
                guard first <= t else { break }
                entries(before: first)
                if first == app {
                    if appEvents[next].1 { on.since = date(app) } // a reconnect: something the widget shows
                    publish(app)
                    next += 1
                } else if first == asked {
                    pendingReads.remove(at: pendingReads.firstIndex(of: asked)!)
                    read(asked)
                } else { read(own) }
            }
            entries(before: t)
            if let entry = timeline.last(where: { $0.date <= date(t) }) { out.append((t, entry.snapshot.fresh(at: entry.date))) }
            t += 30
        }
        return out
    }

    func testARunningAppNeverLooksStaleWhateverThePhaseOfItsChangesAndTheWidgetsReads() {
        // A heartbeat runs 0.5 s (coalescing) plus the totals' query after its time; WidgetKit runs a reload at once or
        // minutes later. Together within the margin, nothing is ever stale.
        for late in [0.5, 1.5, 61, 4 * 60] as [TimeInterval] {
            for delay in [0, 60, 5 * 60, 8.5 * 60] as [TimeInterval] where late + delay < Snapshot.margin {
                for ownReads in [false, true] {
                    // A visible change at every minute of a heartbeat's period, and none at all.
                    for minute in [nil] + Array(0..<30) {
                        var changes: [TimeInterval] = []
                        if let m = minute { changes = [60 + Double(m) * 60, 3 * 3600 + Double(m) * 60 + 17.3] }
                        let run = simulate(changeAt: changes, late: late, delay: delay, ownReads: ownReads)
                        // Once the first read has landed, every moment vouches.
                        let stale = run.filter { $0.t >= delay + 30 && !$0.live }
                        XCTAssertTrue(stale.isEmpty, "late \(late) s, delay \(delay) s, own reads \(ownReads), change at minute \(String(describing: minute)): stale at \(stale.prefix(3).map { $0.t / 60 }) min")
                    }
                }
            }
        }
    }

    func testIdleTheAppReloadsTheWidgetsEverySecondHeartbeat() {
        var stored = Snapshot()
        var lastReload = Date.distantPast
        let on = Snapshot(phase: .on, since: t0)
        var reloads = 0
        var beat: TimeInterval = 0
        for _ in 0..<48 { // a day
            let now = t0.addingTimeInterval(beat)
            let c = on.change(from: stored, now: now, lastReload: lastReload)
            if c.write { stored = on; stored.updated = now }
            if c.reload { lastReload = now; reloads += 1 }
            beat += Snapshot.heartbeat + 0.5
        }
        XCTAssertEqual(reloads, 24)
    }

    func testAStoppedAppShowsWithinTrustedWhetherOrNotTheWidgetsReadOnTheirOwn() {
        for stop in stride(from: 3600.0, to: 3 * 3600, by: 7 * 60) {
            for ownReads in [false, true] {
                let run = simulate(changeAt: [], late: 0.5, delay: 60, ownReads: ownReads, stop: stop)
                XCTAssertTrue(run.filter { $0.t >= stop + Snapshot.trusted }.allSatisfy { !$0.live }, "stopped at \(stop / 60) min")
            }
        }
    }

    /// The clock set back two hours after a write leaves the snapshot dated in the future: it isn't vouched for (the
    /// widgets offer "Open unbraid"), the app's next write replaces it and reloads them, and the widgets read hourly.
    func testASnapshotDatedAfterNowIsNotTrusted() {
        let later = t0.addingTimeInterval(2 * 3600)
        let s = Snapshot(phase: .on, updated: later)
        XCTAssertFalse(s.fresh(at: t0))
        XCTAssertFalse(s.fresh(at: later.addingTimeInterval(-61)))
        XCTAssertTrue(s.fresh(at: later.addingTimeInterval(-30))) // a moment's difference still counts as now
        XCTAssertTrue(s.fresh(at: later))
        XCTAssertEqual(s.nextRead(now: t0), t0.addingTimeInterval(3600))
        XCTAssertTrue(s.change(from: s, now: t0, lastReload: later) == (true, true))
        // Unchanged otherwise: the same content a minute after it was written needs nothing.
        XCTAssertTrue(s.change(from: s, now: later.addingTimeInterval(60), lastReload: later) == (false, false))
    }

    /// A snapshot that says "connected" and was just written is what the widget placeholder draws.
    func testAFreshConnectedSnapshotIsLive() {
        XCTAssertTrue(Snapshot(phase: .on, exits: 3, updated: t0).fresh(at: t0))
        XCTAssertFalse(Snapshot(phase: .on, exits: 3).fresh(at: t0))
    }

    // MARK: Units

    /// Byte figures read the same as a number-and-unit pair and as one string, and halves round up.
    func testUnitsByteFigures() {
        XCTAssertTrue(Units.byteParts(1_234_000_000) == ("1.2", "GB"))
        XCTAssertTrue(Units.byteParts(2_500_000) == ("3", "MB"))
        XCTAssertTrue(Units.byteParts(999_700_000) == ("1.0", "GB"), "999.7 MB reads 1.0 GB everywhere, never 1000 MB")
        XCTAssertEqual(Units.bytes(3_912_345_678), "3.9 GB")
        XCTAssertTrue(Units.rateParts(48_300_000) == ("48.3", "Mbps"))
        XCTAssertEqual(Units.rate(999_700), "1.0 Mbps")
    }

    /// One speed-test formatter: Gbps from 1000 Mbps for every reading, Mbps below.
    func testUnitsSpeedSwitchesToGbpsFromAThousandMbps() {
        XCTAssertTrue(Units.speed(1_250_000_000) == ("1.25", "Gbps"))
        XCTAssertTrue(Units.speed(940_000_000) == ("940", "Mbps"))
        XCTAssertTrue(Units.speed(48_300_000) == ("48.3", "Mbps"))
    }

    /// The usage chart's axis: as many decimals as the step needs, one unit for the whole axis, nothing repeated.
    func testUnitsAxisLabelsNeverRepeat() {
        func labels(step: Double, ticks: Int) -> [String] {
            (0...ticks).map { Units.axisBytes(step * Double($0), step: step, ceiling: step * Double(ticks)) }
        }
        XCTAssertEqual(labels(step: 500_000, ticks: 4), ["0", "0.5 MB", "1.0 MB", "1.5 MB", "2.0 MB"])
        XCTAssertEqual(labels(step: 2_500_000, ticks: 4), ["0", "2.5 MB", "5.0 MB", "7.5 MB", "10.0 MB"])
        XCTAssertEqual(labels(step: 5_000_000, ticks: 3), ["0", "5 MB", "10 MB", "15 MB"])
        XCTAssertEqual(labels(step: 500_000_000, ticks: 4), ["0", "0.5 GB", "1.0 GB", "1.5 GB", "2.0 GB"])
        XCTAssertEqual(labels(step: 25, ticks: 4), ["0", "25 B", "50 B", "75 B", "100 B"])
    }
}
