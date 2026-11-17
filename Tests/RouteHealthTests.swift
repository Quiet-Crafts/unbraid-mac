import XCTest

final class RouteHealthTests: XCTestCase {
    private let home: Route = {
        var r = Route(id: "home")
        r.wg = WgPeer(name: "Home server", privateKey: "a", address: ["10.0.0.2/32"], publicKey: "b", endpoint: "192.0.2.10:51820", allowedIps: ["0.0.0.0/0"])
        return r
    }()
    private let pinned: Route = {
        var r = Route(id: "nl", loc: Location(provider: "mullvad", countryCode: "NL", country: "Netherlands"))
        r.loc.pinned = Server(name: "nl-ams-wg-001", host: "", ip: "", publicKey: "", load: -1)
        return r
    }()

    /// Nothing is known while not connected; a blocked route stays blocked, whether or not it is also silent.
    func testHealthOnlyWhileConnectedAndBlockedComesFirst() {
        for phase in [Snapshot.Phase.off, .connecting, .paused] {
            XCTAssertNil(RouteHealth("home", phase: phase, silent: ["home"], blocked: [:]))
        }
        XCTAssertEqual(RouteHealth("home", phase: .on, silent: ["home"], blocked: [:]), .silent)
        XCTAssertEqual(RouteHealth("home", phase: .on, silent: ["home"], blocked: ["home": "No server"]), .blocked)
        XCTAssertEqual(RouteHealth("home", phase: .on, silent: ["other"], blocked: [:]), .ok)
    }

    /// The card's text counts what can't connect, and says why the route stays where it is.
    func testExplanationCountsAndReason() {
        XCTAssertEqual(RouteHealth.explanation(home, apps: 3, sites: 1),
                       "Its 3 apps and 1 website can't connect until it answers again. unbraid can't tell whether the server or this network is the cause. unbraid keeps checking. It never moves your own server's route somewhere else.")
        XCTAssertEqual(RouteHealth.explanation(home, apps: 1, sites: 0),
                       "Its 1 app can't connect until it answers again. unbraid can't tell whether the server or this network is the cause. unbraid keeps checking. It never moves your own server's route somewhere else.")
        XCTAssertEqual(RouteHealth.explanation(pinned, apps: 0, sites: 2),
                       "Its 2 websites can't connect until it answers again. unbraid can't tell whether the server or this network is the cause. unbraid keeps checking. To use another server, click the pin at the top of its page (Change Location…).")
        XCTAssertEqual(RouteHealth.explanation(pinned, apps: 0, sites: 0),
                       "Nothing can connect through it until it answers again. unbraid can't tell whether the server or this network is the cause. unbraid keeps checking. To use another server, click the pin at the top of its page (Change Location…).")
        XCTAssertFalse(RouteHealth.explanation(nil, apps: 0, sites: 0).contains("Change Location"))
        // Another route answering meanwhile: the network reaches the internet, so the server's side is the likelier.
        XCTAssertEqual(RouteHealth.explanation(home, apps: 1, sites: 0, othersAnswer: true),
                       "Its 1 app can't connect until it answers again. Your other routes answer, so the trouble is at the server or its own connection. unbraid keeps checking. It never moves your own server's route somewhere else.")
    }

    /// The switch is offered for an own server, not for a provider route or a Tailscale exit; it shows what is checked.
    func testInternetCheckIsOfferedForOwnServersOnly() {
        XCTAssertTrue(RouteHealth.offersInternetCheck(home))
        XCTAssertFalse(RouteHealth.offersInternetCheck(pinned))
        var ts = Route(id: "ts")
        ts.tsExit = "100.64.0.1"
        XCTAssertFalse(RouteHealth.offersInternetCheck(ts))
        var off = home
        XCTAssertTrue(off.checksInternet, "a config that carries all traffic is checked by default")
        off.checkInternet = false
        XCTAssertFalse(off.checksInternet)
        var homeOnly = home
        homeOnly.wg?.allowedIps = ["192.168.1.0/24"]
        XCTAssertFalse(homeOnly.checksInternet)
        homeOnly.checkInternet = true
        XCTAssertTrue(homeOnly.checksInternet, "an explicit choice wins over the config")
    }

    /// The words say what the checks do: about once a minute, and a server that may be fine behind a network that isn't.
    func testTheWordsMatchTheChecks() {
        XCTAssertTrue(RouteHealth.checkCaption.hasPrefix("Tests about once a minute"))
        XCTAssertGreaterThanOrEqual(HealthSchedule.every.lowerBound, 40)
        XCTAssertLessThanOrEqual(HealthSchedule.every.upperBound, 90)
        XCTAssertFalse(RouteHealth.title.contains("network"), "the network isn't blamed when it may be the server")
    }
}
