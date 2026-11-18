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

    func testOnlyAFailedMoveWithTheEngineDownIsRetried() {
        XCTAssertTrue(FakePool.retries(failedRotation: true, engineRunning: false))
        XCTAssertFalse(FakePool.retries(failedRotation: true, engineRunning: true))
        XCTAssertFalse(FakePool.retries(failedRotation: false, engineRunning: false), "an app reload that failed is the app's")
        XCTAssertFalse(FakePool.retries(failedRotation: false, engineRunning: true))
    }

    /// A block an engine ran on is kept only with the cache file that names its addresses; a file the engine refused as
    /// damaged is never tried again. A block no engine ran on yet (a move that failed) is tried again as it is.
    func testWhenAStartTakesANewTable() {
        for bytes in [0, 1, 32_768] {
            XCTAssertEqual(FakePool.needsNewTable(ran: true, cacheBytes: bytes, refused: false), bytes == 0, "\(bytes)")
            XCTAssertFalse(FakePool.needsNewTable(ran: false, cacheBytes: bytes, refused: false), "\(bytes)")
            XCTAssertTrue(FakePool.needsNewTable(ran: true, cacheBytes: bytes, refused: true))
            XCTAssertTrue(FakePool.needsNewTable(ran: false, cacheBytes: bytes, refused: true))
        }
    }

    /// The extension knows a refused cache file by the engine's words: they are the engine patch's, in both places it
    /// refuses one, at the step that opens the file.
    func testTheEngineSaysWhenItRefusesItsCacheFile() throws {
        let patch = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tools/sing-box-fakeip-no-reuse.patch")
        let text = try String(contentsOf: patch, encoding: .utf8)
        let refusals = text.split(separator: "\n").filter { $0.hasPrefix("+") && $0.contains("return E.Cause(err, \"") }
            .filter { $0.contains("cache file") }
        XCTAssertEqual(refusals.count, 2)
        XCTAssertTrue(refusals.allSatisfy { $0.contains("E.Cause(err, \"\(FakePool.damagedCache): ") })
        // As the engine's command line and as libbox word it.
        XCTAssertTrue(FakePool.refusedCache("start service: initialize cache-file: damaged cache file kept: it holds fake-IP names: invalid database"))
        XCTAssertTrue(FakePool.refusedCache("start or reload service: initialize cache-file: damaged cache file kept: it holds fake-IP names: checksum error"))
        XCTAssertFalse(FakePool.refusedCache("start or reload service: listen tcp 127.0.0.1:9: bind: address already in use"))
        XCTAssertFalse(FakePool.refusedCache("start or reload service: start inbound/mixed[damaged cache file kept]: listen tcp 127.0.0.1:9: bind: address already in use"))
        XCTAssertFalse(FakePool.refusedCache(""))
    }
}
