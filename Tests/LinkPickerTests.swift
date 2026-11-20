import XCTest

private func link(_ sv: Server) -> Link {
    .wg(sv, WgPeer(name: sv.name, privateKey: "priv", address: ["10.5.0.2/32"], publicKey: sv.publicKey, endpoint: "\(sv.ip):51820", allowedIps: ["0.0.0.0/0"]))
}

private struct Down: Error {}

/// `best` is what connect() returns for an unpinned location; a pinned one returns its own server.
private struct Fake: Provider {
    var best: [Server]
    var online = true
    var trusted = true
    var oneKey = false
    var failIfCalled = false
    var cancelBeforeReturning = false
    var missingPin = false
    /// What the provider's latest list says about a kept server under the page settings.
    var suitsServer = true
    /// What the provider says about taking a disguised tunnel; nil = nothing.
    var disguise: Disguise? = nil
    var id = "fake"
    let name = "Fake"
    let fields: [Field] = []
    let help = ""
    func signIn(_ input: [String: String]) async throws -> String { "acc" }
    func countries(_ account: String) async throws -> [Country] { [] }
    func connect(_ loc: Location, _ account: String) async throws -> Link {
        if failIfCalled { XCTFail("Offline picking called connect"); throw Down() }
        guard online else { throw Down() }
        if missingPin, let pin = loc.pinned { throw Catalog.Gone(provider: name, server: pin.name) }
        if cancelBeforeReturning { withUnsafeCurrentTask { $0?.cancel() } }
        return marked(link(loc.pinned ?? best[0]))
    }
    private func marked(_ l: Link) -> Link {
        guard let disguise, case .wg(let s, var p, let ports, let entries) = l else { return l }
        p.disguise = disguise
        return .wg(s, p, ports: ports, entries: entries)
    }
    func servers(_ loc: Location, _ account: String, limit: Int) async throws -> [Server] {
        if failIfCalled { XCTFail("Offline picking called servers"); throw Down() }
        return best
    }
    func trusts(_ link: Link, _ account: String) -> Bool { trusted }
    func suits(_ server: Server, opts: [String: String]) -> Bool { suitsServer }
}

final class LinkPickerTests: XCTestCase {
    private func server(_ n: String, ip: String? = nil, host: String = "shared.example") -> Server {
        Server(name: n, host: host, ip: ip ?? "10.0.0.\(n.count)", publicKey: "pub", load: 0)
    }

    private func setup(_ routes: Route...) -> Setup {
        Setup(routes: routes, defaultRoute: routes[0].id, apps: Dictionary(uniqueKeysWithValues: routes.dropFirst().map { ("app.\($0.id)", $0.id) }))
    }

    private func pick(_ s: Setup, _ p: Fake, last: [String: Link] = [:]) async throws -> [String: Link] {
        try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:], accounts: ["fake": "acc"], last: last) { $0 == "fake" ? p : nil }.links
    }

    private func route(_ id: String, _ cc: String = "NL", pinned: Server? = nil) -> Route {
        Route(id: id, loc: Location(provider: "fake", countryCode: cc, pinned: pinned))
    }

    private let a = Server(name: "a", host: "shared.example", ip: "10.0.0.1", publicKey: "pub", load: 0)
    private let b = Server(name: "bb", host: "shared.example", ip: "10.0.0.9", publicKey: "pub", load: 0)

    func testRemovedPinStaysBlockedAcrossLaterPicks() async throws {
        let r = route("1", pinned: a), s = setup(r)
        let cache = [LinkPicker.cacheKey(r, account: "acc"): link(a)]
        let first = try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:],
            accounts: ["fake": "acc"], last: cache) { _ in Fake(best: [a], missingPin: true) }
        XCTAssertTrue(first.links.isEmpty)
        XCTAssertEqual(first.blocked, ["1": .noLongerOffered(a.name)])
        var gone = LinkPicker.RemovedPins()
        gone.remember(first.blocked, setup: s, accounts: ["fake": "acc"])
        gone.update(s, accounts: ["fake": "acc"])
        // Neither a provider's saved-pin fallback, a kept link nor the offline cache can revive it.
        for offline in [false, true] {
            for keep in [[:], ["1": link(a)]] {
                let next = try await LinkPicker.pick(s, keep: keep, applied: s, appliedAccounts: ["fake": "acc"],
                    accounts: ["fake": "acc"], last: cache, gone: gone, offline: offline) { _ in
                    Fake(best: [a], failIfCalled: true)
                }
                XCTAssertTrue(next.links.isEmpty)
                XCTAssertTrue(next.remember.isEmpty)
                XCTAssertEqual(next.blocked, first.blocked)
            }
        }
        gone = LinkPicker.RemovedPins()
        let reconnected = try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:],
            accounts: ["fake": "acc"], last: cache, gone: gone) { _ in Fake(best: [a], online: false) }
        XCTAssertEqual(reconnected.links["1"]?.server, a)
    }

    func testRemovedPinsUseProviderAndHostname() async throws {
        let r = route("1", pinned: a)
        var sameHost = a; sameHost.ip = "10.0.0.88"; sameHost.publicKey = "new-key"
        var otherHost = a; otherHost.host = "other.example"
        let shared = route("2", "DE", pinned: sameHost)
        var otherProvider = route("3", pinned: a); otherProvider.loc.provider = "other"
        let other = route("4", pinned: otherHost)
        let s = setup(r, shared, otherProvider, other)
        var gone = LinkPicker.RemovedPins()
        gone.remember(["1": .noLongerOffered(a.name)], setup: s, accounts: ["fake": "acc"])
        let result = try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:],
            accounts: ["fake": "acc", "other": "acc"], last: [:], gone: gone) { id in Fake(best: [a], id: id) }
        XCTAssertEqual(Set(result.blocked.keys), ["1", "2"])
        XCTAssertEqual(Set(result.links.keys), ["3", "4"])
    }

    /// AirVPN gives every server of a country one host name. Two routes pinned to two of them, restored without their
    /// addresses, keep a cached tunnel each, and one server gone doesn't block the other. NordVPN's servers can be gone
    /// for one technology and not another: a NordLynx route isn't blocked by its server leaving the OpenVPN list.
    func testPinsSharingAHostStayApart() async throws {
        let one = Server(name: "Alphard", host: "se.vpn.airdns.org", ip: "", publicKey: "", load: 0)
        let two = Server(name: "Muscida", host: "se.vpn.airdns.org", ip: "", publicKey: "", load: 0)
        func air(_ id: String, _ pin: Server) -> Route { Route(id: id, loc: Location(provider: "airvpn", countryCode: "SE", pinned: pin)) }
        let r1 = air("1", one), r2 = air("2", two)
        XCTAssertNotEqual(LinkPicker.cacheKey(r1, account: "acc"), LinkPicker.cacheKey(r2, account: "acc"))
        XCTAssertNotEqual(LinkPicker.pinKey(r1.loc), LinkPicker.pinKey(r2.loc))
        let s = setup(r1, r2)
        var gone = LinkPicker.RemovedPins()
        gone.remember(["1": .noLongerOffered(one.name)], setup: s, accounts: ["airvpn": "acc"])
        XCTAssertEqual(gone.reason(for: r1), .noLongerOffered(one.name))
        XCTAssertNil(gone.reason(for: r2))
        // A pinned server with an address keeps the key it had.
        var addressed = r1; addressed.loc.pinned?.ip = "10.0.0.1"
        XCTAssertTrue(LinkPicker.cacheKey(addressed, account: "acc").hasSuffix("|10.0.0.1"))

        let nord = Server(name: "Sweden #1", host: "se1.nordvpn.com", ip: "10.0.0.2", publicKey: "", load: 0)
        let lynx = Route(id: "3", loc: Location(provider: "nord", countryCode: "SE", pinned: nord))
        var ovpn = lynx; ovpn.id = "4"; ovpn.loc.proto = "openvpn_udp"
        XCTAssertNotEqual(LinkPicker.pinKey(lynx.loc), LinkPicker.pinKey(ovpn.loc))
        var nordGone = LinkPicker.RemovedPins()
        nordGone.remember(["4": .noLongerOffered(nord.name)], setup: setup(lynx, ovpn), accounts: ["nord": "acc"])
        XCTAssertNil(nordGone.reason(for: lynx))
        XCTAssertNotNil(nordGone.reason(for: ovpn))
    }

    func testRemovedPinsForgetChangedOrDeletedLocationsButKeepInactiveRoutes() {
        let r = route("1", pinned: a)
        var s = setup(r)
        var gone = LinkPicker.RemovedPins()
        gone.remember(["1": .noLongerOffered(a.name)], setup: s, accounts: ["fake": "acc"])
        s.defaultRoute = DIRECT
        s.routes[0].hue = 3
        gone.update(s, accounts: ["fake": "acc"])
        XCTAssertNotNil(gone.reason(for: r))
        s.routes[0].loc.countryCode = "DE"
        gone.update(s, accounts: ["fake": "acc"])
        XCTAssertNil(gone.reason(for: r))
        gone.remember(["1": .noLongerOffered(a.name)], setup: setup(r), accounts: ["fake": "acc"])
        gone.update(Setup(), accounts: ["fake": "acc"])
        XCTAssertNil(gone.reason(for: r))
    }

    func testRemovedPinsForgetOnlyTheProviderWhoseAccountChanged() async throws {
        let r = route("1", pinned: a)
        var other = route("2", pinned: a); other.loc.provider = "other"
        let s = setup(r, other), accounts = ["fake": "acc", "other": "other-acc"]
        for changed in [["other": "other-acc"], ["fake": "new-acc", "other": "other-acc"]] {
            var gone = LinkPicker.RemovedPins()
            gone.remember(["1": .noLongerOffered(a.name), "2": .noLongerOffered(a.name)], setup: s, accounts: accounts)
            gone.update(s, accounts: accounts)
            XCTAssertNotNil(gone.reason(for: r))
            gone.update(s, accounts: changed)
            XCTAssertNil(gone.reason(for: r))
            XCTAssertNotNil(gone.reason(for: other))
            gone.update(s, accounts: accounts)
            let picked = try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:], accounts: accounts,
                                                  last: [:], gone: gone) { Fake(best: [self.a], id: $0) }
            XCTAssertEqual(picked.links["1"]?.server, a)
            XCTAssertEqual(picked.blocked, ["2": .noLongerOffered(a.name)])
        }
    }

    func testRemovedPinsForgetANewSignInWithTheSameCredentials() {
        let r = route("1", pinned: a)
        var other = route("2", pinned: a); other.loc.provider = "other"
        let s = setup(r, other), accounts = ["fake": "acc", "other": "other-acc"]
        var gone = LinkPicker.RemovedPins()
        gone.remember(["1": .noLongerOffered(a.name), "2": .noLongerOffered(a.name)], setup: s, accounts: accounts)
        gone.forget("fake")
        gone.update(s, accounts: accounts)
        XCTAssertNil(gone.reason(for: r))
        XCTAssertNotNil(gone.reason(for: other))
    }

    func testRemovedPinFromAnOlderAccountIsDiscarded() {
        let r = route("1", pinned: a), s = setup(r)
        var gone = LinkPicker.RemovedPins()
        gone.remember(["1": .noLongerOffered(a.name)], setup: s, accounts: ["fake": "old"])
        gone.update(s, accounts: ["fake": "new"])
        XCTAssertNil(gone.reason(for: r))
    }

    func testTemporaryFailureDoesNotRememberARemovedPin() {
        let r = route("1", pinned: a)
        var gone = LinkPicker.RemovedPins()
        gone.remember(["1": .unreachable("offline")], setup: setup(r), accounts: ["fake": "acc"])
        XCTAssertNil(gone.reason(for: r))
    }

    func testCancelledProviderSuccessIsDiscarded() async {
        let s = setup(route("1")), server = a
        let task = Task {
            try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:], accounts: ["fake": "acc"], last: [:]) { _ in
                Fake(best: [server], cancelBeforeReturning: true)
            }
        }
        do { _ = try await task.value; XCTFail("A cancelled lookup returned a usable tunnel") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testOfflinePickingKeepsTrustedLinksAndBlocksMissingRoutesWithoutCallingProviders() async throws {
        let s = setup(route("1"), route("2", "DE"))
        let result = try await LinkPicker.pick(s, keep: ["1": link(a)], applied: s, appliedAccounts: ["fake": "acc"],
            accounts: ["fake": "acc"], last: [:], offline: true) { _ in Fake(best: [], failIfCalled: true) }
        XCTAssertEqual(result.links["1"]?.server, a)
        XCTAssertEqual(result.blocked, ["2": .waiting])
    }

    /// A kept tunnel on a server the provider's latest list no longer suits (Mullvad's owned-only setting) isn't kept;
    /// a pinned route's server always stays.
    func testKeptLinkOnAServerThatNoLongerSuitsIsNotKept() async throws {
        let s = setup(route("1")), a = self.a
        let run: (Setup, Bool) async throws -> LinkPicker.Result = { s, suits in
            try await LinkPicker.pick(s, keep: ["1": link(a)], applied: s, appliedAccounts: ["fake": "acc"],
                accounts: ["fake": "acc"], last: [:], offline: true) { _ in Fake(best: [], failIfCalled: true, suitsServer: suits) }
        }
        let kept = try await run(s, true)
        XCTAssertEqual(kept.links["1"]?.server, a)
        let dropped = try await run(s, false)
        XCTAssertTrue(dropped.links.isEmpty)
        XCTAssertEqual(dropped.blocked["1"], .waiting)
        let pinned = setup(route("1", pinned: a))
        let stays = try await run(pinned, false)
        XCTAssertEqual(stays.links["1"]?.server, a)
    }

    func testOfflinePickingUsesOnlyTheCurrentAccountsTrustedCache() async throws {
        let r = route("1"), s = setup(r)
        let cache = [LinkPicker.cacheKey(r, account: "acc"): link(a)]
        for (account, trusted, expected) in [("acc", true, true), ("other", true, false), ("acc", false, false)] {
            let result = try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:],
                accounts: ["fake": account], last: cache, offline: true) { _ in Fake(best: [], trusted: trusted, failIfCalled: true) }
            XCTAssertEqual(result.links["1"] != nil, expected)
            XCTAssertEqual(result.blocked["1"], expected ? nil : .waiting)
        }
    }

    func testOfflinePickingDropsSignedOutAndRefusedAccountsEvenWithKeptAndCachedLinks() async throws {
        let r = route("1"), s = setup(r)
        let cache = [LinkPicker.cacheKey(r, account: "acc"): link(a)]
        for accounts in [[:], ["fake": "acc"]] {
            let result = try await LinkPicker.pick(s, keep: ["1": link(a)], applied: s, appliedAccounts: ["fake": "acc"],
                accounts: accounts, last: cache, refused: accounts.isEmpty ? [:] : ["fake": .removed("Fake")],
                offline: true) { _ in Fake(best: [], failIfCalled: true) }
            XCTAssertTrue(result.links.isEmpty)
            XCTAssertTrue(result.remember.isEmpty)
            XCTAssertEqual(result.blocked["1"], accounts.isEmpty ? .signedOut("Fake") : .removed("Fake"))
        }
    }

    func testOfflinePickingDoesNotKeepAChangedLocationOrAccount() async throws {
        let s = setup(route("1"))
        for (previous, account) in [(setup(route("1", "DE")), "acc"), (s, "other")] {
            let result = try await LinkPicker.pick(s, keep: ["1": link(a)], applied: previous, appliedAccounts: ["fake": account],
                accounts: ["fake": "acc"], last: [:], offline: true) { _ in Fake(best: [], failIfCalled: true) }
            XCTAssertTrue(result.links.isEmpty)
            XCTAssertEqual(result.blocked["1"], .waiting)
        }
    }

    func testOfflineCacheHonorsAvoidancePinsAndDialability() async throws {
        for (r, cached, expected) in [(route("1"), link(a), false), (route("1", pinned: a), link(a), true),
                                     (route("1", pinned: a), link(server("bad", ip: "")), false)] {
            let result = try await LinkPicker.pick(setup(r), keep: [:], applied: nil, appliedAccounts: [:], accounts: ["fake": "acc"],
                last: [LinkPicker.cacheKey(r, account: "acc"): cached], avoid: [LinkPicker.serverKey(r, link(a))],
                offline: true) { _ in Fake(best: [], failIfCalled: true) }
            XCTAssertEqual(result.links["1"] != nil, expected)
        }
        let pinned = route("1", pinned: b)
        let result = try await LinkPicker.pick(setup(pinned), keep: [:], applied: nil, appliedAccounts: [:], accounts: ["fake": "acc"],
            last: [LinkPicker.cacheKey(route("1", pinned: a), account: "acc"): link(a)],
            offline: true) { _ in Fake(best: [], failIfCalled: true) }
        XCTAssertEqual(result.blocked["1"], .waiting)
    }

    func testOfflineOwnedOnlyDoesNotUseUnverifiedCache() async throws {
        let r = Route(id: "1", loc: Location(provider: "mullvad"))
        var s = setup(r)
        s.opts = ["mullvad": ["owned": "on"]]
        let result = try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:], accounts: ["mullvad": "acc"],
            last: [LinkPicker.cacheKey(r, account: "acc"): link(a)], offline: true) { _ in Fake(best: [], failIfCalled: true, id: "mullvad") }
        XCTAssertEqual(result.blocked["1"], .waiting)
    }

    /// Turning "Mullvad-owned servers only" on stops a running unpinned Mullvad route at once: the interim pick runs, and
    /// it holds the route (its kept tunnel may be on a rented server) until an owned one is found.
    func testOwnedOnlyTurnedOnStopsARunningRouteAtOnce() async throws {
        let r = Route(id: "1", loc: Location(provider: "mullvad", countryCode: "SE"))
        let before = setup(r)
        var after = before
        after.opts = ["mullvad": ["owned": "on"]]
        XCTAssertTrue(LinkPicker.needsInterim(from: before, to: after))
        XCTAssertFalse(LinkPicker.needsInterim(from: after, to: after))
        XCTAssertFalse(LinkPicker.needsInterim(from: after, to: before))
        let interim = try await LinkPicker.pick(after, keep: ["1": link(a)], applied: before, appliedAccounts: ["mullvad": "acc"],
            accounts: ["mullvad": "acc"], last: [LinkPicker.cacheKey(r, account: "acc"): link(a)], offline: true) { _ in
            Fake(best: [], failIfCalled: true, id: "mullvad")
        }
        XCTAssertEqual(interim.blocked["1"], .waiting)
        // A pinned route keeps its server: the owner chose it.
        var pinned = before
        pinned.routes[0].loc.pinned = a
        var pinnedAfter = pinned
        pinnedAfter.opts = after.opts
        XCTAssertFalse(LinkPicker.needsInterim(from: pinned, to: pinnedAfter))
    }

    /// IVPN's Disguise: on, a route never runs plain. A server with V2Ray data gets the hop and its WireGuard port; one without
    /// is held back with the reason; turning it on stops a running plain tunnel at once.
    func testDisguiseNeverRunsAPlainTunnel() async throws {
        let a = self.a
        let r = Route(id: "1", loc: Location(provider: "ivpn", countryCode: "NL"))
        let off = self.setup(r)
        var on = off
        on.opts = ["ivpn": ["disguise": "on"]]
        let vmess = Vmess(server: "149.22.83.102", port: 80, uuid: "27de860d-5601-412d-8b71-baa048a94b98")
        let data = Disguise(vmess: vmess, wgPort: 15351)
        // Turned on: the interim pick runs; turned off, or already on, it doesn't.
        XCTAssertTrue(LinkPicker.needsInterim(from: off, to: on))
        XCTAssertFalse(LinkPicker.needsInterim(from: on, to: on))
        XCTAssertFalse(LinkPicker.needsInterim(from: on, to: off))
        var pinned = off
        pinned.routes[0].loc.pinned = a
        var pinnedOn = pinned
        pinnedOn.opts = on.opts
        XCTAssertTrue(LinkPicker.needsInterim(from: pinned, to: pinnedOn), "a pinned server's tunnel is plain too")
        var imported = off
        imported.routes = [Route(id: "1", wg: WgPeer(name: "mine", privateKey: "p", address: [], publicKey: "k", endpoint: "1.2.3.4:51820", allowedIps: []))]
        var importedOn = imported
        importedOn.opts = on.opts
        XCTAssertFalse(LinkPicker.needsInterim(from: imported, to: importedOn))
        func run(_ s: Setup, keep: [String: Link] = [:], offline: Bool = false, _ p: Fake) async throws -> LinkPicker.Result {
            try await LinkPicker.pick(s, keep: keep, applied: off, appliedAccounts: ["ivpn": "acc"], accounts: ["ivpn": "acc"],
                                      last: [LinkPicker.cacheKey(r, account: "acc"): link(a)], offline: offline) { _ in p }
        }
        // A server without V2Ray data: blocked, never connected plain.
        let none = try await run(on, Fake(best: [a], id: "ivpn"))
        XCTAssertTrue(none.links.isEmpty)
        XCTAssertEqual(none.blocked["1"], .unreachable("a can't be reached through V2Ray right now. Pick another server, or turn Disguise off on the Fake page"))
        let plainOk = try await run(off, Fake(best: [a], id: "ivpn"))
        XCTAssertEqual(plainOk.links.count, 1)
        // With data: the hop, the server's own WireGuard port behind it, the small packet size.
        let ok = try await run(on, Fake(best: [a], disguise: data, id: "ivpn"))
        guard case .wg(_, let peer, _, _)? = ok.links["1"] else { return XCTFail("no tunnel") }
        XCTAssertEqual(peer.vmess, vmess)
        XCTAssertEqual(peer.endpoint, "\(a.ip):15351")
        XCTAssertEqual(peer.mtu, 1280)
        XCTAssertNil(ok.blocked["1"])
        // Off again: the same tunnel is plain, on its usual port.
        guard case .wg(_, let back, _, _)? = LinkPicker.ported(off, ok.links, step: [:])["1"] else { return XCTFail("no tunnel") }
        XCTAssertNil(back.vmess)
        XCTAssertEqual(back.endpoint, "\(a.ip):\(Ivpn.port)")
        // The interim pick (offline): a kept tunnel without data stops, one with it is re-made as the hop.
        let plain = try await run(on, keep: ["1": link(a)], offline: true, Fake(best: [], failIfCalled: true, id: "ivpn"))
        XCTAssertTrue(plain.links.isEmpty)
        XCTAssertEqual(plain.blocked["1"], .waiting)
        guard case .wg(let s0, var p0, let ports, let entries) = link(a) else { return XCTFail() }
        p0.disguise = data
        let kept = try await run(on, keep: ["1": .wg(s0, p0, ports: ports, entries: entries)], offline: true, Fake(best: [], failIfCalled: true, id: "ivpn"))
        guard case .wg(_, let again, _, _)? = kept.links["1"] else { return XCTFail("a kept disguised tunnel stands") }
        XCTAssertEqual(again.vmess, vmess)
    }

    /// A pinned IVPN route with Disguise on while the provider can't be reached: its saved disguised tunnel stands in, a plain
    /// one never does.
    func testPinnedDisguiseOutageUsesOnlyADisguisedCachedTunnel() async throws {
        let a = self.a
        var r = Route(id: "1", loc: Location(provider: "ivpn", countryCode: "NL"))
        r.loc.pinned = a
        var on = setup(r)
        on.opts = ["ivpn": ["disguise": "on"]]
        let data = Disguise(vmess: Vmess(server: "149.22.83.102", port: 80, uuid: "27de860d-5601-412d-8b71-baa048a94b98"), wgPort: 15351)
        guard case .wg(let s0, var p0, let ports, let entries) = link(a) else { return XCTFail() }
        p0.disguise = data
        let disguised = Link.wg(s0, p0, ports: ports, entries: entries)
        func run(_ cached: Link) async throws -> LinkPicker.Result {
            try await LinkPicker.pick(on, keep: [:], applied: nil, appliedAccounts: [:], accounts: ["ivpn": "acc"],
                                      last: [LinkPicker.cacheKey(r, account: "acc"): cached]) { _ in Fake(best: [a], online: false, id: "ivpn") }
        }
        let ok = try await run(disguised)
        guard case .wg(_, let peer, _, _)? = ok.links["1"] else { return XCTFail("the cached disguised tunnel stands in") }
        XCTAssertNotNil(peer.disguise)
        XCTAssertNil(ok.blocked["1"])
        let plain = try await run(link(a))
        XCTAssertTrue(plain.links.isEmpty, "a plain cached tunnel never stands in under Disguise")
        XCTAssertNotNil(plain.blocked["1"])
    }

    func testOfflineImportsStillApplyPortsAndBlockClashes() async throws {
        guard case .wg(_, var peer, _, _) = link(a) else { return XCTFail() }
        peer.mtu = 1280
        let first = Route(id: "1", wg: peer)
        peer.mtu = 1200
        let s = setup(first, Route(id: "2", wg: peer))
        let result = try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:], accounts: [:], last: [:], offline: true) { _ in
            XCTFail("Imports do not need providers"); return nil
        }
        XCTAssertNotNil(result.links["1"])
        XCTAssertEqual(result.blocked["2"], .clash)
    }

    func testInterimDetectsAppsLeavingDirectExplicitlyAndByDefault() {
        let direct = Setup(routes: [route("v")], defaultRoute: DIRECT, apps: ["a": "v"])
        var moved = direct; moved.apps["b"] = "v"
        XCTAssertTrue(LinkPicker.needsInterim(from: direct, to: moved))
        var vpn = direct; vpn.defaultRoute = "v"; vpn.apps = ["b": DIRECT]
        moved = vpn; moved.apps = [:]
        XCTAssertTrue(LinkPicker.needsInterim(from: vpn, to: moved))
        moved = direct; moved.defaultRoute = "v"
        XCTAssertTrue(LinkPicker.needsInterim(from: direct, to: moved))
        XCTAssertFalse(LinkPicker.needsInterim(from: nil, to: moved))
        XCTAssertFalse(LinkPicker.needsInterim(from: direct, to: direct))
    }

    func testInterimDetectsNewBlocksAndRevocationButSkipsOrdinaryEdits() {
        let old = setup(route("1"), route("2", "DE"))
        var changed = old; changed.apps["blocked"] = BLOCK
        XCTAssertTrue(LinkPicker.needsInterim(from: old, to: changed))
        changed = old; changed.defaultRoute = BLOCK
        XCTAssertTrue(LinkPicker.needsInterim(from: old, to: changed))
        var blockedDefault = changed; blockedDefault.apps["excepted"] = DIRECT
        XCTAssertTrue(LinkPicker.needsInterim(from: blockedDefault, to: changed))
        XCTAssertTrue(LinkPicker.needsInterim(from: old, to: old, revoking: true))
        changed = old; changed.apps["app.2"] = "1"
        XCTAssertFalse(LinkPicker.needsInterim(from: old, to: changed))
        changed = old; changed.routes[0].loc.countryCode = "DE"
        XCTAssertFalse(LinkPicker.needsInterim(from: old, to: changed))
        changed = old; changed.apps["app.2"] = DIRECT
        XCTAssertFalse(LinkPicker.needsInterim(from: old, to: changed))
        changed = old; changed.apps["blocked"] = BLOCK
        XCTAssertFalse(LinkPicker.needsInterim(from: changed, to: old))
    }

    func testDeferredBlockedRouteIsNotLookedUp() async throws {
        let s = setup(route("1"), route("2", "DE"))
        let reason = LinkPicker.Blocked.unreachable("down")
        let result = try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:], accounts: ["fake": "acc"], last: [:], deferred: ["2": reason]) { _ in Fake(best: [self.a]) }
        XCTAssertNotNil(result.links["1"])
        XCTAssertNil(result.links["2"])
        XCTAssertEqual(result.blocked["2"], reason)
    }

    func testUnpinnedCollisionMovesToAnotherServerByIpNotHostname() async throws {
        let r = try await pick(setup(route("1"), route("2", "DE")), Fake(best: [a, b]))
        XCTAssertEqual(r["1"]?.server.name, "a")
        XCTAssertEqual(r["2"]?.server.name, "bb")
    }

    func testFailingServerIsAvoidedButPinStays() async throws {
        let movable = route("1"), pinned = route("2", "DE", pinned: a)
        let s = setup(movable, pinned), key = LinkPicker.serverKey(movable, link(a))
        let result = try await LinkPicker.pick(s, keep: ["1": link(a), "2": link(a)], applied: s,
            appliedAccounts: ["fake": "acc"], accounts: ["fake": "acc"], last: [:], avoid: [key]) { _ in Fake(best: [self.a, self.b]) }
        XCTAssertEqual(result.links["1"]?.server, b)
        XCTAssertEqual(result.links["2"]?.server, a)
    }

    func testRemovedProviderBlocksAllRoutes() async throws {
        let s = setup(route("1"), route("2", "DE"))
        let removed = LinkPicker.Blocked.removed("Fake")
        let result = try await LinkPicker.pick(s, keep: ["1": link(a)], applied: s, appliedAccounts: ["fake": "acc"],
            accounts: ["fake": "acc"], last: [:], refused: ["fake": removed]) { _ in Fake(best: [self.a]) }
        XCTAssertTrue(result.links.isEmpty)
        XCTAssertEqual(result.blocked, ["1": removed, "2": removed])
        XCTAssertEqual(removed.text, "Fake no longer has this Mac. Sign in again.")
    }

    func testPinnedCollisionSharesTheServer() async throws {
        let r = try await pick(setup(route("1", pinned: a), route("2", "DE", pinned: a)), Fake(best: [a, b]))
        XCTAssertEqual(r["1"]?.server, a)
        XCTAssertEqual(r["2"]?.server, a)
    }

    func testPinnedRouteNeverFallsBackToAnotherServer() async throws {
        let r = route("1", pinned: a)
        let other = [LinkPicker.cacheKey(route("x", pinned: b), account: "acc"): link(b)]
        let failed = try await LinkPicker.pick(setup(r), keep: [:], applied: nil, appliedAccounts: [:], accounts: ["fake": "acc"], last: other) { _ in Fake(best: [a], online: false) }
        XCTAssertNil(failed.links["1"])
        XCTAssertEqual(failed.blocked["1"], .unreachable("can't reach its servers right now"))
        let same = [LinkPicker.cacheKey(r, account: "acc"): link(a)]
        let picked = try await pick(setup(r), Fake(best: [a], online: false), last: same)
        XCTAssertEqual(picked["1"]?.server, a)
    }

    func testTunnelsWithoutAnAddressAreNeverPicked() async throws {
        let r = route("1"), nowhere = server("a", ip: "")
        let cached = try await LinkPicker.pick(setup(r), keep: [:], applied: nil, appliedAccounts: [:], accounts: ["fake": "acc"], last: [LinkPicker.cacheKey(r, account: "acc"): link(nowhere)]) { _ in Fake(best: [a], online: false) }
        XCTAssertNil(cached.links["1"])
        XCTAssertNotNil(cached.blocked["1"])
        let kept = try await LinkPicker.pick(setup(r), keep: ["1": link(nowhere)], applied: setup(r), appliedAccounts: ["fake": "acc"], accounts: ["fake": "acc"], last: [:]) { _ in Fake(best: [a]) }
        XCTAssertEqual(kept.links["1"]?.server, a)
        let invalid = try await LinkPicker.pick(setup(r), keep: [:], applied: nil, appliedAccounts: [:], accounts: ["fake": "acc"], last: [:]) { _ in Fake(best: [nowhere]) }
        XCTAssertNil(invalid.links["1"])
        XCTAssertNotNil(invalid.blocked["1"])
        XCTAssertFalse(LinkPicker.dialable(link(nowhere)))
    }

    func testUnpinnedRouteMayUseTheLastGoodTunnel() async throws {
        let r = route("1")
        let picked = try await pick(setup(r), Fake(best: [a], online: false), last: [LinkPicker.cacheKey(r, account: "acc"): link(a)])
        XCTAssertEqual(picked["1"]?.server, a)
    }

    func testAnUntrustedCachedTunnelIsNotReused() async throws {
        let r = route("1")
        let picked = try await LinkPicker.pick(setup(r), keep: [:], applied: nil, appliedAccounts: [:], accounts: ["fake": "acc"], last: [LinkPicker.cacheKey(r, account: "acc"): link(a)]) { _ in Fake(best: [a], online: false, trusted: false) }
        XCTAssertNil(picked.links["1"])
        XCTAssertNotNil(picked.blocked["1"])
    }

    func testAnUntrustedKeptTunnelIsReplaced() async throws {
        let r = route("1")
        let s = setup(r)
        let accounts = ["fake": "acc"]
        let keep = ["1": link(b)]
        let trusted = Fake(best: [a], trusted: true)
        let kept = try await LinkPicker.pick(s, keep: keep, applied: s, appliedAccounts: accounts, accounts: accounts, last: [:]) { _ in trusted }
        XCTAssertEqual(kept.links["1"]?.server, b)
        let untrusted = Fake(best: [a], trusted: false)
        let replaced = try await LinkPicker.pick(s, keep: keep, applied: s, appliedAccounts: accounts, accounts: accounts, last: [:]) { _ in untrusted }
        XCTAssertEqual(replaced.links["1"]?.server, a)
    }

    /// A taken-over tunnel's record says which accounts its links were made with: only those are kept.
    func testAKeptTunnelNeedsTheAccountItWasMadeWith() async throws {
        let s = setup(route("1"))
        let keep = ["1": link(b)]
        let p = Fake(best: [a])
        let same = try await LinkPicker.pick(s, keep: keep, applied: s, appliedAccounts: ["fake": "acc"], accounts: ["fake": "acc"], last: [:]) { _ in p }
        XCTAssertEqual(same.links["1"]?.server, b)
        let other = try await LinkPicker.pick(s, keep: keep, applied: s, appliedAccounts: [:], accounts: ["fake": "acc"], last: [:]) { _ in p }
        XCTAssertEqual(other.links["1"]?.server, a)
    }

    /// No account on either side is no match: a signed-out account's tunnel is never kept (and `trusts` vouches for a
    /// server, not for the credentials in its tunnel).
    func testASignedOutAccountsTunnelIsNeverKept() async throws {
        let s = setup(route("1"))
        let signedOut = try await LinkPicker.pick(s, keep: ["1": link(b)], applied: s, appliedAccounts: [:], accounts: [:], last: [:]) { _ in Fake(best: [a]) }
        XCTAssertNil(signedOut.links["1"])
        XCTAssertEqual(signedOut.blocked["1"], .signedOut("Fake"))
        let unknown = try await LinkPicker.pick(s, keep: ["1": link(b)], applied: s, appliedAccounts: ["fake": "acc"], accounts: ["fake": "acc"], last: [:]) { _ in nil }
        XCTAssertNil(unknown.links["1"])
        XCTAssertNotNil(unknown.blocked["1"])
    }

    func testPinnedAndUnpinnedHaveDifferentCacheKeys() {
        let loc = Location(provider: "fake", countryCode: "NL")
        func key(_ l: Location) -> String { LinkPicker.cacheKey(Route(id: "1", loc: l), account: "acc") }
        var pinnedA = loc; pinnedA.pinned = a
        var pinnedB = loc; pinnedB.pinned = b
        XCTAssertNotEqual(key(loc), key(pinnedA))
        XCTAssertNotEqual(key(pinnedA), key(pinnedB))
        // Stable between calls: it is stored with the cached tunnel.
        XCTAssertEqual(key(pinnedA), key(pinnedA))
        // Another account of the same provider has its own cache; the provider still leads the key (sign-out prunes by it).
        XCTAssertNotEqual(key(loc), LinkPicker.cacheKey(Route(id: "1", loc: loc), account: "other"))
        XCTAssertTrue(key(loc).hasPrefix("fake|"))
        // The account part is the start of its fingerprint (shared with the running record), as earlier builds wrote it.
        XCTAssertTrue(key(loc).hasPrefix("fake|@414322309db5c06d|"))
        XCTAssertTrue(Running.fingerprint("acc").hasPrefix("414322309db5c06d"))
    }

    func testDeadServerIsAvoided() async throws {
        let r = route("1")
        let dead = LinkPicker.serverKey(r, link(a))
        let p = Fake(best: [a, b])
        let picked = try await LinkPicker.pick(setup(r), keep: [:], applied: nil, appliedAccounts: [:], accounts: ["fake": "acc"], last: [:], avoid: [dead]) { _ in p }
        XCTAssertEqual(picked.links["1"]?.server.name, "bb")
    }

    func testSignedOutProviderFails() async throws {
        let picked = try await LinkPicker.pick(setup(route("1")), keep: [:], applied: nil, appliedAccounts: [:], accounts: [:], last: [:]) { _ in Fake(best: [a]) }
        XCTAssertEqual(picked.blocked["1"], .signedOut("Fake"))
        XCTAssertTrue(picked.links.isEmpty)
    }

    func testRememberHoldsProviderRoutesOnly() async throws {
        let wg = WgPeer(name: "Home", privateKey: "k", address: ["10.0.0.2/32"], publicKey: "p", endpoint: "[::1]:51820", allowedIps: ["0.0.0.0/0"])
        let s = setup(route("1"), Route(id: "2", wg: wg))
        let r = try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:], accounts: ["fake": "acc"], last: [:]) { _ in Fake(best: [a]) }
        XCTAssertEqual(Set(r.remember.keys), [LinkPicker.cacheKey(route("1"), account: "acc")])
        XCTAssertEqual(r.links["2"]?.server.host, "[::1]")
    }

    /// A connect that finishes after its provider was signed out, or signed in to another account, caches nothing.
    /// Routes in use whose provider is signed out are named together, before any provider is asked; unused ones and
    /// imported routes don't count.
    func testSignedOutProvidersAreNamedBeforeAnyConnect() async throws {
        let s = setup(route("1"), route("2", "DE"))
        let picked = try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:], accounts: [:], last: [:]) { _ in Fake(best: []) }
        XCTAssertEqual(picked.blocked, ["1": .signedOut("Fake"), "2": .signedOut("Fake")])
    }

    func testAnotherAccountsCachedTunnelIsNotAFallback() async throws {
        let r = route("1")
        let picked = try await LinkPicker.pick(setup(r), keep: [:], applied: nil, appliedAccounts: [:], accounts: ["fake": "new"], last: [LinkPicker.cacheKey(r, account: "old"): link(a)]) { _ in Fake(best: [a], online: false) }
        XCTAssertNil(picked.links["1"])
        XCTAssertNotNil(picked.blocked["1"])
    }

    func testClashingImportBlocksOnlyTheLaterRoute() async throws {
        guard case .wg(_, let peer, _, _) = link(a) else { return XCTFail("expected WireGuard") }
        var changed = peer
        changed.mtu = 1200
        let s = setup(Route(id: "1", wg: peer), Route(id: "2", wg: changed))
        let result = try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:], accounts: [:], last: [:]) { _ in nil }
        XCTAssertNotNil(result.links["1"])
        XCTAssertNil(result.links["2"])
        XCTAssertEqual(result.blocked["2"], .clash)
    }

    func testSignedOutRouteDoesNotStopImportedRoute() async throws {
        guard case .wg(_, let peer, _, _) = link(a) else { return XCTFail("expected WireGuard") }
        let s = setup(route("1"), Route(id: "2", wg: peer))
        let result = try await LinkPicker.pick(s, keep: [:], applied: nil, appliedAccounts: [:], accounts: [:], last: [:]) { _ in Fake(best: [a]) }
        XCTAssertEqual(result.blocked["1"], .signedOut("Fake"))
        XCTAssertNotNil(result.links["2"])
    }

    func testRefusalBlocksKeptRoutesAndCachedCredentials() async throws {
        struct Refusing: Provider {
            let id = "fake", name = "Fake", fields: [Field] = [], help = ""
            func signIn(_ input: [String: String]) async throws -> String { "" }
            func countries(_ account: String) async throws -> [Country] { [] }
            func connect(_ loc: Location, _ account: String) async throws -> Link { throw AuthError("refused") }
            func trusts(_ link: Link, _ account: String) -> Bool { true }
        }
        let first = route("1"), second = route("2", "DE"), s = setup(first, second)
        let result = try await LinkPicker.pick(s, keep: ["1": link(a)], applied: s, appliedAccounts: ["fake": "acc"], accounts: ["fake": "acc"], last: [LinkPicker.cacheKey(second, account: "acc"): link(a)]) { _ in Refusing() }
        XCTAssertTrue(result.links.isEmpty)
        XCTAssertTrue(result.remember.isEmpty)
        XCTAssertEqual(result.blocked["1"], .refused("Fake", "refused"))
        XCTAssertEqual(result.blocked["2"], .refused("Fake", "refused"))
        let held = try await LinkPicker.pick(s, keep: ["1": link(a)], applied: s, appliedAccounts: ["fake": "acc"], accounts: ["fake": "acc"], last: [LinkPicker.cacheKey(second, account: "acc"): link(a)], refused: ["fake": .refused("Fake", "refused")]) { _ in Fake(best: [a], online: false) }
        XCTAssertTrue(held.links.isEmpty)
        XCTAssertEqual(held.blocked.count, 2)
    }

    @MainActor func testTunnelsOfAReplacedAccountAreNotCached() {
        let a = link(server("a", ip: "1.2.3.4")), b = link(server("b", ip: "1.2.3.5"))
        let add = ["fake|x|": a, "other|y|": b]
        XCTAssertEqual(Store.current(add, made: ["fake": "A", "other": "O"], now: ["fake": "A", "other": "O"]), add)
        XCTAssertEqual(Store.current(add, made: ["fake": "A", "other": "O"], now: ["fake": "B", "other": "O"]), ["other|y|": b])
        XCTAssertEqual(Store.current(add, made: ["fake": "A", "other": "O"], now: ["other": "O"]), ["other|y|": b])
        XCTAssertEqual(Store.current(add, made: [:], now: ["fake": "A"]), [:])
    }
}

extension LinkPickerTests {
    func testProviderSettingsAndOldCache() throws {
        let server = Server(name: "x", host: "x", ip: "198.51.100.1", publicKey: "key", load: 0)
        let peer = WgPeer(name: "x", privateKey: "k", address: ["10.0.0.2/32"], publicKey: "key", endpoint: "198.51.100.1:51820", allowedIps: ["0.0.0.0/0"])
        let route = Route(id: "r", loc: Location(provider: "mullvad"))
        var setup = Setup(routes: [route], defaultRoute: "r")
        setup.opts["mullvad"] = ["mtu": "1400"]
        let link = Link.wg(server, peer, ports: [51820, 443])
        guard case .wg(_, let result, _, _) = LinkPicker.ported(setup, ["r": link], step: [LinkPicker.serverKey(route, link): 1])["r"] else { return XCTFail("missing link") }
        XCTAssertEqual(result.endpoint, "198.51.100.1:443")
        XCTAssertEqual(result.mtu, 1400)
        setup.opts["mullvad"]?["mtu"] = "9000"
        XCTAssertEqual(setup.opt("mullvad", "mtu"), "auto")
        XCTAssertNil(setup.opt("mullvad", "unknown"))
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(link)) as? [String: Any])
        var wg = try XCTUnwrap(encoded["wg"] as? [String: Any])
        wg.removeValue(forKey: "ports"); wg.removeValue(forKey: "entries"); encoded["wg"] = wg
        let decoded = try JSONDecoder().decode(Link.self, from: JSONSerialization.data(withJSONObject: encoded))
        guard case .wg(_, _, let ports, let entries) = decoded else { return XCTFail("missing link") }
        XCTAssertTrue(ports.isEmpty); XCTAssertTrue(entries.isEmpty)
    }

    func testPortStepsArePerTunnel() {
        func link(_ ip: String) -> Link {
            .wg(Server(name: ip, host: ip, ip: ip, publicKey: "key", load: 0),
                WgPeer(name: ip, privateKey: "k", address: ["10.0.0.2/32"], publicKey: "key", endpoint: "\(ip):51820", allowedIps: ["0.0.0.0/0"]),
                ports: [51820, 443, 80])
        }
        let setup = Setup(routes: [Route(id: "a", loc: Location(provider: "mullvad")), Route(id: "b", loc: Location(provider: "mullvad")),
                                   Route(id: "c", loc: Location(provider: "mullvad"))], defaultRoute: "a")
        let links = ["a": link("198.51.100.1"), "b": link("198.51.100.1"), "c": link("198.51.100.2")]
        func endpoints(_ step: [String: Int]) -> [String] {
            LinkPicker.ported(setup, links, step: step).sorted { $0.key < $1.key }.compactMap { if case .wg(_, let p, _, _) = $0.value { p.endpoint } else { nil } }
        }
        func key(_ id: String) -> String { LinkPicker.serverKey(setup.route(id)!, links[id]!) }
        XCTAssertEqual(endpoints([:]), ["198.51.100.1:51820", "198.51.100.1:51820", "198.51.100.2:51820"])
        // Routes on one server step together (never two ports for one server); another server keeps its port; a step past the list wraps.
        XCTAssertEqual(key("a"), key("b")); XCTAssertNotEqual(key("a"), key("c"))
        XCTAssertEqual(endpoints([key("a"): 1]), ["198.51.100.1:443", "198.51.100.1:443", "198.51.100.2:51820"])
        XCTAssertEqual(endpoints([key("a"): 1, key("c"): 5]), ["198.51.100.1:443", "198.51.100.1:443", "198.51.100.2:80"])
        // A route moved to another provider has another key, so it starts from the first port.
        var moved = setup
        moved.routes[0] = Route(id: "a", loc: Location(provider: "ivpn"))
        XCTAssertNotEqual(LinkPicker.serverKey(moved.route("a")!, links["a"]!), key("a"))
        guard case .wg(_, let p, _, _)? = LinkPicker.ported(moved, links, step: [key("a"): 1])["a"] else { return XCTFail("no tunnel") }
        XCTAssertEqual(p.endpoint, "198.51.100.1:51820")
    }

    /// A dead route the health round moves to another server takes its port step along: the new server goes on from the
    /// port the route had reached, not from the first one again; the other routes keep their own servers' steps.
    func testAMovedRouteCarriesItsPortStep() {
        func link(_ ip: String) -> Link {
            .wg(Server(name: ip, host: ip, ip: ip, publicKey: "key", load: 0),
                WgPeer(name: ip, privateKey: "k", address: ["10.0.0.2/32"], publicKey: "key", endpoint: "\(ip):51820", allowedIps: ["0.0.0.0/0"]),
                ports: [51820, 443, 80])
        }
        let setup = Setup(routes: [Route(id: "a", loc: Location(provider: "mullvad")), Route(id: "c", loc: Location(provider: "mullvad"))], defaultRoute: "a")
        let a = setup.route("a")!, c = setup.route("c")!
        // Route a reached the third port on 198.51.100.1, then moved to 198.51.100.3.
        let step = [LinkPicker.serverKey(a, link("198.51.100.1")): 2, LinkPicker.routeStepKey(a): 2]
        let links = ["a": link("198.51.100.3"), "c": link("198.51.100.2")]
        let out = LinkPicker.ported(setup, links, step: step)
        guard case .wg(_, let pa, _, _)? = out["a"], case .wg(_, let pc, _, _)? = out["c"] else { return XCTFail("no tunnel") }
        XCTAssertEqual(pa.endpoint, "198.51.100.3:80")
        XCTAssertEqual(pc.endpoint, "198.51.100.2:51820")
        // The larger of the server's and the route's steps counts.
        let s3 = LinkPicker.serverKey(a, link("198.51.100.3"))
        XCTAssertEqual(LinkPicker.steps(setup, links, step: [s3: 1, LinkPicker.routeStepKey(a): 2])["a"], 2)
        XCTAssertEqual(LinkPicker.steps(setup, links, step: [s3: 3, LinkPicker.routeStepKey(a): 2])["a"], 3)
        XCTAssertEqual(LinkPicker.steps(setup, links, step: step)["c"], 0)
        // Automatic gives up on WireGuard once the carried step has been through every port.
        XCTAssertTrue(AutoProtocol.exhausted(ports: 3, canStep: true, step: LinkPicker.steps(setup, links, step: step)["a"] ?? 0))

        // Moved onto a server another route already uses: both take that server's step, one port for one server (two
        // would clash and block one), and the route already there shows that port works on this network.
        let both = ["a": link("198.51.100.2"), "c": link("198.51.100.2")]
        let shared = LinkPicker.ported(setup, both, step: step)
        guard case .wg(_, let sa, _, _)? = shared["a"], case .wg(_, let sc, _, _)? = shared["c"] else { return XCTFail("no tunnel") }
        XCTAssertEqual(sa.endpoint, "198.51.100.2:51820")
        XCTAssertEqual(sc.endpoint, "198.51.100.2:51820")
        XCTAssertTrue(Compiler.clashes(setup, shared).isEmpty)

        // A route the user sends to another provider or place starts from the first port: the carried step was its old one's.
        var edited = setup
        edited.routes[0] = Route(id: "a", loc: Location(provider: "mullvad", countryId: 153, countryCode: "NL", country: "Netherlands"))
        XCTAssertNotEqual(LinkPicker.routeStepKey(edited.route("a")!), LinkPicker.routeStepKey(a))
        XCTAssertEqual(LinkPicker.steps(edited, links, step: step)["a"], 0)
    }

    func testIvpnFixedPortCanBeOutsideAutomaticFallbacks() {
        let server = Server(name: "x", host: "x", ip: "1.2.3.4", publicKey: "key", load: 0)
        let peer = WgPeer(name: "x", privateKey: "k", address: ["10.0.0.2/32"], publicKey: "key", endpoint: "1.2.3.4:2049", allowedIps: ["0.0.0.0/0"])
        let route = Route(id: "r", loc: Location(provider: "ivpn"))
        var setup = Setup(routes: [route], defaultRoute: "r")
        setup.opts["ivpn"] = ["port": "9999"]
        let link = Link.wg(server, peer, ports: [2049, 443])
        guard case .wg(_, let result, _, _) = LinkPicker.ported(setup, ["r": link], step: [LinkPicker.serverKey(route, link): 1])["r"] else { return XCTFail("missing link") }
        XCTAssertEqual(result.endpoint, "1.2.3.4:9999")
    }

    func testProviderAndImportedMtuAndIdentity() {
        let server = Server(name: "x", host: "x", ip: "198.51.100.1", publicKey: "key", load: 0)
        let peer = WgPeer(name: "x", privateKey: "k", address: ["10.0.0.2/32"], publicKey: "key", endpoint: "198.51.100.1:51820", allowedIps: ["0.0.0.0/0"])
        let provider = Route(id: "p", loc: Location(provider: "mullvad"))
        let imported = Route(id: "i", wg: peer)
        var setup = Setup(routes: [provider, imported], defaultRoute: "p", apps: ["app": "i"])
        setup.opts["mullvad"] = ["mtu": "1400"]
        let links: [String: Link] = ["p": .wg(server, peer), "i": .wg(server, peer)]
        let effective = LinkPicker.ported(setup, links, step: [:])
        guard case .wg(_, let a, _, _) = effective["p"], case .wg(_, let b, _, _) = effective["i"] else { return XCTFail("missing links") }
        XCTAssertEqual(a.mtu, 1400); XCTAssertEqual(b.mtu, 1280)
        XCTAssertNotEqual(Compiler.linkKey(provider, effective["p"]!), Compiler.linkKey(imported, effective["i"]!))
    }

    func testBlockingMigrationPreservesOldDefaultsAndOverrides() throws {
        for nord in [true, false] {
            for custom in [false, true] {
                let json = """
                {"routes":[{"id":"n","loc":{"provider":"nord"},"filter":true},{"id":"m0","loc":{"provider":"mullvad"},"filter":false},{"id":"m1","loc":{"provider":"mullvad"},"filter":true}],"prefs":{"threatProtection":\(nord),"customDns":\(custom ? "[\"9.9.9.9\"]" : "[]")}}
                """
                let setup = try JSONDecoder().decode(Setup.self, from: Data(json.utf8))
                XCTAssertEqual(setup.opt("nord", "protect"), nord ? "on" : "off")
                XCTAssertNil(setup.routes[0].filter); XCTAssertNil(setup.routes[1].filter)
                XCTAssertEqual(setup.routes[2].filter, true)
                XCTAssertEqual(setup.protects(setup.routes[0]), nord)
                let roundTrip = try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(setup))
                XCTAssertEqual(roundTrip, setup)
            }
        }
    }
}

extension LinkPickerTests {
    func testOneKeyKeepsRecommendedServerUnlessAvoided() async throws {
        let route = route("1")
        let last = [LinkPicker.cacheKey(route, account: "acc"): link(b)]
        let provider = Fake(best: [a, b], oneKey: true)
        let kept = try await pick(setup(route), provider, last: last)
        XCTAssertEqual(kept["1"]?.server, b)
        let moved = try await LinkPicker.pick(setup(route), keep: [:], applied: nil, appliedAccounts: [:], accounts: ["fake": "acc"], last: last, avoid: [LinkPicker.serverKey(route, link(b))]) { _ in provider }
        XCTAssertEqual(moved.links["1"]?.server, a)
        let dropped = try await pick(setup(route), Fake(best: [a], oneKey: true), last: last)
        XCTAssertEqual(dropped["1"]?.server, a)
    }
}

extension LinkPickerTests {
    func testAvoidedCachedServerIsNotUsedDuringOutage() async throws {
        let r = route("1")
        let cached = [LinkPicker.cacheKey(r, account: "acc"): link(a)]
        let result = try await LinkPicker.pick(setup(r), keep: [:], applied: nil, appliedAccounts: [:], accounts: ["fake": "acc"], last: cached, avoid: [LinkPicker.serverKey(r, link(a))]) { _ in Fake(best: [a], online: false, oneKey: true) }
        XCTAssertNil(result.links["1"])
        XCTAssertNotNil(result.blocked["1"])
    }

    func testPiaBlockingOverridesSurviveRoundTrip() throws {
        let json = #"{"routes":[{"id":"a","loc":{"provider":"pia"},"filter":true},{"id":"b","loc":{"provider":"pia"},"filter":false}],"opts":{"pia":{"protect":"on"}}}"#
        let saved = try JSONDecoder().decode(Setup.self, from: Data(json.utf8))
        let restored = try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.routes.map(\.filter), [true, false])
        XCTAssertTrue(restored.protects(restored.routes[0]))
        XCTAssertFalse(restored.protects(restored.routes[1]))
        let legacy = #"{"routes":[{"id":"a","loc":{"provider":"pia"},"filter":true},{"id":"b","loc":{"provider":"pia"},"filter":false},{"id":"c","loc":{"provider":"pia"}}]}"#
        let migrated = try JSONDecoder().decode(Setup.self, from: Data(legacy.utf8))
        XCTAssertEqual(migrated.routes.map(\.filter), [true, false, nil])
    }
}
