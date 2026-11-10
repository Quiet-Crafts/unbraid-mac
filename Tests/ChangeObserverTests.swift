import Observation
import XCTest

final class ChangeObserverTests: XCTestCase {
    @MainActor @Observable final class Source {
        var setup = 0
        var accounts = 0
        var suffix = ""
        var catalog = 0
        var phase = 0
        var values: [String] { [String(setup), String(accounts), suffix, String(catalog), String(phase)] }
    }

    @MainActor func testEditsDuringSuspensionAreSerializedAndReadAfterMutation() async {
        let source = Source()
        let (starts, started) = AsyncStream<[String]>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        var runs = starts.makeAsyncIterator()
        var active = 0, maximum = 0
        let observer = ChangeObserver(read: { _ = source.values }, reconcile: {
            active += 1; maximum = max(maximum, active)
            started.yield(source.values)
            await withCheckedContinuation { release = $0 }
            active -= 1
        })
        observer.start()
        let first = await runs.next()
        XCTAssertEqual(first, ["0", "0", "", "0", "0"])
        source.setup = 1; source.accounts = 2; source.suffix = "tail.example"; source.catalog = 3; source.phase = 4
        // Let the observation callback rearm while the first reconcile remains suspended.
        for _ in 0..<10 { await Task.yield() }
        release?.resume(); release = nil
        let next = await runs.next()
        XCTAssertEqual(next, ["1", "2", "tail.example", "3", "4"])
        XCTAssertEqual(maximum, 1)
        observer.stop()
        release?.resume()
    }

    @MainActor func testStopInvalidatesQueuedCallbacksAndRestartReadsCurrentInputs() async {
        let source = Source()
        let (stream, post) = AsyncStream<Int>.makeStream()
        var runs = stream.makeAsyncIterator()
        let observer = ChangeObserver(read: { _ = source.setup }, reconcile: { post.yield(source.setup) })
        observer.start()
        let first = await runs.next()
        XCTAssertEqual(first, 0)
        source.setup = 1
        observer.stop() // its pre-mutation callback is still queued on MainActor
        source.setup = 2
        observer.start()
        let restarted = await runs.next()
        XCTAssertEqual(restarted, 2)
        observer.stop()
        for _ in 0..<10 { await Task.yield() }
        post.finish()
        let extra = await runs.next()
        XCTAssertNil(extra)
    }

    @MainActor func testEveryDependencyRearmsObservation() async {
        let source = Source()
        let (stream, post) = AsyncStream<[String]>.makeStream()
        var runs = stream.makeAsyncIterator()
        let observer = ChangeObserver(read: { _ = source.values }, reconcile: { post.yield(source.values) })
        observer.start()
        _ = await runs.next()
        for edit in [{ source.setup += 1 }, { source.accounts += 1 }, { source.suffix = "new" },
                     { source.catalog += 1 }, { source.phase += 1 }] {
            edit()
            let next = await runs.next()
            XCTAssertEqual(next, source.values)
        }
        observer.stop()
    }
    @MainActor func testIdleObserverDoesNotPollAndWakesForNextSwitch() async throws {
        let source = Source()
        let (stream, post) = AsyncStream<Int>.makeStream()
        var runs = stream.makeAsyncIterator()
        var count = 0
        let observer = ChangeObserver(read: { _ = source.setup }, reconcile: {
            count += 1
            post.yield(source.setup)
        })
        observer.start()
        _ = await runs.next()
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(count, 1)
        source.setup = 1
        let switched = await runs.next()
        XCTAssertEqual(switched, 1)
        source.setup = 0
        _ = await runs.next()
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(count, 3)
        source.setup = 2
        let next = await runs.next()
        XCTAssertEqual(next, 2)
        observer.stop()
    }

}
