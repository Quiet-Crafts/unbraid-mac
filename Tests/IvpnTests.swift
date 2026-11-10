import XCTest
import Synchronization

private func D(_ s: String) -> Data { Data(s.utf8) }
private func thrown(_ f: () throws -> some Any) -> Error? { do { _ = try f(); return nil } catch { return error } }
private func wg(_ l: Link) -> (server: Server, peer: WgPeer) {
    guard case .wg(let s, let p, _, _) = l else { fatalError("not a WireGuard link") }
    return (s, p)
}

final class IvpnTests: XCTestCase {
    private let list = try! Ivpn.parse(Fixture.data("ivpn_servers.json"))
    private let acct = Ivpn.Account(accountId: "i-ABCD-EFGH-IJKL", sessionToken: "session", privateKey: "cHJpdmF0ZS1wcml2YXRlLXByaXZhdGUtcHJpdmF0ZTE=", ipAddress: "172.16.34.56")

    func testIncompleteSessionIsReleasedAndChallengesAreNot() async throws {
        let deleted = Mutex<[String]>([])
        var provider = Ivpn()
        provider.newSession = { _ in (200, Data(#"{"status":200,"token":"tok"}"#.utf8)) }
        provider.deleteSession = { token in deleted.withLock { $0.append(token) }; return (200, Data()) }
        do { _ = try await provider.signIn(["account": "i-ABCD-EFGH-IJKL"]); XCTFail("expected failure") } catch { }
        XCTAssertEqual(deleted.withLock { $0 }, ["tok"])
        provider.newSession = { _ in (200, Data(#"{"status":200,"token":"empty-ip","wireguard":{"ip_address":""}}"#.utf8)) }
        do { _ = try await provider.signIn(["account": "i-ABCD-EFGH-IJKL"]); XCTFail("expected failure") } catch { }
        XCTAssertEqual(deleted.withLock { $0 }, ["tok", "empty-ip"])
        provider.newSession = { _ in (400, Data(#"{"status":70011}"#.utf8)) }
        do { _ = try await provider.signIn(["account": "i-ABCD-EFGH-IJKL"]); XCTFail("expected challenge") } catch { XCTAssertTrue(error is Challenge) }
        XCTAssertEqual(deleted.withLock { $0 }, ["tok", "empty-ip"])
    }

    func testAlreadyRemovedSessionIsReleased() {
        XCTAssertTrue(Ivpn.released((200, Data())))
        XCTAssertTrue(Ivpn.released((400, Data(#"{"status":601}"#.utf8))))
        XCTAssertTrue(Ivpn.released((401, Data())))
        XCTAssertFalse(Ivpn.released((500, Data())))
        // IVPN's own status decides over a 2xx HTTP answer.
        XCTAssertTrue(Ivpn.released((200, Data(#"{"status":200}"#.utf8))))
        XCTAssertTrue(Ivpn.released((200, Data(#"{"status":601}"#.utf8))))
        XCTAssertFalse(Ivpn.released((200, Data(#"{"status":500}"#.utf8))))
        XCTAssertFalse(Ivpn.released((200, Data(#"{"status":602}"#.utf8))))
        XCTAssertFalse(Ivpn.released((200, Data(#"{"status":500,"data":[]}"#.utf8))), "a field it doesn't expect hides nothing")
        XCTAssertFalse(Ivpn.released((200, Data(#"{"status":"500"}"#.utf8))))
        XCTAssertTrue(Ivpn.released((200, Data(#"{"message":"ok"}"#.utf8))))
    }

    func testCountriesAreGroupedAndKeyed() throws {
        let cs = Ivpn.countries(list)
        XCTAssertEqual(cs.map(\.name), ["Argentina", "Netherlands", "Sweden", "United States"])
        XCTAssertEqual(cs.map(\.code), ["AR", "NL", "SE", "US"])
        XCTAssertEqual(Set(cs.map(\.id)).count, cs.count)
        let us = try XCTUnwrap(cs.first { $0.code == "US" })
        XCTAssertGreaterThan(us.cities.count, 5)
        XCTAssertTrue(us.cities.allSatisfy { $0.key!.hasSuffix(".wg.ivpn.net") })
        XCTAssertEqual(us.cities.map(\.name), us.cities.map(\.name).sorted())
        XCTAssertEqual(Set(us.cities.map(\.key)).count, us.cities.count)
        XCTAssertEqual(us.serverCount, list.wireguard.filter { $0.countryCode == "US" }.reduce(0) { $0 + $1.hosts.count })
    }

    func testHostKeysAreWireGuardKeys() {
        let hosts = list.wireguard.flatMap(\.hosts)
        XCTAssertFalse(hosts.isEmpty)
        XCTAssertTrue(hosts.allSatisfy { $0.publicKey.count == 44 && validWgKey($0.publicKey) })
    }

    func testCountryLinkPicksTheLeastLoadedHost() throws {
        let l = wg(try Ivpn.link(list, Location(provider: "ivpn", countryCode: "NL"), acct))
        let best = try XCTUnwrap(list.wireguard.filter { $0.countryCode == "NL" }.flatMap(\.hosts).min { $0.load < $1.load })
        XCTAssertEqual(l.server.host, best.hostname)
        XCTAssertEqual(l.peer.publicKey, best.publicKey)
        XCTAssertEqual(l.peer.endpoint, "\(best.host):2049")
        XCTAssertEqual(l.peer.address, ["172.16.34.56/32"])
        XCTAssertEqual(l.peer.dns, ["172.16.0.1"])
        XCTAssertEqual(l.peer.allowedIps, ["0.0.0.0/0"])
        XCTAssertEqual(l.peer.privateKey, acct.privateKey)
        XCTAssertEqual(l.server.city, "Amsterdam")
    }

    func testCityLinkStaysInThatGateway() throws {
        let l = wg(try Ivpn.link(list, Location(provider: "ivpn", countryCode: "US", region: "us-ny.wg.ivpn.net"), acct))
        XCTAssertEqual(l.server.city, "New York, NY")
        XCTAssertTrue(l.server.host.hasPrefix("us-ny"))
    }

    func testPinnedServerNeedsNoList() throws {
        let sv = wg(try Ivpn.link(list, Location(provider: "ivpn", countryCode: "SE"), acct)).server
        XCTAssertEqual(wg(try Ivpn.link(nil, Location(provider: "ivpn", pinned: sv), acct)).server, sv)
    }

    func testOutOfRangeLoadIsClamped() throws {
        func load(_ n: String) throws -> Int {
            let l = try Ivpn.parse(D(#"{"wireguard":[{"gateway":"nl.wg.ivpn.net","country_code":"NL","country":"Netherlands","city":"Amsterdam","hosts":[{"hostname":"nl1.wg.ivpn.net","host":"1.2.3.4","public_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","local_ip":"172.16.0.1/12","load":"# + n + "}]}]}"))
            return wg(try Ivpn.link(l, Location(provider: "ivpn", countryCode: "NL"), acct)).server.load
        }
        XCTAssertEqual(try load("1e300"), 100)
        XCTAssertEqual(try load("-1e300"), 0)
        XCTAssertEqual(try load("42.4"), 42)
    }

    func testHostsWithAMalformedKeyOrResolverAreSkipped() throws {
        func host(_ name: String, key: String, localIp: String, load: Int) -> String {
            #"{"hostname":"\#(name)","host":"1.2.3.\#(load)","public_key":"\#(key)","local_ip":"\#(localIp)","load":\#(load)}"#
        }
        let hosts = [host("bad-key", key: "k", localIp: "172.16.0.1/12", load: 1), host("bad-dns", key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", localIp: "dns.example", load: 2),
                     host("good", key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", localIp: "172.16.0.1/12", load: 3)]
        let l = try Ivpn.parse(D(#"{"wireguard":[{"gateway":"nl.wg.ivpn.net","country_code":"NL","country":"Netherlands","city":"Amsterdam","hosts":["# + hosts.joined(separator: ",") + "]}]}"))
        // The lowest load would be picked: a bad row is never it.
        let p = wg(try Ivpn.link(l, Location(provider: "ivpn", countryCode: "NL"), acct))
        XCTAssertEqual(p.server.host, "good")
        XCTAssertEqual(p.peer.dns, ["172.16.0.1"])
        // A pinned host that is still listed is not gone: its route tries again once the list is right.
        for name in ["bad-key", "bad-dns"] {
            let pinned = Server(name: name, host: name, ip: "1.2.3.4", publicKey: "k", load: 0)
            do { _ = try Ivpn.link(l, Location(provider: "ivpn", pinned: pinned), acct); XCTFail(name) } catch {
                XCTAssertFalse(error is Catalog.Gone, name)
            }
        }
    }

    func testUnknownCountryFails() {
        XCTAssertNotNil(thrown { try Ivpn.link(list, Location(provider: "ivpn", countryCode: "ZZ"), acct) })
    }

    func testSessionReplies() throws {
        let ok = try Ivpn.session((200, D(#"{"status":200,"token":"tok","vpn_username":"u","vpn_password":"p","service_status":{"is_active":true},"wireguard":{"status":200,"message":"Success","ip_address":"172.16.1.2"}}"#)), "i-ABCD-EFGH-IJKL", "priv")
        let account = try Ivpn.account(ok)
        XCTAssertEqual(account.accountId, "i-ABCD-EFGH-IJKL")
        XCTAssertEqual(account.ipAddress, "172.16.1.2")
        XCTAssertNotNil(account.createdAt)
        let limit = thrown { try Ivpn.session((400, D(#"{"status":602,"message":"You've reached the maximum number of connected devices","data":{"limit":5}}"#)), "a", "p") }
        XCTAssertTrue(limit is AuthError)
        XCTAssertEqual(limit?.localizedDescription, "All 5 IVPN devices are in use. Sign out another device, then try again.")
        XCTAssertEqual((limit as? AuthError)?.url, "https://www.ivpn.net/clientarea/")
        for body in [#"{"status":401,"message":"The provided Account ID is not valid"}"#, #"{"status":702,"message":"inactive"}"#, #"{"status":70001}"#] {
            XCTAssertTrue(thrown { try Ivpn.session((400, D(body)), "a", "p") } is AuthError)
        }
        let challenge = thrown { try Ivpn.session((400, D(#"{"status":70011}"#)), "a", "p") } as? Challenge
        XCTAssertEqual(challenge?.field.label, "Two-factor code")
        let captcha = thrown { try Ivpn.session((400, D(#"{"status":70001,"captcha_id":"safe-id","captcha_image":"data:image/png;base64,YWJj"}"#)), "a", "p") } as? Challenge
        XCTAssertEqual(captcha?.field.label, "Characters in the picture")
        XCTAssertEqual(captcha?.state["captcha_id"], "safe-id")
        XCTAssertEqual(captcha?.image, Data("abc".utf8))
        let bad = thrown { try Ivpn.session((502, D("<html>")), "a", "p") }
        XCTAssertNotNil(bad)
        XCTAssertFalse(bad is AuthError)
        XCTAssertEqual(signInFailure(bad!, "IVPN"), "IVPN answered with an error (HTTP 502). Try again later.")
        XCTAssertTrue(thrown { try Ivpn.session((401, D("<html>")), "a", "p") } is AuthError)
        XCTAssertEqual(thrown { try Ivpn.session((200, D("<html>")), "a", "p") }?.localizedDescription, "Unexpected reply from IVPN")
        // A body saying 200 doesn't make a failed HTTP answer a session.
        let conflicting = thrown { try Ivpn.session((502, D(#"{"status":200,"token":"tok","wireguard":{"ip_address":"172.16.1.2"}}"#)), "a", "p") }
        XCTAssertEqual(signInFailure(conflicting!, "IVPN"), "IVPN answered with an error (HTTP 502). Try again later.")
    }

    func testRetryChallengesAndRateLimit() {
        for (status, message) in [(70011, "Enter the code from your authenticator app."), (70012, "That code didn't work. Enter the current one."), (70001, "Type the characters in the picture."), (70002, "That didn't match. Try this picture.")] {
            let body = D("{\"status\":\(status),\"captcha_id\":\"safe\"}")
            let challenge = thrown { try Ivpn.session((400, body), "a", "p") } as? Challenge
            XCTAssertEqual(challenge?.message, message)
        }
        for body in [D("<html>"), D(#"{"status":429}"#), D(#"{"status":200}"#), D(#"{"status":401}"#)] {
            let error = thrown { try Ivpn.session((429, body), "a", "p") }!
            XCTAssertEqual(signInFailure(error, "IVPN"), "IVPN is limiting sign-in attempts. Wait a few minutes, then try again.")
        }
    }

    func testParseFailuresDoNotQuoteTheReply() {
        let failures: [() throws -> Any] = [
            { try Ivpn.session((200, D(#"{"status":200,"token":"SECRET-TOKEN" "#)), "a", "p") },
            { try Ivpn.account(#"{"sessionToken":"SECRET" "#) }, { try Ivpn.parse(D("SECRET-LIST")) },
        ]
        for f in failures {
            let e = thrown { try f() }
            XCTAssertNotNil(e)
            XCTAssertFalse(e?.localizedDescription.contains("SECRET") ?? true)
        }
        let noAddress = thrown { try Ivpn.session((200, D(#"{"status":200,"token":"t"}"#)), "a", "p") }
        XCTAssertNotNil(noAddress)
        XCTAssertFalse(noAddress is AuthError)
        let unknown = thrown { try Ivpn.session((400, D(#"{"status":999,"message":"echoes SECRET"}"#)), "a", "p") }
        XCTAssertNotNil(unknown)
        XCTAssertFalse(unknown?.localizedDescription.contains("SECRET") ?? true)
    }

    func testBadAccountIdIsRejectedBeforeAnyRequest() async {
        for bad in ["", "i-ABCD", "x-ABCD-EFGH-IJKL", "1234567890"] {
            do { _ = try await Ivpn().signIn(["account": bad]); XCTFail("accepted \(bad)") } catch {
                XCTAssertEqual(error.localizedDescription, "Account ID must look like i-XXXX-XXXX-XXXX or ivpnXXXXXXXX")
            }
        }
    }
    func testOldAccountAndPlanDecode() throws {
        let old = #"{"accountId":"a","sessionToken":"t","privateKey":"p","ipAddress":"172.16.0.2"}"#
        XCTAssertNil(try Ivpn.account(old).device)
        let reply = #"{"status":200,"token":"t","device_name":"Mac","service_status":{"current_plan":"IVPN Pro","available_plans":[{"name":"Pro","device_limit":7}]},"wireguard":{"ip_address":"172.16.0.2/32"}}"#
        let a = try Ivpn.account(Ivpn.session((200, D(reply)), "a", "p"))
        XCTAssertEqual(a.limit, 7); XCTAssertEqual(a.device, "Mac")
    }
    func testOptionsAndPorts() throws {
        let body = #"{"config":{"ports":{"wireguard":[{"type":"UDP","port":2049},{"type":"UDP","port":443},{"type":"TCP","port":80}]},"antitracker_plus":{"DnsServers":[{"Description":"Example","Normal":"10.0.0.1","Hardcore":"10.0.0.2"}]}}}"#
        let l = try Ivpn.parse(D(body))
        XCTAssertEqual(l.ports, [443, 2049])
        XCTAssertEqual(Ivpn.options(l).map(\.key), ["list", "hardcore", "port"])
        let p = Ivpn()
        XCTAssertFalse(try XCTUnwrap(p.option("port")).accepts("9999"))
        XCTAssertTrue(try XCTUnwrap(Ivpn.options(l).first { $0.key == "port" }).accepts("443"))
        XCTAssertEqual(p.blockingDns { ["list":"10.0.0.1|10.0.0.2", "hardcore":"on"][$0] }, "10.0.0.2")
        XCTAssertEqual(p.blockingDns { _ in "bad|bad" }, "10.0.254.2")
    }

    func testStatusAndRevocation() async throws {
        let blob = JSON.encode(acct)
        var p = Ivpn()
        p.statusRequest = { _ in (200, D(#"{"status":200,"device_name":"Mac"}"#)) }
        let device = try await p.device(blob)
        XCTAssertEqual(device, "Named Mac. See all your devices in the IVPN client area")
        p.statusRequest = { _ in (401, Data()) }
        let revoked = try await p.revoked(blob)
        XCTAssertTrue(revoked)
        p.statusRequest = { _ in throw Fail("offline") }
        let offline = try await p.revoked(blob)
        XCTAssertFalse(offline)
    }
    func testAutomaticPortsUseOnlyListedPorts() throws {
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixture.data("ivpn_servers.json")) as? [String: Any])
        body["config"] = ["ports": ["wireguard": [["type": "UDP", "port": 443], ["type": "UDP", "port": 2049], ["type": "UDP", "port": 9999]]]]
        let l = try Ivpn.parse(JSONSerialization.data(withJSONObject: body))
        guard case .wg(_, _, let ports, _) = try Ivpn.link(l, Location(provider: "ivpn"), acct) else { return XCTFail("not WireGuard") }
        XCTAssertEqual(ports, [2049, 443])
    }

}
