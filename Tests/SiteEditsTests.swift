import XCTest

/// Adding, moving and removing websites, and how they are counted where apps are.
final class SiteEditsTests: XCTestCase {
    private let nl = Route(id: "nl", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands"))
    private let us = Route(id: "us", loc: Location(countryId: 228, countryCode: "US", country: "United States"), hue: 1)

    func testAnAddressIsCheckedAsTheSheetSaysIt() {
        XCTAssertEqual(SiteEdits.check("  ", in: [:]), .empty)
        XCTAssertEqual(SiteEdits.check("https://www.Netflix.com/browse", in: [:]), .valid("netflix.com"))
        XCTAssertEqual(SiteEdits.check("localhost", in: [:]), .refused("That isn't a website address"))
        XCTAssertEqual(SiteEdits.check("192.0.2.1", in: [:]), .refused("That isn't a website address"))
        XCTAssertEqual(SiteEdits.check("www.example.com", in: ["example.com": DIRECT]), .refused("example.com already has a route"))
        let full = Dictionary(uniqueKeysWithValues: (0..<Sites.max).map { ("s\($0).example", DIRECT) })
        XCTAssertEqual(SiteEdits.check("example.com", in: full), .refused("A profile holds up to 50 websites"))
        // A duplicate says so even when the list is full.
        XCTAssertEqual(SiteEdits.check("s1.example", in: full), .refused("s1.example already has a route"))
        XCTAssertEqual(SiteEdits.also("netflix.com"), "www.netflix.com")
    }

    func testAChangeAppliesAtCommit() {
        var s = Setup(routes: [nl, us], defaultRoute: "nl")
        SiteEdits.apply(["netflix.com": "us", "bank.example": DIRECT, "tracker.example": BLOCK], to: &s)
        XCTAssertEqual(s.sites, ["netflix.com": "us", "bank.example": DIRECT, "tracker.example": BLOCK])
        // A route gone since (an undo outliving it): the website follows its app again, never another route.
        SiteEdits.apply(["netflix.com": "gone"], to: &s)
        XCTAssertNil(s.sites["netflix.com"])
        // Removing, and an address not written as a rule keeps it is never saved.
        SiteEdits.apply(["bank.example": nil, "Not A Name": DIRECT], to: &s)
        XCTAssertEqual(s.sites, ["tracker.example": BLOCK])
        // No more than a profile holds, but a website already there still moves.
        s.sites = Dictionary(uniqueKeysWithValues: (0..<Sites.max).map { ("s\($0).example", DIRECT) })
        SiteEdits.apply(["one-more.example": DIRECT, "s0.example": "us"], to: &s)
        XCTAssertEqual(s.sites.count, Sites.max)
        XCTAssertNil(s.sites["one-more.example"])
        XCTAssertEqual(s.sites["s0.example"], "us")
        XCTAssertEqual(SiteEdits.assignments(["s0.example", "none.example"], in: s), ["s0.example": .some("us"), "none.example": String?.none])
    }

    func testABlockedWebsiteLeavesTheKillSwitchAsItIs() {
        var s = Setup(routes: [nl], defaultRoute: "nl")
        s.prefs.killLevel = .off
        let edited = Store.edited(s) { SiteEdits.apply(["tracker.example": BLOCK], to: &$0) }
        XCTAssertEqual(edited.sites, ["tracker.example": BLOCK])
        XCTAssertEqual(edited.prefs.killLevel, .off)
    }

    func testAWebsiteOnARouteNoAppUsesMakesItActive() {
        var s = Setup(routes: [nl, us], defaultRoute: "nl")
        XCTAssertEqual(s.activeRoutes.map(\.id), ["nl"])
        SiteEdits.apply(["netflix.com": "us"], to: &s)
        XCTAssertEqual(s.activeRoutes.map(\.id), ["nl", "us"])
    }

    func testTheSheetStartsOnThePagesRouteElseTheFirstOtherElseDirect() {
        let s = Setup(routes: [nl, us], defaultRoute: "nl")
        XCTAssertEqual(SiteEdits.preselected("nl", in: s), "nl")
        XCTAssertEqual(SiteEdits.preselected(BLOCK, in: s), BLOCK)
        XCTAssertEqual(SiteEdits.preselected(nil, in: s), "us")
        XCTAssertEqual(SiteEdits.preselected("gone", in: s), "us")
        XCTAssertEqual(SiteEdits.preselected(nil, in: Setup(routes: [nl], defaultRoute: "nl")), DIRECT)
    }

    func testCountsAndTheRemoveRouteSentence() {
        XCTAssertEqual(Snapshot.count(apps: 5, sites: 0), "5 apps")
        XCTAssertEqual(Snapshot.count(apps: 1, sites: 2), "1 app · 2 websites")
        XCTAssertEqual(Snapshot.count(apps: 0, sites: 1), "1 website")
        XCTAssertEqual(Snapshot.count(apps: 0, sites: 0), "0 apps")
        XCTAssertEqual(Snapshot.websites(0), "0 websites")
        XCTAssertEqual(Snapshot.websites(1), "1 website")
        XCTAssertNil(SiteEdits.losing(0))
        XCTAssertEqual(SiteEdits.losing(1), "1 website follows its app again.")
        XCTAssertEqual(SiteEdits.losing(2), "2 websites follow their apps again.")
        var s = Setup(routes: [nl, us], defaultRoute: "nl")
        s.sites = ["rai.it": "us", "bbc.co.uk": "us", "bank.example": DIRECT]
        XCTAssertEqual(SiteEdits.on("us", in: s), ["bbc.co.uk", "rai.it"])
    }

    /// A newer move of some websites leaves an older one waiting (a limit question) with the rest, as for apps.
    func testAnOverlappingWebsiteMoveKeepsItsRemainingWebsites() {
        var edits = RouteEdits()
        let batch = edits.begin([.site("a.example"), .site("b.example")], move: true)
        let app = edits.begin([.app("a.example")])
        _ = edits.begin([.site("b.example")])
        XCTAssertTrue(edits.contains(batch))
        XCTAssertTrue(edits.contains(app), "an app and a website never share a target")
        XCTAssertEqual(edits.remainingSites(["a.example": DIRECT, "b.example": BLOCK], in: batch), ["a.example": DIRECT])
        // A profile switch changes the websites too: it supersedes the move.
        _ = edits.begin([.profile])
        XCTAssertFalse(edits.contains(batch))
    }

    func testTheWidgetsCountWebsitesAndShowARouteOnlyWebsitesUse() throws {
        var s = Setup(routes: [nl, us], defaultRoute: "nl", apps: ["a": "nl", "b": DIRECT])
        s.sites = ["netflix.com": "us", "bbc.co.uk": "us", "bank.example": DIRECT, "tracker.example": BLOCK]
        let snap = Snapshot.make(phase: .off, since: nil, pausedUntil: nil, failed: false, edited: s, running: nil, exits: 1, week: [])
        XCTAssertEqual(snap.routes.map(\.id), ["nl", "us"])
        XCTAssertEqual(snap.routes.last?.apps, 0)
        XCTAssertEqual(snap.routes.last?.sites, 2)
        XCTAssertNil(snap.routes.first?.sites)
        XCTAssertEqual(snap.direct, 1)
        XCTAssertEqual(snap.directSites, 1)
        XCTAssertEqual(snap.blocked, 0)
        XCTAssertEqual(snap.blockedSites, 1)
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snap)), snap)
        // Older snapshots have no website counts.
        let old = try JSONDecoder().decode(Snapshot.self, from: Data(#"{"phase":"off","exits":1,"routes":[{"id":"nl","name":"NL","code":"NL","hue":0,"apps":1,"isDefault":true}],"direct":0,"blocked":0,"week":[],"updated":0}"#.utf8))
        XCTAssertNil(old.routes.first?.sites)
        XCTAssertNil(old.directSites)
        XCTAssertNil(old.blockedSites)
    }

    func testARouteOnlyAWebsiteUsesCountsAsProtection() {
        var s = Setup(routes: [nl, us], defaultRoute: DIRECT)
        s.sites = ["netflix.com": "us"]
        var state = RunState()
        state.committed(revision: "s", setup: s, fresh: true)
        XCTAssertEqual(state.protection(blocked: []), true)
        XCTAssertEqual(state.protection(blocked: ["us"]), false)
    }
}
