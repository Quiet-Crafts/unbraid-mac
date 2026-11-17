import XCTest

/// Adding, moving and removing websites, and how they are counted where apps are.
final class SiteEditsTests: XCTestCase {
    private let nl = Route(id: "nl", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands"))
    private let us = Route(id: "us", loc: Location(countryId: 228, countryCode: "US", country: "United States"), hue: 1)

    func testAnAddressIsCheckedAsTheSheetSaysIt() {
        XCTAssertEqual(SiteEdits.check("  ", in: [:]), .empty)
        XCTAssertEqual(SiteEdits.check("https://www.Netflix.com/browse", in: [:]), .valid("netflix.com"))
        XCTAssertEqual(SiteEdits.check("exa mple.com", in: [:]), .refused("That isn't a website address"))
        XCTAssertEqual(SiteEdits.check("www.example.com", in: ["example.com": DIRECT]), .refused("example.com already has a route"))
        // Each refusal says why, in words that fit the address typed.
        let address = "An IP address can't have a rule: add the website's name"
        for raw in ["192.0.2.1", "http://10.0.0.1:8080/x", "[2001:db8::1]", "2001:db8::1", "https://[2001:db8::1]/x"] {
            XCTAssertEqual(SiteEdits.check(raw, in: [:]), .refused(address), raw)
        }
        XCTAssertEqual(SiteEdits.check("netflix", in: [:]), .refused("Add the whole name, such as netflix.com"))
        XCTAssertEqual(SiteEdits.check("localhost", in: [:]), .refused("localhost is a name on your own network: a rule can't route it"))
        XCTAssertEqual(SiteEdits.check("co.uk", in: [:]), .refused("co.uk ends many websites' names: add one website under it"))
        XCTAssertEqual(SiteEdits.check("bücher.de", in: ["xn--bcher-kva.de": DIRECT]), .refused("bücher.de already has a route"))
        let full = Dictionary(uniqueKeysWithValues: (0..<Sites.max).map { ("s\($0).example", DIRECT) })
        XCTAssertEqual(SiteEdits.check("example.com", in: full), .refused("A profile holds up to 50 websites"))
        // At the limit the sheet says so before anything is typed.
        XCTAssertEqual(SiteEdits.check("", in: full), .refused(SiteEdits.full))
        XCTAssertEqual(SiteEdits.check("192.0.2.1", in: full), .refused(SiteEdits.full))
        // A duplicate says so even when the list is full.
        XCTAssertEqual(SiteEdits.check("s1.example", in: full), .refused("s1.example already has a route"))
        XCTAssertEqual(SiteEdits.also("netflix.com"), "www.netflix.com")
    }

    /// Names on the local network or in a tailnet can't take a route: their own resolver answers them, which a
    /// website's route would skip (and `.local` names never pass unbraid). The tailnet's own domain counts once known.
    func testNamesOnTheOwnNetworkOrTailnetAreRefused() {
        for name in ["printer.lan", "nas.local", "router.home.arpa", "box.fritz.box", "10.in-addr.arpa", "app.localhost", "svc.internal"] {
            XCTAssertEqual(SiteEdits.check(name, in: [:]), .refused("\(name) is a name on your own network: a rule can't route it"), name)
        }
        for name in ["nas.tail1234.ts.net", "ts.net"] {
            XCTAssertEqual(SiteEdits.check(name, in: [:]), .refused("\(name) is a name in your tailnet: a rule can't route it"), name)
        }
        XCTAssertEqual(SiteEdits.check("nas.corp.example", in: [:]), .valid("nas.corp.example"))
        XCTAssertEqual(SiteEdits.check("nas.corp.example", in: [:], tailnet: "corp.example"), .refused("nas.corp.example is a name in your tailnet: a rule can't route it"))
        XCTAssertEqual(SiteEdits.check("lan.example.com", in: [:]), .valid("lan.example.com"))
        XCTAssertEqual(SiteEdits.check("planet.com", in: [:]), .valid("planet.com"))
        // For what is typed only: a saved setup or a backup keeps what it holds (the compiler leaves out what can't work).
        let saved = ["printer.lan": DIRECT, "nas.tail1234.ts.net": "nl", "tracker.lan": BLOCK, "co.uk": BLOCK, "example.com": DIRECT]
        XCTAssertTrue(saved.keys.allSatisfy(Sites.isClean))
        XCTAssertEqual(Setup.readable(saved), saved)
    }

    /// A name that only ends other websites' names (a country's "co.uk", a hosting platform) would cover all of them.
    func testAPublicSuffixIsNotAWebsite() {
        for name in ["co.uk", "www.co.uk", "com.au", "co.jp", "org.uk", "github.io", "herokuapp.com"] {
            let kept = name.hasPrefix("www.") ? String(name.dropFirst(4)) : name
            XCTAssertEqual(SiteEdits.check(name, in: [:]), .refused("\(kept) ends many websites' names: add one website under it"), name)
        }
        for name in ["bbc.co.uk", "example.com.au", "user.github.io", "github.com", "co.com", "uk.com"] {
            XCTAssertEqual(Sites.clean(name), name, name)
        }
    }

    /// An international name is saved in its ASCII form and shown in its own letters.
    func testAnInternationalNameIsShownInItsOwnLetters() {
        XCTAssertEqual(Sites.shown("xn--bcher-kva.de"), "bücher.de")
        XCTAssertEqual(Sites.shown("xn--mnchen-3ya.de"), "münchen.de")
        XCTAssertEqual(Sites.shown("www.xn--fsqu00a.xn--0zwm56d"), "www.例子.测试")
        XCTAssertEqual(Sites.shown("example.com"), "example.com")
        XCTAssertEqual(Sites.shown("xn--zz.example"), "xn--zz.example", "a label that doesn't decode stays as it is")
        for raw in ["bücher.de", "münchen.de", "例子.测试", "παράδειγμα.δοκιμή"] {
            XCTAssertEqual(Sites.clean(raw).map(Sites.shown), raw, raw)
        }
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
