import XCTest
import Synchronization

final class ProviderFixesTests: XCTestCase {
    private typealias F = ProviderFixtures
    private let account = KeyAccount(privateKey: F.priv, address: ["10.2.0.2/32"], dns: ["10.2.0.1"], port: 51820, mtu: 1420)

    func testProviderRedirectsAreRefusedWithAndWithoutPinning() async throws {
        let url = try XCTUnwrap(URL(string: "https://provider.example"))
        let destination = try XCTUnwrap(URL(string: "https://other.example"))
        let request = URLRequest(url: destination)
        let task = URLSession.shared.dataTask(with: url)
        let delegates: [Http.NoRedirect] = [Http.NoRedirect(), Http.Pin(ca: try Pia.caCertificate(), host: "provider.example")]
        for code in [301, 302, 307, 308] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: ["Location": destination.absoluteString]))
            for delegate in delegates {
                let redirected = await delegate.urlSession(.shared, task: task, willPerformHTTPRedirection: response, newRequest: request)
                XCTAssertNil(redirected)
            }
            XCTAssertThrowsError(try Http.check(code, credentials: true)) { XCTAssertEqual(($0 as? Http.Status)?.code, code) }
        }
        // The sessions every provider request goes through use that delegate (a pinned request's own delegate is a Pin).
        for session in [Http.session, rawSession] {
            XCTAssertTrue(session.delegate is Http.NoRedirect)
        }
    }

    func testProviderProtectionIsUnavailableWithCustomDNS() {
        XCTAssertTrue(providerProtectionAvailable([]))
        XCTAssertFalse(providerProtectionAvailable(["1.1.1.1"]))
        XCTAssertTrue(providerProtectionAvailable(Filter(id: "quad9", direct: true)))
        XCTAssertFalse(providerProtectionAvailable(Filter(id: "quad9", routes: true)))
        XCTAssertTrue(providerProtectionAvailable(Filter(id: "nextdns", routes: true)))
    }

    func testClipboardMatchesOnlyTheSecretStillPresent() {
        XCTAssertTrue(clipboardContains("secret", secret: "secret"))
        XCTAssertFalse(clipboardContains("another", secret: "secret"))
        XCTAssertFalse(clipboardContains("secret ", secret: "secret"))
        XCTAssertFalse(clipboardContains(" ", secret: " "))
        XCTAssertFalse(clipboardContains(nil, secret: "secret"))
    }

    func testClosedSignInFormInvalidatesOnlyItsOwnResult() {
        var forms = SignInForms()
        let old = forms.version("nord")
        let other = forms.version("ivpn")
        forms.close("nord")
        XCTAssertNotEqual(forms.version("nord"), old)
        XCTAssertEqual(forms.version("ivpn"), other)
    }

    func testOnlyProvidersWithRealLoadSayFastest() {
        XCTAssertTrue(Surfshark().hasLoad); XCTAssertTrue(AirVpn().hasLoad)
        let providers: [any Provider] = [Proton(), ProtonFree(), ExpressVpn(), Windscribe()]
        XCTAssertTrue(providers.allSatisfy { !$0.hasLoad })
    }

    func testLiveLoadIsIngestedAndRanksCatalogue() async throws {
        let clusters = try Surfshark.parse(F.data("""
        [{"country":"Netherlands","location":"Amsterdam","connectionName":"nl-ams.prod.surfshark.com","pubKey":"\(F.key)","load":41},
        {"country":"Netherlands","location":"Amsterdam","connectionName":"nl-ams2.prod.surfshark.com","pubKey":"\(F.key)","load":6},
        {"country":"Netherlands","location":"Amsterdam","connectionName":"nl-ams3.prod.surfshark.com","pubKey":"\(F.key)"}]
        """))
        XCTAssertEqual(clusters.map(\.load), [41, 6, -1])
        var p = F.surfshark()
        p.catalogue = { clusters.map { var e = $0; e.ips = ["203.0.113.7"]; return e } }
        let l = try await p.link(Location(provider: p.id, country: "Netherlands"), account) { clusters }
        XCTAssertEqual(l.server.host, "nl-ams2.prod.surfshark.com"); XCTAssertEqual(l.server.load, 6)
        let air = try AirVpn.parse(F.data("""
        {"servers":[{"public_name":"A","country_name":"Austria","country_code":"at","ip_v4_in1":"1.2.3.4","health":"ok","currentload":70},
        {"public_name":"B","country_name":"Austria","country_code":"at","ip_v4_in1":"1.2.3.5","health":"ok","currentload":12}]}
        """), serverKey: F.key)
        XCTAssertEqual(air.map(\.load), [70, 12])
        let sv = try await F.air().link(Location(provider: "airvpn", country: "Austria"), account) { air }.server
        XCTAssertEqual(sv.name, "B"); XCTAssertEqual(sv.load, 12)
        XCTAssertEqual(try Catalog.server(Catalog.Entry(vpn: "wireguard", country: "Austria", ips: ["1.2.3.4"])).load, -1)
    }

    func testAirvpnPinFoundByNameBecauseHostsAreShared() async throws {
        let entries = try AirVpn.parse(F.data("""
        {"servers":[{"public_name":"A","country_name":"Austria","country_code":"at","ip_v4_in1":"1.2.3.4","health":"ok"},
        {"public_name":"B","country_name":"Austria","country_code":"at","ip_v4_in1":"1.2.3.5","health":"ok"}]}
        """), serverKey: F.key)
        let pinned = Server(name: "B", host: "at.vpn.airdns.org", ip: "9.9.9.9", publicKey: F.key, load: 0)
        var a = account; a.port = 1637
        let l = try F.wg(await F.air().link(Location(provider: "airvpn", pinned: pinned), a) { entries })
        XCTAssertEqual(l.peer.endpoint, "1.2.3.5:1637")
    }

    func testWindscribeStaticIpConfigsAreRefused() async throws {
        var p = F.windscribe()
        p.nodeHosts = { ["us-central-117.whiskergalaxy.com"] }
        _ = try await p.signIn(["config": F.wsConf()])
        for endpoint in ["203.0.113.5:443", "static-1.whiskergalaxy.com:443", "unlisted-1.whiskergalaxy.com:443"] {
            await F.rejects("This looks like a Static IP config, which is tied to one server. Import it under \"Your own servers\" instead.") {
                _ = try await p.signIn(["config": F.wsConf(endpoint: endpoint)])
            }
        }
        p.nodeHosts = { nil }
        _ = try await p.signIn(["config": F.wsConf(endpoint: "unlisted-1.whiskergalaxy.com:443")])
    }

    func testWindscribeGeneratorHostsIncludeDownLocationsAndIgnoreCase() async throws {
        let list = try Windscribe.parse(F.data(#"{"data":[{"status":0,"groups":[{"wg_endpoint":"DFW-86-WG.whiskergalaxy.com","nodes":[{"hostname":"NODE.example.com"}]}]}]}"#))
        let hosts = Windscribe.hosts(list)
        XCTAssertEqual(hosts, ["dfw-86-wg.whiskergalaxy.com", "node.example.com"])
        var p = F.windscribe()
        p.nodeHosts = { hosts }
        let config = "\u{feff}" + F.wsConf(endpoint: "DFW-86-WG.WHISKERGALAXY.COM:443").replacingOccurrences(of: "\n", with: "\r\n")
        _ = try await p.signIn(["config": config])
    }

    func testAirvpnRefusesAmneziaConfigs() async throws {
        let p = F.air()
        _ = try await p.signIn(["key": F.airConf])
        for line in ["Jc = 4", "Jmin = 8", "Jmax=80", "S1 = 15", "S2 = 18", "H1 = 123456", "H4 = 5", "I1 = <b 0x00>", "i5 = x"] {
            let conf = F.conf("10.164.20.6/32", dns: "10.128.0.1", endpoint: "at.vpn.airdns.org:1637", preshared: true, extra: line)
            await F.rejects("This config uses Amnezia obfuscation (Jc, S1, H1 and similar lines), which unbraid can't apply. Generate a standard WireGuard config in the AirVPN Config Generator.") {
                _ = try await p.signIn(["key": conf])
            }
        }
    }

    func testSurfsharkServersUsesCatalogueAndHonoursLimit() async throws {
        let body = Fixture.data("surfshark_clusters.json")
        let cat = try Surfshark.parse(body).map { var e = $0; e.ips = ["203.0.113.7"]; return e }
        let asked = Mutex(0)
        var p = F.surfshark()
        p.live = { body }
        p.catalogue = { asked.withLock { $0 += 1 }; return cat }
        let blob = try await p.signIn(["key": F.priv])
        let servers = try await p.servers(Location(provider: p.id, country: "Germany"), blob, limit: 2)
        XCTAssertEqual(servers.count, 2); XCTAssertEqual(asked.withLock { $0 }, 1)
    }

    func testSurfsharkAddressBookRefreshesAndKeepsLastCopy() async throws {
        let host = "nl-a.prod.surfshark.com"
        let calls = Mutex(0)
        let snapshot = Surfshark.Snapshot.memory()
        let book = Surfshark.AddressBook(snapshot: snapshot)
        let entries = [Catalog.Entry(hostname: host, ips: ["203.0.113.7"]),
                       Catalog.Entry(hostname: "nl-st001.prod.surfshark.com", ips: ["203.0.113.8"])]
        let fetch: @Sendable () async throws -> [Catalog.Entry] = { calls.withLock { $0 += 1 }; return entries }
        let first = await book.read(fetch)
        XCTAssertEqual(first[host], ["203.0.113.7"])
        XCTAssertNil(first["nl-st001.prod.surfshark.com"])
        _ = await book.read(fetch)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        let stored = try XCTUnwrap(snapshot.read())
        var old = try JSONDecoder().decode(Surfshark.AddressBook.Saved.self, from: stored)
        old.date = Date(timeIntervalSinceNow: -90000)
        let stale = Surfshark.AddressBook(snapshot: .memory(try JSONEncoder().encode(old)))
        let fallback = await stale.read { throw Fail("offline") }
        XCTAssertEqual(fallback[host], ["203.0.113.7"])
        let damaged = Surfshark.AddressBook(snapshot: .memory(F.data("broken")))
        let recovered = await damaged.read(fetch)
        XCTAssertEqual(recovered[host], ["203.0.113.7"])
        let missing = Surfshark.AddressBook(snapshot: .memory())
        let unavailable = await missing.read { throw Fail("offline") }
        XCTAssertTrue(unavailable.isEmpty)
    }

    func testSurfsharkPinnedKeyNeedsOwnEvidenceDuringOutage() async throws {
        let p = F.surfshark()
        let pinned = Server(name: "nl-ams", host: "nl-ams.prod.surfshark.com", ip: "203.0.113.7", publicKey: F.key, load: -1)
        await F.rejects("offline") {
            _ = try await p.link(Location(provider: p.id, pinned: pinned), account) { throw Fail("offline") }
        }
        var a = account; a.publicKey = F.key
        let l = try await p.link(Location(provider: p.id, pinned: pinned), a) { throw Fail("offline") }
        XCTAssertEqual(l.server, pinned)
    }

    func testAccountAndParserErrorsNeverExposeInput() {
        for parse: (String) throws -> Void in [
            { _ = try ExpressVpn.account($0) }, { _ = try Windscribe.account($0) },
            { _ = try Surfshark.parse(F.data($0)) }, { _ = try AirVpn.parse(F.data($0), serverKey: F.key) },
        ] {
            XCTAssertThrowsError(try parse("SECRET")) {
                XCTAssertTrue($0 is Fail); XCTAssertFalse($0.localizedDescription.contains("SECRET"))
            }
        }
    }

    func testMissingDefaultsRemainValidButExplicitNullIsRejected() throws {
        XCTAssertTrue(try Surfshark.parse(F.data("[{}]")).isEmpty)
        XCTAssertTrue(try AirVpn.parse(F.data("{}"), serverKey: F.key).isEmpty)
        XCTAssertTrue(try Windscribe.parse(F.data("{}")).data.isEmpty)
        let windscribe = """
        {"data":[{"name":"X","country_code":"nl","groups":[{"city":"A","wg_pubkey":"\(F.key)",
        "nodes":[{"hostname":"x.w.com","ip3":"1.2.3.4"}]}]}]}
        """
        let missing = try Windscribe.rows(Windscribe.parse(F.data(windscribe)))
        XCTAssertEqual(missing.count, 1); XCTAssertEqual(missing.first?.node.health, 0)
        let malformed: [(String, (String) throws -> Void)] = [
            (#"[{"country":null}]"#, { _ = try Surfshark.parse(F.data($0)) }),
            (#"[{"connectionName":null}]"#, { _ = try Surfshark.parse(F.data($0)) }),
            (#"{"servers":null}"#, { _ = try AirVpn.parse(F.data($0), serverKey: F.key) }),
            (#"{"servers":[{"health":null}]}"#, { _ = try AirVpn.parse(F.data($0), serverKey: F.key) }),
            (#"{"data":null}"#, { _ = try Windscribe.parse(F.data($0)) }),
            (windscribe.replacingOccurrences(of: #""country_code":"nl""#, with: #""country_code":"nl","status":null"#),
             { _ = try Windscribe.parse(F.data($0)) }),
            (windscribe.replacingOccurrences(of: #""ip3":"1.2.3.4""#, with: #""ip3":"1.2.3.4","health":null"#),
             { _ = try Windscribe.parse(F.data($0)) }),
        ]
        for (text, parse) in malformed {
            XCTAssertThrowsError(try parse(text)) { XCTAssertTrue($0 is Fail) }
        }
        // load is nullable in both provider APIs.
        XCTAssertTrue(try Surfshark.parse(F.data(#"[{"load":null}]"#)).isEmpty)
        XCTAssertTrue(try AirVpn.parse(F.data(#"{"servers":[{"currentload":null}]}"#), serverKey: F.key).isEmpty)
        let base = #"{"privateKey":"key","address":["10.0.0.2/32"],"presharedKey":"psk"}"#
        let a = try Windscribe.account(base)
        XCTAssertEqual(a.dns, []); XCTAssertEqual(a.port, 1194); XCTAssertEqual(a.mtu, 1420)
        for field in ["dns", "port", "mtu"] {
            let null = String(base.dropLast()) + ",\"\(field)\":null}"
            XCTAssertThrowsError(try Windscribe.account(null)) { XCTAssertEqual($0.localizedDescription, "Unexpected reply from Windscribe") }
        }
    }

    /// Only a request carrying credentials learns from a 401 that they were refused; a public list's 401 is an error
    /// status, so cached tunnels and pins still stand in rather than a "sign in again".
    func testUnauthorizedMeansRefusedCredentialsOnlyWhenSomeWereSent() {
        XCTAssertTrue((try? Http.check(200, credentials: true)) != nil)
        XCTAssertThrowsError(try Http.check(401, credentials: true)) { XCTAssertTrue($0 is AuthError) }
        XCTAssertThrowsError(try Http.check(401, credentials: false)) { XCTAssertEqual(($0 as? Http.Status)?.code, 401) }
        XCTAssertThrowsError(try Http.check(403, credentials: true)) { XCTAssertEqual(($0 as? Http.Status)?.code, 403) }
    }

    /// A provider that answered with a status isn't a connection problem; a rate limit says to wait.
    func testSignInFailuresSayWhatHappened() {
        XCTAssertEqual(signInFailure(Http.Status(code: 429), "PIA"), "PIA is limiting sign-in attempts. Wait a few minutes, then try again.")
        XCTAssertEqual(signInFailure(Http.Status(code: 403), "PIA"), "PIA answered with an error (HTTP 403). Try again later.")
        XCTAssertEqual(signInFailure(URLError(.notConnectedToInternet), "PIA"), "Couldn't reach PIA. Check the connection.")
        XCTAssertEqual(signInFailure(Fail("Nope"), "PIA"), "Nope")
        XCTAssertEqual(signInFailure(AuthError("Refused"), "PIA"), "Refused")
    }
}
