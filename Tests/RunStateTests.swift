import XCTest

final class RunStateTests: XCTestCase {
    func testInterimAndItsRecoveryDoNotApplyOrClearRefusal() {
        var state = RunState()
        var before = Setup()
        before.apps["app"] = DIRECT
        state.committed(revision: RunState.revision(before), setup: before, fresh: true)
        var wanted = before
        wanted.apps["app"] = "nl"
        let revision = RunState.revision(wanted)
        state.committed(revision: revision, setup: wanted, fresh: true, interim: true)
        XCTAssertEqual(state.appliedSetup, before)
        XCTAssertNotEqual(state.applied, revision)
        state.refused(revision: revision, setup: wanted)
        let failed = state
        state.committed(revision: revision, setup: wanted, fresh: true, interim: true)
        XCTAssertEqual(state, failed, "restoring the interim must not turn it into an applied setup")
        state.committed(revision: revision, setup: wanted, fresh: true)
        XCTAssertEqual(state.appliedSetup, wanted)
        XCTAssertEqual(state.applied, revision)
        XCTAssertNil(state.refused)
    }

    func testInterimProfileSwitchWaitsAndCanRollBackAfterRefusal() throws {
        var before = Setup()
        before.apps["app"] = DIRECT
        before.saveAs("Home")
        before.profiles.append(Profile(name: "Trip", defaultRoute: "nl", apps: ["app": BLOCK]))
        var wanted = before
        wanted.beginProfileSwitch("Trip", id: UUID(), running: before, engine: "old-engine")
        let pending = try XCTUnwrap(wanted.pendingSwitch)
        var state = RunState()
        state.committed(revision: RunState.revision(before), setup: before, fresh: true)
        state.committed(revision: RunState.revision(wanted), setup: wanted, fresh: true, interim: true)
        XCTAssertEqual(pending.decide(current: wanted, running: nil, refused: state.refusedSetup, standIn: state.standIn, stopped: false), .waiting)
        state.refused(revision: RunState.revision(wanted), setup: wanted)
        XCTAssertEqual(pending.decide(current: wanted, running: nil, refused: state.refusedSetup, standIn: state.standIn, stopped: false), .refused)
        pending.rollback(&wanted, fallback: try XCTUnwrap(state.appliedSetup))
        XCTAssertEqual(wanted.profile, "Home")
        XCTAssertEqual(wanted.apps["app"], DIRECT)
    }

    func testTemporaryRoutesDoNotCountAsProtection() {
        var setup = Setup()
        setup.defaultRoute = DIRECT
        setup.apps = ["app": DIRECT]
        setup.routes = [Route(id: "nl"), Route(id: "us")]
        setup.testing = ["nl"]
        var state = RunState()
        state.committed(revision: RunState.revision(setup), setup: setup, fresh: true)
        XCTAssertEqual(state.protection(blocked: []), false)
        setup.apps["app"] = "nl"
        state.committed(revision: RunState.revision(setup), setup: setup, fresh: false)
        XCTAssertEqual(state.protection(blocked: []), true)
        XCTAssertEqual(state.protection(blocked: ["nl"]), false)
    }
    func testStandInsKeepTheLastAppliedSetupForRollback() {
        var state = RunState()
        let setup = Setup(), revision = RunState.revision(setup)
        state.committed(revision: revision, setup: setup, fresh: true)
        for transition: (inout RunState) -> Void in [
            { $0.deniedAll() }, { $0.pausedBlocking() }, { $0.fallback() }, { $0.foreign() }
        ] {
            transition(&state)
            XCTAssertNotEqual(state.standIn, .none)
            XCTAssertEqual(state.applied, revision)
            XCTAssertEqual(state.appliedSetup, setup)
        }
        state.stopped()
        XCTAssertEqual(state.standIn, .none)
        XCTAssertEqual(state.appliedSetup, setup)
    }

    func testEachStandInAndCommit() {
        var state = RunState()
        state.deniedAll(); XCTAssertEqual(state.standIn, .denyAll)
        state.pausedBlocking(); XCTAssertEqual(state.standIn, .pause)
        state.fallback(); XCTAssertEqual(state.standIn, .fallback)
        state.foreign(); XCTAssertEqual(state.standIn, .foreign)
        XCTAssertNil(state.applied); XCTAssertNil(state.appliedSetup)
        let setup = Setup(), revision = RunState.revision(setup)
        state.committed(revision: revision, setup: setup, fresh: true)
        XCTAssertEqual(state.standIn, .none)
        XCTAssertEqual(state.applied, revision)
    }

    func testRefusalAndStoreMovement() {
        var state = RunState()
        state.refused(revision: "a")
        state.storeMoved(to: "a")
        XCTAssertEqual(state.refused, "a")
        state.storeMoved(to: "b")
        XCTAssertNil(state.refused)
        state.refused(revision: "b")
        state.committed(revision: "a", setup: Setup(), fresh: false)
        XCTAssertEqual(state.refused, "b")
        state.committed(revision: "b", setup: Setup(), fresh: true)
        XCTAssertNil(state.refused)
    }

    func testOnlyFreshEnginesIncrement() {
        var state = RunState()
        let setup = Setup(), revision = RunState.revision(setup)
        state.committed(revision: revision, setup: setup, fresh: true)
        state.deniedAll(); state.pausedBlocking(); state.fallback(); state.foreign(); state.stopped()
        state.refused(revision: revision); state.storeMoved(to: "other")
        XCTAssertEqual(state.engineStarts, 0)
        state.freshEngine(); state.freshEngine()
        XCTAssertEqual(state.engineStarts, 2)
    }

    func testSetupRevisionIsStableAndChangesWithSetup() {
        var first = Setup()
        first.apps = ["b": "nl", "a": "direct"]
        var reordered = first
        reordered.apps = ["a": "direct", "b": "nl"]
        XCTAssertEqual(RunState.revision(first), RunState.revision(reordered))
        reordered.apps["a"] = "nl"
        XCTAssertNotEqual(RunState.revision(first), RunState.revision(reordered))
    }
}
