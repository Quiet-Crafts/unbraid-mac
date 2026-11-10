import XCTest

/// Small pieces of app state that the views and the quit sequence rely on.
final class UiStateTests: XCTestCase {
    func testTailscaleStatesAreNamedOnce() {
        XCTAssertNil(TailscaleStatus(nil))
        XCTAssertEqual(TailscaleStatus("Running"), .connected)
        XCTAssertEqual(TailscaleStatus("NeedsLogin"), .signInNeeded)
        XCTAssertEqual(TailscaleStatus("NeedsMachineAuth"), .awaitingApproval)
        XCTAssertEqual(TailscaleStatus("Starting"), .starting)
        XCTAssertEqual(TailscaleStatus("NoState"), .starting)
        XCTAssertEqual(TailscaleStatus("Stopped"), .stopped)
        XCTAssertEqual(TailscaleStatus("InUseOtherUser"), .unknown)
    }

    func testBoundedWaitReturnsWhenTheWorkFinishes() async {
        let start = ContinuousClock.now
        let finished = await bounded(5) { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(finished)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testBoundedWaitGivesUpAtItsDeadline() async {
        let gate = AsyncStream<Void>.makeStream()
        let start = ContinuousClock.now
        // Work that never finishes on its own: held behind a gate opened only after the wait.
        let finished = await bounded(0.2) { for await _ in gate.stream { return } }
        XCTAssertFalse(finished)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        gate.continuation.yield()
        gate.continuation.finish()
    }
}
