import XCTest
import SQLite3

final class StatsMathTests: XCTestCase {
    func testBestDownloadIgnoresGroupedResults() {
        let single = TestResult(at: 1, exit: "nl", via: "", server: "server", ip: "", down: 10, up: 0, idle: 0)
        let total = TestResult(at: 2, exit: "all", via: "", server: "", ip: "", down: 100, up: 0, idle: 0, grp: 2, n: 2)
        let leg = TestResult(at: 3, exit: "de", via: "", server: "server", ip: "", down: 50, up: 0, idle: 0, grp: 2, n: 2)
        XCTAssertEqual(StatsMath.bestSingleTest([total, leg, single]), single)
        XCTAssertNil(StatsMath.bestSingleTest([total, leg]))
    }
    private let ams = TimeZone(identifier: "Europe/Amsterdam")!
    private let utc = TimeZone(identifier: "UTC")!
    private let la = TimeZone(identifier: "America/Los_Angeles")!

    /// Milliseconds of a UTC moment.
    private func ms(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Int64 {
        (StatsMath.epochDay(y, mo, d) * 86_400 + Int64(h * 3600 + mi * 60)) * 1000
    }

    // MARK: Calendar

    func testDayAndHourFollowTheLocalClock() {
        // 22:30 UTC on 30 June is 00:30 on 1 July in Amsterdam (summer time) and 15:30 on 30 June in Los Angeles.
        let t = ms(2026, 6, 30, 22, 30)
        XCTAssertEqual(StatsMath.dayOf(t, tz: utc), StatsMath.epochDay(2026, 6, 30))
        XCTAssertEqual(StatsMath.dayOf(t, tz: ams), StatsMath.epochDay(2026, 7, 1))
        XCTAssertEqual(StatsMath.dayOf(t, tz: la), StatsMath.epochDay(2026, 6, 30))
        XCTAssertEqual(StatsMath.hourOf(t, tz: ams) % 24, 0)
        XCTAssertEqual(StatsMath.hourOf(t, tz: la) % 24, 15)
        // Winter time is one hour behind summer time.
        XCTAssertEqual(StatsMath.hourOf(ms(2026, 1, 15, 12), tz: ams) % 24, 13)
    }

    func testCivilDatesRoundTrip() {
        XCTAssertEqual(StatsMath.civil(0).y, 1970)
        XCTAssertEqual(StatsMath.civil(0).m, 1)
        XCTAssertEqual(StatsMath.civil(0).d, 1)
        for d in stride(from: Int64(-800), through: 30_000, by: 37) {
            let c = StatsMath.civil(d)
            XCTAssertEqual(StatsMath.epochDay(c.y, c.m, c.d), d)
        }
        let leap = StatsMath.civil(StatsMath.epochDay(2024, 2, 29))
        XCTAssertEqual([leap.y, leap.m, leap.d], [2024, 2, 29])
        XCTAssertEqual([2024, 2026].map { StatsMath.monthLength($0, 2) }, [29, 28])
        XCTAssertEqual(StatsMath.monthLength(2026, 12), 31)
        XCTAssertEqual(StatsMath.monthLength(2026, 4), 30)
    }

    func testWeeksStartOnMonday() {
        XCTAssertEqual(StatsMath.weekday(0), 3) // 1 January 1970 was a Thursday
        XCTAssertEqual(StatsMath.weekday(StatsMath.epochDay(2026, 10, 20)), 1) // Tuesday
        XCTAssertEqual(StatsMath.weekday(StatsMath.epochDay(2026, 10, 25)), 6) // Sunday
        XCTAssertEqual(StatsMath.weekday(StatsMath.epochDay(1969, 12, 29)), 0) // Monday before the epoch
    }

    func testPeriodRanges() {
        let today = StatsMath.epochDay(2026, 10, 20)
        XCTAssertTrue(Period.day.range(today: today) == (today, today))
        XCTAssertTrue(Period.week.range(today: today) == (StatsMath.epochDay(2026, 10, 19), StatsMath.epochDay(2026, 10, 25)))
        XCTAssertTrue(Period.month.range(today: today) == (StatsMath.epochDay(2026, 10, 1), StatsMath.epochDay(2026, 10, 31)))
        XCTAssertTrue(Period.month.range(today: StatsMath.epochDay(2024, 2, 10)) == (StatsMath.epochDay(2024, 2, 1), StatsMath.epochDay(2024, 2, 29)))
        // A Monday is its own week's first day, a Sunday its last.
        XCTAssertEqual(Period.week.range(today: StatsMath.epochDay(2026, 10, 19)).from, StatsMath.epochDay(2026, 10, 19))
        XCTAssertEqual(Period.week.range(today: StatsMath.epochDay(2026, 10, 25)).to, StatsMath.epochDay(2026, 10, 25))
        XCTAssertEqual(Period.allCases.map(\.label), ["Day", "Week", "Month"])
    }

    func testDaysOnDaylightSavingNightsAreNot24Hours() {
        let spring = StatsMath.epochDay(2026, 3, 29), autumn = StatsMath.epochDay(2026, 10, 25)
        func hours(_ d: Int64) -> Int64 { (StatsMath.dayStartMs(d + 1, tz: ams) - StatsMath.dayStartMs(d, tz: ams)) / StatsMath.hour }
        XCTAssertEqual(hours(spring), 23)
        XCTAssertEqual(hours(autumn), 25)
        XCTAssertEqual(hours(spring - 1), 24)
        XCTAssertEqual(StatsMath.dayStartMs(StatsMath.epochDay(2026, 7, 1), tz: ams), ms(2026, 6, 30, 22))
    }

    // MARK: Formatting

    func testByteFormatting() {
        XCTAssertTrue(StatsMath.bytes(1_234_000_000) == ("1.2", "GB"))
        XCTAssertTrue(StatsMath.bytes(1_000_000_000) == ("1.0", "GB"))
        XCTAssertTrue(StatsMath.bytes(340_400_000) == ("340", "MB"))
        XCTAssertTrue(StatsMath.bytes(2_500_000) == ("3", "MB")) // halves round up, as the Android app's
        XCTAssertTrue(StatsMath.bytes(12_345) == ("12", "kB"))
        XCTAssertTrue(StatsMath.bytes(0) == ("0", "kB"))
        XCTAssertEqual(StatsMath.bytesText(5_000_000_000), "5.0 GB")
    }

    func testSpeedFormatting() {
        XCTAssertTrue(StatsMath.rate(48_300_000) == ("48.3", "Mbps"))
        XCTAssertTrue(StatsMath.rate(140_000_000) == ("140", "Mbps"))
        XCTAssertTrue(StatsMath.rate(1_000_000) == ("1.0", "Mbps"))
        XCTAssertTrue(StatsMath.rate(640_000) == ("640", "kbps"))
        XCTAssertTrue(StatsMath.rate(100) == ("0.1", "kbps")) // small transfers don't read as zero
        XCTAssertTrue(StatsMath.rate(99) == ("0", "kbps"))
        XCTAssertEqual(StatsMath.mbps(99_950_000), "100.0")
        XCTAssertEqual(StatsMath.mbps(100_000_000), "100")
    }

    /// Shared/Units (screens and widgets): every figure as it was, except one that would round to 1000 (or 100.0
    /// Mbps), which moves up. Run under more than one locale: the decimal mark is a point whatever the region.
    func testSharedUnitsFormatting() {
        let bytes: [(Int64, String)] = [
            (0, "0 kB"), (499, "0 kB"), (12_345, "12 kB"), (999_499, "999 kB"), (999_500, "1 MB"), (999_999, "1 MB"),
            (1_000_000, "1 MB"), (2_500_000, "3 MB"), (340_400_000, "340 MB"), (999_499_999, "999 MB"),
            (999_500_000, "1.0 GB"), (999_999_999, "1.0 GB"), (1_000_000_000, "1.0 GB"), (1_234_000_000, "1.2 GB"),
            (5_000_000_000, "5.0 GB"),
        ]
        for (b, text) in bytes { XCTAssertEqual(Units.bytes(b), text, "\(b) bytes") }
        let rates: [(Double, String)] = [
            (0, "0 kbps"), (99, "0 kbps"), (100, "0 kbps"), (640_000, "640 kbps"), (999_499, "999 kbps"),
            (999_500, "1.0 Mbps"), (999_999, "1.0 Mbps"), (1_000_000, "1.0 Mbps"), (48_300_000, "48.3 Mbps"),
            (99_940_000, "99.9 Mbps"), (99_950_000, "100 Mbps"), (99_990_000, "100 Mbps"), (100_000_000, "100 Mbps"),
            (140_700_000, "140 Mbps"), (2_500_000_000, "2500 Mbps"),
        ]
        for (bps, text) in rates { XCTAssertEqual(Units.rate(bps), text, "\(bps) bps") }
        XCTAssertEqual(Units.mbps(98_300_000), "98.3")
        XCTAssertEqual(Units.mbps(99_990_000), "100")
    }

    func testDurations() {
        XCTAssertEqual(StatsMath.hm(45 * 60_000), "45 m")
        XCTAssertEqual(StatsMath.hm(200 * 60_000), "3 h 20 m")
        XCTAssertEqual(StatsMath.hm(59_999), "0 m")
        XCTAssertEqual(StatsMath.hmParts(200 * 60_000).map { $0.0 + $0.1 }, ["3h", "20m"])
        XCTAssertEqual(StatsMath.hmParts(5 * 60_000).map { $0.0 + $0.1 }, ["5m"])
    }

    func testRangeLabels() {
        let en = Locale(identifier: "en_US")
        let today = StatsMath.epochDay(2026, 10, 20)
        XCTAssertEqual(StatsMath.rangeLabel(.day, today: today, tz: utc, locale: en), "TODAY · 20 OCT")
        XCTAssertEqual(StatsMath.rangeLabel(.week, today: today, tz: utc, locale: en), "19–25 OCT")
        XCTAssertEqual(StatsMath.rangeLabel(.month, today: today, tz: utc, locale: en), "1–31 OCT")
        // A week across two months names both; across a year too.
        XCTAssertEqual(StatsMath.rangeLabel(.week, today: StatsMath.epochDay(2026, 10, 29), tz: utc, locale: en), "26 OCT – 1 NOV")
        XCTAssertEqual(StatsMath.rangeLabel(.week, today: StatsMath.epochDay(2026, 12, 30), tz: utc, locale: en), "28 DEC – 3 JAN")
        XCTAssertEqual(StatsMath.dayNames(en), ["M", "T", "W", "T", "F", "S", "S"])
    }

    // MARK: Attribution

    func testExitFollowsTheTunnelTagAndTheAppsRoute() {
        var s = Setup()
        s.routes = [Route(id: "nl"), Route(id: "se"), Route(id: "ts1", tsExit: "100.64.0.9")]
        s.defaultRoute = "nl"
        s.apps = ["com.foo": "se"]
        // Two routes sharing one tunnel: the app's own route says which.
        let tags = ["nl": "r-shared", "se": "r-shared", "ts1": "home-ts"]
        XCTAssertEqual(StatsMath.exitOf(tag: "r-shared", app: "com.foo", setup: s, tags: tags), "se")
        XCTAssertEqual(StatsMath.exitOf(tag: "r-shared", app: "com.other", setup: s, tags: tags), "nl")
        s.apps["com.bar"] = "ts1"
        XCTAssertEqual(StatsMath.exitOf(tag: "r-shared", app: "com.bar", setup: s, tags: tags), "nl") // not among the candidates
        XCTAssertEqual(StatsMath.exitOf(tag: "home-ts", app: "com.bar", setup: s, tags: tags), "ts1")
        XCTAssertEqual(StatsMath.exitOf(tag: "home-ts", app: "x", setup: s, tags: tags), "home") // another route's app reaching Tailscale
        XCTAssertEqual(StatsMath.exitOf(tag: "home-ts", app: "x", setup: s, tags: [:]), "home")
        XCTAssertEqual(StatsMath.exitOf(tag: "home-wg", app: "x", setup: s, tags: tags), "home")
        XCTAssertEqual(StatsMath.exitOf(tag: "direct", app: "x", setup: s, tags: tags), DIRECT)
        XCTAssertEqual(StatsMath.exitOf(tag: nil, app: "x", setup: s, tags: tags), DIRECT)
        XCTAssertEqual(StatsMath.exitOf(tag: "r-gone", app: "x", setup: s, tags: tags), "gone") // a route removed since
    }

    func testProcessesBelongToTheAppWhoseBundleHoldsThem() {
        let bundles = [("/Applications/Safari.app", "com.apple.Safari"),
                       ("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app", "com.apple.Safari"),
                       ("/Applications/Foo.app", "com.foo"), ("/Applications/Foo.app/Contents/Frameworks/Bar.app", "com.foo.bar")]
        let tools: Set = ["/usr/local/bin/mytool"]
        func key(_ p: String) -> String? { StatsMath.appKey(path: p, bundles: bundles.map { (prefix: $0.0, id: $0.1) }, tools: tools) }
        XCTAssertEqual(key("/Applications/Foo.app/Contents/MacOS/Foo"), "com.foo")
        XCTAssertEqual(key("/Applications/Foo.app/Contents/Frameworks/Bar.app/Contents/MacOS/Bar"), "com.foo.bar") // longest match
        XCTAssertEqual(key("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"), "com.apple.Safari")
        XCTAssertEqual(key("/Applications/Foo.application/x"), nil) // a prefix of the name is not a parent folder
        XCTAssertEqual(key("/usr/local/bin/mytool"), "/usr/local/bin/mytool")
        XCTAssertNil(key("/usr/bin/curl"))
        XCTAssertNil(key(""))
        XCTAssertEqual(StatsMath.outerApp("/Users/me/Downloads/Baz.app/Contents/Helpers/H.app/Contents/MacOS/H"), "/Users/me/Downloads/Baz.app")
        XCTAssertEqual(StatsMath.outerApp("/Applications/Baz.app"), "/Applications/Baz.app")
        XCTAssertNil(StatsMath.outerApp("/usr/bin/curl"))
    }

    // MARK: Sums

    func testSumsRollUpPerHourDayAppAndExit() {
        let t = ms(2026, 10, 20, 10, 15)
        var p = Pending()
        p.add(now: t, app: "a", exit: "nl", server: "nl#1", up: 10, down: 100, tz: utc)
        p.add(now: t + 60_000, app: "a", exit: "nl", server: "nl#1", up: 5, down: 50, tz: utc)
        p.add(now: t + 120_000, app: "b", exit: "nl", server: nil, up: 1, down: 2, tz: utc)
        p.add(now: t + 3_600_000, app: "a", exit: "se", server: "se#4", up: 7, down: 0, tz: utc)
        p.add(now: t, app: "a", exit: "nl", server: "x", up: 0, down: 0, tz: utc) // nothing moved: nothing kept
        p.add(now: t, app: "a", exit: "nl", server: "x", up: -3, down: -1, tz: utc)
        let day = StatsMath.dayOf(t, tz: utc), hour = StatsMath.hourOf(t, tz: utc)
        XCTAssertEqual(p.hourly[Pending.HourKey(h: hour, exit: "nl")], Pending.Sum(up: 16, down: 152))
        XCTAssertEqual(p.hourly[Pending.HourKey(h: hour + 1, exit: "se")], Pending.Sum(up: 7, down: 0))
        XCTAssertEqual(p.daily[Pending.DayKey(d: day, app: "a", exit: "nl")], Pending.Sum(up: 15, down: 150))
        XCTAssertEqual(p.daily[Pending.DayKey(d: day, app: "b", exit: "nl")], Pending.Sum(up: 1, down: 2))
        XCTAssertEqual(p.servers[Pending.ServerKey(d: day, exit: "nl", name: "nl#1")], 165)
        XCTAssertEqual(p.servers[Pending.ServerKey(d: day, exit: "se", name: "se#4")], 7)
        XCTAssertEqual(p.servers.count, 2)
        XCTAssertEqual(p.exits, ["nl", "se"])
        p.clear()
        XCTAssertTrue(p.isEmpty)
    }

    // MARK: Exit labels

    func testAnExitKeepsTheLabelCapturedWhenItsTrafficWasCounted() throws {
        let old = Route(id: "r1", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands"), hue: 2)
        var renamed = old
        renamed.loc.country = "Holland"
        let with = Setup(routes: [old], defaultRoute: "r1"), without = Setup(routes: [], defaultRoute: DIRECT)
        let id = StatsMath.idOf(old)
        // Counted while the route existed; removed from both setups before the flush: the captured label stands.
        let captured = try XCTUnwrap(StatsMath.capturedLabel(id, setup: with, tsNames: [:]))
        XCTAssertEqual(captured.name, "Netherlands")
        XCTAssertEqual(captured.hue, 2)
        XCTAssertEqual(StatsMath.exitLabel(id, setup: without, running: without, tsNames: [:], captured: captured), captured)
        // A rename in the edited setup wins over the running setup's old name.
        let newer = Setup(routes: [renamed], defaultRoute: "r1")
        XCTAssertEqual(StatsMath.exitLabel(id, setup: newer, running: with, tsNames: [:], captured: captured)?.name, "Holland")
        // Renamed, then removed while the old name still runs: the rename captured before is written...
        let capturedRename = try XCTUnwrap(StatsMath.capturedLabel(id, setup: newer, tsNames: [:]))
        XCTAssertEqual(StatsMath.exitLabel(id, setup: without, running: with, tsNames: [:], captured: capturedRename)?.name, "Holland")
        // ...and the next flush captures nothing (the route isn't in the edited setup) and keeps the stored rename.
        XCTAssertNil(StatsMath.capturedLabel(id, setup: without, tsNames: [:]))
        XCTAssertEqual(StatsMath.exitLabel(id, setup: without, running: with, tsNames: [:], captured: nil, stored: capturedRename)?.name, "Holland")
        // Nothing captured or stored: the running setup, then nothing.
        XCTAssertEqual(StatsMath.exitLabel(id, setup: without, running: with, tsNames: [:], captured: nil)?.name, "Netherlands")
        XCTAssertNil(StatsMath.exitLabel(id, setup: without, running: without, tsNames: [:], captured: nil))
        XCTAssertNil(StatsMath.exitLabel(DIRECT, setup: with, running: with, tsNames: [:], captured: nil))
        XCTAssertNil(StatsMath.capturedLabel(DIRECT, setup: with, tsNames: [:]))
    }

    func testTailscaleNodesKeepTheirNameAfterLeavingTheList() throws {
        let s = Setup(routes: [], defaultRoute: DIRECT)
        let id = StatsMath.tsNode + "100.64.0.7"
        let named = try XCTUnwrap(StatsMath.capturedLabel(id, setup: s, tsNames: [id: "homeserver"]))
        XCTAssertEqual(named.name, "homeserver")
        XCTAssertEqual(StatsMath.exitLabel(id, setup: s, running: s, tsNames: [:], captured: named)?.name, "homeserver")
        XCTAssertEqual(StatsMath.exitLabel(id, setup: s, running: s, tsNames: [:], captured: nil)?.name, "100.64.0.7")
        XCTAssertEqual(StatsMath.exitLabel(StatsMath.home, setup: s, running: s, tsNames: [:], captured: nil)?.name, "Home network")
    }

    func testTheHomeNetworkLabelFollowsTheSetupOverAStoredOne() throws {
        var s = Setup(routes: [], defaultRoute: DIRECT)
        s.home.wg = try WgConf.parse(CompilerTests.fritz, name: "Home")
        let stored = StoredExit(id: StatsMath.home, code: "HM", name: "Home network", hue: 3, via: "Tailscale")
        // Switched from Tailscale to a WireGuard home: the stored "Tailscale" is not read back.
        XCTAssertEqual(StatsMath.capturedLabel(StatsMath.home, setup: s, tsNames: [:])?.via, "WireGuard")
        XCTAssertEqual(StatsMath.exitLabel(StatsMath.home, setup: s, running: s, tsNames: [:], captured: nil, stored: stored)?.via, "WireGuard")
        XCTAssertEqual(StatsMath.exitLabel(StatsMath.home, setup: s, running: s, tsNames: [:], captured: stored, stored: stored)?.via, "WireGuard")
        // And back, and both.
        let wireGuard = StoredExit(id: StatsMath.home, code: "HM", name: "Home network", hue: 3, via: "WireGuard")
        var ts = Setup(routes: [], defaultRoute: DIRECT)
        ts.home.tailscale = true
        XCTAssertEqual(StatsMath.exitLabel(StatsMath.home, setup: ts, running: ts, tsNames: [:], captured: nil, stored: wireGuard)?.via, "Tailscale")
        ts.home.wg = s.home.wg
        XCTAssertEqual(StatsMath.exitLabel(StatsMath.home, setup: ts, running: ts, tsNames: [:], captured: nil, stored: wireGuard)?.via, "Tailscale & WireGuard")
        // Removed before its last traffic was written: the label it was counted under stands, then the stored one.
        let none = Setup(routes: [], defaultRoute: DIRECT)
        XCTAssertNil(StatsMath.capturedLabel(StatsMath.home, setup: none, tsNames: [:]))
        XCTAssertEqual(StatsMath.exitLabel(StatsMath.home, setup: none, running: none, tsNames: [:], captured: wireGuard, stored: stored)?.via, "WireGuard")
        XCTAssertEqual(StatsMath.exitLabel(StatsMath.home, setup: none, running: none, tsNames: [:], captured: nil, stored: wireGuard)?.via, "WireGuard")
        XCTAssertEqual(StatsMath.exitLabel(StatsMath.home, setup: none, running: none, tsNames: [:], captured: nil)?.name, "Home network")
        // A Tailscale exit node in use is not how home is reached: a WireGuard home stays WireGuard...
        var wgExit = s
        wgExit.routes.append(Route(id: "ts", tsExit: "homeserver", hue: 4)); wgExit.defaultRoute = "ts"
        XCTAssertTrue(wgExit.tailscale)
        XCTAssertEqual(StatsMath.capturedLabel(StatsMath.home, setup: wgExit, tsNames: [:])?.via, "WireGuard")
        XCTAssertEqual(StatsMath.exitLabel(StatsMath.home, setup: wgExit, running: wgExit, tsNames: [:], captured: nil, stored: stored)?.via, "WireGuard")
        // ...and a removed home keeps its last label while the exit node stays in use.
        var exitOnly = none
        exitOnly.routes = wgExit.routes; exitOnly.defaultRoute = "ts"
        XCTAssertTrue(exitOnly.tailscale)
        XCTAssertNil(StatsMath.capturedLabel(StatsMath.home, setup: exitOnly, tsNames: [:]))
        XCTAssertEqual(StatsMath.exitLabel(StatsMath.home, setup: exitOnly, running: exitOnly, tsNames: [:], captured: wireGuard, stored: stored)?.via, "WireGuard")
        XCTAssertEqual(StatsMath.exitLabel(StatsMath.home, setup: exitOnly, running: exitOnly, tsNames: [:], captured: nil, stored: wireGuard)?.via, "WireGuard")
    }

    func testPendingNamesEveryExitItWillWriteAndForgetsLabelsWhenCleared() {
        var p = Pending()
        p.add(now: 0, app: "a", exit: "r1", server: "s", up: 1, down: 1, tz: utc)
        p.labels["r1"] = StoredExit(id: "r1", code: "NL", name: "Netherlands", hue: 0, via: "NordVPN")
        XCTAssertEqual(p.exits, ["r1"])
        p.clear()
        XCTAssertTrue(p.labels.isEmpty)
        XCTAssertTrue(p.isEmpty)
    }

    // MARK: Reconciling events

    private func ev(_ kind: Ledger.Kind, _ id: String, total: (Int64, Int64)? = nil, delta: (Int64, Int64) = (0, 0), closed: Bool = false, created: Int64 = 0) -> Ledger.Ev {
        Ledger.Ev(kind: kind, id: id, total: total.map { Traffic(up: $0.0, down: $0.1) }, delta: Traffic(up: delta.0, down: delta.1),
                  path: "/Applications/Foo.app/x", tag: "r-nl", closed: closed, created: created, own: false)
    }
    private let open: (Ledger.Ev) -> Ledger.Conn = { _ in Ledger.Conn(app: "com.foo", exit: "nl", server: "nl#1") }
    private func sums(_ c: [Ledger.Counted]) -> [Int64] { [c.reduce(0) { $0 + $1.up }, c.reduce(0) { $0 + $1.down }] }

    func testAConnectionCountsOnceFromNewThroughUpdatesToClose() {
        var l = Ledger()
        var r = l.apply([ev(.new, "a", total: (100, 200))], reset: false, open: open)
        XCTAssertEqual(sums(r.counted), [100, 200])
        XCTAssertEqual(r.counted.first, Ledger.Counted(app: "com.foo", exit: "nl", server: "nl#1", up: 100, down: 200, kind: .new))
        XCTAssertFalse(r.batch)
        r = l.apply([ev(.update, "a", delta: (10, 20)), ev(.update, "a", delta: (1, 2))], reset: false, open: open)
        XCTAssertEqual(sums(r.counted), [11, 22])
        XCTAssertTrue(r.batch)
        r = l.apply([ev(.closed, "a", total: (150, 260), closed: true)], reset: false, open: open)
        XCTAssertEqual(sums(r.counted), [39, 38]) // 150 - 111 and 260 - 222: only what no update carried
        XCTAssertTrue(l.seen.isEmpty)
        XCTAssertTrue(l.done.contains("a"))
        r = l.apply([ev(.closed, "a", total: (150, 260), closed: true)], reset: false, open: open)
        XCTAssertTrue(r.counted.isEmpty) // a repeated close counts nothing
    }

    func testWhatWasOpenBeforeRecordingIsBaselinedNotCounted() {
        var l = Ledger()
        var r = l.apply([ev(.new, "old", total: (1000, 5000))], reset: true, open: open)
        XCTAssertTrue(r.counted.isEmpty)
        XCTAssertEqual(l.seen["old"]?.down, 5000)
        r = l.apply([ev(.update, "old", delta: (2, 3))], reset: false, open: open)
        XCTAssertEqual(sums(r.counted), [2, 3])
        r = l.apply([ev(.closed, "old", total: (1010, 5010), closed: true)], reset: false, open: open)
        XCTAssertEqual(sums(r.counted), [8, 7])
        // A replay that lists a closed, unknown connection counts none of it.
        r = l.apply([ev(.new, "gone", total: (9, 9), closed: true)], reset: true, open: open)
        XCTAssertTrue(r.counted.isEmpty)
        XCTAssertFalse(l.done.contains("gone"))
    }

    func testAReplayAddsOnlyWhatHappenedWhileNotListening() {
        var l = Ledger()
        _ = l.apply([ev(.new, "a", total: (100, 200))], reset: false, open: open)
        var r = l.apply([ev(.new, "a", total: (130, 260))], reset: true, open: open)
        XCTAssertEqual(sums(r.counted), [30, 60])
        XCTAssertEqual(l.seen["a"]?.up, 130)
        // A replay listing it closed finishes it; listing it again counts nothing.
        r = l.apply([ev(.new, "a", total: (140, 270), closed: true)], reset: true, open: open)
        XCTAssertEqual(sums(r.counted), [10, 10])
        XCTAssertNil(l.seen["a"])
        r = l.apply([ev(.new, "a", total: (140, 270), closed: true)], reset: true, open: open)
        XCTAssertTrue(r.counted.isEmpty)
    }

    func testAResubscriptionCountsConnectionsBornInTheGap() {
        var l = Ledger()
        l.countFrom = 5_000
        let r = l.apply([ev(.new, "gap", total: (10, 20), created: 6_000), ev(.new, "before", total: (7, 7), created: 4_000),
                         ev(.new, "gapClosed", total: (1, 2), closed: true, created: 5_000)], reset: true, open: open)
        XCTAssertEqual(r.counted.map(\.down), [20, 2])
        XCTAssertEqual(l.countFrom, .max) // the replay landed
    }

    func testAFullReplayDropsConnectionsTheEngineNoLongerHas() {
        var l = Ledger()
        _ = l.apply([ev(.new, "keep", total: (1, 1)), ev(.new, "lost", total: (1, 1))], reset: false, open: open)
        _ = l.apply([ev(.new, "keep", total: (2, 2))], reset: true, open: open)
        XCTAssertEqual(Set(l.seen.keys), ["keep"])
    }

    func testACloseWhoseNewWasDroppedStillCountsIfItBeganWhileListening() {
        var l = Ledger()
        l.startedAt = 10_000
        var r = l.apply([ev(.closed, "x", total: (40, 80), closed: true, created: 10_500)], reset: false, open: open)
        XCTAssertEqual(sums(r.counted), [40, 80])
        r = l.apply([ev(.closed, "y", total: (40, 80), closed: true, created: 9_000)], reset: false, open: open)
        XCTAssertTrue(r.counted.isEmpty) // began before we listened: its bytes were never ours
    }

    func testUpdatesForUnknownConnectionsAreIgnoredButMakeABatch() {
        var l = Ledger()
        let r = l.apply([ev(.update, "?", delta: (1, 1))], reset: false, open: open)
        XCTAssertTrue(r.counted.isEmpty)
        XCTAssertTrue(r.batch)
        XCTAssertTrue(l.apply([ev(.new, "n"), ev(.closed, "c")], reset: false, open: open).counted.isEmpty) // no totals, nothing to count
    }

    func testTheClosedMemoryIsBounded() {
        var d = Ledger.Recent()
        for i in 0..<5000 { d.add("c\(i)") }
        XCTAssertEqual(d.count, 4096)
        XCTAssertFalse(d.contains("c0"))
        XCTAssertFalse(d.contains("c903"))
        XCTAssertTrue(d.contains("c904"))
        XCTAssertTrue(d.contains("c4999"))
        d.add("c4999")
        XCTAssertEqual(d.count, 4096)
        for i in 5000..<20_000 { d.add("c\(i)") }
        XCTAssertEqual(d.count, 4096)
        XCTAssertTrue(d.contains("c19999") && !d.contains("c15903") && d.contains("c15904"))
    }

    // MARK: The live window

    func testALiveSampleIsOneSecondOfDownloadAndUpload() {
        var w = LiveWindow()
        w.update(exit: "nl", up: 125_000, down: 1_000_000) // 1 MB down and 125 kB up in one second
        w.update(exit: "se", up: 0, down: 250_000)
        w.close(exit: "nl", up: 0, down: 125_000) // bytes reported at a close are drawn
        let l = w.sample(prev: Live(), seconds: 1)
        XCTAssertEqual(l.down["nl"]?.last, 9_000_000)
        XCTAssertEqual(l.down["nl"]?.count, 60)
        XCTAssertEqual(l.down["se"]?.last, 2_000_000)
        XCTAssertEqual(l.downNow, 11_000_000)
        XCTAssertEqual(l.upNow, 1_000_000)
    }

    func testDirectIsDrawnApartFromTheExits() throws {
        var w = LiveWindow()
        w.update(exit: "nl", up: 0, down: 125_000)
        w.update(exit: DIRECT, up: 50_000, down: 250_000)
        w.close(exit: DIRECT, up: 0, down: 125_000)
        var l = w.sample(prev: Live(), seconds: 1)
        XCTAssertEqual(l.direct.count, 60)
        XCTAssertEqual(l.direct.last, 3_000_000)
        // The headline, upload and per-exit series stay about the exits.
        XCTAssertNil(l.down[DIRECT])
        XCTAssertEqual(l.downNow, 1_000_000)
        XCTAssertEqual(l.upNow, 0)
        // It scrolls like an exit's series, quiet seconds as zeros.
        l = w.sample(prev: l, seconds: 2)
        let d = l.direct
        XCTAssertEqual(d.count, 60)
        XCTAssertEqual(Array(d.suffix(3)), [3_000_000, 0, 0])
    }

    func testAProgramOutsideAnyAppIsCountedUnderItsOwnPath() {
        let bundles = [(prefix: "/Applications/Safari.app", id: "com.apple.Safari")]
        let ids = ["/Applications/Other.app": "com.example.other"]
        let key = { (path: String, tools: Set<String>) in StatsMath.ownerKey(path: path, bundles: bundles, tools: tools, home: "/Users/me") { ids[$0] } }
        XCTAssertEqual(key("/Applications/Safari.app/Contents/MacOS/Safari", []), "com.apple.Safari")
        XCTAssertEqual(key("/Applications/Other.app/Contents/MacOS/Other", []), "com.example.other")
        XCTAssertEqual(key("/usr/bin/ssh", []), "/usr/bin/ssh")
        XCTAssertEqual(key("/usr/bin/ssh", ["/usr/bin/ssh"]), "/usr/bin/ssh") // the same key once added as a tool
        XCTAssertEqual(key("/Applications/Broken.app/Contents/MacOS/Broken", []), "/Applications/Broken.app/Contents/MacOS/Broken")
        XCTAssertEqual(key("", []), "?")
    }

    func testAToolRecordedWithAndWithoutTheTildeIsOneRow() {
        let rows = [AppBytes(app: "~/bin/tool", exit: "r1", bytes: 5), AppBytes(app: "/Users/me/bin/tool", exit: "r1", bytes: 7),
                    AppBytes(app: "~/bin/tool", exit: DIRECT, bytes: 2), AppBytes(app: "com.example.app", exit: "r1", bytes: 1)]
        let merged = StatsMath.sameTools(rows, home: "/Users/me")
        XCTAssertEqual(Set(merged), [AppBytes(app: "/Users/me/bin/tool", exit: "r1", bytes: 12), AppBytes(app: "/Users/me/bin/tool", exit: DIRECT, bytes: 2),
                                     AppBytes(app: "com.example.app", exit: "r1", bytes: 1)])
        XCTAssertEqual(StatsMath.sameTools(rows, home: "/").count, 4) // no home folder to write out
    }

    func testAToolReachedThroughALinkIsCountedUnderItsKeyAcrossVersions() {
        let tool = "/opt/homebrew/bin/curl"
        let patterns = [tool: [Compiler.pattern(forPath: tool),
                               Compiler.pattern(forPath: "/opt/homebrew/Cellar/curl/8.11.0/bin/curl").replacingOccurrences(of: "8\\.11\\.0", with: "[^/]+")]]
        let key = { (path: String) in StatsMath.ownerKey(path: path, bundles: [], tools: [tool], toolPatterns: patterns) { _ in nil } }
        XCTAssertEqual(key("/opt/homebrew/Cellar/curl/8.11.0/bin/curl"), tool)
        XCTAssertEqual(key("/opt/homebrew/Cellar/curl/8.12.1/bin/curl"), tool) // after `brew upgrade`
        XCTAssertEqual(key("/opt/homebrew/Cellar/wget/1.0/bin/wget"), "/opt/homebrew/Cellar/wget/1.0/bin/wget") // another tool stays apart
    }

    func testProgramsInTheHomeFolderAreKeptWithATildeAndTemporaryOnesTogether() {
        let key = { (path: String) in StatsMath.ownerKey(path: path, bundles: [], tools: [], home: "/Users/me") { _ in nil } }
        XCTAssertEqual(key("/Users/me/Projects/x/bin/tool"), "~/Projects/x/bin/tool")
        XCTAssertEqual(key("/Users/meagain/bin/tool"), "/Users/meagain/bin/tool") // another folder that starts alike
        XCTAssertEqual(key("/private/var/folders/ab/cd/T/go-build123/b001/exe/main"), StatsMath.otherPrograms)
        XCTAssertEqual(key("/Users/me/Library/Caches/Vendor/1.2/helper"), StatsMath.otherPrograms)
        XCTAssertEqual(key("/Users/me/.npm/_npx/abc/node_modules/.bin/x"), StatsMath.otherPrograms)
        XCTAssertEqual(key("/tmp/x"), StatsMath.otherPrograms)
        XCTAssertEqual(key("/opt/homebrew/bin/jq"), "/opt/homebrew/bin/jq")
        // A tool the user added keeps its own key, wherever it lives.
        XCTAssertEqual(StatsMath.ownerKey(path: "/tmp/t", bundles: [], tools: ["/tmp/t"], home: "/Users/me") { _ in nil }, "/tmp/t")
    }

    func testAClosingOnlyExitIsDrawn() {
        var w = LiveWindow()
        w.close(exit: "own", up: 10, down: 500_000)
        let l = w.sample(prev: Live(), seconds: 1)
        XCTAssertEqual(l.down["own"]?.last, 4_000_000)
    }

    func testTheSeriesScrollsAndQuietSecondsAreFilledIn() throws {
        var w = LiveWindow()
        w.update(exit: "nl", up: 0, down: 125_000)
        var l = w.sample(prev: Live(), seconds: 1)
        w.update(exit: "nl", up: 0, down: 375_000)
        l = w.sample(prev: l, seconds: 3) // three seconds passed: the bytes spread over them
        let s = try XCTUnwrap(l.down["nl"])
        XCTAssertEqual(s.count, 60)
        XCTAssertEqual(Array(s.suffix(4)), [1_000_000, 1_000_000, 1_000_000, 1_000_000])
        XCTAssertEqual(s[56], 1_000_000) // the first sample, shifted three places
        XCTAssertEqual(s[55], 0)
        // An exit that went quiet keeps scrolling with zeros.
        l = w.sample(prev: l, seconds: 1)
        XCTAssertEqual(l.down["nl"]?.last, 0)
        XCTAssertEqual(l.downNow, 0)
        // A gap over a minute clears the series.
        w.update(exit: "nl", up: 0, down: 125_000 * 100)
        l = w.sample(prev: l, seconds: 100)
        XCTAssertEqual(l.down["nl"]?.count, 60)
        XCTAssertEqual(Set(l.down["nl"] ?? []), [1_000_000])
    }

    // MARK: The read model

    func testRetiredSeriesExpireOnlyAfterTheLastNonzeroSample() {
        var window = LiveWindow()
        window.update(exit: "retired", up: 0, down: 10)
        window.update(exit: "active", up: 0, down: 10)
        var live = window.sample(prev: Live(), seconds: 1)
        live = window.sample(prev: live, seconds: 59, active: ["active"])
        XCTAssertNotNil(live.down["retired"])
        live = window.sample(prev: live, seconds: 1, active: ["active"])
        XCTAssertNil(live.down["retired"])
        XCTAssertEqual(live.down["active"], Array(repeating: 0, count: 60))
        window.update(exit: "upload", up: 10, down: 0)
        live = window.sample(prev: live, seconds: 1)
        XCTAssertNotNil(live.down["upload"])
        XCTAssertEqual(live.upNow, 80)
    }

    func testAWeekIsBuiltFromTheStoredRows() throws {
        var setup = Setup()
        setup.routes = [Route(id: "nl", loc: Location(countryCode: "NL", country: "Netherlands"), hue: 5), Route(id: "wg1", wg: WgPeer(
            name: "Fritz", privateKey: "", address: [], publicKey: "", endpoint: "", allowedIps: []))]
        let now = Date(timeIntervalSince1970: Double(ms(2026, 10, 20, 9, 30)) / 1000) // Tuesday, 11:30 in Amsterdam
        let monday = StatsMath.epochDay(2026, 10, 19), tuesday = monday + 1
        let at = { (d: Int64, h: Int) in StatsMath.dayStartMs(d, tz: self.ams) + Int64(h) * StatsMath.hour }
        let source = StatsSource(
            exits: { ["old": StoredExit(id: "old", code: "SE", name: "Sweden", hue: 2, via: "Mullvad"), "ts:1.2.3.4": StoredExit(id: "ts:1.2.3.4", code: "TS", name: "nas", hue: -1, via: "Tailscale")] },
            perDay: { from, to in
                XCTAssertEqual(from, monday); XCTAssertEqual(to, monday + 6)
                return [monday: ["nl": Traffic(up: 10, down: 90), "old": Traffic(up: 1, down: 1)], tuesday: ["nl": Traffic(up: 5, down: 15), "wg1": Traffic(up: 0, down: 40)]]
            },
            perHour: { _ in XCTFail("a week has no hours"); return [:] },
            apps: { _, _ in [AppBytes(app: "com.foo", exit: "nl", bytes: 120), AppBytes(app: "com.bar", exit: "wg1", bytes: 40)] },
            peaks: { _, _ in [(monday, "nl", Peak(down: 100, downAt: 1, up: 5, upAt: 2)), (tuesday, "nl", Peak(down: 80, downAt: 3, up: 9, upAt: 4)), (tuesday, "wg1", Peak(down: 7, downAt: 5, up: 0, upAt: 0))] },
            tests: { [
                TestResult(at: at(tuesday, 8), exit: "nl", via: "Nord", server: "nl1", ip: "1.1.1.1", down: 300, up: 100, idle: 12),
                TestResult(at: at(monday, 8), exit: "nl", via: "Nord", server: "nl1", ip: "1.1.1.1", down: 500, up: 90, idle: 11),
                TestResult(at: at(monday - 1, 23), exit: "nl", via: "Nord", server: "nl1", ip: "1.1.1.1", down: 9999, up: 1, idle: 1), // Sunday before: out
            ] },
            spans: { a, b in
                XCTAssertEqual(a, StatsMath.dayStartMs(StatsMath.epochDay(2026, 7, 27), tz: self.ams)) // 13 weeks, Monday first
                XCTAssertEqual(b, StatsMath.dayStartMs(tuesday + 1, tz: self.ams))
                return [Span(start: at(monday, 8), end: at(monday, 12), paused: false), Span(start: at(monday, 12), end: at(monday, 13), paused: true),
                        Span(start: at(tuesday, 7), end: at(tuesday, 9), paused: false)]
            })
        let v = StatsMath.view(.week, now: now, tz: ams, locale: Locale(identifier: "en_US"), setup: setup, source: source)

        XCTAssertEqual(v.from, monday); XCTAssertEqual(v.to, monday + 6)
        XCTAssertEqual(v.total, Traffic(up: 16, down: 146))
        XCTAssertEqual(v.byExit.map(\.exit), ["nl", "wg1", "old"]) // largest first
        XCTAssertEqual(v.byExit.first?.bytes, Traffic(up: 15, down: 105))
        XCTAssertEqual(v.columns.count, 7)
        XCTAssertEqual(v.labels, ["M", "T", "W", "T", "F", "S", "S"])
        XCTAssertEqual(v.columns[1]["wg1"], Traffic(up: 0, down: 40))
        XCTAssertTrue(v.columns[6].isEmpty)
        XCTAssertEqual(v.selected, 1)
        XCTAssertEqual(v.apps.count, 2)
        XCTAssertEqual(v.peaks["nl"], Peak(down: 100, downAt: 1, up: 9, upAt: 4)) // each at its own best, from different days
        XCTAssertEqual(v.dailyPeaks[tuesday], ["nl": 80, "wg1": 7])
        XCTAssertEqual(v.tests["nl"]?.down, 500)
        XCTAssertEqual(v.fastestDown("nl"), 500) // speed-test result
        XCTAssertEqual(v.fastestDown("wg1"), 0)
        XCTAssertEqual(v.fastestDown("old"), 0)
        // Exits: a route as it is now, a removed one as it was, Direct, and the unknown.
        XCTAssertEqual(v.exits[StatsMath.idOf(setup.routes[0])], ExitInfo(id: StatsMath.idOf(setup.routes[0]), code: "NL", name: "Netherlands", via: "Nord", tone: .route(5)))
        XCTAssertEqual(v.exits[StatsMath.idOf(setup.routes[1])]?.code, "WG")
        XCTAssertEqual(v.exits[StatsMath.idOf(setup.routes[1])]?.via, "WireGuard")
        XCTAssertEqual(v.exits["old"], ExitInfo(id: "old", code: "SE", name: "Sweden (older data)", via: "Unknown (older data)", tone: .route(2)))
        XCTAssertEqual(v.exits["ts:1.2.3.4"]?.tone, .neutral)
        XCTAssertEqual(v.exits[DIRECT]?.name, "Direct")
        XCTAssertEqual(v.exits[DIRECT]?.tone, .direct)
        XCTAssertEqual(v.byProvider().map(\.name), ["Other", "Unknown (older data)"])
        XCTAssertEqual(v.byProvider().map(\.bytes), [160, 2])
        var directSource = source
        directSource.perDay = { _, _ in [monday: [DIRECT: Traffic(up: 3, down: 7)]] }
        let directView = StatsMath.view(.week, now: now, tz: ams, setup: Setup(routes: [], defaultRoute: DIRECT), source: directSource)
        XCTAssertEqual(directView.total, Traffic(up: 3, down: 7))
        XCTAssertEqual(directView.columns[0][DIRECT]?.total, 10)
        XCTAssertEqual(directView.byProvider().first?.name, "Direct, no VPN")
        XCTAssertEqual(directView.byProvider().first?.bytes, 10)
        var withDirect = v
        withDirect.byExit.append(ExitBytes(exit: DIRECT, bytes: Traffic(up: 3, down: 7)))
        XCTAssertEqual(withDirect.byProvider().first { $0.name == "Direct, no VPN" }?.bytes, 10)
        withDirect.apps = (1...7).reversed().map { AppBytes(app: "app\($0)", exit: "nl", bytes: Int64($0)) }
            + [AppBytes(app: "other", exit: "wg1", bytes: 100)]
        let lane = withDirect.appLane("nl")
        XCTAssertEqual(lane.top.map(\.app), ["app7", "app6", "app5", "app4", "app3"])
        XCTAssertEqual(lane.rest.map(\.bytes).reduce(0, +), 3)
        XCTAssertEqual(withDirect.appLane("wg1").top.map(\.app), ["other"])
        XCTAssertTrue(withDirect.appLane(DIRECT).top.isEmpty)

        // Journal: hours protected per day (paused time excluded), 13 weeks from a Monday, the future as -1.
        XCTAssertEqual(v.heatStart, StatsMath.epochDay(2026, 7, 27))
        XCTAssertEqual(v.heat.count, 91)
        XCTAssertEqual(v.heat[84], 4) // Monday
        XCTAssertEqual(v.heat[85], 2) // Tuesday
        XCTAssertEqual(v.heat[86], -1)
        XCTAssertEqual(v.heat[0], 0)
        XCTAssertEqual(v.week, [4, 2, -1, -1, -1, -1, -1])
        XCTAssertEqual(v.weekMs, 6 * StatsMath.hour)
    }

    func testADayHasTwentyFourHourBars() {
        let now = Date(timeIntervalSince1970: Double(ms(2026, 10, 20, 9, 30)) / 1000)
        let today = StatsMath.epochDay(2026, 10, 20)
        let source = StatsSource(exits: { [:] }, perDay: { _, _ in [today: ["nl": Traffic(up: 1, down: 2)]] },
                                 perHour: { day in XCTAssertEqual(day, today); return [11: ["nl": Traffic(up: 1, down: 2)]] },
                                 apps: { _, _ in [] }, peaks: { _, _ in [] }, tests: { [] }, spans: { _, _ in [] })
        let v = StatsMath.view(.day, now: now, tz: ams, setup: Setup(), source: source)
        XCTAssertEqual(v.columns.count, 24)
        XCTAssertEqual(v.columns[11]["nl"], Traffic(up: 1, down: 2))
        XCTAssertEqual(v.selected, 11) // the current local hour
        XCTAssertEqual(v.labels.filter { !$0.isEmpty }, ["00", "06", "12", "18"])
        XCTAssertEqual(v.weekMs, 0)
    }

    func testTheHomeRowShowsHowHomeIsReachedNowNotTheStoredLabel() throws {
        let now = Date(timeIntervalSince1970: Double(ms(2026, 10, 20, 9, 30)) / 1000)
        let stored = [StatsMath.home: StoredExit(id: StatsMath.home, code: "HM", name: "Home network", hue: 3, via: "Tailscale")]
        let source = StatsSource(exits: { stored }, perDay: { _, _ in [:] }, perHour: { _ in [:] }, apps: { _, _ in [] }, peaks: { _, _ in [] },
                                 tests: { [] }, spans: { _, _ in [] })
        var s = Setup()
        s.home.wg = try WgConf.parse(CompilerTests.fritz, name: "Home")
        XCTAssertEqual(StatsMath.view(.week, now: now, tz: utc, setup: s, source: source).exits[StatsMath.home]?.via, "WireGuard")
        // Home removed: the stored label stands.
        XCTAssertEqual(StatsMath.view(.week, now: now, tz: utc, setup: Setup(), source: source).exits[StatsMath.home]?.via, "Tailscale")
        // A Tailscale exit node in use doesn't make the WireGuard home "Tailscale & WireGuard", nor override a removed
        // home's stored label.
        let exitNode = Route(id: "ts", tsExit: "homeserver", hue: 4)
        s.routes.append(exitNode); s.defaultRoute = "ts"
        XCTAssertEqual(StatsMath.view(.week, now: now, tz: utc, setup: s, source: source).exits[StatsMath.home]?.via, "WireGuard")
        var exitOnly = Setup()
        exitOnly.routes.append(exitNode); exitOnly.defaultRoute = "ts"
        XCTAssertEqual(StatsMath.view(.week, now: now, tz: utc, setup: exitOnly, source: source).exits[StatsMath.home]?.via, "Tailscale")
        let wgStored = [StatsMath.home: StoredExit(id: StatsMath.home, code: "HM", name: "Home network", hue: 3, via: "WireGuard")]
        let wgSource = StatsSource(exits: { wgStored }, perDay: { _, _ in [:] }, perHour: { _ in [:] }, apps: { _, _ in [] }, peaks: { _, _ in [] },
                                   tests: { [] }, spans: { _, _ in [] })
        XCTAssertEqual(StatsMath.view(.week, now: now, tz: utc, setup: exitOnly, source: wgSource).exits[StatsMath.home]?.via, "WireGuard")
    }

    func testAMonthLabelsEverySeventhDay() {
        let now = Date(timeIntervalSince1970: Double(ms(2026, 10, 20, 9, 30)) / 1000)
        let source = StatsSource(exits: { [:] }, perDay: { _, _ in [:] }, perHour: { _ in [:] }, apps: { _, _ in [] }, peaks: { _, _ in [] },
                                 tests: { [] }, spans: { _, _ in [] })
        let v = StatsMath.view(.month, now: now, tz: utc, setup: Setup(), source: source)
        XCTAssertEqual(v.columns.count, 31)
        XCTAssertEqual(v.labels.filter { !$0.isEmpty }, ["1", "8", "15", "22", "29"])
        XCTAssertEqual(v.selected, 19)
        XCTAssertTrue(v.total == Traffic())
    }
    func testCarrierIdentityAndLegacyHistory() throws {
        var r = Route(id: "r1", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands"))
        let original = StatsMath.idOf(r)
        XCTAssertTrue(original.hasPrefix("r1@"))
        r.hue = 5; r.filter = true; r.loc.country = "Holland"
        XCTAssertEqual(StatsMath.idOf(r), original)
        r.loc.provider = "mullvad"; XCTAssertNotEqual(StatsMath.idOf(r), original)
        r.loc.provider = "nord"; r.loc.city = "Amsterdam"; XCTAssertNotEqual(StatsMath.idOf(r), original)
        r.loc.city = nil; r.loc.pinned = Server(name: "nl1", host: "nl1.example", ip: "", publicKey: "", load: 0)
        XCTAssertNotEqual(StatsMath.idOf(r), original)
        var wg = Route(id: "wg", wg: WgPeer(name: "home", privateKey: "private", address: [], publicKey: "public", endpoint: "a:51820", allowedIps: []))
        let wgID = StatsMath.idOf(wg)
        wg.wg?.privateKey = "other"; wg.wg?.name = "renamed"; XCTAssertEqual(StatsMath.idOf(wg), wgID)
        wg.wg?.endpoint = "b:51820"; XCTAssertNotEqual(StatsMath.idOf(wg), wgID)
        wg.wg?.endpoint = "a:51820"; wg.wg?.publicKey = "other"; XCTAssertNotEqual(StatsMath.idOf(wg), wgID)
        var ss = Route(id: "ss", ss: SsProfile(name: "s", server: "a", port: 8388, method: "aes", password: "secret"))
        let ssID = StatsMath.idOf(ss); ss.ss?.password = "changed"; XCTAssertEqual(StatsMath.idOf(ss), ssID)
        ss.ss?.port = 8389; XCTAssertNotEqual(StatsMath.idOf(ss), ssID)
        XCTAssertFalse(wgID.contains("private")); XCTAssertFalse(wgID.contains("public")); XCTAssertFalse(ssID.contains("secret"))
        XCTAssertTrue(StatsMath.legacy("r1")); XCTAssertFalse(StatsMath.legacy(original))
        for id in [StatsMath.home, DIRECT, "ts:100.64.0.1"] { XCTAssertFalse(StatsMath.legacy(id)) }
        XCTAssertNotEqual(StatsMath.idOf(Route(id: "r1", tsExit: "100.64.0.1")), original)
        var ov = Route(id: "ov", ovpn: OvpnProfile(name: "x", config: "client\nremote a.example 1194\n<auth-user-pass>\nremote secret\n</auth-user-pass>", username: "u", password: "p"))
        let ovID = StatsMath.idOf(ov)
        ov.ovpn?.name = "renamed"; ov.ovpn?.password = "other"
        ov.ovpn?.config = "client\nremote a.example 1194\n<auth-user-pass>\nremote changed\n</auth-user-pass>"
        XCTAssertEqual(StatsMath.idOf(ov), ovID)
        ov.ovpn?.config = "client\nremote b.example 1194"; XCTAssertNotEqual(StatsMath.idOf(ov), ovID)
        ov.ovpn?.config = "client\nremote a.example 443"; XCTAssertNotEqual(StatsMath.idOf(ov), ovID)
        ov.ovpn?.config = "client\nremote a.example 1194\nproto tcp"; XCTAssertNotEqual(StatsMath.idOf(ov), ovID)
        XCTAssertEqual(StatsMath.ovpnServers("--remote \"a.example\" 1194 # comment\nport 443\nproto tcp"), ["a.example 1194", "443", "tcp"])
    }

    func testPruningDeletesAllPeaksAndKeepsRecentHistory() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE hourly(h INTEGER, exit TEXT);
        CREATE TABLE daily(d INTEGER, exit TEXT);
        CREATE TABLE server(d INTEGER, exit TEXT);
        CREATE TABLE peak(d INTEGER, exit TEXT);
        CREATE TABLE span(start INTEGER);
        CREATE TABLE exit(id TEXT);
        CREATE TABLE test(at INTEGER, exit TEXT, grp INTEGER);
        INSERT INTO peak VALUES(20000, 'recent'), (1, 'old');
        INSERT INTO daily VALUES(20000, 'recent'), (1, 'old');
        INSERT INTO exit VALUES('recent'), ('old');
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        for (sql, args) in StatsMath.pruneCommands(now: 20000 * 24 * StatsMath.hour, today: 20000) {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
            for (i, arg) in args.enumerated() { sqlite3_bind_int64(statement, Int32(i + 1), arg) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        func count(_ table: String) -> Int32 {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1
        }
        XCTAssertEqual(count("peak"), 0)
        XCTAssertEqual(count("daily"), 1)
        XCTAssertEqual(count("exit"), 1)
    }

    func testHistoryShowsAGroupOnceWithItsLegs() {
        let single = TestResult(at: 1, exit: "nl", via: "", server: "", ip: "", down: 1, up: 1, idle: 0)
        let total = TestResult(at: 10, exit: "all", via: "", server: "", ip: "", down: 3, up: 3, idle: 0, grp: 10, n: 2)
        let first = TestResult(at: 11, exit: "nl", via: "", server: "", ip: "", down: 1, up: 1, idle: 0, grp: 10, n: 2)
        let second = TestResult(at: 12, exit: "de", via: "", server: "", ip: "", down: 2, up: 2, idle: 0, grp: 10, n: 2)
        let rows = [second, first, total, single]
        XCTAssertEqual(StatsMath.historyRuns(rows), [total, single])
        XCTAssertEqual(StatsMath.historyLegs(total, rows: rows), [second, first])
        XCTAssertTrue(StatsMath.historyLegs(single, rows: rows).isEmpty)
    }

    func testOldTestRowsMigrateWithNoGroup() {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE test(at INTEGER PRIMARY KEY, exit TEXT); INSERT INTO test VALUES(1, 'nl')", nil, nil, nil), SQLITE_OK)
        for sql in StatsMath.testMigration { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT grp, n FROM test", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_type(stmt, 0), SQLITE_NULL); XCTAssertEqual(sqlite3_column_int(stmt, 1), 0)
        sqlite3_finalize(stmt)
    }

    func testRetentionKeepsWholeRuns() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE test(at INTEGER, exit TEXT, grp INTEGER)", nil, nil, nil), SQLITE_OK)
        for i in 1...101 {
            let sql = "INSERT INTO test VALUES (\(i * 10), 'all', \(i * 10)), (\(i * 10 + 1), 'leg', \(i * 10))"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        let command = try XCTUnwrap(StatsMath.pruneCommands(now: 0, today: 0).first { $0.0.hasPrefix("DELETE FROM test") })
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, command.0, -1, &stmt, nil), SQLITE_OK)
        sqlite3_bind_int64(stmt, 1, command.1[0]); XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE); sqlite3_finalize(stmt)
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT COUNT(*), COUNT(DISTINCT grp), MIN(grp) FROM test", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 200); XCTAssertEqual(sqlite3_column_int(stmt, 1), 100); XCTAssertEqual(sqlite3_column_int(stmt, 2), 20)
        sqlite3_finalize(stmt)
    }

    /// A route's week adds up every carrier it used: its current history, earlier ones and rows from before carriers.
    func testRouteIdFoldsEveryHistoryOfARoute() {
        let r = Route(id: "nl", loc: Location(provider: "mullvad", countryCode: "nl"))
        XCTAssertEqual(StatsMath.routeId(StatsMath.idOf(r)), "nl")
        XCTAssertEqual(StatsMath.routeId("nl"), "nl")
        XCTAssertEqual(StatsMath.routeId("home"), "home")
    }
}
