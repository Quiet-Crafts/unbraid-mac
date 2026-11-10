import CryptoKit
import XCTest

private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func D(_ s: String) -> Data { Data(s.utf8) }
private func thrown(_ f: () throws -> some Any) -> Error? { do { _ = try f(); return nil } catch { return error } }
private func wg(_ l: Link) -> (server: Server, peer: WgPeer) {
    guard case .wg(let s, let p, _, _) = l else { fatalError("not a WireGuard link") }
    return (s, p)
}

final class MullvadTests: XCTestCase {
    private let list = try! Mullvad.parse(Fixture.data("mullvad_relays.json"))
    private let acct = Mullvad.Account(account: "1234567890123456", privateKey: "cHJpdmF0ZS1wcml2YXRlLXByaXZhdGUtcHJpdmF0ZTE=", ipv4Address: "10.66.12.34/32", deviceId: "dev-1")

    private func hex(_ s: String) -> Data {
        Data(stride(from: 0, to: s.count, by: 2).map { UInt8(s.dropFirst($0).prefix(2), radix: 16)! })
    }

    private func link(_ loc: Location, seed: UInt64) throws -> Link {
        var rng = SeededRNG(seed)
        return try Mullvad.link(list, loc, acct, using: &rng)
    }

    func testDerivationMatchesRfc7748() throws {
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
        XCTAssertEqual(priv.publicKey.rawRepresentation, hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"))
    }

    func testGeneratedKeysAreWireGuardFormat() throws {
        let k = WgKeys.generate()
        XCTAssertEqual(k.privateKey.count, 44)
        XCTAssertEqual(k.publicKey.count, 44)
        let priv = try XCTUnwrap(Data(base64Encoded: k.privateKey))
        XCTAssertEqual(priv[0] & 7, 0)
        XCTAssertEqual(priv[31] & 0xC0, 64)
        XCTAssertEqual(Data(base64Encoded: k.publicKey), try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: priv).publicKey.rawRepresentation)
        XCTAssertNotEqual(k.privateKey, WgKeys.generate().privateKey)
    }

    func testCountriesAreGroupedAndKeyed() throws {
        let cs = Mullvad.countries(list)
        XCTAssertEqual(cs.map(\.name), ["Netherlands", "Sweden", "USA"])
        XCTAssertEqual(cs.map(\.code), ["NL", "SE", "US"])
        XCTAssertEqual(Set(cs.map(\.id)).count, cs.count)
        let se = try XCTUnwrap(cs.first { $0.code == "SE" })
        XCTAssertEqual(se.cities.compactMap(\.key).sorted(), ["se-got", "se-mma", "se-sto"])
        XCTAssertEqual(se.cities.map(\.name), se.cities.map(\.name).sorted())
        XCTAssertTrue(cs.allSatisfy { c in c.serverCount > 0 && c.cities.allSatisfy { $0.key!.hasPrefix(c.code.lowercased() + "-") } })
    }

    func testInactiveRelaysAreDropped() throws {
        XCTAssertTrue(list.wireguard.relays.contains { !$0.active })
        XCTAssertTrue(list.usable.allSatisfy(\.active))
        let nl = try XCTUnwrap(Mullvad.countries(list).first { $0.code == "NL" })
        XCTAssertEqual(nl.serverCount, list.usable.filter { $0.location == "nl-ams" }.count)
    }

    func testRelayKeysAreWireGuardKeys() throws {
        let rs = try Mullvad.parse(D(#"""
            {"locations":{"xx-aaa":{"country":"X","city":"A"}},"wireguard":{"relays":[
            {"hostname":"xx-aaa-wg-001","location":"xx-aaa","active":true,"ipv4_addr_in":"1.1.1.1","public_key":"not-a-key","weight":100},
            {"hostname":"xx-aaa-wg-002","location":"xx-aaa","active":true,"ipv4_addr_in":"1.1.1.2","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","weight":1}]}}
            """#))
        XCTAssertEqual(rs.usable.map(\.hostname), ["xx-aaa-wg-002"])
        // Pinned, it is still listed: not gone, so its route tries again once the list is right.
        let pinned = Server(name: "xx-aaa-wg-001", host: "xx-aaa-wg-001", ip: "1.1.1.1", publicKey: "k", load: 0)
        do { _ = try Mullvad.link(rs, Location(provider: "mullvad", pinned: pinned), acct); XCTFail("linked") } catch {
            XCTAssertFalse(error is Catalog.Gone)
        }
        XCTAssertFalse(list.wireguard.relays.isEmpty)
        XCTAssertTrue(list.wireguard.relays.allSatisfy { $0.publicKey.count == 44 && validWgKey($0.publicKey) })
    }

    func testCountryLinkUsesAnActiveRelayInThatCountry() throws {
        let eligible = Set(list.usable.filter { $0.location.hasPrefix("se-") && $0.inCountry }.map(\.hostname))
        let seen = try (1...60).map { wg(try link(Location(provider: "mullvad", countryCode: "SE"), seed: $0)) }
        for (server, p) in seen {
            XCTAssertTrue(eligible.contains(server.host))
            XCTAssertEqual(p.publicKey, server.publicKey)
            XCTAssertEqual(p.endpoint, "\(server.ip):51820")
            XCTAssertEqual(p.address, ["10.66.12.34/32"])
            XCTAssertEqual(p.allowedIps, ["0.0.0.0/0"])
            XCTAssertEqual(p.dns, ["10.64.0.1"])
            XCTAssertEqual(p.privateKey, acct.privateKey)
        }
        XCTAssertFalse(seen.contains { $0.server.host == "se-mma-wg-004" })
    }

    func testCityLinkIncludesRelaysHiddenFromTheCountry() throws {
        let picks = try (1...60).map { wg(try link(Location(provider: "mullvad", countryCode: "SE", region: "se-mma"), seed: $0)).server }
        XCTAssertTrue(picks.allSatisfy { $0.host.hasPrefix("se-mma-") && $0.city == "Malmö" })
        XCTAssertTrue(picks.contains { $0.host == "se-mma-wg-004" })
    }

    func testWeightDecidesThePick() throws {
        let rs = try Mullvad.parse(D(#"""
            {"locations":{"xx-aaa":{"country":"X","city":"A"}},"wireguard":{"relays":[
            {"hostname":"xx-aaa-wg-001","location":"xx-aaa","active":true,"ipv4_addr_in":"1.1.1.1","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","weight":0},
            {"hostname":"xx-aaa-wg-002","location":"xx-aaa","active":true,"ipv4_addr_in":"1.1.1.2","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","weight":100}]}}
            """#))
        for seed in 1...30 as ClosedRange<UInt64> {
            var rng = SeededRNG(seed)
            let l = try Mullvad.link(rs, Location(provider: "mullvad", countryCode: "XX"), acct, using: &rng)
            XCTAssertEqual(wg(l).server.host, "xx-aaa-wg-002")
        }
    }

    func testHugeOrNegativeWeightsNeverTrap() throws {
        let rs = try Mullvad.parse(D(#"""
            {"locations":{"xx-aaa":{"country":"X","city":"A"}},"wireguard":{"relays":[
            {"hostname":"xx-aaa-wg-001","location":"xx-aaa","active":true,"ipv4_addr_in":"1.1.1.1","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","weight":9223372036854775807},
            {"hostname":"xx-aaa-wg-002","location":"xx-aaa","active":true,"ipv4_addr_in":"1.1.1.2","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","weight":9223372036854775807},
            {"hostname":"xx-aaa-wg-003","location":"xx-aaa","active":true,"ipv4_addr_in":"1.1.1.3","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","weight":-9223372036854775808}]}}
            """#))
        XCTAssertEqual(rs.wireguard.relays.map(\.weight), [.max, .max, .min])
        var hosts = Set<String>()
        for seed in 1...40 as ClosedRange<UInt64> {
            var rng = SeededRNG(seed)
            hosts.insert(wg(try Mullvad.link(rs, Location(provider: "mullvad", countryCode: "XX"), acct, using: &rng)).server.host)
        }
        // Both huge weights share the picks; the negative one counts as zero.
        XCTAssertEqual(hosts, ["xx-aaa-wg-001", "xx-aaa-wg-002"])
    }

    func testPinnedServerNeedsNoRelayList() throws {
        let sv = wg(try Mullvad.link(list, Location(provider: "mullvad", countryCode: "NL"), acct)).server
        let l = wg(try Mullvad.link(nil, Location(provider: "mullvad", pinned: sv), acct))
        XCTAssertEqual(l.server, sv)
        XCTAssertEqual(l.peer.endpoint, "\(sv.ip):51820")
    }

    func testUnknownCountryFails() {
        XCTAssertNotNil(thrown { try Mullvad.link(list, Location(provider: "mullvad", countryCode: "ZZ"), acct) })
    }

    func testAccountBlobRoundTrips() throws {
        let blob = try Mullvad.device((201, D(#"{"id":"7e0cb5c6-0a0f-4f4a-9a61-0d2f0f0c0b8e","name":"x","pubkey":"k","ipv4_address":"10.68.1.2/32","ipv6_address":"fc00::2/128","hijack_dns":false,"created":"2026-10-18T00:00:00Z"}"#)), "1234567890123456", "priv")
        XCTAssertEqual(try Mullvad.account(blob), Mullvad.Account(account: "1234567890123456", privateKey: "priv", ipv4Address: "10.68.1.2/32", deviceId: "7e0cb5c6-0a0f-4f4a-9a61-0d2f0f0c0b8e", deviceName: "x"))
    }

    func testOwnedCountriesThroughProvider() async throws {
        let list = self.list
        var mullvad = Mullvad()
        mullvad.catalogue = { list }
        let provider: any Provider = mullvad
        let result = try await provider.freshCountries("", opts: ["owned": "on"])
        XCTAssertEqual(result.countries, Mullvad.countries(list, ownedOnly: true))
        XCTAssertNotEqual(result.countries, Mullvad.countries(list))
    }

    func testRateLimitReachesSignInMessage() {
        for error in [thrown { try Mullvad.token((429, Data())) }, thrown { try Mullvad.device((429, Data()), "a", "p") }] {
            XCTAssertEqual(signInFailure(error!, "Mullvad"), "Mullvad is limiting sign-in attempts. Wait a few minutes, then try again.")
        }
    }

    func testRevocationDistinguishesRefusalFromOutage() {
        XCTAssertTrue(Mullvad.revoked(despite: Http.Status(code: 404)))
        XCTAssertFalse(Mullvad.revoked(despite: Http.Status(code: 401)))
        XCTAssertFalse(Mullvad.revoked(despite: Http.Status(code: 403)))
        XCTAssertTrue(Mullvad.revoked(despite: AuthError()))
        XCTAssertFalse(Mullvad.revoked(despite: Http.Status(code: 500)))
        XCTAssertFalse(Mullvad.revoked(despite: URLError(.timedOut)))
        // A 404 from the token endpoint is not the device's.
        let token = thrown { try Mullvad.token((404, Data())) }
        XCTAssertFalse(Mullvad.revoked(despite: token!))
        XCTAssertFalse(Mullvad.released(despite: token!))
        // Nor is a 403 from it a refused account: a filter in front of the API can answer that for a healthy one.
        let blocked = thrown { try Mullvad.token((403, Data())) }
        XCTAssertFalse(blocked is AuthError)
        XCTAssertFalse(Mullvad.revoked(despite: blocked!))
    }

    func testAnAlreadyRemovedDeviceCountsAsReleased() {
        XCTAssertTrue(Mullvad.released(despite: Http.Status(code: 404)))
        XCTAssertFalse(Mullvad.released(despite: Http.Status(code: 500)))
        XCTAssertFalse(Mullvad.released(despite: AuthError()))
        XCTAssertFalse(Mullvad.released(despite: URLError(.timedOut)))
    }

    func testTokenAndDeviceErrors() throws {
        XCTAssertEqual(try Mullvad.token((200, D(#"{"access_token":"tok","expiry":"2026-10-19T00:00:00Z"}"#))), "tok")
        for r in [(400, D(#"{"code":"INVALID_ACCOUNT","error":"Bad account number"}"#)), (401, Data())] {
            XCTAssertTrue(thrown { try Mullvad.token(r) } is AuthError)
        }
        let max = thrown { try Mullvad.device((400, D(#"{"code":"MAX_DEVICES_REACHED","error":"x"}"#)), "1", "p") }
        XCTAssertTrue(max is AuthError)
        XCTAssertEqual(max?.localizedDescription, "All 5 Mullvad devices are in use. Sign out another device, then try again.")
        XCTAssertEqual((max as? AuthError)?.url, "https://mullvad.net/account/devices")
        let server = thrown { try Mullvad.device((500, Data()), "1", "p") }
        XCTAssertNotNil(server)
        XCTAssertFalse(server is AuthError)
    }

    func testLostRegistrationReplyIsReconciledByPublicKey() throws {
        let keys = WgKeys.Keys(privateKey: "priv", publicKey: "ourpub")
        let devices = D(#"[{"id":"d-1","name":"a","pubkey":"other","ipv4_address":"10.68.0.1/32"},{"id":"d-2","name":"b","pubkey":"ourpub","ipv4_address":"10.68.0.2/32","hijack_dns":false}]"#)
        let blob = try XCTUnwrap(try Mullvad.adopt(devices, "1234567890123456", keys))
        XCTAssertEqual(try Mullvad.account(blob), Mullvad.Account(account: "1234567890123456", privateKey: "priv", ipv4Address: "10.68.0.2/32", deviceId: "d-2", deviceName: "b"))
        XCTAssertNil(try Mullvad.adopt(D("[]"), "1234567890123456", keys))
        XCTAssertNil(try Mullvad.adopt(devices, "1234567890123456", WgKeys.Keys(privateKey: "p", publicKey: "unknown")))
    }

    func testParseFailuresDoNotQuoteTheReply() {
        let bad = D(#"{"access_token": SECRET-TOKEN"#)
        let failures: [() throws -> Any] = [
            { try Mullvad.token((200, bad)) }, { try Mullvad.device((201, bad), "1", "p") },
            { try Mullvad.account(#"{"account":"SECRET-ACCT" "#) }, { try Mullvad.parse(D("SECRET-LIST")) },
        ]
        for f in failures {
            let e = thrown { try f() }
            XCTAssertNotNil(e)
            XCTAssertFalse(e?.localizedDescription.contains("SECRET") ?? true)
        }
    }

    func testBadAccountNumberIsRejectedBeforeAnyRequest() async {
        for bad in ["", "1234", "12345678901234567", "abcd1234abcd1234"] {
            do { _ = try await Mullvad().signIn(["account": bad]); XCTFail("accepted \(bad)") } catch {
                XCTAssertEqual(error.localizedDescription, "A Mullvad account number has 16 digits")
            }
        }
    }
}

extension MullvadTests {
    func testBlockingCategoriesAndPorts() throws {
        let p = Mullvad()
        XCTAssertEqual(p.blockingDns { _ in nil }, "100.64.0.7")
        XCTAssertEqual(p.blockingDns { ["adult", "social"].contains($0) ? "on" : "off" }, "100.64.0.47")
        XCTAssertEqual(p.blockingDns { _ in "on" }, "100.64.0.63")
        let list = try Mullvad.parse(Fixture.data("mullvad_relays.json"))
        let a = Mullvad.Account(account: "1", privateKey: "k", ipv4Address: "10.0.0.1/32", deviceId: "d")
        guard case .wg(_, _, let ports, _) = try Mullvad.link(list, Location(provider: "mullvad", countryCode: "NL"), a) else { return XCTFail() }
        XCTAssertEqual(ports, [51820, 53, 123, 4500])
        XCTAssertEqual(p.linkOptions.map(\.key), ["adult", "gambling", "social", "owned", "port"])
    }

    func testOwnedFilterAndLegacyAccount() throws {
        let body = Data(#"{"locations":{"xx-aaa":{"country":"X","city":"A"}},"wireguard":{"relays":[{"hostname":"owned","location":"xx-aaa","ipv4_addr_in":"1.1.1.1","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","owned":true},{"hostname":"rented","location":"xx-aaa","ipv4_addr_in":"1.1.1.2","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","owned":false}]}}"#.utf8)
        let list = try Mullvad.parse(body)
        XCTAssertEqual(Mullvad.countries(list, ownedOnly: true).first?.serverCount, 1)
        XCTAssertEqual(list.match(Location(provider: "mullvad"), ownedOnly: true).map(\.hostname), ["owned"])
        let rented = Server(name: "rented", host: "rented", ip: "1.1.1.2", publicKey: "k", load: 0)
        let account = Mullvad.Account(account: "1", privateKey: "k", ipv4Address: "10.0.0.1/32", deviceId: "d")
        XCTAssertEqual(try Mullvad.link(list, Location(provider: "mullvad", pinned: rented), account, ownedOnly: true).server.host, "rented")
        let old = try Mullvad.account(#"{"account":"1","privateKey":"k","ipv4Address":"10.0.0.1/32","deviceId":"d"}"#)
        XCTAssertNil(old.deviceName)
        XCTAssertEqual(try Mullvad.expiry(Data(#"{"expiry":"2026-11-22T08:00:00Z"}"#.utf8), now: Date(timeIntervalSince1970: 0)), "Paid until 22 Nov 2026")
        XCTAssertEqual(try Mullvad.expiry(Data(#"{"expiry":"2026-11-22T08:00:00.123Z"}"#.utf8), now: Date(timeIntervalSince1970: 0)), "Paid until 22 Nov 2026")
    }
}
