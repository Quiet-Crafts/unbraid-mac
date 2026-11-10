import XCTest

final class ExitCheckStateTests: XCTestCase {
    func testCancelledAttemptIsRefundedOnlyForItsEngine() {
        var state = ExitCheckState()
        state.update(engine: 1, routes: ["a": route("a")])
        for _ in 0..<5 {
            XCTAssertFalse(state.begin().isEmpty)
            state.cancelAttempt(engine: 1)
        }
        XCTAssertEqual(state.attempts, 0)
        _ = state.begin()
        state.update(engine: 2, routes: ["a": route("a")])
        _ = state.begin()
        state.cancelAttempt(engine: 1)
        XCTAssertEqual(state.attempts, 1)
        for _ in 0..<3 { _ = state.begin() }
        XCTAssertTrue(state.exhausted)
    }
    private func route(_ id: String, tag: String = "shared", owner: String = "owner") -> ExitRoute {
        ExitRoute(tag: tag, server: nil, route: Route(id: id), owner: owner)
    }

    func testSharedTunnelAndGenerationInvalidation() {
        var state = ExitCheckState()
        let routes = ["a": route("a"), "b": route("b")]
        state.update(engine: 1, routes: routes)
        let work = state.begin()
        XCTAssertEqual(Set(work.values.map(\.tag)), ["shared"])
        state.accept(["shared": "203.0.113.42"], engine: 1, routes: work)
        XCTAssertEqual(state.answers.count, 2)
        state.update(engine: 2, routes: routes)
        state.accept(["shared": "203.0.113.42"], engine: 1, routes: work)
        XCTAssertTrue(state.answers.isEmpty)
        XCTAssertEqual(state.attempts, 0)
    }

    func testAttemptLimitAndRouteOwnerChange() {
        var state = ExitCheckState()
        let old = ["a": route("a")]
        state.update(engine: 1, routes: old)
        for _ in 0..<4 { XCTAssertEqual(state.begin().count, 1) }
        XCTAssertTrue(state.exhausted)
        XCTAssertTrue(state.begin().isEmpty)
        let replacement = ["a": route("a", owner: "other")]
        state.update(engine: 1, routes: replacement)
        state.accept(["shared": "203.0.113.42"], engine: 1, routes: old)
        XCTAssertTrue(state.answers.isEmpty)
        XCTAssertTrue(state.exhausted)
        state.update(engine: nil, routes: [:])
        XCTAssertTrue(state.answers.isEmpty)
        state.update(engine: 1, routes: replacement)
        XCTAssertTrue(state.exhausted)
        state.update(engine: 2, routes: replacement)
        XCTAssertFalse(state.exhausted)
    }
    func testServerChangeRetiresOnlyItsAnswer() {
        var state = ExitCheckState()
        let old = ["a": route("a", tag: "a"), "b": route("b", tag: "b")]
        state.update(engine: 3, routes: old)
        let work = state.begin()
        state.accept(["a": "192.0.2.1", "b": "192.0.2.2"], engine: 3, routes: work)
        var changed = old
        changed["a"]?.server = Server(name: "new", host: "host", ip: "192.0.2.3", publicKey: "", load: 0)
        state.update(engine: 3, routes: changed)
        XCTAssertNil(state.answers["a"])
        XCTAssertEqual(state.answers["b"], "192.0.2.2")
        state.accept(["a": "192.0.2.4"], engine: 3, routes: old)
        XCTAssertNil(state.answers["a"])
    }

    func testRenameKeepsAnswerAndAcceptsAnInFlightAnswer() {
        var state = ExitCheckState()
        let old = ["a": route("a")]
        state.update(engine: 1, routes: old)
        let work = state.begin()
        var renamed = old
        renamed["a"]?.route.loc.country = "A new name"
        state.update(engine: 1, routes: renamed)
        state.accept(["shared": "192.0.2.1"], engine: 1, routes: work)
        XCTAssertEqual(state.answers["a"], "192.0.2.1")
        state.update(engine: 1, routes: old)
        XCTAssertEqual(state.answers["a"], "192.0.2.1")
        XCTAssertTrue(state.pending.isEmpty)
    }

}
