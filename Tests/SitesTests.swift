import XCTest

/// Websites with a route of their own: how an address is kept, and how the saved setup and its profiles carry them.
final class SitesTests: XCTestCase {
    private var setup: Setup {
        Setup(routes: [Route(id: "nl", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands")),
                       Route(id: "us", loc: Location(countryId: 228, countryCode: "US", country: "United States")),
                       Route(id: "it", loc: Location(countryId: 106, countryCode: "IT", country: "Italy"))],
              defaultRoute: "nl", apps: ["com.a": "us"],
              sites: ["example.com": "it", "api.example.com": "us", "bank.example": DIRECT])
    }

    private func saved(_ s: Setup) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return try e.encode(s)
    }

    func testAnAddressIsKeptAsItsName() {
        for (raw, want) in [("netflix.com", "netflix.com"), (" https://www.Netflix.com/browse?x=1#top ", "netflix.com"),
                            ("http://user:pw@Example.org:8080/a", "example.org"), ("sub.example.co.uk.", "sub.example.co.uk"),
                            ("www.rai.it", "rai.it"), ("www.www.example.com", "example.com"), ("WWW.www.com", "www.com"),
                            ("münchen.de", "xn--mnchen-3ya.de"), ("www.com", "www.com")] {
            XCTAssertEqual(Sites.clean(raw), want, raw)
        }
        for bad in ["", "   ", "localhost", "com", "192.168.1.1", "http://10.0.0.1/x", "[2001:db8::1]", "exa mple.com", "-bad.com",
                    "bad-.com", "a_b.com", "*.example.com", "example..com", String(repeating: "a", count: 64) + ".com",
                    String(repeating: String(repeating: "a", count: 60) + ".", count: 5) + "com", "a.b\u{0}.com", "exam\"ple.com", "ex\\ample.com",
                    // What a browser reads as an IPv4 address: a last part that is a number, hexadecimal included.
                    "93.184.216.0x22", "0x7f.1", "example.0x1f", "example.0x", "1.2.3.04", "a.123"] {
            XCTAssertNil(Sites.clean(bad), bad)
        }
        // Read as a browser reads a web address: a backslash is a slash and tabs and line breaks are dropped, so what is
        // saved is the website a browser opens, never a name after an "@" in its path, query or fragment.
        for (raw, want) in [("https://example.com\\@evil.com", "example.com"), ("example.com\\@evil.com", "example.com"),
                            ("https://example.com\\x@evil.com/", "example.com"), ("https:\\\\example.com\\path", "example.com"),
                            ("https://example.com?@evil.com", "example.com"), ("https://example.com#@evil.com", "example.com"),
                            ("https://example.com/@evil.com", "example.com"), ("https://user:p@ss@example.com/", "example.com"),
                            ("exam\tple.com", "example.com"), ("https://exa\nmple.com/\r", "example.com"), ("example.com:443", "example.com")] {
            XCTAssertEqual(Sites.clean(raw), want, raw.debugDescription)
        }
        // A port as a browser takes it, or no website at all.
        for (raw, want) in [("example.com:99999", nil), ("example.com:1x", nil), ("http://example.com:abc/", nil),
                            ("https:/example.com:99999/path", nil), ("example.com:+80", nil), ("example.com:٨٠", nil),
                            ("http://example.com:065535/", "example.com"), ("Example.com:", "example.com"), ("example.com:0", "example.com")] as [(String, String?)] {
            XCTAssertEqual(Sites.clean(raw), want, raw)
        }
        // An international name shows its own letters beside its xn-- form, a long one xn-- first; others as they are.
        XCTAssertEqual(Sites.shown("xn--mnchen-3ya.de"), "münchen.de (xn--mnchen-3ya.de)")
        XCTAssertEqual(Sites.shown("xn--mnchen-3ya.de", asciiFirst: true), "xn--mnchen-3ya.de (münchen.de)")
        XCTAssertEqual(Sites.shown("example.com"), "example.com")
        // What is kept reads back as itself: a saved address is checked that way.
        for raw in ["WWW.netflix.com", "www.www.example.com", "www.com", "www.www.com", "https://www.a.b.example/x", "münchen.de"] {
            let kept = Sites.clean(raw)
            XCTAssertNotNil(kept, raw)
            XCTAssertEqual(kept.flatMap(Sites.clean), kept, raw)
            XCTAssertTrue(kept.map(Sites.isClean) ?? false, raw)
        }
        XCTAssertFalse(Sites.isClean("Example.com"))
        // A saved name is read by its syntax alone (the list of shared endings may be missing): a leading "www." is kept.
        XCTAssertTrue(Sites.isClean("www.example.com"))
        XCTAssertFalse(Sites.isClean("example.com/"))
    }

    func testTheMostSpecificWebsiteMatches() {
        let sites = ["example.com", "api.example.com", "bank.example"]
        XCTAssertEqual(SiteMatch.match("example.com", sites), "example.com")
        XCTAssertEqual(SiteMatch.match("WWW.Example.com.", sites), "example.com")
        XCTAssertEqual(SiteMatch.match("v2.api.example.com", sites), "api.example.com")
        XCTAssertNil(SiteMatch.match("notexample.com", sites))
        XCTAssertNil(SiteMatch.match("example.com.evil.org", sites))
        XCTAssertNil(SiteMatch.match("", sites))
    }

    func testANameUnderAnotherComesFirstAndRunsShareARoute() {
        let runs = Sites.runs(setup.sites)
        XCTAssertEqual(runs.map(\.id), ["us", DIRECT, "it"])
        XCTAssertEqual(runs.map(\.names), [["api.example.com"], ["bank.example"], ["example.com"]])
        let shared = Sites.runs(["b.com": "us", "a.com": "us"])
        XCTAssertEqual(shared.map(\.id), ["us"])
        XCTAssertEqual(shared.first?.names, ["a.com", "b.com"])
        // Deeper names first, whatever their routes are called.
        let deep = Sites.runs(["a.b.c.example": "zz", "example": "aa", "c.example": "mm"].filter { $0.key.contains(".") })
        XCTAssertEqual(deep.map(\.names), [["a.b.c.example"], ["c.example"]])
    }

    func testARouteOnlyAWebsiteUsesIsActive() {
        XCTAssertEqual(setup.activeRoutes.map(\.id), ["nl", "us", "it"])
        var none = setup
        none.sites = [:]
        XCTAssertEqual(none.activeRoutes.map(\.id), ["nl", "us"])
    }

    // MARK: The saved format

    func testASetupWithoutWebsitesIsWrittenAsBefore() throws {
        var s = setup
        s.sites = [:]
        s.profiles = [Profile(name: "Home", defaultRoute: "nl", apps: ["com.a": "us"])]
        let text = String(decoding: try saved(s), as: UTF8.self)
        XCTAssertFalse(text.contains("\"version\""))
        XCTAssertFalse(text.contains("\"sites\""))
        XCTAssertEqual(s.format, 1)
    }

    func testWebsitesStampTheFormatWhereverTheyAre() throws {
        XCTAssertEqual(setup.format, 2)
        XCTAssertTrue(String(decoding: try saved(setup), as: UTF8.self).contains("\"version\":2"))
        var inProfile = setup
        inProfile.sites = [:]
        inProfile.profiles = [Profile(name: "Trip", defaultRoute: "nl", sites: ["example.com": BLOCK])]
        XCTAssertEqual(inProfile.format, 2)
        var pending = setup
        pending.sites = [:]
        pending.profiles = [Profile(name: "Trip", defaultRoute: "nl")]
        pending.pendingSwitch = ProfileSwitch(id: UUID(), target: "Trip", from: nil, when: .now, switched: Profile(name: "Trip", defaultRoute: "nl"),
                                              before: Profile(name: "", defaultRoute: "nl", sites: ["example.com": "it"]))
        XCTAssertEqual(pending.format, 2)
        let back = try JSONDecoder().decode(Setup.self, from: saved(setup))
        XCTAssertEqual(back.sites, setup.sites)
        XCTAssertEqual(back, setup)
    }

    func testASetupFromANewerUnbraidIsRefusedWhole() throws {
        let newer = Data(#"{"version":5,"routes":[],"defaultRoute":"direct","sites":{"example.com":"block"}}"#.utf8)
        for strict in [false, true] {
            XCTAssertThrowsError(try SavedDecoding.$strict.withValue(strict) { try JSONDecoder().decode(Setup.self, from: newer) }) {
                XCTAssertEqual($0 as? Setup.Newer, Setup.Newer(format: 5))
            }
        }
        // This build's own number, and a file from before the number, are read.
        XCTAssertNoThrow(try JSONDecoder().decode(Setup.self, from: Data(#"{"version":2,"defaultRoute":"direct"}"#.utf8)))
        XCTAssertNoThrow(try JSONDecoder().decode(Setup.self, from: Data(#"{"defaultRoute":"direct"}"#.utf8)))
    }

    func testOnlyAddressesAsTheAppWritesThemAreRead() throws {
        let json = #"{"routes":[{"id":"nl"}],"defaultRoute":"nl","sites":{"example.com":"nl","Example.org":"nl","a b.com":"nl","x\".com":"nl","1.2.3.4":"nl"},"#
            + #""profiles":[{"name":"P","defaultRoute":"nl","sites":{"ok.example":"direct","bad..example":"nl"}}]}"#
        let s = try JSONDecoder().decode(Setup.self, from: Data(json.utf8))
        XCTAssertEqual(s.sites, ["example.com": "nl"])
        XCTAssertEqual(s.profiles.first?.sites, ["ok.example": DIRECT])
        // More than the app lets a profile hold is read (a pause's record may hold what ran and the blocks made since),
        // up to a bound; past it the blocks are what stays.
        let many = Dictionary(uniqueKeysWithValues: (0..<80).map { ("site\($0).example", "nl") })
        XCTAssertEqual(Setup.readable(many).count, 80)
        var huge = Dictionary(uniqueKeysWithValues: (0..<300).map { ("site\($0).example", "nl") })
        for i in 250..<300 { huge["site\(i).example"] = BLOCK }
        let kept = Setup.readable(huge)
        XCTAssertEqual(kept.count, Sites.readMax)
        XCTAssertEqual(kept.values.filter { $0 == BLOCK }.count, 50)
    }

    func testAWebsiteOnARouteThatIsGoneIsBlockedNotLeftToItsApp() throws {
        let json = #"{"routes":[{"id":"nl"}],"defaultRoute":"nl","sites":{"example.com":"gone","keep.example":"nl","d.example":"direct"},"#
            + #""profiles":[{"name":"P","defaultRoute":"nl","sites":{"p.example":"gone"}}]}"#
        let s = try JSONDecoder().decode(Setup.self, from: Data(json.utf8))
        XCTAssertEqual(s.sites, ["example.com": BLOCK, "keep.example": "nl", "d.example": DIRECT])
        XCTAssertEqual(s.profiles.first?.sites, ["p.example": BLOCK])
    }

    /// However a route goes (removed, its server removed, Tailscale signed out or set as the only feature, an import with
    /// no provider signed in), its websites follow their apps again at once, in the setup and its profiles, as removing
    /// the route by hand does; the rest stay, and a backup of what is left saves.
    func testWebsitesOnARouteThatGoesFollowTheirAppsWhereverItGoes() throws {
        let wg = WgPeer(name: "Own", privateKey: ProviderFixtures.priv, address: ["10.7.0.2/32"], publicKey: ProviderFixtures.key,
                        endpoint: "203.0.113.70:51820", allowedIps: ["0.0.0.0/0"])
        var imported = wg
        imported.endpoint = "203.0.113.71:51820"
        var before = Setup(routes: [Route(id: "nord", loc: Location(provider: "nord", countryCode: "NL", country: "Netherlands")),
                                    Route(id: "own", wg: wg, own: "s1"), Route(id: "ts", tsExit: "100.64.0.9", tsName: "exit")],
                           defaultRoute: "nord", apps: ["com.a": "own"],
                           sites: ["own.example": "own", "ts.example": "ts", "nord.example": "nord", "d.example": DIRECT, "b.example": BLOCK])
        before.servers = [OwnServer(id: "s1", wg: wg)]
        before.profiles = [Profile(name: "P", defaultRoute: "nord", apps: [:], sites: ["own.example": "own", "ts.example": "ts", "p.example": DIRECT])]
        for (name, remove, gone) in [
            ("removeRoute", { (s: inout Setup) in s.removeRoute("own") }, ["own"]),
            ("removeServer", { $0.removeServer("s1") }, ["own"]),
            ("dropTailscale", { $0.dropTailscale() }, ["ts"]),
            ("useTailscaleOnly", { $0.useTailscaleOnly(noProviders: true) }, ["nord"]),
            ("addImported", { _ = $0.addImported("", id: "new", signedIn: []) { $0.wg = imported } }, ["nord"]),
        ] as [(String, (inout Setup) -> Void, [String])] {
            let after = Store.edited(before, remove)
            let left = Set(after.routes.map(\.id) + [DIRECT, BLOCK])
            XCTAssertEqual(after.sites, before.sites.filter { !gone.contains($0.value) }, name)
            XCTAssertTrue(after.profiles.allSatisfy { $0.sites.values.allSatisfy(left.contains) }, name)
            XCTAssertEqual(after.profiles.first?.sites["p.example"], DIRECT, name)
            XCTAssertNoThrow(try Backup.read(Backup.export(after, app: "1.2.0", created: .now, keys: true)), name)
        }
    }

    /// Any change to the websites must reach the engine before a provider can delay it, as an app leaving Direct does.
    func testAWebsiteChangeNeedsTheInterimRules() {
        var moved = setup
        moved.sites["new.example"] = "us"
        XCTAssertTrue(LinkPicker.needsInterim(from: setup, to: moved))
        var blocked = setup
        blocked.sites["example.com"] = BLOCK
        XCTAssertTrue(LinkPicker.needsInterim(from: setup, to: blocked))
        XCTAssertFalse(LinkPicker.needsInterim(from: setup, to: setup))
        XCTAssertFalse(LinkPicker.needsInterim(from: nil, to: moved))
    }

    /// The setup a pause runs holds what is blocked, websites included: with none of either it needs no engine.
    func testAPauseKeepsBlockedWebsites() {
        XCTAssertTrue(Setup(routes: [], defaultRoute: DIRECT, apps: [:]).assignsNothing)
        XCTAssertFalse(Setup(routes: [], defaultRoute: DIRECT, apps: [:], sites: ["tracker.example": BLOCK]).assignsNothing)
        XCTAssertFalse(Setup(routes: [], defaultRoute: DIRECT, apps: ["com.a": BLOCK]).assignsNothing)
    }

    // MARK: Profiles

    func testProfilesCarryTheirWebsites() {
        var s = setup
        s.saveAs("Home")
        XCTAssertEqual(s.profiles.first?.sites, setup.sites)
        // A new profile starts as a copy; what is edited belongs to the profile in use.
        s.saveAs("Trip")
        s.sites = ["rai.it": "it"]
        XCTAssertEqual(s.profile, "Trip")
        XCTAssertEqual(s.saved.first { $0.name == "Home" }?.sites, setup.sites)
        XCTAssertEqual(s.saved.first { $0.name == "Trip" }?.sites, ["rai.it": "it"])
        s.use("Home")
        XCTAssertEqual(s.sites, setup.sites)
        XCTAssertEqual(s.profiles.first { $0.name == "Trip" }?.sites, ["rai.it": "it"])
        // Removing a route takes it out of the profiles' websites too.
        s.routes.removeAll { $0.id == "it" }
        XCTAssertEqual(s.profiles.first { $0.name == "Trip" }?.sites, [:])
    }

    func testAPendingSwitchKeepsAndRollsBackWebsites() {
        var s = setup
        s.saveAs("Home")
        s.saveAs("Bare")
        s.sites = [:]
        let running = s
        let id = UUID()
        s.beginProfileSwitch("Home", id: id, running: running, engine: "e")
        XCTAssertEqual(s.sites, setup.sites)
        let pending = s.pendingSwitch
        XCTAssertEqual(pending?.switched.sites, setup.sites)
        XCTAssertEqual(pending?.before?.sites, [:])
        XCTAssertEqual(pending?.previous?.sites, [:])
        // Still running the setup without websites: not applied yet.
        XCTAssertEqual(pending?.decide(current: s, running: running, refused: nil, standIn: .none, stopped: false), .waiting)
        XCTAssertEqual(pending?.decide(current: s, running: s, refused: nil, standIn: .none, stopped: false), .applied)
        var rolled = s
        pending?.rollback(&rolled, fallback: running)
        XCTAssertEqual(rolled.sites, [:])
        XCTAssertEqual(rolled.profile, "Bare")
    }

    func testGoingBackToWhatRanKeepsWebsiteEditsMadeSince() {
        var ran = setup
        ran.sites = ["example.com": "it"]
        var switched = ran
        switched.sites = ["example.com": "us"]
        var current = switched
        current.sites["new.example"] = DIRECT
        current.back(to: ran, after: switched)
        XCTAssertEqual(current.sites, ["example.com": "it", "new.example": DIRECT])
        // Plain: a website whose route is gone is blocked, not left out.
        var plain = setup
        plain.routes.removeAll { $0.id == "it" }
        plain.back(to: setup)
        XCTAssertEqual(plain.sites["example.com"], BLOCK)
        XCTAssertEqual(plain.sites["api.example.com"], "us")
    }
}
