import XCTest

/// Server addresses from lookups, catalogues and pins: only strict public IPv4 reaches an endpoint.
final class ProviderAddressTests: XCTestCase {
    private typealias F = ProviderFixtures
    /// What the system resolver answers while the engine runs: its fake-IP range.
    private static let fake = "198.18.0.5"
    private var fake: String { Self.fake }

    private func nl(_ p: Surfshark) -> Location { Location(provider: p.id, country: "Netherlands") }

    func testStrictDottedQuad() {
        for s in ["185.65.134.1", "8.8.8.8", "198.20.0.1", "198.17.255.255", "1.0.0.1"] { XCTAssertTrue(Catalog.Entry.publicIPv4(s), s) }
        for s in ["1.2.3.4.", "1.2.3..4", ".1.2.3.4", "01.2.3.4", "1.2.3.04", "+1.2.3.4", "1.2.3.4 ", " 1.2.3.4", "1.2.3.-4",
                  "1.2.3.256", "1.2.3.4.5", "1.2.3", "", "١.2.3.4", "1.2.3.0x4", "0.0.0.0", "198.18.0.1", "198.19.255.255",
                  "100.64.0.1", "169.254.1.1", "172.16.0.1", "172.31.255.255", "224.0.0.1", "255.255.255.255", "fd00::1"] {
            XCTAssertFalse(Catalog.Entry.publicIPv4(s), s)
        }
        XCTAssertEqual(Catalog.Entry.octets("10.0.255.9"), [10, 0, 255, 9])
        XCTAssertNil(Catalog.Entry.octets("10.0.255"))
    }

    func testCatalogueServerNeedsPublicAddress() throws {
        XCTAssertThrowsError(try Catalog.server(Catalog.Entry(vpn: "wireguard", country: "Austria", hostname: "a.example", ips: [])))
        XCTAssertThrowsError(try Catalog.server(Catalog.Entry(vpn: "wireguard", country: "Austria", hostname: "a.example", ips: [fake, "10.0.0.1"])))
        XCTAssertEqual(try Catalog.server(Catalog.Entry(vpn: "wireguard", country: "Austria", hostname: "a.example", ips: [fake, "203.0.113.4"])).ip,
                       "203.0.113.4")
    }

    func testSurfsharkUsesOnlyMatchingCatalogueHostAndProviderKey() async throws {
        let entries = try Surfshark.parse(Fixture.data("surfshark_clusters.json"))
        let cat = try F.catalog("surfshark")
        var p = F.surfshark()
        p.catalogue = { cat }
        let a = try await F.signed(p)
        let l = try F.wg(await p.link(nl(p), a) { entries })
        XCTAssertTrue(cat.contains { $0.hostname == l.server.host && $0.ips.contains(l.server.ip) })
        XCTAssertEqual(l.peer.publicKey, entries.first { $0.hostname == l.server.host }?.wgpubkey)
        XCTAssertTrue(Catalog.Entry.publicIPv4(l.server.ip))
    }

    func testSurfsharkRejectsPrivateAndMissingCatalogueAddresses() async throws {
        let entries = try Surfshark.parse(Fixture.data("surfshark_clusters.json"))
        let cat = try F.catalog("surfshark").map { var e = $0; e.ips = [Self.fake, "10.0.0.7"]; return e }
        var p = F.surfshark()
        p.catalogue = { cat }
        let a = try await F.signed(p)
        await F.rejects("No Surfshark server for Netherlands") { _ = try await p.link(nl(p), a) { entries } }
    }

    func testPinnedSurfsharkOnlyUsesSameHostsAddress() async throws {
        let entries = try Surfshark.parse(Fixture.data("surfshark_clusters.json"))
        let cat = try F.catalog("surfshark")
        let host = try XCTUnwrap(entries.first { e in listed(e, in: cat) && e.place == "Netherlands" }).hostname
        var p = F.surfshark()
        p.catalogue = { cat }
        let a = try await F.signed(p)
        let pin = Server(name: String(host.split(separator: ".")[0]), host: host, ip: "203.0.113.1", publicKey: "", load: 0)
        let l = try F.wg(await p.link(Location(provider: p.id, pinned: pin), a) { entries })
        XCTAssertEqual(l.server.host, host)
        XCTAssertTrue(cat.contains { $0.hostname == host && $0.ips.contains(l.server.ip) })
        var offline = F.surfshark()
        offline.catalogue = { throw Fail("offline") }
        let kept = try F.wg(await offline.link(Location(provider: p.id, pinned: pin), a) { entries })
        XCTAssertEqual(kept.peer.endpoint, "203.0.113.1:51820")
        for ip in ["", fake, "10.0.0.2"] {
            var bad = pin; bad.ip = ip
            await F.rejects("\(pin.name) can't be reached right now") {
                _ = try await offline.link(Location(provider: p.id, pinned: bad), a) { entries }
            }
        }
    }

    func testPinnedServerOfflineNeedsPublicAddress() async throws {
        let body = Fixture.data("surfshark_clusters.json")
        let entries = try Surfshark.parse(body)
        var p = F.surfshark()
        p.snapshot = .memory(body)
        let a = try await F.signed(p)
        let good = Server(name: "nl-ams", host: entries[0].hostname, ip: "203.0.113.40", publicKey: try XCTUnwrap(entries[0].wgpubkey), load: 0)
        let l = try F.wg(await p.link(Location(provider: p.id, pinned: good), a) { throw Fail("offline") })
        XCTAssertEqual(l.peer.endpoint, "203.0.113.40:51820")
        for ip in ["", fake, "1.2.3.4."] {
            var bad = good; bad.ip = ip
            await F.rejects("offline") { _ = try await p.link(Location(provider: p.id, pinned: bad), a) { throw Fail("offline") } }
        }
    }

    func testExpressVpnPinnedAddressIsChecked() throws {
        let a = ExpressVpn.Account(username: "user", password: "pass")
        let good = Server(name: "netherlands", host: "netherlands-ca-version-2.expressnetw.com", ip: "203.0.113.50", publicKey: "", load: 0)
        XCTAssertNoThrow(try ExpressVpn.link(nil, Location(provider: "expressvpn", pinned: good), a))
        for ip in ["", fake, "10.0.0.1", "1.2.3.4\nremote 6.6.6.6"] {
            var bad = good; bad.ip = ip
            XCTAssertThrowsError(try ExpressVpn.link(nil, Location(provider: "expressvpn", pinned: bad), a), ip)
        }
    }

    func testSavedTunnelsWithoutUsableAddressAreNotTrusted() async throws {
        let body = Fixture.data("surfshark_clusters.json")
        let entries = try Surfshark.parse(body)
        var p = F.surfshark()
        p.snapshot = .memory(body)
        p.catalogue = { entries.map { var e = $0; e.ips = ["203.0.113.7"]; return e } }
        let blob = try await p.signIn(["key": F.priv])
        let good = try F.wg(await p.link(nl(p), p.keyAccount(blob)) { entries })
        XCTAssertTrue(p.trusts(.wg(good.server, good.peer), blob))
        // What an affected build saved: no address at all, the engine's fake one, or a peer that disagrees with its server.
        for (ip, endpoint) in [("", ":51820"), (fake, "\(fake):51820"), ("203.0.113.7", ":51820"), ("203.0.113.7", "203.0.113.8:51820")] {
            var sv = good.server, peer = good.peer
            sv.ip = ip; peer.endpoint = endpoint
            XCTAssertFalse(p.trusts(.wg(sv, peer), blob), "\(ip) \(endpoint)")
        }
        let express = ExpressVpn()
        let profile = try ExpressVpn.link(nil, Location(provider: "expressvpn", pinned: Server(name: "x", host: "x", ip: "203.0.113.50", publicKey: "", load: 0)),
                                          ExpressVpn.Account(username: "u", password: "p"))
        XCTAssertTrue(express.trusts(profile, ""))
        guard case .ovpn(var sv, let o) = profile else { return XCTFail() }
        sv.ip = ""
        XCTAssertFalse(express.trusts(.ovpn(sv, o), ""))
    }

    func testSurfsharkMergesDuplicateCatalogueHosts() async throws {
        let host = "nl-dup.prod.surfshark.com"
        let body = F.data(#"[{"country":"Netherlands","connectionName":"\#(host)","pubKey":"\#(F.key)"}]"#)
        let cat = [Catalog.Entry(vpn: "wireguard", country: "Netherlands", hostname: host, ips: ["203.0.113.61"]),
                   Catalog.Entry(vpn: "wireguard", country: "Netherlands", hostname: host, ips: [fake])]
        var p = F.surfshark()
        p.catalogue = { cat }
        let l = try F.wg(await p.link(nl(p), F.signed(p)) { try Surfshark.parse(body) })
        XCTAssertEqual(l.peer.endpoint, "203.0.113.61:51820")
    }

    private func listed(_ e: Catalog.Entry, in cat: [Catalog.Entry]) -> Bool { Surfshark.fallback(cat).contains { $0.hostname == e.hostname } }
}
