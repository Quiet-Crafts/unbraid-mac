import XCTest

final class LimitsTests: XCTestCase {
    func testLatestEditWinsOnlyForItsTarget() {
        var edits = RouteEdits()
        let first = edits.begin([.app("browser")])
        let unrelated = edits.begin([.app("mail")])
        let block = edits.begin([.app("browser")])
        XCTAssertFalse(edits.contains(first))
        XCTAssertTrue(edits.contains(unrelated))
        XCTAssertTrue(edits.contains(block))
        edits.finish(block)
        // A delayed lookup or an already displayed confirmation cannot revive the older Direct.
        XCTAssertFalse(edits.contains(first))
        XCTAssertFalse(edits.contains(block))
        XCTAssertTrue(edits.contains(unrelated))
    }

    func testDefaultAndLocationsHaveSeparateOrdering() {
        var edits = RouteEdits()
        let oldDefault = edits.begin([.defaultRoute])
        let location = edits.begin([.location("a")])
        let otherLocation = edits.begin([.location("b")])
        let newDefault = edits.begin([.defaultRoute])
        XCTAssertFalse(edits.contains(oldDefault))
        XCTAssertTrue(edits.contains(newDefault))
        XCTAssertTrue(edits.contains(location))
        _ = edits.begin([.location("a")])
        XCTAssertFalse(edits.contains(location))
        XCTAssertTrue(edits.contains(otherLocation))
    }

    func testOverlappingMoveKeepsItsRemainingApps() {
        var edits = RouteEdits()
        let batch = edits.begin([.app("a"), .app("b")], move: true)
        let unrelated = edits.begin([.app("c")])
        _ = edits.begin([.app("b")])
        XCTAssertTrue(edits.contains(batch))
        XCTAssertEqual(edits.remaining(["a": DIRECT, "b": BLOCK], in: batch), ["a": DIRECT])
        XCTAssertTrue(edits.contains(unrelated))
        edits.clear()
        XCTAssertFalse(edits.contains(unrelated))
    }

    func testSharingCannotOverwriteNewerLocationEvenAfterItCommitted() {
        var edits = RouteEdits()
        let assignment = edits.begin([.app("a")])
        let location = edits.begin([.location("r")])
        edits.finish(location)
        XCTAssertFalse(edits.include([.location("r")], in: assignment))
        let next = edits.begin([.app("a")])
        XCTAssertTrue(edits.include([.location("r")], in: next))
        _ = edits.begin([.location("r")])
        XCTAssertFalse(edits.contains(next))
    }

    func testBatchCountsAllAssignmentsAndResolvesDefaultsAtCommit() {
        var old = Setup()
        old.routes = [Route(id: "a", loc: Location(provider: "proton-free")), Route(id: "b", loc: Location(provider: "proton-free"))]
        old.defaultRoute = DIRECT
        let change: AppMove.Assignments = ["browser": "a", "mail": "b"]
        let proposed = Store.edited(old) { AppMove.apply(change, to: &$0) }
        let limit = Limit(unit: "connection", perTunnel: true, value: 1)
        XCTAssertEqual(Limits.over(old, proposed) { _ in limit }?.count, 2)
        XCTAssertTrue(old.apps.isEmpty)
        XCTAssertEqual(proposed.apps, ["browser": "a", "mail": "b"])
        old.defaultRoute = "b"
        let committed = Store.edited(old) { AppMove.apply(change, to: &$0) }
        XCTAssertEqual(committed.apps, ["browser": "a"])
        XCTAssertNil(committed.apps["mail"])
    }

    func testBatchRemovedRoutesAndBlockHardening() {
        var setup = Setup()
        setup.apps = ["browser": "nl", "mail": DIRECT]
        setup.prefs.killLevel = .off
        AppMove.apply(["browser": "removed", "mail": BLOCK], to: &setup)
        XCTAssertNil(setup.apps["browser"])
        XCTAssertEqual(setup.apps["mail"], BLOCK)
        XCTAssertEqual(setup.prefs.killLevel, .internet)
        setup.prefs.killLevel = .home
        AppMove.apply(["browser": BLOCK], to: &setup)
        XCTAssertEqual(setup.prefs.killLevel, .home)
        let before = AppMove.assignments(["browser", "missing"], in: setup)
        XCTAssertEqual(before.count, 2)
        XCTAssertNotNil(before["missing"] as Any?)
        XCTAssertNil(before["missing"]!)
    }

    @MainActor
    func testMoveUndoRedoWaitsForCommitAndKeepsAcceptedSnapshots() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        var setup = Setup()
        setup.apps["a"] = BLOCK
        var waiting: (() -> Void)?
        undo.beginUndoGrouping()
        _ = MoveHistory(before: ["a": DIRECT], after: ["a": BLOCK], undo: undo, name: "Move App") { change, completed in
            waiting = {
                setup = Store.edited(setup) { AppMove.apply(change, to: &$0) }
                completed(true)
            }
        }
        undo.endUndoGrouping()
        undo.undo()
        XCTAssertEqual(setup.apps["a"], BLOCK)
        XCTAssertTrue(undo.canRedo)
        waiting?()
        XCTAssertEqual(setup.apps["a"], DIRECT)
        undo.redo()
        XCTAssertEqual(setup.apps["a"], DIRECT)
        waiting?()
        XCTAssertEqual(setup.apps["a"], BLOCK)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        waiting?()
        XCTAssertEqual(setup.apps["a"], DIRECT)
    }

    @MainActor
    func testRapidUndoRedoSupersedesPendingUndo() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        var edits = RouteEdits()
        var setup = Setup()
        setup.apps["a"] = BLOCK
        var waiting: [() -> Void] = []
        undo.beginUndoGrouping()
        _ = MoveHistory(before: ["a": DIRECT], after: ["a": BLOCK], undo: undo, name: "Move App") { change, completed in
            let ticket = edits.begin(Set(change.keys.map { .app($0) }))
            waiting.append {
                guard edits.contains(ticket) else { completed(false); return }
                edits.finish(ticket)
                setup = Store.edited(setup) { AppMove.apply(change, to: &$0) }
                completed(true)
            }
        }
        undo.endUndoGrouping()
        undo.undo()
        undo.redo()
        waiting.reversed().forEach { $0() }
        XCTAssertEqual(setup.apps["a"], BLOCK)
        XCTAssertEqual(setup.prefs.killLevel, .internet)
        XCTAssertTrue(undo.canUndo)
    }

    func testProfileSwitchOverlapsAllAssignmentsButNotLocations() {
        var edits = RouteEdits()
        let profile = edits.begin([.profile])
        let location = edits.begin([.location("a")])
        XCTAssertTrue(edits.contains(profile))
        _ = edits.begin([.app("new-app")])
        XCTAssertFalse(edits.contains(profile))
        let assignment = edits.begin([.app("other-app")])
        _ = edits.begin([.profile])
        XCTAssertFalse(edits.contains(assignment))
        XCTAssertTrue(edits.contains(location))
    }

    @MainActor
    func testMultiplePendingUndosKeepRedoOrder() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        var edits = RouteEdits()
        var setup = Setup()
        setup.apps["a"] = BLOCK
        var waiting: [() -> Void] = []
        var queued: Set<RouteEdits.Ticket> = []
        let submit: MoveHistory.Submit = { change, completed in
            let ticket = edits.begin(Set(change.keys.map { .app($0) }), preserving: queued)
            queued.insert(ticket)
            waiting.append {
                guard edits.contains(ticket) else { completed(false); return }
                edits.finish(ticket)
                queued.remove(ticket)
                setup = Store.edited(setup) { AppMove.apply(change, to: &$0) }
                completed(true)
            }
        }
        undo.beginUndoGrouping()
        _ = MoveHistory(before: ["a": nil], after: ["a": DIRECT], undo: undo, name: "Move App", submit: submit)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        _ = MoveHistory(before: ["a": DIRECT], after: ["a": BLOCK], undo: undo, name: "Move App", submit: submit)
        undo.endUndoGrouping()
        undo.undo(); undo.undo()
        waiting.forEach { $0() }; waiting = []
        XCTAssertNil(setup.apps["a"])
        undo.redo()
        waiting.forEach { $0() }; waiting = []
        XCTAssertEqual(setup.apps["a"], DIRECT)
        undo.redo()
        waiting.forEach { $0() }
        XCTAssertEqual(setup.apps["a"], BLOCK)
    }

    @MainActor
    func testOverlappingBatchUndosReplayAtomicallyInOrder() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let replays = MoveReplays()
        var edits = RouteEdits()
        var setup = Setup()
        setup.apps = ["a": DIRECT, "b": BLOCK, "c": BLOCK]
        var waiting: [() -> Void] = []
        let submit: MoveHistory.Submit = { change, completed in
            let ticket = edits.begin(Set(change.keys.map { .app($0) }), preserving: replays.tickets)
            replays.append(ticket) { finished in
                waiting.append {
                    if edits.contains(ticket) {
                        setup = Store.edited(setup) { AppMove.apply(change, to: &$0) }
                        completed(true)
                        edits.finish(ticket)
                    } else { completed(false) }
                    finished()
                }
            }
        }
        undo.beginUndoGrouping()
        _ = MoveHistory(before: ["a": nil, "b": nil], after: ["a": DIRECT, "b": DIRECT], undo: undo, name: "Move Apps", submit: submit)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        _ = MoveHistory(before: ["b": DIRECT, "c": nil], after: ["b": BLOCK, "c": BLOCK], undo: undo, name: "Move Apps", submit: submit)
        undo.endUndoGrouping()
        undo.undo(); undo.undo()
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(setup.apps["c"], BLOCK)
        waiting.removeFirst()()
        XCTAssertEqual(setup.apps, ["a": DIRECT, "b": DIRECT])
        XCTAssertEqual(waiting.count, 1)
        waiting.removeFirst()()
        XCTAssertTrue(setup.apps.isEmpty)
        undo.redo(); undo.redo()
        waiting.removeFirst()()
        XCTAssertEqual(setup.apps, ["a": DIRECT, "b": DIRECT])
        waiting.removeFirst()()
        XCTAssertEqual(setup.apps, ["a": DIRECT, "b": BLOCK, "c": BLOCK])
        XCTAssertTrue(replays.tickets.isEmpty)
    }

    @MainActor
    func testNewEditSupersedesQueuedReplaysAndCancellationAdvancesQueue() {
        let replays = MoveReplays()
        var edits = RouteEdits()
        var completions: [() -> Void] = []
        let first = edits.begin([.app("a")], preserving: replays.tickets)
        replays.append(first) { completions.append($0) }
        let second = edits.begin([.app("a"), .app("b")], preserving: replays.tickets)
        replays.append(second) { completions.append($0) }
        XCTAssertTrue(edits.contains(first))
        XCTAssertTrue(edits.contains(second))
        let newest = edits.begin([.app("a")])
        XCTAssertFalse(edits.contains(first))
        XCTAssertFalse(edits.contains(second))
        XCTAssertTrue(edits.contains(newest))
        XCTAssertEqual(completions.count, 1)
        completions[0]()
        XCTAssertEqual(completions.count, 2)
        completions[0]() // a repeated completion cannot skip the next replay
        XCTAssertEqual(replays.tickets, [second])
        completions[1]()
        XCTAssertTrue(replays.tickets.isEmpty)
    }

    func testOverlappingDragsRecheckOnlyRemainingAssignments() {
        var edits = RouteEdits()
        let first = edits.begin([.app("a"), .app("b")], move: true)
        let second = edits.begin([.app("b"), .app("c")], move: true)
        var setup = Setup(routes: [Route(id: "r2"), Route(id: "r3")], defaultRoute: DIRECT)
        AppMove.apply(edits.remaining(["a": "r2", "b": "r2"], in: first), to: &setup)
        AppMove.apply(edits.remaining(["b": "r3", "c": "r3"], in: second), to: &setup)
        XCTAssertEqual(setup.apps, ["a": "r2", "b": "r3", "c": "r3"])
        _ = edits.begin([.profile])
        XCTAssertFalse(edits.contains(first))
        XCTAssertFalse(edits.contains(second))
    }

    func testNarrowedMoveCanFallBelowLimit() {
        var edits = RouteEdits()
        let ticket = edits.begin([.app("a"), .app("b")], move: true)
        let old = Setup(routes: [Route(id: "r1"), Route(id: "r2")], defaultRoute: DIRECT)
        let change: AppMove.Assignments = ["a": "r1", "b": "r2"]
        let limit = Limit(unit: "connection", perTunnel: true, value: 1)
        let proposed = Store.edited(old) { AppMove.apply(change, to: &$0) }
        XCTAssertNotNil(Limits.over(old, proposed) { _ in limit })
        _ = edits.begin([.app("a")])
        let narrowed = Store.edited(old) { AppMove.apply(edits.remaining(change, in: ticket), to: &$0) }
        XCTAssertNil(Limits.over(old, narrowed) { _ in limit })
        XCTAssertEqual(narrowed.apps, ["b": "r2"])
    }

    func testProviderSignOutKeepsRouteTicketsAndClearsOnlyProfiles() {
        var edits = RouteEdits()
        let assignment = edits.begin([.app("a")], move: true)
        let location = edits.begin([.location("r2")])
        edits.clearProfiles()
        XCTAssertTrue(edits.contains(assignment))
        XCTAssertTrue(edits.contains(location))
        let profile = edits.begin([.profile])
        edits.clearProfiles()
        XCTAssertFalse(edits.contains(profile))
        XCTAssertTrue(edits.contains(location))
        edits.clear()
        XCTAssertFalse(edits.contains(location))
    }

    @MainActor
    func testCancelledUndoPreservesOtherMovesRedo() {
        let undo = UndoManager()
        var submitted: [AppMove.Assignments] = []
        var completions: [(Bool) -> Void] = []
        let submit: MoveHistory.Submit = { change, completed in
            submitted.append(change); completions.append(completed)
        }
        _ = MoveHistory(before: ["a": nil], after: ["a": DIRECT], undo: undo, name: "Move App", submit: submit)
        _ = MoveHistory(before: ["b": nil], after: ["b": BLOCK], undo: undo, name: "Move App", submit: submit)
        undo.undo()
        completions.removeFirst()(true)
        undo.undo()
        completions.removeFirst()(false)
        XCTAssertEqual(submitted, [["b": nil], ["a": nil]])
        XCTAssertTrue(undo.canUndo)
        XCTAssertTrue(undo.canRedo)
        XCTAssertEqual(undo.undoActionName, "Move App")
        XCTAssertEqual(undo.redoActionName, "Move App")
        undo.redo()
        XCTAssertEqual(submitted.last, ["b": BLOCK])
        completions.first?(true)
    }

    @MainActor
    func testCancelledRedoPreservesOtherMovesRedo() {
        let undo = UndoManager()
        var submitted: [AppMove.Assignments] = []
        var completions: [(Bool) -> Void] = []
        let submit: MoveHistory.Submit = { change, completed in
            submitted.append(change); completions.append(completed)
        }
        _ = MoveHistory(before: ["a": nil], after: ["a": DIRECT], undo: undo, name: "Move App", submit: submit)
        _ = MoveHistory(before: ["b": nil], after: ["b": BLOCK], undo: undo, name: "Move App", submit: submit)
        undo.undo()
        completions.removeFirst()(true)
        undo.undo()
        completions.removeFirst()(true)
        undo.redo()
        completions.removeFirst()(false)
        XCTAssertEqual(submitted, [["b": nil], ["a": nil], ["a": DIRECT]])
        XCTAssertFalse(undo.canUndo)
        XCTAssertEqual(undo.redoActionName, "Move App")
        undo.redo()
        completions.removeFirst()(true)
        XCTAssertEqual(submitted.last, ["a": DIRECT])
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(submitted.last, ["b": BLOCK])
        completions.first?(true)
    }

    @MainActor
    func testCancelledUndoBelowAnotherReplayDoesNotRedoThatMove() {
        let undo = UndoManager()
        var submitted: [AppMove.Assignments] = []
        var completions: [(Bool) -> Void] = []
        let submit: MoveHistory.Submit = { change, completed in
            submitted.append(change); completions.append(completed)
        }
        _ = MoveHistory(before: ["a": nil], after: ["a": DIRECT], undo: undo, name: "Move App", submit: submit)
        _ = MoveHistory(before: ["b": nil], after: ["b": BLOCK], undo: undo, name: "Move App", submit: submit)
        undo.undo(); undo.undo()
        completions.removeFirst()(false)
        completions.removeFirst()(true)
        XCTAssertEqual(submitted, [["b": nil], ["a": nil]])
        XCTAssertEqual(undo.undoActionName, "Move App")
        undo.undo()
        XCTAssertEqual(submitted.last, ["b": nil])
        completions.removeFirst()(true)
    }

    @MainActor
    func testCancelledRedoBelowAnotherReplayDoesNotUndoThatMove() {
        let undo = UndoManager()
        var submitted: [AppMove.Assignments] = []
        var completions: [(Bool) -> Void] = []
        let submit: MoveHistory.Submit = { change, completed in
            submitted.append(change); completions.append(completed)
        }
        _ = MoveHistory(before: ["a": nil], after: ["a": DIRECT], undo: undo, name: "Move App", submit: submit)
        _ = MoveHistory(before: ["b": nil], after: ["b": BLOCK], undo: undo, name: "Move App", submit: submit)
        undo.undo(); undo.undo()
        completions.removeFirst()(true)
        completions.removeFirst()(true)
        undo.redo(); undo.redo()
        completions.removeFirst()(false)
        completions.removeFirst()(true)
        XCTAssertEqual(submitted, [["b": nil], ["a": nil], ["a": DIRECT], ["b": BLOCK]])
        XCTAssertEqual(undo.redoActionName, "Move App")
        undo.redo()
        completions.removeFirst()(true)
        XCTAssertEqual(submitted.last, ["a": DIRECT])
        undo.undo(); undo.undo()
        XCTAssertEqual(submitted.suffix(2), [["a": nil], ["b": nil]])
        completions.removeFirst()(true)
        completions.removeFirst()(true)
    }

    @MainActor
    func testMoveReplayKeepsMenuActionNames() {
        let undo = UndoManager()
        _ = MoveHistory(before: ["a": nil], after: ["a": DIRECT], undo: undo, name: "Move App") { _, completed in
            completed(true)
        }
        XCTAssertEqual(undo.undoActionName, "Move App")
        undo.undo()
        XCTAssertEqual(undo.redoActionName, "Move App")
        undo.redo()
        XCTAssertEqual(undo.undoActionName, "Move App")
    }

    @MainActor
    func testCancelledUndoKeepsUndoAndRemovesStaleRedo() {
        let undo = UndoManager()
        var completions: [(Bool) -> Void] = []
        var submitted: [AppMove.Assignments] = []
        _ = MoveHistory(before: ["a": DIRECT], after: ["a": BLOCK], undo: undo, name: "Move App") { change, completed in
            submitted.append(change); completions.append(completed)
        }
        undo.undo()
        completions.removeFirst()(false)
        XCTAssertTrue(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        undo.undo()
        XCTAssertEqual(submitted, [["a": DIRECT], ["a": DIRECT]])
        completions.removeFirst()(true)
        undo.redo()
        XCTAssertEqual(submitted.last, ["a": BLOCK])
        completions.removeFirst()(true)
    }

    @MainActor
    func testCancelledRedoStaysRedoAndDoesNotSubmitDuringRepair() {
        let undo = UndoManager()
        var submitted: [AppMove.Assignments] = []
        var completions: [(Bool) -> Void] = []
        _ = MoveHistory(before: ["a": DIRECT], after: ["a": BLOCK], undo: undo, name: "Move App") { change, completed in
            submitted.append(change); completions.append(completed)
        }
        undo.undo()
        completions.removeFirst()(true)
        undo.redo()
        completions.removeFirst()(false)
        XCTAssertFalse(undo.canUndo)
        XCTAssertTrue(undo.canRedo)
        XCTAssertEqual(submitted.count, 2)
        undo.redo()
        XCTAssertEqual(submitted.last, ["a": BLOCK])
        completions.removeFirst()(true)
        XCTAssertTrue(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
    }

    @MainActor
    func testSynchronousUndoCancellationRestoresAfterNativeReplay() async {
        let undo = UndoManager()
        _ = MoveHistory(before: ["a": DIRECT], after: ["a": BLOCK], undo: undo, name: "Move App") { _, completed in
            completed(false)
        }
        undo.undo()
        await Task.yield()
        XCTAssertTrue(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
    }

    @MainActor
    func testSupersededUndoCanBeRetried() {
        let undo = UndoManager()
        var edits = RouteEdits()
        var setup = Setup()
        setup.apps["a"] = BLOCK
        var waiting: (() -> Void)?
        _ = MoveHistory(before: ["a": DIRECT], after: ["a": BLOCK], undo: undo, name: "Move App") { change, completed in
            let ticket = edits.begin([.app("a")])
            waiting = {
                guard edits.contains(ticket) else { completed(false); return }
                AppMove.apply(change, to: &setup)
                edits.finish(ticket)
                completed(true)
            }
        }
        undo.undo()
        _ = edits.begin([.app("a")])
        waiting?()
        XCTAssertEqual(setup.apps["a"], BLOCK)
        XCTAssertTrue(undo.canUndo)
        XCTAssertFalse(undo.canRedo)
        undo.undo()
        waiting?()
        XCTAssertEqual(setup.apps["a"], DIRECT)
        XCTAssertTrue(undo.canRedo)
    }

    @MainActor
    func testMovesCommittedInOneTurnHaveSeparateUndoGroups() {
        let undo = UndoManager()
        var submitted: [AppMove.Assignments] = []
        let submit: MoveHistory.Submit = { change, completed in submitted.append(change); completed(true) }
        _ = MoveHistory(before: ["a": nil], after: ["a": DIRECT], undo: undo, name: "Move App", submit: submit)
        _ = MoveHistory(before: ["b": nil], after: ["b": BLOCK], undo: undo, name: "Move App", submit: submit)
        XCTAssertTrue(undo.groupsByEvent)
        undo.undo()
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(submitted[0], ["b": nil])
        undo.undo()
        XCTAssertEqual(submitted.count, 2)
        XCTAssertEqual(submitted[1], ["a": nil])
    }

    func testWordingAndOverride() {
        XCTAssertEqual(Limits.line("Mullvad", 5, "device", 1, all: 3), "Mullvad allows 5 devices. 3 are in use, 1 of them by unbraid.")
        XCTAssertEqual(Limits.line("PIA", nil, "connection", 2), "unbraid is using 2 PIA connections. Check how many your plan allows: over the limit, routes can stop working without an error.")
        XCTAssertEqual(Limits.full("IVPN", nil, "device"), "All IVPN devices are in use. Sign out another device, then try again.")
        let l = Limit(unit: "connection", perTunnel: true, value: 10)
        XCTAssertEqual(Limits.effective(l, "3"), 3)
        for invalid in ["", "0", "1000", "abc"] { XCTAssertEqual(Limits.effective(l, invalid), 10) }
    }

    func testCountsActiveRoutesAndOnlyWarnsOnIncrease() {
        let a = Route(id: "a", loc: Location(provider: "proton-free"))
        let b = Route(id: "b", loc: Location(provider: "proton-free"))
        var old = Setup(); old.routes = [a, b]; old.defaultRoute = "a"; old.apps = [:]
        var new = old; new.apps = ["app": "b"]
        let limit = Limit(unit: "connection", perTunnel: true, value: 1)
        XCTAssertEqual(Limits.over(old, new) { _ in limit }, .init(provider: "proton-free", limit: 1, count: 2, unit: "connection"))
        XCTAssertNil(Limits.over(new, new) { _ in limit })
        let server = Server(name: "one", host: "host", ip: "1.2.3.4", publicKey: "key", load: -1)
        old.routes[0].loc.pinned = server; old.routes[1].loc.pinned = server
        new = old; new.apps = ["app": "b"]
        XCTAssertEqual(Limits.tunnels(new, "proton-free"), 1)
        XCTAssertNil(Limits.over(old, new) { _ in limit })
        new.routes[1].loc.proto = "openvpn_udp"
        XCTAssertEqual(Limits.tunnels(new, "proton-free"), 2)
    }

    func testProviderDefaults() async throws {
        let nord = try await Nord().limit("")
        let free = try await ProtonFree().limit("")
        let mullvad = try await Mullvad().limit("")
        let proton = try await Proton().limit("")
        let pia = try await Pia().limit("")
        let air = try await AirVpn().limit("")
        XCTAssertEqual(nord, Limit(unit: "connection", perTunnel: true, value: 10))
        XCTAssertEqual(free, Limit(unit: "connection", perTunnel: true, value: 1))
        XCTAssertEqual(mullvad, Limit(unit: "device", perTunnel: false, value: 5))
        XCTAssertEqual(proton, Limit(unit: "connection", perTunnel: true, value: 10))
        XCTAssertEqual(pia, Limit(unit: "connection", perTunnel: true, value: nil))
        XCTAssertEqual(air, Limit(unit: "connection", perTunnel: true, value: 5))
        let old = #"{"accountId":"a","sessionToken":"t","privateKey":"k","ipAddress":"10.0.0.2"}"#
        let oldLimit = try await Ivpn().limit(old)
        XCTAssertEqual(oldLimit, Limit(unit: "device", perTunnel: false, value: nil))
        let saved = #"{"accountId":"a","sessionToken":"t","privateKey":"k","ipAddress":"10.0.0.2","limit":5}"#
        let savedLimit = try await Ivpn().limit(saved)
        XCTAssertEqual(savedLimit?.value, 5)
        let malformed = try await Ivpn().limit("not json")
        XCTAssertEqual(malformed, Limit(unit: "device", perTunnel: false, value: nil))
    }
    func testAndroidWordingCases() {
        XCTAssertEqual(Limits.line("Proton VPN Free", 1, "connection", 2), "Proton VPN Free allows 1 connection. unbraid is using 2. Your other devices aren't counted.")
        XCTAssertEqual(Limits.line("IVPN", 5, "device", 1), "IVPN allows 5 devices. unbraid is using 1. Your other devices aren't counted.")
        XCTAssertEqual(Limits.line("Mullvad", 5, "device", 1, all: 1), "Mullvad allows 5 devices. 1 is in use, by unbraid.")
        XCTAssertEqual(Limits.line("Proton VPN", nil, "connection", 1), "unbraid is using 1 Proton VPN connection. Check how many your plan allows: over the limit, routes can stop working without an error.")
        XCTAssertEqual(Limits.warning("NordVPN", 10, "connection", 11), "NordVPN allows 10 connections. This would make it 11. Over the limit, routes can stop working without an error.")
        XCTAssertEqual(Limits.full("IVPN", 5, "device"), "All 5 IVPN devices are in use. Sign out another device, then try again.")
        XCTAssertEqual(Limits.dropping("Netherlands", "Proton VPN Free", "connection"), "Netherlands keeps dropping. Proton VPN Free may be over its connection limit.")
        XCTAssertNil(Limits.effective(Limit(unit: "connection", perTunnel: true, value: nil), ""))
        XCTAssertEqual(Limits.effective(Limit(unit: "connection", perTunnel: true, value: nil), "7"), 7)
    }

    func testLiveTunnelIdentity() {
        let a = Route(id: "a", loc: Location(provider: "proton-free"))
        let b = Route(id: "b", loc: Location(provider: "proton-free"))
        var setup = Setup(); setup.routes = [a, b]; setup.defaultRoute = "a"; setup.apps = ["app": "b"]
        let server = Server(name: "one", host: "host", ip: "1.2.3.4", publicKey: "key", load: -1)
        let peer = WgPeer(name: "one", privateKey: "private", address: ["10.0.0.2/32"], publicKey: "public", endpoint: "host:123", allowedIps: ["0.0.0.0/0"])
        var different = peer; different.presharedKey = "other"
        XCTAssertEqual(Limits.tunnels(setup, "proton-free"), 2)
        XCTAssertEqual(Limits.tunnels(setup, "proton-free", links: ["a": .wg(server, peer), "b": .wg(server, peer)]), 1)
        XCTAssertEqual(Limits.tunnels(setup, "proton-free", links: ["a": .wg(server, peer), "b": .wg(server, different)]), 2)
    }

    func testAndroidOverCases() {
        let a = Route(id: "a", loc: Location(provider: "proton-free"))
        let b = Route(id: "b", loc: Location(provider: "proton-free"))
        var one = Setup(); one.routes = [a, b]; one.defaultRoute = "a"
        var two = one; two.apps = ["x": "b"]
        let limit = Limit(unit: "connection", perTunnel: true, value: 1)
        var same = two; same.apps["y"] = "b"
        XCTAssertNil(Limits.over(two, same) { _ in limit })
        XCTAssertNil(Limits.over(two, one) { _ in limit })
        XCTAssertNil(Limits.over(one, one) { _ in limit })
        XCTAssertNil(Limits.over(one, two) { _ in nil })
        XCTAssertNil(Limits.over(one, two) { _ in Limit(unit: "device", perTunnel: false, value: 1) })
        two.opts["proton-free"] = ["limit": "2"]
        XCTAssertNil(Limits.over(one, two) { _ in limit })
    }

    func testSharingAnchorMustStillRunAsSaved() {
        let a = Route(id: "a", loc: Location(provider: "proton-free"))
        let b = Route(id: "b", loc: Location(provider: "proton-free"))
        let server = Server(name: "one", host: "host", ip: "1.2.3.4", publicKey: "key", load: -1)
        var setup = Setup(); setup.routes = [a, b]; setup.defaultRoute = "a"
        XCTAssertEqual(Limits.shareAnchor(setup, running: setup, servers: ["a": server], provider: "proton-free")?.0.id, "a")
        var changed = setup; changed.routes[0].loc.country = "Elsewhere"
        XCTAssertNil(Limits.shareAnchor(changed, running: setup, servers: ["a": server], provider: "proton-free"))
        changed = setup; changed.apps["app"] = "b"
        XCTAssertNil(Limits.shareAnchor(changed, running: changed, servers: ["a": server, "b": server], provider: "proton-free"))
        XCTAssertNil(Limits.shareAnchor(setup, running: nil, servers: ["a": server], provider: "proton-free"))
    }

    func testTemporarySelectionAndOwnership() {
        var setup = Setup()
        setup.routes = [Route(id: "a", loc: Location(provider: "proton-free")), Route(id: "b", loc: Location(provider: "proton-free")), Route(id: "c", loc: Location(provider: "nord"))]
        setup.defaultRoute = "a"
        let picked = TestingRoutes.choose(["b", "c"], setup: setup) { p in Limit(unit: "connection", perTunnel: true, value: p == "proton-free" ? 1 : 10) }
        XCTAssertEqual(picked.routes, ["c"])
        XCTAssertNotNil(picked.errors["b"])
        var owner = TestingOwner()
        let first = owner.begin(["b"]), second = owner.begin(["c"])
        XCTAssertFalse(owner.end(first)); XCTAssertEqual(owner.routes, ["c"])
        XCTAssertTrue(owner.end(second)); XCTAssertTrue(owner.routes.isEmpty)
    }

    func testTemporaryRoutesRespectTailscaleAndDeviceLimits() {
        var setup = Setup()
        setup.routes = [Route(id: "a", tsExit: "100.1.1.1"), Route(id: "b", tsExit: "100.1.1.2"), Route(id: "c", tsExit: "100.1.1.1"), Route(id: "d", loc: Location(provider: "mullvad"))]
        setup.defaultRoute = "a"
        let choice = TestingRoutes.choose(["b", "c", "d"], setup: setup) { _ in Limit(unit: "device", perTunnel: false, value: 0) }
        XCTAssertEqual(choice.routes, ["c", "d"])
        XCTAssertNotNil(choice.errors["b"])
    }

    func testTemporaryRoutesAreNeverEncoded() throws {
        let old = Data(#"{"routes":[{"id":"a"}],"defaultRoute":"a"}"#.utf8)
        var setup = try JSONDecoder().decode(Setup.self, from: old)
        XCTAssertTrue(setup.testing.isEmpty)
        setup.testing = ["a"]
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(setup)) as? [String: Any])
        XCTAssertNil(object["testing"])
        XCTAssertTrue(try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(setup)).testing.isEmpty)
    }

}
