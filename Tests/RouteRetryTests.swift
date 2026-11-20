import XCTest
@testable import UnbraidTests

final class RouteRetryTests: XCTestCase {
    func testSlowLookupAndFailedApplyAdvancePastDueRoute() {
        var retry = RouteRetry<String>()
        let start = Date(timeIntervalSince1970: 1000)
        retry.update(["waiting": "edit"], attempted: [], now: start)
        let finished = start.addingTimeInterval(20)
        let attempted = retry.due(now: finished)
        XCTAssertEqual(attempted, ["waiting"])
        retry.failed(attempted: attempted, now: finished)
        XCTAssertTrue(retry.due(now: finished).isEmpty)
        XCTAssertEqual(retry.dates["waiting"], finished.addingTimeInterval(15))
        retry.update(["waiting": "edit"], attempted: [], now: finished)
        XCTAssertEqual(retry.dates["waiting"], finished.addingTimeInterval(15))
    }

    func testConfirmedRemovedPinsLoseTheirRetryDateUntilTheirLocationChanges() {
        let server = Server(name: "gone", host: "gone.example", ip: "10.0.0.1", publicKey: "pub", load: 0)
        let route = Route(id: "pin", loc: Location(provider: "fake", countryCode: "NL", pinned: server))
        let shared = Route(id: "shared", loc: Location(provider: "fake", countryCode: "DE", pinned: server))
        let waiting = Route(id: "waiting", loc: Location(provider: "fake", countryCode: "NL"))
        var setup = Setup(routes: [route, shared, waiting], defaultRoute: route.id)
        let accounts = ["fake": "acc"], now = Date(timeIntervalSince1970: 1000)
        var removed = LinkPicker.RemovedPins(), retry = RouteRetry<String>()
        let blocked: [String: LinkPicker.Blocked] = ["pin": .noLongerOffered(server.name), "shared": .waiting, "waiting": .waiting]
        retry.update(blocked, setup: setup, removedPins: removed, revision: "edit", attempted: [], now: now)
        XCTAssertEqual(Set(retry.dates.keys), ["pin", "shared", "waiting"])
        removed.remember(["pin": .noLongerOffered(server.name)], setup: setup, accounts: accounts)
        retry.update(blocked, setup: setup, removedPins: removed, revision: "edit", attempted: ["pin"], now: now)
        XCTAssertEqual(retry.dates, ["waiting": now.addingTimeInterval(5)])
        XCTAssertEqual(retry.due(now: now.addingTimeInterval(3600)), ["waiting"])
        setup.routes[0].loc.pinned = nil
        removed.update(setup, accounts: accounts)
        retry.update(blocked, setup: setup, removedPins: removed, revision: "new edit", attempted: [], now: now)
        XCTAssertEqual(Set(retry.dates.keys), ["pin", "shared", "waiting"])
    }

    func testRouteRetryStillExcludesAccountFailuresAndKeepsTemporaryFailures() {
        let reasons: [String: LinkPicker.Blocked] = ["signedOut": .signedOut("Fake"), "refused": .refused("Fake", "no"),
            "removed": .removed("Fake"), "unreachable": .unreachable("offline"), "waiting": .waiting, "clash": .clash]
        let setup = Setup(routes: reasons.keys.map { Route(id: $0, loc: Location(provider: "fake")) })
        var retry = RouteRetry<String>()
        retry.update(reasons, setup: setup, removedPins: LinkPicker.RemovedPins(), revision: "edit", attempted: [], now: .now)
        XCTAssertEqual(Set(retry.dates.keys), ["unreachable", "waiting", "clash"])
    }

    func testBackoffAndIndependentRoutes() {
        var retry = RouteRetry<Int>()
        let start = Date(timeIntervalSince1970: 1000)
        retry.update(["a": 1, "b": 1], attempted: [], now: start)
        var now = start
        for delay in [5.0, 15, 30, 60, 300, 300] {
            XCTAssertEqual(retry.dates["a"], now.addingTimeInterval(delay))
            now.addTimeInterval(delay)
            XCTAssertTrue(retry.due(now: now).contains("a"))
            retry.update(["a": 1, "b": 1], attempted: ["a"], now: now)
        }
        XCTAssertEqual(retry.dates["b"], start.addingTimeInterval(5))
    }

    func testFailedFallbackRetryKeepsItsScheduledInputsAndBackoff() {
        var retry = RouteRetry<String>()
        let start = Date(timeIntervalSince1970: 1000)
        retry.update(["a": "running", "b": "running"], attempted: [], now: start)
        var now = start.addingTimeInterval(5)
        for delay in [15.0, 30, 60, 300, 300] {
            retry.failed(attempted: ["a"], now: now)
            XCTAssertEqual(retry.dates["a"], now.addingTimeInterval(delay))
            XCTAssertEqual(retry.dates["b"], start.addingTimeInterval(5))
            // Preparing the next fallback uses the running revision again, not the pending edit.
            retry.update(["a": "running", "b": "running"], attempted: [], now: now)
            XCTAssertEqual(retry.dates["a"], now.addingTimeInterval(delay))
            now.addTimeInterval(delay)
        }
        retry.update(["a": "edited"], attempted: [], now: now)
        XCTAssertEqual(retry.dates["a"], now.addingTimeInterval(5))
        retry.clear()
        retry.failed(attempted: ["a"], now: now)
        XCTAssertTrue(retry.dates.isEmpty)
    }

    func testRemovalReplacementSleepAndRestart() {
        var retry = RouteRetry<Int>()
        let start = Date(timeIntervalSince1970: 1000)
        retry.update(["a": 1], attempted: [], now: start)
        XCTAssertEqual(retry.due(now: start.addingTimeInterval(3600)), ["a"])
        retry.update(["a": 2], attempted: ["a"], now: start.addingTimeInterval(3600))
        XCTAssertEqual(retry.dates["a"], start.addingTimeInterval(3605))
        retry.update([:], attempted: [], now: start)
        XCTAssertTrue(retry.dates.isEmpty)
        retry = RouteRetry<Int>()
        retry.update(["a": 2], attempted: [], now: start)
        XCTAssertEqual(retry.dates["a"], start.addingTimeInterval(5))
    }

    func testNetworkBurstAndReturnToOriginal() {
        var changes = NetworkChanges<String>()
        let start = Date(timeIntervalSince1970: 1000)
        changes.observe("wifi", now: start)
        changes.observe("wifi", now: start)
        XCTAssertNil(changes.deadline)
        changes.observe("offline", now: start)
        changes.observe("ethernet", now: start.addingTimeInterval(1))
        XCTAssertFalse(changes.take(now: start.addingTimeInterval(2)))
        XCTAssertTrue(changes.take(now: start.addingTimeInterval(3)))
        changes.observe("wifi", now: start.addingTimeInterval(4))
        changes.observe("ethernet", now: start.addingTimeInterval(5))
        XCTAssertFalse(changes.take(now: start.addingTimeInterval(10)))
    }

    /// Another Wi-Fi on the same interface, its router at the same address: the Mac drops off one network and joins the
    /// other within two seconds, and both look the same once joined. Still a move; a change of nothing else isn't.
    func testANetworkJoinedAgainAfterADropIsAMove() {
        var changes = NetworkChanges<String>()
        let start = Date(timeIntervalSince1970: 1000)
        changes.observe("wifi", now: start)
        changes.observe("none", down: true, now: start.addingTimeInterval(0.5))
        changes.observe("wifi", now: start.addingTimeInterval(1))
        XCTAssertFalse(changes.take(now: start.addingTimeInterval(2)))
        XCTAssertTrue(changes.take(now: start.addingTimeInterval(3)))
        // Taken: the same network again without a drop is nothing.
        changes.observe("wifi", now: start.addingTimeInterval(4))
        XCTAssertNil(changes.deadline)
        // Down long enough to be delivered, then updates while still down: no move until a network comes.
        changes.observe("none", down: true, now: start.addingTimeInterval(5))
        XCTAssertTrue(changes.take(now: start.addingTimeInterval(7)))
        changes.observe("none", down: true, now: start.addingTimeInterval(8))
        XCTAssertNil(changes.deadline)
        // Another kind of nothing while still down (the interface list changed while offline): no move either.
        changes.observe("none, other", down: true, now: start.addingTimeInterval(8.5))
        XCTAssertTrue(changes.take(now: start.addingTimeInterval(10.5)))
        changes.observe("wifi", now: start.addingTimeInterval(11))
        XCTAssertTrue(changes.take(now: start.addingTimeInterval(13)))
        // A blip that isn't a drop (a tunnel reloading: the Wi-Fi stays) and back: nothing.
        changes.observe("wifi, blip", now: start.addingTimeInterval(14))
        changes.observe("wifi", now: start.addingTimeInterval(14.5))
        XCTAssertNil(changes.deadline)
    }
}
