import XCTest

/// What a restore says it weakens, judged by what each app, website and the default route effectively get, and how hard
/// a passphrase is to guess: generated pairs and passphrases, plus the cases that were missed before.
final class BackupWeakensTests: XCTestCase {
    private struct RNG: RandomNumberGenerator {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func pick<T>(_ a: [T]) -> T { a[Int.random(in: 0..<a.count, using: &self)] }
        mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &self) }
        mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
    }

    private let key = String(repeating: "A", count: 42) + "E=", peer = String(repeating: "B", count: 42) + "E="
    private func wg(_ endpoint: String = "203.0.113.1:51820", dns: String = "10.0.0.1") -> WgPeer {
        try! WgConf.parse("[Interface]\nPrivateKey = \(key)\nAddress = 10.0.0.2/32\nDNS = \(dns)\n[Peer]\nPublicKey = \(peer)\nEndpoint = \(endpoint)\nAllowedIPs = 0.0.0.0/0\n", name: "Work")
    }

    /// Routes: Nord (blocking on), Mullvad (blocking off), an own WireGuard server.
    private func base() -> Setup {
        var s = Setup()
        s.routes = [Route(id: "nl", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands")),
                    Route(id: "m1", loc: Location(provider: "mullvad", countryCode: "SE", country: "Sweden")),
                    Route(id: "w1", wg: wg(), own: "s1")]
        s.servers = [OwnServer(id: "s1", wg: wg())]
        s.opts = ["nord": ["protect": "on"], "mullvad": ["protect": "off"]]
        return s
    }

    // MARK: Generated pairs

    private func random(_ g: inout RNG) -> Setup {
        var s = base()
        let targets = ["nl", "m1", "w1", DIRECT, BLOCK, "gone"]
        s.defaultRoute = g.pick(["nl", "m1", "w1", DIRECT])
        for a in ["a", "b", "c", "d"] where g.chance(0.6) { s.apps["org.example.\(a)"] = g.pick(targets.filter { $0 != "gone" }) }
        for n in ["example.com", "cdn.example.com", "a.cdn.example.com", "tracker.example", "x.tracker.example", "nas.lan"] where g.chance(0.5) {
            s.sites[n] = g.pick(targets.filter { $0 != "gone" })
        }
        if g.chance(0.5) {
            s.prefs.filter = Filter(id: g.pick(["quad9", "adguard"]), routes: g.chance(0.5), direct: g.chance(0.5), directApps: g.chance(0.5),
                                    apps: g.chance(0.5) ? ["org.example.\(g.pick(["a", "b", "e"]))": g.chance(0.5)] : [:])
        }
        if g.chance(0.3) { s.opts["mullvad"] = ["protect": "on"] }
        if g.chance(0.3) { s.routes[0].filter = false }
        return s
    }

    /// Asked of the compiled configs: anything that gets weaker produces a note; a restore that makes nothing weaker,
    /// and changes no setting, produces none.
    func testEveryWeakeningIsSaidAndNothingElse() {
        var g = RNG(0x7E57)
        var problems: [String] = []
        for _ in 0..<1500 {
            let here = random(&g)
            // Half the time a small change of here, half another setup.
            var next = here
            if g.chance(0.5) { next = random(&g) } else {
                switch g.int(0...3) {
                case 0: next.apps["org.example.\(g.pick(["a", "b", "e"]))"] = g.pick(["nl", "m1", "w1", DIRECT, BLOCK])
                case 1: next.sites[g.pick(["example.com", "cdn.example.com", "x.tracker.example", "nas.lan"])] = g.pick(["nl", "m1", DIRECT, BLOCK])
                case 2: next.prefs.filter.apps["org.example.\(g.pick(["a", "c"]))"] = g.chance(0.5)
                default: next.defaultRoute = g.pick(["nl", "m1", "w1", DIRECT])
                }
            }
            let said = Backup.weakens(here, next)
            guard let l = RestoreTraffic.losses(here, next) else { problems.append("couldn't be compiled: \(here.apps) → \(next.apps)"); continue }
            let weaker = l.defaultRoute != nil || !l.apps.isEmpty || !l.sites.isEmpty || !l.home.isEmpty
            if weaker && said.isEmpty { problems.append("weaker but nothing said: \(here.apps) \(here.sites) → \(next.apps) \(next.sites)") }
            // Nothing the traffic gets changed for the worse, and no setting: nothing to say.
            if !weaker, here.prefs == next.prefs, here.opts == next.opts, here.routes == next.routes, here.servers == next.servers, !said.isEmpty {
                problems.append("nothing changed but said \(said): \(here.apps) \(here.sites) → \(next.apps) \(next.sites)")
            }
        }
        XCTAssertEqual(problems.count, 0, problems.prefix(5).joined(separator: "\n"))
    }

    /// Every nesting of website rules: "blocked" is said exactly when some name blocked here (or under one) would no
    /// longer be, by the most specific applied rule.
    func testRestoresThatOpenAHoleUnderABlockInEveryNesting() {
        var g = RNG(0x401E)
        let chain = ["n.example", "b.n.example", "c.b.n.example", "d.c.b.n.example", "o.example", "nas.lan", "x.nas.lan"]
        let probes = chain.flatMap { [$0, "zz9." + $0, "q.zz9." + $0] }
        func gets(_ name: String, _ rules: [String: String]) -> String? {
            Sites.applied(Setup(routes: [], defaultRoute: DIRECT, apps: [:], sites: rules)).filter { Sites.under(name, $0.key) }.max { $0.key.count < $1.key.count }?.value
        }
        var problems: [String] = []
        for _ in 0..<1000 {
            var here = base(), next = here
            for name in chain {
                if g.chance(0.5) { here.sites[name] = g.pick([BLOCK, BLOCK, DIRECT, "nl", "w1"]) }
                if g.chance(0.5) { next.sites[name] = g.chance(0.6) ? here.sites[name] ?? g.pick([BLOCK, DIRECT, "nl"]) : g.pick([BLOCK, DIRECT, "nl", "w1"]) }
            }
            let opened = probes.filter { gets($0, here.sites) == BLOCK && gets($0, next.sites) != BLOCK }
            let said = Backup.weakens(here, next).filter { $0.contains("blocked") }
            if !opened.isEmpty && said.isEmpty { problems.append("opens \(opened) but says nothing: \(here.sites) → \(next.sites)") }
            if opened.isEmpty && !said.isEmpty { problems.append("opens nothing but says \(said): \(here.sites) → \(next.sites)") }
        }
        XCTAssertEqual(problems.count, 0, problems.prefix(5).joined(separator: "\n"))
    }

    // MARK: Cases missed before


    func testWebsitesByWhatTheyEffectivelyGet() {
        var here = base()
        here.defaultRoute = "nl"
        here.sites = ["example.com": "nl", "nas.lan": "nl"]
        // A child added on a route without blocking, or on Direct: the part under it loses what it had.
        XCTAssertEqual(Backup.weakens(here, here.with { $0.sites["cdn.example.com"] = "m1" }), ["1 website loses the provider's ad and tracker blocking it has now."])
        XCTAssertEqual(Backup.weakens(here, here.with { $0.sites["cdn.example.com"] = DIRECT }), ["1 website goes from a VPN route to Direct."])
        // A rule removed: it goes as its app does, here Direct.
        XCTAssertEqual(Backup.weakens(here.with { $0.defaultRoute = DIRECT }, here.with { $0.defaultRoute = DIRECT; $0.sites["example.com"] = nil }),
                       ["1 website goes from a VPN route to Direct."])
        // A rule that never applies (a name on the own network) changes no traffic: nothing said.
        XCTAssertEqual(Backup.weakens(here, here.with { $0.sites["nas.lan"] = DIRECT }), [])
    }

    func testAnAppLeavingTheFilteredDirectScopeIsSaid() {
        var here = base()
        here.defaultRoute = "nl"
        here.apps = ["com.example.browser": DIRECT]
        here.prefs.filter = Filter(id: "quad9", routes: false, directApps: true)
        XCTAssertEqual(Backup.weakens(here, here.with { $0.apps["com.example.browser"] = "m1" }), ["1 app loses the DNS filter."])
        XCTAssertEqual(Backup.weakens(here, here.with { $0.apps["com.example.browser"] = "nl" }), ["1 app loses the DNS filter."])
        XCTAssertEqual(Backup.weakens(here.with { $0.prefs.filter.routes = true }, here.with { $0.prefs.filter.routes = true; $0.apps["com.example.browser"] = "m1" }), [])
    }

    func testLongHostsAreComparedWhole() {
        let long = String(repeating: "a", count: 63) + "." + String(repeating: "b", count: 30)
        var here = base()
        here.routes.append(Route(id: "x1", ss: SsProfile(name: "Shadow", server: long + ".old.example", port: 8388, method: "chacha20-ietf-poly1305", password: "pw")))
        let next = here.with { $0.routes[3].ss?.server = long + ".new.example" }
        let said = Backup.weakens(here, next)
        XCTAssertEqual(said.count, 1)
        XCTAssertTrue(said[0].hasPrefix("\"Shadow\" connects to …"), said[0])
        XCTAssertTrue(said[0].contains("new.example instead of …"), said[0])
        // A bound route changed on its own, the server entry as it was.
        XCTAssertEqual(Backup.weakens(here, here.with { $0.routes[2].wg?.endpoint = long + ".new.example:51820" }).count, 1)
    }

    // MARK: The evaluator against the compiler

    /// What the walk of a compiled config says, for cases whose outcome the compiler's own tests check by hand.
    func testTheWalkAgreesWithTheCompilersOwnRules() throws {
        var s = base()
        s.defaultRoute = "nl"
        s.apps = ["com.example.blocked": BLOCK, "com.example.direct": DIRECT, "com.example.own": "w1", "com.example.sweden": "m1"]
        s.sites = ["blocked.example": BLOCK, "direct.example": DIRECT, "sweden.example": "m1"]
        s.prefs.lan = true
        s.prefs.filter = Filter(id: "quad9", directApps: true)
        let apps = RestoreTraffic.patterns(s.apps.keys)
        let c = try XCTUnwrap(RestoreTraffic.compile(s, apps: apps))
        func app(_ key: String) -> String { RestoreTraffic.samplePath(apps[key]![0])! }
        func go(_ process: String?, _ name: String?, _ address: String = RestoreTraffic.publicAddress) -> RestoreTraffic.Outcome? {
            RestoreTraffic.connect(c, process: process, name: name, address: address)
        }
        XCTAssertEqual(go(app("com.example.blocked"), "x.example")?.exit, .rejected)
        XCTAssertEqual(go(app("com.example.direct"), "x.example"), .init(exit: .direct, resolver: .filter))
        XCTAssertEqual(go(app("com.example.own"), "x.example")?.exit, .tunnel("r-w1"))
        XCTAssertEqual(go(app("com.example.sweden"), "x.example"), .init(exit: .tunnel("r-m1"), resolver: .route))
        XCTAssertEqual(go(RestoreTraffic.otherProgram, "x.example"), .init(exit: .tunnel("r-nl"), resolver: .provider))
        // Websites beat apps; the most specific wins; a blocked app stays blocked whatever it opens.
        XCTAssertEqual(go(RestoreTraffic.otherProgram, "a.blocked.example")?.exit, .rejected)
        XCTAssertEqual(go(RestoreTraffic.otherProgram, "direct.example"), .init(exit: .direct, resolver: .filter))
        XCTAssertEqual(go(app("com.example.direct"), "sweden.example")?.exit, .tunnel("r-m1"))
        XCTAssertEqual(go(app("com.example.blocked"), "direct.example")?.exit, .rejected)
        // unbraid itself always direct; the local network direct with LAN access on.
        XCTAssertEqual(go("/Applications/unbraid.app/Contents/MacOS/unbraid", "x.example")?.exit, .direct)
        XCTAssertEqual(go(RestoreTraffic.otherProgram, nil, "192.168.1.20")?.exit, .direct)
        // A Home WireGuard tunnel takes its own ranges.
        var home = s
        home.home.wg = try WgConf.parse("[Interface]\nPrivateKey = \(key)\nAddress = 192.168.77.201/24\n[Peer]\nPublicKey = \(peer)\nEndpoint = home.example.org:51820\nAllowedIPs = 10.0.0.0/8\n", name: "Home")
        let h = try XCTUnwrap(RestoreTraffic.compile(home, apps: apps))
        XCTAssertEqual(RestoreTraffic.connect(h, process: RestoreTraffic.otherProgram, name: nil, address: "10.1.2.3")?.exit, .home)
        // A route waiting for its config: refused.
        var waiting = s
        waiting.routes.append(Route(id: "k1", wg: wg().withoutSecrets(), own: "sk", keyless: true))
        waiting.servers.append(OwnServer(id: "sk", wg: wg().withoutSecrets(), keyless: true))
        waiting.apps["com.example.waiting"] = "k1"
        let wa = RestoreTraffic.patterns(waiting.apps.keys)
        let w = try XCTUnwrap(RestoreTraffic.compile(waiting, apps: wa))
        XCTAssertEqual(RestoreTraffic.connect(w, process: RestoreTraffic.samplePath(wa["com.example.waiting"]![0]), name: "x.example")?.exit, .rejected)
    }

    /// Random setups: what the walk finds for each app and website is what the setup says it chose (for these, no
    /// nesting and no rule the walk doesn't know).
    func testTheWalkFollowsEveryChoice() throws {
        var g = RNG(0xC0DE)
        var problems: [String] = []
        for _ in 0..<500 {
            let s = random(&g)
            let apps = RestoreTraffic.patterns(s.apps.keys)
            guard let c = RestoreTraffic.compile(s, apps: apps) else { problems.append("not compiled: \(s.apps)"); continue }
            func expected(_ id: String) -> String { id == BLOCK ? "rejected" : id == DIRECT ? "direct" : "r-\(id)" }
            func got(_ o: RestoreTraffic.Outcome?) -> String {
                switch o?.exit { case .rejected: "rejected"; case .direct: "direct"; case .tunnel(let t): t; case .home: "home"; case nil: "?" }
            }
            for (key, id) in s.apps {
                let o = RestoreTraffic.connect(c, process: RestoreTraffic.samplePath(apps[key]![0]), name: RestoreTraffic.otherName)
                if got(o) != expected(id) { problems.append("app \(key) on \(id): \(got(o))") }
            }
            let rules = Sites.applied(s)
            for name in ["example.com", "a.cdn.example.com", "x.tracker.example", "z.example"] {
                let rule = rules.filter { Sites.under(name, $0.key) }.max { $0.key.count < $1.key.count }?.value ?? s.defaultRoute
                let o = RestoreTraffic.connect(c, process: RestoreTraffic.otherProgram, name: name)
                if got(o) != expected(rule) { problems.append("site \(name) on \(rule): \(got(o))") }
            }
        }
        XCTAssertEqual(problems.prefix(5), [])
    }

    // MARK: Found in the fourth review

    func testWhatTheCompiledConfigsTellApart() throws {
        var here = base()
        // A Direct website rule removed: its lookups no longer go to the filter.
        here.defaultRoute = DIRECT
        here.prefs.filter = Filter(id: "quad9", direct: false, directApps: true)
        here.sites = ["example.com": DIRECT]
        XCTAssertEqual(Backup.weakens(here, here.with { $0.sites = [:] }), ["1 website loses the DNS filter."])
        // An app nested inside another's bundle: its own filter switch counts; a block of its bundle still holds.
        let xcode = "/Applications/Xcode.app", simulator = "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"
        let nested = ["com.apple.dt.Xcode": [Compiler.pattern(forPath: xcode, ignoringCase: true)], "com.apple.iphonesimulator": [Compiler.pattern(forPath: simulator, ignoringCase: true)]]
        var dev = here
        dev.sites = [:]
        dev.apps = ["com.apple.dt.Xcode": "nl"]
        XCTAssertEqual(Backup.weakens(dev, dev.with { $0.prefs.filter.apps["com.apple.iphonesimulator"] = false }, apps: nested), ["1 app loses the DNS filter."])
        let blocked = dev.with { $0.apps = ["com.apple.dt.Xcode": BLOCK, "com.apple.iphonesimulator": BLOCK] }
        XCTAssertEqual(Backup.weakens(blocked, blocked.with { $0.apps["com.apple.iphonesimulator"] = nil }, apps: nested), [])
        // Traffic refused now (a route waiting for its config) sent out Direct.
        var waiting = here
        waiting.sites = [:]
        waiting.routes.append(Route(id: "k1", wg: wg().withoutSecrets(), own: "sk", keyless: true))
        waiting.servers.append(OwnServer(id: "sk", wg: wg().withoutSecrets(), keyless: true))
        waiting.apps = ["org.example.a4": "k1"]
        waiting.sites = ["x.o.example": "k1", "o.example": DIRECT]
        XCTAssertEqual(Backup.weakens(waiting, waiting.with { $0.apps = [:] }),
                       ["1 app that can't connect now, because its route waits for a server's config, goes out without it."])
        XCTAssertEqual(Backup.weakens(waiting, waiting.with { $0.sites["x.o.example"] = nil }),
                       ["1 website that can't connect now, because its route waits for a server's config, goes out without it."])
        // A Home WireGuard tunnel that covers less: the addresses it no longer takes go Direct.
        var home = base()
        home.prefs.lan = true
        home.home.wg = try WgConf.parse("[Interface]\nPrivateKey = \(key)\nAddress = 192.168.77.201/24\n[Peer]\nPublicKey = \(peer)\nEndpoint = home.example.org:51820\nAllowedIPs = 10.0.0.0/8\n", name: "Home")
        let narrower = home.with { $0.home.wg?.allowedIps = ["10.20.0.0/16"] }
        XCTAssertEqual(Backup.weakens(home, narrower), ["Part of the home network goes Direct instead of through the home tunnel."])
        // OpenVPN: another of its servers, or a port it inherits.
        let config = "client\ndev tun\nproto udp\nremote primary.example 1194\nremote old.example 1194\nremote-random\nremote-cert-tls server\n<ca>\n-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n</ca>\n"
        var office = base()
        office.routes.append(Route(id: "o1", ovpn: OvpnProfile(name: "Office", config: config)))
        XCTAssertEqual(Backup.weakens(office, office.with { $0.routes[3].ovpn?.config = config.replacingOccurrences(of: "old.example", with: "new.example") }),
                       ["\"Office\" connects to another server at new.example."])
        let lone = "client\ndev tun\nport 1194\nremote primary.example\nremote-cert-tls server\n<ca>\n-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n</ca>\n"
        office.routes[3].ovpn?.config = lone
        XCTAssertEqual(Backup.weakens(office, office.with { $0.routes[3].ovpn?.config = lone.replacingOccurrences(of: "port 1194", with: "port 443") }),
                       ["\"Office\" connects to another server at primary.example."])
    }

    // MARK: Found in the fifth review

    /// A name given Direct takes an app on a VPN there too: walked from that app's program, not only the default's.
    func testAWebsiteRuleSaysWhatItDoesToEveryApp() {
        var here = base()
        here.defaultRoute = DIRECT
        here.apps = ["com.example.browser": "nl"]
        XCTAssertEqual(Backup.weakens(here, here.with { $0.sites["example.com"] = DIRECT }), ["1 website goes from a VPN route to Direct."])
    }

    /// A home range narrowed at its far end, its first address still covered: the edges of every range are walked.
    func testAHomeRangeNarrowedAtEitherEndIsSaid() throws {
        var home = base()
        home.prefs.lan = true
        home.home.wg = try WgConf.parse("[Interface]\nPrivateKey = \(key)\nAddress = 192.168.77.201/24\n[Peer]\nPublicKey = \(peer)\nEndpoint = home.example.org:51820\nAllowedIPs = 10.0.0.0/8\n", name: "Home")
        XCTAssertEqual(Backup.weakens(home, home.with { $0.home.wg?.allowedIps = ["10.0.0.0/16"] }), ["Part of the home network goes Direct instead of through the home tunnel."])
        XCTAssertEqual(Backup.weakens(home, home.with { $0.home.wg?.allowedIps = ["10.0.0.0/8", "172.16.0.0/12"] }), [])
        XCTAssertEqual(RestoreTraffic.edges("10.0.0.0/8"), ["10.0.0.1", "10.255.255.254"])
        XCTAssertEqual(RestoreTraffic.edges("192.168.1.7/32"), ["192.168.1.7"])
    }

    /// An app with two copies, one inside a blocked bundle: the other copy is walked too.
    func testEveryCopyOfAnAppIsWalked() {
        var here = base()
        here.defaultRoute = DIRECT
        here.apps = ["com.example.outer": BLOCK, "com.example.child": BLOCK]
        let apps = ["com.example.outer": [Compiler.pattern(forPath: "/Applications/Outer.app", ignoringCase: true)],
                    "com.example.child": [Compiler.pattern(forPath: "/Applications/Outer.app/Contents/Child.app", ignoringCase: true),
                                          Compiler.pattern(forPath: "/Users/someone/Applications/Child.app", ignoringCase: true)]]
        XCTAssertEqual(Backup.weakens(here, here.with { $0.apps["com.example.child"] = nil }, apps: apps), ["1 app that is blocked now won't be."])
    }

    /// The default route refused now (its route waits for its config) and Direct after: said.
    func testTheDefaultRouteLetOutIsSaid() {
        var here = base()
        here.routes.append(Route(id: "k1", wg: wg().withoutSecrets(), own: "sk", keyless: true))
        here.servers.append(OwnServer(id: "sk", wg: wg().withoutSecrets(), keyless: true))
        here.defaultRoute = "k1"
        XCTAssertEqual(Backup.weakens(here, here.with { $0.defaultRoute = DIRECT }),
                       ["The default route can't connect now, because its route waits for a server's config; after the restore its traffic goes out."])
    }

    /// Every kind of loss, for the default route, an app, a website and a home address, has a sentence.
    func testEveryLossHasASentence() {
        let here = base()
        for kind in RestoreTraffic.Loss.allCases {
            for slot in 0..<4 {
                var l = RestoreTraffic.Losses()
                switch slot { case 0: l.defaultRoute = kind; case 1: l.apps["org.example.a"] = kind; case 2: l.sites["example.com"] = kind; default: l.home["10.0.0.1"] = kind }
                XCTAssertFalse(Backup.trafficNotes(l, current: here, filterOff: false).isEmpty, "\(kind) in slot \(slot)")
            }
        }
    }

    /// The largest setup a backup may hold: 50 websites, 20 profiles, 1,000 apps on Block, long keys, Direct default.
    /// The whole comparison stays well under a second (it runs away from the window, which shows that it checks).
    func testTheLargestSetupIsComparedQuickly() {
        var big = base()
        big.defaultRoute = DIRECT
        big.apps = Dictionary(uniqueKeysWithValues: (0..<Backup.maxApps).map { ("org.example." + String(repeating: "x", count: 200) + ".\($0)", $0 % 3 == 0 ? BLOCK : $0 % 3 == 1 ? "nl" : DIRECT) })
        big.sites = Dictionary(uniqueKeysWithValues: (0..<Sites.max).map { ("s\($0).example", $0 % 2 == 0 ? BLOCK : DIRECT) })
        big.profiles = (0..<Setup.maxProfiles).map { Profile(name: "P\($0)", defaultRoute: "nl") }
        let next = big.with { $0.apps = $0.apps.mapValues { $0 == BLOCK ? DIRECT : $0 }; $0.sites = $0.sites.mapValues { _ in "m1" } }
        let start = Date()
        let said = Backup.weakens(big, next)
        let took = Date().timeIntervalSince(start)
        print("RESTORE-CHECK largest setup: \(String(format: "%.2f", took)) s, \(said.count) notes")
        XCTAssertFalse(said.isEmpty)
        XCTAssertLessThan(took, 1)
    }

    // MARK: Passphrases

    func testThePassphraseJudge() {
        var g = RNG(0x9A55)
        var wrong: [String] = []
        let stems = ["horse", "pass", "word", "test", "summer", "london", "Pass", "ab12", "password"]
        let seps = [" ", "-", "_", ".", ",", "/", "+", "|", ":", ";", "*", "~", "", "  ", "\t", "!", "#", "@", "=", "\\"]
        for _ in 0..<4000 {
            let stem = g.pick(stems), sep = g.pick(seps), n = g.int(4...10)
            let p = (1...n).map { stem + (g.chance(0.5) ? String($0 % 10) : "") }.joined(separator: sep)
            if Backup.strength(p) == .hard { wrong.append("repeat: \(p.debugDescription)") }
        }
        let trivial = ["password1 password2 password3 password4 password5 password6 password7 password8 password9 password0",
                       "word1 word2 word3 word4 word5 word6 word7 word8", "horse1+horse2+horse3+horse4+horse5+horse6",
                       "qwertyuiop", "asdfghjkl;", "zxcvbnm,./", "1qaz2wsx3edc4rfv", "!QAZ2wsx#EDC4rfv", "zaq1xsw2cde3vfr4", "qazwsxedcrfvtgbyhn",
                       "1q2w3e4r5t6y7u8i", "qwertzuiopasdfgh", "azertyuiopqsdfgh", "poiuytrewqlkjhgf", "mnbvcxzlkjhgfdsa", "1234qwerasdfzxcv",
                       "q1w2e3r4t5y6u7i8o9p0", "aaaaaaaaaaaaaaaaaaaaaaaa", "abcabcabcabcabcabc", "Password1234!", "qwertyqwertyqwerty",
                       "unbraid unbraid unbraid unbraid", "1234567890123456", "abcdefghijklmnopqrstuvwxyz", "Aa1!Aa1!Aa1!Aa1!"]
        for p in trivial where Backup.strength(p) == .hard { wrong.append("trivial: \(p)") }
        // Canonically equivalent spellings.
        let pairs = [("caf\u{E9} cr\u{E8}me br\u{FB}l\u{E9}e na\u{EF}ve", "cafe\u{301} cre\u{300}me bru\u{302}le\u{301}e nai\u{308}ve"),
                     ("\u{1E69}\u{1E69}\u{1E69}Zebra42!", "s\u{323}\u{307}s\u{307}\u{323}\u{1E61}\u{323}Zebra42!"), ("\u{F1}and\u{FA} p\u{E9}rez", "n\u{303}andu\u{301} pe\u{301}rez")]
        for (a, b) in pairs where Backup.strength(a) != Backup.strength(b) || BackupTexts.saveCheck(a, a, keys: true) != BackupTexts.saveCheck(b, b, keys: true) {
            wrong.append("equivalent forms judged apart: \(a)")
        }
        // Random passphrases, word phrases (one word repeated), other scripts and emoji: hard.
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!#$%&*+-=?@")
        let random = (0..<500).filter { _ in Backup.strength(String((0..<16).map { _ in g.pick(alphabet) })) != .hard }.count
        XCTAssertLessThan(random, 25)
        let syll = ["ba", "ko", "ri", "tem", "lu", "mor", "vash", "pel", "dri", "qua", "zon", "fi", "gut", "hes", "jor", "nix", "sal", "wey"]
        var list = Set<String>()
        while list.count < 300 { list.insert(g.pick(syll) + g.pick(syll) + (g.chance(0.5) ? g.pick(syll) : "")) }
        let words = Array(list).sorted()
        for _ in 0..<1000 {
            var phrase = (0..<g.int(5...7)).map { _ in g.pick(words) }
            phrase.insert(phrase[g.int(0...(phrase.count - 1))], at: g.int(0...phrase.count))
            let p = phrase.joined(separator: g.pick([" ", "-", " "]))
            if Backup.strength(p) != .hard { wrong.append("word phrase not hard: \(p)") }
        }
        let han = Array("春湖雲島夢舟雪鳥星野森雨月風花海山川空石竹松梅桜光")
        let flags = ["🇳🇱", "🇯🇵", "🇧🇷", "🇲🇦", "🇳🇿", "🇫🇮", "🇲🇽", "🇰🇷", "🇵🇹", "🇨🇦", "🇮🇳", "🇬🇭", "🇳🇴", "🇨🇱", "🇵🇭", "🇩🇪", "🇮🇹", "🇪🇸", "🇸🇪", "🇦🇷"]
        let cyrillic = Array("абвгдежзиклмнопрстуфхцчшщэюя")
        for _ in 0..<200 {
            let a = String((0..<16).map { _ in g.pick(han) }), b = (0..<16).map { _ in g.pick(flags) }.joined()
            let c = (0..<5).map { _ in String((0..<6).map { _ in g.pick(cyrillic) }) }.joined(separator: " ")
            for p in [a, b, c] where Backup.strength(p) != .hard { wrong.append("other script not hard: \(p)") }
        }
        XCTAssertEqual(Backup.strength("🇳🇱🇯🇵🇧🇷🇲🇦🇳🇿🇫🇮🇲🇽🇰🇷🇵🇹🇨🇦🇮🇳🇬🇭🇳🇴🇨🇱🇵🇭🇩🇪"), .hard)
        XCTAssertEqual(Backup.strength("春湖雲島夢舟雪鳥星野森雨月風花海"), .hard)
        // One character of another kind doesn't lift the rest.
        XCTAssertEqual(Backup.strength("dog€x"), .easy)
        XCTAssertEqual(Backup.strength("summer😀"), .easy)
        // Counters at a word's start, digits of another script in a row, a counter series without separators, a walk
        // with shifted digits: none hard, so none can carry keys.
        for p in ["1password 2password 3password 4password 5password 6password 7password 8password 9password 10password", "١٢٣٤٥٦٧٨٩٠",
                  "pass1pass2pass3pass4pass5pass6pass7", "word1word2word3word4word5word6word7word8", "summer1summer2summer3summer4summer5summer6summer7",
                  "Pass1Pass2Pass3Pass4Pass5Pass6Pass7Pass8", (1...20).map { "horse\($0)" }.joined(), (1...20).map { "pass\($0)" }.joined(), "!QAZ2wsx#EDC4rfv"] {
            XCTAssertNotEqual(Backup.strength(p), .hard, p)
            XCTAssertFalse(BackupTexts.saveCheck(p, p, keys: true).ready, p)
        }
        XCTAssertEqual(Backup.strength("١٢٣٤٥٦٧٨٩٠"), .easy)
        // The whole text is judged: a long repeat first doesn't hide a random part after it.
        let tail = String((0..<24).map { _ in g.pick(alphabet) })
        XCTAssertEqual(Backup.strength(String(repeating: "0", count: 300) + tail), Backup.strength("0" + tail))
        XCTAssertNotEqual(Backup.strength("summer2024€"), .hard)
        let t = Date()
        _ = Backup.strength(String(repeating: "correct horse ", count: 20_000))
        XCTAssertLessThan(Date().timeIntervalSince(t), 1)
        XCTAssertEqual(wrong.prefix(20), [])
    }
}

private extension Setup {
    func with(_ change: (inout Setup) -> Void) -> Setup { var s = self; change(&s); return s }
}
