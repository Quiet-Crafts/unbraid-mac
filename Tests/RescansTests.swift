import XCTest

final class RescansTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testActivationRescansAtMostEvery30Seconds() {
        var r = Rescans()
        XCTAssertTrue(r.start(changed: false, now: t0))
        XCTAssertFalse(r.finished())
        XCTAssertFalse(r.start(changed: false, now: t0 + 10))
        XCTAssertFalse(r.start(changed: false, now: t0 + Rescans.activationGap))
        XCTAssertTrue(r.start(changed: false, now: t0 + Rescans.activationGap + 1))
    }

    func testAChangeRescansWhateverTheLastScan() {
        var r = Rescans()
        XCTAssertTrue(r.start(changed: false, now: t0))
        _ = r.finished()
        XCTAssertTrue(r.start(changed: true, now: t0 + 1))
    }

    func testAChangeDuringAScanRunsOneMoreActivationDoesnt() {
        var r = Rescans()
        XCTAssertTrue(r.start(changed: false, now: t0))
        XCTAssertFalse(r.start(changed: false, now: t0 + 1))
        XCTAssertFalse(r.finished())
        XCTAssertTrue(r.start(changed: false, now: t0 + 31))
        XCTAssertFalse(r.start(changed: true, now: t0 + 32))
        XCTAssertFalse(r.start(changed: true, now: t0 + 33))
        XCTAssertTrue(r.loading)
        XCTAssertTrue(r.finished(), "one follow-up for any number of changes")
        XCTAssertTrue(r.start(changed: true, now: t0 + 34))
        XCTAssertFalse(r.finished())
    }

    func testAChangeWaitsToSettleAndKeepsTheScansApart() {
        var r = Rescans()
        XCTAssertEqual(r.delay(now: t0), Rescans.settle)
        XCTAssertTrue(r.start(changed: true, now: t0))
        _ = r.finished()
        XCTAssertEqual(r.delay(now: t0 + 1), Rescans.changeGap - 1)
        XCTAssertEqual(r.delay(now: t0 + 60), Rescans.settle)
    }

    // MARK: Retries

    func testUnreadableBundlesAreScannedAgainThreeTimesThenNotForTheSameOnes() {
        var r = Retries()
        let half: Set = ["/Applications/Foo.app"]
        XCTAssertNil(r.scanned([], now: t0))
        XCTAssertEqual(r.scanned(half, now: t0), t0 + 10)
        // Scans in between (activation, a folder change) don't use the steps up.
        XCTAssertEqual(r.scanned(half, now: t0 + 3), t0 + 10)
        XCTAssertEqual(r.scanned(half, now: t0 + 9), t0 + 10)
        XCTAssertEqual(r.scanned(half, now: t0 + 10.5), t0 + 40.5)
        XCTAssertEqual(r.scanned(half, now: t0 + 41), t0 + 161)
        XCTAssertNil(r.scanned(half, now: t0 + 161))
        XCTAssertNil(r.scanned(half, now: t0 + 1000), "a bundle that stays unreadable doesn't scan for ever")
        // Another bundle starts over; so does one read at last.
        XCTAssertEqual(r.scanned(half.union(["/Applications/Bar.app"]), now: t0 + 2000), t0 + 2010)
        XCTAssertNil(r.scanned([], now: t0 + 2001))
        XCTAssertEqual(r.scanned(half, now: t0 + 2002), t0 + 2012)
    }

    // MARK: Starts left out (R-8b)

    func testAStartLeftOutIsRebuiltOnceThenAgainWhenAnythingChangesOrAfterAWhile() {
        var u = UnmatchedStarts()
        let start = UnmatchedStarts.key("com.foo", "/P/Foo.app", "/P/Foo.app/Contents/MacOS/Foo")
        XCTAssertTrue(u.due(start, real: "/usr/bin/x", now: t0))
        u.rebuilt(start, real: "/usr/bin/x", now: t0)
        // The same start, resolving the same, soon after: not again (the bug was a rescan at every start).
        XCTAssertFalse(u.due(start, real: "/usr/bin/x", now: t0 + 60))
        // It resolves elsewhere now; or ten minutes have passed: due.
        XCTAssertTrue(u.due(start, real: "/usr/bin/y", now: t0 + 60))
        XCTAssertTrue(u.due(start, real: "/usr/bin/x", now: t0 + UnmatchedStarts.expiry))
        XCTAssertTrue(u.due(start, real: "/usr/bin/x", now: t0 - 60), "a clock set back")
        // What decides Foo's rules changed (a copy found, a place taken): due. Another app's change: not.
        u.forget("com.foo.helper")
        XCTAssertFalse(u.due(start, real: "/usr/bin/x", now: t0 + 60))
        u.forget("com.foo")
        XCTAssertTrue(u.due(start, real: "/usr/bin/x", now: t0 + 60))
        // Matched once, or its rules now take it in: due again next time it is left out.
        u.rebuilt(start, real: "/usr/bin/x", now: t0)
        u.forget("com.foo") { $0 == "/usr/bin/other" }
        XCTAssertFalse(u.due(start, real: "/usr/bin/x", now: t0 + 60))
        u.forget("com.foo") { $0 == "/usr/bin/x" }
        XCTAssertTrue(u.due(start, real: "/usr/bin/x", now: t0 + 60))
        u.rebuilt(start, real: "/usr/bin/x", now: t0)
        u.matched(start)
        XCTAssertTrue(u.due(start, real: "/usr/bin/x", now: t0 + 60))
    }
}
