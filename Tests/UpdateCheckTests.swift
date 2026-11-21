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
        XCTAssertEqual(c.httpAdditionalHeaders?["User-Agent"] as? String, UpdateCheck.agent)
        XCTAssertEqual(UpdateCheck.agent, "unbraid/" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"))
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
        let s = UpdateCheck.State(enabled: true, asked: true, lastAttempt: Date(timeIntervalSince1970: 5), failed: true, latest: "1.2", dismissed: "1.1", turnedOn: true)
        UpdateCheck.save(s, d)
        XCTAssertEqual(UpdateCheck.load(d), s)
        d.set(Data("garbage".utf8), forKey: "updateCheck")
        XCTAssertEqual(UpdateCheck.load(d), UpdateCheck.State(asked: true, turnedOn: true), "unreadable: off, never turned on by default")
        d.set("a string", forKey: "updateCheck")
        XCTAssertEqual(UpdateCheck.load(d), UpdateCheck.State(asked: true, turnedOn: true))
    }

    /// From 1.3.7 checks are on by default, once per install: a new install, and an earlier one also when it chose not
    /// to check. The window then says so once. An earlier install that had them on keeps everything it knew.
    func testUpdateChecksAreOnByDefaultForNewAndEarlierInstalls() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "UpdateCheckTests.\(UUID().uuidString)"))
        let fresh = UpdateCheck.load(d)
        XCTAssertTrue(fresh.enabled, "a new install checks")
        XCTAssertFalse(fresh.asked, "and the window says so once")
        // An earlier version's file (no turnedOn field) that chose "Don't Check".
        d.set(Data(#"{"enabled":false,"asked":true,"failed":false}"#.utf8), forKey: "updateCheck")
        let declined = UpdateCheck.load(d)
        XCTAssertTrue(declined.enabled, "an earlier Don't Check is turned on once")
        XCTAssertFalse(declined.asked, "and told")
        // An earlier version's file with checks on: kept as it was, nothing to tell.
        d.set(Data(#"{"enabled":true,"asked":true,"failed":true,"latest":"1.2","dismissed":"1.1","lastAttempt":5}"#.utf8), forKey: "updateCheck")
        let on = UpdateCheck.load(d)
        XCTAssertTrue(on.enabled)
        XCTAssertTrue(on.asked)
        XCTAssertEqual(on.latest, "1.2")
        XCTAssertEqual(on.dismissed, "1.1")
        XCTAssertTrue(on.failed)
        XCTAssertEqual(on.lastAttempt, Date(timeIntervalSinceReferenceDate: 5), "an earlier file keeps all it held")
    }

    /// Turned off on 1.3.7, then an earlier version (which knows nothing of the default) rewrites the state, then 1.3.7
    /// again: still off. The one-time step lives in a key no earlier version writes.
    func testTurnOffSurvivesGoingBackToAnEarlierVersionAndReturning() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "UpdateCheckTests.\(UUID().uuidString)"))
        d.set(true, forKey: "updateCheckOnByDefault")
        d.set(Data(#"{"enabled":false,"asked":true,"failed":false,"lastAttempt":5}"#.utf8), forKey: "updateCheck")
        XCTAssertFalse(UpdateCheck.load(d).enabled)
        XCTAssertTrue(UpdateCheck.load(d).asked, "and not told again")
    }

    /// A saved state missing the fields every version writes is damaged, not a choice: it stays off, before and after the
    /// one-time step.
    func testDamagedStateWithoutItsFieldsStaysOff() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "UpdateCheckTests.\(UUID().uuidString)"))
        d.set(Data("{}".utf8), forKey: "updateCheck")
        XCTAssertFalse(UpdateCheck.load(d).enabled)
        d.set(Data(#"{"enabled":false,"asked":true}"#.utf8), forKey: "updateCheck")
        XCTAssertFalse(UpdateCheck.load(d).enabled, "a field every version writes is missing: damaged")
        d.set(true, forKey: "updateCheckOnByDefault")
        XCTAssertFalse(UpdateCheck.load(d).enabled)
    }

    /// A saved state that can't be read is never turned on: what the user chose there is unknown.
    func testUnreadableUpdateStateStaysOffAndIsNotAnnounced() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "UpdateCheckTests.\(UUID().uuidString)"))
        d.set(Data("garbage".utf8), forKey: "updateCheck")
        let s = UpdateCheck.load(d)
        XCTAssertFalse(s.enabled)
        XCTAssertTrue(s.asked, "no notice that checks are on, because they are not")
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
        // These tests start from an install whose checks are off (turned off after 1.3.7 turned them on), with the terms
        // accepted, so each one turns checks on itself.
        defaults.set(Data(#"{"enabled":false,"asked":true,"failed":false,"turnedOn":true}"#.utf8), forKey: "updateCheck")
        defaults.set(true, forKey: "termsAccepted")
    }

    private func updates(delay: Duration = .zero) -> Updates {
        let fake = fake
        return Updates(defaults: defaults, installed: UpdateCheck.Version("1.1.0"), now: { [unowned self] in clock }, fetch: {
            fake.calls.withLock { $0 += 1 }
            if delay > .zero { try? await Task.sleep(for: delay) }
            return fake.answer.withLock { $0 }
        })
    }

    func testNoticeThatChecksAreOnShowsOnceAndTurnOffStaysOff() async {
        defaults.removeObject(forKey: "updateCheck")
        defaults.removeObject(forKey: "updateCheckOnByDefault")
        let fresh = updates()
        XCTAssertTrue(fresh.askPending, "a fresh install, or an update from before 1.3.7, is told checks are on")
        XCTAssertTrue(fresh.state.enabled, "on by default")
        XCTAssertTrue(updates().askPending, "a relaunch before OK or Turn Off still owes the notice")
        XCTAssertTrue(updates().state.enabled, "and checks stay on")
        fresh.answer(true)
        XCTAssertFalse(fresh.askPending)
        XCTAssertTrue(fresh.state.enabled, "OK keeps them on")
        XCTAssertFalse(updates().askPending, "told once, not again after a relaunch")

        defaults.removeObject(forKey: "updateCheck")
        defaults.removeObject(forKey: "updateCheckOnByDefault")
        let other = updates()
        XCTAssertTrue(other.askPending)
        other.setEnabled(false)
        XCTAssertFalse(other.askPending, "Turn Off answers the notice")
        let relaunched = updates()
        XCTAssertFalse(relaunched.state.enabled, "turned off stays off after a relaunch: on by default happens once")
        XCTAssertFalse(relaunched.askPending)
    }

    /// Nothing automatic leaves the Mac before the terms are accepted; Check Now is the user's own request.
    func testNoAutomaticCheckBeforeTheTermsAreAccepted() async {
        defaults.set(Data(#"{"enabled":true,"asked":true,"failed":false}"#.utf8), forKey: "updateCheck")
        defaults.set(false, forKey: "termsAccepted")
        let u = updates()
        await u.check(user: false)
        XCTAssertEqual(fake.calls.withLock { $0 }, 0, "terms not accepted: no request")
        defaults.set(true, forKey: "termsAccepted")
        await u.check(user: false)
        XCTAssertEqual(fake.calls.withLock { $0 }, 1, "after the terms, the daily check runs")
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
