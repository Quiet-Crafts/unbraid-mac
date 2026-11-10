import XCTest

final class KeyProviders2Tests: XCTestCase {
    private typealias F = ProviderFixtures
    private func rows() throws -> [Windscribe.Row] { try Windscribe.rows(Windscribe.parse(Fixture.data("windscribe_serverlist.json"))) }

    func testWindscribeCountriesCarryIsoCodesAndCities() throws {
        let rows = try rows()
        let cs = Windscribe.countries(rows)
        XCTAssertEqual(cs.map(\.name), ["Canada East", "Fake Antarctica", "Italy", "Japan", "Netherlands", "US Central", "US East"])
        XCTAssertTrue(cs.allSatisfy { F.iso.contains($0.code) })
        XCTAssertEqual(Set(cs.map(\.id)).count, cs.count)
        let italy = try XCTUnwrap(cs.first { $0.name == "Italy" })
        XCTAssertEqual(italy.cities.map(\.name), ["Milan", "Palermo"])
        XCTAssertEqual(italy.cities.compactMap(\.key), ["Milan", "Palermo"])
        XCTAssertEqual(cs.first { $0.name == "US East" }?.code, "US")
        XCTAssertEqual(cs.reduce(0) { $0 + $1.serverCount }, rows.count)
    }

    func testWindscribeUsesIp3AndGroupKey() throws {
        let list = try Windscribe.parse(Fixture.data("windscribe_serverlist.json"))
        let group = try XCTUnwrap(list.data.first { $0.name == "Italy" }?.groups.first)
        let node = try XCTUnwrap(group.nodes.first)
        let rows = Windscribe.rows(list)
        let row = try XCTUnwrap(rows.first { $0.node.hostname == node.hostname })
        XCTAssertEqual(row.node.ip3, node.ip3); XCTAssertEqual(row.publicKey, group.publicKey)
        XCTAssertTrue(rows.allSatisfy { $0.node.ip3 != $0.node.hostname && $0.node.ip3.contains(".") })
    }

    func testWindscribeSignInKeepsConfigFields() async throws {
        let a = try await F.ws()
        XCTAssertEqual(a.privateKey, F.priv); XCTAssertEqual(a.address, ["100.96.12.34/32"])
        XCTAssertEqual(a.presharedKey, F.psk); XCTAssertEqual(a.dns, ["10.255.255.1"])
        XCTAssertEqual(a.port, 443)
        let high = try await F.ws(65142)
        let fallback = try await F.ws(51820)
        XCTAssertEqual(high.port, 65142); XCTAssertEqual(fallback.port, 1194)
    }

    func testWindscribeRejectsMissingPresharedKeyOrPeer() async {
        for bad in [F.wsConf(preshared: false), "", "[Interface]\nPrivateKey = \(F.priv)\nAddress = 10.0.0.2/32", "PrivateKey = SECRET-KEY-TEXT"] {
            await F.rejects { _ = try await F.windscribe().signIn(["config": bad]) }
        }
    }

    func testWindscribeCountryLinkPicksLeastLoadedNode() async throws {
        let rows = try rows()
        let l = try F.wg(Windscribe.link(rows, Location(provider: "windscribe", countryCode: "NL", country: "Netherlands"), await F.ws()))
        XCTAssertEqual(l.server.load, rows.filter { $0.region == "Netherlands" }.map { $0.node.health }.min())
        XCTAssertEqual(l.peer.endpoint, "\(l.server.ip):443")
        XCTAssertEqual(l.peer.allowedIps, ["0.0.0.0/0"]); XCTAssertEqual(l.peer.address, ["100.96.12.34/32"])
        XCTAssertEqual(l.peer.dns, ["10.255.255.1"]); XCTAssertEqual(l.peer.privateKey, F.priv)
        XCTAssertEqual(l.peer.presharedKey, F.psk); XCTAssertEqual(l.peer.publicKey, l.server.publicKey)
        XCTAssertEqual(l.server.country, "NL"); XCTAssertEqual(l.peer.mtu, 1420)
    }

    func testWindscribeCityAndRegionFilters() async throws {
        let rows = try rows()
        let a = try await F.ws()
        XCTAssertEqual(try Windscribe.link(rows, Location(provider: "windscribe", country: "Italy", region: "Milan"), a).server.city, "Milan")
        XCTAssertTrue(try Windscribe.link(rows, Location(provider: "windscribe", countryCode: "US", country: "US East"), a).server.host.hasPrefix("us-east"))
        XCTAssertEqual(Windscribe.countries(rows).filter { $0.code == "US" }.count, 2)
        XCTAssertEqual(try Windscribe.link(rows, Location(provider: "windscribe", countryCode: "ca"), a).server.country, "CA")
        XCTAssertThrowsError(try Windscribe.link(rows, Location(provider: "windscribe", country: "Italy", region: "Rome"), a))
    }

    func testWindscribePinnedServerNeedsNoList() async throws {
        let sv = try Windscribe.link(rows(), Location(provider: "windscribe", countryCode: "JP"), await F.ws()).server
        let again = try F.wg(Windscribe.link(nil, Location(provider: "windscribe", pinned: sv), await F.ws(80)))
        XCTAssertEqual(again.server, sv); XCTAssertEqual(again.peer.endpoint, "\(sv.ip):80")
        let blob = JSON.encode(try await F.ws(80))
        let connected = try await F.windscribe().connect(Location(provider: "windscribe", pinned: sv), blob)
        XCTAssertEqual(connected.server, sv)
    }

    func testWindscribeSkipsNodesWithoutWireguard() throws {
        let body = """
        {"data":[{"name":"X","country_code":"nl","status":1,"groups":[
        {"city":"A","wg_pubkey":"","nodes":[{"hostname":"x-1.w.com","ip3":"1.2.3.4","health":1}]},
        {"city":"B","wg_pubkey":"\(F.key)","nodes":[{"hostname":"x-2.w.com","ip3":"","health":1},{"hostname":"x-3.w.com","ip3":"1.2.3.5","health":2}]}]},
        {"name":"Down","country_code":"de","status":0,"groups":[{"city":"C","wg_pubkey":"\(F.key)","nodes":[{"hostname":"d.w.com","ip3":"1.2.3.6"}]}]}]}
        """
        let r = try Windscribe.rows(Windscribe.parse(F.data(body)))
        XCTAssertEqual(r.map { $0.node.hostname }, ["x-3.w.com"]); XCTAssertEqual(r.first?.code, "NL")
        XCTAssertThrowsError(try Windscribe.parse(F.data("SECRET-LIST"))) {
            XCTAssertEqual($0.localizedDescription, "Unexpected reply from Windscribe")
            XCTAssertTrue($0 is Fail)
        }
    }

    func testExpressCountriesCarryIsoCodes() throws {
        let entries = try F.catalog("expressvpn")
        let cs = ExpressVpn.countries(entries)
        XCTAssertEqual(cs.map(\.name), cs.map(\.name).sorted())
        XCTAssertTrue(cs.allSatisfy { F.iso.contains($0.code) })
        for (name, code) in ["USA": "US", "UK": "GB", "India (via UK)": "IN", "Hong Kong": "HK", "Turkey": "TR"] {
            XCTAssertEqual(cs.first { $0.name == name }?.code, code)
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(cs.first { $0.name == "USA" }).cities.count, 3)
        XCTAssertEqual(cs.reduce(0) { $0 + $1.serverCount }, entries.count)
    }

    func testExpressLinkParsesIntoOpenvpnEndpoint() throws {
        let entries = try F.catalog("expressvpn")
        let a = ExpressVpn.Account(username: "user1", password: "pass1")
        let l = try F.ovpn(ExpressVpn.link(entries, Location(provider: "expressvpn", country: "Netherlands", region: "Amsterdam"), a))
        XCTAssertEqual(l.server.city, "Amsterdam"); XCTAssertEqual(l.server.country, "NL")
        XCTAssertEqual(try ExpressVpn.link(entries, Location(provider: "expressvpn", countryCode: "NL"), a).server.country, "NL")
        XCTAssertTrue(l.server.host.hasSuffix(".expressnetw.com"))
        XCTAssertTrue(entries.first { $0.hostname == l.server.host }!.ips.contains(l.server.ip))
        XCTAssertEqual(l.profile.username, "user1"); XCTAssertEqual(l.profile.password, "pass1")
        let e = try Manual.ovpnEndpoint("express", l.profile)
        XCTAssertEqual(e["type"]?.str, "openvpn-client"); XCTAssertEqual(e["server"]?.str, l.server.ip)
        XCTAssertEqual(e["server_port"]?.int, 1195); XCTAssertEqual(e["network"]?.str, "udp")
        XCTAssertEqual(e["username"]?.str, "user1"); XCTAssertEqual(e["auth"]?.str, "SHA512")
        XCTAssertEqual(e["data_ciphers"]?.strs, ["AES-256-GCM", "AES-256-CBC", "AES-128-GCM"])
        XCTAssertEqual(e["data_ciphers_fallback"]?.str, "AES-256-GCM")
        XCTAssertEqual(e["mss_fix"]?.int, 1200); XCTAssertEqual(e["fragment"]?.int, 1300)
        let tls = try XCTUnwrap(e["tls"])
        XCTAssertEqual(tls["server_name"]?.str, "Server"); XCTAssertEqual(tls["server_name_type"]?.str, "name-prefix")
        XCTAssertEqual(tls["remote_certificate_tls"]?.str, "server")
        XCTAssertNotNil(tls["client_certificate"]); XCTAssertTrue(tls["client_key"]?.str?.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") == true)
        XCTAssertEqual(tls["certificate"]?.str?.components(separatedBy: "BEGIN CERTIFICATE").count, 3)
        let wrap = try XCTUnwrap(tls["control_wrap"])
        XCTAssertEqual(wrap["type"]?.str, "tls_auth"); XCTAssertEqual(wrap["direction"]?.str, "client")
        XCTAssertEqual(wrap["key"]?.str?.split(separator: "\n").filter { $0.wholeMatch(of: /[0-9a-f]{32}/) != nil }.count, 16)
    }

    func testExpressSignInChecksFormatOnly() async throws {
        let p = ExpressVpn()
        let a = try await ExpressVpn.account(p.signIn(["username": " abc123 ", "password": "pw"]))
        XCTAssertEqual(a.username, "abc123")
        for bad in [["username": "", "password": "x"], ["username": "a", "password": "b c"],
                    ["username": "a\nb", "password": "SECRET"], ["username": String(repeating: "a", count: 257), "password": "x"],
                    ["username": "a\u{7f}", "password": "x"]] {
            await F.rejects { _ = try await p.signIn(bad) }
        }
    }

    func testExpressPinnedServerKeepsAddress() async throws {
        let a = ExpressVpn.Account(username: "u", password: "p")
        let sv = try ExpressVpn.link(F.catalog("expressvpn"), Location(provider: "expressvpn", countryCode: "SE"), a).server
        let l = try F.ovpn(ExpressVpn.link(nil, Location(provider: "expressvpn", pinned: sv), a))
        XCTAssertEqual(l.server, sv); XCTAssertTrue(l.profile.config.contains("remote \(sv.ip) 1195"))
        let connected = try await F.express().connect(Location(provider: "expressvpn", pinned: sv), JSON.encode(a))
        XCTAssertEqual(connected.server, sv)
    }

    func testExpressRejectsCatalogueTextInPlaceOfIpv4() throws {
        let a = ExpressVpn.Account(username: "u", password: "p")
        for ip in ["1.2.3.4\nremote evil.example 443", "256.2.3.4", "1.2.3.", "::1"] {
            let entry = Catalog.Entry(vpn: "openvpn", country: "Netherlands", hostname: "nl.example", ips: [ip], udp: true)
            XCTAssertThrowsError(try ExpressVpn.link([entry], Location(provider: "expressvpn"), a))
        }
    }

    func testSingBoxAcceptsWindscribeEndpoints() async throws {
        let rows = try rows()
        let a = try await F.ws()
        for loc in [Location(provider: "windscribe", country: "US East"), Location(provider: "windscribe", countryCode: "NL")] {
            try F.check(F.wgEndpoint(F.wg(Windscribe.link(rows, loc, a)).peer))
        }
    }

    func testSingBoxAcceptsExpressVpnEndpoints() throws {
        let entries = try F.catalog("expressvpn")
        for loc in [Location(provider: "expressvpn", country: "Netherlands"), Location(provider: "expressvpn", country: "USA", region: "Atlanta")] {
            let l = try F.ovpn(ExpressVpn.link(entries, loc, ExpressVpn.Account(username: "user1", password: "pass1")))
            try F.check(Manual.ovpnEndpoint("exit", l.profile))
        }
    }
}
