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
        // On a setup whose default is still a dead placeholder, the import takes its place and the app just follows it.
        var fresh = Setup()
        fresh.addImported("app:com.a", id: "r1", signedIn: []) { $0.wg = self.wg }
        XCTAssertEqual(fresh.defaultRoute, "r1")
        XCTAssertNil(fresh.apps["com.a"])
    }

    func testReplacingARouteSourceKeepsItsIdAndHue() {
        var s = Setup(routes: [Route(id: "w", wg: wg, hue: 4), Route(id: "x", ss: ss, hue: 1)], defaultRoute: "w", apps: ["com.a": "x"])
        let id = s.addImported("x", id: "unused", signedIn: []) { $0.wg = self.wg }
        XCTAssertEqual(id, "x")
        XCTAssertEqual(s.route("x")?.hue, 1)
        XCTAssertNil(s.route("x")?.ss)
        XCTAssertEqual(s.defaultRoute, "w")
        XCTAssertEqual(s.apps, ["com.a": "x"])
        // A dead placeholder given a source on an empty setup becomes the default; its apps then follow the default.
        var dead = Setup(routes: [provider("main")], defaultRoute: DIRECT, apps: ["com.b": "main"])
        dead.addImported("main", id: "unused", signedIn: []) { $0.wg = self.wg }
        XCTAssertEqual(dead.defaultRoute, "main")
        XCTAssertEqual(dead.apps, [:])
    }

    func testNewRoutesGetUnusedHues() {
        var s = Setup(routes: [Route(id: "a", wg: wg, hue: 0), Route(id: "b", wg: wg, hue: 1)], defaultRoute: "a")
        s.addImported("", id: "r1", signedIn: []) { $0.ss = self.ss }
        XCTAssertEqual(s.route("r1")?.hue, 2)
    }
}
