import XCTest

/// Importing a server into a setup: when nothing could carry traffic before, the import becomes the default.
final class SetupImportTests: XCTestCase {
    private typealias F = ProviderFixtures

    private var wg: WgPeer { WgPeer(name: "Home box", privateKey: F.priv, address: ["10.7.0.2/32"], publicKey: F.key, endpoint: "203.0.113.70:51820", allowedIps: ["0.0.0.0/0"]) }
    private var ss: SsProfile { SsProfile(name: "Outline", server: "203.0.113.71", port: 8388, method: "chacha20-ietf-poly1305", password: "pw") }
    private func ovpn() throws -> OvpnProfile { try Manual.parseOvpn(Fixture.text("ovpn/selfhosted.ovpn"), name: "Office", username: "u", password: "p") }

    /// What Sign Out of Everything, or removing the last server, leaves.
    private var reset: Setup { Setup(routes: [], defaultRoute: DIRECT) }

    private func provider(_ id: String, _ p: String = "nord") -> Route { Route(id: id, loc: Location(provider: p, countryCode: "NL", country: "Netherlands")) }

    /// The setup's compiled default: the tag `route.final` points at.
    private func final(_ s: Setup) async throws -> String {
        let links = try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:], accounts: [:], last: [:]) { _ in nil }.links
        let config = try Compiler.compile(Compiler.Input(setup: s, links: links, apps: [:], selfPattern: Compiler.pattern(forPath: "/Applications/unbraid.app")))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        return try XCTUnwrap((json["route"] as? [String: Any])?["final"] as? String)
    }

    func testImportAfterSignOutOfEverythingBecomesTheDefault() async throws {
        for source: (inout Route) -> Void in [{ $0.wg = self.wg }, { $0.ss = self.ss }] {
            var s = reset
            let id = s.addImported("", id: "r1", signedIn: [], source)
            XCTAssertEqual(id, "r1")
            XCTAssertEqual(s.defaultRoute, "r1")
            XCTAssertEqual(s.activeRoutes.map(\.id), ["r1"])
            let tag = try await final(s)
            let links = try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:], accounts: [:], last: [:]) { _ in nil }.links
            XCTAssertEqual(tag, try Compiler.shared(s, links)["r1"])
            XCTAssertNotEqual(tag, "direct")
        }
    }

    func testOpenVpnAndTailscaleImportsBecomeTheDefaultToo() async throws {
        let profile = try ovpn()
        var s = reset
        s.addImported("", id: "r1", signedIn: []) { $0.ovpn = profile }
        XCTAssertEqual(s.defaultRoute, "r1")
        let links = try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:], accounts: [:], last: [:]) { _ in nil }.links
        let ovpnFinal = try await final(s)
        XCTAssertEqual(ovpnFinal, try Compiler.shared(s, links)["r1"])
        var t = reset
        t.addImported("", id: "r2", signedIn: []) { $0.tsExit = "100.64.0.9"; $0.tsName = "exit" }
        XCTAssertEqual(t.defaultRoute, "r2")
        let tsFinal = try await final(t)
        XCTAssertEqual(tsFinal, Compiler.tsTag)
    }

    /// Use Tailscale Only (or a Home WireGuard) with Direct as the default is a working setup: an exit node or server
    /// added there is an option, not the new default.
    func testTailscaleOrHomeOnlySetupsKeepTheirDirectDefault() {
        var t = reset
        t.home.tailscale = true
        t.addImported("", id: "r2", signedIn: []) { $0.tsExit = "100.64.0.9"; $0.tsName = "exit" }
        XCTAssertEqual(t.defaultRoute, DIRECT)
        XCTAssertEqual(t.routes.map(\.id), ["r2"])
        var h = reset
        h.home.wg = wg
        h.addImported("", id: "r3", signedIn: []) { $0.ss = self.ss }
        XCTAssertEqual(h.defaultRoute, DIRECT)
    }

    func testFreshInstallPlaceholderGoes() async throws {
        var s = Setup()
        s.addImported("", id: "r1", signedIn: []) { $0.wg = self.wg }
        XCTAssertEqual(s.routes.map(\.id), ["r1"])
        XCTAssertEqual(s.defaultRoute, "r1")
        let tag = try await final(s)
        XCTAssertEqual(tag, "r-r1")
    }

    func testStaleProviderRoutesGoAndTheirAppsFollowTheImport() async throws {
        // Signed out of the provider: its routes stay but can't connect.
        var s = Setup(routes: [provider("main"), provider("us")], defaultRoute: DIRECT, apps: ["com.a": "us", "com.b": DIRECT])
        s.addImported("", id: "r1", signedIn: []) { $0.wg = self.wg }
        XCTAssertEqual(s.routes.map(\.id), ["r1"])
        XCTAssertEqual(s.defaultRoute, "r1")
        XCTAssertEqual(s.apps, ["com.b": DIRECT])
        let tag = try await final(s)
        XCTAssertEqual(tag, "r-r1")
    }

    func testEstablishedDirectDefaultIsKept() {
        // An imported route already carries one app; Direct is the user's own choice of default.
        var s = Setup(routes: [Route(id: "w", wg: wg)], defaultRoute: DIRECT, apps: ["com.a": "w"])
        s.addImported("", id: "r1", signedIn: []) { $0.ss = self.ss }
        XCTAssertEqual(s.defaultRoute, DIRECT)
        XCTAssertEqual(s.routes.map(\.id), ["w", "r1"])
        // Same with a signed-in provider's route.
        var p = Setup(routes: [provider("main")], defaultRoute: DIRECT, apps: ["com.a": "main"])
        p.addImported("", id: "r1", signedIn: ["nord"]) { $0.wg = self.wg }
        XCTAssertEqual(p.defaultRoute, DIRECT)
        XCTAssertEqual(p.routes.map(\.id), ["main", "r1"])
        XCTAssertEqual(p.apps, ["com.a": "main"])
    }

    func testEstablishedProviderDefaultIsKept() {
        var s = Setup(routes: [provider("main")], defaultRoute: "main")
        s.addImported("", id: "r1", signedIn: ["nord"]) { $0.wg = self.wg }
        XCTAssertEqual(s.defaultRoute, "main")
    }

    func testImportForOneAppMovesOnlyThatApp() async throws {
        var s = reset
        s.apps = ["com.x": DIRECT]
        let id = s.addImported("app:com.a", id: "r1", signedIn: []) { $0.wg = self.wg }
        XCTAssertEqual(s.defaultRoute, DIRECT)
        XCTAssertEqual(s.apps, ["com.a": id, "com.x": DIRECT])
        // On a setup whose default is still a dead placeholder, the import takes its place and the app is put on it.
        var fresh = Setup()
        fresh.addImported("app:com.a", id: "r1", signedIn: []) { $0.wg = self.wg }
        XCTAssertEqual(fresh.defaultRoute, "r1")
        XCTAssertEqual(fresh.apps["com.a"], "r1")
    }

    func testReplacingARouteSourceKeepsItsIdAndHue() {
        var s = Setup(routes: [Route(id: "w", wg: wg, hue: 4), Route(id: "x", ss: ss, hue: 1)], defaultRoute: "w", apps: ["com.a": "x"])
        let id = s.addImported("x", id: "unused", signedIn: []) { $0.wg = self.wg }
        XCTAssertEqual(id, "x")
        XCTAssertEqual(s.route("x")?.hue, 1)
        XCTAssertNil(s.route("x")?.ss)
        XCTAssertEqual(s.defaultRoute, "w")
        XCTAssertEqual(s.apps, ["com.a": "x"])
        // A dead placeholder given a source on an empty setup becomes the default; its apps keep it.
        var dead = Setup(routes: [provider("main")], defaultRoute: DIRECT, apps: ["com.b": "main"])
        dead.addImported("main", id: "unused", signedIn: []) { $0.wg = self.wg }
        XCTAssertEqual(dead.defaultRoute, "main")
        XCTAssertEqual(dead.apps, ["com.b": "main"])
    }

    func testNewRoutesGetUnusedHues() {
        var s = Setup(routes: [Route(id: "a", wg: wg, hue: 0), Route(id: "b", wg: wg, hue: 1)], defaultRoute: "a")
        s.addImported("", id: "r1", signedIn: []) { $0.ss = self.ss }
        XCTAssertEqual(s.route("r1")?.hue, 2)
    }

    private var proxy: Socks5Profile { Socks5Profile(name: "Office", host: "proxy.example.net", port: 1080, username: "bob", item: "6F1B5D2E-2C4A-4F8E-9B1D-3A7C5E9F0B12") }

    func testProxyServersAreListedOnceAndAUseReplacesARoutesSource() {
        let p = proxy
        var s = Setup(routes: [Route(id: "r1", wg: wg, hue: 3, own: "s1")], defaultRoute: "r1")
        XCTAssertEqual(s.useProxy("r1", p, id: "r9", signedIn: []), "r1")
        let r = s.route("r1")
        XCTAssertEqual(r?.socks5, p)
        XCTAssertNil(r?.wg)
        XCTAssertNil(r?.own, "the route no longer copies the saved server")
        XCTAssertEqual(r?.hue, 3)
        XCTAssertEqual(s.useProxy("app:com.example.mail", p, id: "r2", signedIn: []), "r2")
        XCTAssertEqual(s.apps["com.example.mail"], "r2")
        XCTAssertEqual(s.defaultRoute, "r1")
        XCTAssertEqual(s.proxyServers, [p], "two routes through one proxy share its keychain item and list it once")
    }

    func testAProxyAddedFromSettingsNeverBecomesTheDefaultByItself() {
        var s = reset
        XCTAssertEqual(s.useProxy("", proxy, id: "r1", signedIn: [], keepDefault: true), "r1")
        XCTAssertEqual(s.defaultRoute, DIRECT)
        var kept = Setup(routes: [Route(id: "r0", wg: wg)], defaultRoute: "r0")
        kept.useProxy("", proxy, id: "r1", signedIn: [], keepDefault: true)
        XCTAssertEqual(kept.defaultRoute, "r0")
    }

    func testAProxyServerIsListedAsItsNamePlusSocks5HostAndPort() {
        var s = reset
        s.useProxy("", proxy, id: "r1", signedIn: [])
        var v6 = proxy
        (v6.name, v6.host, v6.port, v6.item) = ("Proxy on this Mac", "::1", 9050, "0C6A2B1E-7D3F-4E5A-8B9C-1D2E3F4A5B6C")
        s.useProxy("", v6, id: "r2", signedIn: [])
        XCTAssertEqual(s.proxyServers.map { "\($0.name) | \($0.caption)" },
                       ["Office | SOCKS5 · proxy.example.net:1080", "Proxy on this Mac | SOCKS5 · [::1]:9050"])
    }

    private var local: Socks5Profile { Socks5Profile(name: "Proxy on this Mac", host: "127.0.0.1", port: 1080, item: "0C6A2B1E-7D3F-4E5A-8B9C-1D2E3F4A5B6C") }

    func testMakingALocalProxyTheDefaultFirstAsksWhichAppRunsIt() {
        var s = Setup(routes: [Route(id: "r0", wg: wg)], defaultRoute: "r0")
        s.useProxy("", local, id: "r1", signedIn: [])
        s.useProxy("", proxy, id: "r2", signedIn: [])
        XCTAssertTrue(s.asksProxyApp("r1"))
        XCTAssertFalse(s.asksProxyApp("r2"), "a proxy elsewhere doesn't run on this Mac")
        XCTAssertFalse(s.asksProxyApp("r0"))
        s.setProxyApp("r1", "com.example.proxy", makeDefault: true)
        XCTAssertEqual(s.route("r1")?.socks5?.proxyApp, "com.example.proxy")
        XCTAssertEqual(s.defaultRoute, "r1")
        XCTAssertFalse(s.asksProxyApp("r1"), "asked once: Change Proxy App changes it later")
        s.setProxyApp("r1", "/usr/local/bin/microsocks", makeDefault: false)
        XCTAssertEqual(s.route("r1")?.socks5?.proxyApp, "/usr/local/bin/microsocks")
        let before = s
        s.setProxyApp("r0", "com.example.proxy", makeDefault: true)
        XCTAssertEqual(s, before, "only a proxy route takes a proxy app")
    }

    func testAProxyInMyServersIsWordedAndManagedAsTheOtherServers() {
        var s = Setup(routes: [Route(id: "r0", wg: wg)], defaultRoute: "r0")
        s.useProxy("", local, id: "r1", signedIn: [])
        XCTAssertEqual(s.proxyUse(local), "SOCKS5 · 127.0.0.1:1080 · used by 1 route")
        s.useProxy("app:com.example.mail", local, id: "r2", signedIn: [])
        XCTAssertEqual(s.proxyUse(local), "SOCKS5 · 127.0.0.1:1080 · used by 2 routes")
        XCTAssertEqual(Setup().proxyUse(local), "SOCKS5 · 127.0.0.1:1080 · not in use")
        s.renameProxy(local.item, "  Home proxy  ")
        XCTAssertEqual(s.proxyRoutes(local.item).map(\.name), ["Home proxy", "Home proxy"])
        s.renameProxy(local.item, " ")
        XCTAssertEqual(s.route("r1")?.name, "Home proxy", "an empty name is ignored")
        s.removeProxy(local.item)
        XCTAssertEqual(s.routes.map(\.id), ["r0"])
        XCTAssertNil(s.apps["com.example.mail"], "its apps follow the default")
        XCTAssertEqual(s.defaultRoute, "r0")
    }

    func testARouteHeaderNamesAnOwnServersKindWithoutAPlace() {
        XCTAssertEqual(Route(id: "p", socks5: local).ownPlace, "SOCKS5")
        XCTAssertEqual(Route(id: "w", wg: wg).ownPlace, "WireGuard")
        XCTAssertNil(provider("n").ownPlace, "a provider route shows its city or Fastest")
    }

    /// A provider route's server line: NordVPN's host code, another provider's server name (never its host's first part),
    /// and the load, 0% included, only where the provider publishes one.
    func testAProviderRoutesServerLineNamesItsServerAndLoad() {
        let nord = Server(name: "Netherlands #1256", host: "nl1256.nordvpn.com", ip: "203.0.113.80", publicKey: "", load: 9)
        XCTAssertEqual(provider("n").serverLine(nord), "nl1256 · 9% load")
        var idle = nord; idle.load = 0
        XCTAssertEqual(provider("n").serverLine(idle), "nl1256 · 0% load")
        var unknown = nord; unknown.load = -1
        XCTAssertEqual(provider("n").serverLine(unknown), "nl1256")
        XCTAssertEqual(provider("i", "ivpn").serverLine(Server(name: "nl-ams-wg-1", host: "gw7.ams.example", ip: "", publicKey: "", load: 30)), "nl-ams-wg-1 · 30% load")
        XCTAssertEqual(provider("m", "mullvad").serverLine(Server(name: "se-got-wg-001", host: "relay12.got.example", ip: "", publicKey: "", load: 12)), "se-got-wg-001")
    }

    /// Two provider routes of one name are told apart by their city, else their server group, else their provider.
    func testProviderRoutesOfOneNameAreToldApartByCityGroupOrProvider() {
        var city = provider("a"); city.loc.city = "Amsterdam"; city.loc.group = "legacy_p2p"
        XCTAssertEqual(city.nameDetail, "Amsterdam")
        var group = provider("b"); group.loc.group = "legacy_p2p"
        XCTAssertEqual(group.nameDetail, "legacy_p2p")
        XCTAssertEqual(provider("c").nameDetail, "NordVPN")
        XCTAssertEqual(provider("d", "mullvad").nameDetail, "Mullvad")
        XCTAssertNil(provider("e", "gone").nameDetail, "a provider this build doesn't know adds nothing")
    }

    /// An imported route has no provider's server code or load: its server line is the address it reaches (a proxy's
    /// host and port), nothing where that is its name already, never a load.
    func testAnImportedRouteShowsNoServerCodeOrLoad() throws {
        let server = { (host: String) in Server(name: "x", host: host, ip: host, publicKey: "", load: 5) }
        XCTAssertEqual(Route(id: "p", socks5: local).serverLine(server("127.0.0.1")), "127.0.0.1:1080")
        XCTAssertEqual(Route(id: "q", socks5: proxy).serverLine(server("proxy.example.net")), "proxy.example.net:1080")
        XCTAssertEqual(Route(id: "w", wg: wg).serverLine(server("alpha.example")), "alpha.example")
        XCTAssertEqual(Route(id: "w", wg: wg).serverLine(server("[2001:db8::1]")), "[2001:db8::1]")
        XCTAssertEqual(Route(id: "s", ss: ss).serverLine(server("2001:db8::2")), "[2001:db8::2]")
        XCTAssertEqual(Route(id: "t", tsExit: "100.64.0.1", tsName: "box").serverLine(server("100.64.0.1")), "100.64.0.1")
        XCTAssertEqual(Route(id: "t", tsExit: "100.64.0.1", tsName: "").serverLine(server("100.64.0.1")), "100.64.0.1", "a row with no name still says which exit")
        XCTAssertNil(Route(id: "t", tsExit: "100.64.0.1").serverLine(server("100.64.0.1")), "its name is its address already")
        let o = try ovpn()
        XCTAssertNil(Route(id: "o", ovpn: o).serverLine(Server(name: o.name, host: o.name, ip: "", publicKey: "", load: 0)), "an OpenVPN profile's server is its name")
        XCTAssertNil(Route(id: "w", wg: wg).serverLine(server("")))
    }

    /// Two imported routes of one name are told apart by what is true of them: the address they reach, or their kind
    /// where there is none to show; never by the provider a provider route would have.
    func testImportedRoutesOfOneNameAreToldApartByAddressOrKind() throws {
        XCTAssertEqual(Route(id: "p", socks5: local).nameDetail, "127.0.0.1:1080")
        var v6 = local; v6.host = "::1"; v6.port = 9050
        XCTAssertEqual(Route(id: "p", socks5: v6).nameDetail, "[::1]:9050")
        XCTAssertEqual(Route(id: "q", socks5: proxy).nameDetail, "proxy.example.net:1080")
        XCTAssertEqual(Route(id: "w", wg: wg).nameDetail, "203.0.113.70")
        var wg6 = wg; wg6.endpoint = "[2001:db8::1]:51820"
        XCTAssertEqual(Route(id: "w", wg: wg6).nameDetail, "[2001:db8::1]")
        XCTAssertEqual(Route(id: "s", ss: ss).nameDetail, "203.0.113.71")
        XCTAssertEqual(Route(id: "o", ovpn: try ovpn()).nameDetail, "OpenVPN")
        XCTAssertEqual(Route(id: "t", tsExit: "100.64.0.1", tsName: "box").nameDetail, "100.64.0.1")
        XCTAssertEqual(Route(id: "t", tsExit: "100.64.0.1").nameDetail, "Tailscale exit")
    }

    /// What menus call two routes of one name, as the sidebar, Move To and the menu bar show them.
    func testRoutesOfOneNameAreToldApartInEveryMenu() {
        var alpha = wg, beta = wg
        alpha.endpoint = "alpha.example:51820"; beta.endpoint = "beta.example:51820"
        var amsterdam = provider("n1"); amsterdam.loc.city = "Amsterdam"
        let s = Setup(routes: [Route(id: "w1", wg: alpha), Route(id: "w2", wg: beta), Route(id: "p1", socks5: local), Route(id: "p2", socks5: proxy),
                               provider("n0"), amsterdam, Route(id: "x1", ss: ss)], defaultRoute: DIRECT)
        XCTAssertEqual(s.label("w1"), "Home box · alpha.example")
        XCTAssertEqual(s.label("w2"), "Home box · beta.example")
        XCTAssertEqual(s.label("n0"), "Netherlands · NordVPN")
        XCTAssertEqual(s.label("n1"), "Netherlands · Amsterdam")
        XCTAssertEqual(s.label("p1"), "Proxy on this Mac", "a name of its own needs nothing more")
        XCTAssertEqual(s.label("x1"), "Outline")
        var two = s
        two.routes.append(Route(id: "p3", socks5: { var x = local; x.port = 1081; return x }()))
        XCTAssertEqual(two.label("p1"), "Proxy on this Mac · 127.0.0.1:1080")
        XCTAssertEqual(two.label("p3"), "Proxy on this Mac · 127.0.0.1:1081")
        XCTAssertEqual(s.label(DIRECT), "Direct")
        XCTAssertEqual(s.label(BLOCK), "Blocked")
        XCTAssertEqual(s.label("gone"), "Removed route")
    }

    func testRemovingTheDefaultNeverHandsItToALocalProxyWithoutItsApp() {
        let lp = Route(id: "r1", socks5: Socks5Profile(name: "Proxy on this Mac", host: "127.0.0.1", port: 1080, item: "0C6A2B1E-7D3F-4E5A-8B9C-1D2E3F4A5B6C"))
        var s = Setup(routes: [Route(id: "r0", wg: wg), lp, Route(id: "r2", wg: wg)], defaultRoute: "r0")
        s.removeRoute("r0")
        XCTAssertEqual(s.defaultRoute, "r2")
        s.removeRoute("r1"); s.routes.insert(lp, at: 0)
        s.removeRoute("r2")
        XCTAssertEqual(s.defaultRoute, DIRECT, "only the waiting proxy is left: Direct, not a default that carries nothing")
    }

    func testALocalProxyWithoutItsAppNeverBecomesTheDefaultByItself() {
        var s = reset
        s.useProxy("", local, id: "r1", signedIn: [])
        XCTAssertEqual(s.defaultRoute, DIRECT, "Make Default asks for its app first")
        var known = local
        known.proxyApp = "com.example.proxy"
        var t = reset
        t.useProxy("", known, id: "r1", signedIn: [])
        XCTAssertEqual(t.defaultRoute, "r1")
    }
}
