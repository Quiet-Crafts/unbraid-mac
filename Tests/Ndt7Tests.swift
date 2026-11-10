import XCTest

final class Ndt7Tests: XCTestCase {
    func testTransportErrorBeforeDurationFailsUnlessServerClosedNormally() {
        XCTAssertTrue(Ndt7.transportFailed(elapsedMs: 3000, normalClose: false))
        XCTAssertFalse(Ndt7.transportFailed(elapsedMs: 3000, normalClose: true))
        XCTAssertFalse(Ndt7.transportFailed(elapsedMs: 9_900, normalClose: false))
        XCTAssertFalse(Ndt7.transportFailed(elapsedMs: 10_000, normalClose: false))
    }
    func testCombinedSamplesUseOnlyTheCommonWindow() throws {
        let samples: [(time: Int64, bytes: Int64)] = [(1000, 100), (2000, 300)]
        XCTAssertEqual(Ndt7.bytesAt(samples, 500), 100)
        XCTAssertEqual(Ndt7.bytesAt(samples, 1250), 150)
        XCTAssertEqual(Ndt7.bytesAt(samples, 1500), 200)
        XCTAssertEqual(Ndt7.bytesAt(samples, 3000), 300)
        let a: [(time: Int64, bytes: Int64)] = [(0, 0), (2000, 4_000_000), (10_000, 6_000_000)]
        let b: [(time: Int64, bytes: Int64)] = [(2000, 0), (8000, 600_000)]
        let result = try XCTUnwrap(Ndt7.combined([a, b]))
        XCTAssertEqual(result.bps, 2_800_000)
        XCTAssertEqual(result.ms, 6000)
    }

    func testCombinedRequiresThreeSecondsAndValidSamples() throws {
        let a: [(time: Int64, bytes: Int64)] = [(0, 0), (5000, 50_000)]
        XCTAssertNil(Ndt7.combined([]))
        XCTAssertNil(Ndt7.combined([a, []]))
        XCTAssertNil(Ndt7.combined([a, [(2001, 0), (5000, 29_990)]]))
        XCTAssertEqual(try XCTUnwrap(Ndt7.combined([a, [(2000, 0), (5000, 30_000)]])).ms, 3000)
        XCTAssertNil(Ndt7.combined([a, [(0, 10), (5000, 5)]]))
        XCTAssertNil(Ndt7.combined([a, [(-1, 0), (5000, 10)]]))
        XCTAssertNil(Ndt7.combined([a, [(0, 0), (5000, Int64.max)]]))
        XCTAssertNil(Ndt7.bytesAt([(0, 0), (0, 1)], 0))
    }

    func testThreeStaggeredCombinedLegs() throws {
        let a: [(time: Int64, bytes: Int64)] = [(0, 0), (10_000, 500_000_000)]
        let b: [(time: Int64, bytes: Int64)] = [(150, 0), (10_150, 250_000_000)]
        let c: [(time: Int64, bytes: Int64)] = [(300, 0), (10_300, 125_000_000)]
        let result = try XCTUnwrap(Ndt7.combined([a, b, c]))
        XCTAssertEqual(result.ms, 9700)
        XCTAssertEqual(result.bps, 700_000_000)
    }
    private let reply = """
    {"results":[{"machine":"mlab1-ams03.mlab-oti.measurement-lab.org","location":{"city":"Amsterdam","country":"NL"},
    "urls":{"wss:///ndt/v7/download":"wss://mlab1-ams03.mlab-oti.measurement-lab.org/ndt/v7/download?access_token=abc",
    "wss:///ndt/v7/upload":"wss://mlab1-ams03.mlab-oti.measurement-lab.org/ndt/v7/upload?access_token=def",
    "ws:///ndt/v7/download":"ws://mlab1-ams03.mlab-oti.measurement-lab.org/ndt/v7/download"}},
    {"machine":"second","location":{"city":"x","country":"NL"},"urls":{}}]}
    """

    func testLocateAsksForTheExitsCountryStrictly() {
        XCTAssertEqual(Ndt7.locatePath(version: "1.9", country: nil), "/v2/nearest/ndt/ndt7?client_name=unbraid&client_version=1.9")
        XCTAssertEqual(Ndt7.locatePath(version: "1.9", country: "NL"), "/v2/nearest/ndt/ndt7?client_name=unbraid&client_version=1.9&country=NL&strict=true")
    }

    func testLocateTakesTheFirstServer() throws {
        let s = try XCTUnwrap(Ndt7.parseLocate(Data(reply.utf8)))
        XCTAssertEqual(s.machine, "mlab1-ams03.mlab-oti.measurement-lab.org")
        XCTAssertEqual(s.city, "Amsterdam")
        XCTAssertEqual(s.country, "NL")
        XCTAssertEqual(s.download, "wss://mlab1-ams03.mlab-oti.measurement-lab.org/ndt/v7/download?access_token=abc")
        XCTAssertEqual(s.upload, "wss://mlab1-ams03.mlab-oti.measurement-lab.org/ndt/v7/upload?access_token=def")
        XCTAssertEqual(s.others.map(\.machine), ["second"])
        XCTAssertEqual(Ndt7.host(s.download), "mlab1-ams03.mlab-oti.measurement-lab.org")
    }

    /// The addresses come from M-Lab's reply: only its own wss servers on the standard port are dialled.
    func testOnlyMLabsOwnServersAreDialled() {
        XCTAssertNotNil(Ndt7.testURL("wss://mlab1-ams03.mlab-oti.measurement-lab.org/ndt/v7/download?access_token=abc"))
        XCTAssertNotNil(Ndt7.testURL("wss://ndt-mlab1-ams03.mlab-oti.measurement-lab.org:443/ndt/v7/upload"))
        XCTAssertNotNil(Ndt7.testURL("wss://server.measurementlab.net/ndt/v7/download"))
        XCTAssertNotNil(Ndt7.testURL("wss://MLAB1.Measurement-Lab.org/ndt/v7/download"))
        for bad in ["", "wss:///ndt/v7/download", "ws://mlab1-ams03.mlab-oti.measurement-lab.org/ndt/v7/download",
                    "https://mlab1-ams03.mlab-oti.measurement-lab.org/ndt/v7/download",
                    "wss://mlab1-ams03.mlab-oti.measurement-lab.org:8443/ndt/v7/download",
                    "wss://example.org/ndt/v7/download", "wss://measurement-lab.org.example.org/ndt/v7/download",
                    "wss://evilmeasurement-lab.org/ndt/v7/download", "wss://router.local/ndt/v7/download",
                    "wss://192.168.1.1/ndt/v7/download"] {
            XCTAssertNil(Ndt7.testURL(bad), bad)
            XCTAssertNil(Ndt7.host(bad), bad)
        }
    }

    func testLocateRateLimit() {
        XCTAssertThrowsError(try Ndt7.locateReply(status: 204, body: Data(), country: "NL")) { XCTAssertTrue($0 is Ndt7.Limited) }
    }

    func testRefusedCandidateFallsBackButOtherErrorsDoNot() async throws {
        let first = try XCTUnwrap(Ndt7.parseLocate(Data(reply.utf8)))
        let (used, value) = try await Ndt7.anyOf(first) { server in
            if server.machine != "second" { throw Ndt7.Refused() }
            return 42
        }
        XCTAssertEqual(used.machine, "second")
        XCTAssertEqual(value, 42)
        do {
            _ = try await Ndt7.anyOf(first) { _ -> Int in throw Fail("failed") }
            XCTFail("Expected the original error")
        } catch { XCTAssertTrue(error is Fail) }
        do {
            _ = try await Ndt7.anyOf(first) { _ -> Int in throw Ndt7.Refused() }
            XCTFail("Expected refusal after all candidates")
        } catch { XCTAssertTrue(error is Ndt7.Refused) }
    }

    func testNoServerIsNilAndAReplyWithoutUrlsIsAnError() throws {
        XCTAssertNil(try Ndt7.parseLocate(Data(#"{"results":[]}"#.utf8)))
        // Only an empty list means none: a reply without one is not an answer.
        XCTAssertThrowsError(try Ndt7.parseLocate(Data(#"{"error":{"title":"No M-Lab servers available"}}"#.utf8)))
        XCTAssertThrowsError(try Ndt7.parseLocate(Data(#"{"results":null}"#.utf8)))
        XCTAssertThrowsError(try Ndt7.parseLocate(Data("{}".utf8)))
        XCTAssertThrowsError(try Ndt7.parseLocate(Data(#"{"results":[{"machine":"m"}]}"#.utf8)))
        XCTAssertThrowsError(try Ndt7.parseLocate(Data("not json".utf8)))
    }

    /// M-Lab's answer for a country without servers, as it came in October 2026 (country=AQ&strict=true).
    private let noneThere = Data(#"{"error":{"type":"nearest","title":"Failed to lookup nearest machines","status":500}}"#.utf8)

    func testOnlyMLabsOwnNoServerAnswerMeansNoneInTheCountry() throws {
        XCTAssertNil(try Ndt7.locateReply(status: 500, body: noneThere, country: "AQ"))
        XCTAssertEqual(try Ndt7.locateReply(status: 200, body: Data(reply.utf8), country: "NL")?.city, "Amsterdam")
        XCTAssertNil(try Ndt7.locateReply(status: 200, body: Data(#"{"results":[]}"#.utf8), country: "NL"))
        // Not held to a country: no server is a failure, not a missing country.
        XCTAssertThrowsError(try Ndt7.locateReply(status: 500, body: noneThere, country: nil))
        // Rate limits, proxies and other failures are failures, whatever the country.
        for status in [403, 404, 429, 502, 503] {
            XCTAssertThrowsError(try Ndt7.locateReply(status: status, body: noneThere, country: "AQ"), "\(status)")
        }
        XCTAssertThrowsError(try Ndt7.locateReply(status: 500, body: Data(#"{"error":{"type":"other"}}"#.utf8), country: "AQ"))
        XCTAssertThrowsError(try Ndt7.locateReply(status: 500, body: Data("<html>Bad gateway</html>".utf8), country: "AQ"))
        XCTAssertThrowsError(try Ndt7.locateReply(status: 200, body: noneThere, country: "AQ"))
    }

    func testPingIsTheMedianWithLowAndHigh() {
        XCTAssertEqual(Ndt7.ping([12, 9, 300, 11, 10]), Ndt7.Ping(median: 11, low: 9, high: 300))
        XCTAssertEqual(Ndt7.ping([0, 0, 5, 0, 0]), Ndt7.Ping(median: 1, low: 1, high: 5)) // never reads 0 ms
    }

    func testTheUploadRateIsWhatTheServerReceived() {
        let m = #"{"ConnectionInfo":{"Client":"1.2.3.4:5","UUID":"x"},"TCPInfo":{"BytesReceived":1250000,"ElapsedTime":1000000,"RTT":12}}"#
        XCTAssertEqual(Ndt7.serverRate(m), 10_000_000)
        XCTAssertNil(Ndt7.serverRate(#"{"ConnectionInfo":{},"BytesReceived":5,"ElapsedTime":9}"#))
        XCTAssertNil(Ndt7.serverRate(#"{"BytesReceived":5,"TCPInfo":{"ElapsedTime":10}}"#)) // before TCPInfo doesn't count
        XCTAssertNil(Ndt7.serverRate(#"{"TCPInfo":{"BytesReceived":5,"ElapsedTime":0}}"#))
        XCTAssertNil(Ndt7.serverRate("{}"))
    }

    func testRates() {
        XCTAssertEqual(Ndt7.bitsPerSecond(bytes: 1_250_000, ms: 1000), 10_000_000)
        XCTAssertEqual(Ndt7.bitsPerSecond(bytes: 100, ms: 0), 800_000) // a zero interval counts as 1 ms
        XCTAssertEqual(Ndt7.bitsPerSecond(bytes: 0, ms: 5000), 0)
    }

    /// A server that sends one frame and closes normally: 8 KiB in 1 ms is not 65 Mbps, it is no measurement.
    func testADownloadEndedWithinASecondHasNoRate() {
        XCTAssertNil(Ndt7.downloadRate(bytes: 8192, ms: 1))
        XCTAssertNil(Ndt7.downloadRate(bytes: 8192, ms: 0))
        XCTAssertNil(Ndt7.downloadRate(bytes: 1_000_000, ms: 999))
        XCTAssertEqual(Ndt7.downloadRate(bytes: 125_000, ms: 1000), 1_000_000)
        XCTAssertEqual(Ndt7.downloadRate(bytes: 12_500_000, ms: 10_000), 10_000_000)
    }

    func testByteCaps() {
        XCTAssertEqual(Ndt7.maxMessage, 1 << 20)
        XCTAssertEqual(Ndt7.maxData, 1 << 25)
        XCTAssertEqual(Ndt7.downloadCap, 13)
        XCTAssertTrue(Ndt7.frameOk(text: true, length: 400))
        XCTAssertTrue(Ndt7.frameOk(text: true, length: 1 << 20))
        XCTAssertFalse(Ndt7.frameOk(text: true, length: (1 << 20) + 1))
        XCTAssertTrue(Ndt7.frameOk(text: false, length: 1 << 24))
        XCTAssertTrue(Ndt7.frameOk(text: false, length: 1 << 25))
        XCTAssertFalse(Ndt7.frameOk(text: false, length: (1 << 25) + 1))
        XCTAssertFalse(Ndt7.frameOk(text: false, length: -1))
    }

    func testUploadMessagesGrowWithWhatWasSent() {
        let buffer = 1 << 20
        var size = 1 << 13, sent: Int64 = 0, sends = 0, firstDoubling = 0
        while size < buffer {
            sent += Int64(size)
            sends += 1
            let next = Ndt7.nextSize(size, sent: sent, buffer: buffer)
            if next != size, firstDoubling == 0 { firstDoubling = sends }
            XCTAssertTrue(next == size || next == size * 2)
            size = next
        }
        XCTAssertEqual(firstDoubling, 17) // 8 KiB stays until it is under a sixteenth of the total
        XCTAssertEqual(Ndt7.nextSize(buffer, sent: .max / 2, buffer: buffer), buffer) // never past the buffer
    }

    func testUserAgentNamesTheVersion() { XCTAssertEqual(Ndt7.userAgent("1.9"), "unbraid/1.9") }

    /// Speeds read as speed tests print them: megabits (not megabytes), decimal (not 1024).
    func testSpeedsAreDecimalMegabits() {
        let bps = Ndt7.bitsPerSecond(bytes: 47_000_000, ms: 1000) // 47 MB in a second
        XCTAssertEqual(StatsMath.mbps(bps), "376")
        XCTAssertTrue(StatsMath.rate(99_400_000) == ("99.4", "Mbps"))
        XCTAssertTrue(StatsMath.rate(250_000) == ("250", "kbps"))
    }

    /// The upload's window of four sends: a server that stops reading leaves all four pending, and only the deadline's
    /// failure frees the sender (SpeedTest's upload cap).
    func testAStalledUploadIsReleasedByItsDeadline() async {
        let window = InFlight(4)
        for _ in 0..<4 { await window.take() }
        let sender = Task { await window.take(); return window.error }
        try? await Task.sleep(for: .milliseconds(50))
        window.put(Fail("Upload past its time"))
        let error = await sender.value
        XCTAssertTrue(error is Fail)
        // After it every take returns at once, and late completions change nothing.
        await window.take()
        window.put(nil)
        window.put(URLError(.cancelled))
        XCTAssertTrue(window.error is Fail)
    }
    func testConcurrentTagAndServerClockSample() throws {
        let url = try XCTUnwrap(Ndt7.concurrentURL("wss://example.org/ndt?x=1", count: 3))
        let query = try XCTUnwrap(URLComponents(string: url)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "concurrent" }?.value, "3")
        XCTAssertNil(query.first { $0.name == "run" })
        XCTAssertNil(Ndt7.concurrentURL("wss://example.org/ndt", count: 11))
        let sample = try XCTUnwrap(Ndt7.serverSample("{\"TCPInfo\":{\"BytesReceived\":1200,\"ElapsedTime\":2000000}}"))
        XCTAssertEqual(sample.bytes, 1200); XCTAssertEqual(sample.us, 2000000)
    }

    func testParallelDecisionsAndDailyReservations() {
        XCTAssertTrue(Ndt7.includeInParallel(hasServer: true, missing: false, limited: false, failed: false, useNearest: false))
        XCTAssertFalse(Ndt7.includeInParallel(hasServer: true, missing: true, limited: false, failed: false, useNearest: false))
        XCTAssertTrue(Ndt7.includeInParallel(hasServer: true, missing: true, limited: false, failed: false, useNearest: true))
        XCTAssertFalse(Ndt7.includeInParallel(hasServer: false, missing: true, limited: false, failed: false, useNearest: true))
        XCTAssertFalse(Ndt7.includeInParallel(hasServer: true, missing: false, limited: true, failed: false, useNearest: true))
        XCTAssertFalse(Ndt7.includeInParallel(hasServer: true, missing: false, limited: false, failed: true, useNearest: true))
        XCTAssertTrue(Ndt7.canReserveParallel(2, used: 38, limit: 40))
        XCTAssertFalse(Ndt7.canReserveParallel(3, used: 38, limit: 40))
        XCTAssertFalse(Ndt7.canReserveParallel(1, used: 0, limit: 40))
        XCTAssertFalse(Ndt7.canReserveParallel(11, used: 0, limit: 40))
    }

    func testParallelDiscardsChangedRoute() {
        func same(_ running: Bool = true, _ tag: String? = "t", _ id: String = "route@old", _ ip: String? = "1.2.3.4") -> Bool {
            Ndt7.sameRoute(running: running, originalTag: "t", tag: tag, originalID: "route@old", id: id, originalIP: "1.2.3.4", ip: ip)
        }
        XCTAssertTrue(same())
        XCTAssertFalse(same(false)); XCTAssertFalse(same(true, nil)); XCTAssertFalse(same(true, "other"))
        XCTAssertFalse(same(true, "t", "route@new")); XCTAssertFalse(same(true, "t", "route@old", "5.6.7.8"))
        XCTAssertTrue(Ndt7.sameRoute(running: true, originalTag: "t", tag: "t", originalID: "r", id: "r", originalIP: "", ip: nil))
    }

    func testFailedPingDoesNotPreventTryingOtherCandidates() async throws {
        let first = try XCTUnwrap(Ndt7.parseLocate(Data(reply.utf8)))
        let ping = try await Ndt7.optionalPing { throw Fail("ping failed") }
        XCTAssertNil(ping)
        let (used, _) = try await Ndt7.anyOf(first) { server in
            if server.machine != "second" { throw Ndt7.Refused() }
            return 1
        }
        XCTAssertEqual(used.machine, "second")
        do {
            _ = try await Ndt7.optionalPing { throw CancellationError() }
            XCTFail("Cancellation must stop the test")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

}
