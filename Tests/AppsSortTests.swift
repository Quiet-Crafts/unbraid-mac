import XCTest
@testable import UnbraidTests

/// The apps list's order: the column and direction asked for, names breaking ties.
final class AppsSortTests: XCTestCase {
    private func row(_ name: String, route: String = "A", week: Int64 = 0) -> Row {
        Row(id: name, name: name, routeName: route, week: week)
    }

    private func names(_ rows: [Row], _ sort: AppsSort) -> [String] { rows.sorted(by: sort.inOrder).map(\.name) }

    func testDefaultIsBusiestFirstWithNamesBreakingTies() {
        let rows = [row("Zed", week: 5), row("beta"), row("Alpha"), row("Mid", week: 9)]
        XCTAssertEqual(names(rows, AppsSort()), ["Mid", "Zed", "Alpha", "beta"])
    }

    func testNamesSortLikeFinderInBothDirections() {
        let rows = [row("App 10"), row("app 2"), row("Äpfel")]
        XCTAssertEqual(names(rows, AppsSort(terms: [.init(key: .name, ascending: true)])), ["Äpfel", "app 2", "App 10"])
        XCTAssertEqual(names(rows, AppsSort(terms: [.init(key: .name, ascending: false)])), ["App 10", "app 2", "Äpfel"])
    }

    func testRouteOrderKeepsNamesAscendingWithinARouteEitherWay() {
        let rows = [row("b", route: "Italy"), row("a", route: "Italy"), row("c", route: "Germany")]
        XCTAssertEqual(names(rows, AppsSort(terms: [.init(key: .route, ascending: true)])), ["c", "a", "b"])
        XCTAssertEqual(names(rows, AppsSort(terms: [.init(key: .route, ascending: false)])), ["a", "b", "c"])
    }

    func testAnEarlierColumnOrdersWhatTheLatestLeavesTied() {
        let rows = [row("a", route: "Italy", week: 1), row("b", route: "Italy", week: 9), row("c", route: "Germany", week: 5)]
        let sort = AppsSort(terms: [.init(key: .route, ascending: true), .init(key: .week, ascending: false)])
        XCTAssertEqual(names(rows, sort), ["c", "b", "a"])
    }

    func testIsAStrictOrderOnEqualRows() {
        XCTAssertFalse(AppsSort().inOrder(row("Same"), row("Same")))
    }

    func testSearchMatchesNamesAndToolPathsButNotAppIdentifiers() {
        XCTAssertTrue(AppSearch.matches(name: "Mail", id: "com.apple.mail", query: "mail"))
        XCTAssertTrue(AppSearch.matches(name: "anything", id: "anything", query: ""))
        XCTAssertFalse(AppSearch.matches(name: "Xcode", id: "com.apple.dt.Xcode", query: "app"))
        XCTAssertTrue(AppSearch.matches(name: "curl", id: "/usr/bin/curl", query: "usr/bin"))
    }
}
