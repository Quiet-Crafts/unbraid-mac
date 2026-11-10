import XCTest

/// Signing out of one provider keeps the setup; what still counts as something to route through.
final class SetupSignOutTests: XCTestCase {
    private typealias F = ProviderFixtures

    private var wg: WgPeer { WgPeer(name: "Home", privateKey: F.priv, address: ["10.7.0.2/32"], publicKey: F.key, endpoint: "203.0.113.70:51820", allowedIps: ["192.168.1.0/24"]) }
    private func provider(_ id: String) -> Route { Route(id: id, loc: Location(provider: "nord", countryCode: "NL", country: "Netherlands")) }

    func testWhatCountsAsSomethingToRouteThrough() {
        // Signed out of the only provider: its routes and app choices stay, but nothing can carry traffic.
        let kept = Setup(routes: [provider("main")], defaultRoute: "main", apps: ["com.a": "main"])
        XCTAssertFalse(kept.hasExit(signedIn: false))
        XCTAssertTrue(kept.hasExit(signedIn: true))
        var home = kept; home.home.wg = wg
        XCTAssertTrue(home.hasExit(signedIn: false), "the Home WireGuard keeps the app set up")
        var ts = kept; ts.home.tailscale = true
        XCTAssertTrue(ts.hasExit(signedIn: false))
        var saved = kept; saved.servers = [OwnServer(id: "s1", wg: wg)]
        XCTAssertTrue(saved.hasExit(signedIn: false))
        var imported = kept; imported.routes.append(Route(id: "w", wg: wg))
        XCTAssertTrue(imported.hasExit(signedIn: false))
        XCTAssertFalse(Setup(routes: [], defaultRoute: DIRECT).hasExit(signedIn: false))
    }

    func testTailscaleSignOutDropsOnlyItsRoutesAndKey() {
        var s = Setup(routes: [provider("main"), Route(id: "t", tsExit: "100.64.0.9", tsName: "exit")], defaultRoute: "t",
                      apps: ["com.a": "t", "com.b": "main", "com.c": DIRECT])
        s.home.tailscale = true; s.home.tsAuthKey = "tskey-auth-x"; s.home.tsControlUrl = "https://hs.example"; s.home.wg = wg
        s.home.tsEnrolled = "id"
        s.dropTailscale()
        XCTAssertEqual(s.routes.map(\.id), ["main"])
        XCTAssertEqual(s.defaultRoute, "main")
        XCTAssertEqual(s.apps, ["com.b": "main", "com.c": DIRECT])
        XCTAssertFalse(s.home.tailscale); XCTAssertNil(s.home.tsAuthKey); XCTAssertNil(s.home.tsEnrolled)
        XCTAssertEqual(s.home.wg, wg, "the Home WireGuard isn't Tailscale's")
        var only = Setup(routes: [Route(id: "t", tsExit: "100.64.0.9")], defaultRoute: "t")
        only.dropTailscale()
        XCTAssertEqual(only.defaultRoute, DIRECT)
    }

    func testImportAfterKeptSignOutTakesOver() {
        // Signing out of the only provider keeps its routes; the next import prunes them and becomes the default.
        var s = Setup(routes: [provider("main")], defaultRoute: "main", apps: ["com.a": "main", "com.b": DIRECT])
        s.addImported("", id: "r1", signedIn: []) { $0.wg = self.wg }
        XCTAssertEqual(s.defaultRoute, "r1")
        XCTAssertEqual(s.apps, ["com.b": DIRECT])
    }

    /// An exit route no app uses still means a node in a tailnet: logged out with the rest, though the engine doesn't run it.
    func testTailscaleCountsAsSetUpWithAnUnusedExitRoute() {
        var s = Setup(routes: [Route(id: "main", loc: Location(provider: "mullvad")), Route(id: "ts", tsExit: "100.64.0.9")], defaultRoute: "main")
        XCTAssertFalse(s.tailscale)
        XCTAssertTrue(s.tailscaleConfigured)
        s.dropTailscale()
        XCTAssertFalse(s.tailscaleConfigured)
        var home = Setup(); home.home.tailscale = true
        XCTAssertTrue(home.tailscaleConfigured)
        XCTAssertFalse(Setup().tailscaleConfigured)
    }
}
