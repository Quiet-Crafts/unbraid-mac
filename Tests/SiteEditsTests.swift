import CryptoKit
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
        XCTAssertEqual(SiteEdits.check("localhost", in: [:]), .refused("localhost is this Mac itself, which apps reach without unbraid, so it can't take a website rule"))
        XCTAssertEqual(SiteEdits.check("co.uk", in: [:]), .refused("co.uk ends many websites' names: add one website under it"))
        XCTAssertEqual(SiteEdits.check("bücher.de", in: ["xn--bcher-kva.de": DIRECT]), .refused("bücher.de (xn--bcher-kva.de) already has a route"))
        let full = Dictionary(uniqueKeysWithValues: (0..<Sites.max).map { ("s\($0).example", DIRECT) })
        XCTAssertEqual(SiteEdits.check("example.com", in: full), .refused("A profile holds up to 50 websites"))
        // At the limit the sheet says so before anything is typed.
        XCTAssertEqual(SiteEdits.check("", in: full), .refused(SiteEdits.full))
        XCTAssertEqual(SiteEdits.check("192.0.2.1", in: full), .refused(SiteEdits.full))
        // A duplicate says so even when the list is full.
        XCTAssertEqual(SiteEdits.check("s1.example", in: full), .refused("s1.example already has a route"))
        XCTAssertEqual(SiteEdits.also("netflix.com"), "www.netflix.com")
    }

    /// Names on the own network or in a Tailscale network are refused, for every route, Block included, each kind with
    /// a sentence that says what it is and which setting looks after it. A saved or restored one is kept as it is.
    func testANameOnTheOwnNetworkOrATailscaleNetworkIsRefusedWithWhy() {
        let end = ", so it can't take a website rule"
        let device = "is a device on your own network, which Reach devices on this network in Settings › Home access looks after"
        for name in ["printer.lan", "nas.local", "router.home.arpa", "box.fritz.box"] {
            XCTAssertEqual(SiteEdits.check(name, in: [:]), .refused("\(name) \(device)\(end)"), name)
        }
        // .internal isn't among the names the local network's resolver is asked: no promise of that setting.
        XCTAssertEqual(SiteEdits.check("svc.internal", in: [:]), .refused("svc.internal is a name for private networks, not a website\(end)"))
        // Only reverse lookups are lookups of an address; other .arpa names are the internet's own.
        XCTAssertEqual(SiteEdits.check("resolver.arpa", in: [:]), .refused("resolver.arpa is part of the internet's own infrastructure, not a website\(end)"))
        XCTAssertEqual(SiteEdits.check("1.0.0.0.ip6.arpa", in: [:]), .refused("1.0.0.0.ip6.arpa is a lookup of an address, not a website\(end)"))
        XCTAssertEqual(SiteEdits.check("app.localhost", in: [:]), .refused("app.localhost is this Mac itself, which apps reach without unbraid\(end)"))
        XCTAssertEqual(SiteEdits.check("localhost", in: [:]), .refused("localhost is this Mac itself, which apps reach without unbraid\(end)"))
        XCTAssertEqual(SiteEdits.check("10.in-addr.arpa", in: [:]), .refused("10.in-addr.arpa is a lookup of an address, not a website\(end)"))
        let tailscale = "belongs to a Tailscale network, which Settings › Tailscale looks after"
        for name in ["app.tail9999.ts.net", "nas.tail1234.ts.net"] {
            XCTAssertEqual(SiteEdits.check(name, in: [:]), .refused("\(name) \(tailscale)\(end)"), name)
        }
        XCTAssertEqual(SiteEdits.check("nas.corp.example", in: [:]), .valid("nas.corp.example"))
        XCTAssertEqual(SiteEdits.check("nas.corp.example", in: [:], tailnet: "Corp.Example."), .refused("nas.corp.example \(tailscale)\(end)"))
        // The tailnet's own domain wins over what its names end in.
        XCTAssertEqual(SiteEdits.check("nas.corp.lan", in: [:], tailnet: "corp.lan"), .refused("nas.corp.lan \(tailscale)\(end)"))
        // The whole name as typed is checked before "www." goes: the tailnet's www.example.org is not the public example.org.
        XCTAssertEqual(SiteEdits.check("https://www.example.org/", in: [:], tailnet: "www.example.org"), .refused("www.example.org \(tailscale)\(end)"))
        XCTAssertEqual(SiteEdits.check("https://www.example.org/", in: [:]), .valid("example.org"))
        XCTAssertEqual(SiteEdits.check("lan.example.com", in: [:]), .valid("lan.example.com"))
        // For what is typed only: a saved setup or a backup keeps what it holds (the compiler leaves out what can't work).
        let saved = ["printer.lan": DIRECT, "nas.tail1234.ts.net": "nl", "tracker.lan": BLOCK, "co.uk": BLOCK, "nas.local": DIRECT, "example.com": DIRECT]
        XCTAssertTrue(saved.keys.allSatisfy(Sites.isClean))
        XCTAssertEqual(Setup.readable(saved), saved)
        // A whole paste is read, up to a length no address needs; longer is refused whole, never cut into another name.
        let long = "https://" + String(repeating: "u", count: 280) + "@example.com.au"
        XCTAssertEqual(SiteEdits.check(long, in: [:]), .valid("example.com.au"))
        XCTAssertEqual(SiteEdits.check("https://example.com/?q=" + String(repeating: "a", count: 2000), in: [:]), .refused("That is too long for an address: paste the link alone"))
    }

    /// Whether a rule applies depends on its name and the saved tailnet domain only, never on what runs: the same in
    /// every state of Tailscale and the local network. A route or Direct for a name in the set never applies, with the
    /// refusal's words on its row; a block always does, and says what it can't cover for .local and localhost names.
    func testWhetherARuleAppliesDependsOnItsNameAlone() {
        let names = ["printer.lan", "nas.local", "router.home.arpa", "svc.internal", "dev.localhost", "168.192.in-addr.arpa", "app.tail9.ts.net",
                     "nas.corp.example", "netflix.com"]
        var seen: [String: Set<Bool>] = [:]
        for tailscale in [false, true] { for headscale in [false, true] { for lan in [false, true] { for exit in [false, true] { for route in ["nl", DIRECT] {
            var s = Setup(routes: [Route(id: "nl"), Route(id: "ts", tsExit: "100.64.0.9")], defaultRoute: DIRECT)
            s.home.tailscale = tailscale
            s.home.tsSuffix = "corp.example"
            s.home.tsControlUrl = headscale ? "https://hs.example" : nil
            s.home.tsSuffixConfirmed = true
            s.prefs.lan = lan
            if exit { s.apps["com.a"] = "ts" }
            s.sites = Dictionary(uniqueKeysWithValues: names.map { ($0, route) })
            let applied = Sites.applied(s)
            for name in names { seen[name, default: []].insert(applied[name] != nil) }
        } } } } }
        for name in names { XCTAssertEqual(seen[name], [name == "netflix.com"], name) }
        var s = Setup(routes: [Route(id: "nl")], defaultRoute: DIRECT)
        s.sites = ["printer.lan": "nl", "nas.local": BLOCK, "dev.localhost": BLOCK, "tracker.lan": BLOCK]
        XCTAssertEqual(Sites.notApplied("printer.lan", in: s), "Not applied: printer.lan is a device on your own network, which Reach devices on this network in Settings › Home access looks after")
        XCTAssertNil(Sites.notApplied("nas.local", in: s))
        XCTAssertEqual(Sites.applied(s).keys.sorted(), ["dev.localhost", "nas.local", "tracker.lan"])
        XCTAssertNotNil(Sites.limited("nas.local", in: s))
        XCTAssertNotNil(Sites.limited("dev.localhost", in: s))
        XCTAssertNil(Sites.limited("tracker.lan", in: s))
    }

    /// A name that ends other websites' names (a country's "co.uk", a shared zone such as "k12.ca.us" or "police.uk",
    /// the base of a wildcard such as "sch.uk", a hosting platform), or sits above such endings ("nordland.no" above
    /// "bo.nordland.no"), would cover all of them: the Public
    /// Suffix List's whole ICANN section decides, with its wildcards and exceptions. "www." stays on a name whose rest is
    /// such an ending: www.gob.mx is Mexico's portal, gob.mx all of Mexico's government.
    func testAPublicSuffixIsNotAWebsite() throws {
        let list = try XCTUnwrap(Sites.suffixes, "the bundled list is read and sound")
        XCTAssertEqual(list.count, 5512)
        for name in ["co.uk", "com.au", "co.jp", "org.uk", "k12.ca.us", "police.uk", "nhs.uk", "asn.au", "gob.mx", "sch.uk", "github.io",
                     "herokuapp.com", "anything.ck", "foo.kawasaki.jp", "school.sch.uk", "nordland.no", "kawasaki.jp"] {
            XCTAssertEqual(SiteEdits.check(name, in: [:]), .refused("\(name) ends many websites' names: add one website under it"), name)
        }
        for (raw, kept) in [("bbc.co.uk", "bbc.co.uk"), ("example.com.au", "example.com.au"), ("user.github.io", "user.github.io"), ("github.com", "github.com"),
                            ("go.co", "go.co"), ("co.com", "co.com"), ("uk.com", "uk.com"), ("www.ck", "www.ck"), ("city.kawasaki.jp", "city.kawasaki.jp"),
                            ("school.k12.ca.us", "school.k12.ca.us"), ("https://www.gob.mx/", "www.gob.mx"), ("www.police.uk", "www.police.uk"),
                            ("www.www.gob.mx", "www.gob.mx"), ("www.example.com", "example.com")] {
            XCTAssertEqual(SiteEdits.check(raw, in: [:]), .valid(kept), raw)
            XCTAssertTrue(Sites.isClean(kept), kept)
        }
        // A name kept with its "www." reads back as itself, so a saved one and a restored one stay.
        XCTAssertEqual(Setup.readable(["www.gob.mx": DIRECT]), ["www.gob.mx": DIRECT])
    }

    /// A saved rule is read by its syntax alone, never by the list of shared endings: a saved block of www.gob.mx (kept
    /// with its "www." because gob.mx is a shared ending) stays a block if the list is missing or damaged.
    func testASavedBlockSurvivesAMissingList() {
        XCTAssertTrue(Sites.isClean("www.gob.mx"))
        XCTAssertEqual(Setup.readable(["www.gob.mx": BLOCK]), ["www.gob.mx": BLOCK])
        let s = Setup(routes: [], defaultRoute: DIRECT, apps: [:], sites: ["www.gob.mx": BLOCK])
        XCTAssertEqual(Sites.applied(s), ["www.gob.mx": BLOCK])
    }

    /// Without a sound list (missing, or not the file this build ships) a new name is refused with why, and a saved
    /// block of a name the list would keep with its "www." still applies, and compiles as a block.
    func testADamagedOrMissingListRefusesNewNamesAndKeepsSavedBlocks() throws {
        XCTAssertNil(Sites.Endings(nil))
        XCTAssertNil(Sites.Endings(Data("co.uk\n".utf8)))
        for list in [Sites.Endings(nil), Sites.Endings(Data("co.uk\n".utf8))] {
            XCTAssertEqual(Sites.refusal("co.uk", tailnet: nil, list: list), Sites.damaged)
            XCTAssertEqual(Sites.refusal("example.com", tailnet: nil, list: list), Sites.damaged)
        }
        XCTAssertEqual(Sites.refusal("co.uk", tailnet: nil), "co.uk ends many websites' names: add one website under it")
        let saved = Setup(routes: [], defaultRoute: DIRECT, apps: [:], sites: ["www.gob.mx": BLOCK])
        XCTAssertEqual(Sites.applied(saved), ["www.gob.mx": BLOCK])
        let config = try Compiler.compile(Compiler.Input(setup: saved, links: [:], apps: [:], selfPattern: "^/x$", tsSuffix: nil))
        XCTAssertTrue(config.contains("www.gob.mx"))
    }

    /// A parent of a hosting platform the app refuses is refused too: amazonaws.com sits above s3.amazonaws.com.
    func testAParentOfARefusedPlatformIsRefused() {
        XCTAssertEqual(SiteEdits.check("amazonaws.com", in: [:]), .refused("amazonaws.com ends many websites' names: add one website under it"))
        XCTAssertEqual(SiteEdits.check("aws.amazon.com", in: [:]), .valid("aws.amazon.com"))
    }

    /// A long international name shows its xn-- form first, so a row cut at its end still shows what the name is.
    func testALongInternationalNameShowsItsAsciiFormFirst() throws {
        let long = try XCTUnwrap(Sites.clean("bücher." + String(repeating: "a", count: 40) + "." + String(repeating: "b", count: 40) + ".com"))
        XCTAssertTrue(Sites.shown(long).hasPrefix("xn--bcher-kva."), Sites.shown(long))
        XCTAssertEqual(Sites.shown("xn--bcher-kva.de"), "bücher.de (xn--bcher-kva.de)")
    }

    /// Moving or adding a name on the own network or in a Tailscale network is refused when it is committed too (a
    /// route menu, a drag, an add retried after a limit question), Block included; one saved can still be removed.
    func testAnOwnNetworkNameIsNeitherAddedNorMovedAtCommit() {
        var s = Setup(routes: [nl, us], defaultRoute: DIRECT)
        s.sites = ["printer.lan": DIRECT]
        SiteEdits.apply(["printer.lan": BLOCK, "nas.local": BLOCK, "app.tail9.ts.net": "us", "netflix.com": "us"], to: &s)
        XCTAssertEqual(s.sites, ["printer.lan": DIRECT, "netflix.com": "us"])
        s.home.tsSuffix = "corp.example"
        SiteEdits.apply(["nas.corp.example": BLOCK], to: &s)
        XCTAssertNil(s.sites["nas.corp.example"])
        SiteEdits.apply(["printer.lan": nil], to: &s)
        XCTAssertEqual(s.sites, ["netflix.com": "us"])
    }

    /// The list is the file this build ships, checked by its digest: a missing, cut or changed file takes no new
    /// website, with why, rather than one a sound list would refuse.
    func testADamagedListTakesNoNewWebsite() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "shared_suffixes", withExtension: "txt"))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), Sites.suffixesDigest)
        XCTAssertTrue(Sites.damaged.contains("no website can be added"))
    }

    /// An international name is saved in its ASCII form and shown in its own letters with that form beside it.
    func testAnInternationalNameIsShownWithItsAsciiForm() {
        XCTAssertEqual(Sites.shown("xn--bcher-kva.de"), "bücher.de (xn--bcher-kva.de)")
        XCTAssertEqual(Sites.shown("www.xn--fsqu00a.xn--0zwm56d"), "www.例子.测试 (www.xn--fsqu00a.xn--0zwm56d)")
        XCTAssertEqual(Sites.shown("example.com"), "example.com")
        XCTAssertEqual(Sites.shown("xn--zz.example"), "xn--zz.example", "a label that doesn't decode stays as it is")
        for raw in ["bücher.de", "münchen.de", "例子.测试", "παράδειγμα.δοκιμή"] {
            let name = Sites.clean(raw)!
            XCTAssertEqual(Sites.shown(name), "\(raw) (\(name))", raw)
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

    /// A name whose letters only look like Latin ones always shows its xn-- form beside them, and a search finds it by
    /// either form: no table of look-alikes to keep complete.
    func testALookAlikeNameAlwaysShowsItsAsciiForm() throws {
        let cisco = try XCTUnwrap(Sites.clean("с\u{A647}ѕсо.example"))
        XCTAssertEqual(cisco, "xn--n1afa3f3774h.example")
        XCTAssertEqual(Sites.shown(cisco), "с\u{A647}ѕсо.example (xn--n1afa3f3774h.example)")
        XCTAssertEqual(Sites.readings("xn--pple-43d.example"), ["xn--pple-43d.example", "аpple.example"])
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
            if shown != name { XCTAssertTrue(shown.hasSuffix(" (\(name))") || shown.hasPrefix("\(name) ("), name) }
        }
        // Real names among them still decode.
        for raw in ["bücher.de", "例子.测试", "😀.com"] { XCTAssertEqual(Sites.clean(raw).map(Sites.shown), Sites.clean(raw).map { "\(raw) (\($0))" }, raw) }
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

    /// A rule for a name on the own network or in a Tailscale network starts no route and protects nothing, whatever
    /// the settings of the moment; one for a public name on the same route does. A block always counts.
    func testARuleNotAppliedStartsNoRouteAndProtectsNothing() {
        var s = Setup(routes: [nl, us], defaultRoute: DIRECT)
        s.sites = ["printer.lan": "us"]
        var state = RunState()
        for lan in [true, false] {
            s.prefs.lan = lan
            state.committed(revision: "\(lan)", setup: s, fresh: true)
            XCTAssertEqual(s.activeRoutes.map(\.id), [])
            XCTAssertEqual(state.protection(blocked: []), false)
        }
        s.sites["netflix.com"] = "us"
        state.committed(revision: "n", setup: s, fresh: true)
        XCTAssertEqual(s.activeRoutes.map(\.id), ["us"])
        XCTAssertEqual(state.protection(blocked: []), true)
        // The tailnet's own domain counts as the user accepted it, whether Tailscale runs or not.
        var t = Setup(routes: [nl, Route(id: "ts", tsExit: "100.64.0.9")], defaultRoute: DIRECT)
        t.home.tsControlUrl = "https://hs.example"
        t.home.tsSuffix = "corp.example"
        t.sites = ["nas.corp.example": "ts", "app.tail9.ts.net": "ts"]
        XCTAssertEqual(Sites.tailnet(of: t), "corp.example")
        XCTAssertEqual(Sites.applied(t), [:])
        XCTAssertEqual(t.activeRoutes.map(\.id), [])
        // A block counts in every state.
        var b = Setup(routes: [nl], defaultRoute: DIRECT)
        b.sites = ["printer.lan": BLOCK]
        b.prefs.lan = true
        XCTAssertEqual(Sites.applied(b), ["printer.lan": BLOCK])
        // The profile summaries say how many aren't applied.
        XCTAssertEqual(Sites.notAppliedCount(["printer.lan": "us", "netflix.com": "us", "tracker.lan": BLOCK], in: Setup(routes: [nl, us], defaultRoute: DIRECT)), 1)
    }
}
