import XCTest

final class PageRoomTests: XCTestCase {
    private func plan(_ room: Double, apps: Int = 5, sites: Int = 4) -> PageRoom.Plan? {
        PageRoom.plan(room: room, top: 200, chrome: 100, row: 40, apps: apps, sites: sites)
    }

    func testRoomyPageShowsEverything() {
        XCTAssertEqual(plan(1000), .init(apps: 5, sites: 4))
        // Past two rows each, the websites get theirs before the apps get more.
        XCTAssertEqual(plan(300 + 40 * 7), .init(apps: 3, sites: 4))
        XCTAssertEqual(plan(300 + 40 * 5), .init(apps: 2, sites: 3))
    }

    func testTwoWholeRowsEachOrTheWholePageScrolls() {
        XCTAssertEqual(plan(300 + 40 * 4), .init(apps: 2, sites: 2))
        XCTAssertNil(plan(300 + 40 * 4 - 1))
        XCTAssertNil(plan(50))
        // A list with one row needs room for one.
        XCTAssertEqual(plan(300 + 40 * 3, apps: 5, sites: 1), .init(apps: 2, sites: 1))
        XCTAssertNil(plan(300 + 40 * 2, apps: 5, sites: 1))
        // No websites: two apps rows are enough.
        XCTAssertEqual(plan(300 + 40 * 2, apps: 9, sites: 0), .init(apps: 2, sites: 0))
    }

    func testUnmeasuredPageAndOddInputsShowEverything() {
        // The first frame, before the page has a height, shows everything rather than nothing.
        XCTAssertEqual(PageRoom.plan(room: 0, top: 0, chrome: 0, row: 40, apps: 3, sites: 1), .init(apps: 3, sites: 1))
        XCTAssertEqual(PageRoom.plan(room: -10, top: 0, chrome: 0, row: 40, apps: 3, sites: 1), .init(apps: 3, sites: 1))
        XCTAssertEqual(PageRoom.plan(room: 500, top: 0, chrome: 0, row: 0, apps: 3, sites: 1), .init(apps: 3, sites: 1))
        XCTAssertEqual(PageRoom.plan(room: 500, top: 0, chrome: 0, row: 40, apps: -1, sites: 0), .init(apps: 0, sites: 0))
    }
}
