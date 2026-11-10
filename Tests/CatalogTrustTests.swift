import XCTest
import CryptoKit

/// Proton's keys come only from the snapshot bundled with the app; the live gluetun list may move or drop servers but
/// never changes a key or adds a host. Proton and ExpressVPN work from the snapshot when GitHub is out.
final class CatalogTrustTests: XCTestCase {
    private typealias F = ProviderFixtures
    private let account = KeyAccount(privateKey: F.priv, address: ["10.2.0.2/32"], dns: ["10.2.0.1"], port: 51820, mtu: 1420)

    private func germany() throws -> Catalog.Entry {
        try XCTUnwrap(F.catalog("protonvpn").first { $0.serverName == "DE#187" })
    }
    private func pin(_ e: Catalog.Entry) throws -> Server { try Catalog.server(e) }
    private func de(_ p: some ProtonPlan) -> Location { Location(provider: p.id, country: "Germany") }

    // MARK: The bundle

    func testBundledListsMatchTheCompiledPin() throws {
        let proton = try Catalog.bundled("protonvpn", vpn: "wireguard")
        XCTAssertGreaterThan(proton.entries.count, 900)
        XCTAssertEqual(proton.keys.count, 782)
        XCTAssertTrue(proton.entries.allSatisfy { Catalog.identity($0.hostname).flatMap { proton.keys[$0] } == $0.wgpubkey })
        let express = try Catalog.bundled("expressvpn", vpn: "openvpn")
        XCTAssertTrue(express.entries.contains(where: \.udp))
        XCTAssertTrue(express.keys.isEmpty)
        let dir = try XCTUnwrap(Catalog.folder)
        let manifest = try JSONDecoder().decode(Catalog.Manifest.self, from: Data(contentsOf: dir.appending(path: "manifest.json")))
        XCTAssertEqual(manifest, Catalog.pin)
        XCTAssertTrue(Catalog.pin.commit.wholeMatch(of: /[0-9a-f]{40}/) != nil)
    }

    func testDamagedBundleIsRefused() throws {
        let original = try XCTUnwrap(Catalog.folder)
        let dir = FileManager.default.temporaryDirectory.appending(path: "unbraid-catalog-\(UUID())")
        try FileManager.default.copyItem(at: original, to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrow(try Catalog.bundled("protonvpn", vpn: "wireguard", dir: dir))
        // One changed byte.
        let file = dir.appending(path: "protonvpn.json")
        var bytes = try Data(contentsOf: file)
        let good = bytes
        let i = try XCTUnwrap(bytes.firstIndex(of: UInt8(ascii: "=")))
        bytes[i] = UInt8(ascii: "A")
        try bytes.write(to: file)
        XCTAssertThrowsError(try Catalog.bundled("protonvpn", vpn: "wireguard", dir: dir)) { XCTAssertTrue($0 is Catalog.Damaged) }
        try good.write(to: file)
        // A manifest that names another commit.
        var other = Catalog.pin
        other.commit = String(repeating: "0", count: 40)
        XCTAssertThrowsError(try Catalog.bundled("protonvpn", vpn: "wireguard", dir: dir, pin: other))
        // Missing files, and no folder at all.
        XCTAssertThrowsError(try Catalog.bundled("nordvpn", vpn: "wireguard", dir: dir))
        try FileManager.default.removeItem(at: dir.appending(path: "manifest.json"))
        XCTAssertThrowsError(try Catalog.bundled("protonvpn", vpn: "wireguard", dir: dir))
        XCTAssertThrowsError(try Catalog.bundled("protonvpn", vpn: "wireguard", dir: nil))
        // Valid, matching, but with nothing usable in it.
        let empty = Data(#"{"servers":[]}"#.utf8)
        try empty.write(to: file)
        var emptyPin = Catalog.pin
        emptyPin.files["protonvpn.json"] = sha256(empty)
        try JSONEncoder().encode(emptyPin).write(to: dir.appending(path: "manifest.json"))
        XCTAssertThrowsError(try Catalog.bundled("protonvpn", vpn: "wireguard", dir: dir, pin: emptyPin)) { XCTAssertTrue($0 is Catalog.Damaged) }
    }

    private func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    func testSnapshotKeysLeaveOutDoubtfulHosts() {
        let k1 = F.key, k2 = F.key2
        let row = { (host: String, key: String) in
            Catalog.Entry(vpn: "wireguard", country: "Germany", serverName: "DE#1", hostname: host, wgpubkey: key, ips: ["203.0.113.1"])
        }
        let pinned = Catalog.Pinned([row("a.example", k1), row("a.example", k1), row("b.example", k1), row("b.example", k2),
                                     row("c.example", "AAAA"), row("d.example", String(F.key.dropLast(2)) + "B="),
                                     row("E.Example.", k2), row("", k1)], vpn: "wireguard")
        XCTAssertEqual(pinned.keys, ["a.example": k1, "e.example": k2])
        XCTAssertEqual(Set(pinned.entries.map(\.hostname)), ["a.example", "E.Example."])
        XCTAssertEqual(Catalog.identity(" Node-DE-01.ProtonVPN.net. "), "node-de-01.protonvpn.net")
        XCTAssertNil(Catalog.identity("."))
        XCTAssertTrue(Catalog.validKey(F.key)); XCTAssertFalse(Catalog.validKey(F.key + " ")); XCTAssertFalse(Catalog.validKey("AAAA"))
    }

    // MARK: Live refresh

    func testLiveListOnlyMovesServersTheSnapshotKnows() throws {
        let snap = try F.catalog("protonvpn")
        let pinned = Catalog.Pinned(snap, vpn: "wireguard")
        let de = try germany()
        var moved = de; moved.ips = ["203.0.113.80"]
        var rekeyed = try XCTUnwrap(snap.first { $0.serverName == "DE#231" }); rekeyed.wgpubkey = F.evil
        let stranger = Catalog.Entry(vpn: "wireguard", country: "Germany", serverName: "DE#999", hostname: "node-de-99.protonvpn.net",
                                     wgpubkey: F.key2, ips: ["203.0.113.99"])
        // A new host borrowing a trusted key, and a known host with another host's key.
        var borrowed = stranger; borrowed.hostname = "node-de-98.protonvpn.net"; borrowed.wgpubkey = de.wgpubkey
        var swapped = try XCTUnwrap(snap.first { $0.serverName == "DE#787" }); swapped.wgpubkey = de.wgpubkey
        // A new server name on a known host is a new server too.
        var alias = de; alias.serverName = "DE#9999"
        let list = pinned.refresh([moved, rekeyed, stranger, borrowed, swapped, alias]) { $0 }
        XCTAssertEqual(list, [moved])
        XCTAssertFalse(list.contains(where: \.bundled))
        // Nothing live is usable: the snapshot, less the hosts the live list just contradicted.
        let fallback = pinned.refresh([rekeyed, stranger]) { $0 }
        XCTAssertTrue(fallback.allSatisfy(\.bundled))
        XCTAssertFalse(fallback.contains { $0.hostname == rekeyed.hostname })
        XCTAssertTrue(fallback.contains { $0.hostname == de.hostname && $0.ips == de.ips })
        XCTAssertEqual(pinned.refresh(nil) { $0 }.count, pinned.entries.count)
        // The fallback is decided after the provider's own filter: paid-only live rows leave a Free plan the snapshot's.
        var free = pinned.entries[0]; free.free = true
        let withFree = Catalog.Pinned(snap + [free], vpn: "wireguard")
        let freeOnly = withFree.refresh([moved]) { $0.filter(\.free) }
        XCTAssertEqual(freeOnly.map(\.hostname), [free.hostname])
        XCTAssertTrue(freeOnly.allSatisfy(\.bundled))
    }

    func testLiveListCannotRelabelAServer() async throws {
        let de = try germany()
        var relabelled = de
        relabelled.country = "Netherlands"; relabelled.city = "Amsterdam"; relabelled.region = "Europe"; relabelled.free = true
        relabelled.ips = ["203.0.113.86"]
        let pinned = Catalog.Pinned(try F.catalog("protonvpn"), vpn: "wireguard")
        let row = try XCTUnwrap(pinned.refresh([relabelled]) { $0 }.first)
        XCTAssertEqual(row.place, "Germany"); XCTAssertEqual(row.city, de.city); XCTAssertEqual(row.region, de.region)
        XCTAssertFalse(row.free); XCTAssertEqual(row.ips, ["203.0.113.86"])
        // Through the provider: picking the Netherlands never lands on it, and a Free plan doesn't get it.
        let live = [relabelled]
        let p = F.proton(live: { live })
        let blob = try await p.signIn(["key": F.priv])
        await F.rejects("No Proton VPN server for Netherlands") { _ = try await p.connect(Location(provider: p.id, country: "Netherlands"), blob) }
        let l = try F.wg(await p.connect(self.de(p), blob))
        XCTAssertEqual(l.server.ip, "203.0.113.86"); XCTAssertEqual(l.server.country, "DE")
        let free = F.protonFree(live: { live })
        let freeServers = try await free.servers(Location(provider: free.id), blob, limit: 50)
        XCTAssertFalse(freeServers.contains { $0.ip == "203.0.113.86" })
        // ExpressVPN the same way: a live row keeps the snapshot's country, and unknown hosts aren't listed.
        let snap = try Catalog.bundled("expressvpn", vpn: "openvpn")
        var nl = try XCTUnwrap(snap.entries.first { $0.country == "Netherlands" && $0.udp })
        nl.country = "Japan"; nl.ips = ["203.0.113.87"]
        let unknown = Catalog.Entry(vpn: "openvpn", country: "Japan", hostname: "jp.example", ips: ["203.0.113.88"], udp: true)
        let express = snap.refresh([nl, unknown]) { $0 }
        XCTAssertEqual(express.map(\.place), ["Netherlands"]); XCTAssertEqual(express.first?.ips, ["203.0.113.87"])
    }

    func testProtonOffersOnlyTrustedServers() async throws {
        let snap = try F.catalog("protonvpn")
        let stranger = Catalog.Entry(vpn: "wireguard", country: "Germany", city: "Berlin", serverName: "DE#999", hostname: "node-de-99.protonvpn.net",
                                     wgpubkey: F.key2, ips: ["203.0.113.99"])
        var rekeyed = try germany(); rekeyed.wgpubkey = F.evil
        let hostile = snap.filter { $0.serverName != "DE#187" } + [stranger, rekeyed]
        let p = F.proton(live: { hostile })
        let blob = try await p.signIn(["key": F.priv])
        let servers = try await p.servers(de(p), blob, limit: 100)
        XCTAssertFalse(servers.isEmpty)
        XCTAssertFalse(servers.contains { $0.host == stranger.hostname || $0.name == "DE#187" })
        let countries = try await p.countries(blob)
        XCTAssertEqual(countries.first { $0.name == "Germany" }?.serverCount, snap.filter { $0.place == "Germany" }.count - 1)
        for _ in 0..<10 {
            let l = try F.wg(await p.connect(de(p), blob))
            XCTAssertNotEqual(l.server.host, stranger.hostname)
            XCTAssertNotEqual(l.peer.publicKey, F.evil)
        }
    }

    // MARK: Pinned servers (replaces the test that required accepting a changed key)

    func testPinnedProtonServerMovesButKeepsItsKey() async throws {
        let de = try germany()
        let pinned = try pin(de)
        var moved = de; moved.ips = ["203.0.113.81"]
        let p = F.proton()
        let l = try F.wg(await p.link(Location(provider: p.id, pinned: pinned), account) { [moved] })
        XCTAssertEqual(l.peer.endpoint, "203.0.113.81:51820"); XCTAssertEqual(l.peer.publicKey, de.wgpubkey)
        XCTAssertEqual(l.server.name, "DE#187")
        // Renamed: found by its address, and only as a server the snapshot vouches for.
        var renamed = pinned; renamed.host = "old-name"; renamed.name = "DE#1"
        let found = try F.wg(await p.link(Location(provider: p.id, pinned: renamed), account) { [de] })
        XCTAssertEqual(found.server.host, de.hostname); XCTAssertEqual(found.peer.publicKey, de.wgpubkey)
        // Gone from the list.
        var gone = pinned; gone.name = "DE#9"; gone.host = "x"; gone.ip = "203.0.113.82"
        await F.rejects("Proton VPN no longer lists DE#9. Pick another server.") { _ = try await p.link(Location(provider: p.id, pinned: gone), self.account) { [moved] } }
    }

    /// A tunnel taken over while the keychain can't be read: Proton's snapshot still decides, without the account.
    func testProtonVouchesForATunnelWithoutTheAccount() async throws {
        let de = try germany()
        let p: any Provider = F.proton()
        let l = try await (p as! Proton).link(Location(provider: "proton", pinned: try pin(de)), account) { [de] }
        XCTAssertTrue(p.vouches(l))
        guard case .wg(let sv, let peer, _, _) = l else { return XCTFail() }
        var otherKey = sv; otherKey.publicKey = F.key2
        var peer2 = peer; peer2.publicKey = F.key2
        XCTAssertFalse(p.vouches(.wg(otherKey, peer2)))
        XCTAssertFalse(p.vouches(.wg(sv, peer2)))
        var lan = sv; lan.ip = "10.0.0.9"
        XCTAssertFalse(p.vouches(.wg(lan, peer)))
        var elsewhere = peer; elsewhere.endpoint = "203.0.113.99:51820"
        XCTAssertFalse(p.vouches(.wg(sv, elsewhere)))
        XCTAssertFalse(p.vouches(.ts(sv)))
        // Providers without a pinned key list vouch as before.
        XCTAssertTrue(Mullvad().vouches(.ts(sv)))
    }

    func testPinnedProtonServerFollowsHostSpellingAndAddress() async throws {
        let de = try germany()
        let pinned = try pin(de)
        var respelled = de; respelled.hostname = de.hostname.uppercased() + "."; respelled.ips = ["203.0.113.85"]
        let live = respelled
        let p = F.proton(live: { [live] })
        let l = try F.wg(await p.connect(Location(provider: p.id, pinned: pinned), p.signIn(["key": F.priv])))
        XCTAssertEqual(l.peer.endpoint, "203.0.113.85:51820")
        XCTAssertEqual(l.peer.publicKey, de.wgpubkey)
    }

    func testPinnedProtonServerRefusesChangedKey() async throws {
        let de = try germany()
        let pinned = try pin(de)
        var changed = de; changed.wgpubkey = F.evil; changed.ips = ["203.0.113.83"]
        let rekeyed = changed
        let p = F.proton(live: { [rekeyed] })
        let message = "Proton VPN's list has a key for DE#187 that this version of unbraid doesn't trust. Update unbraid."
        // Straight from a list that changed the key, even when the address can't be resolved.
        await F.rejects(message) { _ = try await p.link(Location(provider: p.id, pinned: pinned), self.account) { [rekeyed] } }
        // Through the provider's own list: the changed row isn't there and its pin can't fall back to a decoy by address.
        var other = try XCTUnwrap(F.catalog("protonvpn").first { $0.serverName == "DE#231" }); other.ips = de.ips
        let decoy = other
        let q = F.proton(live: { [rekeyed, decoy] })
        let blob = try await q.signIn(["key": F.priv])
        // A decoy at the pin's address is at worst another genuine server with its own key: never the changed key.
        let l = try F.wg(await q.connect(Location(provider: q.id, pinned: pinned), blob))
        XCTAssertEqual(l.peer.publicKey, decoy.wgpubkey)
        XCTAssertNotEqual(l.peer.publicKey, F.evil)
        // A pin saved with a key the snapshot doesn't hold is never used offline.
        var stale = pinned; stale.publicKey = F.evil
        await F.rejects("offline") { _ = try await p.link(Location(provider: p.id, pinned: stale), self.account) { throw Fail("offline") } }
        // But a saved pin the snapshot vouches for is, at its saved address.
        let offline = try F.wg(await p.link(Location(provider: p.id, pinned: pinned), account) { throw Fail("offline") })
        XCTAssertEqual(offline.peer.endpoint, "\(pinned.ip):51820")
    }

    func testPinnedProtonServerKeepsSavedAddressWhenOnlyTheSnapshotAnswers() async throws {
        let de = try germany()
        var saved = try pin(de); saved.ip = "203.0.113.84"
        let p = F.proton(live: { throw Fail("GitHub blocked") })
        let blob = try await p.signIn(["key": F.priv])
        let l = try F.wg(await p.connect(Location(provider: p.id, pinned: saved), blob))
        XCTAssertEqual(l.peer.endpoint, "203.0.113.84:51820")
        // A pin with a key the snapshot doesn't hold is repaired from the snapshot instead.
        var stale = saved; stale.publicKey = F.evil
        let repaired = try F.wg(await p.connect(Location(provider: p.id, pinned: stale), blob))
        XCTAssertEqual(repaired.peer.publicKey, de.wgpubkey)
        XCTAssertEqual(repaired.peer.endpoint, "\(de.ips[0]):51820")
    }

    // MARK: Saved tunnels and LinkPicker

    func testSavedProtonTunnelsNeedTheSnapshotKey() async throws {
        let p = F.proton()
        let blob = try await p.signIn(["key": F.priv])
        let good = try F.wg(await p.link(de(p), p.keyAccount(blob)) { try F.catalog("protonvpn") })
        XCTAssertTrue(p.trusts(.wg(good.server, good.peer), blob))
        var sv = good.server, peer = good.peer
        sv.publicKey = F.evil; peer.publicKey = F.evil
        XCTAssertFalse(p.trusts(.wg(sv, peer), blob))
        var stranger = good.server; stranger.host = "node-de-99.protonvpn.net"
        XCTAssertFalse(p.trusts(.wg(stranger, good.peer), blob))
        XCTAssertFalse(p.trusts(.ts(good.server), blob), "a key provider's tunnel is always WireGuard")

        let route = Route(id: "r", loc: de(p))
        let setup = Setup(routes: [route], defaultRoute: "r")
        let bad = Link.wg(sv, peer)
        // Kept across a reload: refused, so a trusted server is picked afresh.
        let kept = try await LinkPicker.pick(setup, keep: ["r": bad], applied: setup, appliedAccounts: [p.id: blob], accounts: [p.id: blob],
                                             last: [:]) { $0 == p.id ? p : nil }.links
        XCTAssertNotEqual(kept["r"], bad)
        XCTAssertTrue(p.trusts(try XCTUnwrap(kept["r"]), blob))
        // Cached for an outage: not a stand-in.
        let down = F.proton(live: { throw Fail("down") })
        var broken = down
        broken.catalogue.pinned = { throw Catalog.Damaged() }
        let damaged = try await LinkPicker.pick(setup, keep: [:], applied: nil, appliedAccounts: [:], accounts: [p.id: blob],
                                                last: [LinkPicker.cacheKey(route, account: blob): bad]) { $0 == p.id ? broken : nil }
        XCTAssertNil(damaged.links["r"])
        XCTAssertEqual(damaged.blocked["r"], .unreachable(Catalog.Damaged().localizedDescription))
        let signedOut = try await LinkPicker.pick(setup, keep: ["r": .wg(good.server, good.peer)], applied: setup, appliedAccounts: [:], accounts: [:],
                                                  last: [:]) { $0 == p.id ? p : nil }
        XCTAssertNil(signedOut.links["r"])
        XCTAssertEqual(signedOut.blocked["r"], .signedOut(p.name))
    }

    // MARK: Offline

    func testProtonWorksFromTheBundleWhenGitHubIsBlocked() async throws {
        var p = Proton()
        p.catalogue.live = { throw URLError(.cannotConnectToHost) }
        p.catalogue.saved = nil
        let blob = try await p.signIn(["key": F.priv])
        let countries = try await p.countries(blob)
        XCTAssertGreaterThan(countries.count, 50)
        let l = try F.wg(await p.connect(Location(provider: p.id, countryCode: "DE"), blob))
        XCTAssertEqual(l.server.country, "DE")
        XCTAssertTrue(p.trusts(.wg(l.server, l.peer), blob))
        var free = ProtonFree()
        free.catalogue.live = { throw URLError(.cannotConnectToHost) }
        free.catalogue.saved = nil
        let freeCountries = try await free.countries(blob)
        XCTAssertFalse(freeCountries.isEmpty)
    }

    func testExpressVpnWorksFromTheBundleWhenGitHubIsBlocked() async throws {
        var p = ExpressVpn()
        p.catalogue.live = { throw URLError(.cannotConnectToHost) }
        p.catalogue.saved = nil
        let blob = JSON.encode(ExpressVpn.Account(username: "u", password: "p"))
        let offline = try await p.countries(blob)
        XCTAssertGreaterThan(offline.count, 50)
        let l = try F.ovpn(await p.connect(Location(provider: p.id, country: "Netherlands"), blob))
        XCTAssertTrue(Catalog.Entry.publicIPv4(l.server.ip))
        // A live list with only TCP servers is no list for unbraid: the bundled UDP ones stand in.
        let tcp = Catalog.Entry(vpn: "openvpn", country: "Netherlands", hostname: "nl.example", ips: ["203.0.113.90"], tcp: true)
        p.catalogue.live = { [tcp] }
        let fallback = try await p.countries(blob)
        XCTAssertGreaterThan(fallback.count, 50)
        // A usable live list refreshes the addresses of the servers the bundled one lists.
        var udp = try XCTUnwrap(Catalog.bundled("expressvpn", vpn: "openvpn").entries.first { $0.country == "Netherlands" && $0.udp })
        udp.ips = ["203.0.113.91"]
        let fresh = udp
        p.catalogue.live = { [fresh] }
        let live = try F.ovpn(await p.connect(Location(provider: p.id, country: "Netherlands"), blob))
        XCTAssertEqual(live.server.ip, "203.0.113.91")
    }

    /// GitHub unreachable after a good live read: the kept live list's addresses, checked against the snapshot again,
    /// marked as not live (a pin newer than it stands; its countries aren't cached as today's).
    func testTheLastGoodLiveListStandsInWhenGitHubIsBlocked() async throws {
        let de = try germany()
        var m = de; m.ips = ["203.0.113.95"]
        let moved = m
        let evil = { var e = moved; e.wgpubkey = F.key2; return e }()
        var p = F.proton(live: { [moved] })
        p.catalogue.saved = .memory()
        let blob = try await p.signIn(["key": F.priv])
        let first = try await p.freshCountries(blob)
        XCTAssertTrue(first.live)
        p.catalogue.live = { throw URLError(.cannotConnectToHost) }
        let kept = try await p.entries(try p.keyAccount(blob))
        XCTAssertEqual(kept.first { $0.hostname == de.hostname }?.ips, ["203.0.113.95"])
        XCTAssertTrue(kept.allSatisfy(\.bundled))
        let offline = try await p.freshCountries(blob)
        XCTAssertFalse(offline.live)
        XCTAssertEqual(offline.countries, first.countries)
        // A pinned server keeps its saved (newer) address when only a kept list answers.
        var pin = try pin(de); pin.ip = "203.0.113.96"
        let l = try F.wg(await p.connect(Location(provider: p.id, pinned: pin), blob))
        XCTAssertEqual(l.peer.endpoint, "203.0.113.96:51820")
        // A kept list is checked against the snapshot like a live one: a changed key never comes back from it.
        var q = F.proton(live: { [evil] })
        q.catalogue.saved = .memory()
        _ = try await q.entries(try q.keyAccount(blob))
        q.catalogue.live = { throw URLError(.cannotConnectToHost) }
        let checked = try await q.entries(try q.keyAccount(blob))
        XCTAssertFalse(checked.contains { $0.wgpubkey == F.key2 })
        // And a host the live list contradicted after a good read leaves the kept list: an outage later falls back to the
        // snapshot (as before the kept list existed), never to the address the contradicting list replaced.
        var r = F.proton(live: { [moved] })
        r.catalogue.saved = .memory()
        _ = try await r.entries(try r.keyAccount(blob))
        r.catalogue.live = { [evil] }
        _ = try await r.entries(try r.keyAccount(blob))
        r.catalogue.live = { throw URLError(.cannotConnectToHost) }
        let after = try await r.entries(try r.keyAccount(blob))
        XCTAssertFalse(after.contains { $0.ips == ["203.0.113.95"] })
        // A list the snapshot refused (here: only an unknown host) never replaces the kept good one.
        let unknown = Catalog.Entry(vpn: "wireguard", country: "Germany", hostname: "de-999.protonvpn.net", wgpubkey: F.key, ips: ["203.0.113.97"])
        p.catalogue.live = { [unknown] }
        _ = try await p.entries(try p.keyAccount(blob))
        p.catalogue.live = { throw URLError(.cannotConnectToHost) }
        let stillGood = try await p.entries(try p.keyAccount(blob))
        XCTAssertEqual(stillGood.first { $0.hostname == de.hostname }?.ips, ["203.0.113.95"])
    }

    func testPublicationFollowsTheListActuallyUsed() async throws {
        var live = try germany()
        live.published = 1_800_000_000
        let row = live
        var p = F.proton(live: { [row] })
        p.catalogue.pinned = { Catalog.Pinned(try F.catalog("protonvpn"), vpn: "wireguard", published: 1_785_990_858) }
        p.catalogue.saved = .memory()
        let blob = try await p.signIn(["key": F.priv])
        let first = try await p.freshCountries(blob)
        XCTAssertEqual(first.published, 1_800_000_000)
        XCTAssertFalse(first.failed)
        p.catalogue.live = { throw URLError(.notConnectedToInternet) }
        let kept = try await p.freshCountries(blob)
        XCTAssertEqual(kept.published, 1_800_000_000)
        XCTAssertTrue(kept.failed)
        p.catalogue.saved = nil
        let snapshotDate = Catalog.timestamp(try Data(contentsOf: XCTUnwrap(Catalog.folder).appending(path: "protonvpn.json")))
        let bundled = try await p.freshCountries(blob)
        XCTAssertEqual(bundled.published, snapshotDate)
        var rejected = row
        rejected.wgpubkey = F.key2
        let bad = rejected
        p.catalogue.live = { [bad] }
        let refused = try await p.freshCountries(blob)
        XCTAssertEqual(refused.published, snapshotDate)
    }

    func testOldSavedCatalogueEntryDecodesWithoutPublicationDate() throws {
        let data = Data(#"[{"vpn":"wireguard","hostname":"old.example","ips":["203.0.113.1"]}]"#.utf8)
        let saved = Catalog.Saved(load: { data }, save: { _, done in done(true) })
        let entry = try XCTUnwrap(saved.read()?.first)
        XCTAssertNil(entry.published)
        XCTAssertEqual(entry.hostname, "old.example")
    }

    /// A kept list whose write didn't make it to disk is written again, even unchanged.
    func testAKeptListThatWasntStoredIsWrittenAgain() {
        final class Writes: @unchecked Sendable { var count = 0; var ok = false }
        let w = Writes()
        let saved = Catalog.Saved(load: { nil }, save: { _, done in w.count += 1; done(w.ok) })
        let list = [Catalog.Entry(vpn: "wireguard", hostname: "a", ips: ["203.0.113.1"])]
        saved.write(list)
        saved.write(list)
        XCTAssertEqual(w.count, 2)
        w.ok = true
        saved.write(list)
        saved.write(list)
        XCTAssertEqual(w.count, 3)
        XCTAssertEqual(saved.read(), list)
    }

    func testSlowOrCancelledLiveList() async throws {
        let start = ContinuousClock.now
        await F.rejects("The server list took too long") { _ = try await Catalog.within(0.2) { try await Task.sleep(for: .seconds(5)); return 1 } }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        let source = Catalog.Source(live: { try await Task.sleep(for: .seconds(5)); return [] },
                                    pinned: { Catalog.Pinned(try F.catalog("protonvpn"), vpn: "wireguard") })
        let task = Task { try await source.entries { $0 } }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }
}
