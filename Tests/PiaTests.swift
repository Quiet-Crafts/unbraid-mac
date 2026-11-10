import XCTest

private func D(_ s: String) -> Data { Data(s.utf8) }
private func thrown(_ f: () throws -> some Any) -> Error? { do { _ = try f(); return nil } catch { return error } }

final class PiaTests: XCTestCase {
    private let list = Fixture.data("pia_servers_v6.txt")

    func testSignOutClearsTokensAndRejectsAnInFlightRefresh() async throws {
        let a = Pia.Account(username: "signout-test", password: "pw", token: "old", tokenTime: 0, privateKey: "k", publicKey: "p")
        let blob = JSON.encode(a)
        var provider = Pia()
        provider.tokenRequest = { _, _ in "new" }
        let initial = try await Pia.token(a, force: true, fetch: { _, _ in "initial" })
        XCTAssertEqual(initial, "initial")
        let gate = RefreshGate()
        let pending = Task { try await Pia.token(a, force: true, fetch: { _, _ in await gate.wait(); return "stale" }) }
        await gate.started()
        let signedOut = await provider.signOut(blob)
        XCTAssertTrue(signedOut)
        let signedIn = try await provider.signIn(["username": a.username, "password": a.password])
        XCTAssertEqual(try Pia.account(signedIn).token, "new")
        await gate.release()
        _ = try await pending.value
        let cached = try await Pia.token(a, fetch: { _, _ in "unexpected" })
        XCTAssertEqual(cached, "new")
        let signedOutAgain = await provider.signOut(blob)
        XCTAssertTrue(signedOutAgain)
        let afterSecondSignOut = try await Pia.token(a, fetch: { _, _ in "again" })
        XCTAssertEqual(afterSecondSignOut, "again")
        _ = await provider.signOut(blob)
    }

    func testInvalidServersDoNotConsumeRegistrationTries() {
        let servers = [Pia.Wg(ip: "127.0.0.1", cn: "bad"), Pia.Wg(ip: "1.1.1.1", cn: "bad/name"),
                       Pia.Wg(ip: "8.8.8.8", cn: "one"), Pia.Wg(ip: "1.1.1.1", cn: "two"),
                       Pia.Wg(ip: "9.9.9.9", cn: "three"), Pia.Wg(ip: "8.8.4.4", cn: "four")]
        XCTAssertEqual(Pia.targets(servers).map(\.cn), ["one", "two", "three"])
    }

    func testServerListWithSignatureTailParses() throws {
        XCTAssertTrue(Fixture.text("pia_servers_v6.txt").drop { $0 != "\n" }.dropFirst().hasPrefix("\n"))
        let rs = try Pia.parseRegions(list)
        XCTAssertEqual(rs.map(\.id), ["us_denver", "nl_amsterdam", "nl_netherlands-so", "dz", "de_berlin", "de-frankfurt", "uk", "uk_manchester"])
        let denver = try XCTUnwrap(rs.first { $0.id == "us_denver" })
        XCTAssertEqual(denver.servers.wg.map(\.cn), ["denver425", "denver429", "denver431"])
        XCTAssertEqual(denver.servers.wg.first?.ip, "181.41.206.151")
        XCTAssertTrue(denver.country == "US" && !denver.geo && !denver.portForward)
        XCTAssertTrue(try XCTUnwrap(rs.first { $0.id == "dz" }).geo)
    }

    func testRegionsWithoutWireguardOrOfflineAreSkipped() throws {
        let body = #"{"regions":[{"id":"a","name":"A","country":"NL","servers":{"meta":[{"ip":"1.1.1.1","cn":"x"}]}},"#
            + #"{"id":"b","name":"B","country":"NL","offline":true,"servers":{"wg":[{"ip":"1.1.1.2","cn":"y"}]}},"#
            + #"{"id":"c","name":"C","country":"NL","servers":{"wg":[{"ip":"1.1.1.3","cn":"z"}]}}]}"# + "\n\nc2ln"
        XCTAssertEqual(try Pia.parseRegions(D(body)).map(\.id), ["c"])
    }

    func testRegionWithALongCountryIsDroppedNotACrash() throws {
        let body = #"{"regions":[{"id":"a","name":"A","country":"NETHERLANDS","servers":{"wg":[{"ip":"1.1.1.1","cn":"x"}]}},"#
            + #"{"id":"b","name":"B","country":"","servers":{"wg":[{"ip":"1.1.1.2","cn":"y"}]}},"#
            + #"{"id":"c","name":"C","country":"nl","servers":{"wg":[{"ip":"1.1.1.3","cn":"z"}]}}]}"# + "\n\nc2ln"
        let rs = try Pia.parseRegions(D(body))
        XCTAssertEqual(rs.map(\.id), ["c"])
        XCTAssertEqual(Pia.countries(rs).map(\.code), ["NL"])
    }

    func testGarbageListIsAnError() {
        XCTAssertNotNil(thrown { try Pia.parseRegions(D("<html>nope</html>")) })
    }

    func testCountriesAndCities() throws {
        let cs = Pia.countries(try Pia.parseRegions(list))
        XCTAssertEqual(cs.map(\.name), ["Algeria", "Germany", "Netherlands", "United Kingdom", "United States"])
        let de = try XCTUnwrap(cs.first { $0.code == "DE" })
        XCTAssertEqual(de.cities.map(\.name), ["Berlin", "Frankfurt"])
        XCTAssertEqual(de.cities.map(\.key), ["de_berlin", "de-frankfurt"])
        XCTAssertEqual(de.serverCount, 4)
        let nl = try XCTUnwrap(cs.first { $0.code == "NL" })
        XCTAssertEqual(nl.cities.map(\.name), ["Netherlands", "Netherlands Streaming Optimized"])
        // Ids come from the region id, so they survive PIA adding or dropping regions.
        XCTAssertEqual(nl.cities.map { stableId($0.key!) }, nl.cities.map(\.id))
        XCTAssertEqual(Set(nl.cities.map(\.id)).count, 2)
        XCTAssertEqual(Set(cs.map(\.id)).count, cs.count)
    }

    func testAddKeyResponseParses() throws {
        let k = try Pia.parseAddKey(Fixture.data("pia_addkey.json"))
        XCTAssertEqual(k.serverKey, "eo8n2+EwTSaTW8R/q9uJ813QuBY8uaF+vccoM5WNDEs=")
        XCTAssertEqual(k.serverPort, 1337)
        XCTAssertEqual(k.peerIp, "10.30.128.2")
        XCTAssertEqual(k.dns, ["10.0.0.243", "10.0.0.242"])
    }

    func testAddKeyErrors() {
        let refused = thrown { try Pia.parseAddKey(D(#"{"status":"ERROR","message":"Login failed!"}"#)) }
        XCTAssertNotNil(refused)
        XCTAssertFalse(refused?.localizedDescription.contains("Login failed!") ?? true)
        XCTAssertNotNil(thrown { try Pia.parseAddKey(D(#"{"status":"OK"}"#)) })
        XCTAssertNotNil(thrown { try Pia.parseAddKey(D("not json")) })
        let ok = #""status":"OK","server_key":"eo8n2+EwTSaTW8R/q9uJ813QuBY8uaF+vccoM5WNDEs=","#
        XCTAssertNotNil(thrown { try Pia.parseAddKey(D("{" + ok + #""server_port":0,"peer_ip":"10.1.2.3"}"#)) })
        XCTAssertNotNil(thrown { try Pia.parseAddKey(D("{" + ok + #""server_port":1337,"peer_ip":"10.1.2.3/32\n"}"#)) })
        // The server's key and resolvers go into the configuration: only a WireGuard key, only IPv4 addresses.
        XCTAssertNotNil(thrown { try Pia.parseAddKey(D(#"{"status":"OK","server_key":"not-a-key","server_port":1337,"peer_ip":"10.1.2.3"}"#)) })
        let k = try? Pia.parseAddKey(D("{" + ok + #""server_port":1337,"peer_ip":"10.1.2.3","dns_servers":["10.0.0.243","dns.example","10.0.0.242/32"]}"#))
        XCTAssertEqual(k?.dns, ["10.0.0.243"])
    }

    func testCaLoadsAsCertificate() throws {
        let summary = SecCertificateCopySubjectSummary(try Pia.caCertificate()) as String?
        XCTAssertTrue(summary?.contains("Private Internet Access") == true)
    }

    func testAccountBlobRoundTrips() throws {
        let a = Pia.Account(username: "p1234567", password: "pw", token: "tok", tokenTime: 1, privateKey: "k1", publicKey: "k2")
        XCTAssertEqual(try Pia.account(JSON.encode(a)), a)
    }

    func testParseFailuresDoNotQuoteTheReply() {
        let failures: [() throws -> Any] = [
            { try Pia.parseAddKey(D(#"{"status":"OK","server_key":"SECRET-KEY","server_port":"nope" "#)) },
            { try Pia.parseRegions(D(#"{"regions":"SECRET-LIST" "#)) }, { try Pia.account(#"{"username":"SECRET-USER" "#) },
        ]
        for f in failures {
            let e = thrown { try f() }
            XCTAssertNotNil(e)
            XCTAssertFalse(e?.localizedDescription.contains("SECRET") ?? true)
        }
    }
}

extension PiaTests {
    func testMaceIsThePageBlockingOption() {
        XCTAssertEqual(Pia().protection?.label, "MACE")
        XCTAssertEqual(Pia().blockingDns { _ in nil }, "10.0.0.244")
    }
}

private actor RefreshGate {
    private var entered = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        startWaiter?.resume()
        await withCheckedContinuation { resumeWaiter = $0 }
    }

    func started() async {
        if !entered { await withCheckedContinuation { startWaiter = $0 } }
    }

    func release() { resumeWaiter?.resume() }
}
