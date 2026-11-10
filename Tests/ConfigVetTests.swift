import XCTest

/// What the tunnel extension requires of every configuration it runs, beyond refusing what the compiler never writes.
final class ConfigVetTests: XCTestCase {
    func testDirectDefaultSplitGoldenRefusesOwnerlessConnectionsAndPassesVet() throws {
        let text = Fixture.text("golden/direct-default.json")
        XCTAssertNoThrow(try ConfigVet.check(text))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let route = try XCTUnwrap(config["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, "direct")
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let ownerless = try XCTUnwrap(rules.first { $0["type"] as? String == "logical" })
        XCTAssertEqual(ownerless["action"] as? String, "reject")
        XCTAssertEqual(ownerless["mode"] as? String, "and")
    }

    private func goldens() throws -> [(String, String)] {
        let dir = try XCTUnwrap(Bundle(for: Fixture.self).resourceURL).appending(path: "Fixtures/golden")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertFalse(names.isEmpty)
        return names.map { ($0, Fixture.text("golden/\($0)")) }
    }

    private func example() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Fixture.text("golden/example.json").utf8)) as? [String: Any])
    }

    private func refused(_ change: (inout [String: Any]) -> Void) throws -> Bool {
        var c = try example()
        change(&c)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: c), as: UTF8.self)
        return (try? ConfigVet.check(text)) == nil
    }

    private func edit(_ c: inout [String: Any], _ section: String, _ f: (inout [String: Any]) -> Void) {
        var o = c[section] as? [String: Any] ?? [:]
        f(&o)
        c[section] = o
    }

    /// An OpenVPN tunnel's pushed resolver is named after the tunnel, not a route, so routes sharing it share one.
    func testProtectionServerShapesAndReferences() throws {
        var config = try example()
        var dns = try XCTUnwrap(config["dns"] as? [String: Any])
        var servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        servers.append(["type": "https", "tag": "filter-test", "server": "9.9.9.9", "server_port": 443,
                        "path": "/dns-query", "tls": ["enabled": true, "server_name": "dns.quad9.net"]])
        dns["servers"] = servers; config["dns"] = dns
        func check(_ value: [String: Any]) throws { _ = try ConfigVet.check(String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self)) }
        XCTAssertNoThrow(try check(config))
        servers[servers.count - 1]["domain_resolver"] = "missing"
        dns["servers"] = servers; config["dns"] = dns
        XCTAssertThrowsError(try check(config))
        servers[servers.count - 1].removeValue(forKey: "domain_resolver")
        servers[servers.count - 1]["tls"] = ["enabled": true, "server_name": "dns.quad9.net", "insecure": true]
        dns["servers"] = servers; config["dns"] = dns
        XCTAssertThrowsError(try check(config))
        // Its TLS switch is a true, not a number that Foundation would read as one.
        for enabled: Any in [1, 1.0] {
            servers[servers.count - 1]["tls"] = ["enabled": enabled, "server_name": "dns.quad9.net"]
            dns["servers"] = servers; config["dns"] = dns
            XCTAssertThrowsError(try check(config), "\(enabled)")
        }
        servers[servers.count - 1]["tls"] = ["enabled": true, "server_name": "dns.quad9.net"]
        dns["servers"] = servers; config["dns"] = dns
        XCTAssertNoThrow(try check(config))
    }

    func testSharedOpenVpnResolverTagIsAccepted() throws {
        let config = try golden("openvpn")
        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        let resolver = try XCTUnwrap(servers.first { $0["type"] as? String == "openvpn" })
        XCTAssertEqual(resolver["tag"] as? String, "dns-ovpn-\(resolver["endpoint"] as? String ?? "")")
        let data = try JSONSerialization.data(withJSONObject: config)
        XCTAssertNoThrow(try ConfigVet.check(String(decoding: data, as: UTF8.self)))
    }

    func testTailscaleLoginRulesAreAccepted() throws {
        var config = try golden("tailscale-exit")
        var route = try XCTUnwrap(config["route"] as? [String: Any])
        var rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        rules.append(["domain_suffix": ["tailscale.com", "tailscale.io"], "outbound": "direct",
                      "process_path_regex": ["^/Applications/test.app/"]])
        rules.append(["domain": ["hs.example.com"], "outbound": "direct"])
        route["rules"] = rules; config["route"] = route
        let text = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        XCTAssertNoThrow(try ConfigVet.check(text))
    }

    func testEveryCompiledShapePassesAndCheckingTwiceChangesNothing() throws {
        // Direct-only, paused (blocking only), probe, OpenVPN, Tailscale, Shadowsocks, custom WireGuard: all of them.
        for (name, config) in try goldens() {
            let checked = try ConfigVet.check(config)
            // The sealed copy is the checked one: its revision must be the one the app was given.
            XCTAssertEqual(try ConfigVet.check(checked), checked, name)
        }
    }

    func testFakeBlocksRotateAndLegacyConfigsAreRewritten() throws {
        var legacy = try golden("example")
        var dns = try XCTUnwrap(legacy["dns"] as? [String: Any])
        var servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        let index = try XCTUnwrap(servers.firstIndex { $0["type"] as? String == "fakeip" })
        servers[index]["inet4_range"] = "198.18.0.0/15"
        dns["servers"] = servers
        legacy["dns"] = dns
        var route = try XCTUnwrap(legacy["route"] as? [String: Any])
        route["rules"] = (route["rules"] as? [[String: Any]] ?? []).filter { $0["no_drop"] == nil }
        legacy["route"] = route
        let old = try ConfigVet.check(String(decoding: JSONSerialization.data(withJSONObject: legacy), as: UTF8.self))
        var block = 0
        for _ in 0..<16 {
            let rewritten = try ConfigVet.fakeBlock(old, block)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rewritten.utf8)) as? [String: Any])
            let dns = try XCTUnwrap(json["dns"] as? [String: Any])
            let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
            XCTAssertEqual(servers.first { $0["type"] as? String == "fakeip" }?["inet4_range"] as? String, ConfigVet.fakeRanges[block])
            XCTAssertNoThrow(try ConfigVet.check(rewritten))
            XCTAssertEqual(try ConfigVet.fakeBlock(rewritten, block), rewritten)
            block = ConfigVet.nextFakeBlock(block)
        }
        XCTAssertEqual(block, 0)
        XCTAssertThrowsError(try ConfigVet.fakeBlock(old, 8))
    }

    func testFakeBlockRequiresItsExactGuard() throws {
        var config = try golden("example")
        rules(&config, "route") { rules in
            let index = rules.firstIndex { $0["no_drop"] != nil }!
            rules[index]["ip_cidr"] = Array(ConfigVet.fakeRanges.dropLast())
        }
        XCTAssertFalse(passes(config))
        var missing = try golden("example")
        rules(&missing, "route") { $0.removeAll { $0["no_drop"] != nil } }
        XCTAssertFalse(passes(missing))
        for range in ["198.18.0.0/16", "198.18.1.0/18", "198.20.0.0/18"] {
            XCTAssertFalse(passes(try item("example", "dns.servers", "fakeip") { $0["inet4_range"] = range }))
        }
    }

    func testNoDropRefusalsSurviveFakeBlockRotation() throws {
        var config = try golden("example")
        let refusals: [[String: Any]] = [
            ["process_path_regex": ["^/Applications/test.app/"], "action": "reject", "no_drop": true],
            ["action": "reject", "no_drop": true],
            ["ip_cidr": ["0.0.0.0/32", "::/128"], "action": "reject", "no_drop": true],
        ]
        rules(&config, "route") { $0.append(contentsOf: refusals) }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        let checked = try ConfigVet.check(text)
        let rotated = try ConfigVet.fakeBlock(checked, 1)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rotated.utf8)) as? [String: Any])
        let route = try XCTUnwrap(result["route"] as? [String: Any])
        let resultRules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        for refusal in refusals { XCTAssertTrue(resultRules.contains { $0 as NSDictionary == refusal as NSDictionary }) }
        let unspecified: [String: Any] = ["ip_cidr": ["0.0.0.0/32", "::/128"], "action": "reject", "no_drop": true]
        XCTAssertTrue(resultRules.contains { $0 as NSDictionary == unspecified as NSDictionary })
        XCTAssertEqual(resultRules.filter { $0 as NSDictionary == unspecified as NSDictionary }.count,
                       ((config["route"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []).filter { $0 as NSDictionary == unspecified as NSDictionary }.count)
        for bad: [String: Any] in [
            ["action": "reject", "no_drop": false],
            ["action": "reject", "no_drop": true, "port": 53],
            ["action": "resolve", "server": "local", "no_drop": true],
        ] {
            var invalid = config
            rules(&invalid, "route") { $0.append(bad) }
            XCTAssertFalse(passes(invalid))
        }
    }

    func testOnlyTheExactUnspecifiedAddressRefusalIsAccepted() throws {
        var config = try golden("example")
        let refusal: [String: Any] = ["ip_cidr": ["0.0.0.0/32", "::/128"], "action": "reject", "no_drop": true]
        rules(&config, "route") { $0.append(refusal) }
        XCTAssertTrue(passes(config))
        for ranges in [["0.0.0.0/32", "::1/128"], ["0.0.0.0/32", "::/128", "1.1.1.1/32"], ["0.0.0.0/32", "0.0.0.0/32"]] {
            var invalid = config
            rules(&invalid, "route") { $0[$0.count - 1]["ip_cidr"] = ranges }
            XCTAssertFalse(passes(invalid))
        }
    }

    func testOpenVPNFallbackMustBeIPv4() throws {
        XCTAssertTrue(passes(try item("openvpn", "dns.servers", "openvpn") { $0["fallback_server"] = "9.9.9.9" }))
        for bad: Any in ["example.com", "::1", "1.2.3.999", "01.2.3.4", true] {
            XCTAssertFalse(passes(try item("openvpn", "dns.servers", "openvpn") { $0["fallback_server"] = bad }))
        }
    }

    func testAnEmptyOrHeadlessConfigIsRefused() throws {
        for text in ["{}", #"{"inbounds":[{"type":"tun","tag":"tun"}]}"#, #"{"route":{"final":"direct"},"outbounds":[{"type":"direct","tag":"direct"}]}"#] {
            XCTAssertThrowsError(try ConfigVet.check(text), text)
        }
    }

    func testExactlyOneTun() throws {
        XCTAssertTrue(try refused { $0["inbounds"] = [] })
        XCTAssertTrue(try refused { $0["inbounds"] = nil })
        XCTAssertTrue(try refused { c in
            let tun = (c["inbounds"] as! [[String: Any]])[0]
            c["inbounds"] = [tun, tun]
        })
        XCTAssertFalse(try refused { _ in })
    }

    func testTheFinalRouteMustNameAnExit() throws {
        XCTAssertTrue(try refused { edit(&$0, "route") { $0["final"] = nil } })
        XCTAssertTrue(try refused { edit(&$0, "route") { $0["final"] = "" } })
        XCTAssertTrue(try refused { edit(&$0, "route") { $0["final"] = "attacker" } })
        XCTAssertTrue(try refused { edit(&$0, "route") { $0["final"] = 1 } })
        // Endpoints count as exits too.
        XCTAssertFalse(try refused { edit(&$0, "route") { $0["final"] = "home-ts" } })
        XCTAssertFalse(try refused { edit(&$0, "route") { $0["final"] = "direct" } })
    }

    func testExitTagsArePresentAndUnique() throws {
        XCTAssertTrue(try refused { c in
            var o = c["outbounds"] as! [[String: Any]]
            o.append(["type": "direct", "tag": "direct"])
            c["outbounds"] = o
        })
        XCTAssertTrue(try refused { c in
            var o = c["outbounds"] as! [[String: Any]]
            o.append(["type": "direct"])
            c["outbounds"] = o
        })
    }

    func testResolversAndEveryNameForThemMustExist() throws {
        XCTAssertTrue(try refused { edit(&$0, "dns") { $0["servers"] = [] } })
        XCTAssertTrue(try refused { $0["dns"] = nil })
        XCTAssertTrue(try refused { edit(&$0, "dns") { $0["final"] = nil } })
        XCTAssertTrue(try refused { edit(&$0, "dns") { $0["final"] = "attacker" } })
        XCTAssertTrue(try refused { edit(&$0, "dns") { d in
            var s = d["servers"] as! [[String: Any]]
            s.append(["type": "local", "tag": "local"])
            d["servers"] = s
        } })
        // A resolver that leaves through an exit that doesn't exist.
        XCTAssertTrue(try refused { edit(&$0, "dns") { d in
            var s = d["servers"] as! [[String: Any]]
            s.append(["type": "udp", "tag": "x", "server": "10.0.0.1", "detour": "attacker"])
            d["servers"] = s
        } })
        XCTAssertTrue(try refused { edit(&$0, "dns") { d in
            var s = d["servers"] as! [[String: Any]]
            s.append(["type": "tailscale", "tag": "x", "endpoint": "nowhere"])
            d["servers"] = s
        } })
        // Rules, logical ones included, and the route's own lookups.
        XCTAssertTrue(try refused { edit(&$0, "dns") { d in
            d["rules"] = (d["rules"] as! [[String: Any]]) + [["domain_suffix": ["x"], "server": "attacker"]]
        } })
        XCTAssertTrue(try refused { edit(&$0, "dns") { d in
            d["rules"] = (d["rules"] as! [[String: Any]]) + [["type": "logical", "mode": "or", "rules": [["domain_suffix": ["x"], "server": "attacker"]]]]
        } })
        XCTAssertTrue(try refused { edit(&$0, "dns") { $0["rules"] = "x" } })
        XCTAssertTrue(try refused { edit(&$0, "route") { $0["default_domain_resolver"] = "attacker" } })
        XCTAssertTrue(try refused { edit(&$0, "route") { r in
            r["rules"] = (r["rules"] as! [[String: Any]]) + [["action": "resolve", "server": "attacker"]]
        } })
        // A resolver's own "server" is its address, not a name.
        XCTAssertFalse(try refused { edit(&$0, "dns") { d in
            var s = d["servers"] as! [[String: Any]]
            s.append(["type": "udp", "tag": "x", "server": "10.0.0.1", "detour": "direct"])
            d["servers"] = s
        } })
        // Rules that name no resolver (a refusal) are fine.
        XCTAssertFalse(try refused { edit(&$0, "dns") { d in
            var rules = d["rules"] as! [[String: Any]]
            rules.insert(["domain_suffix": ["x"], "action": "predefined", "rcode": "REFUSED"], at: 1)
            d["rules"] = rules
        } })
    }

    func testEachUsersEngineKeepsTailscaleInItsOwnFolder() throws {
        func tailscale(_ json: String) throws -> [[String: Any]] {
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return root.filter { ["endpoints", "outbounds"].contains($0.key.lowercased()) }.flatMap { ($0.value as? [[String: Any]]) ?? [] }
                .filter { ($0.first { $0.key.lowercased() == "type" }?.value as? String)?.lowercased() == "tailscale" }
        }
        var seen = 0
        for (name, golden) in try goldens() {
            let checked = try ConfigVet.check(golden)
            let owned = try ConfigVet.owned(checked, by: 501)
            let before = try tailscale(checked), after = try tailscale(owned)
            XCTAssertEqual(before.count, after.count, name)
            for ts in after { XCTAssertEqual(ts["state_directory"] as? String, "tailscale-501", name) }
            seen += after.count
            // Nothing else changes: put the folder back and it is the checked config again.
            var back = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(owned.utf8)) as? [String: Any])
            for section in ["endpoints", "outbounds"] {
                back[section] = (back[section] as? [[String: Any]])?.map { o in
                    var o = o
                    if (o["type"] as? String) == "tailscale" { o["state_directory"] = "tailscale" }
                    return o
                }
            }
            let text = String(decoding: try JSONSerialization.data(withJSONObject: back, options: [.withoutEscapingSlashes, .sortedKeys]), as: UTF8.self)
            XCTAssertEqual(text, checked, name)
            if before.isEmpty { XCTAssertEqual(owned, checked, name) }
        }
        XCTAssertGreaterThan(seen, 0)
        // Names in any case, the engine's way of reading them; one without a folder gets one (the engine's default is shared).
        let odd = #"{"Endpoints":[{"Type":"Tailscale","tag":"ts","State_Directory":"tailscale"},{"type":"tailscale","tag":"ts2"}],"outbounds":[{"type":"direct","tag":"direct"}]}"#
        let owned = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ConfigVet.owned(odd, by: 0).utf8)) as? [String: Any])
        let eps = try XCTUnwrap(owned["Endpoints"] as? [[String: Any]])
        XCTAssertEqual(eps[0]["state_directory"] as? String, "tailscale-0")
        XCTAssertNil(eps[0]["State_Directory"])
        XCTAssertEqual(eps[1]["state_directory"] as? String, "tailscale-0")
        XCTAssertNil((owned["outbounds"] as? [[String: Any]])?.first?["state_directory"])
        XCTAssertThrowsError(try ConfigVet.owned("not json", by: 501))
    }

    /// What runs when a change and its rollback both fail: the tunnel stays, nothing leaves but unbraid itself and
    /// what the rules before it send direct; every other connection is refused and every other lookup too. The extension
    /// must accept that shape.
    func testADenyAllConfigurationPasses() throws {
        var c = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Fixture.text("golden/paused.json").utf8)) as? [String: Any])
        edit(&c, "route") { r in r["rules"] = (r["rules"] as? [Any] ?? []) + [["action": "reject"]] }
        edit(&c, "dns") { d in d["rules"] = (d["rules"] as? [Any] ?? []) + [["action": "predefined", "rcode": "REFUSED"]] }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: c), as: UTF8.self)
        XCTAssertNoThrow(try ConfigVet.check(text))
    }

    func testBlockedRouteRefusalShapesPassWithoutRelaxingInboundGuards() throws {
        var c = try example()
        edit(&c, "route") { r in r["rules"] = (r["rules"] as? [Any] ?? []) + [["process_path_regex": ["^/app$"], "action": "reject"], ["action": "reject"]] }
        edit(&c, "dns") { d in d["rules"] = (d["rules"] as? [Any] ?? []) + [["process_path_regex": ["^/app$"], "action": "predefined", "rcode": "REFUSED"], ["action": "predefined", "rcode": "REFUSED"]] }
        func text(_ c: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: c), as: UTF8.self) }
        XCTAssertNoThrow(try ConfigVet.check(text(c)))
        edit(&c, "route") { r in
            var rules = r["rules"] as? [[String: Any]] ?? []
            rules.insert(["action": "reject"], at: 0)
            r["rules"] = rules
        }
        XCTAssertThrowsError(try ConfigVet.check(text(c)))
    }

    /// One sealed Tailscale state per user: a second node would overwrite the first one's.
    func testAtMostOneTailscaleNode() throws {
        let name = try XCTUnwrap(try goldens().first { $0.1.contains("\"tailscale\"") && $0.1.contains("\"endpoints\"") }?.0)
        var c = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Fixture.text("golden/\(name)").utf8)) as? [String: Any])
        var endpoints = try XCTUnwrap(c["endpoints"] as? [[String: Any]])
        var ts = try XCTUnwrap(endpoints.first { $0["type"] as? String == "tailscale" })
        XCTAssertNoThrow(try ConfigVet.check(String(decoding: try JSONSerialization.data(withJSONObject: c), as: UTF8.self)))
        ts["tag"] = "second-ts"
        endpoints.append(ts)
        c["endpoints"] = endpoints
        XCTAssertThrowsError(try ConfigVet.check(String(decoding: try JSONSerialization.data(withJSONObject: c), as: UTF8.self)))
    }

    // MARK: Only what the compiler writes

    private func golden(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Fixture.text("golden/\(name).json").utf8)) as? [String: Any])
    }

    private func passes(_ c: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: c) else { return false }
        return (try? ConfigVet.check(String(decoding: data, as: UTF8.self))) != nil
    }

    /// [golden] with [change] made to the first item of [type] in [section] ("inbounds", "endpoints", "outbounds" or
    /// "dns.servers").
    private func item(_ name: String, _ section: String, _ type: String, _ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var c = try golden(name)
        let path = section.split(separator: ".").map(String.init)
        var parent = path.count == 2 ? c[path[0]] as? [String: Any] ?? [:] : c
        var list = try XCTUnwrap(parent[path.last!] as? [[String: Any]], "\(name) \(section)")
        let i = try XCTUnwrap(list.firstIndex { $0["type"] as? String == type }, "\(name) has no \(type)")
        change(&list[i])
        parent[path.last!] = list
        if path.count == 2 { c[path[0]] = parent } else { c = parent }
        return c
    }

    private func rules(_ c: inout [String: Any], _ section: String, _ f: (inout [[String: Any]]) -> Void) {
        edit(&c, section) { s in
            var r = s["rules"] as? [[String: Any]] ?? []
            f(&r)
            s["rules"] = r
        }
    }

    /// Every field the engine takes but the compiler never writes, risky or not, is refused wherever it
    /// appears; the same item without it passes.
    func testEveryFieldTheCompilerNeverWritesIsRefused() throws {
        let cases: [(golden: String, section: String, type: String, field: String, value: Any)] = [
            ("example", "endpoints", "tailscale", "relay_server_port", 40000),
            ("example", "endpoints", "tailscale", "relay_server_static_endpoints", ["0.0.0.0:40000"]),
            ("example", "endpoints", "tailscale", "advertise_exit_node", true),
            ("example", "endpoints", "tailscale", "advertise_routes", ["192.168.0.0/16"]),
            ("example", "endpoints", "tailscale", "advertise_tags", ["tag:x"]),
            ("example", "endpoints", "tailscale", "ssh_server", true),
            ("example", "endpoints", "tailscale", "system_interface", true),
            ("example", "endpoints", "tailscale", "system_interface_name", "utun9"),
            ("example", "endpoints", "tailscale", "udp_timeout", "5m"),
            ("example", "endpoints", "tailscale", "detour", "direct"),
            ("example", "endpoints", "wireguard", "system", true),
            ("example", "endpoints", "wireguard", "name", "utun9"),
            ("example", "endpoints", "wireguard", "listen_port", 51820),
            ("example", "endpoints", "wireguard", "detour", "direct"),
            ("openvpn", "endpoints", "openvpn-client", "system", true),
            ("openvpn", "endpoints", "openvpn-client", "detour", "direct"),
            ("openvpn", "endpoints", "openvpn-client", "bind_interface", "en0"),
            ("probe", "inbounds", "mixed", "set_system_proxy", true),
            ("probe", "inbounds", "mixed", "tls", ["enabled": true]),
            ("probe", "inbounds", "mixed", "detour", "probe"),
            ("example", "inbounds", "tun", "platform", ["http_proxy": ["enabled": true]]),
            ("example", "inbounds", "tun", "include_uid", [0]),
            ("example", "outbounds", "direct", "bind_interface", "en0"),
            ("example", "outbounds", "direct", "detour", "direct"),
            ("shadowsocks-plugin", "outbounds", "shadowsocks", "udp_over_tcp", true),
            ("shadowsocks-plugin", "outbounds", "shadowsocks", "multiplex", ["enabled": true]),
            ("example", "dns.servers", "local", "detour", "direct"),
            ("example", "dns.servers", "udp", "client_subnet", "1.2.3.0/24"),
        ]
        for c in cases {
            XCTAssertTrue(passes(try item(c.golden, c.section, c.type) { _ in }), "\(c.golden) as it is")
            XCTAssertFalse(passes(try item(c.golden, c.section, c.type) { $0[c.field] = c.value }), "\(c.type).\(c.field)")
            // Names in any case, as the engine reads them.
            XCTAssertFalse(passes(try item(c.golden, c.section, c.type) { $0[c.field.uppercased()] = c.value }), "\(c.type).\(c.field)")
        }
        // Nested objects too.
        XCTAssertFalse(passes(try item("example", "endpoints", "wireguard") { e in
            var peers = e["peers"] as! [[String: Any]]
            peers[0]["reserved"] = [1, 2, 3]
            e["peers"] = peers
        }))
        XCTAssertFalse(passes(try item("openvpn", "endpoints", "openvpn-client") { e in
            var tls = e["tls"] as! [String: Any]
            tls["certificate_path"] = "/etc/x"
            e["tls"] = tls
        }))
        XCTAssertFalse(passes(try item("openvpn", "endpoints", "openvpn-client") { e in
            var tls = e["tls"] as! [String: Any]
            tls["utls"] = ["enabled": true]
            e["tls"] = tls
        }))
        XCTAssertFalse(passes(try item("probe", "inbounds", "mixed") { e in
            var users = e["users"] as! [[String: Any]]
            users[0]["uuid"] = "x"
            e["users"] = users
        }))
        func nested(_ key: String, _ change: (inout [String: Any]) -> Void) throws -> [String: Any] {
            try item("openvpn", "endpoints", "openvpn-client") { e in
                if var list = e[key] as? [[String: Any]] {
                    change(&list[0])
                    e[key] = list
                } else {
                    var o = e[key] as? [String: Any] ?? [:]
                    change(&o)
                    e[key] = o
                }
            }
        }
        let openvpn = try golden("openvpn")
        XCTAssertTrue(passes(openvpn))
        // The OpenVPN golden must hold each of these, or the checks below prove nothing.
        let ovpn = try XCTUnwrap((openvpn["endpoints"] as? [[String: Any]])?.first { $0["type"] as? String == "openvpn-client" && $0["servers"] != nil })
        XCTAssertNotNil(ovpn["pull_filters"]); XCTAssertNotNil((ovpn["tls"] as? [String: Any])?["control_wrap"])
        XCTAssertFalse(passes(try nested("servers") { $0["detour"] = "direct" }))
        XCTAssertFalse(passes(try nested("pull_filters") { $0["script"] = "x" }))
        XCTAssertFalse(passes(try nested("tls") { t in
            var w = t["control_wrap"] as! [String: Any]
            w["key_path"] = "x"
            t["control_wrap"] = w
        }))
        XCTAssertFalse(passes(try nested("tls") { t in
            var w = t["control_wrap"] as! [String: Any]
            w["extra"] = "x"
            t["control_wrap"] = w
        }))
        // Names in any case at any depth, but never two that differ only in case.
        XCTAssertTrue(passes(try nested("servers") { $0["Server_Port"] = $0.removeValue(forKey: "server_port") }))
        XCTAssertFalse(passes(try nested("servers") { $0["Server_Port"] = 1 }))
        XCTAssertTrue(passes(try nested("tls") { $0["Server_Name"] = $0.removeValue(forKey: "server_name") }))
        XCTAssertFalse(passes(try nested("tls") { $0["Server_Name"] = "x" }))
        var dnsOptimistic = try example()
        edit(&dnsOptimistic, "dns") { $0["optimistic"] = ["enabled": true, "timeout": "1h", "stale": true] }
        XCTAssertFalse(passes(dnsOptimistic))
        edit(&dnsOptimistic, "dns") { $0["optimistic"] = ["Enabled": true, "timeout": "1h"] }
        XCTAssertTrue(passes(dnsOptimistic))
        edit(&dnsOptimistic, "dns") { $0["optimistic"] = true }
        XCTAssertFalse(passes(dnsOptimistic))
        // Sections and their own fields.
        for (section, field, value) in [("route", "dhcp_lease_files", ["/var/db/dhcpd_leases"]), ("route", "find_neighbor", true),
                                        ("route", "rule_set", [["type": "inline"]]), ("route", "default_interface", "en0"),
                                        ("route", "override_android_vpn", true), ("dns", "reverse_mapping", true), ("dns", "independent_cache", true),
                                        ("dns", "fakeip", ["enabled": true]), ("log", "output", "x.log"), ("log", "disabled", true),
                                        ("experimental", "clash_api", ["external_controller": "127.0.0.1:9090"]), ("experimental", "v2ray_api", ["listen": "127.0.0.1:1"])] as [(String, String, Any)] {
            var c = try example()
            edit(&c, section) { $0[field] = value }
            XCTAssertFalse(passes(c), "\(section).\(field)")
        }
        for (field, value) in [("services", [["type": "resolved"]]), ("certificate", ["store": "system"]), ("ntp", ["enabled": true]),
                               ("providers", [[String: Any]]())] as [(String, Any)] {
            var c = try example()
            c[field] = value
            XCTAssertFalse(passes(c), field)
        }
        var c = try example()
        edit(&c, "experimental") { e in e["cache_file"] = ["enabled": true, "path": "cache.db", "store_rdrc": true] }
        XCTAssertFalse(passes(c))
        // A null is never what the compiler writes either.
        XCTAssertFalse(passes(try item("example", "outbounds", "direct") { $0["tag"] = NSNull() }))
    }

    /// The engine's cache is the file the extension removes before each start: any other name would keep lookups past
    /// the connection, or have the engine replace a file of its own there (a crash report) with a database.
    func testOnlyTheCompilersCacheFile() throws {
        func cache(_ change: (inout [String: Any]) -> Void) throws -> Bool {
            var c = try example()
            edit(&c, "experimental") { e in
                var f = e["cache_file"] as? [String: Any] ?? [:]
                change(&f)
                e["cache_file"] = f
            }
            return passes(c)
        }
        XCTAssertTrue(try cache { _ in })
        XCTAssertTrue(try cache { $0["path"] = nil })
        XCTAssertTrue(try cache { $0["path"] = ConfigVet.cacheFile })
        for path in ["x.db", "CrashReport-1.log", "PlatformMetadata-1.json", ".", "", "Cache.db", "cache.db-wal", "cache.db/", "../cache.db"] {
            XCTAssertFalse(try cache { $0["path"] = path }, path)
        }
        XCTAssertFalse(try cache { $0["path"] = 1 })
        var c = try example()
        c["experimental"] = nil
        XCTAssertTrue(passes(c))
    }

    /// What the compiler writes the same every time is required as it writes it.
    func testTheCompilersFixedValues() throws {
        XCTAssertTrue(passes(try example()))
        func section(_ name: String, _ key: String, _ value: Any?) throws -> Bool {
            var c = try example()
            edit(&c, name) { $0[key] = value }
            return passes(c)
        }
        for level: Any in ["info", "trace", "error", "WARN", "", 1, NSNull()] as [Any] {
            XCTAssertFalse(try section("log", "level", level), "\(level)")
        }
        XCTAssertFalse(try section("log", "level", nil))
        var c = try example()
        c["log"] = nil
        XCTAssertFalse(passes(c))
        // Debug builds may log at debug level (DebugHooks.engineConfig); release builds never.
        #if DEBUG
        XCTAssertTrue(try section("log", "level", "debug"))
        #else
        XCTAssertFalse(try section("log", "level", "debug"))
        #endif
        for strategy: String? in ["prefer_ipv4", "prefer_ipv6", "ipv6_only", "as_is", nil] {
            XCTAssertFalse(try section("dns", "strategy", strategy), "\(String(describing: strategy))")
        }
        XCTAssertFalse(try section("route", "auto_detect_interface", false))
        XCTAssertFalse(try section("route", "auto_detect_interface", 1))
        XCTAssertFalse(try section("route", "auto_detect_interface", nil))
        XCTAssertFalse(try section("route", "default_domain_resolver", "fake"))
        XCTAssertFalse(try section("route", "default_domain_resolver", nil))
        for range: String? in ["0.0.0.0/1", "172.19.0.0/30", "198.18.0.0/16", "10.0.0.0/8", nil] {
            XCTAssertFalse(passes(try item("example", "dns.servers", "fakeip") { $0["inet4_range"] = range }), "\(String(describing: range))")
        }
        XCTAssertTrue(passes(try item("example", "dns.servers", "fakeip") { _ in }))
    }

    /// Each protocol only in its own section.
    func testEndpointsAndOutboundsStayInTheirSections() throws {
        var c = try example()
        var endpoints = c["endpoints"] as! [[String: Any]], outbounds = c["outbounds"] as! [[String: Any]]
        let wg = endpoints.remove(at: try XCTUnwrap(endpoints.firstIndex { $0["type"] as? String == "wireguard" }))
        let tag = wg["tag"] as! String
        outbounds.append(wg)
        c["endpoints"] = endpoints
        c["outbounds"] = outbounds
        // Kept out of rule 0's list too, so it is refused for its section alone.
        rules(&c, "route") { r in r[0]["inbound"] = (r[0]["inbound"] as! [String]).filter { $0 != tag } }
        rules(&c, "dns") { r in r[0]["inbound"] = (r[0]["inbound"] as! [String]).filter { $0 != tag } }
        XCTAssertFalse(passes(c))
        c = try example()
        c["endpoints"] = (c["endpoints"] as! [[String: Any]]) + [["type": "direct", "tag": "d2"]]
        XCTAssertFalse(passes(c))
        // Protocols the compiler never uses, in either section.
        for type in ["vless", "vmess", "trojan", "hysteria2", "tuic", "ssh", "tor", "socks", "http", "selector", "urltest", "anytls", "naive"] {
            c = try example()
            c["outbounds"] = (c["outbounds"] as! [[String: Any]]) + [["type": type, "tag": "x"]]
            XCTAssertFalse(passes(c), type)
        }
        for type in ["shadowsocks", "socks", "http", "tproxy", "redirect", "direct", "naive", "hysteria2", "vless"] {
            c = try example()
            c["inbounds"] = (c["inbounds"] as! [[String: Any]]) + [["type": type, "tag": "x", "listen": "127.0.0.1"]]
            XCTAssertFalse(passes(c), type)
        }
    }

    func testTheProxyIsLoopbackOnlyWithPasswordsAndAtMostOne() throws {
        XCTAssertTrue(passes(try item("probe", "inbounds", "mixed") { _ in }))
        XCTAssertFalse(passes(try item("probe", "inbounds", "mixed") { $0["users"] = [] }))
        XCTAssertFalse(passes(try item("probe", "inbounds", "mixed") { $0["users"] = nil }))
        XCTAssertFalse(passes(try item("probe", "inbounds", "mixed") { e in
            var users = e["users"] as! [[String: Any]]
            users[0]["password"] = ""
            e["users"] = users
        }))
        XCTAssertFalse(passes(try item("probe", "inbounds", "mixed") { e in
            var users = e["users"] as! [[String: Any]]
            users[0]["username"] = ""
            e["users"] = users
        }))
        XCTAssertFalse(passes(try item("probe", "inbounds", "mixed") { e in
            var users = e["users"] as! [[String: Any]]
            users[0]["password"] = nil
            e["users"] = users
        }))
        for listen in ["0.0.0.0", "::", "::1", "localhost", "192.168.1.2"] {
            XCTAssertFalse(passes(try item("probe", "inbounds", "mixed") { $0["listen"] = listen }), listen)
        }
        // On a port the app picks (Connection.freePort: 0 or from 20000), never a privileged one only root could take.
        for port: Int? in [0, 1024, 20_000, 40_123, 65_535, nil] {
            XCTAssertTrue(passes(try item("probe", "inbounds", "mixed") { $0["listen_port"] = port }), "\(String(describing: port))")
        }
        for port in [53, 631, 1, 1023, 65_536, -1, 1.5, "40000", true, false] as [Any] {
            XCTAssertFalse(passes(try item("probe", "inbounds", "mixed") { $0["listen_port"] = port }), "\(port)")
        }
        var c = try golden("probe")
        let mixed = try XCTUnwrap((c["inbounds"] as! [[String: Any]]).first { $0["type"] as? String == "mixed" })
        var second = mixed
        second["tag"] = "probe2"
        second["listen_port"] = 40124
        c["inbounds"] = (c["inbounds"] as! [[String: Any]]) + [second]
        XCTAssertFalse(passes(c))
    }

    func testTheTunIsTheCompilersOwn() throws {
        func tun(_ change: (inout [String: Any]) -> Void) throws -> Bool { passes(try item("example", "inbounds", "tun", change)) }
        XCTAssertTrue(try tun { _ in })
        XCTAssertTrue(try passes(item("lan-off", "inbounds", "tun") { _ in }))
        XCTAssertFalse(try tun { $0["stack"] = "system" })
        XCTAssertFalse(try tun { $0["stack"] = "mixed" })
        XCTAssertFalse(try tun { $0["stack"] = nil })
        XCTAssertFalse(try tun { $0["udp_mapping"] = nil })
        XCTAssertFalse(try tun { $0["udp_mapping"] = "endpoint_independent" })
        XCTAssertFalse(try tun { $0["auto_route"] = false })
        XCTAssertFalse(try tun { $0["auto_route"] = nil })
        XCTAssertFalse(try tun { $0["auto_route"] = 1 })
        XCTAssertFalse(try tun { $0["auto_route"] = 1.0 })
        XCTAssertFalse(try tun { $0["address"] = ["10.0.0.1/30"] })
        XCTAssertFalse(try tun { $0["address"] = ["172.19.0.1/30"] })
        XCTAssertFalse(try tun { $0["route_address"] = nil })
        XCTAssertFalse(try tun { $0["route_address"] = ["1.2.3.4/32"] })
        for missing in ["0.0.0.0/0", "::/0", "172.19.0.0/30"] {
            XCTAssertFalse(try tun { t in t["route_address"] = (t["route_address"] as! [String]).filter { $0 != missing } }, missing)
        }
        // Only local networks may be left out of it.
        XCTAssertTrue(try tun { $0["route_exclude_address"] = ["10.0.0.0/8", "fe80::/10"] })
        XCTAssertFalse(try tun { $0["route_exclude_address"] = ["0.0.0.0/1", "128.0.0.0/1"] })
        XCTAssertFalse(try tun { $0["route_exclude_address"] = ["10.0.0.0/8", "8.8.8.8/32"] })
        XCTAssertFalse(try tun { $0["route_exclude_address"] = "10.0.0.0/8" })
    }

    /// Rules hold only what their action takes; routes and resolvers they name exist.
    func testRulesHoldOnlyWhatTheirActionTakes() throws {
        func route(_ rule: [String: Any]) throws -> Bool {
            var c = try example()
            rules(&c, "route") { $0.insert(rule, at: 2) }
            return passes(c)
        }
        func dns(_ rule: [String: Any]) throws -> Bool {
            var c = try example()
            rules(&c, "dns") { $0.insert(rule, at: 1) }
            return passes(c)
        }
        XCTAssertTrue(try route(["domain": ["x"], "outbound": "direct"]))
        XCTAssertTrue(try route(["domain": ["x"], "action": "route", "outbound": "direct"]))
        XCTAssertTrue(try route(["port": 22, "action": "reject"]))
        XCTAssertTrue(try route(["network": "icmp", "action": "reject"]))
        XCTAssertTrue(try route(["action": "resolve", "server": "local"]))
        XCTAssertFalse(try route(["action": "resolve"]))
        XCTAssertFalse(try route(["action": "resolve", "server": "local", "strategy": "prefer_ipv6"]))
        XCTAssertFalse(try route(["domain": ["x"], "outbound": "attacker"]))
        XCTAssertFalse(try route(["domain": ["x"]]))
        XCTAssertFalse(try route(["action": "reject", "method": "drop"]))
        XCTAssertFalse(try route(["action": "reject", "outbound": "direct"]))
        XCTAssertFalse(try route(["action": "sniff"]))
        XCTAssertFalse(try route(["action": "route-options", "udp_timeout": "1h"]))
        XCTAssertFalse(try route(["action": "bypass"]))
        XCTAssertFalse(try route(["action": 1]))
        XCTAssertFalse(try route(["rule_set": ["x"], "outbound": "direct"]))
        XCTAssertFalse(try route(["source_ip_cidr": ["0.0.0.0/0"], "outbound": "direct"]))
        XCTAssertFalse(try route(["invert": true, "outbound": "direct"]))
        XCTAssertFalse(try route(["type": "default", "outbound": "direct"]))
        // Logical rules: their own rules only match, one level deep.
        let ownerless: [String: Any] = ["type": "logical", "mode": "and", "action": "reject",
                                        "rules": [["network": ["tcp", "udp"]], ["process_path_regex": ["."], "invert": true]]]
        XCTAssertTrue(try route(ownerless))
        var nested = ownerless
        nested["rules"] = [["type": "logical", "mode": "or", "rules": [["network": "tcp"]]]]
        XCTAssertFalse(try route(nested))
        var acting = ownerless
        acting["rules"] = [["network": "tcp", "outbound": "direct"]]
        XCTAssertFalse(try route(acting))
        var empty = ownerless
        empty["rules"] = [[String: Any]]()
        XCTAssertFalse(try route(empty))
        var xor = ownerless
        xor["mode"] = "xor"
        XCTAssertFalse(try route(xor))
        var matching = ownerless
        matching["network"] = "tcp"
        XCTAssertFalse(try route(matching))

        XCTAssertTrue(try dns(["domain_suffix": ["x"], "server": "local"]))
        XCTAssertTrue(try dns(["query_type": ["TXT"], "server": "local", "rewrite_ttl": 1]))
        for rcode in ["REFUSED", "NXDOMAIN", "NOERROR"] { XCTAssertTrue(try dns(["action": "predefined", "rcode": rcode]), rcode) }
        XCTAssertFalse(try dns(["action": "predefined", "rcode": "SERVFAIL"]))
        XCTAssertFalse(try dns(["action": "predefined", "rcode": "NOERROR", "answer": ["x. IN A 1.2.3.4"]]))
        XCTAssertFalse(try dns(["action": "predefined", "rcode": "REFUSED", "server": "local"]))
        XCTAssertFalse(try dns(["domain_suffix": ["x"]]))
        XCTAssertFalse(try dns(["domain_suffix": ["x"], "server": "local", "client_subnet": "1.2.3.0/24"]))
        XCTAssertFalse(try dns(["domain_suffix": ["x"], "action": "reject"]))
        XCTAssertFalse(try dns(["domain": ["x"], "server": "local"]))
        XCTAssertFalse(try dns(["type": "logical", "mode": "or", "rules": [["domain_suffix": ["x"]]], "server": "local"]))
        // A tunnel's resolver asks through an endpoint of its own kind.
        XCTAssertFalse(passes(try item("example", "dns.servers", "tailscale") { $0["endpoint"] = "direct" }))
        XCTAssertFalse(passes(try item("openvpn", "dns.servers", "openvpn") { $0["endpoint"] = "home-ts" }))
    }

    func testTailscaleTalksToItsControlServerOverHttpsOnly() throws {
        let name = "headscale"
        XCTAssertTrue(passes(try item(name, "endpoints", "tailscale") { _ in }))
        XCTAssertTrue(passes(try item(name, "endpoints", "tailscale") { $0["control_url"] = "https://hs.example.com:8443/path" }))
        for url in ["http://hs.example.com", "hs.example.com", "https://", "https://user:pw@hs.example.com", "file:///etc/x", ""] {
            XCTAssertFalse(passes(try item(name, "endpoints", "tailscale") { $0["control_url"] = url }), url)
        }
    }

    // MARK: Nothing comes in through a tunnel

    /// With any endpoint, rule 0 of routing and of DNS refuses what arrives through every one of them, exactly as the
    /// compiler writes it: a copy sealed by an older version without those rules is refused, until the app seals a new one.
    func testWithAnEndpointRuleZeroRefusesWhatComesInThroughIt() throws {
        var checked = 0
        for (file, _) in try goldens() {
            let name = String(file.dropLast(".json".count)), c = try golden(name)
            let endpoints = (c["endpoints"] as? [[String: Any]]) ?? []
            guard !endpoints.isEmpty else { continue }
            checked += 1
            let tags = endpoints.map { $0["tag"] as! String }
            XCTAssertTrue(passes(c), name)
            func refused(_ f: (inout [String: Any]) -> Void) -> Bool {
                var c = c
                f(&c)
                return !passes(c)
            }
            // An older version's: neither rule.
            XCTAssertTrue(refused { rules(&$0, "route") { $0.removeFirst() }; rules(&$0, "dns") { $0.removeFirst() } }, name)
            for section in ["route", "dns"] {
                XCTAssertTrue(refused { rules(&$0, section) { $0.removeFirst() } }, "\(name) \(section) without")
                XCTAssertTrue(refused { rules(&$0, section) { r in r.swapAt(0, 1) } }, "\(name) \(section) moved")
                XCTAssertTrue(refused { rules(&$0, section) { r in r[0]["inbound"] = Array(tags.dropLast()) } }, "\(name) \(section) a tag short")
                XCTAssertTrue(refused { rules(&$0, section) { r in r[0]["inbound"] = tags + ["tun"] } }, "\(name) \(section) a tag more")
                XCTAssertTrue(refused { rules(&$0, section) { r in r[0]["inbound"] = tags.first } }, "\(name) \(section) one as text")
                XCTAssertTrue(refused { rules(&$0, section) { r in r[0]["network"] = "tcp" } }, "\(name) \(section) narrowed")
                XCTAssertTrue(refused { rules(&$0, section) { r in r.insert(["action": "reject"], at: 0) } }, "\(name) \(section) after another")
                // Any order of the same tags.
                XCTAssertFalse(refused { rules(&$0, section) { r in r[0]["inbound"] = Array(tags.reversed()) } }, "\(name) \(section) reordered")
            }
            XCTAssertTrue(refused { rules(&$0, "route") { r in r[0]["action"] = "hijack-dns" } }, name)
            XCTAssertTrue(refused { rules(&$0, "dns") { r in r[0]["rcode"] = "NOERROR" } }, name)
            XCTAssertTrue(refused { rules(&$0, "dns") { r in r[0]["action"] = "route"; r[0]["rcode"] = nil; r[0]["server"] = "local" } }, name)
        }
        XCTAssertGreaterThan(checked, 10)
        // Without an endpoint there is nothing to refuse: a deny-all, a pause and Direct alone need neither rule.
        XCTAssertTrue(passes(try golden("paused")))
        XCTAssertTrue(passes(try golden("empty")))
    }
}

extension ConfigVetTests {
    /// A whole config around [exit] (an endpoint or outbound as the app writes it): the tun, the local resolver, and for an
    /// endpoint the rules that refuse what comes in through it. For checking that the extension takes what Manual imports.
    static func around(_ exit: J) throws -> String {
        var c = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Fixture.text("golden/paused.json").utf8)) as? [String: Any])
        let item = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(exit.string.utf8)) as? [String: Any])
        if ["wireguard", "openvpn-client", "tailscale"].contains(item["type"] as? String) {
            let tag = try XCTUnwrap(item["tag"] as? String)
            c["endpoints"] = [item]
            for (section, rule) in [("route", ["inbound": [tag], "action": "reject"]), ("dns", ["inbound": [tag], "action": "predefined", "rcode": "REFUSED"])] {
                var s = c[section] as? [String: Any] ?? [:]
                s["rules"] = [rule] + (s["rules"] as? [Any] ?? [])
                c[section] = s
            }
        } else {
            c["outbounds"] = (c["outbounds"] as? [Any] ?? []) + [item]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: c), as: UTF8.self)
    }
}

/// The configuration the extension seals in place of a removed copy while Connect on Demand couldn't be turned off.
final class FallbackConfigTests: XCTestCase {
    private let me = Compiler.pattern(forPath: "/Applications/unbraid.app/Contents/MacOS/unbraid", ignoringCase: true)

    /// Every kill-switch and local-network setting the user can have, and a custom resolver.
    private var prefs: [Prefs] {
        var out: [Prefs] = []
        for kill in [KillLevel.off, .internet, .home] {
            for lan in [true, false] {
                var p = Prefs()
                p.killLevel = kill
                p.lan = lan
                p.alwaysOn = true
                out.append(p)
            }
        }
        var dns = Prefs()
        dns.customDns = ["9.9.9.9"]
        out.append(dns)
        return out
    }

    func testTheFallbackPassesTheExtensionsChecksHoldsNoAccountAndSendsEverythingDirect() throws {
        let engine = try ProviderFixtures.engine()
        for p in prefs {
            let json = try Compiler.fallback(prefs: p, selfPattern: me)
            let checked = try ConfigVet.check(json)
            XCTAssertTrue(ConfigVet.isFallback(checked), "\(p)")
            let c = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(checked.utf8)) as? [String: Any])
            XCTAssertEqual((c["endpoints"] as? [Any])?.count ?? 0, 0)
            XCTAssertEqual((c["outbounds"] as? [[String: Any]])?.map { $0["type"] as? String }, ["direct"])
            XCTAssertEqual((c["inbounds"] as? [[String: Any]])?.map { $0["type"] as? String }, ["tun"])
            let route = try XCTUnwrap(c["route"] as? [String: Any])
            XCTAssertEqual(route["final"] as? String, "direct")
            // IPv6, stale fake addresses and unspecified addresses are refused; no app is blocked.
            let rejects = (route["rules"] as? [[String: Any]] ?? []).filter { $0["action"] as? String == "reject" }
            XCTAssertEqual(rejects.count, 4, "\(p)")
            XCTAssertEqual(rejects.filter { $0["ip_version"] as? Int == 6 }.count, 1)
            XCTAssertEqual(rejects.filter { $0["no_drop"] as? Bool == true }.count, 3)
            XCTAssertFalse(checked.contains("auth_key") || checked.contains("private_key") || checked.contains("password"))
            if let engine { XCTAssertNil(ProviderFixtures.engineRefusal(checked, engine), "\(p)") }
        }
    }

    func testOnlyADirectConfigurationWithoutAccountsOrServersIsAFallback() throws {
        var free = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: XCTUnwrap(Bundle(for: Fixture.self).resourceURL).appending(path: "Fixtures/golden").path)
            where name.hasSuffix(".json") {
            let checked = try ConfigVet.check(Fixture.text("golden/\(name)"))
            let c = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(checked.utf8)) as? [String: Any])
            let exits = (c["endpoints"] as? [Any] ?? []) + (c["outbounds"] as? [[String: Any]] ?? []).filter { $0["type"] as? String != "direct" }
            let probe = (c["inbounds"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "mixed" }
            let resolvers = ((c["dns"] as? [String: Any])?["servers"] as? [[String: Any]] ?? []).contains { !["local", "fakeip"].contains($0["type"] as? String ?? "") }
            let rules = ((c["route"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []) + ((c["dns"] as? [String: Any])?["rules"] as? [[String: Any]] ?? [])
            let refuses = rules.contains { ["reject", "predefined"].contains($0["action"] as? String ?? "") && $0["ip_version"] as? Int != 6 && $0["no_drop"] as? Bool != true }
            XCTAssertEqual(ConfigVet.isFallback(checked), exits.isEmpty && !probe && !resolvers && !refuses, name)
            if ConfigVet.isFallback(checked) { free += 1 }
        }
        // Direct alone (as the fallback is built), and nothing else among the shapes the compiler writes.
        XCTAssertGreaterThan(free, 0)
        // Anything that could hold a secret or reach a server, at any depth, is refused, whatever the case of its name.
        let base = try Compiler.fallback(prefs: Prefs(), selfPattern: me)
        func with(_ change: (inout [String: Any]) -> Void) throws -> String {
            var c = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(base.utf8)) as? [String: Any])
            change(&c)
            return String(decoding: try JSONSerialization.data(withJSONObject: c), as: UTF8.self)
        }
        XCTAssertTrue(ConfigVet.isFallback(base))
        let changes: [(inout [String: Any]) -> Void] = [
            { $0["endpoints"] = [["type": "wireguard", "tag": "w"]] },
            { $0["outbounds"] = ($0["outbounds"] as? [Any] ?? []) + [["type": "shadowsocks", "tag": "s"]] },
            { $0["inbounds"] = ($0["inbounds"] as? [Any] ?? []) + [["type": "mixed", "tag": "probe"]] },
            { var d = $0["dns"] as? [String: Any] ?? [:]; d["servers"] = (d["servers"] as? [Any] ?? []) + [["type": "udp", "tag": "u", "server": "1.1.1.1"]]; $0["dns"] = d },
            { var d = $0["dns"] as? [String: Any] ?? [:]; d["servers"] = (d["servers"] as? [Any] ?? []) + [["type": "tailscale", "tag": "t"]]; $0["dns"] = d },
            { var r = $0["route"] as? [String: Any] ?? [:]; r["Auth_Key"] = "tskey"; $0["route"] = r },
            { $0["outbounds"] = [["type": "direct", "tag": "direct", "password": "x"]] },
            { $0["endpoints"] = "none" },
            // DNS alone goes to the engine's resolver.
            { var r = $0["route"] as? [String: Any] ?? [:]; r["rules"] = [["action": "hijack-dns"]] + (r["rules"] as? [Any] ?? []); $0["route"] = r },
            { var r = $0["route"] as? [String: Any] ?? [:]; r["rules"] = [["port": 443, "network": "tcp", "action": "hijack-dns"]]; $0["route"] = r },
            // Nothing refused but IPv6, every lookup answered, everything else out through direct.
            { var r = $0["route"] as? [String: Any] ?? [:]; r["rules"] = [["action": "reject"]] + (r["rules"] as? [Any] ?? []); $0["route"] = r },
            { var r = $0["route"] as? [String: Any] ?? [:]; r["rules"] = [["ip_version": 4, "action": "reject"]]; $0["route"] = r },
            { var r = $0["route"] as? [String: Any] ?? [:]; r["rules"] = [["network": "icmp", "action": "reject"]]; $0["route"] = r },
            { var d = $0["dns"] as? [String: Any] ?? [:]; d["rules"] = [["action": "predefined", "rcode": "REFUSED"]]; $0["dns"] = d },
            { var r = $0["route"] as? [String: Any] ?? [:]; r["final"] = "nowhere"; $0["route"] = r },
            { var r = $0["route"] as? [String: Any] ?? [:]
              r["rules"] = [["type": "logical", "mode": "and", "action": "reject", "rules": [["network": ["tcp"]]]]]; $0["route"] = r },
            // Every lookup answered: resolved with the local resolver, and only address lookups sent to the fake one.
            { var r = $0["route"] as? [String: Any] ?? [:]; r["rules"] = [["action": "resolve", "server": "fake"]] + (r["rules"] as? [Any] ?? []); $0["route"] = r },
            { var r = $0["route"] as? [String: Any] ?? [:]; r["rules"] = [["action": "resolve", "server": "nowhere"]]; $0["route"] = r },
            { var d = $0["dns"] as? [String: Any] ?? [:]; d["rules"] = [["query_type": ["TXT"], "server": "fake"]]; $0["dns"] = d },
            { var d = $0["dns"] as? [String: Any] ?? [:]; d["rules"] = [["query_type": ["A", "TXT"], "server": "fake"]]; $0["dns"] = d },
            { var d = $0["dns"] as? [String: Any] ?? [:]; d["rules"] = [["domain_suffix": ["example.com"], "server": "fake"]]; $0["dns"] = d },
            { var d = $0["dns"] as? [String: Any] ?? [:]; d["rules"] = [["query_type": [] as [String], "server": "fake"]]; $0["dns"] = d },
            { var d = $0["dns"] as? [String: Any] ?? [:]; d["rules"] = [["query_type": [1], "server": "fake"]]; $0["dns"] = d },
            { var d = $0["dns"] as? [String: Any] ?? [:]; d["rules"] = [["server": "nowhere"]]; $0["dns"] = d },
            { var d = $0["dns"] as? [String: Any] ?? [:]; d["final"] = "fake"; $0["dns"] = d },
            { var d = $0["dns"] as? [String: Any] ?? [:]; d["final"] = nil; $0["dns"] = d },
            { var d = $0["dns"] as? [String: Any] ?? [:]
              d["servers"] = (d["servers"] as? [Any] ?? []) + [["type": "fakeip", "tag": "local", "inet4_range": "198.18.0.0/15"]]; $0["dns"] = d },
            { var d = $0["dns"] as? [String: Any] ?? [:]; d["rules"] = [["query_type": ["aaaa"], "server": "fake"]]; $0["dns"] = d },
            { var r = $0["route"] as? [String: Any] ?? [:]; r["default_domain_resolver"] = "fake"; $0["route"] = r },
            { var r = $0["route"] as? [String: Any] ?? [:]; r["default_domain_resolver"] = nil; $0["route"] = r },
            // Tags and types swapped: a fake resolver tagged "local", the local one under another tag as the final.
            { var d = $0["dns"] as? [String: Any] ?? [:]
              d["servers"] = [["type": "fakeip", "tag": "local", "inet4_range": "198.18.0.0/15"], ["type": "local", "tag": "real"]]
              d["final"] = "real"; d["rules"] = [] as [Any]; $0["dns"] = d
              var r = $0["route"] as? [String: Any] ?? [:]
              r["rules"] = (r["rules"] as? [[String: Any]] ?? []).filter { $0["action"] as? String != "resolve" }; $0["route"] = r },
        ]
        for (i, change) in changes.enumerated() { XCTAssertFalse(ConfigVet.isFallback(try with(change)), "change \(i)") }
        XCTAssertFalse(ConfigVet.isFallback("not json"))
        // Address lookups for the fake resolver, listed or alone, and anything for the local one, are fine.
        let fine: [(inout [String: Any]) -> Void] = [
            { var d = $0["dns"] as? [String: Any] ?? [:]; d["rules"] = [["query_type": ["AAAA", "A"], "server": "fake"]]; $0["dns"] = d },
            { var d = $0["dns"] as? [String: Any] ?? [:]; d["rules"] = [["query_type": "A", "server": "fake"]]; $0["dns"] = d },
            { var d = $0["dns"] as? [String: Any] ?? [:]; d["rules"] = [["query_type": ["TXT"], "server": "local"]]; $0["dns"] = d },
        ]
        for (i, change) in fine.enumerated() { XCTAssertTrue(ConfigVet.isFallback(try with(change)), "fine \(i)") }
    }

    func testTheSealedFallbackIsMarkedAndAnOlderCopyIsNot() throws {
        let fallback = try XCTUnwrap(SealedPolicy.decode(XCTUnwrap(SealedPolicy.encode("{}", owner: 501, search: "", fallback: true))))
        XCTAssertTrue(fallback.fallback)
        XCTAssertEqual(fallback.search, "")
        XCTAssertFalse(try XCTUnwrap(SealedPolicy.decode(XCTUnwrap(SealedPolicy.encode("{}", owner: 501)))).fallback)
        // Only JSON's true marks it.
        for text in [#"{"config":"{}","owner":501,"fallback":1}"#, #"{"config":"{}","owner":501,"fallback":"true"}"#, #"{"config":"{}","owner":501}"#] {
            XCTAssertFalse(try XCTUnwrap(SealedPolicy.decode(Data(text.utf8))).fallback, text)
        }
    }

    func testTheFallbackNeverTakesTheirPlaceFromACopyThatStartsOrIsAnotherUsers() {
        // Nothing there, or nothing of theirs that starts: the fallback goes in.
        XCTAssertTrue(Ownership.mayFallback(501, seal: .none, startable: false, dropPending: false))
        XCTAssertTrue(Ownership.mayFallback(501, seal: .owner(501), startable: false, dropPending: false), "a failed sealing, or an interrupted fallback")
        XCTAssertTrue(Ownership.mayFallback(501, seal: .legacy, startable: false, dropPending: false), "nobody's, never started")
        XCTAssertTrue(Ownership.mayFallback(501, seal: .unreadable, startable: false, dropPending: true), "its drop failed: it goes anyway")
        // A copy that starts, anyone's, and another user's or one that can't be told, stays.
        XCTAssertFalse(Ownership.mayFallback(501, seal: .owner(501), startable: true, dropPending: false))
        XCTAssertFalse(Ownership.mayFallback(501, seal: .owner(502), startable: true, dropPending: false))
        XCTAssertFalse(Ownership.mayFallback(501, seal: .owner(502), startable: false, dropPending: false), "another user's, refused or not")
        XCTAssertFalse(Ownership.mayFallback(501, seal: .unreadable, startable: false, dropPending: false))
        XCTAssertFalse(Ownership.mayFallback(501, seal: .owner(501), startable: true, dropPending: true), "a copy that starts never goes")
    }

    func testOnlyThatVeryFallbackIsDroppedOnceConnectOnDemandIsOff() {
        let id = UUID().uuidString, other = UUID().uuidString
        XCTAssertTrue(Ownership.dropsFallback(501, expected: id, current: id, seal: .owner(501), fallback: true))
        XCTAssertFalse(Ownership.dropsFallback(501, expected: id, current: other, seal: .owner(501), fallback: true), "sealed again since")
        XCTAssertFalse(Ownership.dropsFallback(501, expected: id, current: id, seal: .owner(501), fallback: false), "a real copy")
        XCTAssertFalse(Ownership.dropsFallback(501, expected: id, current: id, seal: .owner(502), fallback: true), "another user's")
        XCTAssertFalse(Ownership.dropsFallback(501, expected: id, current: nil, seal: .owner(501), fallback: true), "no id: can't be told")
        XCTAssertFalse(Ownership.dropsFallback(501, expected: "unknown", current: "unknown", seal: .owner(501), fallback: true))
        XCTAssertFalse(Ownership.dropsFallback(501, expected: id, current: id, seal: .unreadable, fallback: true))
    }

    func testEveryUserIsToldThatTheFallbackIsSealedOrRunsButOnlyItsOwnerItsRevisions() {
        let a = Staging.revision("A")
        XCTAssertEqual(Ownership.revisions(501, running: (a, 501), sealed: (a, 501), fallback: (true, true)),
                       ["running": a, "durable": a, "startable": "1", "fallback-running": "1", "fallback-durable": "1"])
        XCTAssertEqual(Ownership.revisions(502, running: (a, 501), sealed: (a, 501), fallback: (true, true)),
                       ["foreign": "1", "startable": "1", "fallback-running": "1", "fallback-durable": "1"])
        XCTAssertEqual(Ownership.revisions(502, running: nil, sealed: (a, 501), fallback: (false, true)), ["startable": "1", "fallback-durable": "1"])
        XCTAssertEqual(Ownership.revisions(502, running: (a, 501), sealed: nil, fallback: (true, false)), ["foreign": "1", "fallback-running": "1"])
        XCTAssertEqual(Ownership.revisions(501, running: (nil, 501), sealed: nil, fallback: (true, false)), [:], "mid-reload: not told")
        XCTAssertEqual(Ownership.revisions(502, running: (a, 501), sealed: (a, 501)), ["foreign": "1", "startable": "1"], "a real copy")
    }
}

extension ConfigVetTests {
    func testProviderWireGuardMtu1420IsAccepted() throws {
        var config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Fixture.text("golden/example.json").utf8)) as? [String: Any])
        var endpoints = try XCTUnwrap(config["endpoints"] as? [[String: Any]])
        let index = try XCTUnwrap(endpoints.firstIndex { $0["type"] as? String == "wireguard" })
        endpoints[index]["mtu"] = 1420
        config["endpoints"] = endpoints
        let data = try JSONSerialization.data(withJSONObject: config)
        XCTAssertNoThrow(try ConfigVet.check(String(decoding: data, as: UTF8.self)))
    }
}

extension ConfigVetTests {
    func testMullvadBlockingResolverIsAccepted() throws {
        var config = try example()
        var dns = try XCTUnwrap(config["dns"] as? [String: Any])
        var servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        let index = try XCTUnwrap(servers.firstIndex { $0["tag"] as? String == "dns-r-nl" })
        servers[index]["server"] = "100.64.0.63"
        dns["servers"] = servers
        config["dns"] = dns
        let data = try JSONSerialization.data(withJSONObject: config)
        XCTAssertNoThrow(try ConfigVet.check(String(decoding: data, as: UTF8.self)))
    }
}
