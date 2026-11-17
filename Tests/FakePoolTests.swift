import XCTest

/// When a running engine moves to the next block of stand-in addresses.
final class FakePoolTests: XCTestCase {
    func testCapacityIsWhatTheEngineHandsOutOfABlock() {
        // A /18 holds 16,384 addresses; the engine skips the network address and the one after it, and never hands out
        // the broadcast address.
        XCTAssertTrue(ConfigVet.fakeRanges.allSatisfy { $0.hasSuffix("/18") })
        XCTAssertEqual(FakePool.capacity, 16_381)
        XCTAssertEqual(FakePool.low, 4_095)
    }

    func testPlentyLeftOrNoStoreDoesNothing() {
        XCTAssertEqual(FakePool.step(remaining: FakePool.capacity, since: .seconds(1)), .nothing)
        XCTAssertEqual(FakePool.step(remaining: FakePool.low, since: .seconds(3600)), .nothing)
        XCTAssertEqual(FakePool.step(remaining: -1, since: nil), .nothing)
        XCTAssertEqual(FakePool.step(remaining: -1, since: .seconds(3600)), .nothing)
    }

    func testRunningLowRotatesOnceTheSpacingHasPassed() {
        XCTAssertEqual(FakePool.step(remaining: FakePool.low - 1, since: .seconds(600)), .rotate)
        XCTAssertEqual(FakePool.step(remaining: 0, since: .seconds(601)), .rotate)
        XCTAssertEqual(FakePool.step(remaining: 10, since: nil), .rotate)
    }

    func testRunningLowTooSoonWaitsAndSaysWhenLookupsFail() {
        XCTAssertEqual(FakePool.step(remaining: FakePool.low - 1, since: .seconds(599)), .wait(exhausted: false))
        XCTAssertEqual(FakePool.step(remaining: 1, since: .zero), .wait(exhausted: false))
        XCTAssertEqual(FakePool.step(remaining: 0, since: .seconds(30)), .wait(exhausted: true))
    }
}
