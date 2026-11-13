import Synchronization
import XCTest

final class UpdateCheckTests: XCTestCase {
    private typealias V = UpdateCheck.Version

    private func answer(_ json: String) -> V? { UpdateCheck.parse(Data(json.utf8)) }

    func testVersionsCompareByNumberNotText() throws {
        let v = { (s: String) in try XCTUnwrap(V(s)) }
        XCTAssertLessThan(try v("1.0.0"), try v("1.1.0"))
        XCTAssertLessThan(try v("1.9.0"), try v("1.10.0"))
        XCTAssertLessThan(try v("1.0.9"), try v("1.1"))
        XCTAssertLessThan(try v("2.0"), try v("10.0"))
        XCTAssertEqual(try v("1.1"), try v("1.1.0"))
        XCTAssertEqual(try v("1.1"), try v("1.1.0.0"))
        XCTAssertEqual(Set([try v("1.1"), try v("1.1.0")]).count, 1)
        XCTAssertFalse(try v("1.1.0") < v("1.1"))
        XCTAssertEqual(try v("1.10.3").description, "1.10.3")
    }

    func testOnlyPlainReleaseNumbersAreVersions() {
        for bad in ["", "1", "1.", ".1", "1..0", "1.0.0.0.0", "1.0.0-beta", "1.1.0-rc1", "1.1.0+5", "v1.1.0", " 1.1.0", "1.1.0 ",
                    "1.1.0\n", "-1.0", "+1.0", "1.0001", "1000.0", "01.0", "1.00", "1.0x", "١.٢", "１.２", "1,2", "0x1.0", "1.e3"] {
            XCTAssertNil(V(bad), bad)
        }
        for good in ["0.1", "1.0", "1.0.0", "1.2.3.4", "999.999.999", "10.0"] { XCTAssertNotNil(V(good), good) }
    }

    func testAnswerIsReadStrictly() {
        XCTAssertEqual(answer(#"{"versionName": "1.1.0"}"#), V("1.1.0"))
        XCTAssertEqual(answer(#"{"versionCode": 3, "versionName": "1.2", "url": "https://elsewhere.example/x.dmg"}"#), V("1.2"))
        // Wrong types, wrong shapes, pre-release tags and garbage are no answer.
        for bad in [#"{"versionName": 110}"#, #"{"versionName": ["1.1.0"]}"#, #"{"versionName": null}"#, #"{"versionName": true}"#,
                    #"{"version": "1.1.0"}"#, #"["1.1.0"]"#, #""1.1.0""#, "1.1.0", #"{"versionName": "1.1.0-beta"}"#,
                    #"{"versionName": "1.1.0"#, "", "<html>Not found</html>", #"{"versionName": "1.1.0\u0000"}"#,
                    #"{"versionName": {"major": 1}}"#] {
            XCTAssertNil(answer(bad), bad)
        }
        XCTAssertNil(UpdateCheck.parse(Data([0xFF, 0xFE, 0x00])))
    }

    func testOversizedAnswerIsRefused() {
        let padding = String(repeating: " ", count: UpdateCheck.maxBytes)
        XCTAssertNil(answer(#"{"versionName": "1.1.0"}"# + padding))
        let fits = #"{"versionName": "1.1.0"}"#
        XCTAssertEqual(answer(fits + String(repeating: " ", count: UpdateCheck.maxBytes - fits.utf8.count)), V("1.1.0"))
    }

    func testOnlyANewerReleaseIsOffered() {
        var s = UpdateCheck.State(enabled: true)
        let installed = V("1.1.0")
        s.latest = "1.2.0"
        XCTAssertEqual(UpdateCheck.newer(s, installed: installed), V("1.2.0"))
        s.latest = "1.1"
        XCTAssertNil(UpdateCheck.newer(s, installed: installed), "the same release")
        s.latest = "1.0.0"
        XCTAssertNil(UpdateCheck.newer(s, installed: installed), "an older release never prompts a downgrade")
        s.latest = "1.2.0-beta"
        XCTAssertNil(UpdateCheck.newer(s, installed: installed))
        s.latest = "9.9.9"
        XCTAssertNil(UpdateCheck.newer(s, installed: nil), "an unreadable installed version is never offered anything")
        s.latest = nil
        XCTAssertNil(UpdateCheck.newer(s, installed: installed))
    }

    func testNoticeShowsWhileOnUntilClosedForThatRelease() {
        let installed = V("1.1.0")
        var s = UpdateCheck.State(enabled: true, latest: "1.2.0")
        XCTAssertTrue(UpdateCheck.showNotice(s, installed: installed))
        s.dismissed = "1.2.0"
        XCTAssertFalse(UpdateCheck.showNotice(s, installed: installed))
        s.latest = "1.2.1"
        XCTAssertTrue(UpdateCheck.showNotice(s, installed: installed), "a newer release than the closed one shows again")
        s.dismissed = "2.0"
        XCTAssertFalse(UpdateCheck.showNotice(s, installed: installed))
        s = UpdateCheck.State(enabled: false, latest: "1.2.0")
        XCTAssertFalse(UpdateCheck.showNotice(s, installed: installed), "off shows nothing")
    }

    func testAtMostOnceADayAndAnHourAfterAFailure() {
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        var s = UpdateCheck.State()
        XCTAssertFalse(UpdateCheck.due(s, now: t0), "off is never due")
        s.enabled = true
        XCTAssertTrue(UpdateCheck.due(s, now: t0), "never tried")
        s.lastAttempt = t0
        XCTAssertFalse(UpdateCheck.due(s, now: t0))
        XCTAssertFalse(UpdateCheck.due(s, now: t0 + 3600))
        XCTAssertFalse(UpdateCheck.due(s, now: t0 + 86_399))
        XCTAssertTrue(UpdateCheck.due(s, now: t0 + 86_400))
        s.failed = true
        XCTAssertFalse(UpdateCheck.due(s, now: t0 + 3599))
        XCTAssertTrue(UpdateCheck.due(s, now: t0 + 3600))
        s.failed = false
        XCTAssertTrue(UpdateCheck.due(s, now: t0 - 60), "a clock set back doesn't hold checks off")
    }

    func testRecordKeepsTheLastGoodAnswerAfterAFailure() {
        var s = UpdateCheck.State(enabled: true)
        s = UpdateCheck.record(s, answer: V("1.2.0"))
        XCTAssertEqual(s.latest, "1.2.0")
        XCTAssertFalse(s.failed)
        s = UpdateCheck.record(s, answer: nil)
        XCTAssertEqual(s.latest, "1.2.0")
        XCTAssertTrue(s.failed)
        s = UpdateCheck.record(s, answer: V("1.1"))
        XCTAssertEqual(s.latest, "1.1", "a valid answer replaces what was known")
    }

    func testOnlyTheReleasePageIsEverOpened() throws {
        XCTAssertTrue(UpdateCheck.isReleasePage(try XCTUnwrap(URL(string: UpdateCheck.releasePage))))
        for bad in ["http://unbraid.app/download/", "https://unbraid.app.example.com/download/", "https://example.com/download/",
                    "https://unbraid.app:8443/download/", "https://user@unbraid.app/download/", "https://unbraid.app/download/x.dmg",
                    "https://unbraid.app/download/?u=https://example.com", "https://unbraid.app/", "file:///Applications/unbraid.app",
                    "https://github.com/someone/else/releases/latest", "https://unbraid.app/download/../../evil", "https://UNBRAID.APP.evil/download/"] {
            XCTAssertFalse(UpdateCheck.isReleasePage(try XCTUnwrap(URL(string: bad))), bad)
        }
    }

    func testRequestCarriesNothingButAGenericAgentAndRefusesRedirects() {
        let c = UpdateCheck.session.configuration
        XCTAssertNil(c.httpCookieStorage)
        XCTAssertFalse(c.httpShouldSetCookies)
        XCTAssertNil(c.urlCache)
        XCTAssertNil(c.urlCredentialStorage)
        XCTAssertEqual(c.httpAdditionalHeaders?["User-Agent"] as? String, "unbraid")
        XCTAssertEqual(Set((c.httpAdditionalHeaders ?? [:]).keys.compactMap { $0 as? String }), ["Accept", "User-Agent", "Accept-Language"])
        XCTAssertTrue(UpdateCheck.session.delegate is Http.NoRedirect)
        XCTAssertEqual(URL(string: UpdateCheck.url)?.scheme, "https")
        XCTAssertEqual(URL(string: UpdateCheck.url)?.host, "unbraid.app")
        XCTAssertNil(URL(string: UpdateCheck.url)?.query)
    }

    func testRedirectIsRefused() async {
        let request = URLRequest(url: URL(string: "https://example.com/elsewhere.json")!)
        let response = HTTPURLResponse(url: URL(string: UpdateCheck.url)!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://example.com/elsewhere.json"])!
        let task = UpdateCheck.session.dataTask(with: URL(string: UpdateCheck.url)!)
        let next = await (UpdateCheck.session.delegate as? Http.NoRedirect)?.urlSession(UpdateCheck.session, task: task, willPerformHTTPRedirection: response, newRequest: request)
        XCTAssertNil(next)
        task.cancel()
    }

    func testStateSurvivesARelaunchAndDamagedStateFallsBackToOff() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "UpdateCheckTests.\(UUID().uuidString)"))
        let s = UpdateCheck.State(enabled: true, asked: true, lastAttempt: Date(timeIntervalSince1970: 5), failed: true, latest: "1.2", dismissed: "1.1")
        UpdateCheck.save(s, d)
        XCTAssertEqual(UpdateCheck.load(d), s)
        d.set(Data("garbage".utf8), forKey: "updateCheck")
        XCTAssertEqual(UpdateCheck.load(d), UpdateCheck.State())
        d.set("a string", forKey: "updateCheck")
        XCTAssertEqual(UpdateCheck.load(d), UpdateCheck.State())
    }
}

/// The runner, with a fake answer and a clock the test moves.
@MainActor
final class UpdatesTests: XCTestCase {
    private final class Fake: Sendable {
        let answer = Mutex<Data?>(nil)
        let calls = Mutex(0)
    }

    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 2_000_000_000)
    private let fake = Fake()

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "UpdatesTests.\(UUID().uuidString)")
        fake.answer.withLock { $0 = Data(#"{"versionName": "1.2.0"}"#.utf8) }
    }

    private func updates(delay: Duration = .zero) -> Updates {
        let fake = fake
        return Updates(defaults: defaults, installed: UpdateCheck.Version("1.1.0"), now: { [unowned self] in clock }, fetch: {
            fake.calls.withLock { $0 += 1 }
            if delay > .zero { try? await Task.sleep(for: delay) }
            return fake.answer.withLock { $0 }
        })
    }

    func testOneTimeQuestionIsAskedExactlyOnce() async {
        let fresh = updates()
        XCTAssertTrue(fresh.askPending, "a fresh install or an update from a version without the check is asked")
        XCTAssertFalse(fresh.state.enabled, "off until the user says yes")
        fresh.answer(false)
        XCTAssertFalse(fresh.askPending)
        XCTAssertFalse(updates().askPending, "answered, never asked again after a relaunch")
        XCTAssertEqual(fake.calls.withLock { $0 }, 0, "no means nothing is checked")

        defaults.removeObject(forKey: "updateCheck")
        let other = updates()
        XCTAssertTrue(other.askPending)
        other.setEnabled(true)
        XCTAssertFalse(updates().askPending, "the Settings switch counts as an answer")
    }

    func testYesChecksRightAwayAndThenOnceADay() async {
        let u = updates()
        u.answer(true)
        await waitForCalls(1)
        await settle(u)
        XCTAssertEqual(u.newer, UpdateCheck.Version("1.2.0"))
        XCTAssertTrue(u.showNotice)
        await u.check(user: false)
        XCTAssertEqual(fake.calls.withLock { $0 }, 1, "not again within the day")
        clock += 86_400
        await u.check(user: false)
        XCTAssertEqual(fake.calls.withLock { $0 }, 2)
    }

    func testFailureIsSilentKeepsWhatWasKnownAndRetriesAfterAnHour() async {
        let u = updates()
        u.answer(true)
        await waitForCalls(1)
        await settle(u)
        fake.answer.withLock { $0 = Data("<html>offline</html>".utf8) }
        clock += 86_400
        await u.check(user: false)
        XCTAssertTrue(u.state.failed)
        XCTAssertEqual(u.newer, UpdateCheck.Version("1.2.0"), "a failed check forgets nothing")
        XCTAssertNil(u.lastManual, "an automatic check never reports")
        clock += 3599
        await u.check(user: false)
        XCTAssertEqual(fake.calls.withLock { $0 }, 2)
        clock += 1
        await u.check(user: false)
        XCTAssertEqual(fake.calls.withLock { $0 }, 3)
    }

    func testCheckNowWorksWhileOffAndSaysWhatItFound() async {
        let u = updates()
        await u.checkNow()
        XCTAssertEqual(u.lastManual, .newer(UpdateCheck.Version("1.2.0")!))
        XCTAssertFalse(u.showNotice, "the notice is for the automatic check, which is off")
        fake.answer.withLock { $0 = Data(#"{"versionName": "1.1"}"#.utf8) }
        await u.checkNow()
        XCTAssertEqual(u.lastManual, .current)
        fake.answer.withLock { $0 = Data(#"{"versionName": "1.0.9"}"#.utf8) }
        await u.checkNow()
        XCTAssertEqual(u.lastManual, .current, "an older release is not offered")
        XCTAssertNil(u.newer)
        fake.answer.withLock { $0 = nil }
        await u.checkNow()
        XCTAssertEqual(u.lastManual, .failed)
    }

    func testTurningChecksOffBeforeTheFirstCheckStartsSendsNothing() async {
        let u = updates()
        u.answer(true)
        u.setEnabled(false)
        for _ in 0..<20 { await Task.yield() }
        await settle(u)
        XCTAssertEqual(fake.calls.withLock { $0 }, 0)
        XCTAssertNil(u.state.lastAttempt)
    }

    func testAnAnswerArrivingAfterChecksWereTurnedOffIsDropped() async {
        let u = updates(delay: .milliseconds(200))
        u.answer(true)
        await waitForCalls(1)
        u.setEnabled(false)
        await settle(u)
        XCTAssertNil(u.state.latest)
        XCTAssertFalse(u.state.failed)
        XCTAssertFalse(u.showNotice)
    }

    func testOverlappingChecksAllFinishWithOneRequestEach() async {
        let u = updates(delay: .milliseconds(50))
        u.setEnabled(true)
        await waitForCalls(1)
        async let a: Void = u.checkNow()
        async let b: Void = u.checkNow()
        async let c: Void = u.check(user: false)
        _ = await (a, b, c)
        XCTAssertFalse(u.checking)
        XCTAssertEqual(fake.calls.withLock { $0 }, 3, "the automatic one rode on the running check; each Check Now asked once")
        XCTAssertEqual(u.lastManual, .newer(UpdateCheck.Version("1.2.0")!))
    }

    func testDismissHidesTheNoticeUntilANewerRelease() async {
        let u = updates()
        u.answer(true)
        await waitForCalls(1)
        await settle(u)
        XCTAssertTrue(u.showNotice)
        u.dismiss()
        XCTAssertFalse(u.showNotice)
        XCTAssertFalse(updates().showNotice, "closed stays closed after a relaunch")
        fake.answer.withLock { $0 = Data(#"{"versionName": "1.3"}"#.utf8) }
        await u.checkNow()
        XCTAssertTrue(u.showNotice)
    }

    private func waitForCalls(_ n: Int) async {
        for _ in 0..<200 where fake.calls.withLock({ $0 }) < n { try? await Task.sleep(for: .milliseconds(10)) }
    }
    private func settle(_ u: Updates) async {
        for _ in 0..<200 where u.checking { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
