import XCTest

/// The app's core promises, checked on a few hundred generated setups: each is compiled, then walked the way the engine
/// walks it (`EngineWalk`), its deny-all config too. A promise's wording, with its exceptions, is the doc comment of its
/// check below. Changing a promise, an exception or the generator's field list is the owner's decision, never a way to
/// make a test pass.
///
/// A setting that changes the compiled config belongs in the generator: `testEverySettingIsGeneratedOrSaysWhyNot`
/// fails for any stored field of the setup or the compiler input that is neither generated nor listed with a reason.
final class PromisesTests: XCTestCase {
    private static let key = "aGVsbG8taGVsbG8taGVsbG8taGVsbG8taGVsbG8tMTI="
    private static let selfApp = "/Applications/unbraid.app"
    private static let appKeys = ["com.a", "com.b", "com.c", "com.v"]
    /// A public address dialled directly, and an ordinary name with no website rule.
    private static let publicIP = EngineWalk.publicAddress, plainName = "unbraid-check.example"
    private static let siteNames = ["example.com", "api.example.com", "news.example.org", "netflix.com", "printer.lan",
                                    "svc.internal", "nas.corp.example", "app.tail123.ts.net", "xn--bcher-kva.de"]

    private static func program(_ app: String) -> String { "/Applications/\(app).app/Contents/MacOS/main" }

    private static func server(_ n: String) -> Server {
        let h = stableId(n)
        return Server(name: "\(n) #1", host: "\(n).nordvpn.com", ip: "10.9.\(h & 0xff).\(h >> 8 & 0xff)", publicKey: key, load: 10)
    }

    // MARK: The generator

    /// One generated case: the setup, the compiler input, and what the generator chose, for messages.
    struct Case {
        var input: Compiler.Input
        var label: String
        var setup: Setup { input.setup }
    }

    /// Seeded, so every run walks the same setups.
    static func cases(_ count: Int) -> [Case] {
        var seed: UInt64 = 0x5afe_7e57
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }
        func coin() -> Bool { next(2) == 0 }
        return (0..<count).map { n in
            let iv = Route(id: "iv", loc: Location(provider: "ivpn", countryId: 0, countryCode: "NL", country: "Netherlands"), hue: 3)
            let iw = Route(id: "iw", loc: Location(provider: "ivpn", countryId: 0, countryCode: "CH", country: "Switzerland"), hue: 5)
            var s = Setup(routes: [Route(id: "nl", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands")),
                                   Route(id: "us", loc: Location(countryId: 228, countryCode: "US", country: "United States"), hue: 1),
                                   Route(id: "it", loc: Location(countryId: 106, countryCode: "IT", country: "Italy"), hue: 2),
                                   iv, iw, Route(id: "tx", tsExit: "100.64.0.9", tsName: "exit")],
                          defaultRoute: "nl")
            let choices = ["nl", "us", "it", "iv", "iw", "tx", DIRECT, BLOCK]
            s.defaultRoute = ["nl", "us", "it", "iv", "tx", DIRECT, DIRECT, DIRECT][next(8)]
            s.apps = Dictionary(uniqueKeysWithValues: appKeys.compactMap { k in next(6) == 0 ? nil : (k, choices[next(choices.count)]) })
            s.sites = Dictionary((0..<next(5)).map { _ in (siteNames[next(siteNames.count)], choices[next(choices.count)]) }) { a, _ in a }
            if next(4) == 0 { s.testing = [["us", "it", "iv"][next(3)]] }
            s.prefs.lan = coin()
            s.prefs.killLevel = KillLevel.allCases[next(3)]
            s.home.tailscale = coin()
            if next(3) == 0 { s.home.tsControlUrl = "https://hs.example" }
            s.home.subnets = coin() ? ["192.168.178.0/24"] : []
            s.home.tsSuffix = [nil, "tail123.ts.net", "corp.example"][next(3)]
            s.home.tsSuffixConfirmed = next(4) != 0
            let disguise = next(3) == 0
            if disguise { s.opts["ivpn"] = ["disguise": "on"] }

            // Tunnels: "it" sometimes on the same server as "us", and the second IVPN route on the first one's (one shared
            // tunnel each time); IVPN with its V2Ray hop.
            let share = coin()
            var links: [String: Link] = [:]
            for r in s.routes {
                if r.tsExit != nil { links[r.id] = .ts(server(r.id)); continue }
                let sv = server(share && r.id == "it" ? "us" : share && r.id == "iw" ? "iv" : r.id)
                var peer = Nord.peer(sv, key)
                if r.loc.provider == "ivpn" {
                    peer.presharedKey = key
                    peer.disguise = Disguise(vmess: Vmess(server: "149.22.83.102", port: 80, uuid: "27de860d-5601-412d-8b71-baa048a94b98"), wgPort: 15351)
                }
                links[r.id] = .wg(sv, peer)
            }
            // Routes with no usable tunnel right now.
            let blocked: Set<String> = next(4) == 0 ? [["nl", "us", "iv", "iw"][next(4)]] : []
            for b in blocked { links[b] = nil }
            // Apps as the scan finds them: installed, only remembered where they were last seen, or not on this Mac.
            let remembered: Set<String> = next(5) == 0 ? [appKeys[next(appKeys.count)]] : []
            let missing = next(6) == 0 ? appKeys[next(appKeys.count)] : nil
            let installed = Dictionary(uniqueKeysWithValues: appKeys.filter { $0 != missing || remembered.contains($0) }
                .map { ($0, [Compiler.pattern(forPath: "/Applications/\($0).app")]) })
            let ownerless = [Compiler.Ownerless.followsDefault, .refusedWhileBlocking, .refusedWhileSplit][next(3)]
            var input = Compiler.Input(setup: s, links: links, blocked: blocked, apps: installed, remembered: remembered,
                                       selfPattern: Compiler.pattern(forPath: selfApp), tsSuffix: s.tailscale ? s.home.tsSuffix : nil,
                                       probe: next(4) == 0 ? (port: 18080, password: "probe") : nil, ownerless: ownerless,
                                       tsLoginPending: next(5) == 0)
            // The tailnet domain the app judges websites by, sometimes not the one this setup holds (a recovery's older
            // setup, a pause). The app takes it and the engine's tailnet domain from the same saved settings, so the two
            // agree whenever Tailscale runs.
            if next(5) == 0 {
                let domain = [nil, "tail123.ts.net", "corp.example"][next(3)]
                input.siteDomain = .given(domain)
                input.tsSuffix = s.tailscale ? domain : nil
            }
            let label = "case \(n): default \(s.defaultRoute) apps \(s.apps.sorted { $0.key < $1.key }) sites \(s.sites.sorted { $0.key < $1.key }) "
                + "blocked \(blocked.sorted()) remembered \(remembered.sorted()) \(ownerless) kill \(s.prefs.killLevel) lan \(s.prefs.lan) "
                + "tailscale \(s.home.tailscale) suffix \(s.home.tsSuffix ?? "-") disguise \(disguise) share \(share) domain \(input.websiteDomain ?? "-")"
            return Case(input: input, label: label)
        }
    }

    // MARK: Every setting is generated or says why not

    /// The generator's field list. "gen" = generated above; anything else is the reason it isn't (yet).
    static let fields: [String: [String: String]] = [
        "Setup": [
            "routes": "gen (Nord, IVPN, a Tailscale exit; imported, OpenVPN and Shadowsocks routes: batch 4)",
            "defaultRoute": "gen", "apps": "gen", "sites": "gen", "home": "gen", "prefs": "gen", "opts": "gen (IVPN Disguise)",
            "testing": "gen (walked through P1 only as a route kept running)",
            "favorites": "window only", "servers": "own servers: batch 4", "profiles": "a profile becomes the setup it names",
            "profile": "a profile becomes the setup it names", "pendingSwitch": "switch by network: batch 3",
            "profileSalt": "profile ids only", "blockedForLostRoute": "a count the window shows",
        ],
        "Prefs": [
            // Generated, but only public traffic is walked: the LAN and home paths they decide are batch 2.
            "lan": "gen (LAN walk: batch 2)", "killSwitch": "gen (killLevel; LAN walk: batch 2)", "killSwitchHome": "gen (killLevel; LAN walk: batch 2)",
            "threatProtection": "lookups: batch 2", "customDns": "lookups: batch 2", "filter": "lookups: batch 2",
            "stats": "not read by the compiler", "testAllRoutes": "not read by the compiler", "alwaysOn": "not read by the compiler",
        ],
        "Home": [
            "tailscale": "gen", "tsControlUrl": "gen (sign-in hosts walk: batch 2)", "tsSuffix": "gen", "tsSuffixConfirmed": "gen",
            "subnets": "gen (home walk: batch 2)",
            "tsAuthKey": "sign-in only", "tsEnrolled": "sign-in only", "wg": "home WireGuard tunnel: batch 2",
        ],
        "Route": [
            "id": "gen", "loc": "gen", "tsExit": "gen", "tsName": "gen", "hue": "window only",
            "wg": "imported: batch 4", "ovpn": "imported: batch 4", "ss": "imported: batch 4", "keyless": "imported: batch 4",
            "own": "own servers: batch 4", "filter": "lookups: batch 2", "checkInternet": "health checks: batch 5",
        ],
        "Input": [
            "setup": "gen", "links": "gen", "blocked": "gen", "apps": "gen", "remembered": "gen", "selfPattern": "gen",
            "tsSuffix": "gen", "probe": "gen (its own path: batch 2)", "ownerless": "gen", "tsLoginPending": "gen (sign-in hosts walk: batch 2)",
            "portStep": "ports step: batch 4", "siteDomain": "gen (and the named case below)",
        ],
        "Location": [
            "provider": "gen (Nord, IVPN)", "countryId": "gen", "countryCode": "gen", "country": "gen",
            "cityId": "server choice: batch 4", "city": "server choice: batch 4", "region": "server choice: batch 4",
            "group": "server choice: batch 4", "proto": "protocols: batch 4", "pinned": "pins: batch 4",
        ],
    ]

    private static func stored(_ value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap { $0.label.map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 } })
    }

    /// A new stored field fails here until it is generated or given a reason.
    func testEverySettingIsGeneratedOrSaysWhyNot() {
        let input = Compiler.Input(setup: Setup(), links: [:], apps: [:], selfPattern: "", tsSuffix: nil)
        let actual = ["Setup": Self.stored(Setup()), "Prefs": Self.stored(Prefs()), "Home": Self.stored(Home()),
                      "Route": Self.stored(Route(id: "x")), "Input": Self.stored(input), "Location": Self.stored(Location())]
        for (type, names) in actual {
            let listed = Set(Self.fields[type, default: [:]].keys)
            XCTAssertEqual(names.subtracting(listed).sorted(), [], "\(type): fields the promises' generator doesn't know; generate them or say why not")
            XCTAssertEqual(listed.subtracting(names).sorted(), [], "\(type): listed fields that no longer exist")
        }
    }

    // MARK: The promises

    /// Where things go in one case, with what the promises need to know about it.
    private struct Walked {
        let c: Case, walk: EngineWalk, deny: EngineWalk, config: String, denyConfig: String
        let shared: [String: String]

        func tag(_ route: String) -> String {
            route == DIRECT ? "direct" : c.setup.route(route)?.tsExit != nil ? Compiler.tsTag : shared[route] ?? "r-\(route)"
        }
        /// A connection from `program` to the public address, and to `name` (looked up first, as an app does).
        static func reach(_ w: EngineWalk, _ program: String?, name: String?) -> String {
            guard let name else { return w.connect(program, name: nil, ip: PromisesTests.publicIP) }
            let a = w.lookup(name, "A")
            if a == "server:fake" { return w.connect(program, name: name, ip: EngineWalk.fake) }
            return a.hasPrefix("server:") ? w.connect(program, name: nil, ip: PromisesTests.publicIP) : "none (\(a))"
        }
    }

    private func exits(_ outcome: String, _ tag: String) -> Bool { outcome.hasPrefix("exit:\(tag) ") }

    /// The address each WireGuard endpoint's first peer dials, by the endpoint's tag.
    private static func peerAddresses(_ config: String) -> [String: String] {
        let o = (try? JSONSerialization.jsonObject(with: Data(config.utf8))) as? [String: Any]
        return Dictionary((((o?["endpoints"] as? [[String: Any]]) ?? []).compactMap { e -> (String, String)? in
            guard let tag = e["tag"] as? String, let address = ((e["peers"] as? [[String: Any]])?.first)?["address"] as? String else { return nil }
            return (tag, address)
        })) { a, _ in a }
    }

    /// The names that can't take a website rule: devices on the own network, this Mac, address lookups, Tailscale's
    /// names and the tailnet's own domain.
    private static let privateZones = ["local", "lan", "home.arpa", "fritz.box", "internal", "localhost", "arpa", "ts.net"]
    private static func isPrivate(_ name: String, tailnet: String?) -> Bool {
        (privateZones + [tailnet].compactMap { $0 }).contains { name == $0 || name.hasSuffix("." + $0) }
    }

    func testThePromisesHoldOnEveryGeneratedSetup() throws {
        let engine = try ProviderFixtures.engine()
        var seen: [String: Int] = [:], refusals: [String] = []

        for (n, c) in Self.cases(300).enumerated() {
            // What came up in this setup, counted once per setup.
            var kinds: Set<String> = []
            func count(_ k: String) { kinds.insert(k) }
            defer { for k in kinds { seen[k, default: 0] += 1 } }
            let s = c.setup, i = c.input
            let config: String
            do { config = try Compiler.compile(i) } catch { refusals.append("\(c.label): \(error)"); continue }
            let denyConfig = try Compiler.denyAll(i)
            let shared = try Compiler.shared(s, LinkPicker.ported(s, i.links, step: [:]), blocked: i.blocked, tailnet: i.websiteDomain)
            let w = Walked(c: c, walk: try EngineWalk(config), deny: try EngineWalk(denyConfig), config: config, denyConfig: denyConfig, shared: shared)
            let applied = Sites.applied(s, tailnet: i.websiteDomain)
            let addresses = Self.peerAddresses(config)
            count("default:\(s.defaultRoute == DIRECT ? "direct" : "vpn")")
            if s.route(s.defaultRoute)?.tsExit != nil { count("default:tx") }
            if i.blocked.contains(s.defaultRoute) { count("default:blocked") }
            if Set(shared.values).count < shared.count { count("tunnel:shared") }
            if !applied.isEmpty { count("sites:applied") }
            if case .given = i.siteDomain { count("domain:given") }

            for app in Self.appKeys {
                // An app with no patterns (not on this Mac, not remembered) has no traffic to check.
                guard let route = s.apps[app], i.apps[app] != nil else { continue }
                let p = Self.program(app)
                for name in [nil, Self.plainName] {
                    let normal = Walked.reach(w.walk, p, name: name), denied = Walked.reach(w.deny, p, name: name)
                    let ctx = "\(app) on \(route) to \(name ?? Self.publicIP), \(c.label)"
                    switch route {
                    case BLOCK:
                        // P2 Block refuses: a blocked app's connections to anything public are refused, in every config.
                        XCTAssertEqual(normal, "reject", "P2 \(ctx)"); XCTAssertEqual(denied, "reject", "P2 deny \(ctx)")
                        count("app:block")
                    case DIRECT:
                        // P1 (Direct): a Direct app goes Direct, also after a failed change.
                        XCTAssertTrue(exits(normal, "direct"), "P1 direct \(ctx): \(normal)")
                        XCTAssertTrue(exits(denied, "direct"), "P5 direct \(ctx): \(denied)")
                        count("app:direct")
                    default:
                        if i.blocked.contains(route) {
                            // P2: an app on a route with no usable tunnel is refused, never sent elsewhere.
                            XCTAssertEqual(normal, "reject", "P2 no tunnel \(ctx)")
                            count("app:route-without-tunnel")
                        } else {
                            // P1 Apps keep their route: out on the route's own tunnel (the shared one, Tailscale for an
                            // exit route); never Direct, never another route, never refused while the tunnel is there.
                            XCTAssertTrue(exits(normal, w.tag(route)), "P1 \(ctx): \(normal), wanted \(w.tag(route))")
                            count(s.route(route)?.tsExit != nil ? "app:tx" : "app:vpn")
                        }
                        // P5 A failed change leaks nothing: an app on a VPN route is refused.
                        XCTAssertEqual(denied, "reject", "P5 \(ctx)")
                    }
                }
                // P1, read from the tunnel itself rather than its name: the tunnel an app's route goes out on dials that
                // route's own server.
                if !i.blocked.contains(route), s.route(route)?.tsExit == nil, case .wg(let sv, _, _, _)? = i.links[route] {
                    XCTAssertEqual(addresses[w.tag(route)], sv.ip, "P1 server of \(route) for \(app), \(c.label)")
                }
                // P1 (websites): a name with an applied website rule, and any name under it, follows the rule (a block
                // refuses, Direct goes Direct, a route its tunnel), whatever the app's route; a blocked app is refused
                // whatever it opens.
                for (site, to) in applied.sorted(by: { $0.key < $1.key }) {
                    for name in [site, "zz-check." + site] {
                        let normal = Walked.reach(w.walk, p, name: name), denied = Walked.reach(w.deny, p, name: name)
                        let ctx = "\(app) on \(route) opens \(name) (website \(site) on \(to)), \(c.label)"
                        if route == BLOCK || to == BLOCK || i.blocked.contains(to) {
                            XCTAssertEqual(normal, "reject", "P1 site \(ctx)")
                        } else {
                            XCTAssertTrue(exits(normal, w.tag(to)), "P1 site \(ctx): \(normal), wanted \(w.tag(to))")
                            count("site:followed")
                        }
                        // P5: after a failed change a website on a VPN route is refused, a Direct one goes Direct or is refused.
                        if to != DIRECT || route == BLOCK { XCTAssertEqual(denied, "reject", "P5 site \(ctx): \(denied)") }
                        else { XCTAssertTrue(exits(denied, "direct") || denied == "reject", "P5 direct site \(ctx): \(denied)") }
                    }
                }
            }
            // P1 (websites): a saved website whose rule doesn't apply is one that can't take a rule (a private name),
            // and never a block, which always applies.
            for (site, to) in s.sites where applied[site] == nil {
                XCTAssertNotEqual(to, BLOCK, "P1 unapplied block \(site), \(c.label)")
                XCTAssertTrue(Self.isPrivate(site, tailnet: i.websiteDomain), "P1 unapplied \(site), \(c.label)")
            }

            // P3 Programs nobody owns: refused under refusedWhileSplit whenever an app is blocked or (Direct default) any
            // app is on a VPN, under refusedWhileBlocking whenever an app is blocked; otherwise the default route. Apps
            // only remembered (not on this Mac) don't count.
            let live = s.apps.filter { !i.remembered.contains($0.key) && i.apps[$0.key] != nil }
            let blocking = live.values.contains { $0 == BLOCK || ($0 != s.defaultRoute && i.blocked.contains($0)) }
            let appsOnExits = live.values.contains { $0 != DIRECT && $0 != BLOCK && $0 != s.defaultRoute }
            let refuse = switch i.ownerless {
            case .followsDefault: false
            case .refusedWhileBlocking: blocking
            case .refusedWhileSplit: blocking || s.defaultRoute == DIRECT && appsOnExits
            }
            let nobody = Walked.reach(w.walk, nil, name: nil)
            if refuse || i.blocked.contains(s.defaultRoute) {
                XCTAssertEqual(nobody, "reject", "P3 \(c.label)")
                if !i.blocked.contains(s.defaultRoute) { count("ownerless:refused:\(i.ownerless)") }
                if i.ownerless == .refusedWhileSplit, !blocking { count("ownerless:split-only") }
            } else {
                XCTAssertTrue(exits(nobody, w.tag(s.defaultRoute)), "P3 \(c.label): \(nobody)"); count("ownerless:default")
            }
            // P5: a failed change refuses what nobody owns whenever the normal config does, and always with a VPN default.
            if nobody == "reject" || s.defaultRoute != DIRECT { XCTAssertEqual(Walked.reach(w.deny, nil, name: nil), "reject", "P5 ownerless \(c.label)") }

            // P4 Disguise never goes plain: every tunnel an IVPN route runs on goes through a V2Ray hop the config has;
            // without the hops the compile refuses.
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
            let endpoints = (parsed["endpoints"] as? [[String: Any]]) ?? []
            let ivpn = s.routes.filter { $0.loc.provider == "ivpn" }.map(\.id)
            if s.opt("ivpn", "disguise") == "on", ivpn.contains(where: { shared[$0] != nil }) {
                for r in ivpn { if let tag = shared[r] {
                    let hop = endpoints.first { $0["tag"] as? String == tag }?["detour"] as? String
                    XCTAssertTrue(hop.map { $0.hasPrefix("v2-") && w.walk.tags.contains($0) } == true, "P4 \(r) hop \(hop ?? "none"), \(c.label)")
                } }
                var plain = i
                for r in ivpn {
                    if case .wg(let sv, var peer, let ports, let entries)? = plain.links[r] { peer.disguise = nil; peer.vmess = nil; plain.links[r] = .wg(sv, peer, ports: ports, entries: entries) }
                }
                XCTAssertThrowsError(try Compiler.compile(plain), "P4 plain \(c.label)")
                count("disguise:on")
            }

            // P5: the deny-all config runs no tunnel, has only Direct outbounds, and built again from its own input is the same.
            let denyParsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(denyConfig.utf8)) as? [String: Any])
            XCTAssertEqual(((denyParsed["endpoints"] as? [[String: Any]]) ?? []).count, 0, "P5 tunnels \(c.label)")
            XCTAssertEqual(Set(((denyParsed["outbounds"] as? [[String: Any]]) ?? []).compactMap { $0["type"] as? String }), ["direct"], "P5 outbounds \(c.label)")
            XCTAssertEqual(try Compiler.denyAll(Compiler.denyAllInput(i)), denyConfig, "P5 again \(c.label)")

            // P6 Well formed: the extension's check and the pinned engine (a fixed sample) take both configs, and every
            // tag a rule, final, resolver or tunnel names exists.
            for (kind, text, walk) in [("normal", config, w.walk), ("deny-all", denyConfig, w.deny)] {
                XCTAssertNoThrow(try ConfigVet.check(text), "P6 \(kind) \(c.label)")
                XCTAssertEqual(Self.tagProblems(text, walk), [], "P6 \(kind) \(c.label)")
                if n % 15 == 0, let engine { XCTAssertNil(ProviderFixtures.engineRefusal(text, engine), "P6 engine \(kind) \(c.label)") }
            }

            // P7 Same input, same config: twice, and with the apps map built in the other order. (Within one run only:
            // a recorded config across runs is a later batch.)
            XCTAssertEqual(try Compiler.compile(i), config, "P7 \(c.label)")
            var reordered = i
            reordered.setup.apps = Dictionary(uniqueKeysWithValues: s.apps.sorted { $0.key > $1.key })
            reordered.apps = Dictionary(uniqueKeysWithValues: i.apps.sorted { $0.key > $1.key })
            XCTAssertEqual(try Compiler.compile(reordered), config, "P7 order \(c.label)")
            count("checked")
        }

        // A generator that tests nothing fails: each kind of case must come up in at least 5 setups, and no compile of a
        // generated setup may be refused (each is valid by construction).
        for k in ["default:direct", "default:vpn", "default:tx", "default:blocked", "tunnel:shared", "sites:applied", "app:block",
                  "app:direct", "app:vpn", "app:tx", "app:route-without-tunnel", "site:followed", "ownerless:refused:refusedWhileBlocking",
                  "ownerless:refused:refusedWhileSplit", "ownerless:split-only", "ownerless:default", "disguise:on", "domain:given"] {
            XCTAssertGreaterThanOrEqual(seen[k, default: 0], 5, "coverage: \(k) came up in \(seen[k, default: 0]) setups")
        }
        XCTAssertEqual(refusals, [], "compiles refused")
        XCTAssertGreaterThanOrEqual(seen["checked", default: 0], 290)
    }

    /// Every outbound, endpoint and resolver a rule, a final, a resolver or a tunnel's detour names is one the config defines.
    private static func tagProblems(_ config: String, _ w: EngineWalk) -> [String] {
        var problems: [String] = []
        for r in w.route { if let o = r["outbound"] as? String, !w.tags.contains(o) { problems.append("route rule to \(o)") }
            if r["action"] as? String == "resolve", let d = r["server"] as? String, !w.servers.contains(d) { problems.append("resolve on \(d)") } }
        for r in w.dns { if let d = r["server"] as? String, !w.servers.contains(d) { problems.append("dns rule to \(d)") } }
        if !w.routeFinal.isEmpty, !w.tags.contains(w.routeFinal) { problems.append("route final \(w.routeFinal)") }
        if !w.dnsFinal.isEmpty, !w.servers.contains(w.dnsFinal) { problems.append("dns final \(w.dnsFinal)") }
        let o = (try? JSONSerialization.jsonObject(with: Data(config.utf8))) as? [String: Any]
        for d in ((o?["dns"] as? [String: Any])?["servers"] as? [[String: Any]]) ?? [] {
            if let t = d["detour"] as? String, !w.tags.contains(t) { problems.append("resolver detour \(t)") }
            if let t = d["endpoint"] as? String, !w.tags.contains(t) { problems.append("resolver endpoint \(t)") }
        }
        for e in ((o?["endpoints"] as? [[String: Any]]) ?? []) + ((o?["outbounds"] as? [[String: Any]]) ?? []) {
            if let t = e["detour"] as? String, !w.tags.contains(t) { problems.append("tunnel detour \(t)") }
        }
        return problems
    }

    // MARK: Named cases (each one a setup that once broke, or could break, a promise)

    /// P6: a website that alone uses a Tailscale exit, judged by the input's tailnet domain where the saved setup holds
    /// another. Rules and tunnels follow the same domain: with the domain cleared the website takes the exit and the
    /// config runs Tailscale with that exit node; with the website's name inside the input's domain the rule doesn't
    /// apply and no exit runs for it.
    func testAWebsiteAloneOnATailscaleExitRunsTailscale() throws {
        func input(saved: String?, given: String?) -> Compiler.Input {
            var s = Setup(routes: [Route(id: "nl", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands")),
                                   Route(id: "tx", tsExit: "100.64.0.9", tsName: "exit")], defaultRoute: DIRECT)
            s.home.tailscale = false
            s.home.tsSuffix = saved
            s.home.tsSuffixConfirmed = true
            s.sites = ["nas.corp.example": "tx"]
            var i = Compiler.Input(setup: s, links: ["nl": .wg(Self.server("nl"), Nord.peer(Self.server("nl"), Self.key)), "tx": .ts(Self.server("tx"))],
                                   apps: [:], selfPattern: Compiler.pattern(forPath: Self.selfApp), tsSuffix: nil)
            i.siteDomain = .given(given)
            return i
        }
        func tailscale(_ config: String) throws -> [String: Any]? {
            let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
            return ((o["endpoints"] as? [[String: Any]]) ?? []).first { $0["tag"] as? String == Compiler.tsTag }
        }
        let engine = try ProviderFixtures.engine()
        // The domain cleared: the website applies, so its exit runs.
        let on = try Compiler.compile(input(saved: "corp.example", given: nil))
        let onWalk = try EngineWalk(on)
        XCTAssertEqual(Self.tagProblems(on, onWalk), [])
        XCTAssertNoThrow(try ConfigVet.check(on))
        if let engine { XCTAssertNil(ProviderFixtures.engineRefusal(on, engine)) }
        XCTAssertEqual(try tailscale(on)?["exit_node"] as? String, "100.64.0.9")
        XCTAssertTrue(onWalk.connect(Self.program("com.a"), name: "nas.corp.example", ip: EngineWalk.fake).hasPrefix("exit:\(Compiler.tsTag) "))
        // The name inside the input's domain: the website doesn't apply, and nothing starts an exit for it.
        let off = try Compiler.compile(input(saved: nil, given: "corp.example"))
        XCTAssertEqual(Self.tagProblems(off, try EngineWalk(off)), [])
        XCTAssertNoThrow(try ConfigVet.check(off))
        XCTAssertNil(try tailscale(off))
    }
}
