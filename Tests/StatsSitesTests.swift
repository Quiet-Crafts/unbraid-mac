import XCTest

/// A website with a route of its own counted in an app's place: what the extension takes and sends, and how the app
/// keys, attributes, sums and names it.
final class StatsSitesTests: XCTestCase {
    // MARK: The extension's side

    func testTheExtensionTakesOnlyAListThatCanBeASetupsWebsites() {
        XCTAssertEqual(SiteMatch.accepted([]), [])
        XCTAssertEqual(SiteMatch.accepted(["example.com", "api.example.org", "xn--bcher-kva.example", "a-b.c0"]),
                       ["example.com", "api.example.org", "xn--bcher-kva.example", "a-b.c0"])
        for bad in ["", "Example.com", "localhost", "example..com", ".example.com", "example.com.", "-a.example", "a-.example",
                    "ex_ample.com", "exämple.com", "example.com/x", "example.com:443", "*.example.com", " example.com",
                    "example.com\n", "\(String(repeating: "a", count: 64)).com"] {
            XCTAssertNil(SiteMatch.accepted(["example.org", bad]), bad)
        }
        // At most 253 bytes, and at most as many as a profile holds.
        let long = Array(repeating: String(repeating: "a", count: 62), count: 4).joined(separator: ".") + ".com" // 255
        XCTAssertNil(SiteMatch.accepted([long]))
        let fits = Array(repeating: String(repeating: "a", count: 62), count: 4).joined(separator: ".") + ".c" // 253
        XCTAssertEqual(fits.utf8.count, 253)
        XCTAssertEqual(SiteMatch.accepted([fits]), [fits])
        let fifty = (0..<50).map { "s\($0).example" }
        XCTAssertEqual(SiteMatch.accepted(fifty), fifty)
        XCTAssertNil(SiteMatch.accepted(fifty + ["one-more.example"]))
        XCTAssertEqual(Sites.max, SiteMatch.max)
    }

    /// A connection to a stand-in address carries its name in the destination, with no name found beside it: that is
    /// how every connection under a website rule arrives.
    func testTheNameOfAConnectionIsItsDestinationWhenTheEngineFoundNoOther() {
        XCTAssertEqual(SiteMatch.name(domain: "", destination: "www.netflix.com:443"), "www.netflix.com")
        XCTAssertEqual(SiteMatch.name(domain: "sniffed.example.org", destination: "192.0.2.7:443"), "sniffed.example.org")
        XCTAssertEqual(SiteMatch.name(domain: "sniffed.example.org", destination: "other.example:443"), "sniffed.example.org")
        XCTAssertEqual(SiteMatch.name(domain: "", destination: "192.0.2.7:443"), "192.0.2.7")
        XCTAssertEqual(SiteMatch.name(domain: "", destination: "[2001:db8::1]:443"), "")
        XCTAssertEqual(SiteMatch.name(domain: "", destination: "netflix.com"), "netflix.com")
        XCTAssertEqual(SiteMatch.name(domain: "", destination: ""), "")
        let sites = ["netflix.com", "example.org"]
        func site(_ domain: String, _ destination: String) -> String? { SiteMatch.match(SiteMatch.name(domain: domain, destination: destination), sites) }
        XCTAssertEqual(site("", "www.netflix.com:443"), "netflix.com")
        XCTAssertEqual(site("", "example.org:80"), "example.org")
        XCTAssertEqual(site("api.example.org", "192.0.2.7:443"), "example.org")
        for destination in ["192.0.2.7:443", "[2001:db8::1]:443", "notnetflix.com:443", "netflix.com.evil.example:443", ""] {
            XCTAssertNil(site("", destination), destination)
        }
    }

    func testTheMatchIsTheRulesAddressNeverTheNameLookedUp() {
        let sites = ["netflix.com", "example.org"]
        XCTAssertEqual(SiteMatch.match("www.netflix.com", sites), "netflix.com")
        XCTAssertEqual(SiteMatch.match("assets.nflx.netflix.com.", sites), "netflix.com")
        XCTAssertEqual(SiteMatch.match("EXAMPLE.org", sites), "example.org")
        // Names outside the list, IP addresses and an unknown name give nothing at all.
        for host in ["", "netflix.co", "notnetflix.com", "netflix.com.evil.example", "192.0.2.7", "2001:db8::1", "example.com"] {
            XCTAssertNil(SiteMatch.match(host, sites), host)
        }
        XCTAssertNil(SiteMatch.match("www.netflix.com", [String]()))
        // Whatever is returned is an element of the list, whatever case the name came in.
        XCTAssertTrue(sites.contains(SiteMatch.match("WWW.NETFLIX.COM", sites) ?? ""))
    }

    func testTheWireCarriesASiteOnlyWhenSet() throws {
        let plain = EngineWire.Connection(up: 1, down: 2, path: "/x", chain: ["r-nl"], inbound: "tun", createdAt: 3, closedAt: 0)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("site"))
        var routed = plain
        routed.site = "netflix.com"
        XCTAssertEqual(try JSONDecoder().decode(EngineWire.Connection.self, from: JSONEncoder().encode(routed)).site, "netflix.com")
        // What an older extension sends (no site at all) still reads.
        let old = Data(#"{"up":1,"down":2,"path":"/x","chain":[],"inbound":"tun","createdAt":3,"closedAt":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(EngineWire.Connection.self, from: old).site)
    }

    // MARK: The app's side

    private func ev(_ id: String, site: String?, own: Bool = false, total: (Int64, Int64)? = (10, 20), kind: Ledger.Kind = .new) -> Ledger.Ev {
        Ledger.Ev(kind: kind, id: id, total: total.map { Traffic(up: $0.0, down: $0.1) }, delta: Traffic(up: 1, down: 2),
                  path: "/Applications/Safari.app/Contents/MacOS/Safari", tag: "r-us", closed: false, created: 0, own: own, site: site)
    }

    func testAMatchedConnectionCountsUnderItsWebsiteNotTheBrowser() {
        let program: (String) -> String = { $0.hasPrefix("/Applications/Safari.app") ? "com.apple.Safari" : "?" }
        XCTAssertEqual(StatsMath.key(of: ev("1", site: "netflix.com"), own: "app.unbraid", program: program), "site:netflix.com")
        XCTAssertEqual(StatsMath.key(of: ev("2", site: nil), own: "app.unbraid", program: program), "com.apple.Safari")
        // The app's own probes stay its own; a name that is no rule's address is never a website key.
        XCTAssertEqual(StatsMath.key(of: ev("3", site: "netflix.com", own: true), own: "app.unbraid", program: program), "app.unbraid")
        for bad in ["netflix.com.", "Netflix.com", "", "/Applications/Evil.app", "netflix"] {
            XCTAssertEqual(StatsMath.key(of: ev("4", site: bad), own: "app.unbraid", program: program), "com.apple.Safari", bad)
        }
    }

    func testKeysAndAddressesRoundTrip() {
        XCTAssertEqual(StatsMath.siteKey("example.com"), "site:example.com")
        XCTAssertNil(StatsMath.siteKey(nil))
        XCTAssertNil(StatsMath.siteKey("Example.com"))
        XCTAssertEqual(StatsMath.site("site:example.com"), "example.com")
        for key in ["com.apple.Safari", "/usr/bin/curl", "~/bin/tool", "?", StatsMath.otherPrograms, "app.unbraid", "sites.example"] {
            XCTAssertNil(StatsMath.site(key), key)
        }
    }

    func testTheExtensionIsGivenTheWebsitesThatCarryTraffic() {
        var s = Setup()
        s.routes = [Route(id: "us")]
        s.sites = ["netflix.com": "us", "news.example": DIRECT, "ads.example": BLOCK, "Bad Name": "us"]
        XCTAssertEqual(StatsMath.countedSites(s), ["netflix.com", "news.example"])
        s.sites = Dictionary(uniqueKeysWithValues: (0..<60).map { ("s\($0).example", DIRECT) })
        let counted = StatsMath.countedSites(s)
        XCTAssertEqual(counted.count, SiteMatch.max)
        XCTAssertNotNil(SiteMatch.accepted(counted))
        XCTAssertEqual(StatsMath.countedSites(Setup()), [])
        // A rule that isn't applied (a name on the own network or in the tailnet, saved on a route or Direct) is not
        // counted: its name's traffic stays its app's. The counts and the widget go by the same.
        s.sites = ["nas.internal": DIRECT, "printer.lan": "us", "nas.corp.example": "us", "tracker.lan": BLOCK, "netflix.com": "us"]
        // Whatever the settings of the moment: devices on the own network never count; a name under a domain only does
        // until that domain is the tailnet's own.
        for lan in [true, false] {
            s.prefs.lan = lan
            XCTAssertEqual(StatsMath.countedSites(s), ["nas.corp.example", "netflix.com"])
            XCTAssertEqual(SiteEdits.applied(BLOCK, in: s), ["tracker.lan"])
            XCTAssertEqual(SiteEdits.applied(DIRECT, in: s), [])
        }
        s.home.tsSuffix = "corp.example"
        XCTAssertEqual(StatsMath.countedSites(s), ["netflix.com"])
    }

    /// One decision for every part of the app: with Headscale's own domain accepted, a rule under it is not applied for
    /// the compiler, the statistics, the route counts, the rows and the widgets alike, with Tailscale on or off.
    func testEveryPartJudgesAWebsiteByTheSameTailnetDomain() throws {
        var s = Setup()
        s.routes = [Route(id: "us")]
        s.defaultRoute = DIRECT
        s.sites = ["host.corp.example": DIRECT, "nas.corp.example": "us", "netflix.com": "us", "tracker.corp.example": BLOCK]
        s.home.tailscale = true
        s.home.tsControlUrl = "https://hs.example"
        s.home.tsSuffix = "corp.example"
        XCTAssertEqual(Sites.tailnet(of: s), "corp.example")
        XCTAssertEqual(Sites.applied(s), ["netflix.com": "us", "tracker.corp.example": BLOCK])
        XCTAssertEqual(StatsMath.countedSites(s), ["netflix.com"])
        XCTAssertEqual(SiteEdits.applied("us", in: s), ["netflix.com"])
        XCTAssertFalse(Sites.isApplied("host.corp.example", in: s))
        let widget = Snapshot.make(phase: .off, since: nil, pausedUntil: nil, failed: false, edited: s, running: nil, exits: 0, week: [])
        XCTAssertNil(widget.directSites)
        XCTAssertEqual(widget.blockedSites, 1)
        // The compiler, given the domain the app gives it, leaves the same rules out.
        XCTAssertEqual(Sites.applied(s, tailnet: "Corp.Example."), Sites.applied(s))
        // (Compiled without Tailscale's own engine parts, which need an account; the domain is handed in as the app does.)
        var plain = s
        plain.home.tailscale = false
        plain.routes = []
        let config = try Compiler.compile(Compiler.Input(setup: plain, links: [:], apps: [:], selfPattern: "^/x$", tsSuffix: Sites.tailnet(of: s)))
        XCTAssertFalse(config.contains("host.corp.example"))
        XCTAssertTrue(config.contains("tracker.corp.example"))
        s.home.tailscale = false
        XCTAssertEqual(Sites.tailnet(of: s), "corp.example")
        XCTAssertEqual(StatsMath.countedSites(s), ["netflix.com"])
    }

    func testAWebsitesExitIsItsOwnRouteWhereRoutesShareATunnel() {
        var s = Setup()
        s.routes = [Route(id: "nl"), Route(id: "us")]
        s.defaultRoute = "nl"
        s.apps = ["com.apple.Safari": "nl"]
        s.sites = ["netflix.com": "us"]
        let tags = ["nl": "r-shared", "us": "r-shared"]
        XCTAssertEqual(StatsMath.exitOf(tag: "r-shared", app: "site:netflix.com", setup: s, tags: tags), "us")
        XCTAssertEqual(StatsMath.exitOf(tag: "r-shared", app: "com.apple.Safari", setup: s, tags: tags), "nl")
        // A rule removed since follows the default; Direct stays Direct.
        XCTAssertEqual(StatsMath.exitOf(tag: "r-shared", app: "site:gone.example", setup: s, tags: tags), "nl")
        XCTAssertEqual(StatsMath.exitOf(tag: "direct", app: "site:netflix.com", setup: s, tags: tags), DIRECT)
    }

    func testAProgramIsNeverTakenForAWebsite() {
        // A bundle claiming a website's key is counted by its location instead.
        let key = StatsMath.ownerKey(path: "/Applications/Evil.app/Contents/MacOS/evil", bundles: [("/Applications/Evil.app", "site:netflix.com")],
                                     tools: [], home: "/Users/me") { _ in "site:netflix.com" }
        XCTAssertEqual(key, "/Applications/Evil.app/Contents/MacOS/evil")
        XCTAssertEqual(StatsMath.ownerKey(path: "site:netflix.com", bundles: [], tools: [], home: "/Users/me") { _ in nil }, "?")
    }

    func testWebsiteRowsRollUpAndReadBackLikeApps() {
        var ledger = Ledger()
        let open: (Ledger.Ev) -> Ledger.Conn = { e in
            Ledger.Conn(app: StatsMath.key(of: e, own: "app.unbraid") { _ in "com.apple.Safari" }, exit: "us@1", server: nil)
        }
        let first = ledger.apply([ev("a", site: "netflix.com"), ev("b", site: nil)], reset: false, open: open)
        XCTAssertEqual(first.counted.map(\.app), ["site:netflix.com", "com.apple.Safari"])
        // Later updates keep the key fixed when it was first seen, even without a site on them.
        let later = ledger.apply([ev("a", site: nil, total: nil, kind: .update)], reset: false, open: open)
        XCTAssertEqual(later.counted, [Ledger.Counted(app: "site:netflix.com", exit: "us@1", server: nil, up: 1, down: 2, kind: .update)])

        var p = Pending()
        for c in first.counted + later.counted { p.add(now: 1_000_000, app: c.app, exit: c.exit, server: c.server, up: c.up, down: c.down) }
        XCTAssertEqual(Set(p.daily.keys.map(\.app)), ["site:netflix.com", "com.apple.Safari"])
        XCTAssertEqual(p.daily.first { $0.key.app == "site:netflix.com" }?.value, Pending.Sum(up: 11, down: 22))

        // Read back: the website keeps its key through the tools merge, and its share of the route's lane.
        let rows = [AppBytes(app: "site:netflix.com", exit: "us@1", bytes: 33), AppBytes(app: "~/bin/tool", exit: "us@1", bytes: 5),
                    AppBytes(app: "/Users/me/bin/tool", exit: "us@1", bytes: 5)]
        let merged = StatsMath.sameTools(rows, home: "/Users/me")
        XCTAssertEqual(merged.first { $0.app.hasPrefix("site:") }, rows[0])
        XCTAssertEqual(merged.count, 2)
        let source = StatsSource(exits: { [:] }, perDay: { _, _ in [:] }, perHour: { _ in [:] }, apps: { _, _ in rows }, peaks: { _, _ in [] },
                                 tests: { [] }, spans: { _, _ in [] })
        let v = StatsMath.view(.week, now: Date(timeIntervalSince1970: 1_800_000_000), homeFolder: "/Users/me", setup: Setup(), source: source)
        XCTAssertEqual(v.appLane("us@1").top.first, rows[0])
    }

    func testWebsiteTotalsComeFromTheSameSumsAsApps() {
        let totals = ["site:netflix.com": 40, "site:example.org": 2, "com.apple.Safari": 900, "/usr/bin/curl": 1, "?": 3] as [String: Int64]
        XCTAssertEqual(StatsMath.siteTotals(totals), ["netflix.com": 40, "example.org": 2])
        XCTAssertEqual(StatsMath.siteTotals([:]), [:])
    }
}
