import XCTest

private actor ProbeCalls {
    var active = 0
    var peak = 0
    var calls: [String: [String]] = [:]
    func start(_ tag: String, _ host: String) {
        active += 1; peak = max(peak, active)
        calls[tag, default: []].append(host)
    }
    func finish() { active -= 1 }
}

final class ExitProbeTests: XCTestCase {
    func testConcurrencyAndFallback() async {
        let calls = ProbeCalls()
        let tags = Set((0..<9).map(String.init))
        let answers = await ExitProbe.ask(tags) { tag, host in
            await calls.start(tag, host)
            try? await Task.sleep(for: .milliseconds(10))
            await calls.finish()
            return host == ExitProbe.hosts[1] ? "192.0.2.1" : nil
        }
        let peak = await calls.peak
        let seen = await calls.calls
        XCTAssertEqual(answers.count, 9)
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertEqual(seen.count, 9)
        for hosts in seen.values { XCTAssertEqual(hosts, ExitProbe.hosts) }
    }

    func testDeadlineCoversBothHosts() async {
        let calls = ProbeCalls()
        // The first host answers at once with nothing, the second only after the deadline: one deadline covers both,
        // without depending on how fast the machine running the tests is.
        let answers = await ExitProbe.ask(["one"], timeout: .milliseconds(200)) { tag, host in
            await calls.start(tag, host)
            guard host == ExitProbe.hosts[1] else { await calls.finish(); return nil }
            do { try await Task.sleep(for: .seconds(5)) } catch { await calls.finish(); return nil }
            await calls.finish()
            return "192.0.2.1"
        }
        let hosts = await calls.calls["one"]
        XCTAssertTrue(answers.isEmpty)
        XCTAssertEqual(hosts, ExitProbe.hosts)
    }
}
