import Darwin
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
        let a = NetworkMark.mark(salt: "one", router: "v6 fe80000000000000021122fffe334455")
        XCTAssertEqual(a, NetworkMark.mark(salt: "one", router: "v6 fe80000000000000021122fffe334455"))
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, NetworkMark.mark(salt: "two", router: "v6 fe80000000000000021122fffe334455"))
        XCTAssertNotEqual(a, NetworkMark.mark(salt: "one", router: "v6 fe80000000000000021122fffe334456"))
        XCTAssertFalse(a.contains("fe80") || a.contains("334455"))
    }

    func testAHardwareAddressIsReadFromArpsLine() {
        XCTAssertEqual(NetworkMark.parseArp("? (192.0.2.1) at 0:1b:c:dd:Ee:ff on en0 ifscope [ethernet]\n"), "00:1b:0c:dd:ee:ff")
        XCTAssertEqual(NetworkMark.parseArp("router.example (192.0.2.1) at a4:91:b1:00:00:01 on en0 ifscope [ethernet]"), "a4:91:b1:00:00:01")
        for none in ["? (192.0.2.1) at (incomplete) on en0 ifscope [ethernet]", "192.0.2.1 (192.0.2.1) -- no entry", "", "? (192.0.2.1) at 0:0:0:0:0:0 on en0",
                     "? (192.0.2.1) at ff:ff:ff:ff:ff:ff on en0", "? (192.0.2.1) at 1:2:3:4:5 on en0", "? (192.0.2.1) at 1:2:3:4:5:zz on en0", "? (192.0.2.1) at 111:2:3:4:5:6 on en0"] {
            XCTAssertNil(NetworkMark.parseArp(none), none)
        }
        // An interface's whole table (what is read, since a lookup of one address goes into a running VPN's tunnel): the
        // router's own line, never a neighbour's whose address starts the same.
        let table = """
        ? (192.0.2.10) at 0:aa:bb:cc:dd:1 on en0 ifscope [ethernet]
        ? (192.0.2.7) at (incomplete) on en0 ifscope [ethernet]
        ? (192.0.2.1) at a4:91:b1:0:0:2 on en0 ifscope [ethernet]
        ? (192.0.2.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
        """
        XCTAssertEqual(NetworkMark.parseArp(table, for: "192.0.2.1"), "a4:91:b1:00:00:02")
        XCTAssertEqual(NetworkMark.parseArp(table, for: "192.0.2.10"), "00:aa:bb:cc:dd:01")
        XCTAssertNil(NetworkMark.parseArp(table, for: "192.0.2.7"))
        XCTAssertNil(NetworkMark.parseArp(table, for: "192.0.2.2"))
        XCTAssertNil(NetworkMark.parseArp(table, for: "192.0.2.255"))
    }

    func testTheRouterIsTheDefaultRoutesOnThePreferredInterface() {
        let routes = [(interface: "en7", destination: "0.0.0.0", gateway: "198.51.100.1"), (interface: "en0", destination: "10.8.0.0", gateway: "192.0.2.9"),
                      (interface: "en0", destination: "0.0.0.0", gateway: "192.0.2.1")]
        XCTAssertEqual(NetworkMark.gateway(on: "en0", routes: routes), "192.0.2.1")
        XCTAssertEqual(NetworkMark.gateway(on: "en7", routes: routes), "198.51.100.1")
        XCTAssertNil(NetworkMark.gateway(on: "utun6", routes: routes))
        // A message as the kernel writes it: header, destination (cut short, as the default route's is), gateway, mask.
        var h = rt_msghdr()
        h.rtm_version = UInt8(RTM_VERSION); h.rtm_type = UInt8(RTM_GET); h.rtm_flags = RTF_UP | RTF_GATEWAY
        h.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK; h.rtm_index = UInt16(if_nametoindex("lo0"))
        let gateway: [UInt8] = [16, UInt8(AF_INET), 0, 0, 192, 0, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0]
        let message = { (dst: [UInt8], mask: [UInt8]) -> [UInt8] in
            var m = h
            m.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + dst.count + gateway.count + mask.count)
            return withUnsafeBytes(of: m) { Array($0) } + dst + gateway + mask
        }
        let full = message([16, UInt8(AF_INET), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0])
        let short = message([0, 0, 0, 0], [0, 0, 0, 0])
        let host = message([16, UInt8(AF_INET), 0, 0, 10, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], [7, 0, 0, 0, 255, 255, 255, 0])
        for (buffer, to) in [(full, "0.0.0.0"), (short, "0.0.0.0"), (host, "10.8.0.0")] {
            let read = NetworkMark.parse(buffer)
            XCTAssertEqual(read.count, 1)
            XCTAssertEqual(read.first?.interface, "lo0")
            XCTAssertEqual(read.first?.destination, to)
            XCTAssertEqual(read.first?.gateway, "192.0.2.1")
        }
        // Two in a row, then one cut anywhere: what is whole is read, the rest dropped, never past the end.
        XCTAssertEqual(NetworkMark.parse(full + host).map(\.destination), ["0.0.0.0", "10.8.0.0"])
        for cut in 0..<host.count { XCTAssertEqual(NetworkMark.parse(full + Array(host.prefix(cut))).count, 1, "\(cut)") }
        var lying = full
        lying.withUnsafeMutableBytes { $0.storeBytes(of: UInt16(full.count + 40), toByteOffset: 0, as: UInt16.self) }
        XCTAssertTrue(NetworkMark.parse(lying).isEmpty)
        var huge = full
        huge[MemoryLayout<rt_msghdr>.size] = 255
        XCTAssertTrue(NetworkMark.parse(huge).isEmpty || NetworkMark.parse(huge).first?.gateway != "192.0.2.1")
        // Whatever the kernel hands back is read within its own lengths, and garbage reads as nothing.
        XCTAssertTrue(NetworkMark.parse([]).isEmpty)
        XCTAssertTrue(NetworkMark.parse([UInt8](repeating: 0xff, count: 300)).isEmpty)
        XCTAssertTrue(NetworkMark.parse([UInt8](repeating: 0, count: 300)).isEmpty)
        // This Mac's own table reads without a crash; on a network it has a default route.
        _ = NetworkMark.routes()
    }

    /// On a network with IPv6 the router is who the default route goes through, told by its own link-local address:
    /// read as the kernel writes it, whatever interface number it tucks in, and never one any router may have.
    func testTheIPv6RouterIsReadFromTheRoutingTable() {
        func in6(_ address: [UInt8]) -> [UInt8] { [28, UInt8(AF_INET6), 0, 0, 0, 0, 0, 0] + address + [0, 0, 0, 0] }
        func message(_ dst: [UInt8], _ gateway: [UInt8], flags: Int32 = RTF_UP | RTF_GATEWAY) -> [UInt8] {
            var h = rt_msghdr()
            h.rtm_version = UInt8(RTM_VERSION); h.rtm_type = UInt8(RTM_GET); h.rtm_flags = flags
            h.rtm_addrs = RTA_DST | RTA_GATEWAY; h.rtm_index = UInt16(if_nametoindex("lo0"))
            h.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + dst.count + gateway.count)
            return withUnsafeBytes(of: h) { Array($0) } + dst + gateway
        }
        let any = [UInt8](repeating: 0, count: 16)
        func router(_ scope: UInt8) -> [UInt8] { [0xfe, 0x80, 0, scope, 0, 0, 0, 0, 0x02, 0x11, 0x22, 0xff, 0xfe, 0x33, 0x44, 0x55] }
        let prefix: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let routes = NetworkMark.records(message(in6(prefix), in6(router(9))) + message(in6(any), in6(router(4))))
        XCTAssertEqual(routes.count, 2)
        let told = NetworkMark.routers6(on: "lo0", routes: routes)
        XCTAssertEqual(told, ["fe80000000000000021122fffe334455"])
        // The same router whatever number the kernel gave the interface.
        XCTAssertEqual(NetworkMark.routers6(on: "lo0", routes: NetworkMark.records(message(in6(any), in6(router(12))))), told)
        XCTAssertEqual(NetworkMark.routers6(on: "en9", routes: routes), [], "another interface's router is not this one's")
        // No default route, or a route that isn't through a router: nothing.
        XCTAssertEqual(NetworkMark.routers6(on: "lo0", routes: Array(routes.prefix(1))), [])
        XCTAssertEqual(NetworkMark.routers6(on: "lo0", routes: NetworkMark.records(message(in6(any), in6(router(4)), flags: RTF_UP))), [])
        // A router that calls itself "1" (or anything as short) is any router: no fingerprint. Nor is one named by a
        // global address, which is the provider's to change.
        for plain: [UInt8] in [[0xfe, 0x80, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1], [0xfe, 0x80, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1],
                               [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0x02, 0x11, 0x22, 0xff, 0xfe, 0x33, 0x44, 0x55], any] {
            XCTAssertEqual(NetworkMark.routers6(on: "lo0", routes: NetworkMark.records(message(in6(any), in6(plain)))), [])
        }
        // Several routers: each one that qualifies, sorted and once, whichever order the table lists them in; one that
        // calls itself "1" is left out.
        func other(_ last: UInt8) -> [UInt8] { [0xfe, 0x80, 0, 4, 0, 0, 0, 0, 0x02, 0x11, 0x22, 0xff, 0xfe, 0x33, 0x44, last] }
        let one: [UInt8] = [0xfe, 0x80, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        for order in [[other(0x66), router(4), one], [one, router(4), other(0x66), router(7)]] {
            XCTAssertEqual(NetworkMark.routers6(on: "lo0", routes: NetworkMark.records(order.flatMap { message(in6(any), in6($0)) })),
                           ["fe80000000000000021122fffe334455", "fe80000000000000021122fffe334466"])
        }
        XCTAssertEqual(NetworkMark.reading(["b", "a", "b"]), "a,b")
        XCTAssertEqual(NetworkMark.reading(["a"]), "a", "one router: its fingerprint, as networks remembered before")
        // A default route whose destination is cut short, as the kernel may write it.
        XCTAssertEqual(NetworkMark.routers6(on: "lo0", routes: NetworkMark.records(message([0, 0, 0, 0], in6(router(4))))), told)
        // This Mac's own table reads without a crash.
        _ = NetworkMark.routers6(on: "en0", routes: NetworkMark.table(AF_INET6, RTF_GATEWAY))
    }

    /// A network is its routers: remembered with all of them, recognised while every router seen is one of them.
    func testANetworkWithSeveralRoutersIsRecognisedByAllOfThem() {
        var r = NetworkRules(salt: "salt")
        r.elsewhere = "Travel"
        XCTAssertTrue(r.remember("a", name: "Flat", profile: "Flat"))
        XCTAssertTrue(r.remember(NetworkMark.reading(["c", "b"]), name: "Home network", profile: "Home"))
        // One router; two routers both there; one of the two away for now.
        XCTAssertEqual(r.profile(on: "a"), "Flat")
        XCTAssertEqual(r.profile(on: NetworkMark.reading(["b", "c"])), "Home")
        XCTAssertEqual(r.profile(on: "b"), "Home")
        XCTAssertEqual(r.profile(on: "c"), "Home")
        // A router home doesn't have beside one that looks like home's: another network, never home.
        XCTAssertNil(r.network(NetworkMark.reading(["b", "x"])))
        XCTAssertEqual(r.profile(on: NetworkMark.reading(["b", "x"])), "Travel")
        XCTAssertEqual(r.profile(on: NetworkMark.reading(["a", "b"])), "Travel", "two remembered networks' routers at once")
        // Nothing read is no network, and can't be remembered.
        XCTAssertNil(r.network(""))
        XCTAssertEqual(r.profile(on: ""), "Travel")
        XCTAssertFalse(r.remember("", name: "Nothing", profile: nil))
        // Already remembered while one of its routers is away; a reading with another router is a network of its own.
        XCTAssertFalse(r.remember("b", name: "Again", profile: nil))
        XCTAssertTrue(r.remember(NetworkMark.reading(["b", "x"]), name: "Next door", profile: nil))
        XCTAssertNil(r.profile(on: NetworkMark.reading(["x", "b"])))
        // Decided on home stays decided while its routers come and go.
        XCTAssertEqual(AutoSwitch.Acted(mark: "c", rules: r), AutoSwitch.Acted(mark: NetworkMark.reading(["b", "c"]), rules: r))
        XCTAssertNotEqual(AutoSwitch.Acted(mark: "c", rules: r), AutoSwitch.Acted(mark: "a", rules: r))
        // A router two remembered networks share: neither by itself, whichever was remembered first; the one the Mac was
        // already on when it is one of them; the one read exactly so first of all.
        XCTAssertNil(r.network("b"))
        XCTAssertEqual(r.profile(on: "b"), "Travel")
        XCTAssertEqual(r.network("b", preferring: NetworkMark.reading(["b", "x"]))?.name, "Next door")
        XCTAssertEqual(r.network("b", preferring: NetworkMark.reading(["b", "c"]))?.name, "Home network")
        XCTAssertNil(r.network("b", preferring: "a"), "a network the reading can't be is no preference")
        XCTAssertEqual(r.identity("b", preferring: NetworkMark.reading(["b", "c"])), "b,c")
        XCTAssertEqual(r.identity("b"), "b")
        XCTAssertTrue(r.remember("b", name: "Shared", profile: "Flat"), "remembered as read, it is a network of its own")
        XCTAssertEqual(r.network("b")?.name, "Shared")
        XCTAssertEqual(r.network("b", preferring: NetworkMark.reading(["b", "c"]))?.name, "Home network", "but the Mac stays where it was")
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
        // Another network decides again, one unbraid can't recognise as any other.
        XCTAssertEqual(AutoSwitch.decide(s, rules: r, mark: "hotel-mark", acted: acted, over: never), .to("Travel"))
        XCTAssertEqual(AutoSwitch.decide(s, rules: r, mark: AutoSwitch.unrecognised, acted: acted, over: never), .to("Travel"))
        // A change to the rules decides again only where it changed the profile: not on the café for the office's rule.
        var changed = r
        changed.known[1].profile = "Travel"
        XCTAssertEqual(AutoSwitch.decide(s, rules: changed, mark: "cafe-mark", acted: acted, over: never), .none)
        let office = AutoSwitch.Acted(mark: "office-mark", rules: r)
        XCTAssertEqual(AutoSwitch.decide(s, rules: changed, mark: "office-mark", acted: office, over: never), .to("Travel"))
        // The name unrecognised networks go by is never remembered.
        XCTAssertFalse(changed.remember(AutoSwitch.unrecognised, name: "Café", profile: "Home"))
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
        // Its route removed the usual way: the profile is repaired to a route that exists, and is switched to.
        var removed = setup
        removed.routes.removeAll { $0.id == "us" }
        XCTAssertEqual(removed.profiles.first { $0.name == "Travel" }?.defaultRoute, "nl")
        XCTAssertEqual(AutoSwitch.decide(removed, rules: r, mark: "cafe-mark", acted: nil, over: never), .to("Travel"))
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
