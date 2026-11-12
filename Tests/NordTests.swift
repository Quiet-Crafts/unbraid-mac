import XCTest

final class NordTests: XCTestCase {
    private let key1 = "vOgsnvam/Xc6w8zfQeGcynOr8RMxYzpki3b0EaOkEoI="

    private func ovpn(_ n: String) -> String { Fixture.text("ovpn/\(n)") }

    func testRateLimitRemainsAnHttpStatus() async {
        do {
            _ = try await NordApi.get("/test", request: { _, _, _ in throw Http.Status(code: 429) })
            XCTFail("expected rate limit")
        } catch {
            XCTAssertEqual((error as? Http.Status)?.code, 429)
            XCTAssertEqual(signInFailure(error, "NordVPN"), "NordVPN is limiting sign-in attempts. Wait a few minutes, then try again.")
        }
    }

    func testNordDoubleVpnProfilesParseAndValidate() throws {
        for n in ["nord-double.udp.ovpn", "nord-double.tcp.ovpn"] {
            let p = try Manual.parseOvpn(ovpn(n), name: "UK-NL #19", username: "user", password: "pass")
            let ep = try Manual.ovpnEndpoint("r-nord", p)
            XCTAssertEqual(ep["type"]?.str, "openvpn-client")
            XCTAssertEqual(ep["ping_restart_disabled"]?.bool, true)
            XCTAssertNil(ep["ping_restart"])
            XCTAssertEqual(ep["ping_interval"]?.str, "15s")
        }
    }

    func testNordProfilesStillOfferTheCbcCipherNordServersNeed() throws {
        let p = try Manual.parseOvpn(Nord.withLegacyCiphers(ovpn("nord-double.udp.ovpn")), name: "dv", username: "user", password: "pass")
        let ep = try Manual.ovpnEndpoint("r", p)
        let ciphers = ep["data_ciphers"]?.strs?.map { $0.uppercased() } ?? []
        XCTAssertTrue(ciphers.contains("AES-256-CBC") && ciphers.contains("AES-256-GCM"), "\(ciphers)")
        XCTAssertEqual(ep["data_ciphers_fallback"]?.str?.uppercased(), "AES-256-CBC")
    }

    func testParsesNordRecommendations() throws {
        let s = try XCTUnwrap(NordApi.parseServers(Fixture.data("recommendations.json")).first)
        XCTAssertNotNil(s.host.wholeMatch(of: /nl\d+\.nordvpn\.com/))
        XCTAssertEqual(s.city, "Amsterdam")
        XCTAssertEqual(s.publicKey.count, 44)
        XCTAssertEqual(try NordApi.parseServers(Fixture.data("recommendations.json")).count, 1)
    }

    func testServersWithoutAWireGuardKeyAreSkippedOnlyWhenOneIsNeeded() throws {
        let body = Data(#"[{"name":"a #1","hostname":"a1.nordvpn.com","station":"1.2.3.4","load":9,"technologies":[]}]"#.utf8)
        XCTAssertTrue(try NordApi.parseServers(body).isEmpty)
        let s = try XCTUnwrap(NordApi.parseServers(body, needKey: false).first)
        XCTAssertEqual(s.publicKey, ""); XCTAssertEqual(s.load, 9); XCTAssertEqual(s.city, "")
        // A key that isn't one (32 bytes in Base64) counts as none.
        let bad = Data(#"[{"name":"a #1","hostname":"a1.nordvpn.com","station":"1.2.3.4","technologies":[{"identifier":"wireguard_udp","metadata":[{"name":"public_key","value":"not-a-key"}]}]}]"#.utf8)
        XCTAssertTrue(try NordApi.parseServers(bad).isEmpty)
    }

    func testGroupCountriesAreReadFromTheFullServerList() throws {
        let body = #"[{"hostname":"a","locations":[{"country":{"code":"US"}}]},{"hostname":"b","locations":[{"country":{"code":"NL"}}]},{"hostname":"c","locations":[{"country":{"code":"US"}}]}]"#
        XCTAssertEqual(try NordApi.countryCodes(Data(body.utf8)), ["US", "NL"])
    }

    func testDedicatedServersComeFromTheAccountsOwnService() throws {
        let services = #"""
            [{"ID":1,"expires_at":"2099-01-01 00:00:00","service":{"id":1,"name":"VPN"},"details":{}},
            {"ID":2,"expires_at":"2099-01-01 00:00:00","service":{"id":11,"name":"Dedicated IP"},"details":{"servers":[{"id":947235},{"id":947238}]}},
            {"ID":3,"expires_at":"2020-01-01 00:00:00","service":{"id":11,"name":"Dedicated IP"},"details":{"servers":[{"id":111}]}},
            {"ID":4,"expires_at":"2099-01-01 00:00:00","service":{"id":33,"name":"Dedicated server"},"details":{"servers":[{"id":222}]}}]
            """#
        var c = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 10, day: 18, hour: 12)
        c.calendar = Calendar(identifier: .gregorian)
        let ids = try NordApi.dedicatedIds(Data(services.utf8), now: c.date!)
        XCTAssertEqual(ids, [947235, 947238])
        XCTAssertTrue(try NordApi.dedicatedIds(Data("[]".utf8)).isEmpty)

        func sv(_ id: Int, _ host: String) -> String {
            """
            {"id":\(id),"name":"United States #\(id)","hostname":"\(host).nordvpn.com","station":"89.187.175.\(id % 250)","load":3,
            "locations":[{"country":{"code":"US","city":{"name":"Dallas"}}}],
            "technologies":[{"identifier":"wireguard_udp","metadata":[{"name":"public_key","value":"\(key1)"}]}]}
            """
        }
        let all = "[\(sv(947235, "us2943")),\(sv(947238, "us2944")),\(sv(5, "us1"))]"
        let mine = try NordApi.withIds(Data(all.utf8), ids, needKey: true)
        XCTAssertEqual(mine.map(\.host), ["us2943.nordvpn.com", "us2944.nordvpn.com"])
        XCTAssertEqual(mine.first?.city, "Dallas")
        XCTAssertEqual(mine.first?.publicKey, key1)
    }

    func testTechFollowsTheGroupAndProtocol() {
        XCTAssertEqual(Nord.tech(Location()), "wireguard_udp")
        XCTAssertEqual(Nord.tech(Location(proto: "openvpn_tcp")), "openvpn_tcp")
        XCTAssertEqual(Nord.tech(Location(group: "legacy_double_vpn")), "openvpn_udp")
        XCTAssertEqual(Nord.tech(Location(group: "legacy_onion_over_vpn", proto: "wireguard_udp")), "openvpn_udp")
        XCTAssertEqual(Nord.tech(Location(group: "legacy_double_vpn", proto: "openvpn_tcp")), "openvpn_tcp")
    }

    func testAccountSurvivesARoundTripAndOldBlobsWithoutServiceCredentials() throws {
        let a = Nord.Account(token: "t", key: "k", user: "u", pass: "p")
        XCTAssertEqual(try Nord.account(JSON.encode(a)).user, "u")
        let old = try Nord.account(#"{"token":"t","key":"k"}"#)
        XCTAssertEqual(old.user, ""); XCTAssertEqual(old.pass, "")
        XCTAssertThrowsError(try Nord.account("{}"))
    }

    func testPeerUsesNordsFixedTunnelAddress() {
        let p = Nord.peer(Server(name: "n", host: "h", ip: "1.2.3.4", publicKey: key1, load: 1), "priv")
        XCTAssertEqual(p.endpoint, "1.2.3.4:51820"); XCTAssertEqual(p.address, ["10.5.0.2/32"]); XCTAssertEqual(p.publicKey, key1)
    }

    func testSignInRejectsAMalformedToken() async {
        do { _ = try await Nord().signIn(["token": "short"]); XCTFail("expected rejection") } catch {
            XCTAssertEqual(error.localizedDescription, "That doesn't look like a NordVPN token")
        }
    }

    func testSignInChecksTheServiceKeyAndOpenVpnRemotes() async throws {
        let valid = key1
        let good = try await NordApi.credentials("t", request: { _, _, _ in Data(#"{"nordlynx_private_key":"\#(valid)","username":"u","password":"p"}"#.utf8) })
        XCTAssertEqual(good.key, key1)
        // 31 bytes of key: refused at sign-in, not found later as a problem with a route.
        let short = Data(repeating: 1, count: 31).base64EncodedString()
        for key in [short, "not base64", ""] {
            do {
                _ = try await NordApi.credentials("t", request: { _, _, _ in Data(#"{"nordlynx_private_key":"\#(key)","username":"u","password":"p"}"#.utf8) })
                XCTFail("accepted key \(key)")
            } catch { XCTAssertEqual(error.localizedDescription, "Unexpected reply from NordVPN") }
        }
        let sv = Server(name: "UK #1", host: "uk1.nordvpn.com", ip: "89.238.150.123", publicKey: "", load: 1)
        XCTAssertNoThrow(try Nord.profile(ovpn("nord-double.udp.ovpn"), sv, user: "u", pass: "p"))
        let original = ovpn("nord-double.udp.ovpn")
        for remote in ["192.168.1.1 1194", "127.0.0.1 1194", "evil.example.com 1194", "10.0.0.1 1194"] {
            let tampered = original.replacingOccurrences(of: "remote 89.238.150.123 1231", with: "remote \(remote)")
            XCTAssertThrowsError(try Nord.profile(tampered, sv, user: "u", pass: "p"), remote)
        }
        // A profile with no remote at all is refused here too, not left to the parser.
        let none = original.split(separator: "\n").filter { !$0.hasPrefix("remote ") }.joined(separator: "\n")
        XCTAssertThrowsError(try Nord.profile(none, sv, user: "u", pass: "p"))
    }
}
