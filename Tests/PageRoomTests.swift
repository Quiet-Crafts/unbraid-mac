import XCTest

final class PageRoomTests: XCTestCase {
    private func plan(_ room: Double, apps: Int = 5, sites: Int = 2) -> PageRoom.Plan {
        PageRoom.plan(room: room, top: 100, strip: 100, chrome: 100, row: 40, apps: apps, sites: sites)
    }

    func testRoomyPageShowsEverything() {
        XCTAssertEqual(plan(1000), .init(strip: true, apps: 5, sites: 2))
        // Websites get their rows before the apps get more than two.
        XCTAssertEqual(plan(300 + 40 * 5), .init(strip: true, apps: 3, sites: 2))
    }

    func testStripGivesWayBeforeTheListsLoseTheirSecondRow() {
        // With the strip: room for three rows only. Without it: five.
        XCTAssertEqual(plan(300 + 40 * 3), .init(strip: false, apps: 3, sites: 2))
        XCTAssertEqual(plan(300 + 40 * 4), .init(strip: true, apps: 2, sites: 2))
    }

    func testShortRoomSharesRowsAndNeverGoesNegative() {
        XCTAssertEqual(plan(200 + 40 * 3), .init(strip: false, apps: 2, sites: 1))
        XCTAssertEqual(plan(200 + 40), .init(strip: false, apps: 1, sites: 0))
        XCTAssertEqual(plan(50), .init(strip: false, apps: 0, sites: 0))
        // Few rows wanted: the strip stays as long as they all fit.
        XCTAssertEqual(plan(300 + 40 * 2, apps: 1, sites: 1), .init(strip: true, apps: 1, sites: 1))
        // No websites: the apps alone.
        XCTAssertEqual(plan(300 + 40 * 2, apps: 9, sites: 0), .init(strip: true, apps: 2, sites: 0))
    }
}
