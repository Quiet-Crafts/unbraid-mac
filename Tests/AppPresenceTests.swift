import XCTest

final class AppPresenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3600

    private func scan(_ apps: [String: String], seen: [String: (name: String, path: String)] = [:], unknown: Set<String> = [],
                      _ records: [String: AppPresence.Record], at t: Date) -> ([String: AppPresence.Record], [String]) {
        let r = AppPresence.reconcile(apps: apps, seen: seen, unknown: unknown, records: records, now: t)
        return (r.records, r.drop)
    }

    func testBlockAndDirectAreNeverDroppedForAMissingApp() {
        for route in [BLOCK, DIRECT] { neverDropped(route) }
    }

    private func neverDropped(_ route: String) {
        let apps = ["com.foo": route]
        var records = scan(apps, seen: ["com.foo": ("Foo", "/Applications/Foo.app")], [:], at: t0).0
        for i in 1...10 {
            let (r, drop) = scan(apps, records, at: t0 + Double(i) * 30 * day)
            XCTAssertEqual(drop, [])
            records = r
        }
        XCTAssertEqual(records["com.foo"]?.name, "Foo")
        XCTAssertEqual(records["com.foo"]?.path, "/Applications/Foo.app")
        // Counted up to the threshold only, so a long absence doesn't rewrite the record every scan.
        XCTAssertEqual(records["com.foo"]?.missedScans, AppPresence.graceScans)
        XCTAssertEqual(records["com.foo"]?.missingSince, t0 + 30 * day)
        XCTAssertEqual(records["com.foo"]?.route, route)
    }

    func testARouteGoesOnlyAfterSeveralScansAndDays() {
        let apps = ["com.foo": "r1"]
        // Many scans in one day: kept.
        var records: [String: AppPresence.Record] = [:]
        for i in 0..<10 {
            let (r, drop) = scan(apps, records, at: t0 + Double(i) * 60)
            XCTAssertEqual(drop, [])
            records = r
        }
        // Days later, after enough scans: dropped, and forgotten.
        let (r, drop) = scan(apps, records, at: t0 + AppPresence.graceTime)
        XCTAssertEqual(drop, ["com.foo"])
        XCTAssertNil(r["com.foo"])
        // Days apart but too few scans: kept.
        var few = scan(apps, [:], at: t0).0
        few = scan(apps, few, at: t0 + 10 * day).0
        XCTAssertEqual(few["com.foo"]?.missedScans, 2)
        XCTAssertEqual(scan(apps, few, at: t0 + 20 * day).1, ["com.foo"])
    }

    func testAnAppThatComesBackStartsOver() {
        let apps = ["com.foo": "r1", "com.bar": "r2"]
        var records = scan(apps, [:], at: t0).0
        records = scan(apps, records, at: t0 + 3 * day).0
        records = scan(apps, seen: ["com.foo": ("Foo", "/Volumes/Ext/Foo.app")], records, at: t0 + 4 * day).0
        XCTAssertEqual(records["com.foo"], AppPresence.Record(name: "Foo", path: "/Volumes/Ext/Foo.app"))
        XCTAssertEqual(records["com.bar"]?.missedScans, 3)
        let (r, drop) = scan(apps, records, at: t0 + 8 * day)
        XCTAssertEqual(drop, ["com.bar"])
        XCTAssertEqual(r["com.foo"]?.missedScans, 1)
        XCTAssertEqual(r["com.foo"]?.missingSince, t0 + 8 * day)
    }

    func testToolsAndUnassignedAppsAreLeftAlone() {
        let old = ["com.gone": AppPresence.Record(name: "Gone", path: "/Applications/Gone.app", missingSince: t0, missedScans: 9)]
        let (r, drop) = scan(["/opt/homebrew/bin/node": "r1"], old, at: t0 + 100 * day)
        XCTAssertEqual(drop, [])
        XCTAssertEqual(r, [:])
    }

    func testTheExactBoundaries() {
        let apps = ["com.foo": "r1"]
        var records = scan(apps, [:], at: t0).0
        records = scan(apps, records, at: t0 + 1).0
        XCTAssertEqual(scan(apps, records, at: t0 + AppPresence.graceTime - 1).1, [])
        XCTAssertEqual(scan(apps, records, at: t0 + AppPresence.graceTime).1, ["com.foo"])
        let two = scan(apps, [:], at: t0).0
        XCTAssertEqual(scan(apps, two, at: t0 + 2 * AppPresence.graceTime).1, [], "two scans are not enough")
    }

    func testMovingAMissingAppStartsTheWaitAgain() {
        // Missing for weeks while blocked; moved to a VPN route: that route gets its own grace.
        var records: [String: AppPresence.Record] = [:]
        for i in 0..<5 { records = scan(["com.foo": BLOCK], records, at: t0 + Double(i) * 10 * day).0 }
        let (r, drop) = scan(["com.foo": "r1"], records, at: t0 + 50 * day)
        XCTAssertEqual(drop, [])
        XCTAssertEqual(r["com.foo"]?.missingSince, t0 + 50 * day)
        XCTAssertEqual(r["com.foo"]?.missedScans, 1)
    }

    func testAnAbsenceTheScanCantConfirmPausesTheCountAndKeepsTheName() {
        let apps = ["com.foo": "r1"]
        var records = scan(apps, seen: ["com.foo": ("Foo", "/Volumes/Ext/Foo.app")], [:], at: t0).0
        for i in 1...2 { records = scan(apps, records, at: t0 + Double(i) * 10 * day).0 }
        // The disk is unplugged (or a folder couldn't be read): no drop, and the count stands still, not reset.
        let (r, drop) = scan(apps, unknown: ["com.foo"], records, at: t0 + 60 * day)
        XCTAssertEqual(drop, [])
        XCTAssertEqual(r["com.foo"]?.name, "Foo")
        XCTAssertEqual(r["com.foo"]?.path, "/Volumes/Ext/Foo.app")
        XCTAssertEqual(r["com.foo"]?.missedScans, 2)
        XCTAssertEqual(r["com.foo"]?.missingSince, t0 + 10 * day)
        XCTAssertEqual(r["com.foo"]?.unavailableSince, t0 + 60 * day)
        // Intermittent: the next scan that can tell finishes the count.
        XCTAssertEqual(scan(apps, r, at: t0 + 61 * day).1, ["com.foo"])
    }

    func testNothingGoesOnAScanThatCantTellEvenPastTheThresholds() {
        let apps = ["com.foo": "r1"]
        var records: [String: AppPresence.Record] = [:]
        for i in 0..<3 { records = scan(apps, records, at: t0 + Double(i) * day).0 }
        let (r, drop) = scan(apps, unknown: ["com.foo"], records, at: t0 + 30 * day)
        XCTAssertEqual(drop, [])
        XCTAssertEqual(r["com.foo"]?.missedScans, AppPresence.graceScans)
        // And one that can't tell for weeks first gives no head start: the wait counts from the first that could.
        var late: [String: AppPresence.Record] = [:]
        for i in 0..<3 { late = scan(apps, unknown: ["com.foo"], late, at: t0 + Double(i) * 10 * day).0 }
        XCTAssertNil(late["com.foo"]?.missingSince)
        for i in 0..<3 { late = scan(apps, late, at: t0 + 25 * day + Double(i) * 60).0 }
        XCTAssertEqual(late["com.foo"]?.missingSince, t0 + 25 * day)
        XCTAssertEqual(scan(apps, late, at: t0 + 25 * day + AppPresence.graceTime - 1).1, [])
        XCTAssertEqual(scan(apps, late, at: t0 + 25 * day + AppPresence.graceTime).1, ["com.foo"])
    }

    func testAMoveWhileAScanCantTellStartsOver() {
        var records: [String: AppPresence.Record] = [:]
        for i in 0..<3 { records = scan(["com.foo": "r1"], records, at: t0 + Double(i) * 10 * day).0 }
        records = scan(["com.foo": "r1"], unknown: ["com.foo"], records, at: t0 + 30 * day).0
        let r = scan(["com.foo": "r2"], unknown: ["com.foo"], records, at: t0 + 31 * day).0
        XCTAssertEqual(r["com.foo"], AppPresence.Record(name: "", path: "", route: "r2", unavailableSince: t0 + 31 * day))
        // Undo or a move from the app list restarts the disk's wait too.
        XCTAssertEqual(AppPresence.restart(r, ["com.foo"])["com.foo"], AppPresence.Record(name: "", path: ""))
    }

    func testScansThatCantTellHoldOffAVpnRouteForAMonthAtMost() {
        // Whatever the reason (a disk never plugged in again, an uninstaller's leftovers, a locked folder).
        let apps = ["com.foo": "r1"]
        let cap = AppPresence.unknownGrace
        var r = scan(apps, unknown: ["com.foo"], [:], at: t0).0
        XCTAssertEqual(r["com.foo"]?.unavailableSince, t0)
        XCTAssertNil(scan(apps, unknown: ["com.foo"], r, at: t0 + cap - 1).0["com.foo"]?.missingSince)
        // From then on they count as missing: the usual wait follows, from that scan.
        for i in 0..<AppPresence.graceScans { r = scan(apps, unknown: ["com.foo"], r, at: t0 + cap + Double(i) * 60).0 }
        XCTAssertEqual(r["com.foo"]?.missingSince, t0 + cap)
        XCTAssertEqual(r["com.foo"]?.missedScans, AppPresence.graceScans)
        XCTAssertEqual(r["com.foo"]?.unavailableSince, t0)
        XCTAssertEqual(scan(apps, unknown: ["com.foo"], r, at: t0 + cap + AppPresence.graceTime - 1).1, [])
        XCTAssertEqual(scan(apps, unknown: ["com.foo"], r, at: t0 + cap + AppPresence.graceTime).1, ["com.foo"])
        // Block and Direct wait for good; a clock set back keeps waiting.
        for route in [BLOCK, DIRECT] {
            var b = scan(["com.foo": route], unknown: ["com.foo"], [:], at: t0).0
            for i in 1...5 { b = scan(["com.foo": route], unknown: ["com.foo"], b, at: t0 + Double(i) * cap).0 }
            XCTAssertNil(b["com.foo"]?.missingSince, route)
        }
        XCTAssertNil(scan(apps, unknown: ["com.foo"], scan(apps, unknown: ["com.foo"], [:], at: t0).0, at: t0 - 100 * day).0["com.foo"]?.missingSince)
    }

    func testADiskUnpluggedAgainGetsNoNewMonth() {
        // unavailableSince outlives the scans that could tell in between: the second absence doesn't restart the month.
        let apps = ["com.foo": "r1"]
        var r = scan(apps, seen: ["com.foo": ("Foo", "/Volumes/Ext/Foo.app")], [:], at: t0).0
        for i in 0...31 { r = scan(apps, unknown: ["com.foo"], r, at: t0 + Double(i) * day).0 }
        XCTAssertEqual(r["com.foo"]?.missingSince, t0 + 30 * day)
        r = scan(apps, r, at: t0 + 32 * day).0
        XCTAssertEqual(r["com.foo"]?.unavailableSince, t0)
        r = scan(apps, unknown: ["com.foo"], r, at: t0 + 33 * day).0
        XCTAssertEqual(r["com.foo"]?.missedScans, AppPresence.graceScans)
        XCTAssertEqual(scan(apps, unknown: ["com.foo"], r, at: t0 + 37 * day).1, ["com.foo"])
        // Seen again, or moved: both clocks start over.
        let back = scan(apps, seen: ["com.foo": ("Foo", "/Volumes/Ext/Foo.app")], r, at: t0 + 34 * day).0
        XCTAssertEqual(back["com.foo"], AppPresence.Record(name: "Foo", path: "/Volumes/Ext/Foo.app"))
        XCTAssertNil(scan(["com.foo": "r2"], unknown: ["com.foo"], r, at: t0 + 40 * day).0["com.foo"]?.missingSince)
    }

    func testAnAppGoneForADayNoLongerHoldsTheWholeMacsGuards() {
        // A program of it may still run a while after its bundle went; never while a scan couldn't tell.
        XCTAssertFalse(AppPresence.settled(nil, now: t0))
        XCTAssertFalse(AppPresence.settled(t0, now: t0 + AppPresence.settledAfter - 1))
        XCTAssertTrue(AppPresence.settled(t0, now: t0 + AppPresence.settledAfter))
        XCTAssertFalse(AppPresence.settled(t0, now: t0 - 100 * day))
        let r = scan(["com.foo": BLOCK], unknown: ["com.foo"], [:], at: t0).0
        XCTAssertFalse(AppPresence.settled(r["com.foo"]?.missingSince, now: t0 + 100 * day))
    }

    func testATrashOrTranslocatedCopyIsRememberedBesideWhereTheAppWasBefore() {
        // A running app dragged to the Trash, or opened translocated. That place still matches what runs from it
        // (a helper left running), and where it was before stays remembered for a copy installed there again.
        let apps = ["com.foo": BLOCK]
        let home = "/Applications/Foo.app"
        let before = scan(apps, seen: ["com.foo": ("Foo", home)], [:], at: t0).0
        for transient in ["/Users/me/.Trash/Foo.app", "/Volumes/Ext/.Trashes/501/Foo.app",
                          "/private/var/folders/x7/k2/T/AppTranslocation/0B6E1C2A/d/Foo.app"] {
            XCTAssertTrue(AppPresence.transient(transient), transient)
            var r = scan(apps, seen: ["com.foo": ("Foo 2", transient)], before, at: t0 + day).0
            XCTAssertEqual(r["com.foo"], AppPresence.Record(name: "Foo 2", path: transient, before: home))
            XCTAssertEqual(r["com.foo"]?.places, [transient, home])
            // Seen in another such place next: still where it was before. Then missing: both stay.
            r = scan(apps, seen: ["com.foo": ("Foo", "/Users/me/.Trash/Foo 2.app")], r, at: t0 + 2 * day).0
            XCTAssertEqual(r["com.foo"]?.before, home)
            r = scan(apps, r, at: t0 + 3 * day).0
            XCTAssertEqual(r["com.foo"]?.places, ["/Users/me/.Trash/Foo 2.app", home])
            // Never seen anywhere else: that copy's place is all there is.
            XCTAssertEqual(scan(apps, seen: ["com.foo": ("Foo", transient)], [:], at: t0).0["com.foo"]?.places, [transient])
            // Back in a lasting place: that one alone.
            XCTAssertNil(scan(apps, seen: ["com.foo": ("Foo", home)], r, at: t0 + 4 * day).0["com.foo"]?.before)
        }
        // Folders merely named alike, and a real move, are places.
        for path in ["/Users/me/Trash/Foo.app", "/Users/me/.Trashy/Foo.app", "/Users/me/Apps/Foo.app"] {
            XCTAssertFalse(AppPresence.transient(path), path)
            XCTAssertEqual(scan(apps, seen: ["com.foo": ("Foo", path)], before, at: t0 + day).0["com.foo"], AppPresence.Record(name: "Foo", path: path))
        }
        // Another app at the place before: retired like the path.
        let r = AppPresence.retire(["com.foo": AppPresence.Record(name: "Foo", path: "/Users/me/.Trash/Foo.app", before: home)]) { _, p in p != home }
        XCTAssertEqual(r["com.foo"]?.places, ["/Users/me/.Trash/Foo.app"])
    }

    func testOnlyAFolderHoldingAPlaceOfTheAppLeavesItUndecided() {
        let none: (String) -> Bool = { _ in false }
        let foo = ["/Applications/Vendor/Foo.app", "/Users/me/Downloads/Foo.app"]
        XCTAssertTrue(AppPresence.undecided(foo, failed: ["/Applications/Vendor"], unreadable: false, doubt: none))
        XCTAssertTrue(AppPresence.undecided(foo, failed: ["/Applications"], unreadable: false, doubt: none))
        // A sibling folder of a similar name, or another folder: decided. So is a bundle elsewhere that couldn't be read.
        XCTAssertFalse(AppPresence.undecided(foo, failed: ["/Applications/Vend", "/Applications/VendorX"], unreadable: true, doubt: none))
        // A place in doubt (a disk not mounted, a bundle being installed).
        XCTAssertTrue(AppPresence.undecided(foo, failed: [], unreadable: false) { $0.hasPrefix("/Users") })
        // Nothing known of where it was (an older version kept no path): anything the scan couldn't read may be it.
        XCTAssertTrue(AppPresence.undecided(["", ""], failed: [], unreadable: true, doubt: none))
        XCTAssertTrue(AppPresence.undecided([], failed: ["/x"], unreadable: false, doubt: none))
        XCTAssertFalse(AppPresence.undecided([], failed: [], unreadable: false, doubt: none))
    }

    func testAMoveAndItsUndoBetweenScansStartTheWaitAgain() {
        // Missing on r1 for weeks; moved off and back (Undo) before the next scan: it isn't dropped on that scan.
        let apps = ["com.foo": "r1"]
        var records: [String: AppPresence.Record] = [:]
        for i in 0..<3 { records = scan(apps, records, at: t0 + Double(i) * 10 * day).0 }
        records = AppPresence.restart(records, ["com.foo", "com.other"])
        XCTAssertEqual(records["com.foo"]?.missingSince, nil)
        XCTAssertNil(records["com.other"])
        let (r, drop) = scan(apps, records, at: t0 + 30 * day)
        XCTAssertEqual(drop, [])
        XCTAssertEqual(r["com.foo"]?.missedScans, 1)
        // An app that is here is left as it is.
        let here = ["com.foo": AppPresence.Record(name: "Foo", path: "/Applications/Foo.app")]
        XCTAssertEqual(AppPresence.restart(here, ["com.foo"]), here)
    }

    func testAPlaceAnotherAppHasTakenIsNoLongerRemembered() {
        // Foo was at P; Bar is there now. Foo's record loses P for good, so Bar's next update (P unreadable a while)
        // doesn't bring Foo's Block back over Bar.
        let records = ["com.foo": AppPresence.Record(name: "Foo", path: "/Applications/P.app", missingSince: t0, missedScans: 1, route: BLOCK),
                       "com.baz": AppPresence.Record(name: "Baz", path: "/Applications/Baz.app"),
                       "com.qux": AppPresence.Record(name: "Qux", path: "/Applications/Qux.app")]
        let holders = ["/Applications/P.app": "com.bar", "/Applications/Baz.app": "com.baz"]
        let r = AppPresence.retire(records) { id, path in !AppPaths.claims(id, [path], holder: { holders[$0] }).isEmpty }
        XCTAssertEqual(r["com.foo"]?.path, "")
        XCTAssertEqual(r["com.foo"]?.name, "Foo")
        XCTAssertEqual(r["com.foo"]?.missingSince, t0)
        XCTAssertEqual(r["com.baz"], records["com.baz"])
        // Gone or unreadable: still its place.
        XCTAssertEqual(r["com.qux"], records["com.qux"])
        XCTAssertEqual(AppPaths.claims("com.foo", [r["com.foo"]!.path], holder: { _ in nil }), [])
    }

    func testAClockSetBackNeverDrops() {
        let apps = ["com.foo": "r1"]
        var records = scan(apps, [:], at: t0).0
        for _ in 0..<5 { records = scan(apps, records, at: t0 - 30 * day).0 }
        XCTAssertNotNil(records["com.foo"])
    }
}
