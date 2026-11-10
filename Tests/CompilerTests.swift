import XCTest

private typealias O = [String: Any]

final class CompilerTests: XCTestCase {
    func testTemporaryRouteCompilesAndPassesVet() throws {
        var s = example
        s.apps = [:]
        s.testing = ["us"]
        XCTAssertEqual(Set(s.activeRoutes.map(\.id)), ["nl", "us"])
        let config = try raw(s)
        XCTAssertNoThrow(try ConfigVet.check(config))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        XCTAssertTrue(((object["endpoints"] as? [[String: Any]]) ?? []).contains { ($0["tag"] as? String) == "r-us" })
    }

    func testProtectionModelAndMigration() throws {
        XCTAssertNil(Filter(id: "nextdns", value: "a-b").server)
        XCTAssertEqual(Filter(id: "nextdns", value: "abc123").server?.path, "/abc123")
        for value in ["http://x.org", "https://x.org:99999/q", "tls://x.org/path", "dns.example.org", "1.2.3", "https://a b", "https://x.org/q%", "https://x.org/q%GG", "https://.example.org/query"] {
            XCTAssertNil(FilterServer.own(value), value)
        }
        XCTAssertEqual(FilterServer.own("https://x.org/a%2Fb")?.path, "/a%2Fb")
        XCTAssertEqual(FilterServer.own("tls://dns.example.org")?.port, 853)
        let old = Data(#"{"prefs":{"customDns":["1.1.1.1"]}}"#.utf8)
        let setup = try JSONDecoder().decode(Setup.self, from: old)
        XCTAssertEqual(setup.prefs.filter, Filter(id: "own", value: "1.1.1.1", routes: true))
        XCTAssertTrue(setup.prefs.customDns.isEmpty)
        let restored = try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(setup))
        XCTAssertEqual(restored.prefs.filter, setup.prefs.filter)
        let peer = #"{"name":"old","privateKey":"k","address":["10.0.0.2/32"],"publicKey":"p","endpoint":"host:1","allowedIps":["0.0.0.0/0"]}"#
        let fixture = "{\"routes\":[{\"id\":\"x\",\"wg\":\(peer)}],\"home\":{\"wg\":\(peer)},\"servers\":[{\"id\":\"x\",\"wg\":\(peer)}]}"
        let oldSetup = try JSONDecoder().decode(Setup.self, from: Data(fixture.utf8))
        XCTAssertEqual(oldSetup.routes.first?.wg?.mtu, 1420)
        XCTAssertEqual(oldSetup.home.wg?.dns, [])
        XCTAssertEqual(oldSetup.servers.first?.wg?.mtu, 1420)
        XCTAssertEqual(try JSONDecoder().decode(WgPeer.self, from: Data(peer.utf8)).dns, [])
        let oldLink = "{\"wg\":{\"_0\":{\"name\":\"old\",\"host\":\"host\",\"ip\":\"1.2.3.4\",\"publicKey\":\"p\",\"load\":0,\"city\":\"\",\"country\":\"\"},\"_1\":\(peer)}}"
        guard case .wg(_, let cached, _, _) = try JSONDecoder().decode(Link.self, from: Data(oldLink.utf8)) else { return XCTFail("Expected WireGuard link") }
        XCTAssertEqual(cached.mtu, 1420)
    }

    func testProtectionPresetsAndScopes() throws {
        for preset in FilterServer.presets {
            var s = example
            s.prefs.filter = Filter(id: preset.id, value: preset.id == "nextdns" ? "abc123" : "", routes: true)
            let c = try compile(s)
            let server = try XCTUnwrap(dnsServer(c, "dns-r-nl"))
            XCTAssertEqual(server["type"] as? String, "https")
            XCTAssertEqual(server["server"] as? String, preset.address)
            XCTAssertEqual(server["detour"] as? String, "r-nl")
            XCTAssertEqual((server["tls"] as? O)?["server_name"] as? String, preset.tls)
        }
        var s = example
        s.defaultRoute = DIRECT
        s.prefs.filter = Filter(id: "quad9", direct: true, directApps: false, apps: ["com.x": true])
        let c = try compile(s)
        XCTAssertEqual((c["dns"] as? O)?["final"] as? String, "dns-filter")
        XCTAssertEqual(dnsServer(c, "dns-filter")?["type"] as? String, "https")
        XCTAssertTrue(rules(c).contains { action($0) == "resolve" && $0["server"] as? String == "dns-filter" && (($0["process_path_regex"] as? [String])?.contains(pat("com.x")) == true) })
        XCTAssertTrue(rules(c).contains { action($0) == "resolve" && $0["server"] as? String == "local" && (($0["process_path_regex"] as? [String])?.contains(pat("com.y")) == true) })
    }

    func testProtectionNamedServerBootAndVetReferences() throws {
        var s = example
        s.prefs.filter = Filter(id: "own", value: "tls://dns.example.org", routes: true)
        let c = try compile(s)
        let server = try XCTUnwrap(dnsServer(c, "dns-r-nl"))
        XCTAssertEqual(server["domain_resolver"] as? String, "boot-r-nl")
        XCTAssertEqual(dnsServer(c, "boot-r-nl")?["detour"] as? String, "r-nl")
        var bad = c
        var dns = try XCTUnwrap(bad["dns"] as? O)
        var servers = try XCTUnwrap(dns["servers"] as? [O])
        let index = try XCTUnwrap(servers.firstIndex { $0["tag"] as? String == "dns-r-nl" })
        servers[index]["domain_resolver"] = "local"
        dns["servers"] = servers; bad["dns"] = dns
        let bytes = try JSONSerialization.data(withJSONObject: bad)
        XCTAssertThrowsError(try ConfigVet.check(String(decoding: bytes, as: UTF8.self)))
    }

    private let key = "aGVsbG8taGVsbG8taGVsbG8taGVsbG8taGVsbG8tMTI="
    private let otherKey = "5p4RkybdRU5uaDi90eu4KZPTFif0lKCg4Qp6t1c4F30="
    private let selfApp = "/Applications/unbraid.app"

    private func sv(_ n: String) -> Server {
        let h = stableId(n)
        return Server(name: "\(n) #1", host: "\(n).nordvpn.com", ip: "10.9.\(h & 0xff).\(h >> 8 & 0xff)", publicKey: otherKey, load: 10)
    }

    private func nl() -> Route { Route(id: "nl", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands")) }

    /// Example setup: NL default, US for A, IT for B, X+Y direct, home over Tailscale.
    private var example: Setup {
        Setup(
            routes: [nl(),
                     Route(id: "us", loc: Location(countryId: 228, countryCode: "US", country: "United States"), hue: 1),
                     Route(id: "it", loc: Location(countryId: 106, countryCode: "IT", country: "Italy"), hue: 2)],
            defaultRoute: "nl",
            apps: ["com.a": "us", "com.b": "it", "com.x": DIRECT, "com.y": DIRECT],
            home: Home(tailscale: true, subnets: ["192.168.178.0/24"]))
    }

    private func links(_ s: Setup) -> [String: Link] {
        Dictionary(uniqueKeysWithValues: s.activeRoutes.map { r in
            if let w = r.wg { return (r.id, .wg(sv(r.id), w)) }
            if let p = r.ss { return (r.id, .ss(sv(r.id), p)) }
            if r.tsExit != nil { return (r.id, .ts(sv(r.id))) }
            return (r.id, .wg(sv(r.id), Nord.peer(sv(r.id), key)))
        })
    }

    /// What the app finds installed: every key in `setup.apps` is a bundle under /Applications.
    private func patterns(_ s: Setup) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: s.apps.keys.map { ($0, [Compiler.pattern(forPath: "/Applications/\($0).app")]) })
    }

    private func pat(_ app: String) -> String { Compiler.pattern(forPath: "/Applications/\(app).app") }

    func testBlockedTranslocationIsRejectedByCompiledConfig() throws {
        var s = example
        s.apps["com.blocked"] = BLOCK
        let path = "/Applications/Foo [1].app"
        let patterns = AppPaths.bundle([path]) + AppPaths.blockedTranslocations([path])
        var apps = self.patterns(s)
        apps["com.blocked"] = patterns
        let c = try compile(s, apps: apps)
        let image = "/private/var/folders/a/T/AppTranslocation/uuid/d/Foo [1].app/Contents/MacOS/Foo"
        XCTAssertTrue(rules(c).contains { action($0) == "reject" && AppPaths.matches(strings($0["process_path_regex"]), image) })
    }

    private func raw(_ s: Setup, links: [String: Link]? = nil, apps: [String: [String]]? = nil, remembered: Set<String> = [], tsSuffix: String? = nil,
                     probe: (port: Int, password: String)? = nil, ownerless: Compiler.Ownerless = .refusedWhileSplit, login: Bool = false) throws -> String {
        let config = try Compiler.compile(Compiler.Input(setup: s, links: links ?? self.links(s), apps: apps ?? patterns(s), remembered: remembered,
                                                         selfPattern: Compiler.pattern(forPath: selfApp), tsSuffix: tsSuffix, probe: probe, ownerless: ownerless, tsLoginPending: login))
        // Every config any test compiles must also be one the tunnel extension accepts, and the engine it ships.
        XCTAssertNoThrow(try ConfigVet.check(config), "the extension would refuse this config")
        if let engine = try ProviderFixtures.engine() {
            let refusal = ProviderFixtures.engineRefusal(config, engine)
            XCTAssertNil(refusal, "sing-box 1.14.4 refuses this config: \(refusal ?? "")")
        }
        XCTAssertEqual(try tagProblems(parse(config)), [])
        return config
    }

    /// The engine's `check` never starts the config, so a rule naming a tunnel or resolver that doesn't exist (which the
    /// engine skips, or refuses at connect) would pass it: every tag a config names must be one it defines, and a resolver
    /// inside a tunnel must name an endpoint of that tunnel's kind.
    private func tagProblems(_ c: O) -> [String] {
        let endpointTypes = Dictionary(endpoints(c).compactMap { e in (e["tag"] as? String).map { ($0, e["type"] as? String ?? "") } }) { a, _ in a }
        let ways = Set(endpointTypes.keys).union(((c["outbounds"] as? [O]) ?? []).compactMap { $0["tag"] as? String })
        let resolvers = Set(dnsServers(c).compactMap { $0["tag"] as? String })
        var problems: [String] = []
        for r in rules(c) {
            if let o = outbound(r), !ways.contains(o) { problems.append("route rule to \(o)") }
            if action(r) == "resolve", let d = r["server"] as? String, !resolvers.contains(d) { problems.append("resolve on \(d)") }
        }
        if let f = final(c), !ways.contains(f) { problems.append("route final \(f)") }
        for r in dnsRules(c) { if let d = r["server"] as? String, !resolvers.contains(d) { problems.append("dns rule to \(d)") } }
        if let f = (c["dns"] as? O)?["final"] as? String, !resolvers.contains(f) { problems.append("dns final \(f)") }
        for d in dnsServers(c) {
            if let t = d["detour"] as? String, !ways.contains(t) { problems.append("resolver detour \(t)") }
            if let t = d["endpoint"] as? String {
                let wanted = ["openvpn": "openvpn-client", "tailscale": "tailscale"][d["type"] as? String ?? ""]
                if endpointTypes[t] == nil || endpointTypes[t] != wanted { problems.append("resolver endpoint \(t)") }
            }
        }
        return problems
    }

    private func compile(_ s: Setup, links: [String: Link]? = nil, apps: [String: [String]]? = nil, tsSuffix: String? = nil, probe: (port: Int, password: String)? = nil, login: Bool = false) throws -> O {
        try parse(raw(s, links: links, apps: apps, tsSuffix: tsSuffix, probe: probe, login: login))
    }

    private func parse(_ text: String) throws -> O { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? O) }

    private func rules(_ c: O) -> [O] { ((c["route"] as? O)?["rules"] as? [O]) ?? [] }
    private func dnsRules(_ c: O) -> [O] { ((c["dns"] as? O)?["rules"] as? [O]) ?? [] }
    private func dnsServers(_ c: O) -> [O] { ((c["dns"] as? O)?["servers"] as? [O]) ?? [] }
    private func dnsServer(_ c: O, _ tag: String) -> O? { dnsServers(c).first { $0["tag"] as? String == tag } }
    private func endpoints(_ c: O) -> [O] { (c["endpoints"] as? [O]) ?? [] }
    private func endpointTags(_ c: O) -> [String] { endpoints(c).compactMap { $0["tag"] as? String } }
    private func tun(_ c: O) -> O { ((c["inbounds"] as? [O]) ?? [])[0] }
    private func final(_ c: O) -> String? { (c["route"] as? O)?["final"] as? String }
    private func outbound(_ r: O) -> String? { r["outbound"] as? String }
    private func action(_ r: O) -> String? { r["action"] as? String }

    /// A deny-all config: checked like any other (the extension and the engine take it), with no tunnel and no
    /// credentials, apps on a VPN refused, Direct apps and unbraid direct.
    private func denyAll(_ s: Setup, apps: [String: [String]]? = nil) throws -> O {
        let config = try Compiler.denyAll(Compiler.Input(setup: s, links: links(s), apps: apps ?? patterns(s), selfPattern: Compiler.pattern(forPath: selfApp),
                                                         tsSuffix: "tail123.ts.net", probe: (4000, "pw")))
        XCTAssertNoThrow(try ConfigVet.check(config), "the extension would refuse this config")
        if let engine = try ProviderFixtures.engine() {
            let refusal = ProviderFixtures.engineRefusal(config, engine)
            XCTAssertNil(refusal, "sing-box 1.14.4 refuses this config: \(refusal ?? "")")
        }
        XCTAssertEqual(try tagProblems(parse(config)), [])
        XCTAssertFalse(config.contains(key) || config.contains("private_key") || config.contains("pw"), "no credentials")
        return try parse(config)
    }

    /// The auth key goes into the configuration only until the node is enrolled; a record keeps it no longer either.
    func testTheAuthKeyStaysOutOnceEnrolled() throws {
        var s = example
        s.home.tsAuthKey = "tskey-auth-secret"
        XCTAssertEqual(try endpoints(compile(s)).first { $0["type"] as? String == "tailscale" }?["auth_key"] as? String, "tskey-auth-secret")
        s.home.tsEnrolled = "id1"
        let ts = try XCTUnwrap(endpoints(compile(s)).first { $0["type"] as? String == "tailscale" })
        XCTAssertNil(ts["auth_key"])
        XCTAssertFalse(try raw(s).contains("tskey-auth-secret"))
        XCTAssertNil(Running.recorded(s).home.tsAuthKey)
        s.home.tsEnrolled = nil
        XCTAssertEqual(Running.recorded(s).home.tsAuthKey, "tskey-auth-secret")
        // Older setups have no enrolment: none.
        XCTAssertNil(try JSONDecoder().decode(Home.self, from: Data(#"{"tailscale":true,"tsAuthKey":"k"}"#.utf8)).tsEnrolled)
    }

    private func on(_ r: O, _ app: String) -> Bool { (r["process_path_regex"] as? [String])?.contains(pat(app)) == true }

    func testOfflinePolicyRejectsAppsLeavingDirectAndNewBlocksBeforeLookup() async throws {
        var old = example
        old.defaultRoute = DIRECT
        old.apps = ["com.x": DIRECT, "com.y": DIRECT]
        for change in 0..<3 {
            var s = old
            if change == 0 { s.apps["com.x"] = "nl" }
            if change == 1 { s.defaultRoute = "nl"; s.apps["com.x"] = nil }
            if change == 2 { s.apps["com.x"] = BLOCK; s.apps["com.a"] = "nl" }
            XCTAssertTrue(LinkPicker.needsInterim(from: old, to: s))
            let picked = try await LinkPicker.pick(s, keep: [:], applied: old, appliedAccounts: [:],
                accounts: ["nord": "acc"], last: [:], offline: true, providers: Providers.get)
            XCTAssertEqual(picked.blocked["nl"], .waiting)
            XCTAssertTrue(picked.links.isEmpty)
            let input = Compiler.Input(setup: s, links: picked.links, blocked: Set(picked.blocked.keys),
                apps: patterns(s), selfPattern: Compiler.pattern(forPath: selfApp), tsSuffix: nil)
            let json = try Compiler.compile(input)
            XCTAssertNoThrow(try ConfigVet.check(json))
            if let engine = try ProviderFixtures.engine() { XCTAssertNil(ProviderFixtures.engineRefusal(json, engine)) }
            let c = try parse(json)
            if change == 1 {
                XCTAssertTrue(rules(c).contains { on($0, "com.y") && outbound($0) == "direct" })
                XCTAssertTrue(rules(c).contains { $0 as NSDictionary == ["action": "reject", "no_drop": true] as NSDictionary })
                XCTAssertEqual(dnsRules(c).last?["rcode"] as? String, "REFUSED")
            } else {
                XCTAssertEqual((c["route"] as? O)?["final"] as? String, "direct")
                XCTAssertFalse(rules(c).contains { on($0, "com.y") && action($0) == "reject" })
                XCTAssertTrue(rules(c).contains { on($0, "com.x") && action($0) == "reject" })
                XCTAssertTrue(dnsRules(c).contains { on($0, "com.x") && $0["rcode"] as? String == "REFUSED" })
            }
            XCTAssertFalse(rules(c).contains { on($0, "com.x") && outbound($0) == "direct" })
        }
    }

    func testBlockedRoutesRefuseTheirAppsAndBlockedDefault() throws {
        for blocked: Set<String> in [["us"], ["nl"]] {
            let s = example
            let input = Compiler.Input(setup: s, links: links(s).filter { !blocked.contains($0.key) }, blocked: blocked,
                                       apps: patterns(s), selfPattern: Compiler.pattern(forPath: selfApp), tsSuffix: nil)
            let json = try Compiler.compile(input)
            XCTAssertNoThrow(try ConfigVet.check(json))
            if let engine = try ProviderFixtures.engine() { XCTAssertNil(ProviderFixtures.engineRefusal(json, engine)) }
            let c = try parse(json)
            XCTAssertEqual(tagProblems(c), [])
            XCTAssertFalse(endpointTags(c).contains("r-\(blocked.first!)"))
            if blocked.contains("us") {
                XCTAssertTrue(rules(c).contains { on($0, "com.a") && action($0) == "reject" && $0["no_drop"] as? Bool == true })
                XCTAssertTrue(dnsRules(c).contains { on($0, "com.a") && $0["rcode"] as? String == "REFUSED" })
            } else {
                let direct = try XCTUnwrap(rules(c).firstIndex { on($0, "com.x") && outbound($0) == "direct" })
                let refusal = try XCTUnwrap(rules(c).firstIndex { $0 as NSDictionary == ["action": "reject", "no_drop": true] as NSDictionary })
                XCTAssertLessThan(direct, refusal)
                XCTAssertTrue(rules(c)[..<refusal].contains { outbound($0) == "home-ts" })
                XCTAssertEqual(dnsRules(c).last?["rcode"] as? String, "REFUSED")
            }
        }
    }

    /// Block is not a default route: a setup that has it as one is refused, never compiled to Direct (nothing routed) or
    /// to tunnels and resolvers that don't exist (an app on a VPN). A failed change still refuses everything.
    func testBlockAsTheDefaultRouteIsRefused() throws {
        for apps: [String: String] in [[:], ["com.a": "us"]] {
            var s = example
            s.defaultRoute = BLOCK; s.apps = apps
            let input = Compiler.Input(setup: s, links: links(s), apps: patterns(s), selfPattern: Compiler.pattern(forPath: selfApp), tsSuffix: nil)
            XCTAssertThrowsError(try Compiler.compile(input)) { XCTAssertEqual($0.localizedDescription, "Block can't be the default route. Make Direct or a VPN route the default.") }
            XCTAssertThrowsError(try Compiler.probeDNS(input))
            XCTAssertTrue(rules(try denyAll(s)).contains { $0 as NSDictionary == ["action": "reject", "no_drop": true] as NSDictionary })
        }
    }

    func testDenyAllBlocksVpnAppsAndEverythingElseWithAVpnDefault() throws {
        var s = example
        s.apps["com.blocked"] = BLOCK
        let c = try denyAll(s)
        XCTAssertEqual(endpoints(c).count, 0)
        XCTAssertEqual((c["outbounds"] as? [O])?.compactMap { $0["type"] as? String }, ["direct"])
        XCTAssertEqual(final(c), "direct")
        // Every app on a VPN is refused like a blocked one, its lookups too.
        for app in ["com.a", "com.b", "com.blocked"] {
            XCTAssertTrue(rules(c).contains { action($0) == "reject" && $0["port"] == nil && on($0, app) }, app)
            XCTAssertTrue(dnsRules(c).contains { $0["rcode"] as? String == "REFUSED" && on($0, app) }, app)
        }
        // Direct apps and unbraid itself leave direct, before the catch-all that refuses the rest.
        let direct = try XCTUnwrap(rules(c).firstIndex { outbound($0) == "direct" && on($0, "com.x") })
        let me = try XCTUnwrap(rules(c).firstIndex { outbound($0) == "direct" && on($0, "unbraid") })
        let refuse = try XCTUnwrap(rules(c).firstIndex { $0 as NSDictionary == ["action": "reject", "no_drop": true] as NSDictionary })
        XCTAssertLessThan(max(direct, me), refuse)
        XCTAssertEqual(try XCTUnwrap(dnsRules(c).last) as NSDictionary, ["action": "predefined", "rcode": "REFUSED"] as NSDictionary)
        // Neither the tailnet nor its domain: no tunnel to reach them, and its names aren't asked of the local resolver.
        XCTAssertNil(dnsServer(c, "dns-tailnet"))
        XCTAssertTrue(dnsRules(c).contains { $0["rcode"] as? String == "NXDOMAIN" && ($0["domain_suffix"] as? [String]) == ["tail123.ts.net"] })
        // Nothing is resolved for what no app rule claims: the refusal comes first.
        let catchAll = rules(c).count - 1 - (rules(c).reversed().firstIndex { $0 as NSDictionary == ["action": "reject", "no_drop": true] as NSDictionary } ?? 0)
        XCTAssertFalse(rules(c)[..<catchAll].contains { action($0) == "resolve" && $0["process_path_regex"] == nil && $0["inbound"] == nil })
        // Built again from its own input, it is the same.
        let full = Compiler.Input(setup: s, links: links(s), apps: patterns(s), selfPattern: Compiler.pattern(forPath: selfApp), tsSuffix: "tail123.ts.net",
                                  probe: (4000, "pw"))
        let blocking = Compiler.denyAllInput(full)
        XCTAssertEqual(blocking.setup.routes, [])
        XCTAssertTrue(blocking.links.isEmpty)
        XCTAssertNil(blocking.probe)
        XCTAssertEqual(try Compiler.denyAll(blocking), try Compiler.denyAll(full))
    }

    /// A deny-all put back after another failure is the one of the setup as it is now, not the first one again: an app
    /// moved from Direct to a VPN route meanwhile is blocked with the others.
    func testADenyAllPutBackFollowsTheSetupAsItIsNow() throws {
        func input(_ s: Setup) -> Compiler.Input {
            Compiler.Input(setup: s, links: links(s), apps: patterns(s), selfPattern: Compiler.pattern(forPath: selfApp), tsSuffix: "tail123.ts.net")
        }
        let s = example
        let running = try Compiler.denyAll(input(s))
        var moved = s
        moved.apps["com.x"] = "us"
        // What a put-back used to run: the first deny-all, built again from its own input.
        let again = try Compiler.denyAll(Compiler.denyAllInput(input(s)))
        XCTAssertEqual(again, running)
        let fresh = try denyAll(moved)
        XCTAssertTrue(rules(fresh).contains { action($0) == "reject" && on($0, "com.x") })
        XCTAssertFalse(rules(try parse(again)).contains { action($0) == "reject" && on($0, "com.x") })
        let text = try Compiler.denyAll(input(moved)), old = (json: running, search: "tail123.ts.net")
        XCTAssertTrue(Lifecycle.reblock(blocking: true, held: false, running: old, fresh: (text, "tail123.ts.net")))
        // Not without a deny-all running, never from stand-ins, and not when nothing changed.
        XCTAssertFalse(Lifecycle.reblock(blocking: false, held: false, running: old, fresh: (text, "tail123.ts.net")))
        XCTAssertFalse(Lifecycle.reblock(blocking: true, held: true, running: old, fresh: (text, "tail123.ts.net")))
        XCTAssertFalse(Lifecycle.reblock(blocking: true, held: false, running: old, fresh: old))
        XCTAssertFalse(Lifecycle.reblock(blocking: true, held: false, running: old, fresh: nil))
        // The search domain alone (the tailnet left the setup meanwhile): put in place too.
        XCTAssertTrue(Lifecycle.reblock(blocking: true, held: false, running: old, fresh: (running, "")))
        // Back from VPN to Direct: the app goes direct again.
        XCTAssertFalse(rules(try parse(Compiler.denyAll(input(s)))).contains { action($0) == "reject" && on($0, "com.x") })
    }

    /// A pause and a deny-all run without the home, but keep the tailnet's search domain while the user's setup has a
    /// Tailscale home: short tailnet names expand to it and are refused, not asked of the local network.
    func testAPauseKeepsTheTailnetsSearchDomain() throws {
        let paused = Setup(routes: [], defaultRoute: DIRECT, apps: ["com.a": BLOCK], favorites: [])
        let input = Compiler.Input(setup: paused, links: [:], apps: patterns(paused), selfPattern: Compiler.pattern(forPath: selfApp), tsSuffix: "tail123.ts.net")
        XCTAssertEqual(Compiler.searchDomain(input), "")
        XCTAssertEqual(Compiler.searchDomain(input, tailnet: true), "tail123.ts.net")
        XCTAssertEqual(Compiler.searchDomain(input, tailnet: false), "")
        let c = try parse(raw(paused, links: [:], tsSuffix: "tail123.ts.net"))
        XCTAssertTrue(dnsRules(c).contains { $0["rcode"] as? String == "NXDOMAIN" && ($0["domain_suffix"] as? [String]) == ["tail123.ts.net"] })
        XCTAssertNil(dnsServer(c, "dns-tailnet"))
        let blocking = Compiler.denyAllInput(Compiler.Input(setup: example, links: links(example), apps: patterns(example),
                                                            selfPattern: Compiler.pattern(forPath: selfApp), tsSuffix: "tail123.ts.net"))
        XCTAssertEqual(Compiler.searchDomain(blocking), "")
        XCTAssertEqual(Compiler.searchDomain(blocking, tailnet: true), "tail123.ts.net")
    }

    /// No app has a route of its own: everything is refused, apart from unbraid and the local network as far as Settings
    /// allow blocked apps it.
    func testDenyAllWithoutAppsRefusesEverythingElse() throws {
        var s = example
        s.apps = [:]
        let c = try denyAll(s)
        XCTAssertTrue(rules(c).contains { $0 as NSDictionary == ["action": "reject", "no_drop": true] as NSDictionary })
        XCTAssertTrue(rules(c).contains { outbound($0) == "direct" && on($0, "unbraid") })
    }

    /// The "failed twice" deny-all with a VPN default, at the kill switch's home level with LAN access on: an app with no
    /// rule of its own follows the VPN default and is kept off the home network, its own lookups included, as a blocked
    /// app is. Direct apps, unbraid, the system resolver and traffic without a program keep them. At the Internet level,
    /// where blocked apps keep the home network, and outside a deny-all, nothing changes.
    func testDenyAllKeepsAppsFollowingAVpnDefaultOffTheHomeNetworkAtTheHomeLevel() throws {
        func matches(_ r: O, _ process: String?, _ ip: String, _ port: Int, _ udp: Bool) -> Bool {
            if r["type"] as? String == "logical" { return ((r["rules"] as? [O]) ?? []).allSatisfy { matches($0, process, ip, port, udp) } != (r["invert"] as? Bool == true) }
            var hit = r["inbound"] == nil && r["auth_user"] == nil && r["ip_version"] == nil && r["domain_suffix"] == nil
            if let proto = r["protocol"] as? String { hit = hit && proto == "dns" && port == 53 }
            let network = udp ? "udp" : "tcp"
            if let n = r["network"] as? [String] { hit = hit && n.contains(network) } else if let n = r["network"] as? String { hit = hit && n == network }
            if let ports = r["port"] as? [Int] { hit = hit && ports.contains(port) } else if let p = r["port"] as? Int { hit = hit && p == port }
            if let cidrs = r["ip_cidr"] as? [String] {
                hit = hit && cidrs.contains { c in !c.contains(":") && Compiler.canonical(c).map { Compiler.canonical("\(ip)/\($0.split(separator: "/")[1])") == $0 } == true }
            }
            if let patterns = r["process_path_regex"] as? [String] {
                hit = hit && process.map { p in patterns.contains { (try? NSRegularExpression(pattern: $0))?.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)) != nil } } == true
            }
            return hit != (r["invert"] as? Bool == true)
        }
        // What decides a connection: its outbound, "reject", or "hijack-dns" (handed to the DNS rules).
        func connect(_ c: O, from process: String?, to ip: String, port: Int = 443, udp: Bool = false) -> String? {
            for r in rules(c) where matches(r, process, ip, port, udp) {
                if let o = outbound(r) { return o }
                if action(r) == "reject" || action(r) == "hijack-dns" { return action(r) }
            }
            return final(c)
        }
        func refusesOthers(_ c: O) -> Bool {
            rules(c).contains { r in let f = (r["rules"] as? [O])?.first; return f?["process_path_regex"] as? [String] == ["."] && f?["invert"] == nil }
        }
        let other = path("com.other"), router = "192.168.178.1", resolver = "/usr/sbin/mDNSResponder"
        let unbraid = selfApp + "/Contents/MacOS/unbraid"
        var s = example
        s.prefs.lan = true
        s.prefs.killLevel = .home
        let home = try denyAll(s)
        XCTAssertTrue(refusesOthers(home))
        XCTAssertEqual(connect(home, from: other, to: router), "reject")
        XCTAssertEqual(connect(home, from: other, to: router, port: 53, udp: true), "reject")
        XCTAssertEqual(connect(home, from: other, to: "203.0.113.1"), "reject")
        XCTAssertEqual(connect(home, from: path("com.a"), to: router), "reject")
        XCTAssertEqual(connect(home, from: path("com.x"), to: router), "direct")
        XCTAssertEqual(connect(home, from: path("com.x"), to: router, port: 53, udp: true), "hijack-dns")
        XCTAssertEqual(connect(home, from: path("com.x"), to: "203.0.113.1"), "direct")
        XCTAssertEqual(connect(home, from: unbraid, to: router), "direct")
        XCTAssertEqual(connect(home, from: unbraid, to: "203.0.113.1"), "direct")
        XCTAssertEqual(connect(home, from: resolver, to: router, port: 53, udp: true), "hijack-dns")
        XCTAssertEqual(connect(home, from: resolver, to: "224.0.0.251", port: 5353, udp: true), "direct")
        XCTAssertEqual(connect(home, from: nil, to: router), "direct")
        XCTAssertEqual(connect(home, from: nil, to: router, port: 53, udp: true), "hijack-dns")
        // At the Internet level blocked apps keep the home network: so do apps following the default, as before.
        s.home = Home()
        s.prefs.killLevel = .internet
        let internet = try denyAll(s)
        XCTAssertFalse(refusesOthers(internet))
        XCTAssertEqual(connect(internet, from: other, to: router), "direct")
        XCTAssertEqual(connect(internet, from: other, to: router, port: 53, udp: true), "hijack-dns")
        XCTAssertEqual(connect(internet, from: other, to: "203.0.113.1"), "reject")
        // Outside a deny-all, nothing changes either.
        s.prefs.killLevel = .home
        XCTAssertFalse(refusesOthers(try compile(s)))
    }

    func testDenyAllWithDirectAsTheDefaultBlocksOnlyVpnApps() throws {
        var s = example
        s.defaultRoute = DIRECT
        let c = try denyAll(s)
        XCTAssertEqual(final(c), "direct")
        XCTAssertFalse(rules(c).contains { $0 as NSDictionary == ["action": "reject", "no_drop": true] as NSDictionary })
        XCTAssertTrue(rules(c).contains { action($0) == "reject" && on($0, "com.a") })
        XCTAssertFalse(rules(c).contains { on($0, "com.x") && action($0) == "reject" })
        XCTAssertFalse(dnsRules(c).contains { $0["process_path_regex"] == nil && $0["rcode"] as? String == "REFUSED" })
    }

    /// The tailnet's domain goes with the configuration only while the tailnet is reached, and only in a form the extension
    /// takes; otherwise none, never left to the VPN profile.
    func testTheSearchDomainIsExplicit() {
        func search(_ s: Setup, _ suffix: String?) -> String {
            Compiler.searchDomain(Compiler.Input(setup: s, links: [:], apps: [:], selfPattern: "", tsSuffix: suffix))
        }
        var s = example
        XCTAssertEqual(search(s, "Tail123.TS.net."), "tail123.ts.net")
        XCTAssertEqual(search(s, nil), "")
        XCTAssertEqual(search(s, "co.uk"), "")
        XCTAssertEqual(search(s, "a-.example.com"), "")
        s.home.tailscale = false
        XCTAssertEqual(search(s, "tail123.ts.net"), "")
    }
    private func cidrs(_ r: O) -> [String]? { r["ip_cidr"] as? [String] }
    private func paths(_ r: O) -> [String]? { r["process_path_regex"] as? [String] }
    private func strings(_ v: Any?) -> [String] { (v as? [String]) ?? [] }
    private func exitNodeEndpoint(_ c: O) -> O? { endpoints(c).first { $0["type"] as? String == "tailscale" } }

    /// Rules that send an app's connections somewhere, as the patterns they match; the rule for unbraid itself excluded.
    private func appRules(_ c: O) -> [O] { rules(c).filter { paths($0) != nil && paths($0) != [Compiler.pattern(forPath: selfApp)] } }
    private func firstAppRule(_ rs: [O]) -> Int? { rs.firstIndex { paths($0) != nil && paths($0) != [Compiler.pattern(forPath: selfApp)] } }
    private func routes(_ c: O, to tag: String, for app: String) -> Bool {
        rules(c).contains { outbound($0) == tag && paths($0)?.contains(pat(app)) == true }
    }

    // MARK: - Ported from CompilerTest.kt

    /// A new probe pair always changes the config (so every engine start gets one), the same pair never.
    func testTheProbePairIsPartOfTheConfig() throws {
        let a = try raw(example, probe: (41001, "pw-one"))
        XCTAssertEqual(a, try raw(example, probe: (41001, "pw-one")))
        XCTAssertNotEqual(a, try raw(example, probe: (41001, "pw-two")))
        XCTAssertNotEqual(a, try raw(example, probe: (41002, "pw-one")))
        let inbounds = try XCTUnwrap(parse(a)["inbounds"] as? [O])
        let probe = try XCTUnwrap(inbounds.first { $0["tag"] as? String == Compiler.probeTag })
        XCTAssertEqual(probe["listen"] as? String, "127.0.0.1")
        let users = try XCTUnwrap(probe["users"] as? [O])
        XCTAssertFalse(users.isEmpty)
        XCTAssertTrue(users.allSatisfy { $0["password"] as? String == "pw-one" })
        // When STUN fails everywhere, the HTTPS health fallback must authenticate and resolve directly.
        XCTAssertTrue(users.contains { $0["username"] as? String == "direct" })
        let direct = rules(try parse(a)).filter { strings($0["auth_user"]) == ["direct"] }
        XCTAssertEqual(direct.count, 2)
        XCTAssertTrue(direct.allSatisfy { $0["inbound"] as? String == Compiler.probeTag })
        XCTAssertEqual(action(direct[0]), "resolve")
        XCTAssertEqual(direct[0]["server"] as? String, "local")
        XCTAssertEqual(outbound(direct[1]), "direct")
        let none = try XCTUnwrap(compile(example)["inbounds"] as? [O])
        XCTAssertTrue(none.allSatisfy { $0["tag"] as? String != Compiler.probeTag })
        let directOnly = try XCTUnwrap(compile(Setup(routes: [], defaultRoute: DIRECT), probe: (41001, "pw-one"))["inbounds"] as? [O])
        XCTAssertTrue(directOnly.allSatisfy { $0["tag"] as? String != Compiler.probeTag })
    }

    func testUnspecifiedAddressesAreRefusedAfterEveryResolve() throws {
        var s = example
        s.prefs.filter = Filter(id: "quad9", routes: true)
        let json = try raw(s, probe: (41001, "password"))
        let rs = rules(try parse(json))
        let resolves = rs.indices.filter { action(rs[$0]) == "resolve" }
        XCTAssertGreaterThan(resolves.count, 1)
        for i in resolves {
            let next = try XCTUnwrap(rs.dropFirst(i + 1).first)
            XCTAssertEqual(strings(next["ip_cidr"]), ["0.0.0.0/32", "::/128"])
            XCTAssertEqual(action(next), "reject")
            XCTAssertEqual(next["no_drop"] as? Bool, true)
        }
        XCTAssertNoThrow(try ConfigVet.check(json))
        let engine = try XCTUnwrap(ProviderFixtures.engine())
        XCTAssertNil(ProviderFixtures.engineRefusal(json, engine))
    }

    func testExampleRoutesEachAppToItsExit() throws {
        let c = try compile(example)
        XCTAssertEqual(endpointTags(c), ["r-nl", "r-us", "r-it", "home-ts"])
        XCTAssertEqual(final(c), "r-nl")
        var routed: [String: [String]] = [:]
        for r in rules(c) where outbound(r) != nil && outbound(r) != "direct" && paths(r) != nil { routed[outbound(r)!] = paths(r) }
        XCTAssertEqual(routed, ["r-it": [pat("com.b")], "r-us": [pat("com.a")]])
    }

    func testHomeBeatsLanAndAppRules() throws {
        let c = try compile(example)
        let rs = rules(c)
        let home = try XCTUnwrap(rs.firstIndex { outbound($0) == "home-ts" })
        let lan = try XCTUnwrap(rs.firstIndex { outbound($0) == "direct" && $0["ip_cidr"] != nil })
        let app = try XCTUnwrap(firstAppRule(rs))
        XCTAssertTrue(home < lan && lan < app)
        XCTAssertTrue(strings(rs[home]["ip_cidr"]).contains("192.168.178.0/24"))
    }

    func testUnusedRoutesDoNotConnect() throws {
        var s = example
        s.apps = ["com.a": "us"]
        XCTAssertEqual(endpointTags(try compile(s)), ["r-nl", "r-us", "home-ts"])
    }

    func testDirectDefaultTunnelsOnlyAssignedApps() throws {
        var s = example
        s.defaultRoute = DIRECT
        s.home = Home()
        let c = try compile(s)
        XCTAssertEqual(final(c), "direct")
        XCTAssertEqual(endpointTags(c), ["r-us", "r-it"])
    }

    func testHttpsLookupsThroughTheSystemResolverNeverReachTheIsp() throws {
        // With apps on their own exits and Direct as the default, HTTPS and SVCB lookups that match no app (one per site a
        // browser opens) are answered empty rather than asked of the ISP's resolver; an app on a VPN keeps its own.
        var s = example
        s.defaultRoute = DIRECT
        s.home = Home()
        let c = try compile(s)
        XCTAssertEqual(dnsRules(c).filter { strings($0["query_type"]) == ["HTTPS", "SVCB"] }.count, 1)
        for type in ["HTTPS", "SVCB"] {
            XCTAssertEqual(lookup(c, type, "example.com", from: mDNSResponder), "NOERROR")
            XCTAssertEqual(lookup(c, type, "example.com", from: nil), "NOERROR")
            XCTAssertEqual(lookup(c, type, "example.com", from: path("com.x")), "NOERROR")
            XCTAssertEqual(lookup(c, type, "example.com", from: path("com.a")), "dns-r-us")
        }
        // Nothing on its own exit: nothing to keep apart, so no rule.
        let none = try compile(Setup(routes: [], defaultRoute: DIRECT), links: [:])
        XCTAssertFalse(dnsRules(none).contains { strings($0["query_type"]) == ["HTTPS", "SVCB"] })
        // Apps on an exit that aren't installed here match nothing: no rule either.
        XCTAssertFalse(dnsRules(try compile(s, apps: ["com.x": [pat("com.x")]])).contains { strings($0["query_type"]) == ["HTTPS", "SVCB"] })
        // With a VPN as the default they reach its resolver: never the ISP's.
        XCTAssertFalse(dnsRules(try compile(example)).contains { strings($0["query_type"]) == ["HTTPS", "SVCB"] })
        XCTAssertEqual(lookup(try compile(example), "HTTPS", "example.com", from: mDNSResponder), "dns-r-nl")
    }

    func testTailnetSuffixMustNotBeATopLevelOrPublicSuffix() {
        XCTAssertEqual(Compiler.tsSuffix("tail1234.ts.net."), "tail1234.ts.net")
        XCTAssertEqual(Compiler.tsSuffix("corp.example"), "corp.example")
        XCTAssertEqual(Compiler.tsSuffix("my-net.corp.example"), "my-net.corp.example")
        for bad in ["com", "COM.", "co.uk", "com.au", "ts.net", "", nil, "a..example", "-a.example", "a-.example", "a.-b.example",
                    "a_b.example", "x.example\"", "\(String(repeating: "a", count: 64)).example"] {
            XCTAssertNil(Compiler.tsSuffix(bad), "\(bad ?? "nil")")
        }
    }

    /// Tailscale's own tailnet domain is used as reported; any other only once the user accepts it, and a different one
    /// reported later stops the accepted one (and is offered in turn).
    func testOnlyTailscalesOwnTailnetDomainIsUsedWithoutAsking() throws {
        XCTAssertTrue(Compiler.tsSuffixIsTailscales("tail1234.ts.net"))
        XCTAssertTrue(Compiler.tsSuffixIsTailscales("a.b.ts.net"))
        XCTAssertFalse(Compiler.tsSuffixIsTailscales("evil-ts.net.example"))
        XCTAssertFalse(Compiler.tsSuffixIsTailscales("xts.net"))
        func change(_ reported: String?, _ accepted: String?) -> [String?] {
            let r = Store.tsSuffix(reported: reported, accepted: accepted)
            return [r.accepted, r.offered]
        }
        XCTAssertEqual(change("Tail1234.ts.net.", nil), ["tail1234.ts.net", nil])
        XCTAssertEqual(change("apple.com", nil), [nil, "apple.com"])
        XCTAssertEqual(change("corp.example", "corp.example"), ["corp.example", nil])
        XCTAssertEqual(change("other.example", "corp.example"), [nil, "other.example"])
        XCTAssertEqual(change("tail1.ts.net", "corp.example"), ["tail1.ts.net", nil])
        XCTAssertEqual(change(nil, "corp.example"), [nil, nil])
        XCTAssertEqual(change("co.uk", "corp.example"), [nil, nil])
        // Saved setups from before the field decode with none.
        let old = try JSONDecoder().decode(Setup.self, from: Data(#"{"home":{"tailscale":true}}"#.utf8))
        XCTAssertNil(old.home.tsSuffix)
        XCTAssertFalse(old.home.tsSuffixConfirmed)
        var s = Setup()
        s.home.tsSuffix = "corp.example"
        XCTAssertEqual(try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(s)).home.tsSuffix, "corp.example")
    }

    /// An accepted domain can be removed: it goes back on offer, so the next report of it asks again instead of taking it.
    /// Only the domain the user saw, and never Tailscale's own.
    func testAnAcceptedTailnetDomainCanBeRemoved() throws {
        let removed = try XCTUnwrap(Store.tsSuffix(removing: "corp.example", accepted: "corp.example"))
        XCTAssertNil(removed.accepted)
        XCTAssertEqual(removed.offered, "corp.example")
        // The server reports it again: still only offered.
        let again = Store.tsSuffix(reported: "corp.example", accepted: removed.accepted)
        XCTAssertNil(again.accepted)
        XCTAssertEqual(again.offered, "corp.example")
        // A confirmation for a domain that has changed since, or isn't accepted, changes nothing.
        XCTAssertNil(Store.tsSuffix(removing: "corp.example", accepted: "other.example"))
        XCTAssertNil(Store.tsSuffix(removing: "corp.example", accepted: nil))
        // Tailscale's own is always used while Tailscale runs.
        XCTAssertNil(Store.tsSuffix(removing: "tail1.ts.net", accepted: "tail1.ts.net"))
    }

    func testTheTunnelAcceptsEveryConfigTheCompilerWrites() throws {
        // The extension refuses configs outside the compiler's shape: everything it writes must pass, probe included.
        var direct = example
        direct.defaultRoute = DIRECT
        for config in [try raw(example), try raw(direct), try raw(example, probe: (port: 40123, password: "p")),
                       try raw(Setup(routes: [], defaultRoute: DIRECT), links: [:])] {
            XCTAssertNoThrow(try ConfigVet.check(config))
        }
    }

    func testTheTunnelRunsTheCheckedCopyWhichMeansTheSame() throws {
        // The extension runs ConfigVet's re-serialised copy: identical in meaning to what the compiler wrote.
        for config in [try raw(example), try raw(example, probe: (port: 40123, password: "p"))] {
            let checked = try ConfigVet.check(config)
            let a = try JSONSerialization.jsonObject(with: Data(config.utf8)) as! NSDictionary
            let b = try JSONSerialization.jsonObject(with: Data(checked.utf8)) as! NSDictionary
            XCTAssertEqual(a, b)
        }
        // A name given twice can't carry anything past the check: whichever copy the check saw is all that runs.
        let twice = #"{"log":{"output":"x.log"},"log":{"level":"warn"},"inbounds":[{"type":"tun"}]}"#
        if let checked = try? ConfigVet.check(twice) { XCTAssertFalse(checked.contains("output")) }
    }

    func testTheTunnelRefusesListenersApisAndFilesTheCompilerNeverWrites() throws {
        func refused(_ change: (inout [String: Any]) -> Void) throws -> Bool {
            let base = try JSONSerialization.jsonObject(with: Data(try raw(example).utf8)) as! [String: Any]
            var c = base
            change(&c)
            // Listed items join the compiled ones, so each is refused for itself, not for a missing tun or a dangling name.
            func join(_ new: Any?, _ old: Any?) -> Any? {
                guard let added = new as? [Any], let had = old as? [Any], (new as? NSArray) != (old as? NSArray) else { return new }
                return had + added
            }
            for key in ["inbounds", "endpoints", "outbounds"] { c[key] = join(c[key], base[key]) }
            if var d = c["dns"] as? [String: Any] { d["servers"] = join(d["servers"], (base["dns"] as? [String: Any])?["servers"]); c["dns"] = d }
            let text = String(data: try JSONSerialization.data(withJSONObject: c), encoding: .utf8)!
            return (try? ConfigVet.check(text)) == nil
        }
        XCTAssertFalse(try refused { _ in })
        XCTAssertTrue(try refused { $0["inbounds"] = [["type": "mixed", "listen": "0.0.0.0", "users": [["username": "a", "password": "b"]]]] })
        XCTAssertTrue(try refused { $0["inbounds"] = [["type": "mixed", "listen": "127.0.0.1"]] })
        XCTAssertTrue(try refused { $0["inbounds"] = [["type": "socks", "listen": "127.0.0.1"]] })
        XCTAssertTrue(try refused { $0["experimental"] = ["clash_api": ["external_controller": "0.0.0.0:9090"]] })
        XCTAssertTrue(try refused { $0["experimental"] = ["cache_file": ["enabled": true, "path": "/etc/x.db"]] })
        XCTAssertTrue(try refused { $0["log"] = ["output": "/tmp/engine.log"] })
        XCTAssertTrue(try refused { $0["services"] = [["type": "derp", "listen": "0.0.0.0", "listen_port": 3478]] })
        XCTAssertTrue(try refused { var r = $0["route"] as! [String: Any]; r["rule_set"] = [["type": "local", "path": "/etc/x"]]; $0["route"] = r })
        XCTAssertTrue(try refused { $0["endpoints"] = [["type": "tailscale", "tag": "ts", "state_directory": "/Library/x"]] })
        XCTAssertTrue(try refused { $0["endpoints"] = [["type": "wireguard", "tag": "wg", "listen_port": 51820]] })
        // The engine ignores case in field names: so does the check.
        XCTAssertTrue(try refused { $0["Services"] = [["type": "derp"]] })
        XCTAssertTrue(try refused { var r = $0["route"] as! [String: Any]; r["Rule_Set"] = [["type": "local"]]; $0["route"] = r })
        XCTAssertTrue(try refused { $0["endpoints"] = [["type": "tailscale", "tag": "ts", "STATE_DIRECTORY": "/Library/x"]] })
        XCTAssertTrue(try refused { $0["log"] = ["level": "warn", "Level": "debug"] })
        XCTAssertTrue(try refused { $0["outbounds"] = [["type": "direct", "tag": "d", "listen_port": 8080]] })
        // Only the protocols the compiler uses: some engine types run programs or write files as root.
        XCTAssertTrue(try refused { $0["outbounds"] = [["type": "tor", "tag": "t", "executable_path": "/tmp/x"]] })
        XCTAssertTrue(try refused { $0["outbounds"] = [["type": "direct", "tag": "d", "tls": ["certificate_path": "/etc/x"]]] })
        XCTAssertTrue(try refused { var d = $0["dns"] as! [String: Any]; d["servers"] = [["type": "dhcp", "tag": "x"]]; $0["dns"] = d })
        XCTAssertTrue(try refused { $0["inbounds"] = ["type": "tun"] })
        // Go folds Unicode in names ("rule_ſet" is rule_set): only ASCII names pass.
        XCTAssertTrue(try refused { var r = $0["route"] as! [String: Any]; r["rule_\u{17F}et"] = [["type": "local"]]; $0["route"] = r })
        // A Shadowsocks plugin may not name a file for the engine to read, however it's spelled.
        for opts in ["tls;cert=/etc/x", "tls;c\\ert=/etc/x", "tls; CERT =/etc/x"] {
            XCTAssertTrue(try refused { $0["outbounds"] = [["type": "shadowsocks", "tag": "s", "plugin": "v2ray-plugin", "plugin_opts": opts]] })
        }
        XCTAssertTrue(try refused { $0["outbounds"] = [["type": "shadowsocks", "tag": "s", "plugin": "some-binary"]] })
        XCTAssertThrowsError(try ConfigVet.check(String(repeating: " ", count: 5 << 20)))
    }

    /// Direct and Shadowsocks UDP share no session across destinations: each is judged by its own first packet.
    func testUdpSessionsArePerDestination() throws {
        for s in [example, Setup(routes: [], defaultRoute: DIRECT)] {
            let t = tun(try compile(s, links: s.routes.isEmpty ? [:] : nil))
            XCTAssertEqual(t["udp_mapping"] as? String, "address_and_port_dependent")
            XCTAssertEqual(t["udp_timeout"] as? String, "5m")
            XCTAssertNil(t["udp_filtering"])
        }
    }

    func testTheTunnelsOwnResolverIsRoutedThroughItWithLanAccessOn() throws {
        // LAN access excludes 172.16.0.0/12, which holds the tunnel's own address: its resolver (listed in
        // /etc/resolv.conf) would otherwise be sent to the physical network.
        let t = tun(try compile(example))
        XCTAssertTrue(strings(t["route_exclude_address"]).contains("172.16.0.0/12"))
        XCTAssertTrue(strings(t["route_address"]).contains("172.19.0.0/30"))
    }

    func testKillSwitchLevelsDecideWhoReachesTheHomeNetwork() throws {
        func rules(_ c: O) -> [O] { ((c["route"] as? O)?["rules"] as? [O]) ?? [] }
        func lanForBlocked(_ c: O) -> Bool {
            rules(c).contains { strings($0["ip_cidr"]).contains("192.168.0.0/16") && $0["process_path_regex"] != nil && $0["outbound"] as? String == "direct" }
        }
        var s = example
        s.home = Home()
        s.apps["com.blocked"] = BLOCK
        // Off: nothing changes; with an app blocked the home network enters the tunnel and the block covers it.
        XCTAssertNil(tun(try compile(s))["route_exclude_address"])
        XCTAssertFalse(lanForBlocked(try compile(s)))
        // Internet: the home network enters the tunnel (macOS drops it outside), and blocked apps keep it, before their reject.
        s.prefs.killLevel = .internet
        var c = try compile(s)
        XCTAssertNil(tun(c)["route_exclude_address"])
        XCTAssertTrue(lanForBlocked(c))
        let allow = rules(c).firstIndex { strings($0["ip_cidr"]).contains("192.168.0.0/16") && $0["process_path_regex"] != nil }
        let reject = rules(c).firstIndex { $0["action"] as? String == "reject" && $0["process_path_regex"] != nil && $0["port"] == nil }
        XCTAssertLessThan(try XCTUnwrap(allow), try XCTUnwrap(reject))
        // ...but never DNS: the router's resolver would be a channel to the internet.
        let dns = rules(c).firstIndex { ($0["port"] as? [Int]) == [53, 853] && $0["action"] as? String == "reject" && $0["process_path_regex"] != nil }
        XCTAssertLessThan(try XCTUnwrap(dns), try XCTUnwrap(allow))
        // Home: it enters the tunnel, blocked apps are refused there, every other app's local traffic still goes direct.
        s.prefs.killLevel = .home
        c = try compile(s)
        XCTAssertNil(tun(c)["route_exclude_address"])
        XCTAssertFalse(lanForBlocked(c))
        XCTAssertTrue(rules(c).contains { strings($0["ip_cidr"]).contains("192.168.0.0/16") && $0["process_path_regex"] == nil && $0["outbound"] as? String == "direct" })
        // Off with nothing blocked: the home network bypasses the tunnel, as before.
        s.prefs.killLevel = .off
        s.apps["com.blocked"] = nil
        XCTAssertTrue(strings(tun(try compile(s))["route_exclude_address"]).contains("192.168.0.0/16"))
    }

    func testKillLevelReadsAndWritesBothSwitches() throws {
        var p = Prefs()
        XCTAssertEqual(p.killLevel, .off)
        p.killLevel = .home
        XCTAssertTrue(p.killSwitch && p.killSwitchHome)
        p.killLevel = .internet
        XCTAssertTrue(p.killSwitch && !p.killSwitchHome)
        p.killLevel = .off
        XCTAssertFalse(p.killSwitch || p.killSwitchHome)
        // A file saved before the home level existed decodes with it off.
        let old = try JSONDecoder().decode(Prefs.self, from: Data(#"{"killSwitch":true,"lan":true}"#.utf8))
        XCTAssertEqual(old.killLevel, .internet)
        // A setup saved with the kill switch on and apps blocked had the home network taken in automatically: kept.
        func level(_ json: String) throws -> KillLevel { try JSONDecoder().decode(Setup.self, from: Data(json.utf8)).prefs.killLevel }
        XCTAssertEqual(try level(#"{"apps":{"a":"block"},"prefs":{"killSwitch":true}}"#), .home)
        XCTAssertEqual(try level(#"{"apps":{"a":"nl"},"prefs":{"killSwitch":true}}"#), .internet)
        XCTAssertEqual(try level(#"{"apps":{"a":"block"},"prefs":{"killSwitch":true,"killSwitchHome":false}}"#), .internet)
        // Saved before Block needed the kill switch: blocked apps were kept off the home network, so they get the home level.
        XCTAssertEqual(try level(#"{"apps":{"a":"block"},"prefs":{"killSwitch":false}}"#), .home)
        XCTAssertEqual(try level(#"{"apps":{"a":"nl"},"prefs":{"killSwitch":false}}"#), .off)
        var s = Setup()
        s.apps["a"] = BLOCK
        s.requireKillSwitchForBlocks()
        XCTAssertEqual(s.prefs.killLevel, .internet)
    }

    /// Every change to the stored setup keeps the kill switch on while an app is blocked, however it was made.
    func testNoChangeLeavesABlockWithoutTheKillSwitch() throws {
        var blocked = Setup()
        blocked.apps["a"] = BLOCK
        blocked.prefs.killLevel = .home
        // Settings: Off while blocked keeps the level the user had, never a weaker one (Internet would let blocked apps
        // reach the home network).
        XCTAssertEqual(Store.edited(blocked) { $0.prefs.killLevel = .off }.prefs.killLevel, .home)
        XCTAssertEqual(Store.edited(blocked) { $0.prefs.killSwitch = false }.prefs.killLevel, .home)
        var internet = blocked
        internet.prefs.killLevel = .internet
        XCTAssertEqual(Store.edited(internet) { $0.prefs.killLevel = .off }.prefs.killLevel, .internet)
        // Another level that keeps the kill switch on is the user's to choose.
        XCTAssertEqual(Store.edited(blocked) { $0.prefs.killLevel = .internet }.prefs.killLevel, .internet)
        XCTAssertEqual(Store.edited(internet) { $0.prefs.killLevel = .home }.prefs.killLevel, .home)
        // A whole setup replaced (an import, an undo) with blocks and Off keeps the level too.
        var replacement = Setup()
        replacement.apps["b"] = BLOCK
        XCTAssertEqual(Store.edited(blocked) { $0 = replacement }.prefs.killLevel, .home)
        // One that was decoded (an import) already had Off turned into Internet: that stays.
        let decoded = try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(replacement))
        XCTAssertEqual(decoded.prefs.killLevel, .internet)
        XCTAssertEqual(Store.edited(blocked) { $0 = decoded }.prefs.killLevel, .internet)
        // A first block with the kill switch off turns it on at the Internet level.
        XCTAssertEqual(Store.edited(Setup()) { $0.apps["a"] = BLOCK }.prefs.killLevel, .internet)
        XCTAssertEqual(Store.edited(Setup()) { $0.apps["a"] = BLOCK; $0.prefs.killLevel = .off }.prefs.killLevel, .internet)
        // Unblocking the last app keeps the level the user had.
        XCTAssertEqual(Store.edited(blocked) { $0.apps["a"] = nil }.prefs.killLevel, .home)
        // Without blocks, Off is Off.
        XCTAssertEqual(Store.edited(Setup()) { $0.prefs.killLevel = .off }.prefs.killLevel, .off)
        XCTAssertEqual(Store.edited(blocked) { $0.apps["a"] = nil; $0.prefs.killLevel = .off }.prefs.killLevel, .off)
    }

    /// The tunnel's profile never lets the home network bypass it while an app is blocked, even from a setup that (against
    /// Store.update's rule) has the kill switch off.
    func testTheHomeNetworkNeverBypassesTheTunnelWhileAnAppIsBlocked() {
        var s = Setup()
        s.prefs.lan = true
        s.prefs.killLevel = .off
        XCTAssertTrue(s.lanBypassesTunnel)
        s.apps["a"] = BLOCK
        XCTAssertFalse(s.lanBypassesTunnel)
        s.apps["a"] = DIRECT
        XCTAssertTrue(s.lanBypassesTunnel)
        s.prefs.lan = false
        XCTAssertFalse(s.lanBypassesTunnel)
        s.prefs.lan = true
        for level in [KillLevel.internet, .home] { s.prefs.killLevel = level; XCTAssertFalse(s.lanBypassesTunnel) }
    }

    func testNothingActiveIsAllDirect() throws {
        let c = try compile(Setup(routes: [], defaultRoute: DIRECT), links: [:])
        XCTAssertTrue(endpoints(c).isEmpty)
        XCTAssertEqual(final(c), "direct")
    }

    func testThreatProtectionAndCustomDns() throws {
        func dns(_ s: Setup) throws -> String? { dnsServer(try compile(s), "dns-r-nl")?["server"] as? String }
        XCTAssertEqual(try dns(example), Compiler.nordTP)
        var off = example; off.opts["nord"] = ["protect": "off"]
        XCTAssertEqual(try dns(off), Compiler.nordDns)
        var custom = example; custom.prefs.customDns = ["9.9.9.9"]
        XCTAssertEqual(try dns(custom), "9.9.9.9")
    }

    func testLanBypassesTheTunnelButHomeSubnetsStayRouted() throws {
        let t = tun(try compile(example))
        XCTAssertTrue(strings(t["route_exclude_address"]).contains("192.168.0.0/16"))
        XCTAssertTrue(strings(t["route_address"]).contains("192.168.178.0/24"))
        var off = example; off.prefs.lan = false
        XCTAssertNil(tun(try compile(off))["route_exclude_address"])
    }

    /// With a Tailscale exit carrying traffic, its login must not ride that exit; otherwise those sites follow each app.
    func testTailscaleLoginGoesDirectOnlyWithAnExitNode() throws {
        func login(_ s: Setup) throws -> O? { rules(try compile(s, login: true)).first { strings($0["domain_suffix"]).contains("tailscale.com") } }
        XCTAssertNil(try login(example))
        var withExit = example
        withExit.routes.append(Route(id: "ts", tsExit: "100.101.102.103", hue: 4))
        withExit.apps["com.n"] = "ts"
        XCTAssertFalse(try rules(compile(withExit)).contains { strings($0["domain_suffix"]).contains("tailscale.com") })
        let rule = try XCTUnwrap(try login(withExit))
        XCTAssertEqual(outbound(rule), "direct")
        // Only for the apps on that exit: a browser on another VPN keeps its own exit for tailscale.com.
        XCTAssertEqual(paths(rule), [pat("com.n")])
        let rs = rules(try compile(withExit, login: true))
        XCTAssertEqual(rs.filter { strings($0["domain_suffix"]).contains("tailscale.com") }.count, 1)
        // Ahead of that app's resolve through the exit, which can't answer before the exit node is signed in.
        let at = try XCTUnwrap(rs.firstIndex { $0["domain_suffix"] != nil && paths($0) == [pat("com.n")] })
        let resolve = try XCTUnwrap(rs.firstIndex { paths($0) == [pat("com.n")] && action($0) == "resolve" })
        XCTAssertLessThan(at, resolve)
    }

    /// Ping has no owner to route by: with Direct as the default it would leave a VPN app from the Mac's address.
    func testPingIsRefusedWhenItWouldBypassAnAppsVpn() throws {
        func icmp(_ s: Setup) throws -> [O] { rules(try compile(s)).filter { $0["network"] as? String == "icmp" } }
        XCTAssertTrue(try icmp(example).isEmpty)
        var directDefault = example
        directDefault.defaultRoute = DIRECT
        XCTAssertEqual(action(try XCTUnwrap(try icmp(directDefault).first)), "reject")
        XCTAssertEqual(try icmp(directDefault).count, 1)
        // LAN and home rules come first, so pinging the router or a home box still works.
        let rs = rules(try compile(directDefault))
        XCTAssertGreaterThan(try XCTUnwrap(rs.firstIndex { $0["network"] as? String == "icmp" }), try XCTUnwrap(rs.firstIndex { $0["ip_cidr"] != nil }))
        directDefault.apps = ["com.x": DIRECT]
        XCTAssertTrue(try icmp(directDefault).isEmpty)
    }

    /// Over plain HTTP the Headscale key exchange could be faked, so such a control URL is refused, not used.
    func testHeadscaleNeedsHttps() throws {
        func with(_ url: String) -> Setup { var s = example; s.home.tailscale = true; s.home.tsControlUrl = url; return s }
        XCTAssertTrue(try raw(with("https://hs.example.com")).contains("https://hs.example.com"))
        XCTAssertThrowsError(try raw(with("http://hs.example.com"))) { XCTAssertTrue($0 is Fail) }
        // Saved by an earlier version as typed: accepted, and the engine gets the normalised address.
        let upper = try raw(with("HTTPS://HS.Example.com/Path"))
        XCTAssertTrue(upper.contains("\"https://hs.example.com/Path\""))
        XCTAssertFalse(upper.contains("HTTPS://"))
    }

    /// The control server stays reachable outside a Tailscale exit: an address by address, any other host by name, even
    /// one starting with a digit (which once became an invalid CIDR the engine refused).
    func testControlServerHostIsMatchedByNameOrAddress() throws {
        func login(_ url: String) throws -> [String: Any]? {
            var s = example; s.home = Home(); s.home.tsControlUrl = url
            s.routes.append(Route(id: "ts", tsExit: "nas", hue: 4)); s.defaultRoute = "ts"
            return rules(try compile(s, login: true)).first { outbound($0) == "direct" && ($0["domain"] != nil || strings($0["ip_cidr"]).count == 1) && $0["process_path_regex"] == nil }
        }
        var s = example; s.home.tsControlUrl = "https://1-control.example.com"
        s.routes.append(Route(id: "ts", tsExit: "nas", hue: 4)); s.defaultRoute = "ts"
        let normal = rules(try compile(s))
        XCTAssertFalse(normal.contains { strings($0["domain"]).contains("1-control.example.com") })
        let pending = rules(try compile(s, login: true))
        XCTAssertFalse(pending.contains { strings($0["domain_suffix"]).contains("tailscale.com") })
        XCTAssertEqual(strings(try login("https://1-control.example.com")?["domain"]), ["1-control.example.com"])
        XCTAssertEqual(strings(try login("https://203.0.113.7")?["ip_cidr"]), ["203.0.113.7/32"])
        XCTAssertEqual(strings(try login("https://[2001:db8::7]:443")?["ip_cidr"]), ["2001:db8::7/128"])
        XCTAssertNil(try login("https://[fe80::1%25en0]:8443"))
    }

    /// Apps test "online?" with a TCP connect to 8.8.8.8:53; a hijacked TCP flow never completes, so only UDP is hijacked.
    func testOnlyUdpDnsIsHijackedSoTcpPort53Connects() throws {
        let byPort = rules(try compile(example)).filter { $0["port"] as? Int == 53 }
        XCTAssertEqual(byPort.count, 1)
        XCTAssertEqual(byPort[0]["network"] as? String, "udp")
        XCTAssertEqual(action(byPort[0]), "hijack-dns")
    }

    /// A route asking for its provider's blocking resolver uses it; a custom DNS still wins.
    func testProviderBlockingDnsPerRoute() throws {
        var mullvad = example
        mullvad.routes = mullvad.routes.map { var r = $0; if r.id == "us" { r.loc.provider = "mullvad"; r.filter = true }; return r }
        XCTAssertEqual(dnsServer(try compile(mullvad), "dns-r-us")?["server"] as? String, "100.64.0.7")
        mullvad.opts["mullvad"] = ["adult": "on", "social": "on"]
        XCTAssertEqual(dnsServer(try compile(mullvad), "dns-r-us")?["server"] as? String, "100.64.0.47")
        mullvad.routes = mullvad.routes.map { var r = $0; if r.id == "us" { r.filter = false }; return r }
        XCTAssertNotEqual(dnsServer(try compile(mullvad), "dns-r-us")?["server"] as? String, "100.64.0.47")
        mullvad.routes = mullvad.routes.map { var r = $0; if r.id == "us" { r.filter = true }; return r }
        mullvad.prefs.customDns = ["9.9.9.9"]
        XCTAssertEqual(dnsServer(try compile(mullvad), "dns-r-us")?["server"] as? String, "9.9.9.9")
    }

    func testLanOffRemovesDirectLanRule() throws {
        var s = example; s.prefs.lan = false
        XCTAssertFalse(rules(try compile(s)).contains { outbound($0) == "direct" && $0["ip_cidr"] != nil })
        XCTAssertFalse(dnsRules(try compile(s)).contains { strings($0["domain_suffix"]).contains("fritz.box") })
    }

    func testShadowsocksRouteWithPluginPassesTheExtensionCheck() throws {
        // An imported Shadowsocks route, plugin included: compiled (and so vetted, see raw) like any other route.
        let userinfo = Data("chacha20-ietf-poly1305:secret".utf8).base64EncodedString()
        let ss = try Manual.parseSs("ss://\(userinfo)@ss.example.net:8388/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dexample.com#Mine")
        var s = example
        s.routes.append(Route(id: "s1", ss: ss, hue: 4))
        s.apps["com.c"] = "s1"
        XCTAssertTrue(((try compile(s)["outbounds"] as? [O]) ?? []).contains { $0["type"] as? String == "shadowsocks" })
    }

    func testTwoImportsDifferingOnlyInRequestedMtuShareOneTunnel() throws {
        // Both emit MTU 1280, so they are one tunnel: two endpoints with one key would fight over it.
        var a = try WgConf.parse(Self.fritz, name: "A"), b = a
        a.mtu = 1380; b.mtu = 1420
        let server = sv("w")
        XCTAssertEqual(Compiler.linkKey(Route(id: "w1", wg: a, hue: 3), .wg(server, a)), Compiler.linkKey(Route(id: "w2", wg: b, hue: 4), .wg(server, b)))
        // A real difference (another preshared key) is another tunnel.
        var c = a
        c.presharedKey = "other"
        XCTAssertNotEqual(Compiler.linkKey(Route(id: "w1", wg: a, hue: 3), .wg(server, a)), Compiler.linkKey(Route(id: "w3", wg: c, hue: 5), .wg(server, c)))
    }

    func testTheTailnetDomainIsRefusedWhileTailscaleIsntRunning() throws {
        // A pause keeps the search domain, so "nas" still expands to nas.tail123.ts.net: refused, never looked up locally.
        var s = example
        s.home = Home()
        let rule = dnsRules(try compile(s, tsSuffix: "tail123.ts.net")).first { strings($0["domain_suffix"]) == ["tail123.ts.net"] }
        XCTAssertEqual(rule?["rcode"] as? String, "NXDOMAIN")
        // With Tailscale on, the tailnet resolver answers it instead.
        XCTAssertFalse(dnsRules(try compile(example, tsSuffix: "tail123.ts.net")).contains { $0["rcode"] as? String == "NXDOMAIN" })
    }

    func testCustomWireGuardRoute() throws {
        let peer = try WgConf.parse(Self.fritz, name: "Home box")
        var s = example
        s.routes.append(Route(id: "w1", wg: peer, hue: 3))
        s.apps["com.c"] = "w1"
        let ep = try XCTUnwrap(endpoints(try compile(s)).first { $0["tag"] as? String == "r-w1" })
        let p = try XCTUnwrap((ep["peers"] as? [O])?.first)
        XCTAssertEqual(p["address"] as? String, "abc.myfritz.net")
        XCTAssertEqual(p["port"] as? Int, 51820)
    }

    func testTailscaleExitRouteRidesTheTailscaleEndpoint() throws {
        var s = example
        s.home = Home()
        s.routes.append(Route(id: "ts", tsExit: "nas", hue: 4))
        s.apps["com.n"] = "ts"
        let c = try compile(s)
        XCTAssertEqual(exitNodeEndpoint(c)?["exit_node"] as? String, "nas")
        XCTAssertTrue(routes(c, to: "home-ts", for: "com.n"))
        XCTAssertFalse(endpointTags(c).contains("r-ts"))
    }

    /// Keeping an exit alive must not grant every app the separately controlled home access.
    func testTailnetAccessToggleIsIndependentOfAnActiveExit() throws {
        let subnets = ["192.168.0.0/16", "10.42.0.0/16"]
        for homeAccess in [false, true] {
            for dflt in [DIRECT, "nl", "ts"] {
                for lan in [false, true] {
                    var s = example
                    s.home = Home(tailscale: homeAccess, subnets: subnets)
                    s.routes.append(Route(id: "ts", tsExit: "100.101.102.103", hue: 4))
                    s.defaultRoute = dflt
                    s.apps["com.n"] = "ts"
                    s.prefs.lan = lan
                    let c = try compile(s, tsSuffix: "corp.example")
                    let context = "home=\(homeAccess) default=\(dflt) lan=\(lan)"
                    let homeRules = rules(c).filter { outbound($0) == "home-ts" && $0["ip_cidr"] != nil }
                    XCTAssertEqual(!homeRules.isEmpty, homeAccess, context)
                    for r in homeRules { XCTAssertEqual(cidrs(r), [Compiler.tailnet] + subnets, context) }
                    let tailnetDns = dnsRules(c).filter { $0["server"] as? String == "dns-tailnet" }
                    XCTAssertEqual(!tailnetDns.isEmpty, homeAccess, context)
                    // The Mac lists the suffixes sorted; the engine takes them as a set.
                    if homeAccess { XCTAssertEqual(Set(strings(tailnetDns.first?["domain_suffix"])), ["ts.net", "corp.example"], context) }
                    XCTAssertEqual(dnsServer(c, "dns-tailnet") != nil, homeAccess, context)
                    let t = tun(c)
                    XCTAssertEqual(strings(t["route_address"]), ["0.0.0.0/0", "::/0", "172.19.0.0/30"] + (homeAccess ? subnets : []), context)
                    if lan { XCTAssertEqual(strings(t["route_exclude_address"]).contains("192.168.0.0/16"), !homeAccess, context) }
                    else { XCTAssertNil(t["route_exclude_address"], context) }
                    XCTAssertEqual(exitNodeEndpoint(c)?["exit_node"] as? String, "100.101.102.103", context)
                    XCTAssertEqual(dnsServer(c, "dns-r-ts")?["detour"] as? String, "home-ts", context)
                    XCTAssertEqual(final(c), dflt == DIRECT ? "direct" : dflt == "ts" ? "home-ts" : "r-nl", context)
                    if dflt != "ts" { XCTAssertTrue(routes(c, to: "home-ts", for: "com.n"), context) }
                    XCTAssertTrue(routes(c, to: "r-us", for: "com.a"), context)
                }
            }
        }
    }

    /// A bracketed IPv6 endpoint reaches the engine whole, split at its last colon.
    func testWireGuardEndpointsSplitAtTheLastColon() throws {
        func peer(_ endpoint: String) throws -> O? {
            var s = example
            s.routes.append(Route(id: "own", wg: WgPeer(name: "Own", privateKey: key, address: ["10.9.0.2/32"], publicKey: key, endpoint: endpoint, allowedIps: ["0.0.0.0/0"]), hue: 4))
            s.apps["com.n"] = "own"
            let e = endpoints(try compile(s)).first { ($0["tag"] as? String)?.hasSuffix("own") == true }
            return (e?["peers"] as? [O])?.first
        }
        let v6 = try XCTUnwrap(try peer("[2001:db8::1]:51820"))
        XCTAssertEqual(v6["address"] as? String, "2001:db8::1")
        XCTAssertEqual(v6["port"] as? Int, 51820)
        let v4 = try XCTUnwrap(try peer("vpn.example.net:443"))
        XCTAssertEqual(v4["address"] as? String, "vpn.example.net")
        XCTAssertEqual(v4["port"] as? Int, 443)
    }

    func testDisablingTailnetAccessPreservesTheSeparateHomeWireGuardTunnel() throws {
        var s = example
        s.home = Home(subnets: ["10.42.0.0/16"], wg: try WgConf.parse(Self.fritz, name: "Home"))
        s.routes.append(Route(id: "ts", tsExit: "100.101.102.103", hue: 4))
        s.apps["com.n"] = "ts"
        let c = try compile(s)
        XCTAssertTrue(rules(c).contains { outbound($0) == "home-wg" && cidrs($0)?.contains("192.168.178.0/24") == true })
        XCTAssertEqual(strings(tun(c)["route_address"]), ["0.0.0.0/0", "::/0", "172.19.0.0/30", "192.168.178.0/24"])
    }

    func testNordOpenVpnKeepsNordDnsWhileOtherOpenVpnUsesPushedDns() throws {
        let p = try Manual.parseOvpn(Fixture.text("ovpn/nord-double.udp.ovpn"), name: "dv", username: "u", password: "p")
        var other = p; other.username = "other"
        var s = example
        s.home = Home()
        s.routes = [nl(), Route(id: "ex", loc: Location(provider: "expressvpn", countryCode: "JP", country: "Japan"))]
        s.apps = ["com.e": "ex"]
        let c = try compile(s, links: ["nl": .ovpn(sv("nl"), p), "ex": .ovpn(sv("exx"), other)])
        XCTAssertEqual(dnsServer(c, "dns-r-nl")?["type"] as? String, "udp")
        XCTAssertEqual(dnsServer(c, "dns-ovpn-r-ex")?["type"] as? String, "openvpn")
    }

    func testHomeTunnelNeverCatchesAll() throws {
        let full = try WgConf.parse(Self.fritz.replacingOccurrences(of: "192.168.178.0/24, ", with: ""), name: "Home") // AllowedIPs = 0.0.0.0/0 only
        XCTAssertEqual(Compiler.homeCidrs(full), ["192.168.178.0/24"])
        var s = example; s.home = Home(wg: full)
        let homeRules = rules(try compile(s)).filter { outbound($0) == "home-wg" }
        XCTAssertFalse(homeRules.isEmpty)
        for r in homeRules { XCTAssertFalse(cidrs(r)!.contains { $0.hasSuffix("/0") }) }
    }

    func testHomeTunnelIgnoresPublicRanges() throws {
        let evil = try WgConf.parse(Self.fritz.replacingOccurrences(of: "192.168.178.0/24, 0.0.0.0/0, ::/0", with: "0.0.0.0/1, 128.0.0.0/1, 10.9.0.0/16"), name: "Home")
        XCTAssertEqual(Compiler.homeCidrs(evil), ["10.9.0.0/16"])
        XCTAssertTrue(Compiler.isPrivate("192.168.178.0/24") && Compiler.isPrivate("100.100.1.0/24"))
        XCTAssertFalse(Compiler.isPrivate("0.0.0.0/1") || Compiler.isPrivate("8.8.8.0/24") || Compiler.isPrivate("10.0.0.0/7"))
    }

    func testPublicBoxTldIsNotLocal() throws {
        XCTAssertFalse(dnsRules(try compile(example)).contains { strings($0["domain_suffix"]).contains("box") })
    }

    func testWgConfWithTwoPeersIsRejected() {
        XCTAssertThrowsError(try WgConf.parse(Self.fritz + "\n[Peer]\nPublicKey = \(otherKey)\nEndpoint = x:1\nAllowedIPs = 10.0.0.0/8\n", name: "x")) { XCTAssertTrue($0 is Fail) }
    }

    func testWgConfWithBadKeyIsRejected() {
        XCTAssertThrowsError(try WgConf.parse(Self.fritz.replacingOccurrences(of: "PrivateKey = \(key)", with: "PrivateKey = nope"), name: "x")) { XCTAssertTrue($0 is Fail) }
    }

    func testWgConfWithoutIpv4AllowedIpsIsRejected() {
        XCTAssertThrowsError(try WgConf.parse(Self.fritz.replacingOccurrences(of: "AllowedIPs = 192.168.178.0/24, 0.0.0.0/0, ::/0", with: "AllowedIPs = ::/0"), name: "x")) { XCTAssertTrue($0 is Fail) }
    }

    /// Other query types (HTTPS, SVCB, TXT…) follow the asking app to its own exit, not the default one.
    func testNonAddressDnsFollowsTheAppsExit() throws {
        var s = example; s.defaultRoute = DIRECT
        let rs = dnsRules(try compile(s))
        let us = try XCTUnwrap(rs.first { paths($0) == [pat("com.a")] })
        XCTAssertEqual(us["server"] as? String, "dns-r-us")
        // After the A/AAAA rule, which sends address lookups to the fake-IP server first.
        XCTAssertLessThan(try XCTUnwrap(rs.firstIndex { $0["server"] as? String == "fake" }), try XCTUnwrap(rs.firstIndex { paths($0) == [pat("com.a")] }))
    }

    func testHomeAndLanRulesFollowEveryResolve() throws {
        let rs = rules(try compile(example))
        let resolves = rs.indices.filter { action(rs[$0]) == "resolve" }
        XCTAssertFalse(resolves.isEmpty)
        for i in resolves { XCTAssertEqual(outbound(rs[i + 2]), "home-ts") }
    }

    func testWgConfParsesFritzExport() throws {
        let p = try WgConf.parse(Self.fritz, name: "Home")
        XCTAssertEqual(p.address, ["192.168.178.201/24"])
        XCTAssertEqual(p.allowedIps, ["192.168.178.0/24", "0.0.0.0/0"])
        XCTAssertEqual(p.dns, ["192.168.178.1"])
        XCTAssertEqual(p.endpoint, "abc.myfritz.net:51820")
    }

    func testParsesNordRecommendations() throws {
        let s = try XCTUnwrap(NordApi.parseServers(Fixture.data("recommendations.json")).first)
        XCTAssertNotNil(s.host.wholeMatch(of: /nl\d+\.nordvpn\.com/))
        XCTAssertEqual(s.city, "Amsterdam")
        XCTAssertEqual(s.publicKey.count, 44)
    }

    // MARK: Shared tunnels

    private func two(_ second: Link, first: Link? = nil) throws -> O {
        let s = Setup(routes: [Route(id: "a", loc: Location(countryId: 1, countryCode: "NL", country: "Netherlands")),
                               Route(id: "b", loc: Location(countryId: 2, countryCode: "DE", country: "Germany"), hue: 1)],
                      defaultRoute: "a", apps: ["com.b": "b"])
        return try compile(s, links: ["a": first ?? .wg(sv("a"), Nord.peer(sv("a"), key)), "b": second])
    }

    func testSameServerAndKeyShareOneEndpoint() throws {
        let c = try two(.wg(sv("a"), Nord.peer(sv("a"), key)))
        XCTAssertEqual(endpointTags(c), ["r-a"])
        XCTAssertTrue(routes(c, to: "r-a", for: "com.b"))
        XCTAssertFalse(try parseString(c).contains("\"r-b\""))
        XCTAssertEqual(dnsServer(c, "dns-r-b")?["detour"] as? String, "r-a")
    }

    private func parseString(_ c: O) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: c), as: UTF8.self) }

    func testDifferentKeyOrServerIsNotShared() throws {
        XCTAssertEqual(endpointTags(try two(.wg(sv("a"), Nord.peer(sv("a"), otherKey)))), ["r-a", "r-b"])
        XCTAssertEqual(endpointTags(try two(.wg(sv("b"), Nord.peer(sv("b"), key)))), ["r-a", "r-b"])
    }

    private func ovpnRoute(_ id: String, _ user: String) throws -> Route {
        Route(id: id, ovpn: try Manual.parseOvpn(Fixture.text("ovpn/expressvpn.ovpn"), name: id, username: user, password: "pw"))
    }

    func testSameOpenVpnRemoteAndUserShareOneEndpoint() throws {
        let rs = [try ovpnRoute("a", "u"), try ovpnRoute("b", "u"), try ovpnRoute("c", "other")]
        let s = Setup(routes: rs, defaultRoute: "a", apps: ["com.b": "b", "com.c": "c"])
        let c = try compile(s, links: Dictionary(uniqueKeysWithValues: rs.map { ($0.id, Link.ovpn(sv($0.id), $0.ovpn!)) }))
        XCTAssertEqual(endpointTags(c), ["r-a", "r-c"])
    }

    func testSharedOpenVpnDnsAndFilters() throws {
        let profile = try Manual.parseOvpn(Fixture.text("ovpn/expressvpn.ovpn") + "\npull-filter accept \"route\"\n", name: "x", username: "u", password: "p")
        let imported = Route(id: "a", ovpn: profile)
        let nord = Route(id: "b", loc: Location(provider: "nord", countryCode: "NL", country: "Netherlands"))
        let express = Route(id: "b", loc: Location(provider: "expressvpn", countryCode: "NL", country: "Netherlands"))
        for second in [nord, express, Route(id: "b", ovpn: profile)] {
            for rs in [[imported, second], [second, imported]] {
                let setup = Setup(routes: rs, defaultRoute: "a", apps: ["com.b": "b"])
                let links: [String: Link] = ["a": .ovpn(sv("a"), profile), "b": .ovpn(sv("b"), profile)]
                let c = try compile(setup, links: links, probe: (4000, "pw"))
                let tag = "r-\(rs[0].id)"
                XCTAssertEqual(endpointTags(c), [tag])
                let pushed = dnsServers(c).filter { $0["type"] as? String == "openvpn" }
                XCTAssertEqual(pushed.count, 1)
                XCTAssertEqual(pushed.first?["tag"] as? String, "dns-ovpn-\(tag)")
                XCTAssertEqual((c["dns"] as? O)?["final"] as? String, "dns-ovpn-\(tag)")
                let ep = try XCTUnwrap(endpoints(c).first)
                XCTAssertNil(ep["route_no_pull"])
                let filters = try XCTUnwrap(ep["pull_filters"] as? [O])
                // unbraid's ignores come first: the first match wins, so the profile's accept can't let pushed routes in.
                let firstAccept = try XCTUnwrap(filters.firstIndex { $0["action"] as? String == "accept" })
                let routeIgnore = try XCTUnwrap(filters.firstIndex { $0["action"] as? String == "ignore" && $0["text"] as? String == "route " })
                XCTAssertLessThan(routeIgnore, firstAccept)
                let probeRule = try XCTUnwrap(rules(c).first { $0["inbound"] as? String == "probe" && ($0["auth_user"] as? [String]) == [tag] && $0["action"] as? String == "resolve" })
                let expected = rs[0].id == "b" && second.loc.provider == "nord" && !second.imported ? "dns-r-b" : "dns-ovpn-\(tag)"
                XCTAssertEqual(probeRule["server"] as? String, expected)
            }
        }
    }

    func testWireGuardIdentityAndClashes() throws {
        let a = try WgConf.parse(Self.fritz, name: "a")
        let ra = Route(id: "a", wg: a), rb = Route(id: "b", wg: a)
        let setup = Setup(routes: [ra, rb], defaultRoute: "a", apps: ["com.b": "b"])
        func pairs(_ b: WgPeer) -> [String: Link] { ["a": .wg(sv("a"), a), "b": .wg(sv("b"), b)] }
        XCTAssertEqual(try Compiler.shared(setup, pairs(a))["b"], "r-a")
        XCTAssertEqual(try Compiler.shared(setup, ["a": .wg(sv("a"), a)], blocked: ["b"]), ["a": "r-a"])
        XCTAssertThrowsError(try Compiler.shared(setup, ["a": .wg(sv("a"), a)]))
        var variants: [WgPeer] = []
        var p = a; p.mtu = 1200; variants.append(p)
        p = a; p.presharedKey = key; variants.append(p)
        p = a; p.address = ["10.0.0.1/32", "10.0.0.2/32"]; var reversed = p; reversed.address.reverse()
        let two = Setup(routes: [Route(id: "a", wg: p), rb], defaultRoute: "a", apps: ["com.b": "b"])
        XCTAssertEqual(Compiler.clashes(two, ["a": .wg(sv("a"), p), "b": .wg(sv("b"), reversed)]), ["b"])
        p = a; p.keepalive = 0; variants.append(p)
        p = a; p.endpoint = a.endpoint.replacingOccurrences(of: ":51820", with: ":51821"); variants.append(p)
        for b in variants {
            XCTAssertEqual(Compiler.clashes(setup, pairs(b)), ["b"])
            XCTAssertThrowsError(try Compiler.shared(setup, pairs(b))) { XCTAssertEqual($0.localizedDescription, Compiler.clashMessage) }
            XCTAssertNotEqual(Compiler.linkKey(ra, .wg(sv("a"), a)), Compiler.linkKey(rb, .wg(sv("b"), b)))
        }
        var home = setup; home.home.wg = a
        XCTAssertFalse(Compiler.clashes(home, pairs(a)).isEmpty)
    }

    func testWireGuardNumericHostIdentity() throws {
        let peer = try WgConf.parse(Self.fritz, name: "a")
        func pair(_ first: String, _ second: String) -> (Setup, [String: Link], WgPeer, WgPeer) {
            var a = peer; a.endpoint = first
            var b = peer; b.endpoint = second
            let setup = Setup(routes: [Route(id: "a", wg: a), Route(id: "b", wg: b)], defaultRoute: "a", apps: ["com.b": "b"])
            return (setup, ["a": .wg(sv("a"), a), "b": .wg(sv("b"), b)], a, b)
        }
        for (first, second) in [("[2001:DB8::1]:51820", "[2001:db8:0:0::1]:51820"),
                                ("192.0.2.1:51820", "192.0.2.1:51820"),
                                ("VPN.Example:51820", "vpn.example:51820")] {
            let (s, links, a, b) = pair(first, second)
            XCTAssertEqual(try Compiler.shared(s, links)["b"], "r-a")
            XCTAssertTrue(Compiler.clashes(s, links).isEmpty)
            var changed = b; changed.mtu = 1200
            XCTAssertEqual(Compiler.clashes(s, ["a": .wg(sv("a"), a), "b": .wg(sv("b"), changed)]), ["b"])
            var home = s; home.home.wg = a
            XCTAssertEqual(Compiler.clashes(home, ["b": .wg(sv("b"), b)]), ["b"])
        }
        for (first, second) in [("[2001:db8::1]:51820", "[2001:db8::2]:51820"),
                                ("192.0.2.1:51820", "192.0.2.2:51820"),
                                ("192.000.002.001:51820", "192.0.2.1:51820")] {
            let (s, links, _, _) = pair(first, second)
            XCTAssertEqual(try Compiler.shared(s, links)["b"], "r-b")
            XCTAssertTrue(Compiler.clashes(s, links).isEmpty)
        }
    }

    func testKeepaliveAndOldPeerDecoding() throws {
        for (value, expected) in [("0", 0), ("off", 0), ("25", 25), ("15", 15)] {
            let p = try WgConf.parse(Self.fritz.replacingOccurrences(of: "PersistentKeepalive = 25", with: "PersistentKeepalive = \(value)"), name: "x")
            XCTAssertEqual(p.keepalive, expected)
            let c = try compile(Setup(home: Home(wg: p)))
            let homeEndpoint = try XCTUnwrap(endpoints(c).first { $0["tag"] as? String == "home-wg" })
            let peer = try XCTUnwrap((homeEndpoint["peers"] as? [O])?.first)
            XCTAssertEqual(peer["persistent_keepalive_interval"] as? Int, expected == 0 ? nil : expected)
        }
        let old = try WgConf.parse(Self.fritz.replacingOccurrences(of: "PersistentKeepalive = 25", with: ""), name: "x")
        XCTAssertNil(old.keepalive)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? O)
        json.removeValue(forKey: "keepalive")
        let decoded = try JSONDecoder().decode(WgPeer.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.keepalive)
        let setup = Setup(routes: [Route(id: "a", wg: old)], defaultRoute: "a", home: Home(wg: old), servers: [OwnServer(id: "own", wg: old)])
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(setup)) as? O)
        var oldHome = try XCTUnwrap(oldJSON["home"] as? O)
        oldHome.removeValue(forKey: "tsSuffixConfirmed")
        oldJSON["home"] = oldHome
        let oldSetup = try JSONDecoder().decode(Setup.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        XCTAssertFalse(oldSetup.home.tsSuffixConfirmed)
        XCTAssertNil(oldSetup.routes.first?.wg?.keepalive)
        XCTAssertNil(oldSetup.home.wg?.keepalive)
        XCTAssertNil(oldSetup.servers.first?.wg?.keepalive)
        let oldLink = Link.wg(sv("a"), old)
        let decodedLink = try JSONDecoder().decode(Link.self, from: JSONEncoder().encode(oldLink))
        if case .wg(_, let peer, _, _) = decodedLink { XCTAssertNil(peer.keepalive) } else { XCTFail("missing peer") }
        XCTAssertThrowsError(try WgConf.parse(Self.fritz.replacingOccurrences(of: "PersistentKeepalive = 25", with: "PersistentKeepalive = bad"), name: "x"))
    }

    func testStrictImportsAndCanonicalHomeRanges() throws {
        XCTAssertNoThrow(try WgConf.parse("\u{FEFF}" + Self.fritz, name: "x"))
        for bad in ["010.0.0.0/8", "300.0.0.0/8", "10.0.0.1/33", "garbage::/64", "::/129"] {
            let input = Self.fritz.replacingOccurrences(of: "192.168.178.0/24, 0.0.0.0/0, ::/0", with: "0.0.0.0/0, \(bad)")
            XCTAssertThrowsError(try WgConf.parse(input, name: "x")) { XCTAssertTrue($0.localizedDescription.contains("AllowedIPs has an invalid range")) }
        }
        XCTAssertEqual(Compiler.canonical("192.168.1.0/16"), "192.168.0.0/16")
        XCTAssertEqual(Compiler.canonical("10.1.2.3/0"), "0.0.0.0/0")
        XCTAssertEqual(Compiler.canonical("10.1.2.3/32"), "10.1.2.3/32")
        for bad in ["010.0.0.0/8", "1.2.3", "1.2.3.4/", "1.2.3.4/33", "1.2.3.4/1/2"] { XCTAssertNil(Compiler.canonical(bad)) }
        var p = try WgConf.parse(Self.fritz, name: "x"); p.allowedIps = ["192.168.1.0/16"]
        XCTAssertEqual(Compiler.homeCidrs(p), ["192.168.0.0/16"])
        let c = try compile(Setup(home: Home(tailscale: true, subnets: ["192.168.1.0/16"])))
        XCTAssertTrue(strings(tun(c)["route_address"]).contains("192.168.0.0/16"))
        XCTAssertFalse(strings(tun(c)["route_exclude_address"]).contains("192.168.0.0/16"))
    }

    // MARK: WireGuard keys

    private func keyError(_ edit: (inout WgPeer) -> Void) -> String? {
        let s = Setup(routes: [Route(id: "a", loc: Location(countryId: 1, countryCode: "NL", country: "Netherlands"))], defaultRoute: "a")
        var peer = Nord.peer(sv("a"), key)
        edit(&peer)
        do { _ = try compile(s, links: ["a": .wg(sv("a"), peer)]) } catch { return error.localizedDescription }
        XCTFail("expected a rejection")
        return nil
    }

    func testMalformedWireGuardKeysAreRejectedWithoutQuotingThem() {
        let secret = "this-is-not-a-key-but-looks-like-one-0123456789"
        let msg = keyError { $0.privateKey = secret }
        XCTAssertEqual(msg, "Invalid WireGuard key for Netherlands")
        XCTAssertFalse(msg?.contains(secret) ?? true)
        _ = keyError { $0.publicKey = "AAAA" }
        _ = keyError { $0.presharedKey = "c2hvcnQ=" }
        _ = keyError { $0.privateKey = "" }
    }

    // MARK: OpenVPN DNS

    private func ovpnSetup(_ prefs: Prefs = Prefs()) throws -> Setup { Setup(routes: [try ovpnRoute("x", "u")], defaultRoute: "x", prefs: prefs) }

    func testProtectionPresetsOnOpenVpnAndNamedBoot() throws {
        for preset in FilterServer.presets {
            var s = try ovpnSetup()
            s.prefs.filter = Filter(id: preset.id, value: preset.id == "nextdns" ? "abc123" : "", routes: true)
            let c = try compile(s, links: ["x": .ovpn(sv("x"), s.routes[0].ovpn!)])
            XCTAssertEqual(dnsServer(c, "dns-r-x")?["type"] as? String, "https")
            XCTAssertEqual(dnsServer(c, "dns-r-x")?["detour"] as? String, "r-x")
        }
        var s = try ovpnSetup()
        s.prefs.filter = Filter(id: "own", value: "tls://dns.example.org", routes: true)
        let c = try compile(s, links: ["x": .ovpn(sv("x"), s.routes[0].ovpn!)])
        XCTAssertEqual(dnsServer(c, "boot-r-x")?["type"] as? String, "openvpn")
        XCTAssertEqual(dnsServer(c, "dns-r-x")?["domain_resolver"] as? String, "boot-r-x")
        XCTAssertNil(endpoints(c)[0]["route_no_pull"])
        var two = s
        var copy = s.routes[0]; copy.id = "y"; two.routes.append(copy); two.apps["com.y"] = "y"
        let shared = try compile(two, links: ["x": .ovpn(sv("x"), s.routes[0].ovpn!), "y": .ovpn(sv("x"), s.routes[0].ovpn!)])
        XCTAssertEqual(dnsServers(shared).filter { $0["type"] as? String == "openvpn" }.count, 1)
        XCTAssertEqual(dnsServers(shared).filter { $0["type"] as? String == "tls" }.count, 1)
    }

    func testOpenVpnRoutesUseThePushedDnsButIgnorePushedRoutes() throws {
        let s = try ovpnSetup()
        let c = try compile(s, links: ["x": .ovpn(sv("x"), s.routes[0].ovpn!)])
        let dns = try XCTUnwrap(dnsServer(c, "dns-ovpn-r-x"))
        XCTAssertEqual(dns["type"] as? String, "openvpn")
        XCTAssertEqual(dns["endpoint"] as? String, "r-x")
        let ep = endpoints(c)[0]
        XCTAssertNil(ep["route_no_pull"])
        let ignored = ((ep["pull_filters"] as? [O]) ?? []).filter { $0["action"] as? String == "ignore" }.compactMap { $0["text"] as? String }
        XCTAssertTrue(Set(["route ", "route-ipv6 ", "redirect-gateway"]).isSubset(of: ignored))
        XCTAssertFalse(ignored.contains { $0.hasPrefix("dhcp-option") || $0.hasPrefix("dns") })
    }

    func testCustomDnsKeepsOpenVpnOnItsOwnResolverAndNoPull() throws {
        let s = try ovpnSetup(Prefs(customDns: ["1.1.1.1"]))
        let c = try compile(s, links: ["x": .ovpn(sv("x"), s.routes[0].ovpn!)])
        XCTAssertEqual(dnsServer(c, "dns-r-x")?["type"] as? String, "udp")
        XCTAssertEqual(endpoints(c)[0]["route_no_pull"] as? Bool, true)
    }

    // MARK: Tailnet DNS

    func testTailnetSuffixIsRoutedToTailscaleDns() throws {
        func suffixes(_ suffix: String?) throws -> [String] {
            let c = try compile(example, tsSuffix: suffix)
            return strings(dnsRules(c).first { $0["server"] as? String == "dns-tailnet" }?["domain_suffix"]).sorted()
        }
        XCTAssertEqual(try suffixes(nil), ["ts.net"])
        XCTAssertEqual(try suffixes("Tail1234.ts.net."), ["tail1234.ts.net", "ts.net"])
        XCTAssertEqual(try suffixes("corp.example"), ["corp.example", "ts.net"])
        XCTAssertEqual(try suffixes("bad\" domain"), ["ts.net"])
        XCTAssertNil(Compiler.tsSuffix("ts.net"))
        XCTAssertEqual(Compiler.tsSuffix(" Tail1234.ts.net. "), "tail1234.ts.net")
    }

    func testHeadscaleDoesNotRouteAllTsNetNames() throws {
        var s = example
        s.home.tsControlUrl = "https://hs.example.com"
        func suffixes(_ suffix: String?) throws -> [String] {
            let rules = dnsRules(try compile(s, tsSuffix: suffix)).filter { $0["server"] as? String == "dns-tailnet" }
            return rules.flatMap { strings($0["domain_suffix"]) }
        }
        XCTAssertFalse(try suffixes(nil).contains("ts.net"))
        XCTAssertTrue(try suffixes("corp.example").contains("corp.example"))
        XCTAssertFalse(try suffixes("corp.example").contains("ts.net"))
    }

    func testHeadscaleSuffixNeedsConsentEvenUnderTsNet() {
        var home = Home(tailscale: true, tsControlUrl: "https://hs.example.com", tsSuffix: "tail1.ts.net")
        XCTAssertNil(Compiler.trustedStoredSuffix(home))
        home.tsSuffixConfirmed = true
        XCTAssertEqual(Compiler.trustedStoredSuffix(home), "tail1.ts.net")
        home.tsSuffixConfirmed = false; home.tsControlUrl = nil
        XCTAssertEqual(Compiler.trustedStoredSuffix(home), "tail1.ts.net")
        let offered = Store.tsSuffix(reported: "tail1.ts.net", accepted: nil, official: false)
        XCTAssertNil(offered.accepted)
        XCTAssertEqual(offered.offered, "tail1.ts.net")
        XCTAssertEqual(Store.tsSuffix(reported: "tail1.ts.net", accepted: "tail1.ts.net", official: false).accepted, "tail1.ts.net")
        XCTAssertNotNil(Store.tsSuffix(removing: "tail1.ts.net", accepted: "tail1.ts.net", official: false))
    }

    func testProbeResolverMap() throws {
        let input = Compiler.Input(setup: example, links: links(example), apps: patterns(example), selfPattern: pat("unbraid"), tsSuffix: nil, probe: nil)
        let map = try Compiler.probeDNS(input)
        XCTAssertEqual(map["r-nl"], "dns-r-nl")
        XCTAssertEqual(map["direct"], "local")
    }

    func testTailscaleExitNodeTakesAnIpAndKeepsItsName() throws {
        var s = example
        s.home = Home()
        s.routes.append(Route(id: "ts", tsExit: "100.101.102.103", tsName: "nas", hue: 4))
        s.apps["com.n"] = "ts"
        XCTAssertEqual(exitNodeEndpoint(try compile(s))?["exit_node"] as? String, "100.101.102.103")
        XCTAssertEqual(s.route("ts")?.name, "nas")
    }

    // MARK: - macOS specific

    func testSameInputGivesTheSameConfig() throws {
        XCTAssertEqual(try raw(example), try raw(example))
    }

    func testAppsAreMatchedByProcessPathNotPackageName() throws {
        let text = try raw(example)
        XCTAssertFalse(text.contains("package_name"))
        XCTAssertFalse(text.contains("exclude_package"))
        XCTAssertNil(tun(try compile(example))["exclude_package"])
        XCTAssertEqual(tun(try compile(example))["address"] as? [String], ["172.19.0.1/30", "fdfe:dcba:9876::1/126"])
    }

    func testDirectAppsGetARuleToTheDirectOutbound() throws {
        let c = try compile(example)
        let rs = rules(c)
        let wanted = [pat("com.x"), pat("com.y")]
        let at = try XCTUnwrap(rs.firstIndex { paths($0) == wanted && outbound($0) == "direct" })
        // Resolved locally first, then the LAN and home rules (which beat the app's own), then the rule to `direct`;
        // no VPN tunnel or DNS server exists for Direct.
        let resolve = try XCTUnwrap(rs.firstIndex { paths($0) == wanted && action($0) == "resolve" })
        XCTAssertEqual(rs[resolve]["server"] as? String, "local")
        XCTAssertEqual(outbound(rs[resolve + 2]), "home-ts")
        XCTAssertEqual(rs[resolve + 3]["ip_cidr"] != nil, true)
        XCTAssertEqual(at, resolve + 4)
        XCTAssertNil(dnsServer(c, "dns-r-direct"))
        XCTAssertFalse(endpointTags(c).contains("r-direct"))
        XCTAssertEqual(dnsRules(c).first { paths($0) == wanted }?["server"] as? String, "local")
    }

    func testDirectAppsKeepTheirRuleWhenTheDefaultIsAVpn() throws {
        var s = example
        s.apps = ["com.x": DIRECT]
        let c = try compile(s)
        XCTAssertTrue(routes(c, to: "direct", for: "com.x"))
        XCTAssertEqual(endpointTags(c), ["r-nl", "home-ts"])
    }

    func testBlockedAppsAreRejectedBeforeTheNetworkRules() throws {
        var s = example
        s.apps["com.z"] = BLOCK
        s.apps["com.w"] = BLOCK
        let c = try compile(s)
        let rs = rules(c)
        let wanted = [pat("com.w"), pat("com.z")]
        let reject = try XCTUnwrap(rs.firstIndex { paths($0) == wanted })
        XCTAssertEqual(action(rs[reject]), "reject")
        XCTAssertNil(rs[reject]["outbound"])
        XCTAssertLessThan(reject, try XCTUnwrap(rs.firstIndex { outbound($0) == "home-ts" }))
        XCTAssertLessThan(reject, try XCTUnwrap(rs.firstIndex { outbound($0) == "direct" && $0["ip_cidr"] != nil }))
        XCTAssertLessThan(reject, try XCTUnwrap(firstAppRule(rs.filter { action($0) != "reject" })))
        // Blocked apps get no tunnel, no resolver and no second rule.
        XCTAssertEqual(rs.filter { paths($0) == wanted }.count, 1)
        XCTAssertEqual(rs.filter { $0["server"] as? String == "dns-r-block" }.count, 0)
        XCTAssertNil(dnsServer(c, "dns-r-block"))
        // Their only DNS rule is the refusal, first after what comes in through a tunnel.
        XCTAssertNotNil(dnsRules(c)[0]["inbound"])
        XCTAssertEqual(dnsRules(c).indices.filter { paths(dnsRules(c)[$0]) == wanted }, [1])
        XCTAssertEqual(endpointTags(c), ["r-nl", "r-us", "r-it", "home-ts"])
    }

    /// The far side of a tunnel (a provider's server, the home server, a tailnet peer) can open connections and send
    /// lookups into it: they are refused before anything else, from every endpoint the config has and nothing else.
    func testNothingThatComesInThroughATunnelGoesAnywhere() throws {
        func refusals(_ c: O) -> (route: [String]?, dns: [String]?) {
            let r = rules(c).first { $0["inbound"] != nil }, d = dnsRules(c).first { $0["inbound"] != nil }
            return (r?["inbound"] as? [String], d?["inbound"] as? [String])
        }
        var s = example
        s.apps["com.z"] = BLOCK
        s.prefs.killLevel = .home
        let c = try compile(s, probe: (port: 40123, password: "p"))
        let tags = ["home-ts", "r-it", "r-nl", "r-us"]
        XCTAssertEqual(Set(endpointTags(c)), Set(tags))
        // First of all, and nothing but the refusal.
        XCTAssertEqual(rules(c)[0] as NSDictionary, ["inbound": tags, "action": "reject"] as NSDictionary)
        XCTAssertEqual(dnsRules(c)[0] as NSDictionary, ["inbound": tags, "action": "predefined", "rcode": "REFUSED"] as NSDictionary)
        XCTAssertEqual(rules(c).filter { $0["inbound"] as? [String] == tags }.count, 1)
        XCTAssertEqual(lookup(c, "A", "example.com", from: nil, via: "home-ts"), "REFUSED")
        XCTAssertEqual(lookup(c, "TXT", "nas.tail123.ts.net", from: nil, via: "r-nl"), "REFUSED")
        // The tun and the app's own test proxy are untouched.
        XCTAssertEqual(lookup(c, "A", "example.com", from: mDNSResponder), "fake")
        XCTAssertTrue(rules(c).contains { $0["inbound"] as? String == Compiler.probeTag })
        // Every kind of endpoint, each tunnel once; never an outbound (Shadowsocks only connects out) or `direct`.
        let ssUser = Data("chacha20-ietf-poly1305:secret".utf8).base64EncodedString()
        let ssRoute = Route(id: "s1", ss: try Manual.parseSs("ss://\(ssUser)@ss.example.net:8388#Mine"), hue: 4)
        let ssOnly = Setup(routes: [ssRoute], defaultRoute: "s1", apps: ["com.a": DIRECT])
        XCTAssertNil(refusals(try compile(ssOnly)).route)
        XCTAssertNil(refusals(try compile(ssOnly)).dns)
        var mixed = example
        mixed.home = Home(subnets: ["10.42.0.0/16"], wg: try WgConf.parse(Self.fritz, name: "Home"))
        mixed.routes.append(ssRoute); mixed.apps["com.s"] = "s1"
        mixed.routes.append(Route(id: "ts", tsExit: "100.101.102.103", hue: 5)); mixed.apps["com.n"] = "ts"
        XCTAssertEqual(refusals(try compile(mixed)).route, ["home-ts", "home-wg", "r-it", "r-nl", "r-us"])
        XCTAssertEqual(refusals(try compile(mixed)).dns, ["home-ts", "home-wg", "r-it", "r-nl", "r-us"])
        let ovpn = try Manual.parseOvpn(Fixture.text("ovpn/nord-double.udp.ovpn"), name: "dv", username: "u", password: "p")
        let openvpn = Setup(routes: [nl()], defaultRoute: "nl")
        XCTAssertEqual(refusals(try compile(openvpn, links: ["nl": .ovpn(sv("nl"), ovpn)])).route, ["r-nl"])
        // Two routes on one tunnel name it once.
        var shared = Setup(routes: [nl(), Route(id: "nl2", loc: nl().loc)], defaultRoute: "nl", apps: ["com.a": "nl2"])
        let link = Link.wg(sv("nl"), Nord.peer(sv("nl"), key))
        XCTAssertEqual(refusals(try compile(shared, links: ["nl": link, "nl2": link])).route, ["r-nl"])
        // Nothing to come in through: no rule.
        shared.routes = []; shared.defaultRoute = DIRECT; shared.apps = [:]
        XCTAssertNil(refusals(try compile(shared, links: [:])).route)
        XCTAssertNil(refusals(try compile(shared, links: [:])).dns)
    }

    /// A connection with no program to match is refused while an app is blocked (by default), after the LAN, home and
    /// tailnet rules and unbraid's own, before each app's route is chosen; never ping, which has its own rule.
    func testConnectionsWithoutAnOwnerAreRefusedWhileAnAppIsBlocked() throws {
        func ownerless(_ c: O) -> [Int] { rules(c).indices.filter { rules(c)[$0]["type"] as? String == "logical" } }
        var s = example
        s.apps["com.z"] = BLOCK
        s.prefs.killLevel = .internet
        var c = try compile(s)
        let at = try XCTUnwrap(ownerless(c).first)
        XCTAssertEqual(ownerless(c).count, 1)
        let rule = rules(c)[at]
        XCTAssertEqual(rule["mode"] as? String, "and")
        XCTAssertEqual(action(rule), "reject")
        let parts = try XCTUnwrap(rule["rules"] as? [O])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(strings(parts[0]["network"]), ["tcp", "udp"])
        XCTAssertNil(parts[0]["invert"])
        XCTAssertEqual(strings(parts[1]["process_path_regex"]), ["."])
        XCTAssertEqual(parts[1]["invert"] as? Bool, true)
        XCTAssertNil(parts[0]["action"] ?? parts[1]["action"])
        let rs = rules(c)
        XCTAssertGreaterThan(at, try XCTUnwrap(rs.firstIndex { paths($0) == [Compiler.pattern(forPath: selfApp)] }))
        // Right after the home (tailnet) and LAN rules.
        XCTAssertEqual(outbound(rs[at - 2]), "home-ts")
        XCTAssertEqual(outbound(rs[at - 1]), "direct")
        XCTAssertNotNil(rs[at - 1]["ip_cidr"])
        XCTAssertLessThan(at, try XCTUnwrap(rs.firstIndex { paths($0) != nil && action($0) == "resolve" }))
        // Blocked apps are refused earlier still, by their own rule.
        XCTAssertLessThan(try XCTUnwrap(rs.firstIndex { paths($0) == [pat("com.z")] && action($0) == "reject" }), at)
        // Nothing blocked: a VPN default carries ownerless traffic; a Direct default must refuse it.
        s.apps["com.z"] = nil
        XCTAssertTrue(ownerless(try compile(s)).isEmpty)
        var split = s
        split.defaultRoute = DIRECT
        XCTAssertEqual(ownerless(try compile(split)).count, 1)
        XCTAssertEqual(ownerless(try parse(try raw(split, ownerless: .refusedWhileSplit))).count, 1)
        // A VPN default already keeps them on a VPN.
        XCTAssertTrue(ownerless(try parse(try raw(s, ownerless: .refusedWhileSplit))).isEmpty)
        // And never while following the default.
        s.apps["com.z"] = BLOCK
        XCTAssertTrue(ownerless(try parse(try raw(s, ownerless: .followsDefault))).isEmpty)
        // A pause (nothing but blocks) refuses them too.
        var paused = Setup(routes: [], defaultRoute: DIRECT, apps: ["com.z": BLOCK])
        paused.prefs.killLevel = .internet
        c = try compile(paused, links: [:])
        XCTAssertEqual(ownerless(c).count, 1)
    }

    func testABlockedAppRefusesPingToo() throws {
        // Ping has no owner to match, so a blocked app could otherwise still ping out.
        var s = example
        s.defaultRoute = DIRECT
        s.apps = ["com.z": BLOCK, "com.x": DIRECT]
        XCTAssertEqual(rules(try compile(s)).filter { $0["network"] as? String == "icmp" }.count, 1)
    }

    /// An app that is gone keeps its rule where it was last seen (one installed there again is refused from its
    /// first connection), but doesn't hold the whole Mac's guards against a blocked or routed app's ways round for good.
    func testAnAppOnlyRememberedKeepsItsRuleButNotTheWholeMacsGuards() throws {
        func icmp(_ c: O) -> Bool { rules(c).contains { $0["network"] as? String == "icmp" } }
        func ownerless(_ c: O) -> Bool { rules(c).contains { $0["type"] as? String == "logical" } }
        func noHints(_ c: O) -> Bool { dnsRules(c).contains { strings($0["query_type"]) == ["HTTPS", "SVCB"] } }
        var s = example
        s.defaultRoute = DIRECT
        s.home = Home()
        s.apps = ["com.z": BLOCK, "com.x": DIRECT]
        s.prefs.killLevel = .internet
        func compiled(_ s: Setup, _ remembered: Set<String>, apps: [String: [String]]? = nil, ownerless: Compiler.Ownerless = .refusedWhileBlocking) throws -> O {
            try parse(try raw(s, apps: apps, remembered: remembered, ownerless: ownerless))
        }
        let here = try compiled(s, [])
        XCTAssertTrue(icmp(here) && ownerless(here) && noHints(here))
        let gone = try compiled(s, ["com.z"])
        XCTAssertTrue(rules(gone).contains { paths($0) == [pat("com.z")] && action($0) == "reject" })
        XCTAssertTrue(dnsRules(gone).contains { paths($0) == [pat("com.z")] && $0["rcode"] as? String == "REFUSED" })
        XCTAssertFalse(icmp(gone) || ownerless(gone) || noHints(gone))
        // At the Internet level its LAN allowance (and its resolvers' refusal) stays as for any blocked app.
        s.prefs.lan = true
        XCTAssertEqual(rules(try compiled(s, ["com.z"])).filter { paths($0) == [pat("com.z")] }.count,
                       rules(try compiled(s, [])).filter { paths($0) == [pat("com.z")] }.count)
        // The same pattern held by an app here: that one counts.
        var shared = s
        shared.apps["com.w"] = BLOCK
        XCTAssertTrue(icmp(try compiled(shared, ["com.z"], apps: ["com.z": [pat("com.z")], "com.w": [pat("com.z")], "com.x": [pat("com.x")]])))
        XCTAssertFalse(icmp(try compiled(shared, ["com.z", "com.w"], apps: ["com.z": [pat("com.z")], "com.w": [pat("com.z")], "com.x": [pat("com.x")]])))
        // A blocked bundle remembered still refuses an app here inside it: that is a block.
        let xcode = "/Applications/Xcode.app", sim = xcode + "/Contents/Developer/Applications/Simulator.app"
        var nested = s
        nested.apps = ["xcode": BLOCK, "sim": DIRECT]
        let p = ["xcode": [Compiler.pattern(forPath: xcode)], "sim": [Compiler.pattern(forPath: sim)]]
        XCTAssertTrue(icmp(try compiled(nested, ["xcode"], apps: p)))
        XCTAssertFalse(icmp(try compiled(nested, ["xcode", "sim"], apps: p)))
        // A pause routes the blocks only, but passes every app's patterns: the app inside still counts.
        var paused = Setup(routes: [], defaultRoute: DIRECT, apps: ["xcode": BLOCK], prefs: s.prefs)
        XCTAssertTrue(icmp(try parse(try raw(paused, links: [:], apps: p, remembered: ["xcode"]))))
        XCTAssertFalse(rules(try parse(try raw(paused, links: [:], apps: p, remembered: ["xcode"]))).contains { paths($0) == [p["sim"]![0]] })
        paused.apps = [:]
        XCTAssertFalse(icmp(try parse(try raw(paused, links: [:], apps: p, remembered: ["xcode"]))))
        // An app on a VPN while Direct is the default: its rule stays, the split's guards go with it.
        var split = s
        split.apps = ["com.a": "us"]
        let routed = try compiled(split, [], ownerless: .refusedWhileSplit)
        XCTAssertTrue(icmp(routed) && ownerless(routed) && noHints(routed))
        let away = try compiled(split, ["com.a"], ownerless: .refusedWhileSplit)
        XCTAssertTrue(routes(away, to: "r-us", for: "com.a"))
        XCTAssertFalse(icmp(away) || ownerless(away) || noHints(away))
    }

    /// The tunnel lets the LAN bypass it exactly when the profile does: never with an app blocked, whether it is here.
    func testTheLanBypassFollowsTheSetupWithABlockedAppHereOrNot() throws {
        var s = example
        s.home = Home()
        s.apps = ["com.x": DIRECT]
        s.prefs.lan = true
        s.prefs.killLevel = .off
        XCTAssertTrue(strings(tun(try compile(s))["route_exclude_address"]).contains("192.168.0.0/16"))
        s.apps["com.z"] = BLOCK
        s.prefs.killLevel = .off
        XCTAssertFalse(s.lanBypassesTunnel)
        for remembered: Set<String> in [[], ["com.z"]] {
            XCTAssertFalse(strings(tun(try parse(try raw(s, remembered: remembered)))["route_exclude_address"]).contains("192.168.0.0/16"))
        }
        XCTAssertFalse(strings(tun(try compile(s, apps: ["com.x": [pat("com.x")]]))["route_exclude_address"]).contains("192.168.0.0/16"))
    }

    func testUnbraidItselfGoesDirectBeforeAnyAppRule() throws {
        var s = example
        s.apps["com.z"] = BLOCK
        let c = try compile(s)
        let rs = rules(c)
        let mine = try XCTUnwrap(rs.firstIndex { paths($0) == [Compiler.pattern(forPath: selfApp)] })
        XCTAssertEqual(outbound(rs[mine]), "direct")
        XCTAssertGreaterThan(mine, try XCTUnwrap(rs.firstIndex { $0["protocol"] as? String == "dns" }))
        // Only blocked apps come earlier: a block is absolute, even for DNS.
        for i in rs.indices where paths(rs[i]) != nil && i != mine && rs[i]["action"] as? String != "reject" { XCTAssertLessThan(mine, i) }
        let block = try XCTUnwrap(rs.firstIndex { $0["action"] as? String == "reject" && paths($0) != nil })
        XCTAssertLessThan(block, try XCTUnwrap(rs.firstIndex { $0["protocol"] as? String == "dns" }))
        XCTAssertLessThan(mine, try XCTUnwrap(rs.firstIndex { outbound($0) == "home-ts" }))
        // Even a Setup with nothing else configured has it.
        let bare = try compile(Setup(routes: [], defaultRoute: DIRECT), links: [:], apps: [:])
        XCTAssertEqual(rules(bare).filter { paths($0) == [Compiler.pattern(forPath: selfApp)] }.count, 1)
    }

    func testIpv6IsCapturedAndRefused() throws {
        let c = try compile(example)
        let rs = rules(c)
        let v6 = rs.indices.filter { rs[$0]["ip_version"] as? Int == 6 }
        XCTAssertEqual(v6.count, 1)
        XCTAssertEqual(action(rs[v6[0]]), "reject")
        // After the final resolve and its LAN/home rules, so local IPv6 (lan6) and the tailnet still pass first.
        let lastResolve = try XCTUnwrap(rs.lastIndex { action($0) == "resolve" })
        XCTAssertGreaterThan(v6[0], lastResolve + 1)
        XCTAssertTrue(strings(tun(c)["route_address"]).contains("::/0"))
        let lan6 = ["fc00::/7", "fe80::/10", "ff00::/8"]
        XCTAssertEqual(Compiler.lan6, lan6)
        XCTAssertTrue(Set(lan6).isSubset(of: strings(tun(c)["route_exclude_address"])))
        let lanRule = try XCTUnwrap(rs.first { outbound($0) == "direct" && $0["ip_cidr"] != nil })
        XCTAssertTrue(Set(lan6).isSubset(of: strings(lanRule["ip_cidr"])))
        XCTAssertLessThan(try XCTUnwrap(rs.firstIndex { outbound($0) == "direct" && $0["ip_cidr"] != nil }), v6[0])
    }

    func testAppsWithoutPatternsAreSkipped() throws {
        // Nothing installed: no app rules at all, only unbraid's own.
        let none = try compile(example, apps: [:])
        XCTAssertTrue(appRules(none).isEmpty)
        XCTAssertFalse(rules(none).contains { $0["action"] as? String == "resolve" && $0["server"] as? String == "dns-r-us" })
        XCTAssertFalse(dnsRules(none).contains { $0["server"] as? String == "dns-r-us" })
        // One installed, one with an empty list, one missing.
        let some = try compile(example, apps: ["com.a": [pat("com.a")], "com.b": [], "com.x": []])
        XCTAssertEqual(appRules(some).flatMap { paths($0)! }.reduce(into: Set<String>()) { $0.insert($1) }, [pat("com.a")])
        XCTAssertTrue(routes(some, to: "r-us", for: "com.a"))
        XCTAssertFalse(rules(some).contains { outbound($0) == "r-it" })
        // The route stays active (its app is assigned), so its tunnel is still built.
        XCTAssertEqual(endpointTags(some), ["r-nl", "r-us", "r-it", "home-ts"])
    }

    func testAnAppKeyCanHoldSeveralPatterns() throws {
        var s = example
        s.apps = ["com.a": "us", "tool": "us"]
        let c = try compile(s, apps: ["com.a": [pat("com.a"), pat("com.a.helper")], "tool": [Compiler.pattern(forPath: "/usr/bin/curl")]])
        // Sorted by app key, then in the order given.
        XCTAssertEqual(paths(try XCTUnwrap(rules(c).first { outbound($0) == "r-us" })), [pat("com.a"), pat("com.a.helper"), Compiler.pattern(forPath: "/usr/bin/curl")])
    }

    /// Nested bundles: the innermost assignment decides, whichever route ids sort first; DNS follows the same order.
    func testTheInnermostOfNestedBundlesDecides() throws {
        let xcode = "/Applications/Xcode.app", sim = xcode + "/Contents/Developer/Applications/Simulator.app"
        let inner = sim + "/Contents/Helpers/Inner.app", tool = xcode + "/Contents/Developer/usr/bin/git"
        func p(_ path: String) -> String { Compiler.pattern(forPath: path) }
        func order(_ c: O, _ wanted: [String]) -> [String: Int] {
            var at: [String: Int] = [:]
            for (n, r) in rules(c).enumerated() where outbound(r) != nil { for x in paths(r) ?? [] where wanted.contains(x) && at[x] == nil { at[x] = n } }
            return at
        }
        func dnsOrder(_ c: O) -> [String: Int] {
            var at: [String: Int] = [:]
            for (n, r) in dnsRules(c).enumerated() { for x in paths(r) ?? [] where at[x] == nil { at[x] = n } }
            return at
        }
        // Xcode on Direct, Simulator inside it on a VPN: "direct" sorts first, yet Simulator's rule comes first.
        var s = example
        s.apps = ["xcode": DIRECT, "sim": "us", "git": "it"]
        let c = try compile(s, apps: ["xcode": [p(xcode)], "sim": [p(sim)], "git": [p(tool)]])
        var at = order(c, [p(xcode), p(sim), p(tool)])
        XCTAssertLessThan(try XCTUnwrap(at[p(sim)]), try XCTUnwrap(at[p(xcode)]))
        XCTAssertLessThan(try XCTUnwrap(at[p(tool)]), try XCTUnwrap(at[p(xcode)]))
        XCTAssertTrue(rules(c).contains { outbound($0) == "r-us" && paths($0) == [p(sim)] })
        // Alternating routes: outer and inner on us, the middle on it ("it" sorts before "us").
        s.apps = ["xcode": "us", "sim": "it", "inner": "us"]
        let alt = try compile(s, apps: ["xcode": [p(xcode)], "sim": [p(sim)], "inner": [p(inner)]])
        at = order(alt, [p(xcode), p(sim), p(inner)])
        XCTAssertLessThan(try XCTUnwrap(at[p(inner)]), try XCTUnwrap(at[p(sim)]))
        XCTAssertLessThan(try XCTUnwrap(at[p(sim)]), try XCTUnwrap(at[p(xcode)]))
        XCTAssertEqual(outbound(rules(alt)[at[p(inner)]!]), "r-us")
        XCTAssertEqual(outbound(rules(alt)[at[p(sim)]!]), "r-it")
        let d = dnsOrder(alt)
        XCTAssertLessThan(try XCTUnwrap(d[p(inner)]), try XCTUnwrap(d[p(sim)]))
        XCTAssertLessThan(try XCTUnwrap(d[p(sim)]), try XCTUnwrap(d[p(xcode)]))
        XCTAssertEqual(lookup(alt, "TXT", "example.com", from: inner + "/Contents/MacOS/Inner"), "dns-r-us")
        XCTAssertEqual(lookup(alt, "TXT", "example.com", from: sim + "/Contents/MacOS/Simulator"), "dns-r-it")
        XCTAssertEqual(lookup(alt, "TXT", "example.com", from: xcode + "/Contents/MacOS/Xcode"), "dns-r-us")
        // Merely alike paths aren't nested.
        XCTAssertFalse(Compiler.contains(p(xcode), p("/Applications/Xcode.app2/x")))
        XCTAssertFalse(Compiler.contains(p(xcode), p(xcode)))
        XCTAssertFalse(Compiler.contains(p(tool), p(tool + "/x")))
        XCTAssertTrue(Compiler.contains(p(xcode), p(tool)))
        // Block still comes first: a blocked outer bundle blocks what is inside it.
        s.apps = ["xcode": BLOCK, "sim": "us"]
        let blocked = try compile(s, apps: ["xcode": [p(xcode)], "sim": [p(sim)]])
        XCTAssertEqual(action(try XCTUnwrap(rules(blocked).first { paths($0) != nil })), "reject")
        // An app on the default route inside a bundle with another route keeps its own rule, connections and lookups; one
        // that isn't nested needs none.
        let other = "/Applications/Other.app"
        var ds = example
        ds.home = Home(); ds.defaultRoute = DIRECT
        ds.apps = ["xcode": "us", "sim": DIRECT, "other": DIRECT]
        let nested = try compile(ds, apps: ["xcode": [p(xcode)], "sim": [p(sim)], "other": [p(other)]])
        at = order(nested, [p(xcode), p(sim)])
        XCTAssertLessThan(try XCTUnwrap(at[p(sim)]), try XCTUnwrap(at[p(xcode)]))
        XCTAssertEqual(outbound(rules(nested)[at[p(sim)]!]), "direct")
        XCTAssertEqual(lookup(nested, "TXT", "example.com", from: sim + "/Contents/MacOS/Simulator"), "local")
        XCTAssertEqual(lookup(nested, "TXT", "example.com", from: xcode + "/Contents/MacOS/Xcode"), "dns-r-us")
        XCTAssertFalse(rules(nested).contains { paths($0)?.contains(p(other)) == true })
        XCTAssertFalse(dnsRules(nested).contains { paths($0)?.contains(p(other)) == true })
        // With a VPN as the default, the same.
        ds.defaultRoute = "nl"
        ds.apps = ["xcode": "us", "sim": "nl", "other": "nl"]
        let vpn = try compile(ds, apps: ["xcode": [p(xcode)], "sim": [p(sim)], "other": [p(other)]])
        at = order(vpn, [p(xcode), p(sim)])
        XCTAssertEqual(outbound(rules(vpn)[try XCTUnwrap(at[p(sim)])]), "r-nl")
        XCTAssertLessThan(try XCTUnwrap(at[p(sim)]), try XCTUnwrap(at[p(xcode)]))
        XCTAssertEqual(lookup(vpn, "TXT", "example.com", from: sim + "/Contents/MacOS/Simulator"), "dns-r-nl")
        XCTAssertFalse(rules(vpn).contains { paths($0)?.contains(p(other)) == true })
    }

    /// An app inside another's bundle put back on the default route the way the app does it (the setup then keeps no entry
    /// for it) stays on the default route the list shows, connections and lookups, instead of following the outer app's.
    func testAnAppPutBackOnTheDefaultInsideABundleRoutedElsewhereStaysOnTheDefault() throws {
        let xcode = "/Applications/Xcode.app", sim = xcode + "/Contents/Developer/Applications/Simulator.app"
        let other = "/Applications/Other.app"
        func p(_ path: String) -> String { Compiler.pattern(forPath: path) }
        func at(_ c: O, _ pattern: String) -> Int? { rules(c).firstIndex { (outbound($0) != nil || action($0) == "reject") && paths($0)?.contains(pattern) == true } }
        // What the app finds here: Simulator and Other are listed but on the default route.
        let apps = ["xcode": [p(xcode)], "sim": [p(sim)], "other": [p(other)]]
        var s = example
        s.home = Home()
        AppMove.apply(["xcode": DIRECT, "sim": "us"], to: &s)
        AppMove.apply(["sim": "nl"], to: &s)
        XCTAssertNil(s.apps["sim"])
        XCTAssertEqual(s.routeOf("sim"), "nl")
        XCTAssertEqual(Compiler.nestedDefaults(s, apps), ["sim"])
        let direct = try compile(s, apps: apps)
        XCTAssertEqual(outbound(rules(direct)[try XCTUnwrap(at(direct, p(sim)))]), "r-nl")
        XCTAssertLessThan(try XCTUnwrap(at(direct, p(sim))), try XCTUnwrap(at(direct, p(xcode))))
        XCTAssertEqual(outbound(rules(direct)[try XCTUnwrap(at(direct, p(xcode)))]), "direct")
        XCTAssertEqual(lookup(direct, "TXT", "example.com", from: sim + "/Contents/MacOS/Simulator"), "dns-r-nl")
        XCTAssertNil(at(direct, p(other)))
        // Outer on another VPN: the same.
        AppMove.apply(["xcode": "us"], to: &s)
        let vpn = try compile(s, apps: apps)
        XCTAssertEqual(outbound(rules(vpn)[try XCTUnwrap(at(vpn, p(sim)))]), "r-nl")
        XCTAssertLessThan(try XCTUnwrap(at(vpn, p(sim))), try XCTUnwrap(at(vpn, p(xcode))))
        // Outer blocked: Block still refuses what is inside it.
        AppMove.apply(["xcode": BLOCK], to: &s)
        XCTAssertEqual(Compiler.nestedDefaults(s, apps), [])
        XCTAssertEqual(action(try XCTUnwrap(rules(try compile(s, apps: apps)).first { paths($0) != nil })), "reject")
        // Outer on the default too: no rule needed.
        AppMove.apply(["xcode": "nl"], to: &s)
        XCTAssertEqual(Compiler.nestedDefaults(s, apps), [])
        // A change that failed twice: with a VPN default, Simulator is refused with the VPN apps, not let out with Xcode.
        AppMove.apply(["xcode": DIRECT], to: &s)
        let deny = try denyAll(s, apps: apps)
        XCTAssertEqual(action(rules(deny)[try XCTUnwrap(at(deny, p(sim)))]), "reject")
        XCTAssertLessThan(try XCTUnwrap(at(deny, p(sim))), try XCTUnwrap(at(deny, p(xcode))))
    }

    /// A bundle with id `id` at `path`, as a scan reads it.
    private func makeApp(_ path: String, _ id: String) throws {
        try FileManager.default.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
        XCTAssertTrue(NSDictionary(dictionary: ["CFBundleIdentifier": id]).write(toFile: path + "/Contents/Info.plist", atomically: true))
    }

    /// One catalogue scan of `root`, as `AppCatalog.load` runs it: every copy known of the apps listed, added, routed or
    /// kept (`ls`: what LaunchServices knows, `running`: bundles running), and those inside another bundle. Returns the
    /// copies known, from which the catalogue builds each app's patterns.
    @discardableResult
    private func rescan(_ n: inout NestedApps, _ s: Setup, _ root: String, ls: [String: [String]] = [:], running: [String: [String]] = [:],
                        added: [String: [String]] = [:]) -> [String: [String]] {
        n.scanning()
        let scan = AppScan.scan([(root, false)], skip: nil)
        let known = NestedApps.known(scan, added: added, others: Array(s.apps.keys) + n.kept, launchServices: { ls[$0] ?? [] }, running: running)
        n.scanned(NestedApps.inside(known), asked: Set(known.keys), listed: Set(scan.apps.map(\.id)).union(added.keys))
        return known
    }

    /// The patterns the catalogue hands the compiler (`AppCatalog.routingKeys`, then `patterns(for:)`): every routed app,
    /// and each app on the default route with a copy inside the bundle of one routed elsewhere.
    private func routing(_ s: Setup, _ n: NestedApps, _ known: [String: [String]]) -> [String: [String]] {
        func patterns(_ keys: [String]) -> [String: [String]] { Dictionary(uniqueKeysWithValues: keys.map { ($0, AppPaths.bundle(known[$0] ?? [])) }) }
        let routed = Array(s.apps.keys)
        return patterns(routed + Compiler.nestedDefaults(s, patterns(routed + n.candidates(s))))
    }

    /// The route a process at `path` leaves by: the first rule naming it that sends or refuses.
    private func leaves(_ c: O, _ path: String) -> String? {
        rules(c).first { (outbound($0) != nil || action($0) == "reject") && AppPaths.matches(strings($0["process_path_regex"]), path) }
            .map { outbound($0) ?? "reject" }
    }

    /// An app listed by a link (in /Applications) that leads into another app's bundle, on the default route with the
    /// outer app on Direct: its own rule keeps it on the default, across rescans and a restart (a new catalogue).
    func testAnAppListedByALinkIntoABundleRoutedElsewhereStaysOnTheDefault() throws {
        let fm = FileManager.default
        let made = AppPaths.real(fm.temporaryDirectory.path) + "/unbraid-nest-\(UUID())"
        defer { try? fm.removeItem(atPath: made) }
        let root = made + "/Applications", outer = root + "/Outer.app", inner = outer + "/Contents/Helpers/Inner.app"
        try makeApp(outer, "test.outer")
        try makeApp(inner, "test.inner")
        try fm.createSymbolicLink(atPath: root + "/Inner.app", withDestinationPath: inner)
        var s = example
        s.apps = [:]
        AppMove.apply(["test.outer": DIRECT], to: &s)
        var n = NestedApps()
        let known = rescan(&n, s, root)
        // Listed by the link, which is in no bundle; where it leads, it is.
        XCTAssertEqual(known["test.inner"], [root + "/Inner.app"])
        XCTAssertEqual(n.candidates(s), ["test.inner"])
        let process = inner + "/Contents/MacOS/Inner"
        XCTAssertEqual(leaves(try compile(s, apps: routing(s, n, known)), process), "r-nl")
        // Rescanned (as at every launch, activation or folder change): the same, with nothing carried over.
        rescan(&n, s, root)
        XCTAssertEqual(leaves(try compile(s, apps: routing(s, n, known)), process), "r-nl")
        // A restart: a catalogue with nothing but what is saved finds it again at its first scan.
        var fresh = NestedApps(kept: n.kept)
        let again = rescan(&fresh, s, root)
        XCTAssertEqual(leaves(try compile(s, apps: routing(s, fresh, again)), process), "r-nl")
        XCTAssertEqual(n.kept, [])
        // The outer app on another VPN: the same; blocked, it refuses what is inside it; on the default, no rule needed.
        AppMove.apply(["test.outer": "us"], to: &s)
        XCTAssertEqual(leaves(try compile(s, apps: routing(s, n, known)), process), "r-nl")
        AppMove.apply(["test.outer": BLOCK], to: &s)
        XCTAssertEqual(leaves(try compile(s, apps: routing(s, n, known)), process), "reject")
        AppMove.apply(["test.outer": "nl"], to: &s)
        XCTAssertEqual(routing(s, n, known), [:])
    }

    /// A listed app with a second copy inside another app's bundle that only LaunchServices knows (or that runs, or was
    /// added by hand): on the default route, that copy keeps to the default too, after the app was routed and put back,
    /// at every rescan, and after a restart.
    func testACopyOnlyLaunchServicesKnowsInsideABundleRoutedElsewhereStaysOnTheDefault() throws {
        let fm = FileManager.default
        let made = AppPaths.real(fm.temporaryDirectory.path) + "/unbraid-nest-\(UUID())"
        defer { try? fm.removeItem(atPath: made) }
        let root = made + "/Applications", outer = root + "/Outer.app", listed = root + "/Tool.app", copy = outer + "/Contents/Library/Tool.app"
        try makeApp(outer, "test.outer")
        try makeApp(listed, "test.tool")
        try makeApp(copy, "test.tool")
        let ls = ["test.tool": [listed, copy]]
        var s = example
        s.apps = [:]
        AppMove.apply(["test.outer": DIRECT, "test.tool": "us"], to: &s)
        var n = NestedApps()
        rescan(&n, s, root, ls: ls)
        XCTAssertEqual(n.candidates(s), [])
        AppMove.apply(["test.tool": "nl"], to: &s)
        XCTAssertNil(s.apps["test.tool"])
        n.returned(["test.tool"], s) { _ in [] }
        let process = copy + "/Contents/MacOS/Tool"
        // Rescanned once it is back on the default route: LaunchServices is asked about every app listed, routed or not.
        let known = rescan(&n, s, root, ls: ls)
        XCTAssertEqual(n.candidates(s), ["test.tool"])
        XCTAssertEqual(leaves(try compile(s, apps: routing(s, n, known)), process), "r-nl")
        XCTAssertEqual(leaves(try compile(s, apps: routing(s, n, known)), outer + "/Contents/MacOS/Outer"), "direct")
        // Listed by the scan, it needs keeping no more.
        XCTAssertEqual(n.kept, [])
        // A restart.
        var fresh = NestedApps(kept: n.kept)
        let again = rescan(&fresh, s, root, ls: ls)
        XCTAssertEqual(leaves(try compile(s, apps: routing(s, fresh, again)), process), "r-nl")
        // The same copy seen running, or added by hand, instead.
        for (running, added) in [(["test.tool": [copy]], [String: [String]]()), ([:], ["test.tool": [copy]])] {
            var other = NestedApps()
            let k = rescan(&other, s, root, running: running, added: added)
            XCTAssertEqual(leaves(try compile(s, apps: routing(s, other, k)), process), "r-nl")
        }
    }

    /// An app that exists only inside another app's bundle (Simulator inside Xcode) is listed only while it is routed. Put
    /// back on the default route, no scan lists it any more: it is kept by id, so it keeps its rule at every rescan and
    /// after a restart, and is let go once no copy inside a bundle is left.
    func testAnAppOnlyInsideABundlePutBackOnTheDefaultKeepsItsRule() throws {
        let fm = FileManager.default
        let made = AppPaths.real(fm.temporaryDirectory.path) + "/unbraid-nest-\(UUID())"
        defer { try? fm.removeItem(atPath: made) }
        let root = made + "/Applications", outer = root + "/Outer.app", sim = outer + "/Contents/Developer/Applications/Sim.app"
        try makeApp(outer, "test.outer")
        try makeApp(sim, "test.sim")
        var ls = ["test.sim": [sim]]
        var s = example
        s.apps = [:]
        AppMove.apply(["test.outer": DIRECT, "test.sim": "us"], to: &s)
        var n = NestedApps()
        rescan(&n, s, root, ls: ls)
        AppMove.apply(["test.sim": "nl"], to: &s)
        n.returned(["test.sim"], s) { _ in [] }
        XCTAssertEqual(n.kept, ["test.sim"])
        let process = sim + "/Contents/MacOS/Sim"
        var known = rescan(&n, s, root, ls: ls)
        XCTAssertEqual(n.candidates(s), ["test.sim"])
        XCTAssertEqual(leaves(try compile(s, apps: routing(s, n, known)), process), "r-nl")
        // A change that failed twice: refused with the VPN apps, not let out Direct with the outer app.
        XCTAssertEqual(leaves(try denyAll(s, apps: routing(s, n, known)), process), "reject")
        // A restart: only the id is saved.
        var fresh = NestedApps(kept: n.kept)
        known = rescan(&fresh, s, root, ls: ls)
        XCTAssertEqual(leaves(try compile(s, apps: routing(s, fresh, known)), process), "r-nl")
        // Put back on the default before any scan saw it: kept by the copy the catalogue knows from its route.
        var early = NestedApps()
        early.returned(["test.sim"], s) { _ in [sim] }
        XCTAssertEqual(early.kept, ["test.sim"])
        // Kept while a scan ran that didn't ask about it: not let go by that scan.
        early.scanned([:], asked: ["test.outer"], listed: [])
        XCTAssertEqual(early.candidates(s), ["test.sim"])
        // Added by hand while a scan ran, one that scan asks about (it read only another copy) or not: kept; the next scan,
        // which reads it, decides.
        for asked in [["test.sim"], ["test.outer"]] as [Set<String>] {
            var adding = NestedApps()
            adding.scanning()
            adding.found(NestedApps.inside(["test.sim": [sim]]))
            adding.scanned([:], asked: asked, listed: ["test.sim"])
            XCTAssertEqual(adding.candidates(s), ["test.sim"])
            adding.scanning()
            adding.scanned([:], asked: ["test.sim"], listed: ["test.sim"])
            XCTAssertEqual(adding.candidates(s), [])
        }
        // Put back on the default before any scan saw it, its only copy known a link from elsewhere into the outer bundle
        // (LaunchServices'): kept, by where the link leads, and found again at the next scan and after a restart.
        let link = made + "/Elsewhere/Sim.app"
        try fm.createDirectory(atPath: made + "/Elsewhere", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link, withDestinationPath: sim)
        var linked = NestedApps()
        linked.returned(["test.sim"], s) { _ in [link] }
        XCTAssertEqual(linked.kept, ["test.sim"])
        known = rescan(&linked, s, root, ls: ["test.sim": [link]])
        XCTAssertEqual(leaves(try compile(s, apps: routing(s, linked, known)), process), "r-nl")
        var restarted = NestedApps(kept: linked.kept)
        known = rescan(&restarted, s, root, ls: ["test.sim": [link]])
        XCTAssertEqual(leaves(try compile(s, apps: routing(s, restarted, known)), process), "r-nl")
        // On the default route because its route became the default (or by any other change of the setup): kept too.
        var t = s
        AppMove.apply(["test.sim": "us"], to: &t)
        var promoted = NestedApps()
        rescan(&promoted, t, root, ls: ["test.sim": [sim]])
        t.defaultRoute = "us"
        t.apps = t.apps.filter { $0.value != "us" }
        promoted.returned(["test.sim"], t) { _ in [] }
        known = rescan(&promoted, t, root, ls: ["test.sim": [sim]])
        XCTAssertEqual(leaves(try compile(t, apps: routing(t, promoted, known)), process), "r-us")
        // Its copy gone: let go.
        ls = [:]
        rescan(&fresh, s, root, ls: ls)
        XCTAssertEqual(fresh.kept, [])
        XCTAssertEqual(fresh.candidates(s), [])
    }

    /// Apps not inside another bundle, and apps routed on their own (nested or not), are passed to the compiler as before.
    func testAppsNotNestedOrRoutedOnTheirOwnAreRoutedAsBefore() throws {
        let fm = FileManager.default
        let made = AppPaths.real(fm.temporaryDirectory.path) + "/unbraid-nest-\(UUID())"
        defer { try? fm.removeItem(atPath: made) }
        let root = made + "/Applications", outer = root + "/Outer.app", inner = outer + "/Contents/Helpers/Inner.app"
        try makeApp(outer, "test.outer")
        try makeApp(inner, "test.inner")
        try makeApp(root + "/Plain.app", "test.plain")
        try fm.createSymbolicLink(atPath: root + "/Inner.app", withDestinationPath: inner)
        var s = example
        s.apps = [:]
        AppMove.apply(["test.outer": DIRECT, "test.inner": "us"], to: &s)
        var n = NestedApps()
        let known = rescan(&n, s, root, ls: ["test.plain": [root + "/Plain.app"]], running: ["test.plain": [root + "/Plain.app"]])
        XCTAssertEqual(n.candidates(s), [])
        XCTAssertNil(n.copies["test.plain"])
        XCTAssertEqual(Set(routing(s, n, known).keys), ["test.outer", "test.inner"])
        XCTAssertEqual(leaves(try compile(s, apps: routing(s, n, known)), inner + "/Contents/MacOS/Inner"), "r-us")
        XCTAssertNil(leaves(try compile(s, apps: routing(s, n, known)), root + "/Plain.app/Contents/MacOS/Plain"))
        // Routed on its own and put back: no different from never routed.
        AppMove.apply(["test.inner": "nl"], to: &s)
        n.returned(["test.inner"], s) { _ in [] }
        rescan(&n, s, root)
        XCTAssertEqual(n.kept, [])
        XCTAssertEqual(Set(routing(s, n, known).keys), ["test.outer", "test.inner"])
    }

    /// git routes its helpers too (libexec/git-core, as a folder); a helper routed on its own is nested in that folder, so
    /// its rule comes first whatever the route ids, with the volume's case folding (`(?i)`) on both.
    func testAGitHelperRoutedOnItsOwnComesBeforeGitsHelperFolder() throws {
        let fm = FileManager.default
        let made = fm.temporaryDirectory.appending(path: "unbraid-git-\(UUID())").path
        try fm.createDirectory(atPath: made, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: made) }
        // As the kernel reports it (/private/var), so the patterns are those of the files themselves.
        let root = AppPaths.real(made)
        for f in ["/bin/git", "/libexec/git-core/git-remote-https"] {
            try fm.createDirectory(atPath: root + (f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            XCTAssertTrue(fm.createFile(atPath: root + f, contents: Data()))
        }
        let git = root + "/bin/git", helper = root + "/libexec/git-core/git-remote-https"
        let gitPatterns = AppPaths.tool(git, developerDirs: []), helperPatterns = AppPaths.tool(helper, developerDirs: [])
        let core = try XCTUnwrap(gitPatterns.first { $0.hasSuffix("/") })
        let fold = Compiler.volumeIgnoresCase(root) ? "(?i)" : ""
        // The folder keeps the compiler's form (case folding, anchor) and ends in an unescaped "/".
        XCTAssertEqual(core, String(Compiler.pattern(forPath: root + "/libexec/git-core").dropLast()) + "/")
        XCTAssertTrue(core.hasPrefix(fold + "^"))
        XCTAssertTrue(AppPaths.matches([core], helper))
        XCTAssertFalse(AppPaths.matches([core], root + "/libexec/git-core2/x"))
        let literal = Compiler.pattern(forPath: helper)
        XCTAssertEqual(helperPatterns, [literal])
        XCTAssertTrue(Compiler.contains(core, literal))
        var s = example
        s.home = Home()
        s.routes += [Route(id: "a", loc: Location(countryId: 81, countryCode: "DE", country: "Germany"), hue: 3),
                     Route(id: "z", loc: Location(countryId: 74, countryCode: "FR", country: "France"), hue: 4)]
        s.apps = [git: "a", helper: "z"]
        let c = try compile(s, apps: [git: gitPatterns, helper: helperPatterns])
        let rs = rules(c)
        let mine = try XCTUnwrap(rs.firstIndex { outbound($0) != nil && paths($0)?.contains(literal) == true })
        let theirs = try XCTUnwrap(rs.firstIndex { outbound($0) != nil && paths($0)?.contains(core) == true })
        XCTAssertLessThan(mine, theirs)
        XCTAssertEqual(outbound(rs[mine]), "r-z")
        XCTAssertEqual(outbound(rs[theirs]), "r-a")
        XCTAssertFalse(paths(rs[mine])!.contains(core))
        // Its lookups too.
        let ds = dnsRules(c)
        let myDns = try XCTUnwrap(ds.firstIndex { paths($0)?.contains(literal) == true })
        XCTAssertEqual(ds[myDns]["server"] as? String, "dns-r-z")
        XCTAssertLessThan(myDns, try XCTUnwrap(ds.firstIndex { paths($0)?.contains(core) == true }))
        // Whatever this volume does: folded patterns nest by their folded paths, and a folded folder holds a path
        // spelled in another case.
        func folder(_ path: String) -> String { String(Compiler.pattern(forPath: path, ignoringCase: true).dropLast()) + "/" }
        XCTAssertTrue(Compiler.contains(folder("/X/libexec/git-core"), Compiler.pattern(forPath: "/x/LIBEXEC/git-core/git-remote-https", ignoringCase: true)))
        XCTAssertTrue(AppPaths.matches([folder("/X/libexec/git-core")], "/x/LIBEXEC/Git-Core/git-remote-https"))
        XCTAssertFalse(Compiler.contains(folder("/X/libexec/git-core"), Compiler.pattern(forPath: "/X/libexec/git-core2/h", ignoringCase: true)))
    }

    func testPatternForPath() throws {
        func matches(_ pattern: String, _ path: String) throws -> Bool {
            try NSRegularExpression(pattern: pattern).firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
        }
        let app = Compiler.pattern(forPath: "/Applications/Foo Bar.app")
        XCTAssertTrue(app.hasPrefix("(?i)^") && app.hasSuffix("/"))
        XCTAssertTrue(app.contains("\\."), "the dot of .app is escaped")
        // Everything inside the bundle, helpers and nested apps included.
        XCTAssertTrue(try matches(app, "/Applications/Foo Bar.app/Contents/MacOS/Foo Bar"))
        XCTAssertTrue(try matches(app, "/Applications/Foo Bar.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"))
        // But no other path that merely resembles it.
        XCTAssertFalse(try matches(app, "/Applications/Foo Bar.app"))
        XCTAssertFalse(try matches(app, "/Applications/Foo BarXapp/Contents/MacOS/x"))
        XCTAssertFalse(try matches(app, "/Applications/Foo Bar.app2/Contents/MacOS/x"))
        XCTAssertFalse(try matches(app, "/Users/me/Applications/Foo Bar.app/Contents/MacOS/x"))

        let tool = Compiler.pattern(forPath: "/usr/bin/curl")
        XCTAssertTrue(tool.hasPrefix("(?i)^") && tool.hasSuffix("$"))
        XCTAssertTrue(try matches(tool, "/usr/bin/curl"))
        XCTAssertFalse(try matches(tool, "/usr/bin/curl2"))
        XCTAssertFalse(try matches(tool, "/opt/usr/bin/curl"))
        XCTAssertFalse(try matches(tool, "/usr/bin/curl/x"))
        // The Mac's volume ignores case, and so does the engine's match: the same app however its path was typed.
        XCTAssertTrue(Compiler.volumeIgnoresCase("/Applications"))
        XCTAssertTrue(try matches(app, "/applications/FOO BAR.APP/Contents/MacOS/Foo Bar"))
        XCTAssertTrue(try matches(tool, "/USR/bin/Curl"))
        XCTAssertTrue(Compiler.pattern(forPath: "/Applications/Foo.APP").hasSuffix("/"))
        // A folder that doesn't exist yet takes its volume's answer.
        XCTAssertTrue(Compiler.volumeIgnoresCase("/Applications/Not There \(UUID()).app/x"))
        // On a case-sensitive volume, case tells apps apart.
        let sensitive = Compiler.pattern(forPath: "/Volumes/CS/Foo.app", ignoringCase: false)
        XCTAssertEqual(sensitive, "^\\/Volumes\\/CS\\/Foo\\.app/")
        XCTAssertFalse(try matches(sensitive, "/Volumes/CS/foo.app/Contents/MacOS/foo"))
        XCTAssertTrue(try matches(sensitive, "/Volumes/CS/Foo.app/Contents/MacOS/foo"))
        // Nesting follows the outer pattern's rule.
        XCTAssertTrue(Compiler.contains(app, Compiler.pattern(forPath: "/applications/foo bar.app/Contents/x.app")))
        XCTAssertFalse(Compiler.contains(sensitive, Compiler.pattern(forPath: "/Volumes/CS/foo.app/x.app", ignoringCase: false)))
        // Regex characters in a path are literal.
        XCTAssertFalse(try matches(Compiler.pattern(forPath: "/opt/a+b/tool"), "/opt/aab/tool"))
        XCTAssertTrue(try matches(Compiler.pattern(forPath: "/opt/a+b/tool"), "/opt/a+b/tool"))
    }

    func testFakeIpPoolAndCachePath() throws {
        let c = try compile(example)
        XCTAssertEqual(dnsServer(c, "fake")?["inet4_range"] as? String, ConfigVet.fakeRanges[0])
        let cache = (c["experimental"] as? O)?["cache_file"] as? O
        XCTAssertEqual(cache?["path"] as? String, "cache.db")
        XCTAssertEqual(cache?["store_fakeip"] as? Bool, true)
    }

    static let fritz = """

    [Interface]
    PrivateKey = aGVsbG8taGVsbG8taGVsbG8taGVsbG8taGVsbG8tMTI=
    Address = 192.168.178.201/24, fd00::201/64
    DNS = 192.168.178.1, fd00::1, fritz.box

    [Peer]
    PublicKey = 5p4RkybdRU5uaDi90eu4KZPTFif0lKCg4Qp6t1c4F30=
    PresharedKey = 5p4RkybdRU5uaDi90eu4KZPTFif0lKCg4Qp6t1c4F30=
    AllowedIPs = 192.168.178.0/24, 0.0.0.0/0, ::/0
    Endpoint = abc.myfritz.net:51820
    PersistentKeepalive = 25

    """
}

// MARK: - DNS policy

/// Every lookup reaches the engine's DNS rules: an app's own sent to the tunnel's resolver carries the app's path, one
/// made through the system resolver carries mDNSResponder's, and the engine's own carry none.
extension CompilerTests {
    fileprivate var mDNSResponder: String { "/usr/sbin/mDNSResponder" }
    fileprivate func path(_ app: String) -> String { "/Applications/\(app).app/Contents/MacOS/\(app)" }

    /// The server (or refusal) the engine's rules pick for a query that reaches the tunnel's resolver: the first DNS rule
    /// whose conditions all hold (`invert` turning the whole rule around, and names compared lowercased without the final
    /// dot, as the engine does), else `final`. It models the rule walk only: not the engine's own lookups (which skip
    /// the fake-IP server), lookups with an explicit server (which skip the rules) or what a resolver then answers.
    fileprivate func lookup(_ c: O, _ type: String, _ query: String, from process: String?, via inbound: String = "tun") -> String? {
        let name = query.lowercased().hasSuffix(".") ? String(query.lowercased().dropLast()) : query.lowercased()
        for r in dnsRules(c) {
            var hit = true
            if let inbounds = r["inbound"] as? [String] { hit = hit && inbounds.contains(inbound) }
            if let types = r["query_type"] as? [String] { hit = hit && types.contains(type) }
            if let suffixes = r["domain_suffix"] as? [String] { hit = hit && suffixes.contains { name == $0 || name.hasSuffix("." + $0) } }
            if let patterns = r["process_path_regex"] as? [String] {
                hit = hit && process.map { p in patterns.contains { (try? NSRegularExpression(pattern: $0))?.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)) != nil } } == true
            }
            if (r["invert"] as? Bool) == true { hit.toggle() }
            guard hit else { continue }
            return r["action"] as? String == "predefined" ? r["rcode"] as? String : r["server"] as? String
        }
        return (c["dns"] as? O)?["final"] as? String
    }

    private static let otherTypes = ["TXT", "MX", "SRV", "HTTPS", "SVCB", "NULL", "ANY", "CNAME", "NS", "SOA", "CAA"]

    func testBlockedAppsLookupsAreRefusedBeforeAnyException() throws {
        var s = example
        s.apps["com.z"] = BLOCK
        s.prefs.killLevel = .internet
        let c = try compile(s, tsSuffix: "tail123.ts.net")
        // Only lookups from a tunnel's far side come before them.
        XCTAssertNotNil(dnsRules(c).first?["inbound"])
        let first = try XCTUnwrap(dnsRules(c).dropFirst().first)
        XCTAssertEqual(paths(first), [pat("com.z")])
        XCTAssertEqual(action(first), "predefined")
        XCTAssertEqual(first["rcode"] as? String, "REFUSED")
        XCTAssertNil(first["query_type"])
        // Every type, tailnet, local and private reverse names included.
        for (type, name) in [("A", "example.com"), ("AAAA", "example.com"), ("TXT", "x.example.com"), ("NULL", "t.example.com"),
                             ("A", "nas.tail123.ts.net"), ("TXT", "fritz.box"), ("PTR", "1.1.168.192.in-addr.arpa"), ("SRV", "_x._udp.local")] {
            XCTAssertEqual(lookup(c, type, name, from: path("com.z")), "REFUSED", "\(type) \(name)")
        }
        // Everyone else is unaffected.
        XCTAssertEqual(lookup(c, "A", "example.com", from: path("com.a")), "fake")
        XCTAssertEqual(lookup(c, "TXT", "example.com", from: path("com.a")), "dns-r-us")
        // Blocking during a pause (nothing but the blocks) too.
        var paused = Setup(routes: [], defaultRoute: DIRECT, apps: ["com.z": BLOCK])
        paused.prefs.killLevel = .internet
        let p = try compile(paused, links: [:], tsSuffix: "tail123.ts.net")
        XCTAssertEqual(action(try XCTUnwrap(dnsRules(p).first)), "predefined")
        for type in ["A", "TXT", "HTTPS"] { XCTAssertEqual(lookup(p, type, "example.com", from: path("com.z")), "REFUSED") }
    }

    func testOtherLookupsFollowTheAppsRouteOrAVpnNeverTheIspWithAVpnDefault() throws {
        let c = try compile(example)
        XCTAssertEqual((c["dns"] as? O)?["final"] as? String, "dns-r-nl")
        // The default is already a VPN: nothing more is needed than `final`.
        XCTAssertFalse(dnsRules(c).contains { $0["invert"] != nil })
        for type in Self.otherTypes {
            XCTAssertEqual(lookup(c, type, "example.com", from: mDNSResponder), "dns-r-nl", type)
            XCTAssertEqual(lookup(c, type, "example.com", from: nil), "dns-r-nl", type)
            XCTAssertEqual(lookup(c, type, "example.com", from: path("com.a")), "dns-r-us", type)
            XCTAssertEqual(lookup(c, type, "example.com", from: path("com.b")), "dns-r-it", type)
            XCTAssertEqual(lookup(c, type, "example.com", from: path("com.x")), "local", type)
            XCTAssertEqual(lookup(c, type, "example.com", from: path("com.unassigned")), "dns-r-nl", type)
        }
        for p in [mDNSResponder, path("com.a"), path("com.x")] {
            XCTAssertEqual(lookup(c, "A", "example.com", from: p), "fake")
            XCTAssertEqual(lookup(c, "AAAA", "example.com", from: p), "fake")
        }
    }

    func testWithDirectAsTheDefaultOtherLookupsStayLocal() throws {
        var s = example
        s.defaultRoute = DIRECT
        s.home = Home()
        let c = try compile(s)
        XCTAssertEqual((c["dns"] as? O)?["final"] as? String, "local")
        // Nothing sends the rest to a VPN: lookups through the system resolver are the local network's, as without apps on
        // a VPN (service discovery, Kerberos, captive portals). Apps on a VPN keep their own lookups on their route.
        XCTAssertFalse(dnsRules(c).contains { $0["invert"] != nil })
        for type in Self.otherTypes.filter({ $0 != "HTTPS" && $0 != "SVCB" }) + ["PTR"] {
            let name = type == "PTR" ? "8.8.8.8.in-addr.arpa" : "example.com"
            XCTAssertEqual(lookup(c, type, name, from: mDNSResponder), "local", type)
            XCTAssertEqual(lookup(c, type, name, from: nil), "local", type)
            XCTAssertEqual(lookup(c, type, name, from: path("com.unassigned")), "local", type)
            XCTAssertEqual(lookup(c, type, name, from: path("com.x")), "local", type)
            XCTAssertEqual(lookup(c, type, name, from: path("com.a")), "dns-r-us", type)
            XCTAssertEqual(lookup(c, type, name, from: path("com.b")), "dns-r-it", type)
        }
        XCTAssertEqual(lookup(c, "A", "example.com", from: mDNSResponder), "fake")
        XCTAssertEqual(lookup(c, "A", "example.com", from: path("com.a")), "fake")
        // Apps on Direct need no rule of their own: they follow the default.
        XCTAssertFalse(dnsRules(c).contains { paths($0) == [pat("com.x"), pat("com.y")] })
        // The order of the routes doesn't matter.
        s.routes = [s.routes[2], s.routes[0], s.routes[1]]
        XCTAssertEqual(lookup(try compile(s), "TXT", "example.com", from: mDNSResponder), "local")
        XCTAssertEqual(lookup(try compile(s), "TXT", "example.com", from: path("com.b")), "dns-r-it")
        // A Tailscale exit's apps keep theirs on the tailnet.
        var ts = example
        ts.home = Home(); ts.defaultRoute = DIRECT
        ts.routes = [Route(id: "ts", tsExit: "100.101.102.103", hue: 4)] + ts.routes
        ts.apps["com.n"] = "ts"
        let t = try compile(ts)
        XCTAssertEqual(lookup(t, "SRV", "_x._tcp.example.com", from: path("com.n")), "dns-r-ts")
        XCTAssertEqual(lookup(t, "SRV", "_x._tcp.example.com", from: mDNSResponder), "local")
        XCTAssertEqual(dnsServer(t, "dns-r-ts")?["detour"] as? String, "home-ts")
    }

    func testOpenVpnPushedResolverCanTakeTheOtherLookups() throws {
        let p = try Manual.parseOvpn(Fixture.text("ovpn/expressvpn.ovpn"), name: "ex", username: "u", password: "p")
        let s = Setup(routes: [Route(id: "ex", ovpn: p)], defaultRoute: DIRECT, apps: ["com.e": "ex", "com.x": DIRECT])
        let c = try compile(s, links: ["ex": .ovpn(sv("ex"), p)])
        XCTAssertEqual(dnsServer(c, "dns-ovpn-r-ex")?["type"] as? String, "openvpn")
        XCTAssertEqual(lookup(c, "TXT", "example.com", from: path("com.e")), "dns-ovpn-r-ex")
        XCTAssertEqual(lookup(c, "TXT", "example.com", from: mDNSResponder), "local")
        XCTAssertEqual(lookup(c, "TXT", "example.com", from: path("com.x")), "local")
        // As the default, it takes the rest.
        let d = try compile(Setup(routes: [Route(id: "ex", ovpn: p)], defaultRoute: "ex", apps: ["com.x": DIRECT]), links: ["ex": .ovpn(sv("ex"), p)])
        XCTAssertEqual(lookup(d, "TXT", "example.com", from: mDNSResponder), "dns-ovpn-r-ex")
        XCTAssertEqual(lookup(d, "TXT", "example.com", from: path("com.x")), "local")
    }

    func testWithNoVpnLookupsStayLocalAndBlockedBrowsersGetNoHints() throws {
        // Only blocks (a pause, or Direct with blocked apps): nothing to forward to, so local, as accepted; HTTPS and SVCB
        // through mDNSResponder are answered empty so a blocked browser's hints don't go out.
        var s = Setup(routes: [], defaultRoute: DIRECT, apps: ["com.z": BLOCK, "com.x": DIRECT])
        s.prefs.killLevel = .internet
        let c = try compile(s, links: [:])
        XCTAssertEqual(lookup(c, "TXT", "example.com", from: mDNSResponder), "local")
        XCTAssertEqual(lookup(c, "HTTPS", "example.com", from: mDNSResponder), "NOERROR")
        XCTAssertEqual(lookup(c, "SVCB", "example.com", from: mDNSResponder), "NOERROR")
        XCTAssertEqual(lookup(c, "TXT", "example.com", from: path("com.x")), "local")
        XCTAssertEqual(lookup(c, "TXT", "example.com", from: path("com.z")), "REFUSED")
        XCTAssertFalse(dnsRules(c).contains { $0["invert"] != nil })
        // Nothing blocked, nothing on a VPN: no rules for either.
        let plain = try compile(Setup(routes: [], defaultRoute: DIRECT, apps: ["com.x": DIRECT]), links: [:])
        XCTAssertFalse(dnsRules(plain).contains { $0["invert"] != nil || $0["rcode"] != nil })
        XCTAssertEqual(lookup(plain, "HTTPS", "example.com", from: mDNSResponder), "local")
    }

    func testPrivateReverseLookupsStayLocalPublicOnesDoNot() throws {
        // With a VPN as the default (whose `final` would otherwise take them) and with Direct, for an app on a VPN.
        for vpnDefault in [true, false] {
            var s = example
            s.defaultRoute = vpnDefault ? "nl" : DIRECT
            s.home = Home()
            let c = try compile(s)
            let rest = vpnDefault ? "dns-r-nl" : "local"
            for name in ["5.0.0.10.in-addr.arpa", "1.0.16.172.in-addr.arpa", "1.0.31.172.in-addr.arpa", "1.178.168.192.in-addr.arpa",
                         "1.1.254.169.in-addr.arpa", "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.d.f.ip6.arpa",
                         "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.e.f.ip6.arpa", "b.e.f.ip6.arpa"] {
                XCTAssertEqual(lookup(c, "PTR", name, from: mDNSResponder), "local", name)
                XCTAssertEqual(lookup(c, "PTR", name, from: path("com.a")), "local", name)
            }
            // Public addresses, and ranges that merely start alike, are not local.
            for name in ["8.8.8.8.in-addr.arpa", "1.0.15.172.in-addr.arpa", "1.0.32.172.in-addr.arpa", "1.1.168.193.in-addr.arpa",
                         "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.e.f.ip6.arpa", "1.0.0.2.ip6.arpa", "110.in-addr.arpa"] {
                XCTAssertEqual(lookup(c, "PTR", name, from: mDNSResponder), rest, name)
                XCTAssertEqual(lookup(c, "PTR", name, from: path("com.a")), "dns-r-us", name)
            }
            // Only reverse lookups: another type under those names follows the rest.
            XCTAssertEqual(lookup(c, "TXT", "5.0.0.10.in-addr.arpa", from: path("com.a")), "dns-r-us")
            XCTAssertEqual(lookup(c, "PTR", "5.0.0.10.IN-ADDR.ARPA.", from: mDNSResponder), "local")
            // With LAN access off too (unlike local names): no VPN's resolver can answer them.
            s.prefs.lan = false
            let off = try compile(s)
            XCTAssertEqual(lookup(off, "PTR", "5.0.0.10.in-addr.arpa", from: path("com.a")), "local")
            XCTAssertEqual(lookup(off, "TXT", "fritz.box", from: path("com.a")), "dns-r-us")
            // A blocked app's are refused first, like the rest of its lookups.
            s.apps["com.z"] = BLOCK
            s.prefs.killLevel = .internet
            XCTAssertEqual(lookup(try compile(s), "PTR", "5.0.0.10.in-addr.arpa", from: path("com.z")), "REFUSED")
        }
        XCTAssertEqual(lookup(try compile(example), "TXT", "FRITZ.BOX.", from: mDNSResponder), "local")
    }

    func testHomeTailscaleAloneSendsNothingToAVpn() throws {
        // Reaching the tailnet is no exit: with Direct as the default and no route in use, other lookups stay local.
        let s = Setup(routes: [], defaultRoute: DIRECT, apps: ["com.x": DIRECT], home: Home(tailscale: true))
        let c = try compile(s, links: [:], tsSuffix: "tail123.ts.net")
        XCTAssertEqual(lookup(c, "TXT", "example.com", from: mDNSResponder), "local")
        XCTAssertEqual(lookup(c, "TXT", "nas.tail123.ts.net", from: mDNSResponder), "dns-tailnet")
        XCTAssertFalse(dnsRules(c).contains { $0["invert"] != nil || $0["rcode"] != nil && $0["inbound"] == nil })
    }

    func testTailnetNamesKeepTheirResolver() throws {
        let c = try compile(example, tsSuffix: "tail123.ts.net")
        XCTAssertEqual(lookup(c, "A", "nas.tail123.ts.net", from: mDNSResponder), "dns-tailnet")
        XCTAssertEqual(lookup(c, "TXT", "nas.tail123.ts.net", from: path("com.a")), "dns-tailnet")
        var direct = example
        direct.defaultRoute = DIRECT
        XCTAssertEqual(lookup(try compile(direct, tsSuffix: "tail123.ts.net"), "SRV", "_x._tcp.nas.tail123.ts.net", from: mDNSResponder), "dns-tailnet")
    }

    /// Reverse lookups of tailnet addresses (100.64/10, fd7a:115c:a1e0::/48), any type, go to the tailnet's resolver while
    /// the tailnet is reached, not to the local network's or a VPN's (where the tailnet's DNS sends them then is its own).
    func testTailnetReverseLookupsStayOnTheTailnet() throws {
        let v6 = "4.3.2.1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.e.1.a.c.5.1.1.a.7.d.f.ip6.arpa"
        for vpnDefault in [true, false] {
            var s = example
            s.defaultRoute = vpnDefault ? "nl" : DIRECT
            s.apps["com.z"] = BLOCK
            s.prefs.killLevel = .internet
            let c = try compile(s, tsSuffix: "tail123.ts.net")
            for name in ["5.6.64.100.in-addr.arpa", "1.2.127.100.in-addr.arpa", "100.100.100.100.in-addr.arpa", v6] {
                for type in ["PTR", "TXT", "A"] {
                    XCTAssertEqual(lookup(c, type, name, from: mDNSResponder), "dns-tailnet", "\(type) \(name)")
                    XCTAssertEqual(lookup(c, type, name, from: path("com.a")), "dns-tailnet", "\(type) \(name)")
                }
                XCTAssertEqual(lookup(c, "PTR", name, from: path("com.z")), "REFUSED")
            }
            // Next door: the ISP's shared range around it, and other unique-local addresses (local, as any private one).
            XCTAssertEqual(lookup(c, "PTR", "1.2.63.100.in-addr.arpa", from: path("com.a")), "dns-r-us")
            XCTAssertEqual(lookup(c, "PTR", "1.2.128.100.in-addr.arpa", from: path("com.a")), "dns-r-us")
            XCTAssertEqual(lookup(c, "PTR", "1.1.e.1.a.c.5.1.1.a.7.d.f.ip6.arpa", from: path("com.a")), "local")
        }
        // Tailscale only for an exit, the tailnet not reached: no tailnet resolver, they follow the rest.
        var exit = example
        exit.home = Home()
        exit.routes.append(Route(id: "ts", tsExit: "100.101.102.103", hue: 4)); exit.apps["com.n"] = "ts"
        let e = try compile(exit)
        XCTAssertNil(dnsServer(e, "dns-tailnet"))
        XCTAssertEqual(lookup(e, "PTR", "5.6.64.100.in-addr.arpa", from: mDNSResponder), "dns-r-nl")
        XCTAssertEqual(lookup(e, "PTR", v6, from: mDNSResponder), "local")
    }
}

// MARK: - Golden configs

/// The exact bytes the compiler writes for a spread of setups, frozen before refactoring it: every refactor step must
/// reproduce them. A missing or changed fixture fails; run with UPDATE_GOLDEN=1 to write them after an intended change.
extension CompilerTests {
    private var goldenDir: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/golden") }

    private func goldenCases() throws -> [(String, String)] {
        var out: [(String, String)] = []
        func add(_ name: String, _ s: Setup, links: [String: Link]? = nil, tsSuffix: String? = nil, probe: (port: Int, password: String)? = nil) throws {
            out.append((name, try raw(s, links: links, tsSuffix: tsSuffix, probe: probe)))
        }
        try add("example", example)
        for blocked: Set<String> in [["us"], ["nl"]] {
            let input = Compiler.Input(setup: example, links: links(example).filter { !blocked.contains($0.key) }, blocked: blocked,
                                       apps: patterns(example), selfPattern: Compiler.pattern(forPath: selfApp), tsSuffix: nil)
            out.append(("blocked-\(blocked.first!)", try Compiler.compile(input)))
        }
        var direct = example; direct.defaultRoute = DIRECT
        try add("direct-default", direct)
        try add("probe", example, probe: (port: 40123, password: "p"))
        try add("empty", Setup(routes: [], defaultRoute: DIRECT), links: [:])
        var internet = example; internet.apps["com.blocked"] = BLOCK; internet.prefs.killLevel = .internet
        try add("kill-internet-blocked", internet)
        var home = internet; home.prefs.killLevel = .home
        try add("kill-home-blocked", home)
        var lanOff = example; lanOff.prefs.lan = false
        try add("lan-off", lanOff)
        var wg = example; wg.routes.append(Route(id: "w1", wg: try WgConf.parse(Self.fritz, name: "Home box"), hue: 3)); wg.apps["com.c"] = "w1"
        try add("custom-wireguard", wg)
        let ssUser = Data("chacha20-ietf-poly1305:secret".utf8).base64EncodedString()
        var ss = example
        ss.routes.append(Route(id: "s1", ss: try Manual.parseSs("ss://\(ssUser)@ss.example.net:8388/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dexample.com#Mine"), hue: 4))
        ss.apps["com.c"] = "s1"
        try add("shadowsocks-plugin", ss)
        var exit = example; exit.home = Home(); exit.routes.append(Route(id: "ts", tsExit: "nas", hue: 4)); exit.apps["com.n"] = "ts"
        try add("tailscale-exit", exit)
        var homeWg = example
        homeWg.home = Home(subnets: ["10.42.0.0/16"], wg: try WgConf.parse(Self.fritz, name: "Home"))
        homeWg.routes.append(Route(id: "ts", tsExit: "100.101.102.103", hue: 4)); homeWg.apps["com.n"] = "ts"
        try add("home-wireguard-and-exit", homeWg)
        let ovpn = try Manual.parseOvpn(Fixture.text("ovpn/nord-double.udp.ovpn"), name: "dv", username: "u", password: "p")
        var other = ovpn; other.username = "other"
        var openvpn = example; openvpn.home = Home()
        openvpn.routes = [nl(), Route(id: "ex", loc: Location(provider: "expressvpn", countryCode: "JP", country: "Japan"))]
        openvpn.apps = ["com.e": "ex"]
        try add("openvpn", openvpn, links: ["nl": .ovpn(sv("nl"), ovpn), "ex": .ovpn(sv("exx"), other)])
        var headscale = example; headscale.home.tsControlUrl = "https://hs.example.com"
        try add("headscale", headscale)
        try add("tailnet-suffix", example, tsSuffix: "tail123.ts.net")
        var paused = Setup(routes: [], defaultRoute: DIRECT, apps: ["com.blocked": BLOCK], favorites: [], prefs: Prefs())
        paused.prefs.killLevel = .internet
        try add("paused", paused, links: [:], tsSuffix: "tail123.ts.net")
        var tsDefault = example; tsDefault.home = Home(); tsDefault.home.tsControlUrl = "https://1-control.example.com"
        tsDefault.routes.append(Route(id: "ts", tsExit: "nas", hue: 4)); tsDefault.defaultRoute = "ts"
        try add("tailscale-default-exit-headscale-probe", tsDefault, probe: (port: 40123, password: "p"))
        try add("direct-default-home-tailscale-probe", direct, probe: (port: 40123, password: "p"))
        try add("probe-no-exits", Setup(routes: [], defaultRoute: DIRECT), links: [:], probe: (port: 40123, password: "p"))
        var filteredRoutes = example; filteredRoutes.prefs.filter = Filter(id: "quad9", routes: true)
        try add("filter-vpn-routes", filteredRoutes)
        var filteredDefault = direct; filteredDefault.prefs.filter = Filter(id: "quad9", direct: true)
        try add("filter-direct-default", filteredDefault)
        var filteredApps = example; filteredApps.prefs.filter = Filter(id: "quad9", apps: ["com.x": true])
        try add("filter-direct-apps", filteredApps)
        return out
    }

    /// The goldens are compared as text; this also has the engine unbraid ships build each of them. Skipped, visibly,
    /// on a Mac without tools/build-cli.sh's build (every other compiled config is then checked by ConfigVet only).
    func testThePinnedEngineAcceptsEveryGoldenConfig() throws {
        guard let engine = try ProviderFixtures.engine() else { throw XCTSkip("sing-box-cli-mac not found: run tools/build-cli.sh") }
        for (name, config) in try goldenCases() {
            let refusal = ProviderFixtures.engineRefusal(config, engine)
            XCTAssertNil(refusal, "\(name): \(refusal ?? "")")
        }
        // And it is a check: a value it can't decode is refused, naming the field but never the value (it can be a key).
        XCTAssertEqual(ProviderFixtures.engineRefusal(#"{"dns":{"rules":[{"action":"predefined","rcode":"NOPE"}]}}"#, engine), "refused at dns.rules[0].rcode")
        let key = "dW5icmFpZC10ZXN0LXByaXZhdGUta2V5LTAwMDAwMDE="
        let refusal = ProviderFixtures.engineRefusal(#"{"endpoints":[{"type":"\#(key)","tag":"x"}]}"#, engine)
        XCTAssertNotNil(refusal)
        XCTAssertFalse(refusal?.contains(key) ?? true)
    }

    func testEngineRefusalsNeverQuoteValues() {
        let key = "dW5icmFpZC10ZXN0LXByaXZhdGUta2V5LTAwMDAwMDE="
        let decode = "FATAL[0000] decode config at /tmp/x/config.json: endpoints[0].private_key: illegal base64 \(key)"
        XCTAssertEqual(ProviderFixtures.refusalReason(decode, 1), "refused at endpoints[0].private_key")
        for out in ["FATAL[0000] create service: initialize endpoint[0]: \(key)", "FATAL[0000] decode config at /tmp/x/config.json: \(key): x", ""] {
            XCTAssertFalse(ProviderFixtures.refusalReason(out, 1).contains(key), out)
        }
    }

    /// The CLI's stamp (tools/build-cli.sh) names the source commit and the patches it was built with: another commit, a
    /// patch added, dropped, renamed or changed since, or a stamp left beside another binary, and the CLI is refused. Same
    /// format as the script writes.
    func testTheEngineCheckRefusesACliBuiltWithOtherPatches() throws {
        let empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let a = "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"
        let pin = "c005f35300ce76427dc285481ec5695f5b179cd2", other = "0000cac5124465ffdb145870d7c01885566711b1"
        XCTAssertEqual(ProviderFixtures.enginePin(), pin, "tools/build-libbox.sh pins the reviewed engine release")
        // The engine's OpenVPN module is patched too (tools/build-libbox.sh), so its patches are part of the stamp.
        let names = ProviderFixtures.enginePatches()?.map(\.name) ?? []
        XCTAssertTrue(names.contains("sing-box-darwin-udp-owner.patch"))
        XCTAssertTrue(names.contains("sing-box-z-deps-security.patch"))
        XCTAssertTrue(names.contains { $0.hasPrefix("sing-box-") } && names.contains { $0.hasPrefix("sing-openvpn-") }, "\(names)")
        let patches = [(name: "sing-box-b.patch", data: Data("a".utf8)), (name: "sing-box-a.patch", data: Data())]
        XCTAssertEqual(ProviderFixtures.stamp(source: pin, patches: patches, binary: Data("a".utf8)),
                       "source \(pin)\npatch sing-box-a.patch \(empty)\npatch sing-box-b.patch \(a)\nbinary \(a)\n")
        let dir = FileManager.default.temporaryDirectory.appending(path: "unbraid-stamp-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appending(path: "cli"), stamp = dir.appending(path: "cli.patches")
        try Data("a".utf8).write(to: bin)
        try Data(ProviderFixtures.stamp(source: pin, patches: patches, binary: Data("a".utf8)).utf8).write(to: stamp)
        XCTAssertTrue(ProviderFixtures.matchesStamp(bin, source: pin, patches: patches))
        XCTAssertTrue(ProviderFixtures.matchesStamp(bin, source: pin, patches: patches.reversed()))
        XCTAssertFalse(ProviderFixtures.matchesStamp(bin, source: other, patches: patches))
        XCTAssertFalse(ProviderFixtures.matchesStamp(bin, source: pin, patches: patches + [(name: "sing-box-c.patch", data: Data("c".utf8))]))
        XCTAssertFalse(ProviderFixtures.matchesStamp(bin, source: pin, patches: [patches[0]]))
        XCTAssertFalse(ProviderFixtures.matchesStamp(bin, source: pin, patches: [(name: "sing-box-b.patch", data: Data("b".utf8)), patches[1]]))
        XCTAssertFalse(ProviderFixtures.matchesStamp(bin, source: pin, patches: [(name: "sing-box-z.patch", data: Data("a".utf8)), patches[1]]))
        let withModule = patches + [(name: "sing-openvpn-a.patch", data: Data("a".utf8))]
        XCTAssertEqual(ProviderFixtures.stamp(source: pin, patches: withModule.reversed(), binary: Data("a".utf8)),
                       "source \(pin)\npatch sing-box-a.patch \(empty)\npatch sing-box-b.patch \(a)\npatch sing-openvpn-a.patch \(a)\nbinary \(a)\n")
        XCTAssertFalse(ProviderFixtures.matchesStamp(bin, source: pin, patches: withModule))
        // A stamp from before the source line (patches and binary only) is refused too.
        try Data(ProviderFixtures.stamp(source: pin, patches: patches, binary: Data("a".utf8)).utf8.dropFirst("source \(pin)\n".utf8.count)).write(to: stamp)
        XCTAssertFalse(ProviderFixtures.matchesStamp(bin, source: pin, patches: patches))
        try Data(ProviderFixtures.stamp(source: pin, patches: patches, binary: Data("a".utf8)).utf8).write(to: stamp)
        try Data("b".utf8).write(to: bin)
        XCTAssertFalse(ProviderFixtures.matchesStamp(bin, source: pin, patches: patches))
        try Data("a".utf8).write(to: bin)
        try FileManager.default.removeItem(at: stamp)
        XCTAssertFalse(ProviderFixtures.matchesStamp(bin, source: pin, patches: patches))
    }

    func testTagCheckFindsWhatTheEngineWouldMiss() throws {
        var c = try parse(try raw(example))
        XCTAssertEqual(tagProblems(c), [])
        var dns = c["dns"] as! O
        dns["rules"] = (dns["rules"] as! [O]) + [["server": "nope"]]
        dns["servers"] = (dns["servers"] as! [O]) + [["type": "openvpn", "tag": "o", "endpoint": "direct"], ["type": "tailscale", "tag": "t", "endpoint": "r-nl"],
                                                   ["type": "udp", "tag": "u", "server": "9.9.9.9", "detour": "gone"]]
        c["dns"] = dns
        var route = c["route"] as! O
        route["final"] = "missing"
        c["route"] = route
        XCTAssertEqual(Set(tagProblems(c)), ["dns rule to nope", "resolver endpoint direct", "resolver endpoint r-nl", "resolver detour gone", "route final missing"])
    }

    /// With the filter on for Direct traffic, lookups macOS makes for apps on a VPN would reach the filter from this Mac's
    /// own address: HTTPS and SVCB are answered empty, as they are with the local resolver.
    func testDirectFilterKeepsHttpsLookupsOfVpnAppsEmpty() throws {
        let config = try XCTUnwrap(try goldenCases().first { $0.0 == "filter-direct-default" }?.1)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let rules = try XCTUnwrap((json["dns"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertTrue(rules.contains { ($0["query_type"] as? [String]) == ["HTTPS", "SVCB"] && $0["rcode"] as? String == "NOERROR" })
    }

    func testCompiledConfigsMatchTheGoldenFixtures() throws {
        let update = ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1"
        for (name, config) in try goldenCases() {
            let url = goldenDir.appending(path: "\(name).json")
            if update {
                try FileManager.default.createDirectory(at: goldenDir, withIntermediateDirectories: true)
                try Data(config.utf8).write(to: url)
            } else {
                XCTAssertEqual(try? Data(contentsOf: url), Data(config.utf8), "\(name): the compiled config changed, or its fixture is missing")
            }
        }
    }
}
