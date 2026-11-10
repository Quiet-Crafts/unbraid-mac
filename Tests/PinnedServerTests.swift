import XCTest

/// Pinned servers are looked up in a fresh list where the provider has one: moved or re-keyed servers are
/// followed, gone ones say so (and no cached tunnel stands in), and the saved values are used only when the list can't
/// be read.
final class PinnedServerTests: XCTestCase {
    private typealias F = ProviderFixtures
    private let key = F.key

    private func gone(_ f: () throws -> Any) -> String? {
        do { _ = try f(); return nil } catch let e as Catalog.Gone { return e.errorDescription } catch { return "not Gone: \(error)" }
    }

    func testNord() throws {
        let pin = Server(name: "Germany #1187", host: "de1187.nordvpn.com", ip: "203.0.113.10", publicKey: key, load: 1)
        var moved = pin; moved.host = "DE1187.nordvpn.com"; moved.ip = "203.0.113.11"; moved.publicKey = F.key2
        XCTAssertEqual(try Nord.current([moved], pin), moved)
        XCTAssertEqual(try Nord.current(nil, pin), pin)
        XCTAssertEqual(gone { try Nord.current([], pin) }, "NordVPN no longer lists Germany #1187. Pick another server.")
        var other = moved; other.host = "de1188.nordvpn.com"
        XCTAssertNotNil(gone { try Nord.current([other], pin) })
        var renamed = other; renamed.name = "GERMANY #1187"
        XCTAssertNotNil(gone { try Nord.current([renamed], pin) })
        // The host wins over a row with the name on another host.
        XCTAssertEqual(try Nord.current([other, moved], pin), moved)
        // Nord ignored the name filter (other servers only): no evidence, the saved values stand.
        var unrelated = other; unrelated.name = "France #12"; unrelated.host = "fr12.nordvpn.com"
        XCTAssertEqual(try Nord.current([unrelated], pin), pin)
    }

    /// Rows that are all unusable (no key, no public address) aren't "no server by that name".
    func testNordNamedLookupTellsUnusableRowsFromNone() throws {
        let row = #"{"name":"Germany #1187","hostname":"de1187.nordvpn.com","station":"203.0.113.10","load":3,"technologies":[]}"#
        XCTAssertThrowsError(try NordApi.parseNamed(Data("[\(row)]".utf8), needKey: true))
        XCTAssertEqual(try NordApi.parseNamed(Data("[\(row)]".utf8), needKey: false).map(\.host), ["de1187.nordvpn.com"])
        XCTAssertEqual(try NordApi.parseNamed(Data("[]".utf8), needKey: true), [])
    }

    /// Nord rows without a public address (an empty `station`) are skipped, not dialled.
    func testNordSkipsServersWithoutAnAddress() throws {
        func row(_ station: String) -> String {
            #"{"name":"X","hostname":"x.nordvpn.com","station":"\#(station)","load":3,"technologies":[{"identifier":"wireguard_udp","metadata":[{"name":"public_key","value":"\#(key)"}]}]}"#
        }
        let list = try NordApi.parseServers(Data("[\(row("")),\(row("10.0.0.1")),\(row("203.0.113.9"))]".utf8))
        XCTAssertEqual(list.map(\.ip), ["203.0.113.9"])
    }

    func testNordPinnedConnectFollowsTheLookup() async throws {
        let pin = Server(name: "Germany #1187", host: "de1187.nordvpn.com", ip: "203.0.113.10", publicKey: key, load: 1)
        var m = pin; m.ip = "203.0.113.11"
        let moved = m
        var p = Nord()
        p.lookup = { name, tech in XCTAssertEqual(name, "Germany #1187"); XCTAssertEqual(tech, "wireguard_udp"); return [moved] }
        let blob = JSON.encode(Nord.Account(token: "t", key: F.priv))
        let followed = try await p.connect(Location(provider: "nord", pinned: pin), blob)
        XCTAssertEqual(try F.wg(followed).peer.endpoint, "203.0.113.11:51820")
        p.lookup = { _, _ in throw URLError(.notConnectedToInternet) }
        let saved = try await p.connect(Location(provider: "nord", pinned: pin), blob)
        XCTAssertEqual(try F.wg(saved).peer.endpoint, "203.0.113.10:51820")
        var lan = pin; lan.ip = "192.168.1.5"
        await F.rejects { _ = try await p.connect(Location(provider: "nord", pinned: lan), blob) }
        p.lookup = { _, _ in throw AuthError("refused") }
        await F.rejects("refused") { _ = try await p.connect(Location(provider: "nord", pinned: pin), blob) }
        p.lookup = { _, _ in [] }
        await F.rejects("NordVPN no longer lists Germany #1187. Pick another server.") { _ = try await p.connect(Location(provider: "nord", pinned: pin), blob) }
        // The name filter ignored: the saved endpoint and key.
        var unrelated = moved; unrelated.name = "France #12"; unrelated.host = "fr12.nordvpn.com"; unrelated.publicKey = F.key2
        let other = unrelated
        p.lookup = { _, _ in [other] }
        let kept = try F.wg(try await p.connect(Location(provider: "nord", pinned: pin), blob))
        XCTAssertEqual(kept.peer.endpoint, "203.0.113.10:51820")
        XCTAssertEqual(kept.peer.publicKey, key)
    }

    func testIvpn() throws {
        let list = try Ivpn.parse(Fixture.data("ivpn_servers.json"))
        let acct = Ivpn.Account(accountId: "i-ABCD-EFGH-IJKL", sessionToken: "s", privateKey: F.priv, ipAddress: "172.16.34.56")
        let (g, h) = try XCTUnwrap(list.match(Location(provider: "ivpn", countryCode: "SE")).first)
        // Pinned with old values (another address and key, an old place): the list's current ones win.
        let pin = Server(name: "My SE", host: h.hostname.uppercased(), ip: "203.0.113.20", publicKey: key, load: 0, city: "Elsewhere")
        let l = try F.wg(Ivpn.link(list, Location(provider: "ivpn", countryCode: "US", pinned: pin), acct))
        XCTAssertEqual(l.peer.endpoint, "\(h.host):2049"); XCTAssertEqual(l.peer.publicKey, h.publicKey)
        XCTAssertEqual(l.peer.dns, [String(h.localIp.prefix { $0 != "/" })]); XCTAssertEqual(l.server.city, g.city); XCTAssertEqual(l.server.name, "My SE")
        // Gone, even if another host now has its address.
        var gonePin = pin; gonePin.host = "se99.wg.ivpn.net"; gonePin.ip = h.host
        XCTAssertEqual(gone { try Ivpn.link(list, Location(provider: "ivpn", pinned: gonePin), acct) }, "IVPN no longer lists My SE. Pick another server.")
        // No list, or an empty one: the saved values, if they are a public address.
        XCTAssertEqual(try F.wg(Ivpn.link(nil, Location(provider: "ivpn", pinned: pin), acct)).peer.endpoint, "203.0.113.20:2049")
        XCTAssertEqual(try F.wg(Ivpn.link(Ivpn.ServerList(), Location(provider: "ivpn", pinned: pin), acct)).peer.endpoint, "203.0.113.20:2049")
        var lan = pin; lan.ip = "10.1.2.3"
        XCTAssertThrowsError(try Ivpn.link(nil, Location(provider: "ivpn", pinned: lan), acct))
    }

    func testIvpnPinnedConnectReadsTheList() async throws {
        let list = try Ivpn.parse(Fixture.data("ivpn_servers.json"))
        let (_, h) = try XCTUnwrap(list.match(Location(provider: "ivpn", countryCode: "SE")).first)
        let pin = Server(name: "x", host: h.hostname, ip: "203.0.113.20", publicKey: key, load: 0)
        let blob = JSON.encode(Ivpn.Account(accountId: "i-ABCD-EFGH-IJKL", sessionToken: "s", privateKey: F.priv, ipAddress: "172.16.34.56"))
        var p = Ivpn()
        p.catalogue = { list }
        let followed = try await p.connect(Location(provider: "ivpn", pinned: pin), blob)
        XCTAssertEqual(try F.wg(followed).peer.endpoint, "\(h.host):2049")
        p.catalogue = { throw Http.Status(code: 503) }
        let saved = try await p.connect(Location(provider: "ivpn", pinned: pin), blob)
        XCTAssertEqual(try F.wg(saved).peer.endpoint, "203.0.113.20:2049")
    }

    func testWindscribe() async throws {
        let rows = Windscribe.rows(try Windscribe.parse(Fixture.data("windscribe_serverlist.json")))
        let a = try await F.ws()
        let r = try XCTUnwrap(rows.first)
        let pin = Server(name: "old", host: r.node.hostname.uppercased(), ip: "203.0.113.30", publicKey: F.key2, load: 0)
        let l = try F.wg(Windscribe.link(rows, Location(provider: "windscribe", pinned: pin), a))
        XCTAssertEqual(l.server.ip, r.node.ip3); XCTAssertEqual(l.peer.publicKey, r.publicKey)
        XCTAssertEqual(l.peer.presharedKey, a.presharedKey); XCTAssertEqual(l.peer.endpoint, "\(r.node.ip3):\(a.port)")
        var gonePin = pin; gonePin.host = "zz-999.whiskergalaxy.com"
        XCTAssertEqual(gone { try Windscribe.link(rows, Location(provider: "windscribe", pinned: gonePin), a) }, "Windscribe doesn't offer old right now. Pick another server.")
        XCTAssertEqual(try F.wg(Windscribe.link(nil, Location(provider: "windscribe", pinned: pin), a)).server, pin)
        XCTAssertEqual(try F.wg(Windscribe.link([], Location(provider: "windscribe", pinned: pin), a)).server, pin)
    }

    func testExpressVpn() throws {
        let a = ExpressVpn.Account(username: "u", password: "p")
        let live = try F.catalog("expressvpn")
        let e = try XCTUnwrap(live.first { !$0.ips.isEmpty })
        let pin = Server(name: "pinned", host: e.hostname, ip: e.ips[0], publicKey: "", load: 0)
        XCTAssertEqual(try ExpressVpn.link(live, Location(provider: "expressvpn", pinned: pin), a).server.ip, e.ips[0])
        // Moved: a listed address instead.
        var moved = pin; moved.ip = "203.0.113.40"
        let m = try ExpressVpn.link(live, Location(provider: "expressvpn", pinned: moved), a).server
        XCTAssertTrue(live.filter { $0.hostname == e.hostname }.flatMap(\.ips).contains(m.ip)); XCTAssertEqual(m.name, "pinned")
        // Gone from a live list; kept when only the bundled snapshot (older than the pin) answered.
        var gonePin = moved; gonePin.host = "nowhere-ca-version-2.expressnetw.com"
        XCTAssertEqual(gone { try ExpressVpn.link(live, Location(provider: "expressvpn", pinned: gonePin), a) }, "ExpressVPN no longer lists pinned. Pick another server.")
        let bundled = live.map { var x = $0; x.bundled = true; return x }
        XCTAssertEqual(try ExpressVpn.link(bundled, Location(provider: "expressvpn", pinned: gonePin), a).server.ip, "203.0.113.40")
        XCTAssertEqual(try ExpressVpn.link(bundled, Location(provider: "expressvpn", pinned: moved), a).server.ip, "203.0.113.40")
    }

    func testPia() throws {
        let regions = try Pia.parseRegions(Fixture.data("pia_servers_v6.txt"))
        let wg = try XCTUnwrap(regions.first { $0.id == "us_denver" }?.servers.wg)
        let pin = Server(name: "denver", host: wg[0].cn, ip: wg[0].ip, publicKey: "", load: 0)
        XCTAssertEqual(try Pia.target(regions, pin), wg[0])
        var moved = pin; moved.ip = "203.0.113.50"
        XCTAssertEqual(try Pia.target(regions, moved).ip, wg[0].ip)
        XCTAssertEqual(try Pia.target(nil, moved).ip, "203.0.113.50")
        var gonePin = pin; gonePin.host = "nowhere999"
        XCTAssertEqual(gone { try Pia.target(regions, gonePin) }, "PIA no longer lists denver. Pick another server.")
        var lan = pin; lan.ip = "10.0.0.1"
        XCTAssertThrowsError(try Pia.target(nil, lan))
    }

    func testMullvadGoneIsNotAnOutage() throws {
        let list = try Mullvad.parse(Fixture.data("mullvad_relays.json"))
        let acct = Mullvad.Account(account: "1234567890123456", privateKey: F.priv, ipv4Address: "10.66.12.34/32", deviceId: "d")
        let pin = Server(name: "gone", host: "xx-zzz-wg-999", ip: "203.0.113.60", publicKey: key, load: 0)
        XCTAssertEqual(gone { try Mullvad.link(list, Location(provider: "mullvad", pinned: pin), acct) }, "Mullvad no longer lists gone. Pick another server.")
        var lan = pin; lan.ip = "10.9.9.9"
        XCTAssertThrowsError(try Mullvad.link(nil, Location(provider: "mullvad", pinned: lan), acct))
    }

    /// A pinned server a list just said is gone: no cached tunnel stands in, and the message says so.
    func testGoneSkipsTheCachedTunnel() async throws {
        struct GoneProvider: Provider {
            let id = "g", name = "G", fields: [Field] = [], help = ""
            func signIn(_ input: [String: String]) async throws -> String { "" }
            func countries(_ account: String) async throws -> [Country] { [] }
            func connect(_ loc: Location, _ account: String) async throws -> Link { throw Catalog.Gone(provider: "G", server: "S") }
        }
        let pin = Server(name: "S", host: "s", ip: "203.0.113.70", publicKey: key, load: 0)
        let r = Route(id: "r", loc: Location(provider: "g", pinned: pin))
        let cached = Link.wg(pin, WgPeer(name: "S", privateKey: F.priv, address: ["10.0.0.2/32"], publicKey: key, endpoint: "203.0.113.70:51820", allowedIps: ["0.0.0.0/0"]))
        let result = try await LinkPicker.pick(Setup(routes: [r], defaultRoute: "r"), keep: [:], applied: nil, appliedAccounts: [:], accounts: ["g": "a"],
                                               last: [LinkPicker.cacheKey(r, account: "a"): cached]) { _ in GoneProvider() }
        XCTAssertNil(result.links["r"])
        XCTAssertEqual(result.blocked["r"], .noLongerOffered("S"))
    }
}
