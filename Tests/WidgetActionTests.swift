import XCTest

/// A widget button's request as the widget extension hands it over, against a stand-in for the app taking it.
final class WidgetActionTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appending(path: "widget-action") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "widget-action-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// What is left in the folder, but a press's "failed" answer: kept (until swept) so the app can't take that press
    /// later, it acts on nothing.
    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter {
            !$0.hasPrefix("widget-action.answer.") || (try? String(contentsOf: dir.appending(path: $0), encoding: .utf8)) != "failed"
        }.sorted()
    }

    func testARequestNobodyTakesFailsAndLeavesNothingForALaterLaunch() async throws {
        var posted = 0
        let start = ContinuousClock.now
        let handed = await WidgetAction.hand("connect", to: file, wait: .milliseconds(300)) { posted += 1 }
        XCTAssertEqual(handed, .notTaken)
        XCTAssertEqual(posted, 1)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(300))
        XCTAssertEqual(try leftovers(), [])
        XCTAssertNil(WidgetAction.take(from: file))
    }

    func testARequestTheAppTakesSucceedsAndTheAppHasIt() async throws {
        let file = file
        let app = Task.detached { () -> String? in
            try? await Task.sleep(for: .milliseconds(100))
            return WidgetAction.take(from: file)
        }
        let handed = await WidgetAction.hand("pause", to: file, wait: .seconds(2)) {}
        let taken = await app.value
        XCTAssertEqual(handed, .taken)
        XCTAssertEqual(taken, "pause")
        XCTAssertEqual(try leftovers(), [])
    }

    /// The app and the widget taking it back at the same moment: exactly one of them has it.
    func testTheAppAndTheWidgetCantBothHaveARequest() async throws {
        let file = file
        for _ in 0..<50 {
            let app = Task.detached { () -> String? in
                try? await Task.sleep(for: .milliseconds(Int.random(in: 0...30)))
                return WidgetAction.take(from: file)
            }
            let handed = await WidgetAction.hand("connect", to: file, wait: .milliseconds(15)) {}
            let taken = await app.value
            XCTAssertEqual(handed == .taken, taken == "connect", "\(handed) \(String(describing: taken))")
            XCTAssertEqual(try leftovers(), [])
        }
    }

    /// Two presses before anyone takes either: neither is acted on, the first only replaced (no error of its own), and
    /// nothing is left for a later launch.
    func testTwoPressesNobodyTakesBothFail() async throws {
        let file = file
        let first = Task.detached { await WidgetAction.hand("connect", to: file, wait: .milliseconds(400)) {} }
        try await Task.sleep(for: .milliseconds(100))
        let second = await WidgetAction.hand("pause", to: file, wait: .milliseconds(400)) {}
        let firstHanded = await first.value
        XCTAssertEqual(firstHanded, .superseded)
        XCTAssertEqual(second, .notTaken)
        XCTAssertEqual(try leftovers(), [])
        XCTAssertNil(WidgetAction.take(from: file))
    }

    /// The app takes the second press, which replaced the first: only the second reports success.
    func testOnlyThePressTheAppTookSucceeds() async throws {
        let file = file
        let first = Task.detached { await WidgetAction.hand("connect", to: file, wait: .milliseconds(500)) {} }
        try await Task.sleep(for: .milliseconds(100))
        let app = Task.detached { () -> String? in
            try? await Task.sleep(for: .milliseconds(200))
            return WidgetAction.take(from: file)
        }
        let second = await WidgetAction.hand("pause", to: file, wait: .seconds(2)) {}
        let firstHanded = await first.value, taken = await app.value
        XCTAssertEqual(taken, "pause")
        XCTAssertEqual(second, .taken)
        XCTAssertEqual(firstHanded, .notTaken)
        XCTAssertEqual(try leftovers(), [])
    }

    /// The app took the first press before a second one was written: the first still succeeds.
    func testAPressTakenBeforeALaterOneSucceeds() async throws {
        let file = file
        let first = Task.detached { await WidgetAction.hand("connect", to: file, wait: .milliseconds(500)) {} }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(WidgetAction.take(from: file), "connect")
        let second = await WidgetAction.hand("pause", to: file, wait: .milliseconds(300)) {}
        let firstHanded = await first.value
        XCTAssertEqual(firstHanded, .taken)
        XCTAssertEqual(second, .notTaken)
        XCTAssertEqual(try leftovers(), [])
    }

    /// A folder that stopped taking changes (here: made read-only as soon as the request is out) fails the press; the
    /// app can't take the request from it either. Once it takes changes again, the request is still there, unanswered,
    /// but the app takes it only while it is under 3 seconds old.
    func testARequestThatCantBeTakenBackFails() async throws {
        let dir = dir!
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        let handed = await WidgetAction.hand("connect", to: file, wait: .milliseconds(300)) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int, 0o500)
        XCTAssertEqual(handed, .notTaken)
        XCTAssertNil(WidgetAction.take(from: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let written = try XCTUnwrap(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["widget-action"])
        XCTAssertNil(WidgetAction.take(from: file, now: written.addingTimeInterval(3.5)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    /// The app's answer for a press stays until its widget reads it; a request whose id isn't a press's is refused.
    func testATakenPressIsAnsweredAndABadIdRefused() throws {
        let id = UUID().uuidString
        XCTAssertTrue(WidgetAction.send("pause", press: id, to: file) {})
        XCTAssertEqual(WidgetAction.take(from: file), "pause")
        XCTAssertEqual(try leftovers(), ["widget-action.answer.\(id)"])
        XCTAssertEqual(try String(contentsOf: dir.appending(path: "widget-action.answer.\(id)"), encoding: .utf8), "taken")
        try Data("pause\n../../x".utf8).write(to: file)
        XCTAssertNil(WidgetAction.take(from: file))
        XCTAssertEqual(try leftovers(), ["widget-action.answer.\(id)"])
    }

    /// A press its widget settled as failed while the request still sat in the slot: the app doesn't act on it.
    func testAPressItsWidgetGaveUpOnIsNotTaken() throws {
        let id = UUID().uuidString
        XCTAssertTrue(WidgetAction.send("connect", press: id, to: file) {})
        try Data("failed".utf8).write(to: dir.appending(path: "widget-action.answer.\(id)"))
        XCTAssertNil(WidgetAction.take(from: file))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    /// A widget giving up on a press while a request from the app's own process sits in the slot: it is put back and
    /// the app woken again, since the app may have looked while the slot was briefly empty.
    func testARequestTakenBackByMistakeIsPutBackAndTheAppWokenAgain() async throws {
        let file = file
        var posted = 0
        let inApp = Task.detached {
            try? await Task.sleep(for: .milliseconds(100))
            WidgetAction.send("pause", to: file) {}
        }
        let handed = await WidgetAction.hand("connect", to: file, wait: .milliseconds(300)) { posted += 1 }
        await inApp.value
        XCTAssertEqual(handed, .superseded)
        XCTAssertEqual(posted, 2)
        XCTAssertEqual(WidgetAction.take(from: file), "pause")
    }

    /// Something that isn't a request replaced the press: not counted as a later press, and never acted on.
    func testAPressReplacedByNoRequestFails() async throws {
        let file = file
        for text in ["pause\nnot-an-id", "garbage", "", "connect\n\(UUID().uuidString)\nmore"] {
            let junk = Task.detached {
                try? await Task.sleep(for: .milliseconds(100))
                try? Data(text.utf8).write(to: file)
            }
            let handed = await WidgetAction.hand("connect", to: file, wait: .milliseconds(300)) {}
            await junk.value
            XCTAssertEqual(handed, .notTaken, text)
            XCTAssertNil(WidgetAction.take(from: file), text)
        }
    }

    /// The press's request, read from the slot: its id names its answer.
    private func pressInSlot() throws -> String {
        try XCTUnwrap(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").last.map(String.init))
    }

    /// The app claimed the first press, then a second one filled the slot. The first's widget settles first: the app
    /// can't act on it, and the first reports it was replaced. The app settles first: the first succeeds.
    func testAPressTheAppHoldsWhileALaterOneWaits() async throws {
        let file = file
        for appFirst in [false, true] {
            let first = Task.detached { await WidgetAction.hand("connect", to: file, wait: .milliseconds(400)) {} }
            try await Task.sleep(for: .milliseconds(100))
            let id = try pressInSlot()
            // The app's claim, and a later press's request.
            try FileManager.default.moveItem(at: file, to: dir.appending(path: "widget-action.\(UUID().uuidString)"))
            XCTAssertTrue(WidgetAction.send("pause", press: UUID().uuidString, to: file) {})
            // The app's settle, when it comes first.
            if appFirst { try Data("taken".utf8).write(to: dir.appending(path: "widget-action.answer.\(id)")) }
            let handed = await first.value
            XCTAssertEqual(handed, appFirst ? .taken : .superseded)
            if !appFirst {
                XCTAssertEqual(try String(contentsOf: dir.appending(path: "widget-action.answer.\(id)"), encoding: .utf8), "failed")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the later press is back in the slot")
            try FileManager.default.contentsOfDirectory(atPath: dir.path).forEach { try FileManager.default.removeItem(at: dir.appending(path: $0)) }
        }
    }

    /// An older request put back in the slot by another press's widget isn't a later press: the press fails.
    func testAnOlderRequestPutBackIsNotALaterPress() async throws {
        let file = file
        let first = Task.detached { await WidgetAction.hand("connect", to: file, wait: .milliseconds(400)) {} }
        try await Task.sleep(for: .milliseconds(100))
        // Another widget claimed it, and put back an earlier press of its own.
        try FileManager.default.moveItem(at: file, to: dir.appending(path: "widget-action.\(UUID().uuidString)"))
        XCTAssertTrue(WidgetAction.send("pause", press: UUID().uuidString, to: file) {})
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-1)], ofItemAtPath: file.path)
        let handed = await first.value
        XCTAssertEqual(handed, .notTaken)
    }

    /// A press cancelled while it waits is settled at once, and the app can't take it afterwards.
    func testACancelledPressFailsForGood() async throws {
        let file = file
        let press = Task.detached { await WidgetAction.hand("connect", to: file, wait: .seconds(5)) {} }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        press.cancel()
        let handed = await press.value
        XCTAssertEqual(handed, .notTaken)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        XCTAssertNil(WidgetAction.take(from: file))
        XCTAssertEqual(try leftovers(), [])
    }

    /// Only small regular files are read: a link, a pipe or a huge file in the slot is not a request, and is dropped
    /// without hanging or filling the reader.
    func testOnlyASmallRegularFileIsARequest() throws {
        let real = dir.appending(path: "elsewhere")
        try Data("connect".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: real)
        XCTAssertNil(WidgetAction.take(from: file))
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "connect", "the link's target is left alone")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        XCTAssertNil(WidgetAction.take(from: file))
        // A pipe nobody writes to: read in the background, so a reader that waits on it fails here instead of hanging.
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        let done = DispatchSemaphore(value: 0), file = file
        nonisolated(unsafe) var taken: String? = "unset"
        Thread { taken = WidgetAction.take(from: file); done.signal() }.start()
        guard done.wait(timeout: .now() + 3) == .success else { return XCTFail("reading a pipe hung") }
        XCTAssertNil(taken)
        // A huge (sparse) file.
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("connect".utf8)))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1 << 32)
        try handle.close()
        let start = ContinuousClock.now
        XCTAssertNil(WidgetAction.take(from: file))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5), "a huge file was read")
        XCTAssertEqual(try leftovers(), ["elsewhere"])
    }

    /// A press's answer is read on the same terms: "taken" through a link is no answer, and the press fails.
    func testAnAnswerThroughALinkIsNoAnswer() async throws {
        let file = file, dir = dir!
        let real = dir.appending(path: "elsewhere")
        try Data("taken".utf8).write(to: real)
        var planted = false
        // As soon as the request is out, its answer's name is a link to "taken".
        let handed = await WidgetAction.hand("connect", to: file, wait: .milliseconds(300)) {
            guard let text = try? String(contentsOf: file, encoding: .utf8), let id = text.split(separator: "\n").last else { return }
            planted = (try? FileManager.default.createSymbolicLink(at: dir.appending(path: "widget-action.answer.\(id)"), withDestinationURL: real)) != nil
        }
        XCTAssertTrue(planted)
        XCTAssertEqual(handed, .notTaken)
    }

    func testLeftoversOlderThanTenMinutesAreSwept() throws {
        let old = dir.appending(path: "widget-action.answer.\(UUID().uuidString)"), recent = dir.appending(path: "widget-action.\(UUID().uuidString)")
        try Data().write(to: old); try Data().write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-700)], ofItemAtPath: old.path)
        XCTAssertNil(WidgetAction.take(from: file))
        XCTAssertEqual(try leftovers(), [recent.lastPathComponent])
    }

    /// Run in the app, a button's request is only written: read at once, or at launch while fresh.
    func testARequestSentWithoutAPressIsReadAsItsAction() {
        XCTAssertTrue(WidgetAction.send("pause", to: file) {})
        XCTAssertEqual(WidgetAction.take(from: file), "pause")
    }

    func testNoContainerSendsNothing() async {
        var posted = false
        let handed = await WidgetAction.hand("connect", to: nil) { posted = true }
        XCTAssertEqual(handed, .notWritten)
        XCTAssertFalse(posted)
    }

    /// A press from the widget extension: only while its widget may still be waiting for it, give or take a second.
    func testOnlyAPressWrittenInTheLastThreeSecondsIsTaken() throws {
        let now = Date()
        for (age, fresh) in [(0.0, true), (2.9, true), (3.0, false), (4.0, false), (9.5, false), (-0.5, false)] {
            let id = UUID().uuidString
            XCTAssertTrue(WidgetAction.send("connect", press: id, to: file) {})
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
            XCTAssertEqual(WidgetAction.take(from: file, now: now), fresh ? "connect" : nil, "age \(age)")
            // Taken: answered for its widget. Too old: removed, and nothing answered.
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), fresh ? ["widget-action.answer.\(id)"] : [], "age \(age)")
            try? FileManager.default.removeItem(at: dir.appending(path: "widget-action.answer.\(id)"))
        }
    }

    func testOnlyARequestWrittenInTheLastTenSecondsIsTaken() throws {
        let now = Date()
        for (age, fresh) in [(0.0, true), (9.5, true), (10.0, false), (10.5, false), (-0.5, false), (-60, false), (3600, false)] {
            XCTAssertTrue(WidgetAction.send("connect", to: file) {})
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
            XCTAssertEqual(WidgetAction.take(from: file, now: now), fresh ? "connect" : nil, "age \(age)")
            XCTAssertEqual(try leftovers(), [], "a request \(age) s old is removed, taken or not")
        }
        XCTAssertNil(WidgetAction.take(from: file, now: now))
    }
}
