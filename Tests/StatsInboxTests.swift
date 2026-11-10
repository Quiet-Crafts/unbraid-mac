import XCTest

final class StatsInboxTests: XCTestCase {
    func testBackpressurePreservesDeltasAndBatchBoundaries() async {
        let inbox = StatsInbox(capacity: 2)
        DispatchQueue.global().async {
            for i in 0..<200 {
                let e = Ledger.Ev(kind: .update, id: "\(i)", delta: Traffic(up: 2, down: 3), path: "", closed: false, created: 0, own: false)
                inbox.send(.events(gen: 0, [e], reset: i == 0))
                inbox.send(.status(gen: 0))
            }
        }
        var ids: [String] = [], bytes: Int64 = 0, resets = 0
        for await _ in inbox.wakeups {
            while let message = inbox.next() {
                if case .events(_, let events, let reset) = message {
                    ids += events.map(\.id)
                    bytes += events.reduce(0) { $0 + $1.delta.total }
                    if reset { resets += 1 }
                }
            }
            if ids.count == 200 { break }
        }
        XCTAssertEqual(ids, (0..<200).map(String.init))
        XCTAssertEqual(bytes, 1000)
        XCTAssertEqual(resets, 1)
    }

    func testCoalescesControlsAndDropsOldGenerations() {
        let inbox = StatsInbox()
        for _ in 0..<1000 { inbox.send(.status(gen: 0)) }
        guard case .status(0) = inbox.next() else { return XCTFail("Missing status") }
        XCTAssertNil(inbox.next())
        inbox.advance(to: 1)
        inbox.send(.events(gen: 0, [], reset: true))
        inbox.send(.status(gen: 0))
        inbox.send(.retry(gen: 1))
        guard case .retry(1) = inbox.next() else { return XCTFail("Missing current retry") }
        XCTAssertNil(inbox.next())
    }

    func testGenerationChangeReleasesBlockedProducer() async {
        let inbox = StatsInbox(capacity: 1)
        inbox.send(.events(gen: 0, [], reset: false))
        let done = expectation(description: "Producer released")
        DispatchQueue.global().async {
            inbox.send(.events(gen: 0, [], reset: false))
            done.fulfill()
        }
        inbox.advance(to: 1)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNil(inbox.next())
    }
}
