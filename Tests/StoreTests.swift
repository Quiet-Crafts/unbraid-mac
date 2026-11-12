import CryptoKit
import Synchronization
import XCTest

private final class KeyBox: Sendable {
    func testOldSealedSetupDecodesWithoutLinkInformation() throws {
        let old = try JSONEncoder().encode(Setup())
        let decoded = try XCTUnwrap(Running.decodeSealed(old))
        XCTAssertNil(decoded.linked)
        XCTAssertEqual(decoded.setup, Setup())
    }

    let key = Mutex<SymmetricKey?>(SymmetricKey(size: .bits256))
    func withLock<T>(_ f: (inout SymmetricKey?) -> T) -> T { key.withLock { f(&$0) } }
}

/// The store on a temporary folder, sealed with a key the test holds (never the keychain), and its own defaults.
@MainActor
final class StoreTests: XCTestCase {
    func testProfileSaltPersistsOnlyInSealedSetupAndIsForgotten() async throws {
        let first = store()
        let salt = UUID().uuidString
        first.update { $0.profileSalt = salt; $0.saveAs("Home") }
        await settle()
        let bytes = try Data(contentsOf: dir.appending(path: "setup.bin"))
        XCTAssertNil(bytes.range(of: Data(salt.utf8)))
        let relaunched = store()
        XCTAssertEqual(relaunched.setup.profileSalt, salt)
        XCTAssertEqual(ProfileGeneration.value(relaunched.setup, accounts: relaunched.accounts),
                       ProfileGeneration.value(first.setup, accounts: first.accounts))
        let forgotten = await relaunched.forgetAll()
        XCTAssertTrue(forgotten)
        XCTAssertNil(relaunched.setup.profileSalt)
        XCTAssertNil(store().setup.profileSalt)
    }

    func testSaltRotationIsSavedWithoutChangingEngineSetup() async {
        let s = store()
        s.update { $0.apps["a"] = DIRECT }
        await settle()
        let before = s.setup
        let generation = ProfileGeneration.value(before, accounts: [:])
        s.update { $0.profileSalt = UUID().uuidString }
        XCTAssertEqual(s.setup, before)
        XCTAssertEqual(RunState.revision(s.setup), RunState.revision(before))
        XCTAssertNotEqual(ProfileGeneration.value(s.setup, accounts: [:]), generation)
        await settle()
        XCTAssertEqual(store().setup.profileSalt, s.setup.profileSalt)
    }

    func testOldSetupGetsSaltOnLoadWithoutChangingEngineRevision() async throws {
        let fixture = Data(#"{"routes":[{"id":"main"}],"defaultRoute":"main","apps":{"mail":"DIRECT"},"opts":{}}"#.utf8)
        let old = try JSONDecoder().decode(Setup.self, from: fixture)
        let vault = Sealed(dir: dir, key: { [key] in key.withLock { $0 } })
        XCTAssertTrue(vault.write("setup.bin", fixture))
        let loaded = store()
        XCTAssertNotNil(loaded.setup.profileSalt)
        XCTAssertEqual(RunState.revision(old), RunState.revision(loaded.setup))
        await settle()
        XCTAssertEqual(store().setup.profileSalt, loaded.setup.profileSalt)
    }

    func testReadingGenerationAfterForgetDoesNotRecreateSetup() async throws {
        let s = store()
        XCTAssertNil(s.setup.profileSalt)
        s.update { $0.apps["a"] = DIRECT }
        XCTAssertNotNil(s.setup.profileSalt)
        await settle()
        let oldSalt = s.setup.profileSalt
        let forgotten = await s.forgetAll()
        XCTAssertTrue(forgotten)
        for _ in 0..<3 { XCTAssertEqual(ProfileGeneration.value(s.setup, accounts: s.accounts), "") }
        s.update { _ in }
        await settle()
        XCTAssertFalse(exists("setup.bin"))
        s.update { $0.apps["a"] = DIRECT }
        XCTAssertNotNil(s.setup.profileSalt)
        XCTAssertNotEqual(s.setup.profileSalt, oldSalt)
        await settle()
        XCTAssertTrue(exists("setup.bin"))
    }

    func testOldHeldSetupGetsSaltOnlyAfterUnlock() async throws {
        let vault = Sealed(dir: dir, key: { [key] in key.withLock { $0 } })
        XCTAssertTrue(vault.write("setup.bin", Data(#"{"opts":{},"apps":{"a":"DIRECT"}}"#.utf8)))
        let savedKey = key.withLock { $0 }
        key.withLock { $0 = nil }
        let s = store()
        XCTAssertTrue(s.isHeld)
        XCTAssertNil(s.setup.profileSalt)
        key.withLock { $0 = savedKey }
        XCTAssertEqual(s.reloadHeld(), ["setup.bin"])
        XCTAssertNotNil(s.setup.profileSalt)
        await settle()
        XCTAssertEqual(store().setup.profileSalt, s.setup.profileSalt)
    }

    func testOldPreferencesDecodeWithParallelDefault() throws {
        let old = Data("{\"stats\":true}".utf8)
        let prefs = try JSONDecoder().decode(Prefs.self, from: old)
        XCTAssertTrue(prefs.stats)
        XCTAssertEqual(prefs.testAllRoutes, Prefs().testAllRoutes)
    }

    private var dir: URL!
    private var defaults: UserDefaults!
    private var suite = ""
    private let key = KeyBox()

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "StoreTests-\(UUID().uuidString)")
        suite = "StoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    }

    private func store() -> Store {
        let key = key
        return Store(dir: dir, vault: Sealed(dir: dir, key: { key.withLock { $0 } }), defaults: defaults)
    }

    /// Queued writes done, and their reports back on the main actor.
    private func settle() async {
        await FileWork.shared.drain()
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appending(path: name).path) }
    func testSealedTempsSweptAtLaunchAndForget() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = ".accounts.bin.\(UUID().uuidString).tmp"
        let fresh = ".setup.bin.\(UUID().uuidString).tmp"
        let unrelated = ".accounts.bin.not-a-uuid.tmp"
        // Left by a write that never finished: old enough that nothing is still writing it.
        func leftover(_ name: String) throws {
            let url = dir.appending(path: name)
            try Data("secret".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: url.path)
        }
        try leftover(temp); try leftover(unrelated)
        try Data("writing".utf8).write(to: dir.appending(path: fresh))
        let s = store()
        XCTAssertFalse(exists(temp)); XCTAssertTrue(exists(unrelated))
        // A write still under way keeps its file.
        XCTAssertTrue(exists(fresh))
        try FileManager.default.removeItem(at: dir.appending(path: fresh))
        try leftover(temp)
        let forgotten = await s.forgetAll()
        XCTAssertTrue(forgotten); XCTAssertFalse(exists(temp)); XCTAssertTrue(exists(unrelated))
    }

    func testFailedLinkRewriteDeletesCacheAndRetries() async throws {
        let s = await signedIn()
        key.withLock { $0 = nil }
        s.account("mullvad", nil)
        await settle()
        XCTAssertFalse(exists("links.bin"))
        XCTAssertTrue(defaults.bool(forKey: "linksCleanupPending"))
        key.withLock { $0 = SymmetricKey(size: .bits256) }
        s.retrySave()
        await settle()
        XCTAssertFalse(defaults.bool(forKey: "linksCleanupPending"))
        let links = await s.lastLinks()
        XCTAssertTrue(links.isEmpty)
    }

    func testFailedLinkDeletionIsRetriedAtLaunch() async throws {
        let s = await signedIn()
        try readOnly(true)
        s.account("mullvad", nil)
        await settle()
        XCTAssertTrue(exists("links.bin"))
        let locked = store()
        let hidden = await locked.lastLinks()
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertTrue(defaults.bool(forKey: "linksCleanupPending"))
        try readOnly(false)
        let reopened = store()
        XCTAssertFalse(exists("links.bin"))
        XCTAssertFalse(defaults.bool(forKey: "linksCleanupPending"))
        let links = await reopened.lastLinks()
        XCTAssertTrue(links.isEmpty)
    }

    func testCountryCacheReadsOldFormatAndPersistsPublication() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = Data(#"{"provider":"proton","countries":[]}"#.utf8)
        let sealedWithTheStoresKey = Sealed(dir: dir, key: { [key] in key.withLock { $0 } })
        XCTAssertTrue(sealedWithTheStoresKey.write("countries-proton.bin", old))
        let s = store()
        XCTAssertEqual(s.countries("proton"), [])
        XCTAssertNil(s.catalogDate("proton"))
        s.countries("proton", [], published: 1_785_990_858)
        await settle()
        let reopened = store()
        XCTAssertEqual(reopened.countries("proton"), [])
        XCTAssertEqual(reopened.catalogDate("proton"), 1_785_990_858)
    }

    /// A plain file another process planted is never read as the list; the list is fetched again instead.
    func testAPlantedCountryListIsNotOffered() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let planted = Data(#"{"countries":[{"id":"1","name":"Netherlands","code":"NL","cities":[],"serverCount":1}],"published":1}"#.utf8)
        try planted.write(to: dir.appending(path: "countries-nord.json"))
        try planted.write(to: dir.appending(path: "countries-nord.bin"))
        let s = store()
        XCTAssertEqual(s.countries("nord"), [])
        XCTAssertNil(s.catalogDate("nord"))
        s.countries("nord", [])
        await settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "countries-nord.json").path))
        XCTAssertEqual(store().countries("nord"), [])
        // Sealed with the right key but for another provider: not this one's list.
        let vault = Sealed(dir: dir, key: { [key] in key.withLock { $0 } })
        XCTAssertTrue(vault.write("countries-proton.bin", Data(#"{"provider":"nord","countries":[],"published":5}"#.utf8)))
        XCTAssertNil(store().catalogDate("proton"))
        XCTAssertTrue(vault.write("countries-proton.bin", Data(#"{"provider":"proton","countries":[],"published":5}"#.utf8)))
        XCTAssertEqual(store().catalogDate("proton"), 5)
    }

    func testPendingProfileSwitchSurvivesSealedStoreRelaunch() async {
        let s = store()
        let pending = ProfileSwitch(id: UUID(), target: "Trip", from: "Home", when: Date(timeIntervalSince1970: 123),
            switched: Profile(name: "Trip", defaultRoute: DIRECT, apps: [:]))
        s.update { setup in
            setup.saveAs("Home")
            setup.defaultRoute = DIRECT
            setup.saveAs("Trip")
            setup.pendingSwitch = pending
        }
        await settle()
        let reopened = store()
        XCTAssertEqual(reopened.setup.pendingSwitch, pending)
        XCTAssertEqual(pending.decide(current: reopened.setup, running: reopened.setup, refused: nil, standIn: .none, stopped: false), .applied)
        reopened.update { $0.pendingSwitch = nil }
        await settle()
        XCTAssertNil(store().setup.pendingSwitch)
    }

    func testTermsAcceptanceDoesNotChangeExistingDisclosureOrSetup() {
        defaults.set(true, forKey: "disclosed")
        let old = store()
        XCTAssertTrue(old.disclosed)
        XCTAssertFalse(old.termsAccepted)
        XCTAssertFalse(old.tourPending)
        let setup = old.setup
        old.termsAccepted = true
        let reopened = store()
        XCTAssertTrue(reopened.disclosed)
        XCTAssertTrue(reopened.termsAccepted)
        XCTAssertEqual(reopened.setup, setup)
        reopened.tourPending = true
        XCTAssertTrue(store().tourPending)
    }
    func testSafetySnoozeSchedulePersists() {
        let s = store()
        let now = Date(timeIntervalSince1970: 1_000_000)
        for (i, days) in [3, 7, 14, 14].enumerated() {
            s.snoozeSafety(now: now)
            let reopened = store()
            XCTAssertEqual(reopened.safetySnoozes, i + 1)
            XCTAssertEqual(reopened.safetyUntil, now.addingTimeInterval(Double(days) * 86400))
        }
        s.safetyNever = true
        s.safetyConnected = true
        XCTAssertTrue(store().safetyNever)
        XCTAssertTrue(store().safetyConnected)
    }
    func testSafetyNoticeRequiresKnownUnprotectedProfileAndFirstConnection() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func due(_ connected: Bool = true, _ never: Bool = false, _ until: Date = .distantPast,
                 _ demand: Bool? = false, _ kill: Bool? = false) -> Bool {
            Store.safetyDue(connected: connected, never: never, until: until, now: now, onDemand: demand, killSwitch: kill)
        }
        XCTAssertTrue(due())
        XCTAssertFalse(due(false))
        XCTAssertFalse(due(true, true))
        XCTAssertFalse(due(true, false, now.addingTimeInterval(1)))
        XCTAssertFalse(due(true, false, .distantPast, true))
        XCTAssertFalse(due(true, false, .distantPast, false, true))
        XCTAssertFalse(due(true, false, .distantPast, nil))
        XCTAssertFalse(due(true, false, .distantPast, false, nil))
    }
    private func readOnly(_ on: Bool) throws { try FileManager.default.setAttributes([.posixPermissions: on ? 0o500 : 0o700], ofItemAtPath: dir.path) }

    private let cached = ["mullvad|x|": Link.wg(Server(name: "se1", host: "se1", ip: "1.2.3.4", publicKey: "k", load: 0),
                                                WgPeer(name: "se1", privateKey: "p", address: ["10.0.0.2/32"], publicKey: "k", endpoint: "1.2.3.4:51820", allowedIps: ["0.0.0.0/0"]))]

    /// A signed-in store on disk: accounts, setup and cached tunnels, plus every other credential file.
    private func signedIn() async -> Store {
        let s = store()
        s.account("mullvad", "A")
        s.update { $0.routes = [Route(id: "main", loc: Location(provider: "mullvad"))]; $0.defaultRoute = "main" }
        s.rememberLinks(cached)
        await settle()
        let links = await s.lastLinks()
        XCTAssertEqual(links, cached)
        for name in Store.credentialFiles where !exists(name) { FileManager.default.createFile(atPath: dir.appending(path: name).path, contents: Data("x".utf8)) }
        return s
    }

    func testSignOutOfEverythingDeletesEveryCredentialFile() async throws {
        let s = await signedIn()
        XCTAssertTrue(Store.credentialFiles.contains("running.bin"))
        XCTAssertTrue(Store.credentialFiles.allSatisfy(exists))
        let gone = await s.forgetAll()
        XCTAssertTrue(gone)
        XCTAssertTrue(Store.credentialFiles.allSatisfy { !exists($0) })
        XCTAssertTrue(s.accounts.isEmpty)
        XCTAssertNil(defaults.object(forKey: "forgetAllPending"))
        XCTAssertTrue(store().accounts.isEmpty)
    }

    func testADeletionThatFailedIsFinishedAtLaunchAndNothingIsReadBackMeanwhile() async throws {
        let s = await signedIn()
        try readOnly(true)
        let gone = await s.forgetAll()
        XCTAssertFalse(gone)
        XCTAssertEqual(Set(defaults.stringArray(forKey: "forgetAllPending") ?? []), Set(Store.credentialFiles))
        // Still undeletable at the next launch: the old accounts and tunnels are there and readable, but never read,
        // held or merged back.
        let stuck = store()
        XCTAssertTrue(stuck.accounts.isEmpty)
        XCTAssertEqual(stuck.setup, Setup())
        XCTAssertFalse(stuck.isHeld)
        let old = await stuck.lastLinks()
        XCTAssertTrue(old.isEmpty)
        // Nor held while the keychain is locked.
        let real = key.withLock { $0 }
        key.withLock { $0 = nil }
        XCTAssertFalse(store().isHeld)
        key.withLock { $0 = real }
        // Deletable again: the launch finishes the job.
        try readOnly(false)
        let later = store()
        XCTAssertTrue(later.accounts.isEmpty)
        XCTAssertTrue(Store.credentialFiles.allSatisfy { !exists($0) })
        XCTAssertNil(defaults.object(forKey: "forgetAllPending"))
    }

    /// A sign-in after a deletion that failed writes new files: the next launch keeps them, and deletes only the rest.
    func testFilesWrittenAfterAFailedDeletionAreKept() async throws {
        let s = await signedIn()
        try readOnly(true)
        _ = await s.forgetAll()
        try readOnly(false)
        s.account("mullvad", "B")
        // A new tunnel cached for the new sign-in: the old cache isn't merged into it.
        let fresh = ["mullvad|y|": cached["mullvad|x|"]!]
        s.rememberLinks(fresh)
        await settle()
        XCTAssertFalse((defaults.stringArray(forKey: "forgetAllPending") ?? []).contains("accounts.bin"))
        XCTAssertFalse((defaults.stringArray(forKey: "forgetAllPending") ?? []).contains("links.bin"))
        XCTAssertTrue((defaults.stringArray(forKey: "forgetAllPending") ?? []).contains("setup.bin"))
        let next = store()
        let links = await next.lastLinks()
        XCTAssertEqual(links, fresh)
        XCTAssertEqual(next.accounts, ["mullvad": "B"])
        XCTAssertEqual(next.setup, Setup())
        XCTAssertTrue(exists("links.bin"))
        XCTAssertFalse(exists("running.bin"))
    }

    /// The running tunnel's record, written outside the store, follows the same rule: never read back while it awaits
    /// deletion; kept at the next launch once written again.
    func testARunningRecordWrittenAfterAFailedDeletionIsKept() async throws {
        let s = await signedIn()
        let key = key
        let vault = Sealed(dir: dir, key: { key.withLock { $0 } })
        let state = Running.State(setup: Setup(routes: [Route(id: "main", loc: Location(provider: "mullvad"))], defaultRoute: "main"), links: cached)
        try FileManager.default.removeItem(at: dir.appending(path: "running.bin"))
        Running.save(state, store: s, vault: vault)
        await settle()
        let before = await Running.load(store: s, vault: vault)
        XCTAssertEqual(before?.links, cached)
        try readOnly(true)
        _ = await s.forgetAll()
        XCTAssertTrue(s.awaitsDeletion("running.bin"))
        let pending = await Running.load(store: s, vault: vault)
        XCTAssertNil(pending)
        try readOnly(false)
        Running.save(state, store: s, vault: vault)
        await settle()
        XCTAssertFalse(s.awaitsDeletion("running.bin"))
        let next = store()
        let after = await Running.load(store: next, vault: vault)
        XCTAssertEqual(after?.links, cached)
        // A write from before the sign-out doesn't count.
        let early = s.writing("links.bin")
        FileManager.default.createFile(atPath: dir.appending(path: "links.bin").path, contents: Data("x".utf8))
        try readOnly(true)
        _ = await s.forgetAll()
        early(true)
        await settle()
        XCTAssertTrue(s.awaitsDeletion("links.bin"))
    }

    /// The record of what the extension sealed holds credentials too: Sign Out of Everything deletes it, it is never
    /// read back while that deletion is pending, and one written since is kept.
    func testTheSealedRecordIsACredentialFile() async throws {
        let s = await signedIn()
        let key = key
        let vault = Sealed(dir: dir, key: { key.withLock { $0 } })
        let setup = Setup(routes: [Route(id: "main", loc: Location(provider: "mullvad"))], defaultRoute: "main")
        try FileManager.default.removeItem(at: dir.appending(path: "sealed.bin"))
        Running.sealed(setup, store: s, vault: vault)
        await settle()
        let before = await Running.sealed(store: s, vault: vault)
        XCTAssertEqual(before, setup)
        let forgotten = await s.forgetAll()
        XCTAssertTrue(forgotten)
        XCTAssertFalse(exists("sealed.bin"))
        try readOnly(false)
        Running.sealed(setup, store: s, vault: vault)
        await settle()
        try readOnly(true)
        _ = await s.forgetAll()
        XCTAssertTrue(exists("sealed.bin"))
        XCTAssertTrue(s.awaitsDeletion("sealed.bin"))
        let pending = await Running.sealed(store: s, vault: vault)
        XCTAssertNil(pending)
        try readOnly(false)
        let unsealed = await Running.unsealed(store: s, vault: vault)
        XCTAssertTrue(unsealed)
        XCTAssertFalse(exists("sealed.bin"))
        await settle()
        XCTAssertFalse(s.awaitsDeletion("sealed.bin"))
        Running.sealed(setup, store: s, vault: vault)
        await settle()
        XCTAssertFalse(s.awaitsDeletion("sealed.bin"))
        let after = await Running.sealed(store: store(), vault: vault)
        XCTAssertEqual(after, setup)
    }

    /// The build that sealed this user's copy is known only while the record of that copy is (`Lifecycle.reseal`), and each
    /// launch notes its build, giving the one before.
    func testTheBuildMarkersFollowTheSealedRecord() async throws {
        let s = store()
        let key = key
        let vault = Sealed(dir: dir, key: { key.withLock { $0 } })
        let setup = Setup(routes: [Route(id: "main", loc: Location(provider: "mullvad"))], defaultRoute: "main")
        let none = await Running.sealedBy(store: s, vault: vault)
        XCTAssertNil(none)
        Running.sealed(setup, store: s, vault: vault, build: "7")
        await settle()
        let seven = await Running.sealedBy(store: s, vault: vault)
        XCTAssertEqual(seven, "7")
        // A copy no longer known (a seal that failed, a drop) and one about to be replaced take the marker with them.
        Running.sealed(nil, store: s, vault: vault, build: "8")
        await settle()
        let dropped = await Running.sealedBy(store: s, vault: vault)
        XCTAssertNil(dropped)
        Running.sealed(setup, store: s, vault: vault, build: "8")
        await settle()
        _ = await Running.unsealed(store: s, vault: vault)
        let unsealed = await Running.sealedBy(store: s, vault: vault)
        XCTAssertNil(unsealed)
        // A marker without its record says nothing.
        Running.sealed(setup, store: s, vault: vault, build: "8")
        await settle()
        try FileManager.default.removeItem(at: dir.appending(path: "sealed.bin"))
        let orphan = await Running.sealedBy(store: s, vault: vault)
        XCTAssertNil(orphan)
        let first = await Running.launched("7", vault: vault)
        XCTAssertNil(first)
        let second = await Running.launched("8", vault: vault)
        XCTAssertEqual(second, "7")
        let third = await Running.launched("8", vault: vault)
        XCTAssertEqual(third, "8")
        // A launch that can't be noted, or a note that can't be read, is never taken for a first launch.
        try readOnly(true)
        let unnoted = await Running.launched("9", vault: vault)
        XCTAssertEqual(unnoted, "9")
        try readOnly(false)
        let after = await Running.launched("9", vault: vault)
        XCTAssertEqual(after, "8")
        try FileManager.default.removeItem(at: dir.appending(path: "launched-build"))
        try FileManager.default.createDirectory(at: dir.appending(path: "launched-build"), withIntermediateDirectories: false)
        let unreadable = await Running.launched("10", vault: vault)
        XCTAssertEqual(unreadable, "10")
    }

    /// An owed drop keeps the sealing it named, so a retry never drops a copy sealed since; a new sign-out of that provider
    /// names its copy afresh. The list an older version wrote reads as owed drops not named yet.
    func testAnOwedDropKeepsTheSealingItNamed() async throws {
        let key = key
        let vault = Sealed(dir: dir, key: { key.withLock { $0 } })
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(["mullvad", ""]).write(to: dir.appending(path: "forget-sealed.json"))
        let old = await Running.owed(vault: vault)
        XCTAssertEqual(old, ["mullvad": "", "": ""])
        Running.owe("mullvad", named: "A", vault: vault)
        // Only a drop still owed is named.
        Running.owe("ivpn", named: "B", vault: vault)
        let named = await Running.owed(vault: vault)
        XCTAssertEqual(named, ["mullvad": "A", "": ""])
        Running.owe("mullvad", true, vault: vault)
        let again = await Running.owed(vault: vault)
        XCTAssertEqual(again, ["mullvad": "", "": ""])
        Running.owe("mullvad", false, vault: vault)
        Running.owe("", false, vault: vault)
        let none = await Running.owed(vault: vault)
        XCTAssertEqual(none, [:])
        XCTAssertFalse(exists("forget-sealed.json"))
    }

    /// An owed drop whose write failed isn't lost: the next change writes it too.
    func testAnOwedDropThatCouldNotBeWrittenIsWrittenWithTheNextChange() async throws {
        let key = key
        let vault = Sealed(dir: dir, key: { key.withLock { $0 } })
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A folder that can't be written: the write fails.
        try readOnly(true)
        Running.owe("mullvad", true, vault: vault)
        await FileWork.shared.drain()
        XCTAssertFalse(exists("forget-sealed.json"))
        // Tried again while the folder still can't be written: still kept.
        Running.retryOwed(vault: vault)
        await FileWork.shared.drain()
        XCTAssertFalse(exists("forget-sealed.json"))
        try readOnly(false)
        // Written again without another change (a settling of the drops, or the quit), before the queue drains.
        Running.retryOwed(vault: vault)
        await FileWork.shared.drain()
        let file = dir.appending(path: "forget-sealed.json")
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file)), ["mullvad": ""])
        Running.owe("ivpn", true, vault: vault)
        await FileWork.shared.drain()
        let written = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
        XCTAssertEqual(written, ["mullvad": "", "ivpn": ""])
        // Nothing unsaved: a retry leaves the file as it is.
        try Data("not json".utf8).write(to: file)
        Running.retryOwed(vault: vault)
        await FileWork.shared.drain()
        XCTAssertEqual(try Data(contentsOf: file), Data("not json".utf8))
        try FileManager.default.removeItem(at: file)
    }

    /// Turning Connect on Demand off that wasn't saved is on disk until it is: the user's Off, or one decided again; one
    /// that can't be read is decided again, never forgotten.
    func testAnOwedOnDemandOffSurvivesARelaunch() async throws {
        let key = key
        let vault = Sealed(dir: dir, key: { key.withLock { $0 } })
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let none = await Running.onDemandOwed(vault: vault)
        XCTAssertNil(none)
        for owed in [Lifecycle.OnDemandOwed.off, .hold] {
            Running.onDemandOwed(owed, vault: vault)
            let read = await Running.onDemandOwed(vault: vault)
            XCTAssertEqual(read, owed)
        }
        Running.onDemandOwed(nil, vault: vault)
        let cleared = await Running.onDemandOwed(vault: vault)
        XCTAssertNil(cleared)
        XCTAssertFalse(exists("ondemand-off"))
        try Data("?".utf8).write(to: dir.appending(path: "ondemand-off"))
        let unknown = await Running.onDemandOwed(vault: vault)
        XCTAssertEqual(unknown, .hold)
        // One that can't be written says so, so it is written again later.
        try FileManager.default.removeItem(at: dir.appending(path: "ondemand-off"))
        try readOnly(true)
        let written = expectation(description: "written")
        Running.onDemandOwed(.off, vault: vault) { XCTAssertFalse($0); written.fulfill() }
        await fulfillment(of: [written], timeout: 5)
        try readOnly(false)
        let ok = expectation(description: "written again")
        Running.onDemandOwed(.off, vault: vault) { XCTAssertTrue($0); ok.fulfill() }
        await fulfillment(of: [ok], timeout: 5)
    }

    /// Earlier versions only stored "something is pending": everything is deleted.
    func testAnOldPendingFlagDeletesEverything() async throws {
        _ = await signedIn()
        defaults.set(true, forKey: "forgetAllPending")
        XCTAssertTrue(store().accounts.isEmpty)
        XCTAssertTrue(Store.credentialFiles.allSatisfy { !exists($0) })
    }

    /// A keychain that can't be read says nothing about the files: they are held, never copied as ".bad", and come back
    /// once the key does. A file the key really can't open is kept as ".bad".
    func testBadCopiesOnlyWhenTheKeyWasReadable() async throws {
        _ = await signedIn()
        for name in Store.credentialFiles where name.hasSuffix(".bad") { try FileManager.default.removeItem(at: dir.appending(path: name)) }
        let real = key.withLock { $0 }
        key.withLock { $0 = nil }
        let locked = store()
        XCTAssertTrue(locked.accounts.isEmpty)
        XCTAssertTrue(locked.isHeld)
        XCTAssertFalse(exists("accounts.bin.bad"))
        XCTAssertFalse(exists("setup.bin.bad"))
        key.withLock { $0 = real }
        XCTAssertEqual(locked.reloadHeld(), ["accounts.bin", "setup.bin"])
        XCTAssertEqual(locked.accounts, ["mullvad": "A"])
        XCTAssertFalse(locked.isHeld)
        // Another key (a reset keychain): the file is unreadable for real.
        key.withLock { $0 = SymmetricKey(size: .bits256) }
        let reset = store()
        XCTAssertTrue(reset.accounts.isEmpty)
        XCTAssertTrue(exists("accounts.bin.bad"))
    }

    /// Held at launch, then the file turns out not to open once the key answers: kept as ".bad" before anything replaces it.
    func testAFileFoundBadAfterUnlockIsKept() async throws {
        _ = await signedIn()
        try FileManager.default.removeItem(at: dir.appending(path: "accounts.bin.bad"))
        try Data("not sealed".utf8).write(to: dir.appending(path: "accounts.bin"))
        let real = key.withLock { $0 }
        key.withLock { $0 = nil }
        let locked = store()
        XCTAssertTrue(locked.isHeld)
        key.withLock { $0 = real }
        locked.reloadHeld()
        XCTAssertTrue(exists("accounts.bin.bad"))
    }

    /// A second file that won't open replaces the ".bad" an earlier incident left, before a change writes over it; one
    /// that can't be kept as ".bad" at all is held, so a change never replaces it.
    func testASecondUnreadableFileIsKeptOverAnEarlierBadCopy() async throws {
        _ = await signedIn()
        let first = Data("first incident".utf8), second = Data("second incident".utf8)
        try first.write(to: dir.appending(path: "accounts.bin.bad"))
        try second.write(to: dir.appending(path: "accounts.bin"))
        let s = store()
        XCTAssertTrue(s.accounts.isEmpty)
        XCTAssertFalse(s.isHeld)
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "accounts.bin.bad")), second)
        s.account("ivpn", "B")
        await settle()
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "accounts.bin.bad")), second)
        // The copy fails (what is at ".bad" can't be removed): held, and the change leaves the file as it is.
        let fm = FileManager.default, bad = dir.appending(path: "accounts.bin.bad"), locked = bad.appending(path: "locked")
        try fm.removeItem(at: bad)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        fm.createFile(atPath: locked.appending(path: "f").path, contents: Data())
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        try second.write(to: dir.appending(path: "accounts.bin"))
        let stuck = store()
        XCTAssertTrue(stuck.isHeld)
        stuck.account("ivpn", "C")
        await settle()
        XCTAssertTrue(stuck.unsaved)
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "accounts.bin")), second)
        // Once the copy can be made, it is, and a change may follow.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        stuck.account("ivpn", "C")
        await settle()
        XCTAssertEqual(try Data(contentsOf: bad), second)
        XCTAssertFalse(stuck.isHeld)
        stuck.account("ivpn", "D")
        await settle()
        XCTAssertFalse(stuck.unsaved)
        XCTAssertNotEqual(try Data(contentsOf: dir.appending(path: "accounts.bin")), second)
    }

    /// A value that won't encode (a date that isn't a number) is a failed save: the file stays, the change is unsaved.
    func testASetupThatWontEncodeLeavesTheFileAndIsReportedUnsaved() async throws {
        let s = await signedIn()
        let before = try Data(contentsOf: dir.appending(path: "setup.bin"))
        s.update { $0.pendingSwitch = ProfileSwitch(id: UUID(), target: "x", when: Date(timeIntervalSinceReferenceDate: .nan), switched: Profile(name: "x", defaultRoute: DIRECT)) }
        await settle()
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "setup.bin")), before)
        XCTAssertTrue(s.unsaved)
    }

    /// Saved setups decode as before, the current format and the first build's alike; read strictly, a field that is
    /// there but can't be read fails, which is how the store tells a malformed file to keep as ".bad".
    func testSetupDecodingKeepsValidFilesAndRefusesMalformedValues() throws {
        let peer = #"{"name":"home","privateKey":"k","address":["10.0.0.2/32"],"publicKey":"p","endpoint":"host:51820","allowedIps":["0.0.0.0/0"]}"#
        // Current format: every kind of route, profiles, a pending switch, home, servers, options.
        var s = Setup()
        let wg = try JSONDecoder().decode(WgPeer.self, from: Data(peer.utf8))
        s.routes = [Route(id: "nl", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands")),
                    Route(id: "pin", loc: Location(provider: "mullvad", countryCode: "SE", country: "Sweden", region: "se-got",
                                                   pinned: Server(name: "se-got-wg-001", host: "h", ip: "203.0.113.7", publicKey: "pk", load: 3, city: "Gothenburg", country: "Sweden")), hue: 1),
                    Route(id: "w", wg: wg, hue: 2),
                    Route(id: "o", ovpn: OvpnProfile(name: "o", config: "client", username: "u", password: "pw"), hue: 3),
                    Route(id: "ss", ss: SsProfile(name: "s", server: "ss.example", port: 8388, method: "chacha20-ietf-poly1305", password: "pw"), hue: 4),
                    Route(id: "ts", tsExit: "100.64.0.1", tsName: "exit", hue: 5)]
        s.defaultRoute = "pin"
        s.apps = ["com.a": "w", "com.b": BLOCK, "com.c": DIRECT]; s.requireKillSwitchForBlocks()
        s.profiles = [Profile(name: "Work", defaultRoute: "nl", apps: ["com.a": "o"])]
        s.pendingSwitch = ProfileSwitch(id: UUID(), target: "Work", when: Date(timeIntervalSinceReferenceDate: 800_000_000), switched: s.profiles[0])
        s.profileSalt = "salt"
        s.home = Home(tailscale: true, subnets: ["192.168.178.0/24"]); s.home.wg = wg
        s.servers = [OwnServer(id: "x", wg: wg)]
        s.opts = ["nord": ["protect": "on"]]
        let encoder = JSONEncoder()
        encoder.userInfo[Setup.includeProfileSalt] = true
        XCTAssertEqual(try JSONDecoder().decode(Setup.self, from: encoder.encode(s)), s)
        // The first build's format: no options, profiles or salt; Prefs with customDns and no filter; Route.filter a Bool;
        // a WireGuard peer without keepalive.
        let first = #"{"routes":[{"id":"nl","loc":{"provider":"nord","countryId":153,"countryCode":"NL","country":"Netherlands"},"hue":0,"filter":false},"#
            + #"{"id":"us","loc":{"provider":"nord","countryId":228,"countryCode":"US","country":"United States","pinned":{"name":"us1","host":"us1.example","ip":"203.0.113.5","publicKey":"pk","load":10,"city":"","country":""}},"hue":1,"filter":true},"#
            + #"{"id":"w","loc":{"provider":"nord"},"wg":\#(peer),"hue":2,"filter":false}],"defaultRoute":"nl","apps":{"com.a":"us","com.b":"w"},"#
            + #""favorites":[{"provider":"nord","countryId":228,"countryCode":"US","country":"United States"}],"home":{"tailscale":false,"subnets":[]},"#
            + #""prefs":{"threatProtection":true,"customDns":[],"lan":true,"stats":false,"killSwitch":false,"alwaysOn":false},"servers":[]}"#
        let old = try JSONDecoder().decode(Setup.self, from: Data(first.utf8))
        XCTAssertEqual(old.routes.map(\.id), ["nl", "us", "w"])
        // A route whose server source can't be read is left out on its own, not turned into "Nord, Fastest"; the apps
        // that were on it are blocked until the user moves them, and the other routes are kept.
        let brokenWg = #"{"routes":[{"id":"nl"},{"id":"w","wg":{"name":"x"}}],"defaultRoute":"nl","apps":{"com.a":"w","com.b":"nl"}}"#
        let partial = try JSONDecoder().decode(Setup.self, from: Data(brokenWg.utf8))
        XCTAssertEqual(partial.routes.map(\.id), ["nl"])
        XCTAssertEqual(partial.apps, ["com.a": BLOCK, "com.b": "nl"])
        XCTAssertEqual(partial.blockedForLostRoute, 1)
        // A saved profile's apps on that route are blocked too, not left to follow the profile's default.
        let withProfile = #"{"routes":[{"id":"nl"},{"id":"w","wg":{"name":"x"}}],"defaultRoute":"nl","profiles":[{"name":"Work","defaultRoute":"nl","apps":{"com.a":"w","com.b":"nl"}}]}"#
        let profiled = try JSONDecoder().decode(Setup.self, from: Data(withProfile.utf8))
        XCTAssertEqual(profiled.profiles.first?.apps, ["com.a": BLOCK, "com.b": "nl"])
        // Protection that can't be read stays on; one that is simply missing takes its default.
        let unreadable = try JSONDecoder().decode(Setup.self, from: Data(#"{"prefs":{"killSwitch":"yes","alwaysOn":null}}"#.utf8))
        XCTAssertTrue(unreadable.prefs.killSwitch)
        XCTAssertTrue(unreadable.prefs.alwaysOn)
        XCTAssertFalse(try JSONDecoder().decode(Setup.self, from: Data(#"{"prefs":{}}"#.utf8)).prefs.killSwitch)
        XCTAssertEqual(old.routes[1].loc.pinned?.name, "us1")
        XCTAssertEqual(old.routes[2].wg?.allowedIps, ["0.0.0.0/0"])
        XCTAssertEqual(old.apps, ["com.a": "us", "com.b": "w"])
        XCTAssertEqual(old.favorites.map(\.countryCode), ["US"])
        // Missing: the default, as before; null only where no value is needed.
        let sparse = try JSONDecoder().decode(Setup.self, from: Data(#"{"routes":[{"id":"x","wg":null}],"profile":null}"#.utf8))
        XCTAssertEqual(sparse.routes.first?.hue, 0)
        XCTAssertNil(sparse.routes.first?.wg)
        // There but unreadable: read strictly, the whole file fails, rather than one route quietly becoming "Nord, Fastest".
        let noAllowed = peer.replacingOccurrences(of: #","allowedIps":["0.0.0.0/0"]"#, with: "")
        for bad in [#"{"routes":[{"id":"w","wg":\#(noAllowed)}],"defaultRoute":"w"}"#, #"{"routes":[{"id":"x","hue":"one"}]}"#,
                    #"{"routes":[{"id":"o","ovpn":{"name":"o"}}]}"#, #"{"home":{"wg":\#(noAllowed)}}"#, #"{"prefs":{"lan":"yes"}}"#,
                    #"{"apps":["com.a"]}"#, #"{"apps":null}"#, #"{"routes":[{"id":"x","hue":null}]}"#, #"{"prefs":{"killSwitch":null}}"#] {
            XCTAssertThrowsError(try SavedDecoding.$strict.withValue(true) { try JSONDecoder().decode(Setup.self, from: Data(bad.utf8)) }, bad)
            XCTAssertNoThrow(try JSONDecoder().decode(Setup.self, from: Data(bad.utf8)), bad)
        }
        // The sealed record: a malformed value inside it takes its default as before (the routes stay); a record without
        // its setup is unknown, not a default setup read from the wrapper.
        var mullvad = Setup()
        mullvad.routes = [Route(id: "m", loc: Location(provider: "mullvad"))]; mullvad.defaultRoute = "m"
        let wrapped = try JSONEncoder().encode(Running.SealedState(setup: mullvad, linked: ["m"]))
        XCTAssertEqual(Running.decodeSealed(wrapped)?.setup.routes.first?.loc.provider, "mullvad")
        let broken = String(decoding: wrapped, as: UTF8.self).replacingOccurrences(of: #""lan":true"#, with: #""lan":"yes""#)
        XCTAssertNotEqual(broken, String(decoding: wrapped, as: UTF8.self))
        XCTAssertEqual(Running.decodeSealed(Data(broken.utf8))?.setup.routes.first?.loc.provider, "mullvad")
        XCTAssertNil(Running.decodeSealed(Data(#"{"linked":["m"]}"#.utf8)))
    }

    /// A cached catalogue is fresh for a day after it was written, and not when its date is ahead of the clock.
    func testACatalogueDatedInTheFutureIsNotFresh() async throws {
        let s = store()
        s.countries("nord", [])
        await settle()
        let file = dir.appending(path: "countries-nord.bin").path
        XCTAssertTrue(s.countriesFresh("nord"))
        for (age, fresh) in [(-3_600.0, false), (-60.0, false), (90_000.0, false), (3_600.0, true)] {
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-age)], ofItemAtPath: file)
            XCTAssertEqual(s.countriesFresh("nord"), fresh, "\(age)")
        }
    }

    /// A setup that opens but holds one malformed value (relaunched during a blocking pause, say): its blocks and the rest
    /// load as they are, the bad value takes its default as before, and the file is kept as ".bad" before anything is
    /// saved over it.
    func testASetupWithOneMalformedValueKeepsItsBlocksAndTheOriginal() async throws {
        var s = Setup()
        s.apps = ["com.blocked": BLOCK, "com.vpn": "nl"]; s.requireKillSwitchForBlocks()
        var json = try XCTUnwrap(String(data: JSONEncoder().encode(s), encoding: .utf8))
        json = json.replacingOccurrences(of: #""stats":false"#, with: #""stats":"FAKE""#)
        XCTAssertTrue(json.contains("FAKE"))
        let vault = Sealed(dir: dir, key: { [key] in key.withLock { $0 } })
        XCTAssertTrue(vault.write("setup.bin", Data(json.utf8)))
        let original = try Data(contentsOf: dir.appending(path: "setup.bin"))
        let loaded = store()
        XCTAssertEqual(loaded.setup.apps, s.apps)
        XCTAssertEqual(loaded.setup.prefs.killLevel, s.prefs.killLevel)
        XCTAssertFalse(loaded.isHeld)
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "setup.bin.bad")), original)
        loaded.update { $0.apps["com.other"] = DIRECT }
        await settle()
        XCTAssertEqual(try Data(contentsOf: dir.appending(path: "setup.bin.bad")), original)
        XCTAssertEqual(store().setup.apps["com.blocked"], BLOCK)
        // The copy can't be made (what is at ".bad" can't be removed): the blocks still load, and a new block is saved as
        // before, so it survives a restart. Protection comes before the copy.
        let fm = FileManager.default, bad = dir.appending(path: "setup.bin.bad"), locked = bad.appending(path: "locked")
        XCTAssertTrue(vault.write("setup.bin", Data(json.utf8)))
        try fm.removeItem(at: bad)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        fm.createFile(atPath: locked.appending(path: "f").path, contents: Data())
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let stuck = store()
        XCTAssertEqual(stuck.setup.apps, s.apps)
        XCTAssertFalse(stuck.isHeld)
        stuck.update { $0.apps["com.more"] = BLOCK }
        await settle()
        XCTAssertFalse(stuck.unsaved)
        XCTAssertEqual(store().setup.apps["com.more"], BLOCK)
        XCTAssertEqual(store().setup.apps["com.blocked"], BLOCK)
    }

    /// A change made while held is reported unsaved, even if an earlier warning was dismissed.
    func testAChangeWhileHeldIsReportedEvenAfterADismissal() async throws {
        _ = await signedIn()
        key.withLock { $0 = nil }
        let locked = store()
        locked.unsavedDismissed = true
        locked.account("ivpn", "B")
        XCTAssertTrue(locked.unsaved)
        XCTAssertFalse(locked.unsavedDismissed)
    }

    func testLastSignOutRemovesBadCopiesWithoutDeletingOtherFiles() async throws {
        let s = await signedIn()
        await s.forgetBadCopies()
        for name in Store.credentialFiles where name.hasSuffix(".bad") { XCTAssertFalse(exists(name), name) }
        XCTAssertTrue(exists("accounts.bin"))
        XCTAssertTrue(exists("setup.bin"))
    }

    func testSaveAcknowledgementRequiresItsOwnSuccessfulWrite() async throws {
        let s = store()
        let done = expectation(description: "saved")
        s.update { $0.home.tsAuthKey = "secret" }
        s.confirmSetup { ok in XCTAssertTrue(ok); done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(store().setup.home.tsAuthKey, "secret")

        try readOnly(true)
        let failed = expectation(description: "failed")
        s.update { $0.home.tsAuthKey = "other" }
        s.confirmSetup { ok in XCTAssertFalse(ok); failed.fulfill() }
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertTrue(s.unsaved)
    }

    func testCleanupWaitsForSuccessfulRetryAndItsOwnFile() async throws {
        let s = store()
        let clipboard = Mutex("secret")
        try readOnly(true)
        s.update { $0.home.tsAuthKey = "secret" }
        s.afterSave("setup") { clipboard.withLock { value in if clipboardContains(value, secret: "secret") { value = "" } } }
        s.confirmSetup { _ in }
        await settle()
        XCTAssertEqual(clipboard.withLock { $0 }, "secret")
        try readOnly(false)
        s.account("other", "account")
        await settle()
        XCTAssertEqual(clipboard.withLock { $0 }, "secret")
        s.retrySave()
        await settle()
        XCTAssertEqual(clipboard.withLock { $0 }, "")
    }

    func testCleanupDoesNotClearReplacedClipboardOrSurviveForget() async throws {
        let s = store()
        let clipboard = Mutex("replacement")
        try readOnly(true)
        s.afterSave("accounts") { clipboard.withLock { value in if clipboardContains(value, secret: "secret") { value = "" } } }
        s.account("p", "secret")
        await settle()
        try readOnly(false)
        s.retrySave()
        await settle()
        XCTAssertEqual(clipboard.withLock { $0 }, "replacement")
        s.afterSave("accounts") { clipboard.withLock { $0 = "cleared" } }
        _ = await s.forgetAll()
        s.account("p", "new")
        await settle()
        XCTAssertEqual(clipboard.withLock { $0 }, "replacement")
    }

    func testFailedSaveLeavesClipboardValueAlone() async throws {
        let s = store()
        let clipboard = Mutex("secret")
        try readOnly(true)
        s.update { $0.home.tsAuthKey = "secret" }
        let done = expectation(description: "failed")
        s.confirmSetup { ok in
            if ok { clipboard.withLock { value in if clipboardContains(value, secret: "secret") { value = "" } } }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(clipboard.withLock { $0 }, "secret")
    }

    /// Every write holds the whole setup: once a newer one is on disk, an older change it replaced is settled too, so a
    /// secret pasted for it can leave the clipboard.
    func testNewerWriteSettlesOlderChange() async throws {
        let s = store()
        let release = DispatchSemaphore(value: 0)
        FileWork.shared.submit { release.wait() }
        let old = expectation(description: "old")
        let new = expectation(description: "new")
        s.update { $0.home.tsAuthKey = "old" }
        s.confirmSetup { ok in XCTAssertTrue(ok); old.fulfill() }
        s.update { $0.home.tsAuthKey = "new" }
        s.confirmSetup { ok in XCTAssertTrue(ok); new.fulfill() }
        release.signal()
        await fulfillment(of: [old, new], timeout: 5)
    }

    func testHeldWriteIsNotAcknowledged() async throws {
        _ = await signedIn()
        key.withLock { $0 = nil }
        let s = store()
        s.update { $0.home.tsAuthKey = "secret" }
        let done = expectation(description: "held")
        s.confirmSetup { ok in XCTAssertFalse(ok); done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertTrue(s.unsaved)
    }

    /// A last sign-out that can't be written stays visible and comes back after a restart: reported, with Retry.
    func testAFailedSignOutWriteIsReportedAndRetried() async throws {
        let s = await signedIn()
        try readOnly(true)
        s.account("mullvad", nil)
        await settle()
        XCTAssertTrue(s.unsaved)
        XCTAssertTrue(s.accounts.isEmpty)
        try readOnly(false)
        s.retrySave()
        await settle()
        XCTAssertFalse(s.unsaved)
        XCTAssertTrue(store().accounts.isEmpty)
    }

    /// A takeover tells a record the keychain can't open yet (wait) from none to go by (no file, a damaged one, one
    /// awaiting deletion), and reads the account fingerprints back; an older version's record has none.
    func testTheRunningRecordAsATakeoverReadsIt() async throws {
        let s = await signedIn()
        let key = key
        let vault = Sealed(dir: dir, key: { key.withLock { $0 } })
        try? FileManager.default.removeItem(at: dir.appending(path: "running.bin"))
        func read() async -> String {
            switch await Running.read(store: s, vault: vault) {
            case .locked: "locked"
            case .none: "none"
            case .record(let r): "record \(r.accounts?.sorted { $0.key < $1.key }.map(\.value) ?? ["legacy"])"
            }
        }
        var r = await read()
        XCTAssertEqual(r, "none")
        let setup = Setup(routes: [Route(id: "main", loc: Location(provider: "mullvad"))], defaultRoute: "main")
        Running.save(.init(setup: setup, links: cached, accounts: Running.fingerprints(["mullvad": "A"])), store: s, vault: vault)
        await settle()
        r = await read()
        XCTAssertEqual(r, "record [\"\(Running.fingerprint("A"))\"]")
        // The keychain doesn't answer: a record that exists is waited for, no record is none.
        let saved = key.withLock { k in defer { k = nil }; return k }
        r = await read()
        XCTAssertEqual(r, "locked")
        try FileManager.default.moveItem(at: dir.appending(path: "running.bin"), to: dir.appending(path: "running.keep"))
        r = await read()
        XCTAssertEqual(r, "none")
        try FileManager.default.moveItem(at: dir.appending(path: "running.keep"), to: dir.appending(path: "running.bin"))
        key.withLock { $0 = saved }
        r = await read()
        XCTAssertTrue(r.hasPrefix("record"))
        // An older version's record (no fingerprints) still reads.
        struct Old: Encodable { var setup: Setup; var links: [String: Link] }
        XCTAssertTrue(vault.write("running.bin", try JSONEncoder().encode(Old(setup: setup, links: cached))))
        r = await read()
        XCTAssertEqual(r, "record [\"legacy\"]")
        // Damaged with the key there: nothing to go by, not a wait.
        try Data("damaged".utf8).write(to: dir.appending(path: "running.bin"))
        r = await read()
        XCTAssertEqual(r, "none")
        // Awaiting deletion: never read back.
        Running.save(.init(setup: setup, links: cached, accounts: [:]), store: s, vault: vault)
        await settle()
        try readOnly(true)
        _ = await s.forgetAll()
        XCTAssertTrue(s.awaitsDeletion("running.bin"))
        r = await read()
        XCTAssertEqual(r, "none")
        try readOnly(false)
    }
    func testSuccessfulRunningWriteClearsTheSessionTaint() async throws {
        let s = store(), key = key
        let vault = Sealed(dir: dir, key: { key.withLock { $0 } })
        let marked = await Running.taint(vault: vault)
        XCTAssertTrue(marked)
        Running.save(.init(setup: Setup(), links: [:]), store: s, vault: vault)
        await settle()
        let tainted = await Running.tainted(vault: vault)
        XCTAssertFalse(tainted)
        XCTAssertFalse(exists("running-tainted"))
    }

    func testDeletionAndFailedRunningWritesDoNotClearTaint() async throws {
        let s = store(), key = key
        let vault = Sealed(dir: dir, key: { key.withLock { $0 } })
        var saved = 0
        _ = await Running.taint(vault: vault)
        Running.save(nil, store: s, vault: vault) { saved += 1 }
        await settle()
        var tainted = await Running.tainted(vault: vault)
        XCTAssertTrue(tainted)
        let heldKey = key.withLock { k in defer { k = nil }; return k }
        Running.save(.init(setup: Setup(), links: [:]), store: s, vault: vault) { saved += 1 }
        await settle()
        tainted = await Running.tainted(vault: vault)
        XCTAssertTrue(tainted)
        key.withLock { $0 = heldKey }
        var invalid = Setup()
        invalid.pendingSwitch = ProfileSwitch(id: UUID(), target: "bad", when: Date(timeIntervalSince1970: .infinity),
                                              switched: Profile(name: "bad", defaultRoute: DIRECT))
        Running.save(.init(setup: invalid, links: [:]), store: s, vault: vault) { saved += 1 }
        await settle()
        tainted = await Running.tainted(vault: vault)
        XCTAssertTrue(tainted, "an encoding failure is not a successful non-nil write")
        XCTAssertEqual(saved, 0, "deletions and failures must not trigger settlement as a fresh save")
        Running.save(.init(setup: Setup(), links: [:]), store: s, vault: vault) { saved += 1 }
        await settle()
        XCTAssertEqual(saved, 1)
    }

    func testAnOlderWriteCannotClearANewerSessionTaint() async throws {
        let s = store(), key = key
        let vault = Sealed(dir: dir, key: { key.withLock { $0 } })
        Running.save(.init(setup: Setup(), links: [:]), store: s, vault: vault)
        // No yield between submitting the write and setting the new in-memory taint.
        _ = await Running.taint(vault: vault)
        await settle()
        // Exercise the in-memory fence independently of the disk marker.
        try FileManager.default.removeItem(at: dir.appending(path: "running-tainted"))
        let tainted = await Running.tainted(vault: vault)
        XCTAssertTrue(tainted)
        Running.save(.init(setup: Setup(), links: [:]), store: s, vault: vault)
        await settle()
    }

    private func pruningRecord() -> Running.State {
        let link = cached.values.first!
        guard case .wg(_, let peer, _, _) = link else { preconditionFailure() }
        let setup = Setup(routes: [Route(id: "a", loc: Location(provider: "mullvad")),
                                   Route(id: "b", loc: Location(provider: "mullvad")),
                                   Route(id: "other", loc: Location(provider: "ivpn")),
                                   Route(id: "own", wg: peer)], defaultRoute: "a")
        return .init(setup: setup, links: ["a": link, "b": link, "other": link, "own": link],
                     accounts: Running.fingerprints(["mullvad": "A", "ivpn": "B"]))
    }

    func testPruningRemovesOnlyTheSignedOutProvidersLinksAndFingerprint() throws {
        let record = pruningRecord()
        let pruned = Running.pruning(record, provider: "mullvad", account: Running.fingerprint("A"))
        XCTAssertEqual(Set(pruned.links.keys), ["other", "own"])
        XCTAssertEqual(pruned.accounts, Running.fingerprints(["ivpn": "B"]))
        XCTAssertEqual(pruned.setup, record.setup)
        XCTAssertEqual(Running.digest(pruned.setup), Running.digest(record.setup))
        let newer = Running.pruning(record, provider: "mullvad", account: Running.fingerprint("old account"))
        XCTAssertEqual(newer.links, record.links)
        XCTAssertEqual(newer.accounts, record.accounts)
        struct Old: Encodable { var setup: Setup; var links: [String: Link] }
        let old = try JSONDecoder().decode(Running.State.self, from: JSONEncoder().encode(Old(setup: record.setup, links: record.links)))
        let legacy = Running.pruning(old, provider: "mullvad", account: Running.fingerprint("A"))
        XCTAssertNil(legacy.accounts)
        XCTAssertEqual(legacy.links, pruned.links)
    }

    func testRunningPruneIsSerializedWithSavesAndCanRetryAFailedWrite() async throws {
        let s = store(), key = key
        let vault = Sealed(dir: dir, key: { key.withLock { $0 } })
        let record = pruningRecord()
        Running.save(record, store: s, vault: vault)
        await settle()
        try readOnly(true)
        var pruned = await Running.prune("mullvad", account: Running.fingerprint("A"), store: s, vault: vault)
        XCTAssertFalse(pruned)
        var back = await Running.load(store: s, vault: vault)
        XCTAssertEqual(back?.links, record.links)
        try readOnly(false)
        pruned = await Running.prune("mullvad", account: Running.fingerprint("A"), store: s, vault: vault)
        XCTAssertTrue(pruned)
        back = await Running.load(store: s, vault: vault)
        XCTAssertEqual(Set(back?.links.keys ?? [:].keys), ["other", "own"])
        XCTAssertEqual(back?.setup, record.setup)
        // A queued newer write is read within the prune's file-queue turn, not overwritten by an earlier snapshot.
        var newer = record
        newer.accounts?["mullvad"] = Running.fingerprint("new")
        Running.save(newer, store: s, vault: vault)
        pruned = await Running.prune("mullvad", account: Running.fingerprint("A"), store: s, vault: vault)
        XCTAssertTrue(pruned)
        back = await Running.load(store: s, vault: vault)
        XCTAssertEqual(back?.accounts, newer.accounts)
        XCTAssertEqual(back?.links, newer.links)
    }

    func testUnknownSignOutKeepsOnlyCurrentAccountsPerProvider() {
        let record = pruningRecord()
        let current = Running.fingerprints(["mullvad": "A", "ivpn": "new B"])
        let pruned = Running.pruning(record, provider: "", account: nil, current: current)
        XCTAssertEqual(Set(pruned.links.keys), ["a", "b", "own"])
        XCTAssertEqual(pruned.accounts, Running.fingerprints(["mullvad": "A"]))
        XCTAssertEqual(pruned.setup, record.setup)
        let signedOut = Running.pruning(record, provider: "", account: nil, current: [:])
        XCTAssertEqual(Set(signedOut.links.keys), ["own"])
        XCTAssertEqual(signedOut.accounts, [:])
        let known = Running.pruning(record, provider: "mullvad", account: Running.fingerprint("A"), current: current)
        XCTAssertEqual(Set(known.links.keys), ["other", "own"], "a known sign-out still removes its own account")
    }

    func testUnknownSignOutPrunesOldRecordsWithoutFingerprints() throws {
        struct Old: Encodable { var setup: Setup; var links: [String: Link] }
        let record = pruningRecord()
        let old = try JSONDecoder().decode(Running.State.self, from: JSONEncoder().encode(Old(setup: record.setup, links: record.links)))
        let pruned = Running.pruning(old, provider: "", account: nil, current: record.accounts!)
        XCTAssertEqual(Set(pruned.links.keys), ["own"])
        XCTAssertNil(pruned.accounts)
        XCTAssertEqual(pruned.setup, record.setup)
    }

    func testUnknownSignOutAfterFreshSaveKeepsSignedInProviders() async throws {
        let s = store(), key = key
        let vault = Sealed(dir: dir, key: { key.withLock { $0 } })
        let record = pruningRecord()
        s.account("mullvad", "A")
        s.account("ivpn", "B")
        // The retry reads a record queued after the sign-out, using the store's current accounts.
        for provider in ["", "mullvad"] {
            Running.save(record, store: s, vault: vault)
            let pruned = await Running.prune(provider, account: nil, store: s, vault: vault)
            XCTAssertTrue(pruned)
            let back = await Running.load(store: s, vault: vault)
            XCTAssertEqual(back?.links, record.links)
            XCTAssertEqual(back?.accounts, record.accounts)
        }
    }

    func testFreshRunningSaveCanImmediatelySettleTaintedDebt() async throws {
        let s = store(), key = key
        let vault = Sealed(dir: dir, key: { key.withLock { $0 } })
        _ = await Running.taint(vault: vault)
        let pruned: Bool = await withCheckedContinuation { done in
            Running.save(pruningRecord(), store: s, vault: vault) {
                Task { done.resume(returning: await Running.prune("mullvad", account: nil, store: s, vault: vault)) }
            }
        }
        XCTAssertTrue(pruned)
        let back = await Running.load(store: s, vault: vault)
        XCTAssertEqual(Set(back?.links.keys ?? [:].keys), ["other", "own"])
    }

    func testRunningPruneDefersWhileTaintedAndDoesNotResurrectADeletedRecord() async throws {
        let s = store(), key = key
        let vault = Sealed(dir: dir, key: { key.withLock { $0 } })
        let record = pruningRecord()
        Running.save(record, store: s, vault: vault)
        await settle()
        _ = await Running.taint(vault: vault)
        var pruned = await Running.prune("mullvad", account: nil, store: s, vault: vault)
        XCTAssertFalse(pruned)
        let back = await Running.load(store: s, vault: vault)
        XCTAssertEqual(back?.links, record.links)
        Running.save(nil, store: s, vault: vault)
        pruned = await Running.prune("mullvad", account: nil, store: s, vault: vault)
        XCTAssertTrue(pruned)
        XCTAssertFalse(exists("running.bin"))
        let tainted = await Running.tainted(vault: vault)
        XCTAssertTrue(tainted, "absence settles the debt without clearing the taint fence")
        Running.save(record, store: s, vault: vault)
        await settle()
    }

}
