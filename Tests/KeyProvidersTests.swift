import XCTest
import Synchronization

final class KeyProvidersTests: XCTestCase {
    private typealias F = ProviderFixtures

    func testProtonDropsSecureCoreAndTor() throws {
        let raw = try F.catalog("protonvpn")
        let kept = Proton().filtered(raw)
        XCTAssertTrue(raw.contains { ($0.serverName ?? "").contains(/^(CH|IS|SE)-[A-Z]{2}#/) })
        XCTAssertFalse(kept.isEmpty)
        XCTAssertLessThan(kept.count, raw.count)
        XCTAssertFalse(kept.contains { ($0.serverName ?? "").contains(/^(CH|IS|SE)-[A-Z]{2}#/) || ($0.serverName ?? "").hasSuffix("-TOR") })
        XCTAssertTrue(Catalog.countries(kept).allSatisfy { F.iso.contains($0.code) && $0.serverCount > 0 })
    }

    func testProtonBareKeyConnectsToCountryAndCity() async throws {
        let p = F.proton()
        let a = try await F.signed(p)
        let entries = try p.filtered(F.catalog("protonvpn"))
        let l = try F.wg(await p.link(Location(provider: p.id, countryCode: "DE", country: "Germany"), a) { entries })
        XCTAssertTrue(entries.filter { $0.place == "Germany" }.compactMap(\.ipv4).contains(l.server.ip))
        XCTAssertEqual(l.server.publicKey, l.peer.publicKey)
        XCTAssertEqual(l.peer.address, ["10.2.0.2/32"])
        XCTAssertEqual(l.peer.dns, ["10.2.0.1"])
        XCTAssertEqual(l.peer.endpoint, "\(l.server.ip):51820")
        XCTAssertEqual(l.peer.allowedIps, ["0.0.0.0/0"])
        XCTAssertNil(l.peer.presharedKey)
        XCTAssertEqual(l.peer.privateKey, F.priv)
        let byCode = try F.wg(await p.link(Location(provider: p.id, countryCode: "DE"), a) { entries })
        XCTAssertEqual(byCode.server.country, "DE")
        let city = try F.cityLoc(p.id, entries)
        let lc = try F.wg(await p.link(city, a) { entries })
        XCTAssertEqual(lc.server.city, city.region)
        XCTAssertTrue(entries.contains { $0.ipv4 == lc.server.ip && $0.place == city.country })
    }

    func testProtonFreeOffersOnlyFreeServers() async throws {
        let raw = try F.catalog("protonvpn").map { var e = $0; if e.place == "Austria" { e.free = true }; return e }
        let p = F.protonFree()
        let free = p.filtered(raw)
        XCTAssertFalse(free.isEmpty)
        XCTAssertTrue(free.allSatisfy { $0.free && $0.place == "Austria" })
        XCTAssertTrue(Set(Proton().filtered(raw)).isSuperset(of: free))
        XCTAssertTrue(Proton().filtered(raw).contains { !$0.free })
        XCTAssertEqual(Catalog.countries(free).map(\.name), ["Austria"])
        XCTAssertEqual(p.id, "proton-free"); XCTAssertEqual(p.name, "Proton VPN Free")
        XCTAssertEqual(Proton().id, "proton"); XCTAssertTrue(p.help.contains("free-vpn/server"))
        let a = try await F.signed(p)
        let l = try F.wg(await p.link(Location(provider: p.id, countryCode: "AT"), a) { free })
        XCTAssertEqual(l.server.country, "AT")
        await F.rejects("No Proton VPN Free server for Germany") {
            _ = try await p.link(Location(provider: p.id, country: "Germany"), a) { free }
        }
    }

    func testProtonConfOverridesDefaults() async throws {
        let a = try await F.signed(Proton(), F.conf("10.2.0.2/32, 2a07:b944::2:2/128", extra: "MTU = 1400"))
        XCTAssertEqual(a.privateKey, F.priv); XCTAssertEqual(a.address, ["10.2.0.2/32"])
        XCTAssertEqual(a.dns, ["10.2.0.1"]); XCTAssertEqual(a.mtu, 1400)
        let b = try await F.signed(Proton(), F.conf("10.3.0.2/32", dns: "10.3.0.1"))
        XCTAssertEqual(b.address, ["10.3.0.2/32"]); XCTAssertEqual(b.dns, ["10.3.0.1"]); XCTAssertEqual(b.mtu, 1420)
    }

    func testProtonPinnedServerNeedsNoList() async throws {
        let p = F.proton()
        let entries = try p.filtered(F.catalog("protonvpn"))
        let a = try await F.signed(p)
        let sv = try await p.link(Location(provider: p.id, country: "Germany"), a) { entries }.server
        let l = try F.wg(await p.link(Location(provider: p.id, pinned: sv), a) { throw Fail("offline") })
        XCTAssertEqual(l.server, sv)
        XCTAssertEqual(l.peer.endpoint, "\(sv.ip):51820")
    }

    func testBadKeysAreRejected() async {
        for p: any KeyProvider in [Proton(), ProtonFree(), F.surfshark(), F.air()] {
            for bad in ["", "hello", String(repeating: "a", count: 64), String(F.priv.dropLast()),
                        "!" + F.priv.dropFirst(), F.conf().replacingOccurrences(of: F.priv, with: "short"),
                        F.conf().replacingOccurrences(of: "[Peer]", with: "")] {
                await F.rejects { _ = try await p.signIn(["key": bad]) }
            }
        }
    }

    func testSurfsharkLiveListHasCountriesKeysAndNoIps() throws {
        let entries = try Surfshark.parse(Fixture.data("surfshark_clusters.json"))
        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.allSatisfy { $0.ips.isEmpty && $0.hostname.hasSuffix(".prod.surfshark.com") && $0.wgpubkey?.count == 44 })
        let cs = Catalog.countries(entries)
        XCTAssertTrue(cs.contains { $0.name == "Netherlands" && $0.code == "NL" && $0.cities.contains { $0.name == "Amsterdam" } })
        XCTAssertTrue(cs.allSatisfy { F.iso.contains($0.code) })
    }

    func testSurfsharkUsesCatalogueForChosenHost() async throws {
        let entries = try Surfshark.parse(Fixture.data("surfshark_clusters.json"))
        let cat = try F.catalog("surfshark")
        var p = F.surfshark()
        p.catalogue = { cat }
        let a = try await F.signed(p)
        let l = try F.wg(await p.link(Location(provider: p.id, country: "Netherlands"), a) { entries })
        XCTAssertTrue(cat.contains { $0.hostname == l.server.host && $0.ips.contains(l.server.ip) })
        XCTAssertEqual(l.peer.endpoint, "\(l.server.ip):51820")
        XCTAssertEqual(l.peer.address, ["10.14.0.2/16"])
        XCTAssertEqual(l.peer.dns, ["162.252.172.57", "149.154.159.92"])
        XCTAssertEqual(l.peer.mtu, 1280)
        XCTAssertEqual(l.peer.publicKey, entries.first { $0.hostname == l.server.host }?.wgpubkey)
        let byCode = try await p.link(Location(provider: p.id, countryCode: "DE"), a) { entries }
        XCTAssertEqual(byCode.server.country, "DE")
        let city = try F.cityLoc(p.id, entries)
        let lc = try await p.link(city, a) { entries }
        XCTAssertEqual(lc.server.city, city.region)
    }

    func testSurfsharkFallsBackToSameLocationWithoutStaticIps() async throws {
        let entries = try Surfshark.parse(Fixture.data("surfshark_clusters.json"))
        let cat = try F.catalog("surfshark") + [Catalog.Entry(vpn: "wireguard", country: "Germany", city: "Frankfurt",
                    hostname: "de-fra-st001.prod.surfshark.com", wgpubkey: F.key, ips: ["5.5.5.5"])]
        var p = F.surfshark()
        p.catalogue = { cat }
        let a = try await F.signed(p)
        let l = try F.wg(await p.link(Location(provider: p.id, country: "Germany"), a) { entries })
        XCTAssertTrue(Surfshark.fallback(cat).filter { $0.place == "Germany" }.flatMap(\.ips).contains(l.server.ip))
        XCTAssertEqual(l.server.country, "DE"); XCTAssertNotEqual(l.server.ip, "5.5.5.5")
        let city = try F.cityLoc(p.id, Surfshark.fallback(cat))
        let lc = try await p.link(city, a) { entries }
        XCTAssertEqual(lc.server.city, city.region); XCTAssertEqual(lc.server.country, city.countryCode)
    }

    func testSurfsharkSkipsHostsWithoutCatalogueAddresses() async throws {
        let entries = try Surfshark.parse(Fixture.data("surfshark_clusters.json"))
        let wanted = try XCTUnwrap(entries.last { $0.place == "Germany" })
        var p = F.surfshark()
        p.catalogue = { [Catalog.Entry(hostname: wanted.hostname, ips: ["198.51.100.9"])] }
        let a = try await F.signed(p)
        let l = try F.wg(await p.link(Location(provider: p.id, country: "Germany"), a) { entries })
        XCTAssertEqual(l.peer.endpoint, "198.51.100.9:51820")
        var q = F.surfshark()
        q.catalogue = { throw Fail("offline") }
        await F.rejects("No Surfshark server for Germany") {
            _ = try await q.link(Location(provider: q.id, country: "Germany"), a) { entries }
        }
    }

    func testSurfsharkCatalogueFallbackHasIpsAndNoStaticServers() async throws {
        let raw = try F.catalog("surfshark") + [Catalog.Entry(vpn: "wireguard", country: "Germany",
                    hostname: "de-fra-st001.prod.surfshark.com", wgpubkey: F.key, ips: ["5.5.5.5"])]
        let kept = Surfshark.fallback(raw)
        XCTAssertEqual(kept, raw.filter { !$0.hostname.contains(/-st\d+\./) })
        var p = F.surfshark()
        p.catalogue = { XCTFail("Addresses already present"); return [] }
        let a = try await F.signed(p)
        let l = try F.wg(await p.link(Location(provider: p.id, country: "Netherlands"), a) { kept })
        XCTAssertTrue(kept.filter { $0.place == "Netherlands" }.flatMap(\.ips).contains(l.server.ip))
        XCTAssertTrue(l.peer.endpoint.hasSuffix(":51820"))
    }

    func testSurfsharkConfIsUsedAsPasted() async throws {
        let p = F.surfshark()
        let a = try await F.signed(p, F.conf("10.14.0.2/16", dns: "162.252.172.57, 149.154.159.92", endpoint: "nl-ams.prod.surfshark.com:51820"))
        XCTAssertEqual(a.address, ["10.14.0.2/16"]); XCTAssertEqual(a.dns, p.defaultDns)
        XCTAssertEqual(a.port, 51820); XCTAssertEqual(a.mtu, 1280); XCTAssertNil(a.presharedKey)
        let b = try await F.signed(p, F.conf("10.64.222.21/16", dns: "1.1.1.1"))
        XCTAssertEqual(b.address, ["10.64.222.21/16"]); XCTAssertEqual(b.dns, ["1.1.1.1"])
    }

    func testAirvpnLiveListUsesHealthyIpv4Entries() throws {
        let entries = try AirVpn.parse(Fixture.data("airvpn_status.json"), serverKey: F.key)
        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.allSatisfy { $0.vpn == "wireguard" && $0.ips.count == 1 && $0.ipv4 != nil && $0.wgpubkey == F.key && $0.hostname.hasSuffix(".vpn.airdns.org") })
        let cs = Catalog.countries(entries)
        XCTAssertTrue(cs.contains { $0.name == "Netherlands" && $0.code == "NL" })
        XCTAssertTrue(cs.allSatisfy { F.iso.contains($0.code) })
        XCTAssertFalse(entries.compactMap(\.city).contains { $0.contains(",") })
        let body = #"{"servers":[{"country_name":"Austria","country_code":"at","ip_v4_in1":"1.2.3.4","health":"warning"},{"country_name":"Austria","country_code":"at","ip_v4_in1":"1.2.3.5","health":"ok"}]}"#
        XCTAssertEqual(try AirVpn.parse(F.data(body), serverKey: F.key).flatMap(\.ips), ["1.2.3.5"])
        // The second address is dialled as the "Entry address" option: a first one that isn't public never stands with it.
        for first in ["10.1.2.3", "entry.example", "1.2.3"] {
            let two = #"{"servers":[{"country_name":"Austria","country_code":"at","ip_v4_in1":"\#(first)","ip_v4_in3":"1.2.3.6","health":"ok"}]}"#
            XCTAssertEqual(try AirVpn.parse(F.data(two), serverKey: F.key).flatMap(\.ips), ["1.2.3.6"], first)
        }
    }

    func testAirvpnNeedsWholeConfAndPresharedKey() async throws {
        let p = F.air()
        await F.rejects("AirVPN needs the whole downloaded .conf file: it holds this device's address and preshared key") {
            _ = try await p.signIn(["key": F.priv])
        }
        await F.rejects("That AirVPN config has no PresharedKey line") { _ = try await p.signIn(["key": F.conf()]) }
        let a = try await F.signed(p, F.airConf)
        XCTAssertEqual(a.address, ["10.164.20.6/32"]); XCTAssertEqual(a.presharedKey, F.psk)
        XCTAssertEqual(a.publicKey, F.key); XCTAssertEqual(a.port, 1637); XCTAssertEqual(a.dns, ["10.128.0.1"])
    }

    func testAirvpnConnectsWithPresharedKeyOnPort1637() async throws {
        let p = F.air()
        let a = try await F.signed(p, F.airConf)
        let entries = try AirVpn.parse(Fixture.data("airvpn_status.json"), serverKey: F.key)
        let l = try F.wg(await p.link(Location(provider: p.id, country: "Netherlands"), a) { entries })
        XCTAssertTrue(entries.filter { $0.place == "Netherlands" }.compactMap(\.ipv4).contains(l.server.ip))
        XCTAssertEqual(l.peer.endpoint, "\(l.server.ip):1637")
        XCTAssertEqual(l.peer.presharedKey, F.psk); XCTAssertEqual(l.peer.publicKey, F.key)
        XCTAssertEqual(l.peer.address, ["10.164.20.6/32"]); XCTAssertEqual(l.peer.dns, ["10.128.0.1"])
        let byCode = try await p.link(Location(provider: p.id, countryCode: "NL"), a) { entries }
        XCTAssertEqual(byCode.server.country, "NL")
        let city = try F.cityLoc(p.id, entries)
        let lc = try await p.link(city, a) { entries }
        XCTAssertEqual(lc.server.city, city.region)
    }

    func testAirvpnCatalogueLinkUsesAccountKey() async throws {
        let p = F.air()
        let entries = try F.catalog("airvpn")
        let a = try await F.signed(p, F.airConf)
        let l = try F.wg(await p.link(Location(provider: p.id, country: "Germany"), a) { entries })
        XCTAssertEqual(l.peer.publicKey, F.key)
        XCTAssertTrue(l.peer.endpoint.hasSuffix(":1637"))
    }

    func testSingBoxAcceptsEveryLink() async throws {
        var surf = F.surfshark()
        surf.catalogue = { try F.catalog("surfshark") }
        let inputs: [(any KeyProvider, [Catalog.Entry], String, String)] = [
            (F.proton(), try Proton().filtered(F.catalog("protonvpn")), F.priv, "Germany"),
            (surf, try Surfshark.parse(Fixture.data("surfshark_clusters.json")), F.priv, "Netherlands"),
            (F.air(), try AirVpn.parse(Fixture.data("airvpn_status.json"), serverKey: F.key), F.airConf, "Germany"),
        ]
        for (p, entries, text, country) in inputs {
            let a = try await F.signed(p, text)
            for loc in [Location(provider: p.id, country: country), try F.cityLoc(p.id, entries)] {
                let l = try F.wg(await p.link(loc, a) { entries })
                try F.check(F.wgEndpoint(l.peer))
            }
        }
    }
}

extension KeyProvidersTests {
    func testProtonConfigFactsAndOldAccount() async throws {
        let p = Proton()
        let conf = "# VPN Accelerator = on\n# NetShield = 2\n# Moderate NAT = off\n# NAT-PMP (Port Forwarding) = off\n# Secret = ignored\n" + ProviderFixtures.conf()
        let blob = try await p.signIn(["key": conf])
        let facts = try await p.facts(blob)
        XCTAssertEqual(facts, "VPN Accelerator on · NetShield malware, ads and trackers · Moderate NAT off · Port forwarding off")
        let bare = try await p.signIn(["key": ProviderFixtures.priv])
        let unknown = try await p.facts(bare)
        XCTAssertEqual(unknown, "Not known")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(blob.utf8)) as? [String: Any])
        object.removeValue(forKey: "facts")
        let old = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let oldFacts = try await p.facts(old)
        XCTAssertEqual(oldFacts, "Not known")
    }
}

extension KeyProvidersTests {
    func testSurfsharkFixtureHostsAreUnique() throws {
        let entries = try Surfshark.parse(Fixture.data("surfshark_clusters.json"))
        XCTAssertEqual(Set(entries.map(\.hostname)).count, entries.count)
    }
}
