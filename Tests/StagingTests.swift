import XCTest
import Synchronization

/// The extension's store of configurations staged over XPC: what a start's unauthenticated options can name.
final class StagingTests: XCTestCase {
    private final class Clock: Sendable {
        let base = ContinuousClock.now
        let offset = Mutex(Duration.zero)
        var now: ContinuousClock.Instant { base + offset.withLock { $0 } }
        func advance(_ d: Duration) { offset.withLock { $0 += d } }
    }

    func testATokenWorksOnceAndOnlyForItsConfig() throws {
        let s = Staging()
        let a = try s.stage("A", persist: true, uid: 501, epoch: s.epoch(for: 501))
        let b = try s.stage("B", persist: false, uid: 502, epoch: s.epoch(for: 502))
        XCTAssertNotEqual(a.token, b.token)
        XCTAssertEqual(a.token.count, 64)
        XCTAssertFalse(a.token.contains(a.revision))
        let e = try XCTUnwrap(s.take(b.token))
        XCTAssertEqual(e.config, "B")
        XCTAssertFalse(e.persist)
        XCTAssertEqual(e.uid, 502)
        XCTAssertEqual(e.revision, Staging.revision("B"))
        XCTAssertNil(s.take(b.token), "replayed")
        XCTAssertEqual(s.take(a.token)?.config, "A")
        XCTAssertNil(s.take(""))
        XCTAssertNil(s.take("not a token"))
    }

    func testTheSameConfigStagedTwiceGetsTwoTokensAndOneRevision() throws {
        let s = Staging()
        let a = try s.stage("A", persist: true, uid: 501, epoch: s.epoch(for: 501)), b = try s.stage("A", persist: true, uid: 501, epoch: s.epoch(for: 501))
        XCTAssertNotEqual(a.token, b.token)
        XCTAssertEqual(a.revision, b.revision)
        XCTAssertNotEqual(a.revision, Staging.revision("B"))
    }

    func testATokenExpires() throws {
        let clock = Clock()
        let s = Staging(now: { clock.now })
        let a = try s.stage("A", persist: true, uid: 501, epoch: s.epoch(for: 501))
        let b = try s.stage("B", persist: true, uid: 501, epoch: s.epoch(for: 501))
        clock.advance(Staging.lifetime - .seconds(1))
        XCTAssertNotNil(s.take(a.token))
        clock.advance(.seconds(1))
        XCTAssertNil(s.take(b.token), "expired")
    }

    func testOnlyAFewWaitAndTheOldestMakesRoom() throws {
        let clock = Clock()
        let s = Staging(now: { clock.now })
        var tokens: [String] = []
        for i in 0...Staging.capacity {
            tokens.append(try s.stage("\(i)", persist: false, uid: 501, epoch: s.epoch(for: 501)).token)
            clock.advance(.milliseconds(1))
        }
        XCTAssertNil(s.take(tokens[0]), "evicted")
        for t in tokens.dropFirst() { XCTAssertNotNil(s.take(t)) }
    }

    func testClearDropsEverythingAUserHasPendingAndWhatIsBeingChecked() throws {
        let s = Staging()
        let a = try s.stage("A", persist: true, uid: 501, epoch: s.epoch(for: 501))
        let other = try s.stage("B", persist: true, uid: 502, epoch: s.epoch(for: 502))
        // A check that began before the reset finishes after it: nothing it staged may survive the reset.
        let before = s.epoch(for: 501), otherBefore = s.epoch(for: 502)
        s.clear(uid: 501)
        XCTAssertNil(s.take(a.token))
        XCTAssertThrowsError(try s.stage("B", persist: true, uid: 501, epoch: before))
        XCTAssertNoThrow(try s.stage("B", persist: true, uid: 501, epoch: s.epoch(for: 501)))
        // Another user's sign-out or reset leaves this user's pending changes, and their checks under way, alone.
        XCTAssertEqual(s.epoch(for: 502), otherBefore)
        XCTAssertNoThrow(try s.stage("C", persist: true, uid: 502, epoch: otherBefore))
        XCTAssertEqual(s.take(other.token)?.config, "B")
    }

    func testAUserCanPushOutOnlyTheirOwnPendingChanges() throws {
        let clock = Clock()
        let s = Staging(now: { clock.now })
        let a = try s.stage("A", persist: true, uid: 501, epoch: s.epoch(for: 501))
        clock.advance(.milliseconds(1))
        var resets: [String] = []
        for _ in 0...Staging.capacity {
            _ = try s.stage("B", persist: true, uid: 502, epoch: s.epoch(for: 502))
            resets.append(try s.stage("", persist: false, uid: 502, epoch: s.epoch(for: 502), for: .reset).token)
            clock.advance(.milliseconds(1))
        }
        XCTAssertEqual(s.take(a.token)?.config, "A", "another user's many stages and resets don't evict it")
        XCTAssertNil(s.take(resets[0], for: .reset), "their own oldest went")
        // A user's resets and runs make room separately: a burst of resets leaves their own pending start.
        let run = try s.stage("A", persist: true, uid: 501, epoch: s.epoch(for: 501))
        for _ in 0...Staging.capacity { _ = try s.stage("", persist: false, uid: 501, epoch: s.epoch(for: 501), for: .reset) }
        XCTAssertNotNil(s.take(run.token))
    }

    func testWhatRunsDecidesTheAcknowledgement() {
        let r = Staging.revision("A"), old = Staging.revision("old")
        // Persisted: durable only once the sealed copy is this one.
        XCTAssertEqual(EngineAck.outcome(running: r, durable: r, revision: r, persist: true), .runs(durable: true))
        XCTAssertEqual(EngineAck.outcome(running: r, durable: nil, revision: r, persist: true), .runs(durable: false))
        XCTAssertEqual(EngineAck.outcome(running: r, durable: old, revision: r, persist: true), .runs(durable: false))
        // A pause isn't sealed: on-demand needs some sealed copy to start, never this one.
        XCTAssertEqual(EngineAck.outcome(running: r, durable: old, revision: r, persist: false), .runs(durable: true))
        XCTAssertEqual(EngineAck.outcome(running: r, durable: nil, revision: r, persist: false), .runs(durable: false))
        // Connected with something else (the sealed copy, after the token expired), or nothing at all.
        XCTAssertEqual(EngineAck.outcome(running: old, durable: old, revision: r, persist: true), .other)
        XCTAssertEqual(EngineAck.outcome(running: nil, durable: r, revision: r, persist: true), .other)
    }

    func testConcurrentStartsUseOneTokenOnce() throws {
        let s = Staging()
        let a = try s.stage("A", persist: true, uid: 501, epoch: s.epoch(for: 501))
        let wins = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if s.take(a.token) != nil { wins.withLock { $0 += 1 } }
        }
        XCTAssertEqual(wins.withLock { $0 }, 1)
    }

    func testStartOptionsCanOnlyNameAToken() {
        XCTAssertNil(Staging.token(in: nil))
        XCTAssertNil(Staging.token(in: [:]))
        // The old way in: a configuration in the options themselves. Ignored, persist flag and all.
        XCTAssertNil(Staging.token(in: ["config": "{}", "persist": NSNumber(value: true)]))
        XCTAssertNil(Staging.token(in: ["token": NSNumber(value: 1)]))
        XCTAssertEqual(Staging.token(in: ["token": "abc", "config": "{}"]), "abc")
    }

    func testAResetTokenIsGoodForAResetOnly() throws {
        let s = Staging()
        let reset = try s.stage("", persist: false, uid: 501, epoch: s.epoch(for: 501), for: .reset)
        XCTAssertNil(s.take(reset.token), "a reset token can't start or reload anything")
        let reset2 = try s.stage("", persist: false, uid: 501, epoch: s.epoch(for: 501), for: .reset)
        XCTAssertEqual(s.take(reset2.token, for: .reset)?.uid, 501)
        let run = try s.stage("A", persist: true, uid: 501, epoch: s.epoch(for: 501))
        XCTAssertNil(s.take(run.token, for: .reset), "a configuration's token can't reset")
        XCTAssertNil(s.take(run.token), "and is gone once tried")
    }

    func testEachUserSeesAndChangesOnlyTheEngineTheyStarted() {
        // Nothing runs: anyone may start. Running: only its owner stages, watches or changes it.
        XCTAssertTrue(Ownership.mayStage(502, running: nil))
        XCTAssertTrue(Ownership.mayStage(501, running: 501))
        XCTAssertFalse(Ownership.mayStage(502, running: 501))
        XCTAssertTrue(Ownership.mayUse(501, running: 501))
        XCTAssertFalse(Ownership.mayUse(502, running: 501))
        XCTAssertFalse(Ownership.mayUse(501, running: nil))
    }

    func testAResetStopsOnlyTheirOwnEngine() {
        // Another user's engine runs: their engine and identity stay; only the asker's own identity goes. The sealed copy
        // gets what a sign-out would do to it either way (see the sign-out test), so a Tailscale key can't outlive it.
        XCTAssertEqual(Ownership.reset(502, running: 501), .ownIdentity)
        XCTAssertEqual(Ownership.reset(501, running: 501), .everything)
        XCTAssertEqual(Ownership.reset(502, running: nil), .everything)
    }

    func testTheSealedCopyCarriesItsOwnerAndAnOlderOneHasNone() throws {
        let config = try XCTUnwrap(Fixture.text("golden/example.json").nilIfEmpty)
        let sealed = try XCTUnwrap(SealedPolicy.encode(config, owner: 501))
        let back = try XCTUnwrap(SealedPolicy.decode(sealed))
        XCTAssertEqual(back.config, config)
        XCTAssertEqual(back.owner, 501)
        // What older versions sealed: the bare configuration. Nobody's, so nobody's to start.
        XCTAssertNil(SealedPolicy.decode(Data(config.utf8)))
        for bad in [#"{"config":"{}"}"#, #"{"config":"{}","owner":true}"#, #"{"config":"{}","owner":-1}"#, #"{"config":1,"owner":501}"#, "[]", "x"] {
            XCTAssertNil(SealedPolicy.decode(Data(bad.utf8)), bad)
        }
    }

    func testASignOutDropsOnlyAUsersOwnSealedCopy() {
        XCTAssertEqual(Ownership.forget(501, seal: .owner(501)), .drop)
        XCTAssertNil(Ownership.forget(502, seal: .owner(501)), "another user's: theirs to keep")
        XCTAssertEqual(Ownership.forget(502, seal: .none), .keep)
        // Nothing anyone can start: dropped (it may hold the account).
        XCTAssertEqual(Ownership.forget(502, seal: .legacy), .drop)
        // Whose it is can't be told now: never deleted, only never started as the signed-out user's.
        XCTAssertEqual(Ownership.forget(502, seal: .unreadable), .suppress)
    }

    /// A drop named for one sealing never drops a copy sealed since (it came, or ran, late), also one with the same content.
    func testALateDropNeverDropsANewerCopy() {
        let a = UUID().uuidString, b = UUID().uuidString
        XCTAssertTrue(Ownership.forgetStands(expected: a, current: a))
        XCTAssertFalse(Ownership.forgetStands(expected: a, current: b))
        XCTAssertFalse(Ownership.forgetStands(expected: "none", current: b), "sealed after a drop asked for while there was none")
        XCTAssertFalse(Ownership.forgetStands(expected: "unknown", current: b))
        // Nothing there that could be theirs: whatever is left is dropped or set aside as before.
        XCTAssertTrue(Ownership.forgetStands(expected: a, current: nil))
        XCTAssertTrue(Ownership.forgetStands(expected: "none", current: nil))
        // An id that can't be read fences nothing: a signed-out account's copy never stays for want of it.
        let unreadable = Ownership.sealing(501, seal: .owner(501), id: nil, unreadable: true)
        XCTAssertEqual(unreadable, Ownership.unreadableSealing)
        for expected in [a, "none", "unknown", Ownership.unreadableSealing] {
            XCTAssertTrue(Ownership.forgetStands(expected: expected, current: unreadable))
        }
        // Unreadable (or missing) when asked, readable now: no proof of a sealing since.
        for expected in [Ownership.unreadableSealing, "", "junk"] { XCTAssertTrue(Ownership.forgetStands(expected: expected, current: b)) }
        // A known id that turned missing, empty or malformed: no proof either.
        for current in ["unknown", "", "junk"] { XCTAssertTrue(Ownership.forgetStands(expected: a, current: current)) }
    }

    /// "ok" only once the drop went through; a drop that could only be set aside stays owed, and asked for again.
    func testADropThatOnlySetTheCopyAsideIsStillOwed() {
        XCTAssertEqual(Ownership.forgetResult(step: .drop, applied: true, suppressed: false), "ok")
        XCTAssertEqual(Ownership.forgetResult(step: .drop, applied: false, suppressed: true), "suppressed")
        XCTAssertEqual(Ownership.forgetResult(step: .drop, applied: false, suppressed: false), "failed")
        // An ownerless copy an older version sealed is dropped too, and owed the same way until it is.
        XCTAssertEqual(Ownership.forget(501, seal: .legacy), .drop)
        // A copy whose drop failed still goes once it can't be read (no downgrade to setting it aside); another user's
        // newer copy (a sealing clears the pending drop) is never touched.
        XCTAssertEqual(Ownership.forget(501, seal: .unreadable, dropPending: true), .drop)
        XCTAssertEqual(Ownership.forget(501, seal: .unreadable, dropPending: false), .suppress)
        XCTAssertNil(Ownership.forget(501, seal: .owner(502), dropPending: true))
        // Nothing there, or one that can't be read now set aside by design: done.
        XCTAssertEqual(Ownership.forgetResult(step: .keep, applied: true, suppressed: false), "ok")
        XCTAssertEqual(Ownership.forgetResult(step: .suppress, applied: true, suppressed: false), "ok")
        XCTAssertEqual(Ownership.forgetResult(step: .suppress, applied: false, suppressed: false), "failed")
    }

    /// The sealing's id is told only for a copy that may be this user's: theirs, ownerless, or unreadable now.
    func testASealingIsNamedOnlyForACopyThatMayBeTheirs() {
        XCTAssertEqual(Ownership.sealing(501, seal: .owner(501), id: "x"), "x")
        XCTAssertEqual(Ownership.sealing(501, seal: .unreadable, id: "x"), "x")
        XCTAssertEqual(Ownership.sealing(501, seal: .legacy, id: nil), "unknown")
        XCTAssertNil(Ownership.sealing(501, seal: .owner(502), id: "x"))
        XCTAssertNil(Ownership.sealing(501, seal: .none, id: "x"))
        XCTAssertNil(Ownership.sealing(501, seal: .owner(502), id: nil, unreadable: true), "another user's: nothing told")
    }

    func testEachUserIsToldOnlyAboutTheirOwnEngineAndSealedCopy() {
        let a = Staging.revision("A"), b = Staging.revision("B")
        // Their own engine and sealed copy: both revisions.
        XCTAssertEqual(Ownership.revisions(501, running: (a, 501), sealed: (a, 501)), ["running": a, "durable": a, "startable": "1"])
        // Another user's engine runs over this user's sealed copy: theirs stays hidden, this user's copy is told.
        XCTAssertEqual(Ownership.revisions(501, running: (b, 502), sealed: (a, 501)), ["durable": a, "foreign": "1", "startable": "1"])
        // Another user's sealed copy is no reason to turn Connect on Demand on here, nor a way to tell when they change setup:
        // only that an unattended start has something to run.
        XCTAssertEqual(Ownership.revisions(501, running: (a, 501), sealed: (b, 502)), ["running": a, "startable": "1"])
        XCTAssertEqual(Ownership.revisions(501, running: nil, sealed: (b, 502)), ["startable": "1"])
        XCTAssertEqual(Ownership.revisions(501, running: (nil, 501), sealed: nil), [:], "mid-reload: no revision, not foreign")
        XCTAssertEqual(Ownership.revisions(501, running: nil, sealed: nil), [:])
    }

    // MARK: Search domain

    func testASearchDomainTravelsWithItsConfigurationAndIsPartOfItsRevision() throws {
        let s = Staging()
        let a = try s.stage("A", search: "tail1.ts.net", persist: true, uid: 501, epoch: s.epoch(for: 501))
        XCTAssertEqual(s.take(a.token)?.search, "tail1.ts.net")
        // None given: the VPN profile's, as before, and the same revision as before.
        let b = try s.stage("A", persist: true, uid: 501, epoch: s.epoch(for: 501))
        XCTAssertNil(s.take(b.token)?.search)
        XCTAssertEqual(b.revision, Staging.revision("A"))
        // A new domain alone is a new revision: what runs and what is sealed tell it apart.
        let revisions = Set([nil, "", "tail1.ts.net", "tail2.ts.net"].map { Staging.revision("A", search: $0) })
        XCTAssertEqual(revisions.count, 4)
    }

    func testOnlyATailnetDomainIsASearchDomain() {
        for good in ["tail1234.ts.net", "example.com", "home.example.co.uk", "a.b", "x-1.y-2.example", String(repeating: "a", count: 63) + ".com"] {
            XCTAssertTrue(Staging.isSearchDomain(good), good)
        }
        // Anything the compiler would never write searches nothing.
        for bad in ["", "com", "ts.net", "co.uk", "com.au", ".example.com", "example.com.", "Example.com", "a..b", "-a.example", "a-.example",
                    "ex ample.com", "exämple.com", "ex_ample.com", String(repeating: "a", count: 64) + ".com",
                    Array(repeating: "abcdefgh", count: 32).joined(separator: ".")] {
            XCTAssertFalse(Staging.isSearchDomain(bad), bad)
        }
    }

    func testTheSealedCopyKeepsItsSearchDomain() throws {
        func decoded(_ text: String) throws -> String? { try XCTUnwrap(SealedPolicy.decode(Data(text.utf8))).search }
        XCTAssertEqual(try XCTUnwrap(SealedPolicy.decode(XCTUnwrap(SealedPolicy.encode("{}", owner: 501, search: "tail1.ts.net")))).search, "tail1.ts.net")
        // Explicitly none stays none: it never brings back the domain an older app left in the VPN profile.
        XCTAssertEqual(try XCTUnwrap(SealedPolicy.decode(XCTUnwrap(SealedPolicy.encode("{}", owner: 501, search: "")))).search, "")
        XCTAssertNil(try XCTUnwrap(SealedPolicy.decode(XCTUnwrap(SealedPolicy.encode("{}", owner: 501)))).search)
        // Sealed by the previous version (no search): the VPN profile's, as then.
        XCTAssertNil(try decoded(#"{"config":"{}","owner":501}"#))
        XCTAssertEqual(try decoded(#"{"config":"{}","owner":501,"search":"com"}"#), "")
        XCTAssertNil(try decoded(#"{"config":"{}","owner":501,"search":1}"#))
    }

    // MARK: Sealing without running

    func testOnlyTheEnginesOwnerSealsAndNeverLate() {
        func may(_ owner: uid_t?, epoch: (Int, Int) = (3, 3), engine: (Int, Int) = (5, 5), seals: (Int, Int) = (7, 7)) -> [String: String]? {
            Ownership.maySeal(501, running: owner, epoch: epoch, engine: engine, seals: seals)
        }
        // Their engine runs (or failed a reload: still theirs), nothing happened since they asked.
        XCTAssertNil(may(501))
        XCTAssertNil(may(nil)?["foreign"])
        XCTAssertNotNil(may(nil), "nothing runs: no new way to replace another user's copy")
        XCTAssertEqual(may(502)?["foreign"], "1")
        XCTAssertNotNil(may(501, epoch: (3, 4)), "signed out since asking")
        XCTAssertNotNil(may(501, engine: (5, 6)), "restarted or reloaded since asking (a persist:false restart withdraws nothing)")
        XCTAssertNotNil(may(501, seals: (7, 8)), "withdrawn since asking: a failed persisting reload, a newer seal, a drop")
    }

    func testACopyKeptForASignedOutUserGoesOnceItCanBeRead() {
        XCTAssertEqual(Ownership.signedOut(.owner(501), forgotten: { $0 == 501 }), 501)
        // Someone else's copy, or one of a user who didn't sign out meanwhile: kept.
        XCTAssertNil(Ownership.signedOut(.owner(502), forgotten: { $0 == 501 }))
        XCTAssertNil(Ownership.signedOut(.owner(501), forgotten: { _ in false }))
        for seal in [Ownership.Seal.none, .legacy, .unreadable] { XCTAssertNil(Ownership.signedOut(seal, forgotten: { _ in true }), "\(seal)") }
    }

    // MARK: Tailscale identity

    /// RFC 7748's X25519 test vector: Alice's private and public keys.
    private let nodePrivate = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
    private let nodePublic = "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"

    /// tsnet's state as its FileStore writes it (every value base64), with the layout the pinned version reads at a start.
    private func state(machine: String? = "privkey:" + String(repeating: "1", count: 64), current: String? = "profile-ab12",
                       profile: String = "profile-ab12", control: Any? = "https://controlplane.tailscale.com", node: Any? = nil,
                       nodeID: Any? = "nABC", known: [String: Any]? = nil) -> String {
        var prefs: [String: Any] = ["RouteAll": true]
        prefs["ControlURL"] = control
        var persist: [String: Any] = [:]
        persist["PrivateNodeKey"] = node ?? "privkey:" + nodePrivate
        persist["NodeID"] = nodeID
        prefs["Config"] = persist
        let login: [String: Any] = known ?? ["ID": "ab12", "Name": "me@example.com", "Key": "profile-ab12", "NodeID": "nABC",
                                             "ControlURL": "https://controlplane.tailscale.com"]
        var keys: [String: String] = [:]
        keys["_machinekey"] = machine.map { Data($0.utf8).base64EncodedString() }
        keys["_current-profile"] = current.map { Data($0.utf8).base64EncodedString() }
        keys["_profiles"] = try! JSONSerialization.data(withJSONObject: ["ab12": login]).base64EncodedString()
        keys[profile] = try! JSONSerialization.data(withJSONObject: prefs).base64EncodedString()
        return String(decoding: try! JSONSerialization.data(withJSONObject: keys), as: UTF8.self)
    }

    func testTheNodeIdentityIsReadFromTheCurrentProfile() throws {
        let id = try XCTUnwrap(TailscaleIdentity.parse(state()))
        XCTAssertEqual(id.control, "https://controlplane.tailscale.com")
        XCTAssertEqual(id.node.map { String(format: "%02x", $0) }.joined(), nodePublic)
        XCTAssertEqual(id.nodeID, "nABC")
        let headscale = state(control: "https://hs.example.com", known: ["ID": "ab12", "Key": "profile-ab12", "NodeID": "nABC", "ControlURL": "https://hs.example.com"])
        XCTAssertEqual(TailscaleIdentity.parse(headscale)?.control, "https://hs.example.com")
        // A known profile that doesn't record its server doesn't contradict the profile's own.
        XCTAssertNotNil(TailscaleIdentity.parse(state(known: ["ID": "ab12", "Key": "profile-ab12", "NodeID": "nABC"])))
    }

    func testNoIdentityWithoutAllOfIt() {
        let zero = "privkey:" + String(repeating: "0", count: 64)
        let cases: [(String, String)] = [
            ("no machine key", state(machine: nil)),
            ("zero machine key", state(machine: zero)),
            ("machine key not a key", state(machine: "x")),
            ("no current profile", state(current: nil)),
            ("current profile missing", state(current: "profile-other")),
            ("not a profile key", state(current: "_machinekey", profile: "_machinekey")),
            ("signed out: zero node key", state(node: zero)),
            ("no node key", state(node: NSNull())),
            ("short node key", state(node: "privkey:abcd")),
            ("uppercase hex", state(node: "privkey:" + nodePrivate.uppercased())),
            ("not hex", state(node: "privkey:" + String(repeating: "g", count: 64))),
            ("public key in its place", state(node: "nodekey:" + nodePublic)),
            ("no node id", state(nodeID: nil)),
            ("empty node id", state(nodeID: "")),
            ("no control server", state(control: nil)),
            ("empty control server", state(control: "")),
            ("not among the known profiles", state(known: ["ID": "ab12", "Key": "profile-other", "NodeID": "nABC"])),
            ("known as another node", state(known: ["ID": "ab12", "Key": "profile-ab12", "NodeID": "nOTHER"])),
            ("known with another server", state(known: ["ID": "ab12", "Key": "profile-ab12", "NodeID": "nABC", "ControlURL": "https://hs.example.com"])),
            ("known without an ID", state(known: ["Key": "profile-ab12", "NodeID": "nABC"])),
            ("known under another ID", state(known: ["ID": "cd34", "Key": "profile-ab12", "NodeID": "nABC"])),
            ("not JSON", "x"),
            ("empty", ""),
            ("an array", "[]"),
        ]
        for (name, s) in cases { XCTAssertNil(TailscaleIdentity.parse(s), name) }
    }

    func testTheIdentityIsBoundToTheUserTheServerAndTheNode() throws {
        let node = try XCTUnwrap(TailscaleIdentity.parse(state())).node
        let id = TailscaleIdentity.id(owner: 501, control: "https://controlplane.tailscale.com", node: node)
        XCTAssertEqual(id.count, 64)
        XCTAssertEqual(id, TailscaleIdentity.id(owner: 501, control: "https://controlplane.tailscale.com", node: node))
        XCTAssertNotEqual(id, TailscaleIdentity.id(owner: 502, control: "https://controlplane.tailscale.com", node: node))
        XCTAssertNotEqual(id, TailscaleIdentity.id(owner: 501, control: "https://hs.example.com", node: node))
        // A rotated node key is a new enrolment.
        XCTAssertNotEqual(id, TailscaleIdentity.id(owner: 501, control: "https://controlplane.tailscale.com", node: Data(repeating: 9, count: 32)))
        XCTAssertFalse(id.contains(nodePublic) || id.contains(nodePrivate))
    }

    func testTheIdentityIsToldOnlyOnceSealedAndAsLongAsWhatIsSealedIsWhatRuns() throws {
        let enrolled = state(), other = state(node: "privkey:" + String(repeating: "2", count: 64))
        var t = TailscaleIdentity.Tracker(owner: 501)
        // A new node: nothing sealed yet, then its first state with keys.
        t.read(nil)
        XCTAssertNil(t.told)
        t.wrote(state(machine: nil))
        XCTAssertNil(t.told, "no identity in it yet")
        t.wrote(enrolled)
        let first = try XCTUnwrap(t.told)
        XCTAssertEqual(first.node, "nABC")
        XCTAssertFalse(first.sealed.restored, "only written so far")
        XCTAssertEqual(first.sealed.control, "https://controlplane.tailscale.com")
        // The next start (or reload) reads it back from the seal.
        t.reset()
        XCTAssertNil(t.told, "nothing told until the new engine read its state")
        t.read(enrolled)
        XCTAssertEqual(t.told?.sealed.id, first.sealed.id)
        XCTAssertEqual(t.told?.sealed.restored, true)
        t.wrote(enrolled)
        XCTAssertEqual(t.told?.sealed.restored, true, "the same identity sealed again")
        // A rotated key, sealed: a new enrolment, not one read back.
        t.wrote(other)
        XCTAssertNotEqual(t.told?.sealed.id, first.sealed.id)
        XCTAssertEqual(t.told?.sealed.restored, false)
        // A failed write: nothing told, even after a later write succeeds (it could seal an older profile beside newer keys),
        // until the state is read again.
        t.failed()
        XCTAssertNil(t.told)
        t.wrote(enrolled)
        XCTAssertNil(t.told)
        t.read(enrolled)
        XCTAssertNotNil(t.told)
        // Signing out removes the node key: nothing to tell.
        t.wrote(state(node: "privkey:" + String(repeating: "0", count: 64)))
        XCTAssertNil(t.told)
        // A state that can't be read tells nothing.
        t.read(nil)
        XCTAssertNil(t.told)
        // Bound to the user.
        var u = TailscaleIdentity.Tracker(owner: 502)
        u.read(enrolled)
        XCTAssertNotEqual(u.told?.sealed.id, first.sealed.id)
    }

    // MARK: Wire

    func testTailscaleStatusFromAnOlderExtensionStillDecodes() throws {
        let old = #"{"backendState":"Running","nodes":[{"id":"n1","ip":"100.64.0.1","name":"a","online":true}],"suffix":"tail1.ts.net"}"#
        let u = try JSONDecoder().decode(EngineWire.Tailscale.self, from: Data(old.utf8))
        XCTAssertEqual(u.nodes.first?.exit, false)
        XCTAssertNil(u.exitNode)
        XCTAssertNil(u.sealed)
        var now = u
        now.nodes[0].exit = true
        now.exitNode = "n1"
        now.sealed = .init(id: "x", control: "https://controlplane.tailscale.com", restored: true)
        let back = try JSONDecoder().decode(EngineWire.Tailscale.self, from: JSONEncoder().encode(now))
        XCTAssertEqual(back.nodes.first?.exit, true)
        XCTAssertEqual(back.exitNode, "n1")
        XCTAssertEqual(back.sealed, now.sealed)
    }

    // MARK: Deadline

    func testAnEngineCallThatDoesNotAnswerIsCutOffAndAnswersNothing() {
        // In time: its own answer, and nothing cancelled, then or later.
        final class Count: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func add() { lock.withLock { n += 1 } }
            var value: Int { lock.withLock { n } }
        }
        let calls = Count()
        XCTAssertEqual(Deadline.run(0.2, cancel: { calls.add() }) { true }, true)
        XCTAssertEqual(Deadline.run(0.2, cancel: { calls.add() }) { false }, false)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(calls.value, 0)
        // One that only returns once cancelled: cut off, and no answer, even if it then reports one.
        let cancelled = DispatchSemaphore(value: 0)
        let start = Date()
        let r = Deadline.run(0.2, cancel: { calls.add(); cancelled.signal() }) {
            cancelled.wait(timeout: .now() + 5) == .success
        }
        XCTAssertNil(r)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(calls.value, 1)
    }
}

