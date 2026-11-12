import XCTest

final class ProfilesTests: XCTestCase {
    private func storeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.userInfo[Setup.includeProfileSalt] = true
        return encoder
    }

    func testProfileSaltDoesNotChangeEngineSetupOrRevision() throws {
        let old = Setup()
        var salted = old
        salted.profileSalt = UUID().uuidString
        XCTAssertEqual(old, salted)
        XCTAssertEqual(Set([old, salted]).count, 1)
        XCTAssertEqual(RunState.revision(old), RunState.revision(salted))
        XCTAssertEqual(Running.digest(old), Running.digest(salted))
        XCTAssertNotEqual(ProfileGeneration.value(old, accounts: [:]), ProfileGeneration.value(salted, accounts: [:]))
        let encoded = try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(salted))
        XCTAssertNil(encoded.profileSalt)
        salted.apps["a"] = BLOCK
        XCTAssertNotEqual(old, salted)
        XCTAssertNotEqual(RunState.revision(old), RunState.revision(salted))
    }

    func testGenerationSurvivesRelaunchAndRejectsStaleRequests() throws {
        var setup = Setup()
        setup.profileSalt = UUID().uuidString
        setup.saveAs("Home")
        setup.profiles.append(Profile(name: "Trip", defaultRoute: DIRECT))
        let accounts = ["nord": "account", "proton": "other"]
        let generation = ProfileGeneration.value(setup, accounts: accounts)
        let action = WidgetAction.profileAction(name: "Trip", generation: generation)
        let relaunched = try JSONDecoder().decode(Setup.self, from: storeEncoder().encode(setup))
        XCTAssertEqual(ProfileGeneration.value(relaunched, accounts: ["proton": "other", "nord": "account"]), generation)
        XCTAssertEqual(WidgetAction.profileDecision(action, generation: ProfileGeneration.value(relaunched, accounts: accounts), names: relaunched.profiles.map(\.name), current: relaunched.profile, connected: false), .switchTo("Trip"))
        XCTAssertEqual(WidgetAction.profileDecision(action, generation: generation, names: setup.profiles.map(\.name), current: setup.profile, connected: false, lastSwitch: action), .reject)
        var changed = setup
        changed.profiles[1].apps["mail"] = BLOCK
        XCTAssertNotEqual(ProfileGeneration.value(changed, accounts: accounts), generation)
        changed = setup; changed.apps["mail"] = DIRECT
        XCTAssertNotEqual(ProfileGeneration.value(changed, accounts: accounts), generation)
        changed = setup; changed.routes[0].loc.country = "Italy"
        XCTAssertNotEqual(ProfileGeneration.value(changed, accounts: accounts), generation)
        XCTAssertNotEqual(ProfileGeneration.value(setup, accounts: [:]), generation)
        XCTAssertNotEqual(ProfileGeneration.value(setup, accounts: ["nord": "replacement", "proton": "other"]), generation)
        // Even restoring the same accounts and profiles after a reset must not restore the old generation.
        changed = setup; changed.profileSalt = UUID().uuidString
        XCTAssertNotEqual(ProfileGeneration.value(changed, accounts: accounts), generation)
    }

    func testOldSetupHasNoGenerationUntilPrivateSaltIsSaved() throws {
        let old = try JSONDecoder().decode(Setup.self, from: Data(#"{"opts":{},"profiles":[{"name":"Home","defaultRoute":"nl"}]}"#.utf8))
        XCTAssertNil(old.profileSalt)
        XCTAssertEqual(ProfileGeneration.value(old, accounts: [:]), "")
        var setup = old
        setup.profileSalt = UUID().uuidString
        let copy = try JSONDecoder().decode(Setup.self, from: storeEncoder().encode(setup))
        XCTAssertEqual(copy.profileSalt, setup.profileSalt)
        XCTAssertEqual(ProfileGeneration.value(copy, accounts: [:]).count, 64)
    }

    func testGenerationAccountsHaveUnambiguousEncoding() {
        var setup = Setup()
        setup.profileSalt = UUID().uuidString
        XCTAssertNotEqual(ProfileGeneration.value(setup, accounts: ["a": "x|b=y"]),
                          ProfileGeneration.value(setup, accounts: ["a": "x", "b": "y"]))
    }

    func testSaveSwitchRenameForgetAndMove() {
        var s = Setup()
        s.saveAs("Home")
        s.apps["bank"] = DIRECT
        s.saveAs("Travel")
        s.defaultRoute = DIRECT
        s.use("Home")
        XCTAssertEqual(s.apps["bank"], DIRECT)
        XCTAssertEqual(s.profiles[1].defaultRoute, DIRECT)
        s.move("Travel", by: -5)
        XCTAssertEqual(s.profiles.map(\.name), ["Travel", "Home"])
        s.rename("Home", "House")
        XCTAssertEqual(s.profile, "House")
        s.forget("House")
        XCTAssertNil(s.profile)
        XCTAssertEqual(s.apps["bank"], DIRECT)
    }

    func testNamesRepairAndOldSetup() throws {
        var s = try JSONDecoder().decode(Setup.self, from: Data("{}".utf8))
        XCTAssertTrue(s.profiles.isEmpty)
        s.saveAs(" Home ")
        XCTAssertNil(s.profileName("home"))
        XCTAssertNil(s.profileName("1234567890123"))
        XCTAssertNil(s.profileName("Ho\u{202E}me"))
        XCTAssertEqual(s.profileName("👨‍👩‍👧 Casa"), "👨‍👩‍👧 Casa")
        let data = Data(#"{"profiles":[{"name":" Home ","defaultRoute":"gone","apps":{"a":"gone"}},{"name":"home","defaultRoute":"nl"}],"profile":"missing"}"#.utf8)
        let repaired = try JSONDecoder().decode(Setup.self, from: data)
        XCTAssertEqual(repaired.profiles, [Profile(name: "Home", defaultRoute: "nl")])
        XCTAssertNil(repaired.profile)
    }

    func testTidyAndBackPreserveRefusedProfile() {
        var ran = Setup()
        ran.saveAs("Home")
        var s = ran
        s.saveAs("Trip")
        s.defaultRoute = DIRECT
        s.back(to: ran)
        XCTAssertEqual(s.profile, "Home")
        XCTAssertEqual(s.defaultRoute, "nl")
        XCTAssertEqual(s.profiles[1].defaultRoute, DIRECT)
        s.routes = []
        s.tidyProfiles()
        XCTAssertEqual(s.profiles[0].defaultRoute, DIRECT)
    }
    func testOldWireGuardPeerDecodesInEveryContainer() throws {
        let peer = #"{"name":"Home","privateKey":"private","address":["10.0.0.2/32"],"publicKey":"public","endpoint":"example.com:51820","allowedIps":["0.0.0.0/0"]}"#
        let json = "{\"routes\":[{\"id\":\"wg\",\"wg\":\(peer)}],\"servers\":[{\"id\":\"home\",\"wg\":\(peer)}],\"home\":{\"wg\":\(peer)}}"
        let setup = try JSONDecoder().decode(Setup.self, from: Data(json.utf8))
        for wg in [setup.routes.first?.wg, setup.servers.first?.wg, setup.home.wg] {
            XCTAssertEqual(wg?.dns, [])
            XCTAssertEqual(wg?.mtu, 1420)
            XCTAssertNil(wg?.keepalive)
        }
    }

    func testSnapshotAndActionCarryProfileNames() throws {
        var setup = Setup()
        setup.saveAs("Home")
        let snapshot = Snapshot.make(phase: .off, since: nil, pausedUntil: nil, failed: false, edited: setup, running: nil, exits: 0, week: [], profileGeneration: String(repeating: "a", count: 64))
        let copy = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(copy.profiles, ["Home"])
        let action = WidgetAction.profileAction(name: "Home", generation: copy.profileGeneration!)
        XCTAssertEqual(WidgetAction.profileRequest(action)?.name, "Home")
        XCTAssertNil(WidgetAction.profileRequest("profile:bad:SG9tZQ=="))
    }
    func testProfileActionRejectsStaleAndUnknownAndRepeatingPauses() {
        let generation = String(repeating: "a", count: 64)
        let action = WidgetAction.profileAction(name: "Home", generation: generation)
        XCTAssertEqual(WidgetAction.profileDecision(action, generation: String(repeating: "b", count: 64), names: ["Home"], current: nil, connected: true), .reject)
        XCTAssertEqual(WidgetAction.profileDecision(action, generation: generation, names: [], current: nil, connected: true), .reject)
        XCTAssertEqual(WidgetAction.profileDecision(action, generation: generation, names: ["Home"], current: nil, connected: true), .switchTo("Home"))
        XCTAssertEqual(WidgetAction.profileDecision(action, generation: generation, names: ["Home"], current: "Home", connected: true), .pause)
        XCTAssertEqual(WidgetAction.profileDecision(action, generation: generation, names: ["Home"], current: "Home", connected: false), .connect)
    }
    func testRollbackKeepsEditsAfterSwitch() {
        var ran = Setup()
        ran.apps["bank"] = DIRECT
        ran.saveAs("Home")
        var switched = ran
        switched.saveAs("Trip")
        switched.apps = [:]
        var edited = switched
        edited.apps["music"] = BLOCK
        edited.back(to: ran, after: switched)
        XCTAssertEqual(edited.apps["bank"], DIRECT)
        XCTAssertEqual(edited.apps["music"], BLOCK)
        XCTAssertNil(edited.profile)
        XCTAssertEqual(edited.profiles.first { $0.name == "Trip" }?.apps["music"], BLOCK)
    }
    func testSwitchResolutionAndRecovery() throws {
        var before = Setup()
        before.saveAs("Home")
        before.saveAs("Trip")
        before.defaultRoute = DIRECT
        before.use("Home")
        var current = before
        current.use("Trip")
        let pending = ProfileSwitch(id: UUID(), target: "Trip", from: "Home", when: Date(timeIntervalSince1970: 123),
            switched: Profile(name: "Trip", defaultRoute: current.defaultRoute, apps: current.apps))
        current.pendingSwitch = pending
        func decide(_ s: Setup, _ running: Setup? = nil, _ refused: Setup? = nil,
                    _ standIn: RunState.StandIn = .none, _ stopped: Bool = false) -> ProfileSwitch.Decision {
            pending.decide(current: s, running: running, refused: refused, standIn: standIn, stopped: stopped)
        }
        XCTAssertEqual(decide(current, current), .applied)
        var edited = current
        edited.apps["bank"] = DIRECT
        XCTAssertEqual(decide(edited, edited), .applied)
        XCTAssertEqual(decide(edited, before, edited), .refused)
        XCTAssertEqual(decide(edited, edited, nil, .denyAll), .waiting)
        XCTAssertEqual(decide(edited, edited, edited, .denyAll), .refused)
        XCTAssertEqual(decide(edited, nil, nil, .none, true), .stopped)
        var superseded = edited
        superseded.pendingSwitch?.id = UUID()
        XCTAssertEqual(decide(superseded, edited, edited), .superseded)
        let restored = try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(restored.pendingSwitch, pending)
        XCTAssertEqual(decide(restored, restored), .applied)
        XCTAssertEqual(decide(restored, before, restored), .refused)
        XCTAssertEqual(decide(restored, nil, nil, .none, true), .stopped)
        XCTAssertNil(try JSONDecoder().decode(Setup.self, from: Data("{}".utf8)).pendingSwitch)
        var witnessed = pending
        witnessed.previous = Profile(name: "Home", defaultRoute: before.defaultRoute, apps: before.apps)
        witnessed.previousEngine = "engine-revision"
        XCTAssertTrue(witnessed.confirmsPrevious(engine: "engine-revision", foreign: false, fallback: false, trusted: true))
        XCTAssertFalse(witnessed.confirmsPrevious(engine: "other", foreign: false, fallback: false, trusted: true))
        XCTAssertFalse(witnessed.confirmsPrevious(engine: "engine-revision", foreign: true, fallback: false, trusted: true))
        XCTAssertFalse(witnessed.confirmsPrevious(engine: "engine-revision", foreign: false, fallback: true, trusted: true))
        XCTAssertFalse(witnessed.confirmsPrevious(engine: "engine-revision", foreign: false, fallback: false, trusted: false))
    }

    func testDuplicateProfileHandOffIsRejected() {
        let generation = String(repeating: "a", count: 64)
        let action = WidgetAction.profileAction(name: "Trip", generation: generation)
        XCTAssertEqual(WidgetAction.profileDecision(action, generation: generation, names: ["Trip"], current: "Home", connected: true), .switchTo("Trip"))
        XCTAssertEqual(WidgetAction.profileDecision(action, generation: generation, names: ["Trip"], current: "Home", connected: true, lastSwitch: action), .reject)
        let other = WidgetAction.profileAction(name: "Home", generation: generation)
        XCTAssertEqual(WidgetAction.profileDecision(other, generation: generation, names: ["Home", "Trip"], current: "Home", connected: true, lastSwitch: action), .pause)
    }

    func testOldCachedWireGuardLinkFixture() throws {
        let json = #"{"wg":{"_0":{"name":"se1","host":"se1","ip":"1.2.3.4","publicKey":"key","load":0,"city":"","country":""},"_1":{"name":"Home","privateKey":"private","address":["10.0.0.2/32"],"publicKey":"public","endpoint":"example.com:51820","allowedIps":["0.0.0.0/0"]},"ports":[],"entries":[]}}"#
        let link = try JSONDecoder().decode(Link.self, from: Data(json.utf8))
        guard case .wg(_, let peer, _, _) = link else { return XCTFail("missing peer") }
        XCTAssertEqual(peer.dns, [])
        XCTAssertEqual(peer.mtu, 1420)
        XCTAssertNil(peer.keepalive)
    }

    private func switchingSetup(blocked: Bool = false) -> Setup {
        var s = Setup(routes: [Route(id: "r1"), Route(id: "r2")], defaultRoute: "r1")
        s.prefs.killLevel = .off
        s.saveAs("Home")
        s.profiles.append(Profile(name: "Trip", defaultRoute: DIRECT, apps: blocked ? ["bank": BLOCK] : [:]))
        return s
    }

    func testSwitchCapturesRunningEngineAndNewerUserSelection() throws {
        let running = switchingSetup()
        var s = running
        s.defaultRoute = "r2"
        s.beginProfileSwitch("Trip", id: UUID(), running: running, engine: "engine-r1")
        let pending = try XCTUnwrap(s.pendingSwitch)
        XCTAssertEqual(pending.previous?.defaultRoute, "r1")
        XCTAssertEqual(pending.previousEngine, "engine-r1")
        XCTAssertEqual(pending.before?.defaultRoute, "r2")
        XCTAssertTrue(pending.confirmsPrevious(engine: "engine-r1", foreign: false, fallback: false, trusted: true))
        // The saved run-state can still say r1 after the engine finishes the earlier r2 edit.
        pending.rollback(&s, fallback: running)
        XCTAssertEqual(s.defaultRoute, "r2")
        XCTAssertEqual(s.profile, "Home")
        XCTAssertEqual(s.profiles.first { $0.name == "Trip" }?.defaultRoute, DIRECT)
    }

    func testRefusedSwitchRestoresProtectionAndRoundTrips() throws {
        let before = switchingSetup(blocked: true)
        var s = before
        s.beginProfileSwitch("Trip", id: UUID(), running: before, engine: "engine")
        XCTAssertEqual(s.prefs.killLevel, .internet)
        s = try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(s))
        let pending = try XCTUnwrap(s.pendingSwitch)
        s = Store.edited(s) { pending.rollback(&$0, fallback: before) }
        XCTAssertEqual(s.prefs.killLevel, .off)
        XCTAssertEqual(s.prefs.killSwitchHome, before.prefs.killSwitchHome)
        XCTAssertEqual(s.apps, before.apps)
        XCTAssertEqual(s.profile, "Home")
        XCTAssertEqual(s.profiles.first { $0.name == "Trip" }?.apps["bank"], BLOCK)
    }

    func testRollbackKeepsNewerRoutingAndProtectionEdits() throws {
        let before = switchingSetup(blocked: true)
        var s = before
        s.beginProfileSwitch("Trip", id: UUID(), running: before, engine: "engine")
        let pending = try XCTUnwrap(s.pendingSwitch)
        s.defaultRoute = "r2"
        s.apps["music"] = BLOCK
        s.prefs.killLevel = .home
        s.prefs.alwaysOn.toggle()
        let alwaysOn = s.prefs.alwaysOn
        pending.rollback(&s, fallback: before)
        XCTAssertEqual(s.defaultRoute, "r2")
        XCTAssertEqual(s.apps, ["music": BLOCK])
        XCTAssertEqual(s.prefs.killLevel, .home)
        XCTAssertEqual(s.prefs.alwaysOn, alwaysOn)
        XCTAssertNil(s.profile)
    }

    func testRollbackNeverLeavesBlocksWithoutProtection() throws {
        let before = switchingSetup(blocked: true)
        var s = before
        s.beginProfileSwitch("Trip", id: UUID(), running: before, engine: "engine")
        let pending = try XCTUnwrap(s.pendingSwitch)
        s.apps["music"] = BLOCK
        pending.rollback(&s, fallback: before)
        XCTAssertEqual(s.apps, ["music": BLOCK])
        XCTAssertEqual(s.prefs.killLevel, .internet)
        var blocked = before
        blocked.apps["music"] = BLOCK
        blocked.prefs.killLevel = .home
        s.back(to: blocked)
        XCTAssertEqual(s.prefs.killLevel, .home)
    }

    func testRollbackRestoresHiddenHomeSettingAndPreservesLaterChange() {
        var before = switchingSetup()
        before.prefs.killSwitchHome = true
        var switched = before
        switched.use("Trip")
        var s = switched
        s.back(to: before, after: switched)
        XCTAssertFalse(s.prefs.killSwitch)
        XCTAssertTrue(s.prefs.killSwitchHome)
        s = switched
        s.prefs.killSwitchHome = false
        s.back(to: before, after: switched)
        XCTAssertFalse(s.prefs.killSwitchHome)
    }

    func testOldPendingSwitchDecodesAndUsesRecordedPrevious() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","target":"Trip","from":"Home","when":0,"switched":{"name":"Trip","defaultRoute":"direct","apps":{}},"previous":{"name":"Home","defaultRoute":"r2","apps":{}},"previousEngine":"engine"}"#
        let pending = try JSONDecoder().decode(ProfileSwitch.self, from: Data(json.utf8))
        XCTAssertNil(pending.before)
        XCTAssertNil(pending.beforePrefs)
        XCTAssertNil(pending.switchedPrefs)
        var s = switchingSetup()
        s.use("Trip")
        s.prefs.killLevel = .home
        pending.rollback(&s, fallback: switchingSetup())
        XCTAssertEqual(s.defaultRoute, "r2")
        XCTAssertEqual(s.prefs.killLevel, .home)
    }

    func testEveryRouteRemovalTidiesSavedProfiles() {
        var before = Setup(routes: [Route(id: "own", own: "server"), Route(id: "ts", tsExit: "100.64.0.1"), Route(id: "provider")], defaultRoute: DIRECT)
        before.profiles = [Profile(name: "Own", defaultRoute: "own", apps: ["tail": "ts", "provider": "provider"]),
                           Profile(name: "Tail", defaultRoute: "ts", apps: ["own": "own"])]
        for remove: (inout Setup) -> Void in [
            { $0.routes.removeAll { $0.own == "server" } },
            { $0.routes.removeAll { !$0.imported } },
            { $0.dropTailscale() },
            { $0.addImported("", id: "import", signedIn: []) { $0.tsExit = "100.64.0.2" } },
            { $0.routes = [] }
        ] {
            let edited = Store.edited(before, remove)
            let valid = Set(edited.routes.map(\.id) + [DIRECT, BLOCK])
            for p in edited.profiles {
                XCTAssertTrue(valid.contains(p.defaultRoute), p.name)
                XCTAssertTrue(p.apps.values.allSatisfy(valid.contains), p.name)
                var selected = edited
                selected.use(p.name)
                XCTAssertTrue(valid.contains(selected.defaultRoute))
            }
        }
    }

    func testProfileSlotsRequireANameAndValidGeneration() {
        var snapshot = Snapshot()
        XCTAssertNil(WidgetAction.profileSlot(0, names: snapshot.profiles, generation: snapshot.profileGeneration))
        snapshot.profiles = ["Home"]
        XCTAssertNil(WidgetAction.profileSlot(0, names: snapshot.profiles, generation: snapshot.profileGeneration))
        snapshot.profileGeneration = ""
        XCTAssertNil(WidgetAction.profileSlot(0, names: snapshot.profiles, generation: snapshot.profileGeneration))
        snapshot.profileGeneration = String(repeating: "g", count: 64)
        XCTAssertNil(WidgetAction.profileSlot(0, names: snapshot.profiles, generation: snapshot.profileGeneration))
        snapshot.profileGeneration = String(repeating: "a", count: 64)
        XCTAssertEqual(WidgetAction.profileSlot(0, names: snapshot.profiles, generation: snapshot.profileGeneration)?.name, "Home")
        XCTAssertNil(WidgetAction.profileSlot(-1, names: snapshot.profiles, generation: snapshot.profileGeneration))
        XCTAssertNil(WidgetAction.profileSlot(1, names: snapshot.profiles, generation: snapshot.profileGeneration))
        XCTAssertNil(WidgetAction.profileSlot(2, names: snapshot.profiles, generation: snapshot.profileGeneration))
    }

    func testAnAppsOwnRouteSticksWhenItBecomesTheDefault() {
        var s = Setup(routes: [Route(id: "r1"), Route(id: "r2")], defaultRoute: "r1", apps: ["pinned": "r2", "onDefault": "r1"])
        // Moving to the default route is the app's own choice, not "follow the default".
        AppMove.apply(["a": "r1", "b": nil, "c": "r2"], to: &s)
        XCTAssertEqual(s.apps["a"], "r1")
        XCTAssertNil(s.apps["b"])
        // Making r2 the default doesn't take the choice away from the apps on it, nor move the ones on r1.
        s.defaultRoute = "r2"
        XCTAssertEqual(s.apps["pinned"], "r2")
        XCTAssertEqual(s.apps["onDefault"], "r1")
        XCTAssertEqual(s.routeOf("pinned"), "r2")
        XCTAssertEqual(s.routeOf("follower"), "r2")
        // Tidying and importing keep it too.
        s.profiles = [Profile(name: "Trip", defaultRoute: "r2", apps: ["x": "r2", "y": "gone"])]
        s.tidyProfiles()
        XCTAssertEqual(s.profiles[0].apps, ["x": "r2"])
        _ = s.addImported("app:tool", id: "r3", signedIn: ["nord"]) { $0.tsExit = "100.64.0.1" }
        XCTAssertEqual(s.apps["tool"], "r3")
        s.defaultRoute = "r3"
        XCTAssertEqual(s.apps["tool"], "r3")
    }

}
