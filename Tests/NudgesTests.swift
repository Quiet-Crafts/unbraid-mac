import XCTest

/// The support card: rare, never in a first week, never again once turned off.
final class NudgesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ n: Double) -> Date { t0.addingTimeInterval(n * Nudges.day) }

    private func ready() -> NudgeState {
        var s = Nudges.installed(NudgeState(), now: t0)
        for d in [1.0, 2, 3] { s = Nudges.connectedDay(s, now: days(d)) }
        return s
    }

    func testNotInTheFirstWeekNorBeforeThreeConnectedDays() {
        XCTAssertFalse(Nudges.due(NudgeState(), now: days(400), calm: true), "never opened: no install date")
        var s = Nudges.installed(NudgeState(), now: t0)
        XCTAssertEqual(Nudges.installed(s, now: days(5)).installedAt, t0, "kept once set")
        s = Nudges.connectedDay(s, now: days(1))
        s = Nudges.connectedDay(s, now: days(1.5))
        XCTAssertEqual(s.connectedDays.count, 1, "the same day counts once")
        s = Nudges.connectedDay(s, now: days(2))
        XCTAssertFalse(Nudges.due(s, now: days(30), calm: true))
        s = Nudges.connectedDay(s, now: days(3))
        XCTAssertFalse(Nudges.due(s, now: days(6.9), calm: true))
        XCTAssertTrue(Nudges.due(s, now: days(7), calm: true))
        XCTAssertFalse(Nudges.due(s, now: days(7), calm: false))
        XCTAssertEqual(Nudges.connectedDay(s, now: days(9)).connectedDays.count, 3, "three days are all it keeps")
    }

    func testAtMostOnceInNinetyDaysAndFourTimesAYear() {
        var s = ready()
        var now = days(10)
        XCTAssertTrue(Nudges.due(s, now: now, calm: true))
        s = Nudges.shown(s, now: now)
        XCTAssertFalse(Nudges.due(s, now: now.addingTimeInterval(89 * Nudges.day), calm: true))
        var shows = 1
        // Checked every day for three years: never closer than 90 days, never more than four in any 365.
        var all = [now]
        for _ in 0..<(3 * 365) {
            now = now.addingTimeInterval(Nudges.day)
            if Nudges.due(s, now: now, calm: true) { s = Nudges.shown(s, now: now); shows += 1; all.append(now) }
        }
        XCTAssertGreaterThan(shows, 8)
        for (a, b) in zip(all, all.dropFirst()) { XCTAssertGreaterThanOrEqual(b.timeIntervalSince(a), 90 * Nudges.day) }
        for start in all { XCTAssertLessThanOrEqual(all.filter { $0 >= start && $0.timeIntervalSince(start) < 365 * Nudges.day }.count, 4) }
        XCTAssertLessThanOrEqual(s.shownAt.count, 4)
    }

    func testNeverAgainOnceTurnedOffAndNotWhileTheClockIsBehind() {
        let off = Nudges.disable(ready())
        XCTAssertFalse(Nudges.due(off, now: days(500), calm: true))
        // Shown "in the future" (the clock was set back since): counts as just shown.
        let shown = Nudges.shown(ready(), now: days(200))
        XCTAssertFalse(Nudges.due(shown, now: days(100), calm: true))
        // Saved and read back the same; a file from before any of it reads as nothing recorded.
        XCTAssertEqual(try JSONDecoder().decode(NudgeState.self, from: JSONEncoder().encode(off)).disabled, true)
        XCTAssertEqual(try JSONDecoder().decode(NudgeState.self, from: Data("{}".utf8)), NudgeState())
    }
}
