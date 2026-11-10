import XCTest

/// Provider-owned key provenance, including hostile catalogue substitutions.
final class KeySourcesTests: XCTestCase {
    private typealias F = ProviderFixtures

    func testSurfsharkTakesOnlyAddressesFromCatalogue() async throws {
        let live = try Surfshark.parse(Fixture.data("surfshark_clusters.json"))
        var p = F.surfshark()
        p.catalogue = { [Catalog.Entry(vpn: "wireguard", country: live[0].country, hostname: live[0].hostname, wgpubkey: F.evil, ips: ["198.51.100.66"])] }
        let a = try await F.signed(p)
        let l = try F.wg(await p.link(Location(provider: p.id, country: live[0].place), a) { live })
        XCTAssertEqual(l.peer.endpoint, "198.51.100.66:51820")
        XCTAssertEqual(l.peer.publicKey, live[0].wgpubkey)
    }

    func testSurfsharkIgnoresCatalogueHostsItDoesNotList() async throws {
        let live = try Surfshark.parse(Fixture.data("surfshark_clusters.json"))
        var p = F.surfshark()
        p.catalogue = { [Catalog.Entry(vpn: "wireguard", country: live[0].country, hostname: "nl-evil.prod.surfshark.com", wgpubkey: F.evil, ips: ["198.51.100.66"])] }
        let a = try await F.signed(p)
        await F.rejects("No Surfshark server for \(live[0].place)") {
            _ = try await p.link(Location(provider: p.id, country: live[0].place), a) { live }
        }
    }

    func testSurfsharkKeepsItsLastListWhenApiIsDown() async throws {
        let body = Fixture.data("surfshark_clusters.json")
        var p = F.surfshark()
        p.live = { body }
        let account = try await p.signIn(["key": F.priv])
        let fresh = try await p.countries(account)
        XCTAssertEqual(p.snapshot.read(), body)
        p.live = { throw Fail("down") }
        p.catalogue = { XCTFail("Catalogue must not supply keys"); return [] }
        let cached = try await p.countries(account)
        XCTAssertEqual(cached, fresh)
    }

    func testSurfsharkWithoutOwnListFails() async throws {
        var p = F.surfshark()
        p.catalogue = { XCTFail("Catalogue must not supply keys"); return [] }
        let account = try await p.signIn(["key": F.priv])
        await F.rejects("Surfshark's server list can't be reached right now") { _ = try await p.countries(account) }
    }

    func testSurfsharkKeepsOldCopyWhenApiHasNothingUsable() async throws {
        let body = Fixture.data("surfshark_clusters.json")
        var p = F.surfshark()
        p.snapshot = .memory(body)
        p.live = { F.data("[]") }
        let countries = try await p.countries(p.signIn(["key": F.priv]))
        XCTAssertFalse(countries.isEmpty)
        XCTAssertEqual(p.snapshot.read(), body)
        // From the saved copy: shown, not cached as today's.
        let fresh = try await p.freshCountries(p.signIn(["key": F.priv]))
        XCTAssertFalse(fresh.live)
        p.live = { body }
        let live = try await p.freshCountries(p.signIn(["key": F.priv]))
        XCTAssertTrue(live.live)
    }

    func testSurfsharkKeepsOldCopyWhenLiveReplyHasExplicitNull() async throws {
        let body = Fixture.data("surfshark_clusters.json")
        var p = F.surfshark()
        p.snapshot = .memory(body)
        p.live = { F.data(#"[{"country":null}]"#) }
        let account = try await p.signIn(["key": F.priv])
        let countries = try await p.countries(account)
        XCTAssertFalse(countries.isEmpty)
        XCTAssertEqual(p.snapshot.read(), body)
    }

    func testAirvpnFallbackUsesAccountKeyNotCatalogues() async throws {
        let cat = try F.catalog("airvpn").map { var e = $0; e.wgpubkey = F.evil; return e }
        var p = F.air()
        p.catalogue = { cat }
        let blob = try await p.signIn(["key": F.airConf])
        let l = try F.wg(await p.connect(Location(provider: p.id, country: cat[0].place), blob))
        XCTAssertEqual(l.peer.publicKey, F.key)
        XCTAssertEqual(l.peer.presharedKey, F.psk)
        XCTAssertTrue(cat.flatMap(\.ips).contains(l.server.ip))
    }

    func testSurfsharkDropsMalformedKeysBeforeKeepingList() throws {
        let body = Fixture.text("surfshark_clusters.json")
        let first = try XCTUnwrap(Surfshark.parse(F.data(body)).first)
        for key in ["not-a-key", String(repeating: "A", count: 42) + "B="] {
            let bad = body.replacingOccurrences(of: first.wgpubkey!, with: key)
            XCTAssertFalse(try Surfshark.parse(F.data(bad)).contains { $0.hostname == first.hostname })
        }
    }

    func testSavedSurfsharkTunnelsNeedTrustedKey() async throws {
        let body = Fixture.data("surfshark_clusters.json")
        let live = try Surfshark.parse(body)
        var p = F.surfshark()
        p.catalogue = { live.map { var e = $0; e.ips = ["203.0.113.7"]; return e } }
        let blob = try await p.signIn(["key": F.priv])
        let good = try await p.link(Location(provider: p.id, country: live[0].place), p.keyAccount(blob)) { live }
        XCTAssertFalse(p.trusts(good, blob))
        p.snapshot = .memory(body)
        XCTAssertTrue(p.trusts(good, blob))
        var l = try F.wg(good)
        l.server.publicKey = F.evil; l.peer.publicKey = F.evil
        XCTAssertFalse(p.trusts(.wg(l.server, l.peer), blob))
    }

    func testAirvpnSavedAndPinnedTunnelsUseAccountKey() async throws {
        let p = F.air()
        let blob = try await p.signIn(["key": F.airConf])
        let a = try p.keyAccount(blob)
        let entries = try AirVpn.parse(Fixture.data("airvpn_status.json"), serverKey: F.key)
        let good = try await p.link(Location(provider: p.id, country: entries[0].place), a) { entries }
        XCTAssertTrue(p.trusts(good, blob))
        var l = try F.wg(good)
        l.server.publicKey = F.evil; l.peer.publicKey = F.evil
        XCTAssertFalse(p.trusts(.wg(l.server, l.peer), blob))
        let pinned = try F.wg(await p.link(Location(provider: p.id, pinned: l.server), a) { entries })
        XCTAssertEqual(pinned.peer.publicKey, F.key)
    }

    func testSurfsharkTrustsDownloadedConfKey() async throws {
        let entries = try Surfshark.parse(Fixture.data("surfshark_clusters.json"))
        var p = F.surfshark()
        p.catalogue = { entries.map { var e = $0; e.ips = ["203.0.113.7"]; return e } }
        let conf = F.conf("10.14.0.2/16", endpoint: "\(entries[0].hostname):51820", publicKey: entries[0].wgpubkey!)
        let blob = try await p.signIn(["key": conf])
        let link = try await p.link(Location(provider: p.id, country: entries[0].place), p.keyAccount(blob)) { entries }
        XCTAssertTrue(p.trusts(link, blob))
    }

    func testSnapshotSurvivesFailedSaveInMemory() {
        let snapshot = Surfshark.Snapshot(load: { nil }, save: { _ in throw Fail("disk full") })
        snapshot.write(F.data("list"))
        XCTAssertEqual(snapshot.read(), F.data("list"))
    }
}
