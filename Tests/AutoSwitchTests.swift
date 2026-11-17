import XCTest

/// Switching profile by network: which network this is, what is remembered, and when a switch is made.
final class AutoSwitchTests: XCTestCase {
    private var setup: Setup {
        var s = Setup(routes: [Route(id: "nl", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands")),
                               Route(id: "us", loc: Location(countryId: 228, countryCode: "US", country: "United States"))],
                      defaultRoute: "nl", apps: [:])
        s.saveAs("Home")
        s.saveAs("Travel")
        s.defaultRoute = "us"
        s.use("Home")
        return s
    }

    private var rules: NetworkRules {
        var r = NetworkRules(salt: "salt")
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        r.remember("home-mark", name: "Home network", profile: "Home", now: day)
        r.remember("office-mark", name: "Office", profile: nil, now: day)
        r.elsewhere = "Travel"
        return r
    }

    func testAFingerprintIsStableAndMeansNothingElsewhere() {
        let a = NetworkMark.mark(salt: "one", gateway: "192.0.2.1", hardware: "00:11:22:33:44:55")
        XCTAssertEqual(a, NetworkMark.mark(salt: "one", gateway: "192.0.2.1", hardware: "00:11:22:33:44:55"))
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, NetworkMark.mark(salt: "two", gateway: "192.0.2.1", hardware: "00:11:22:33:44:55"))
        XCTAssertNotEqual(a, NetworkMark.mark(salt: "one", gateway: "192.0.2.2", hardware: "00:11:22:33:44:55"))
        XCTAssertNotEqual(a, NetworkMark.mark(salt: "one", gateway: "192.0.2.1", hardware: "00:11:22:33:44:56"))
        XCTAssertFalse(a.contains("192") || a.contains("44:55"))
    }

    func testAHardwareAddressIsReadFromArpsLine() {
        XCTAssertEqual(NetworkMark.parseArp("? (192.0.2.1) at 0:1b:c:dd:Ee:ff on en0 ifscope [ethernet]\n"), "00:1b:0c:dd:ee:ff")
        XCTAssertEqual(NetworkMark.parseArp("router.example (192.0.2.1) at a4:91:b1:00:00:01 on en0 ifscope [ethernet]"), "a4:91:b1:00:00:01")
        for none in ["? (192.0.2.1) at (incomplete) on en0 ifscope [ethernet]", "192.0.2.1 (192.0.2.1) -- no entry", "", "? (192.0.2.1) at 0:0:0:0:0:0 on en0",
                     "? (192.0.2.1) at ff:ff:ff:ff:ff:ff on en0", "? (192.0.2.1) at 1:2:3:4:5 on en0", "? (192.0.2.1) at 1:2:3:4:5:zz on en0", "? (192.0.2.1) at 111:2:3:4:5:6 on en0"] {
            XCTAssertNil(NetworkMark.parseArp(none), none)
        }
    }

    func testTheRouterIsTheDefaultRoutesOnThePreferredInterface() {
        let routes = [(interface: "en7", destination: "0.0.0.0", gateway: "198.51.100.1"), (interface: "en0", destination: "10.8.0.0", gateway: "192.0.2.9"),
                      (interface: "en0", destination: "0.0.0.0", gateway: "192.0.2.1")]
        XCTAssertEqual(NetworkMark.gateway(on: "en0", routes: routes), "192.0.2.1")
        XCTAssertEqual(NetworkMark.gateway(on: "en7", routes: routes), "198.51.100.1")
        XCTAssertNil(NetworkMark.gateway(on: "utun6", routes: routes))
        // Whatever the kernel hands back is read within its own lengths, and garbage reads as nothing.
        XCTAssertTrue(NetworkMark.parse([]).isEmpty)
        XCTAssertTrue(NetworkMark.parse([UInt8](repeating: 0xff, count: 300)).isEmpty)
        XCTAssertTrue(NetworkMark.parse([UInt8](repeating: 0, count: 300)).isEmpty)
        // This Mac's own table reads without a crash; on a network it has a default route.
        _ = NetworkMark.routes()
    }

    func testRulesFollowTheirProfilesAndNetworks() {
        var r = rules
        XCTAssertEqual(r.profile(on: "home-mark"), "Home")
        XCTAssertNil(r.profile(on: "office-mark"), "remembered with no profile: don't switch here")
        XCTAssertEqual(r.profile(on: "cafe-mark"), "Travel")
        XCTAssertFalse(r.remember("home-mark", name: "Again", profile: nil), "already remembered")
        XCTAssertFalse(r.remember("x", name: "home NETWORK", profile: nil), "name taken, whatever the capitals")
        XCTAssertFalse(r.remember("x", name: "  ", profile: nil))
        XCTAssertFalse(r.remember("x", name: String(repeating: "n", count: 25), profile: nil))
        XCTAssertTrue(r.remember("x", name: " Caf\u{202E}é ", profile: "Travel"))
        XCTAssertEqual(r.known.last?.name, "Café")
        r.renamed("Travel", to: "Trip")
        XCTAssertEqual(r.elsewhere, "Trip")
        XCTAssertEqual(r.profile(on: "x"), "Trip")
        r.deleted("Home")
        XCTAssertNil(r.profile(on: "home-mark"))
        XCTAssertEqual(r.known.count, 3, "the network stays remembered")
        r.tidy(profiles: ["Other"])
        XCTAssertNil(r.elsewhere)
        XCTAssertTrue(r.isEmpty)
        r.forget(network: "x")
        XCTAssertEqual(r.known.map(\.id), ["home-mark", "office-mark"])
        var full = NetworkRules()
        for i in 0..<30 { full.remember("m\(i)", name: "n\(i)", profile: nil) }
        XCTAssertEqual(full.known.count, NetworkRules.max)
        // Saved and read back the same.
        XCTAssertEqual(try JSONDecoder().decode(NetworkRules.self, from: JSONEncoder().encode(rules)), rules)
    }

    func testASwitchIsMadeOnlyWhenTheNetworkOrTheRulesChanged() {
        let s = setup, r = rules
        XCTAssertEqual(s.profile, "Home")
        let never: (Setup) -> Bool = { _ in false }
        // On the home network with Home in use: nothing. Elsewhere: Travel.
        XCTAssertEqual(AutoSwitch.decide(s, rules: r, mark: "home-mark", acted: nil, over: never), .none)
        XCTAssertEqual(AutoSwitch.decide(s, rules: r, mark: "cafe-mark", acted: nil, over: never), .to("Travel"))
        // Remembered with no profile: nothing.
        XCTAssertEqual(AutoSwitch.decide(s, rules: r, mark: "office-mark", acted: nil, over: never), .none)
        // Already decided on this network with these rules (the user picked Home by hand since): it stays.
        let acted = AutoSwitch.Acted(mark: "cafe-mark", rules: r)
        XCTAssertEqual(AutoSwitch.decide(s, rules: r, mark: "cafe-mark", acted: acted, over: never), .none)
        // Another network, or changed rules, decide again.
        XCTAssertEqual(AutoSwitch.decide(s, rules: r, mark: "hotel-mark", acted: acted, over: never), .to("Travel"))
        var changed = r
        changed.known[1].profile = "Travel"
        XCTAssertEqual(AutoSwitch.decide(s, rules: changed, mark: "cafe-mark", acted: acted, over: never), .to("Travel"))
    }

    func testASwitchThatCantBeMadeSaysWhyOrDoesNothing() {
        let r = rules
        let never: (Setup) -> Bool = { _ in false }
        // Over a provider's limit: said, not done.
        guard case .blocked(let why) = AutoSwitch.decide(setup, rules: r, mark: "cafe-mark", acted: nil, over: { _ in true }) else { return XCTFail("expected blocked") }
        XCTAssertTrue(why.contains("Travel") && why.contains("more connections"))
        // The profile was deleted, or its default route is gone: nothing.
        var gone = setup
        gone.forget("Travel")
        XCTAssertEqual(AutoSwitch.decide(gone, rules: r, mark: "cafe-mark", acted: nil, over: never), .none)
        var broken = setup
        broken.profiles[broken.profiles.firstIndex { $0.name == "Travel" }!].defaultRoute = "missing"
        XCTAssertEqual(AutoSwitch.decide(broken, rules: r, mark: "cafe-mark", acted: nil, over: never), .none)
        // A setup that is no profile is never replaced by itself.
        var loose = setup
        loose.profile = nil
        guard case .blocked(let unsaved) = AutoSwitch.decide(loose, rules: r, mark: "cafe-mark", acted: nil, over: never) else { return XCTFail("expected blocked") }
        XCTAssertTrue(unsaved.contains("isn't saved as a profile"))
        // What `over` is asked about is the setup as it would be after the switch.
        var asked: Setup?
        _ = AutoSwitch.decide(setup, rules: r, mark: "cafe-mark", acted: nil, over: { asked = $0; return false })
        XCTAssertEqual(asked?.profile, "Travel")
        XCTAssertEqual(asked?.defaultRoute, "us")
    }
}
