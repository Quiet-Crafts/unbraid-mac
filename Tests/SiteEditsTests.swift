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
        XCTAssertEqual(SiteEdits.check("localhost", in: [:]), .refused("localhost is this Mac itself: unbraid can't give it a rule"))
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

    /// Only names no rule can ever work for are refused: `.local` (answered by the devices themselves), this Mac and
    /// address lookups. Names on the local network or in a tailnet are taken: whether their rule applies depends on
    /// the setup (`testWhetherARuleAppliesFollowsTheResolverThatAnswersItsName`).
    func testOnlyNamesNoRuleCanWorkForAreRefused() {
        let no = "unbraid can't give it a rule"
        XCTAssertEqual(SiteEdits.check("nas.local", in: [:]), .refused("nas.local is answered by the devices on your network themselves, never through unbraid: \(no)"))
        XCTAssertEqual(SiteEdits.check("10.in-addr.arpa", in: [:]), .refused("10.in-addr.arpa is a lookup of an address, not a website: \(no)"))
        XCTAssertEqual(SiteEdits.check("app.localhost", in: [:]), .refused("app.localhost is this Mac itself: \(no)"))
        for name in ["printer.lan", "router.home.arpa", "box.fritz.box", "svc.internal", "app.tail9999.ts.net", "nas.corp.example", "lan.example.com"] {
            XCTAssertEqual(SiteEdits.check(name, in: [:]), .valid(name), name)
        }
        // For what is typed only: a saved setup or a backup keeps what it holds (the compiler leaves out what can't work).
        let saved = ["printer.lan": DIRECT, "nas.tail1234.ts.net": "nl", "tracker.lan": BLOCK, "co.uk": BLOCK, "nas.local": DIRECT, "example.com": DIRECT]
        XCTAssertTrue(saved.keys.allSatisfy(Sites.isClean))
        XCTAssertEqual(Setup.readable(saved), saved)
        // A whole paste is read, up to a length no address needs; longer is refused whole, never cut into another name.
        let long = "https://" + String(repeating: "u", count: 280) + "@example.com.au"
        XCTAssertEqual(SiteEdits.check(long, in: [:]), .valid("example.com.au"))
        XCTAssertEqual(SiteEdits.check("https://example.com/?q=" + String(repeating: "a", count: 2000), in: [:]), .refused("That is too long for an address: paste the link alone"))
    }

    /// A rule applies unless, in this setup, the resolver that answers its name is one a website rule would take it from:
    /// Tailscale's or the tailnet's while Reach your tailnet is on, the tailnet's domain refused while it is off, the
    /// local network's while Reach devices on this network is on, its reverse zones, and `.local`. A block always applies.
    func testWhetherARuleAppliesFollowsTheResolverThatAnswersItsName() {
        func reason(_ name: String, _ route: String = "nl", tailscale: Bool = false, headscale: Bool = false, lan: Bool = false, tailnet: String? = nil) -> String? {
            var s = Setup(routes: [Route(id: "nl")], defaultRoute: "nl")
            s.home.tailscale = tailscale
            if headscale { s.home.tsControlUrl = "https://hs.example" }
            s.prefs.lan = lan
            return Sites.notApplied(name, route, in: s, tailnet: tailnet)
        }
        let tailscale = "Tailscale answers ts.net names while Reach your tailnet is on", tailnet = "your tailnet answers this name while Reach your tailnet is on"
        // Someone's public Funnel site: applies unless Tailscale's own server answers all of ts.net.
        XCTAssertNil(reason("app.tail9999.ts.net"))
        XCTAssertEqual(reason("app.tail9999.ts.net", tailscale: true), tailscale)
        XCTAssertNil(reason("app.tail9999.ts.net", tailscale: true, headscale: true))
        XCTAssertEqual(reason("nas.tail1234.ts.net", tailscale: true, tailnet: "tail1234.ts.net"), tailnet)
        // A Headscale tailnet's own domain: once known; refused while Reach your tailnet is off.
        XCTAssertNil(reason("nas.corp.example", tailscale: true, headscale: true))
        XCTAssertEqual(reason("nas.corp.example", tailscale: true, headscale: true, tailnet: "Corp.Example."), tailnet)
        XCTAssertEqual(reason("nas.corp.example", headscale: true, tailnet: "corp.example"), "unbraid leaves your tailnet's names unanswered while Reach your tailnet is off")
        XCTAssertEqual(reason("64.100.in-addr.arpa", tailscale: true), tailnet)
        // Local names: only while the local network answers them.
        for name in ["printer.lan", "router.home.arpa", "box.fritz.box"] {
            XCTAssertNil(reason(name), name)
            XCTAssertEqual(reason(name, lan: true), "your network answers this name while Reach devices on this network is on", name)
        }
        XCTAssertNil(reason("svc.internal", lan: true))
        XCTAssertEqual(reason("168.192.in-addr.arpa"), "your network answers lookups of its own addresses")
        XCTAssertEqual(reason("nas.local"), "the devices on your network answer .local names themselves, never through unbraid")
        // A block always applies.
        for name in ["printer.lan", "nas.local", "app.tail9999.ts.net", "168.192.in-addr.arpa"] { XCTAssertNil(reason(name, BLOCK, tailscale: true, lan: true), name) }
    }

    /// A name that only ends other websites' names (a country's "co.uk", a shared zone such as "k12.ca.us", a hosting
    /// platform) would cover all of them: the Public Suffix List's ICANN section decides, with its wildcards and exceptions.
    func testAPublicSuffixIsNotAWebsite() {
        XCTAssertGreaterThan(Sites.suffixes.count, 1600, "the bundled list is read")
        for name in ["co.uk", "www.co.uk", "com.au", "co.jp", "org.uk", "k12.ca.us", "github.io", "herokuapp.com", "ts.net", "anything.ck", "foo.kawasaki.jp"] {
            let kept = name.hasPrefix("www.") ? String(name.dropFirst(4)) : name
            XCTAssertEqual(SiteEdits.check(name, in: [:]), .refused("\(kept) ends many websites' names: add one website under it"), name)
        }
        for name in ["bbc.co.uk", "example.com.au", "user.github.io", "github.com", "go.co", "co.com", "uk.com", "www.ck", "city.kawasaki.jp", "school.k12.ca.us"] {
            XCTAssertEqual(SiteEdits.check(name, in: [:]), .valid(name == "www.ck" ? "www.ck" : name), name)
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

    /// What is typed is saved as the name a browser opens. Foundation writes an international name by the same rules as
    /// browsers (UTS 46, as the WHATWG URL standard): checked against Node's URL parser for every character after ASCII
    /// in "a<c>x.com" and for 20,000 seeded mixes of scripts, marks, joiners and right-to-left letters, with no
    /// difference. These pairs are from that run, so a change in macOS shows here.
    func testAnInternationalNameIsSavedAsABrowserOpensIt() {
        for (raw, opened) in [("a\u{115F}x.com", "ax.com"), ("faß.de", "xn--fa-hia.de"), ("ab\u{00AD}c.com", "abc.com"), ("\u{217D}.example", "c.example"),
                              ("аpple.example", "xn--pple-43d.example"), ("ＥＸＡＭＰＬＥ.com", "example.com")] {
            XCTAssertEqual(Sites.clean(raw), opened, raw.debugDescription)
        }
        // A joiner browsers keep can't be written as Foundation writes hosts: refused rather than saved as another name.
        XCTAssertNil(Sites.clean("a\u{200D}b.com"))
    }

    /// A name whose letters mix scripts, or are all of another script but look like Latin ones, is shown as it is saved
    /// (the xn-- form), as browsers show it; a search finds it by either form and by the Latin it looks like.
    func testALookAlikeNameIsShownInItsAsciiForm() {
        XCTAssertEqual(Sites.shown("xn--pple-43d.example"), "xn--pple-43d.example")
        XCTAssertEqual(Sites.readings("xn--pple-43d.example"), ["xn--pple-43d.example", "аpple.example", "apple.example"])
        let allCyrillic = Sites.clean("сосо.example")!
        XCTAssertEqual(Sites.shown(allCyrillic), allCyrillic)
        for raw in ["bücher.de", "пример.рф", "例子.测试", "日本語テスト.jp", "한국어.kr", "παράδειγμα.δοκιμή", "عربي.example", "Latin中文.example"] {
            let name = Sites.clean(raw)!
            XCTAssertEqual(Sites.shown(name), raw.lowercased(), raw)
            XCTAssertTrue(Sites.readings(name).contains(name), raw)
        }
        XCTAssertEqual(Sites.readings("example.com"), ["example.com"])
    }

    /// Whatever label a name holds, showing it never traps: a crafted one (an increment near Int.max), an empty one,
    /// bad digits, long runs. Seeded, so a failure repeats. Only a decoding that writes back to the name is shown.
    func testShowingAnyLabelNeverTraps() {
        XCTAssertEqual(SiteEdits.check("xn--mw767205604493046e.com", in: [:]), .valid("xn--mw767205604493046e.com"))
        XCTAssertEqual(Sites.shown("xn--mw767205604493046e.com"), "xn--mw767205604493046e.com")
        for label in ["", "-", "--", "a-", "-a", "zzzzzzzzzzzzzzzzzzzz", "99999999999999999999999", "9", "a", "0", "_", "!",
                      String(repeating: "z", count: 59), String(repeating: "9", count: 59), String(repeating: "-", count: 59)] {
            _ = Punycode.decode(label[...])
            XCTAssertEqual(Sites.shown("xn--\(label).com").isEmpty, false, label)
        }
        XCTAssertEqual(Sites.shown("xn--.com"), "xn--.com")
        var seed: UInt64 = 0x5eed_5175
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789-_.ABZ\u{e9}9")
        for _ in 0..<20_000 {
            let length = Int(next() % 70)
            let label = String((0..<length).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] })
            _ = Punycode.decode(label[...])
            let name = "xn--\(label).example"
            let shown = Sites.shown(name)
            if shown != name { XCTAssertEqual(Sites.clean(shown), Sites.clean(name), name) }
        }
        // Real names among them still decode.
        for raw in ["bücher.de", "例子.测试", "😀.com"] { XCTAssertEqual(Sites.clean(raw).map(Sites.shown), raw, raw) }
    }

    /// A website blocked now is opened by a setup that unblocks it, or that gives a name under it a route of its own.
    func testABlockIsOpenedWholeOrInPart() {
        let here = ["tracker.example": BLOCK, "ads.example": BLOCK, "x.example": "nl"]
        XCTAssertEqual(Sites.opened(here, here), [])
        XCTAssertEqual(Sites.opened(here, ["tracker.example": BLOCK, "cdn.tracker.example": DIRECT, "ads.example": BLOCK]), ["tracker.example"])
        XCTAssertEqual(Sites.opened(here, ["tracker.example": BLOCK, "a.b.tracker.example": "nl", "ads.example": "nl"]), ["ads.example", "tracker.example"])
        XCTAssertEqual(Sites.opened(here, ["tracker.example": BLOCK, "sub.tracker.example": BLOCK, "ads.example": BLOCK]), [])
        XCTAssertEqual(Sites.opened(here, ["tracker.example": BLOCK, "nottracker.example": DIRECT, "ads.example": BLOCK]), [])
        XCTAssertEqual(Sites.opened(here, ["ads.example": BLOCK]), ["tracker.example"])
        // A name under a blocked one that was open before opens nothing new.
        let holed = here.merging(["cdn.tracker.example": DIRECT]) { $1 }
        XCTAssertEqual(Sites.opened(holed, holed), [])
        XCTAssertEqual(Sites.opened(holed, holed.merging(["img.tracker.example": "nl"]) { $1 }), ["tracker.example"])
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

    /// A rule shown as not applied starts no tunnel and protects nothing; once it applies (the setting that answers its
    /// name turned off) its route runs again. A block always counts. The tailnet's domain is judged without websites.
    func testARuleNotAppliedStartsNoRouteAndProtectsNothing() {
        var s = Setup(routes: [nl, us], defaultRoute: DIRECT)
        s.sites = ["printer.lan": "us"]
        s.prefs.lan = true
        var state = RunState()
        state.committed(revision: "s", setup: s, fresh: true)
        XCTAssertEqual(s.activeRoutes.map(\.id), [])
        XCTAssertEqual(state.protection(blocked: []), false)
        s.prefs.lan = false
        state.committed(revision: "t", setup: s, fresh: true)
        XCTAssertEqual(s.activeRoutes.map(\.id), ["us"])
        XCTAssertEqual(state.protection(blocked: []), true)
        // A Funnel site on a Tailscale exit: Tailscale runs for it, and its domain counts, whatever the site's rule.
        var t = Setup(routes: [nl, Route(id: "ts", tsExit: "100.64.0.9")], defaultRoute: DIRECT)
        t.home.tsControlUrl = "https://hs.example"
        t.home.tsSuffix = "corp.example"
        t.sites = ["nas.corp.example": "ts", "app.tail9.ts.net": "ts"]
        XCTAssertTrue(t.tailnetCounts)
        XCTAssertEqual(Sites.tailnet(of: t), "corp.example")
        XCTAssertEqual(Sites.applied(t), ["app.tail9.ts.net": "ts"], "the tailnet's domain is unanswered while Reach your tailnet is off")
        XCTAssertEqual(t.activeRoutes.map(\.id), ["ts"])
        t.sites = ["nas.corp.example": "ts"]
        XCTAssertEqual(t.activeRoutes.map(\.id), [])
        XCTAssertFalse(t.tailscale)
        XCTAssertTrue(t.tailnetCounts, "a saved website on the exit keeps the domain known")
        // A block counts in every state.
        var b = Setup(routes: [nl], defaultRoute: DIRECT)
        b.sites = ["printer.lan": BLOCK]
        b.prefs.lan = true
        XCTAssertEqual(Sites.applied(b), ["printer.lan": BLOCK])
    }
}
