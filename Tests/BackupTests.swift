import XCTest

/// What a backup holds, how it is checked before anything changes, and how a restore merges it into this Mac's setup.
final class BackupTests: XCTestCase {
    private let key = String(repeating: "A", count: 42) + "E="
    private let peerKey = String(repeating: "B", count: 42) + "E="
    private let psk = String(repeating: "C", count: 42) + "E="
    private let ovpnKeyLine = "0bouqAJuJcQZUX2Zdse5dO9p48oobiTCParVDzkP"

    private var wg: WgPeer {
        try! WgConf.parse("[Interface]\nPrivateKey = \(key)\nAddress = 10.0.0.2/32\nDNS = 10.0.0.1\n[Peer]\nPublicKey = \(peerKey)\nPresharedKey = \(psk)\nEndpoint = 203.0.113.1:51820\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 15\n", name: "Home box")
    }
    private var homeWg: WgPeer {
        var p = try! WgConf.parse("[Interface]\nPrivateKey = \(key)\nAddress = 192.168.1.201/24\n[Peer]\nPublicKey = \(peerKey)\nEndpoint = home.example.org:51820\nAllowedIPs = 192.168.1.0/24\n", name: "Home")
        p.allowedIps = p.allowedIps.compactMap(Compiler.canonical)
        return p
    }
    private var ovpn: OvpnProfile { try! Manual.parseOvpn(Fixture.text("ovpn/selfhosted.ovpn"), name: "Office", username: "user-secret", password: "pass-secret") }
    private var ss: SsProfile {
        try! Manual.parseSs("ss://chacha20-ietf-poly1305:p%40ss%2Bw%20rd@[2001:db8::1]:8388/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dsecret-host.example", name: "Outline é")
    }

    private func nl() -> Route { Route(id: "nl", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands")) }

    /// A setup using every part a backup carries, with secrets planted wherever this Mac keeps some.
    private func full() -> Setup {
        var s = Setup(
            routes: [nl(), Route(id: "w1", wg: wg, hue: 1, own: "s1"), Route(id: "o1", ovpn: ovpn, hue: 2, own: "s2"), Route(id: "x1", ss: ss, hue: 3, own: "s3"),
                     Route(id: "m1", loc: Location(provider: "mullvad", countryCode: "SE", country: "Sweden"), hue: 4),
                     Route(id: "t1", tsExit: "100.64.0.1", tsName: "box", hue: 5)],
            defaultRoute: "nl",
            apps: ["org.example.a": "w1", "org.example.b": DIRECT, "org.example.c": "m1", "org.example.d": BLOCK, "/usr/local/bin/tool": "x1"],
            sites: ["example.com": "x1", "news.example.org": DIRECT],
            home: Home(tailscale: true, tsAuthKey: "tskey-auth-SECRET", tsEnrolled: "enrolled-SECRET", tsControlUrl: "https://hs.example",
                       tsSuffix: "tail-secret.ts.net", tsSuffixConfirmed: true, subnets: ["192.168.77.0/24"], wg: homeWg),
            servers: [OwnServer(id: "s1", wg: wg), OwnServer(id: "s2", ovpn: ovpn), OwnServer(id: "s3", ss: ss)],
            opts: ["nord": ["protect": "off"]],
            profiles: [Profile(name: "Work", defaultRoute: "o1", apps: ["org.example.a": "x1", "org.example.e": "t1"], sites: ["example.com": BLOCK]),
                       Profile(name: "Home", defaultRoute: "nl", apps: ["org.example.c": "m1"])],
            profile: "Home")
        s.prefs.stats = true; s.prefs.lan = false; s.prefs.filter = Filter(id: "adguard", routes: true); s.prefs.killLevel = .home; s.prefs.alwaysOn = true
        s.profileSalt = UUID().uuidString
        s.testing = ["w1"]
        s.pendingSwitch = ProfileSwitch(id: UUID(), target: "Home", from: "Work", when: .now, switched: Profile(name: "Home", defaultRoute: "nl"))
        return s
    }

    private func read(_ s: Setup, keys: Bool = true) throws -> Backup.Content { try Backup.read(Backup.export(s, app: "1.2.0", created: Date(timeIntervalSince1970: 1_700_000_000), keys: keys)) }
    private func text(_ s: Setup, keys: Bool = true) -> String { String(decoding: Backup.export(s, app: "1.2.0", created: .now, keys: keys), as: UTF8.self) }
    private func failure(_ f: () throws -> Any) -> Backup.Failure? {
        do { _ = try f(); XCTFail("accepted"); return nil } catch { return error as? Backup.Failure }
    }
    private func refused(_ s: Setup, file: StaticString = #filePath, line: UInt = #line) -> String {
        do { _ = try Backup.valid(s); XCTFail("accepted", file: file, line: line); return "" } catch {
            guard case .invalid(let why) = error as? Backup.Failure else { XCTFail("\(error)", file: file, line: line); return "" }
            return why
        }
    }
    private func plain(_ json: String) -> Data { Data(json.utf8) }
    private func edited(_ s: Setup, keys: Bool = true, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var top = try XCTUnwrap(JSONSerialization.jsonObject(with: Backup.export(s, app: "1.2.0", created: .now, keys: keys)) as? [String: Any])
        var mac = try XCTUnwrap(top["mac"] as? [String: Any])
        change(&mac)
        top["mac"] = mac
        return try JSONSerialization.data(withJSONObject: top)
    }

    // MARK: Round trip

    func testRoundTripThroughASealedFile() throws {
        let s = full()
        let file = try BackupFile.seal(Backup.export(s, app: "1.2.0", created: Date(timeIntervalSince1970: 1_700_000_000.123), keys: true),
                                       passphrase: "correct horse", logN: 10, r: 8, p: 1)
        let back = try Backup.read(BackupFile.open(file, passphrase: "correct horse"))
        XCTAssertEqual(back.app, "1.2.0")
        XCTAssertEqual(back.created.timeIntervalSince1970, 1_700_000_000.123, accuracy: 0.001)
        XCTAssertTrue(back.keys)
        XCTAssertEqual(back.setup, Backup.contents(s, keys: true))
        XCTAssertEqual(back.setup.profile, "Home")
        XCTAssertEqual(back.summary, Backup.Summary(routes: 6, apps: 5, websites: 2, profiles: 2, servers: 3, keyless: 0, homeTunnel: true))
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: Backup.export(s, app: "1.2.0", created: Date(timeIntervalSince1970: 2), keys: false)) as? [String: Any])
        XCTAssertEqual(Set(top.keys), ["format", "platform", "app", "created", "keys", "mac"])
        XCTAssertEqual(top["format"] as? Int, 1); XCTAssertEqual(top["platform"] as? String, "mac"); XCTAssertEqual(top["created"] as? Int, 2000)
        XCTAssertEqual(top["keys"] as? Bool, false)
        XCTAssertEqual((top["mac"] as? [String: Any])?["version"] as? Int, 2)
    }

    func testNoSignInTailscaleOrConsentGetsIn() throws {
        let s = full()
        let withKeys = text(s)
        for secret in ["tskey-auth-SECRET", "enrolled-SECRET", "hs.example", "tail-secret", "192.168.77.0/24", "192.168.77.0\\/24", s.profileSalt!,
                       "\"tailscale\":true", "\"stats\":true", "pendingSwitch", "profileSalt", "testing"] {
            XCTAssertFalse(withKeys.contains(secret), secret)
        }
        // Own servers are what the file is for, so with keys theirs are in it (sealed).
        for own in [key, psk, "user-secret", "pass-secret", "p@ss+w rd", "secret-host.example", ovpnKeyLine] { XCTAssertTrue(withKeys.contains(own), own) }
        // Sign-ins don't live in the setup at all: no field of it may look like one.
        let fields = Set(withKeys.matches(of: /"([A-Za-z]+)":/).map { String($0.1).lowercased() })
        XCTAssertTrue(fields.allSatisfy { k in !["token", "account", "authkey", "session", "cookie", "enrolled", "salt"].contains { k.contains($0) } }, "\(fields)")
        // Without keys: none of them at all, and nothing of Tailscale either.
        let without = text(s, keys: false)
        for secret in [key, psk, "user-secret", "pass-secret", "p@ss+w rd", "secret-host.example", ovpnKeyLine, "BEGIN PRIVATE KEY", "BEGIN CERTIFICATE",
                       "tskey-auth-SECRET", "enrolled-SECRET", "hs.example", "tail-secret", "home.example.org"] {
            XCTAssertFalse(without.contains(secret), secret)
        }
        // A Tailscale exit holds no key: it stays as it is.
        XCTAssertEqual(try read(s, keys: false).setup.route("t1"), s.route("t1"))
    }

    // MARK: Keys left out

    func testWithoutKeysEveryOwnServerWaitsForItsConfig() async throws {
        var loose = full()
        var spare = wg; spare.name = "Loose"; spare.endpoint = "203.0.113.7:51820"
        loose.routes.append(Route(id: "w2", wg: spare))
        loose.apps["org.example.f"] = "w2"
        let c = try read(loose, keys: false)
        XCTAssertFalse(c.keys)
        XCTAssertTrue(c.setup.servers.allSatisfy(\.keyless))
        XCTAssertEqual(c.setup.routes.filter(\.keyless).map(\.id), ["w1", "o1", "x1", "w2"])
        XCTAssertNil(c.setup.home.wg)
        // A route that had no own server gets one, to be given its config back through.
        let own = try XCTUnwrap(c.setup.servers.first { $0.id == c.setup.route("w2")?.own })
        XCTAssertTrue(own.keyless); XCTAssertEqual(own.name, "Loose")
        XCTAssertEqual(c.summary.keyless, 4); XCTAssertEqual(c.summary.servers, 4); XCTAssertFalse(c.summary.homeTunnel)
        // Their routes are blocked, never retried, never run on another route or Direct.
        var used = c.setup
        used.apps.merge(["org.example.g": "o1", "org.example.h": "x1"]) { $1 }
        let p = try await LinkPicker.pick(used, keep: [:], applied: nil, appliedAccounts: [:], accounts: [:], last: [:], offline: true, providers: Providers.get)
        for id in ["w1", "o1", "x1", "w2"] { XCTAssertEqual(p.blocked[id], .keyLeftOut, id); XCTAssertNil(p.links[id]) }
        XCTAssertEqual(LinkPicker.Blocked.keyLeftOut.text, "needs its config again")
        // A route through a server still waiting for its config is blocked even if the route itself isn't marked.
        var unmarked = used
        unmarked.routes = unmarked.routes.map { var r = $0; if r.id == "w1" { r.keyless = false; r.wg = wg }; return r }
        let q = try await LinkPicker.pick(unmarked, keep: [:], applied: nil, appliedAccounts: [:], accounts: [:], last: [:], offline: true, providers: Providers.get)
        XCTAssertEqual(q.blocked["w1"], .keyLeftOut)
        // Never retried, and as settled as a sign-out for taking over a running tunnel.
        var retry = RouteRetry<Int>()
        retry.update(p.blocked, setup: used, removedPins: .init(), revision: 1, attempted: [], now: .now)
        XCTAssertTrue(retry.dates.keys.allSatisfy { !["w1", "o1", "x1", "w2"].contains($0) }, "\(retry.dates)")
        XCTAssertTrue(Lifecycle.acceptsTakeover(["w1": .keyLeftOut, "nl": .signedOut("NordVPN")], activeRoutes: 3))
        XCTAssertFalse(Lifecycle.acceptsTakeover(["w1": .keyLeftOut, "nl": .waiting], activeRoutes: 3))
        // Refused in the compiled config: an app on it reaches nothing.
        let config = try Compiler.compile(Compiler.Input(setup: used, links: p.links, blocked: Set(p.blocked.keys), apps: ["org.example.g": [Compiler.pattern(forPath: "/Applications/G.app", ignoringCase: true)]],
                                                         selfPattern: Compiler.pattern(forPath: "/Applications/unbraid.app", ignoringCase: true)))
        XCTAssertNoThrow(try ConfigVet.check(config))
        XCTAssertFalse(config.contains("pass-secret"))
        XCTAssertTrue(Backup.hasSecrets(full())); XCTAssertFalse(Backup.hasSecrets(Setup()))
        XCTAssertFalse(Backup.hasSecrets(Setup(routes: [nl(), Route(id: "t", tsExit: "100.64.0.9")])))
        var homeOnly = Setup(); homeOnly.home.wg = homeWg
        XCTAssertTrue(Backup.hasSecrets(homeOnly))
    }

    func testAServerWithoutKeysTakesItsConfigAgain() async throws {
        let b = try read(full(), keys: false)
        let plan = Backup.plan(onto: Setup(), from: b, keepPrevious: true, now: .now)
        XCTAssertNil(plan.keptAs); XCTAssertFalse(plan.unkept)
        XCTAssertEqual(plan.needConfig, ["Home box", "Office", "Outline é"])
        let r = plan.setup
        XCTAssertNoThrow(try Backup.valid(r))
        var renamed = wg; renamed.name = "Renamed"
        let back = try XCTUnwrap(r.refilled("s1", with: OwnServer(id: "", wg: renamed)))
        XCTAssertNoThrow(try Backup.valid(back))
        XCTAssertEqual(back.servers.first { $0.id == "s1" }, OwnServer(id: "s1", wg: renamed))
        XCTAssertEqual(back.route("w1")?.wg, renamed); XCTAssertFalse(back.route("w1")!.keyless)
        XCTAssertTrue(back.route("o1")!.keyless)
        // Only a server waiting for its config, and only with one of its own kind.
        XCTAssertNil(back.refilled("s1", with: OwnServer(id: "", wg: wg)))
        XCTAssertNil(back.refilled("gone", with: OwnServer(id: "", wg: wg)))
        XCTAssertNil(back.refilled("s2", with: OwnServer(id: "", wg: wg)))
        let ov = try XCTUnwrap(back.refilled("s2", with: OwnServer(id: "x", ovpn: ovpn)))
        XCTAssertEqual(ov.route("o1")?.ovpn, ovpn)
        // Unblocked: it runs its own tunnel again.
        var used = back
        used.apps["org.example.z"] = "w1"
        let p = try await LinkPicker.pick(used, keep: [:], applied: nil, appliedAccounts: [:], accounts: [:], last: [:], offline: true, providers: Providers.get)
        XCTAssertNil(p.blocked["w1"]); XCTAssertNotNil(p.links["w1"]); XCTAssertEqual(p.blocked["x1"], .keyLeftOut)
    }

    func testRestoringWithoutKeysOnTheSameMacKeepsItsKeys() throws {
        let here = full()
        let b = try read(here, keys: false)
        let r = Backup.restored(onto: here, from: b, keepPrevious: false, now: .now)
        XCTAssertTrue(r.servers.allSatisfy { !$0.keyless } && r.routes.allSatisfy { !$0.keyless })
        XCTAssertEqual(r.servers, here.servers)
        XCTAssertEqual(r.route("w1"), here.route("w1")); XCTAssertEqual(r.route("x1"), here.route("x1")); XCTAssertEqual(r.route("o1"), here.route("o1"))
        XCTAssertEqual(r.home.wg, here.home.wg)
        XCTAssertNoThrow(try Backup.valid(r))
        // A server that changed since is not taken for the same one.
        var moved = here
        moved.servers[0].wg?.endpoint = "203.0.113.9:51820"
        XCTAssertEqual(Backup.restored(onto: moved, from: b, keepPrevious: false, now: .now).servers.filter(\.keyless).map(\.id), ["s1"])
        // Nor one renamed, or of another kind under the same id.
        var renamed = here
        renamed.servers[2].ss?.name = "Other"
        XCTAssertEqual(Backup.restored(onto: renamed, from: b, keepPrevious: false, now: .now).servers.filter(\.keyless).map(\.id), ["s3"])
    }

    func testAFileSavedWithoutKeysMustHoldNone() throws {
        let s = try read(full(), keys: false).setup
        XCTAssertFalse(refused(s.with { $0.servers[0].wg?.privateKey = key }).contains(key))
        _ = refused(s.with { $0.servers[1].ovpn = ovpn; $0.servers[1].keyless = true })
        _ = refused(s.with { $0.servers[2].ss?.password = "pw" })
        _ = refused(s.with { $0.routes[1].wg?.presharedKey = psk })
        // A keyless route must point at a keyless server, and a keyless server's routes must be keyless.
        _ = refused(s.with { $0.routes[1].keyless = false })
        _ = refused(s.with { $0.routes[0].keyless = true })
        _ = refused(s.with { $0.routes[1].own = nil })
        // The file itself: a keyless route given a key is refused when read, not only by `valid`.
        XCTAssertEqual(failure { try Backup.read(self.edited(self.full(), keys: false) { mac in
            var routes = mac["routes"] as! [[String: Any]]
            var w = routes[1]["wg"] as! [String: Any]; w["privateKey"] = self.key; routes[1]["wg"] = w
            mac["routes"] = routes
        }) }.map { if case .invalid = $0 { return true }; return false }, true)
    }

    // MARK: Validation

    func testValidationReusesTheImportChecks() throws {
        let f = full()
        let ok = try read(f).setup
        XCTAssertEqual(ok, Backup.contents(f, keys: true))
        let short = refused(f.with { $0.servers[0].wg?.privateKey = "short" })
        XCTAssertTrue(short.contains("own server Home box"), short); XCTAssertFalse(short.contains("short"))
        _ = refused(f.with { $0.routes[3].ss?.method = "none" })
        _ = refused(f.with { $0.routes[2].ovpn?.config = "dev tun\n" })
        XCTAssertFalse(refused(f.with { $0.servers[1].ovpn?.config += "\nbogus-directive \(self.ovpnKeyLine)" }).contains(ovpnKeyLine))
        _ = refused(f.with { $0.servers[2].ss?.pluginOpts = "cert=/etc/passwd" })
        _ = refused(f.with { $0.servers[0].wg?.endpoint = "nowhere" })
        // An MTU out of range is no damage: it is read as the import reads it.
        XCTAssertEqual(try Backup.valid(f.with { $0.servers[0].wg?.mtu = 9000 }).servers[0].wg?.mtu, 1500)
        _ = refused(f.with { $0.servers[0].wg = nil })
        _ = refused(f.with { $0.servers.append(OwnServer(id: "s1", wg: self.wg)) })
        _ = refused(f.with { $0.home.wg?.endpoint = "nowhere" })
        _ = refused(f.with { $0.defaultRoute = "gone" })
        _ = refused(f.with { $0.defaultRoute = BLOCK })
        _ = refused(f.with { $0.apps["org.example.z"] = "gone" })
        _ = refused(f.with { $0.apps["bad\u{0}key"] = DIRECT })
        _ = refused(f.with { $0.routes.append(Route(id: "nl")) })
        _ = refused(f.with { $0.routes.append(Route(id: DIRECT)) })
        _ = refused(f.with { $0.routes.append(Route(id: "bad id")) })
        _ = refused(f.with { $0.routes.append(Route(id: "zz", loc: Location(provider: "nobody"))) })
        _ = refused(f.with { $0.routes.append(Route(id: "zz", wg: self.wg, ss: self.ss)) })
        _ = refused(f.with { $0.routes.append(Route(id: "zz", tsExit: "100.64.0.1\n")) })
        _ = refused(f.with { $0.sites["Example.COM"] = DIRECT })
        _ = refused(f.with { $0.sites["example.net"] = "gone" })
        let many = f.with { s in s.sites = Dictionary(uniqueKeysWithValues: (0...Sites.max).map { ("site\($0).example.com", DIRECT) }) }
        XCTAssertEqual(many.sites.count, 51)
        _ = refused(many)
        _ = refused(f.with { s in s.profiles[0].sites = Dictionary(uniqueKeysWithValues: (0...Sites.max).map { ("site\($0).example.com", DIRECT) }) })
        _ = refused(f.with { $0.profiles.append(Profile(name: "work", defaultRoute: "nl")) })
        _ = refused(f.with { $0.profiles.append(Profile(name: "Far too long a name", defaultRoute: "nl")) })
        _ = refused(f.with { $0.profiles.append(Profile(name: " Padded", defaultRoute: "nl")) })
        _ = refused(f.with { s in s.profiles = (1...Setup.maxProfiles + 1).map { Profile(name: "P\($0)", defaultRoute: "nl") }; s.profile = nil })
        _ = refused(f.with { $0.profile = "Gone" })
        _ = refused(f.with { $0.profiles.append(Profile(name: "Bad", defaultRoute: "gone")) })
        _ = refused(f.with { $0.profiles.append(Profile(name: "Bad", defaultRoute: "nl", apps: ["org.example.a": "gone"])) })
        _ = refused(f.with { $0.prefs.filter = Filter(id: "no-such-filter") })
        _ = refused(f.with { $0.opts["nord"] = ["protect": String(repeating: "x", count: 300)] })
        _ = refused(f.with { s in s.routes += (1...Backup.maxRoutes).map { Route(id: "r\($0)") } })
        // A route still naming an own server that is gone keeps its config, no longer tied to it.
        XCTAssertNil(try Backup.valid(f.with { $0.servers.removeAll { $0.id == "s1" } }).route("w1")?.own)
    }

    func testEverySavedProfileMustBeAbleToRun() throws {
        let f = full()
        let two = f.with { s in
            s.routes += [Route(id: "t2", tsExit: "100.64.0.2")]
            s.profiles.append(Profile(name: "Odd", defaultRoute: "t1", apps: ["org.example.a": "t2"]))
        }
        XCTAssertEqual(refused(two), "profile Odd can't run")
        XCTAssertNoThrow(try Backup.valid(f.with { $0.profiles.append(Profile(name: "Fine", defaultRoute: "t1", apps: ["org.example.a": "t1"])) }))
        // The live setup too.
        XCTAssertEqual(refused(two.with { $0.apps["org.example.a"] = "t1"; $0.apps["org.example.b"] = "t2" }), "its setup can't run")
    }

    func testTheInnerSetupIsReadStrictly() throws {
        let f = full()
        // A value that is there but can't be read fails the backup: read leniently, the route would be left out and
        // its apps blocked, or the preference would take its default.
        XCTAssertEqual(failure { try Backup.read(self.edited(f) { mac in
            var routes = mac["routes"] as! [[String: Any]]; routes[1]["hue"] = "red"; mac["routes"] = routes
        }) }, .damaged)
        XCTAssertEqual(failure { try Backup.read(self.edited(f) { mac in
            var prefs = mac["prefs"] as! [String: Any]; prefs["killSwitch"] = "yes"; mac["prefs"] = prefs
        }) }, .damaged)
        XCTAssertEqual(failure { try Backup.read(self.edited(f) { mac in mac["servers"] = [["id": "s1", "wg": ["name": "x"]]] }) }, .damaged)
        // Something the setup's reader would repair is refused, not repaired: an app on a route that isn't there, a
        // website address not as unbraid writes it, a profile name it would change.
        for change: (inout [String: Any]) -> Void in [
            { mac in var a = mac["apps"] as! [String: Any]; a["org.example.z"] = "gone"; mac["apps"] = a },
            { mac in var a = mac["sites"] as! [String: Any]; a["WWW.Example.com"] = DIRECT; mac["sites"] = a },
            { mac in var p = mac["profiles"] as! [[String: Any]]; p[0]["name"] = " Work "; mac["profiles"] = p },
            { mac in var p = mac["profiles"] as! [[String: Any]]; p[0]["defaultRoute"] = "gone"; mac["profiles"] = p },
            { mac in mac["profile"] = "Gone" },
        ] {
            XCTAssertEqual(failure { try Backup.read(self.edited(f, change)) }.map { if case .invalid = $0 { return true }; return false }, true)
        }
    }

    func testHostileOrDamagedContentsAreRefusedPlainly() throws {
        for junk in ["", "{", "[]", "5", "null", "\u{0}", #"{"format":1,"platform":"mac"}"#, #"{"format":"1","platform":"mac","mac":{}}"#,
                     #"{"format":0,"platform":"mac","app":"","created":0,"keys":true,"mac":{}}"#,
                     #"{"format":1,"platform":"mac","app":"","created":0,"keys":true,"mac":5}"#,
                     #"{"format":1,"platform":"mac","app":"","created":0,"keys":true,"mac":{"routes":"#] + [String(repeating: "[", count: 5000)] {
            XCTAssertEqual(failure { try Backup.read(self.plain(junk)) }, .damaged, String(junk.prefix(40)))
        }
        XCTAssertEqual(failure { try Backup.read(Data(count: BackupFile.maxSize + 1)) }, .damaged)
        // A string far longer than any unbraid keeps is refused before the parsers see it.
        let huge = full().with { $0.favorites.append(Location(country: String(repeating: "x", count: Backup.maxString + 1))) }
        XCTAssertEqual(failure { try self.read(huge) }, .invalid("it holds more than unbraid keeps"))
        XCTAssertNoThrow(try read(full().with { $0.favorites.append(Location(country: String(repeating: "x", count: 1000))) }))
        XCTAssertEqual(Backup.Failure.damaged.message, "This backup is damaged or incomplete. Use another copy of it.")
        XCTAssertEqual(Backup.Failure.invalid("a route has more than one exit").message, "This backup can't be restored: a route has more than one exit.")
    }

    /// What the import no longer writes the same way is taken as the import reads it, and a setup whose backup
    /// couldn't be restored is refused when it is saved, not when it is needed.
    func testABackupThatSavesCanBeRestored() throws {
        var old = full()
        old.servers[0].wg?.mtu = 9000
        old.routes[1].wg?.mtu = 9000
        let back = try read(old).setup
        XCTAssertEqual(back.servers[0].wg?.mtu, 1500)
        XCTAssertEqual(back.routes[1].wg?.mtu, 1500)
        XCTAssertEqual(back.routes[1].wg, back.servers[0].wg)
        // A setup the check refuses: nothing is written, and the reason is the restore's own.
        var broken = full()
        broken.routes.append(Route(id: "__filtered_direct", tsExit: "100.64.0.9", tsName: "exit"))
        let url = FileManager.default.temporaryDirectory.appending(path: "unbraid-\(UUID().uuidString).unbraidbackup")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try BackupFile.save(broken, app: "1.2.0", keys: true, passphrase: "x", to: url)) { error in
            XCTAssertNotNil(error as? BackupFile.Unrestorable)
            XCTAssertTrue(BackupTexts.saveFailure(error).hasPrefix("Nothing was saved: a backup of this setup couldn't be restored later."))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: What a file from elsewhere can't do

    /// No route may carry a name the compiler reads as Direct, Block or a refusal: a Tailscale route called so would
    /// show as that route and run as Direct.
    func testARouteCantTakeAnInternalName() throws {
        for id in ["__filtered_direct", "denied", DIRECT, BLOCK] {
            var s = full()
            s.routes.append(Route(id: id, tsExit: "100.64.0.9", tsName: "exit"))
            s.apps["org.example.z"] = id
            XCTAssertEqual(refused(s), "a route has a missing or repeated name", id)
            let data = try edited(full()) { mac in
                var routes = mac["routes"] as? [[String: Any]] ?? []
                routes.append(["id": id, "tsExit": "100.64.0.9", "tsName": "exit"])
                mac["routes"] = routes
            }
            XCTAssertNotNil(failure { try Backup.read(data) }, id)
        }
    }

    /// A pinned provider server comes back by its name and host only: the address and key a file gives are never what
    /// a provider's tunnel is made to, in a route or in a favourite, written by this app or by someone else.
    func testAPinnedServersAddressAndKeyAreNeverTakenFromAFile() throws {
        let pin = Server(name: "se-got-wg-001", host: "se-got-wg-001.relays.example", ip: "203.0.113.66", publicKey: peerKey, load: 12, city: "Gothenburg", country: "Sweden")
        var s = full()
        s.routes[4].loc.pinned = pin
        s.favorites = [Location(provider: "mullvad", countryCode: "SE", country: "Sweden", pinned: pin)]
        XCTAssertFalse(text(s).contains("203.0.113.66"))
        let back = try read(s).setup
        XCTAssertEqual(back.routes[4].loc.pinned, Server(name: pin.name, host: pin.host, ip: "", publicKey: "", load: -1, city: "Gothenburg", country: "Sweden"))
        XCTAssertEqual(back.favorites.first?.pinned?.ip, "")
        // Put back in by hand: read the same way.
        let data = try edited(s) { mac in
            var routes = mac["routes"] as? [[String: Any]] ?? []
            var loc = routes[4]["loc"] as? [String: Any] ?? [:]
            loc["pinned"] = ["name": pin.name, "host": pin.host, "ip": "203.0.113.66", "publicKey": self.peerKey, "load": 1, "city": "", "country": ""]
            routes[4]["loc"] = loc
            mac["routes"] = routes
        }
        let forged = try Backup.read(data).setup
        XCTAssertEqual(forged.routes[4].loc.pinned?.ip, "")
        XCTAssertEqual(forged.routes[4].loc.pinned?.publicKey, "")
        XCTAssertEqual(forged.routes[4].loc.pinned?.host, pin.host)
    }

    /// The one provider setting that names addresses (IVPN's block list: a pair of its resolvers) never comes from a
    /// file: after a restore it is the provider's standard one again.
    func testAProvidersResolversAreNeverTakenFromAFile() throws {
        var s = full()
        s.opts["ivpn"] = ["list": "203.0.113.5|203.0.113.6", "port": "2049", "hardcore": "on"]
        XCTAssertFalse(text(s).contains("203.0.113.5"))
        XCTAssertEqual(try read(s).setup.opts["ivpn"], ["port": "2049", "hardcore": "on"])
        let data = try edited(s) { mac in
            var opts = mac["opts"] as? [String: Any] ?? [:]
            opts["ivpn"] = ["list": "203.0.113.5|203.0.113.6"]
            mac["opts"] = opts
        }
        XCTAssertNil(try Backup.read(data).setup.opts["ivpn"]?["list"])
    }

    /// A route saved without keys must describe the very server it names: this Mac's config for that server is what
    /// it gets back.
    func testAKeylessRouteMustBeItsOwnServers() throws {
        let content = try read(full(), keys: false)
        var s = content.setup
        let i = try XCTUnwrap(s.routes.firstIndex { $0.id == "w1" })
        XCTAssertTrue(s.routes[i].keyless)
        XCTAssertNoThrow(try Backup.valid(s))
        s.routes[i].wg?.endpoint = "198.51.100.9:51820"
        XCTAssertEqual(refused(s), "a route and its own server don't match")
        // Another kind than its server's, too.
        var other = content.setup
        (other.routes[i].wg, other.routes[i].ss) = (nil, other.servers.first { $0.ss != nil }?.ss)
        XCTAssertEqual(refused(other), "a route and its own server don't match")
    }

    /// What a restore would weaken is said, one sentence each; what stays as strong or gets stronger is not.
    func testWhatARestoreWeakensIsSaid() throws {
        var here = full()
        here.sites["tracker.example"] = BLOCK
        var weaker = full()
        weaker.prefs.killLevel = .internet; weaker.prefs.alwaysOn = false; weaker.prefs.filter = Filter(); weaker.prefs.lan = true
        weaker.apps["org.example.d"] = DIRECT
        // From a VPN to Direct: the default route, and an app and a website with a VPN route of their own.
        weaker.defaultRoute = DIRECT; weaker.apps["org.example.a"] = DIRECT; weaker.sites["example.com"] = DIRECT
        XCTAssertEqual(Backup.weakens(here, weaker), [
            "The kill switch goes from Internet and home network to Internet.", "Connect on demand is turned off.", "The DNS filter is turned off.",
            "Apps can reach the local network again.", "The default route goes from Netherlands to Direct.",
            "1 app and 1 website go from a VPN route to Direct.", "1 app that is blocked now won't be.", "1 website that is blocked now won't be.",
        ])
        XCTAssertEqual(Backup.weakens(weaker, here), [])
        XCTAssertEqual(Backup.weakens(here, here), [])
        var filter = here
        filter.prefs.filter = Filter(id: "quad9", routes: true)
        XCTAssertEqual(Backup.weakens(here, filter), ["The DNS filter changes to another server."])
        filter.prefs.filter = Filter(id: "adguard", routes: false, direct: true)
        XCTAssertEqual(Backup.weakens(here, filter), ["The DNS filter covers less than it does now."])
        // App by app: a Direct app the filter covers now, and won't.
        var perApp = here
        perApp.prefs.filter.apps = ["org.example.b": true]
        XCTAssertEqual(Backup.weakens(perApp, here), ["The DNS filter covers less than it does now."])
        XCTAssertEqual(Backup.weakens(here, perApp), [])
        // Apps that follow a default going to Direct count as well; one following a VPN default the backup sets on Direct too.
        var follow = here
        follow.apps = [:]; follow.sites = [:]
        XCTAssertEqual(Backup.weakens(follow, follow.with { $0.apps = ["org.example.a": DIRECT, "org.example.b": "nl"] }), ["1 app goes from a VPN route to Direct."])
        XCTAssertEqual(Backup.weakens(follow.with { $0.apps = ["org.example.a": "w1", "org.example.b": "m1"] }, follow.with { $0.defaultRoute = DIRECT }),
                       ["The default route goes from Netherlands to Direct.", "2 apps go from a VPN route to Direct."])
        // The provider's own blocking, which runs while unbraid's filter doesn't cover VPN routes.
        var own = here
        own.prefs.filter = Filter()
        own.routes.append(Route(id: "iv", loc: Location(provider: "ivpn", countryCode: "CH", country: "Switzerland")))
        own.opts = ["nord": ["protect": "on"], "mullvad": ["protect": "on", "gambling": "on", "owned": "on"], "ivpn": ["protect": "on", "list": "10.0.254.4|10.0.254.5", "hardcore": "on"]]
        let open = own.with { $0.opts = ["nord": ["protect": "off"], "mullvad": [:], "ivpn": ["protect": "on"]] }
        XCTAssertEqual(Backup.weakens(own, open), [
            "Hardcore mode is turned off for IVPN.", "IVPN's block list goes back to the standard one.",
            "Mullvad blocking, Gambling and Mullvad-owned servers only are turned off for Mullvad.", "Threat Protection Lite is turned off for NordVPN.",
        ])
        XCTAssertEqual(Backup.weakens(open, own), [])
        // A route's own choice turns it off, with the provider's setting on in both.
        XCTAssertEqual(Backup.weakens(own, own.with { $0.routes[4].filter = false; $0.routes[0].filter = false }), ["The provider's own blocking is turned off for 2 routes."])
        XCTAssertEqual(Backup.weakens(own.with { $0.routes[4].filter = false }, own.with { $0.routes[4].filter = nil; $0.opts["mullvad"]?["protect"] = "off" }), [])
        // Said with unbraid's filter on VPN routes too: once the filter is off, the provider's setting is what protects them.
        XCTAssertEqual(Backup.weakens(here.with { $0.opts = own.opts }, here.with { $0.opts = open.opts }).last, "Threat Protection Lite is turned off for NordVPN.")
        // An own server or the Home WireGuard tunnel under the same name that connects elsewhere or sets other DNS servers:
        // the host and servers are said, never a key.
        var moved = here
        moved.servers[0].wg?.endpoint = "198.51.100.9:51820"; moved.servers[0].wg?.dns = ["9.9.9.9"]
        moved.servers[2].ss?.server = "203.0.113.77"
        moved.home.wg?.endpoint = "elsewhere.example:51820"
        XCTAssertEqual(Backup.weakens(here, moved), [
            "The Home WireGuard tunnel connects to elsewhere.example instead of home.example.org.",
            "\"Home box\" connects to 198.51.100.9 instead of 203.0.113.1.", "\"Home box\" uses other DNS servers: 9.9.9.9.",
            "\"Outline é\" connects to 203.0.113.77 instead of 2001:db8::1.",
        ])
        XCTAssertFalse(Backup.weakens(here, moved).joined().contains(peerKey))
        // A route of its own (not tied to a server) too.
        let loose = here.with { $0.routes[2].own = nil; $0.servers.remove(at: 1) }
        let config = try XCTUnwrap(loose.routes[2].ovpn?.config).replacingOccurrences(of: "remote vpn.example.net 443", with: "remote other.example 443")
        let looseMoved = loose.with { $0.routes[2].ovpn?.config = config }
        XCTAssertEqual(Backup.weakens(loose, looseMoved), ["\"Office\" connects to other.example instead of vpn.example.net."])
        // The plan carries them, and the sheet's notes show them.
        let plan = Backup.plan(onto: here, from: try read(weaker), keepPrevious: false, now: .now)
        XCTAssertEqual(plan.weakens.count, 8)
        XCTAssertTrue(BackupTexts.restoreNotes(plan, accounts: [:], tunnelUp: false).contains("The DNS filter is turned off."))
    }

    /// Every protective setting the user can change, one at a time: a restore that weakens it says so.
    func testEveryProtectiveFieldThatGoesIsSaid() throws {
        var here = Setup()
        here.routes = [nl(), Route(id: "r0", wg: wg, own: "s0"),
                       Route(id: "m1", loc: Location(provider: "mullvad", countryCode: "SE", country: "Sweden"), filter: true)]
        here.servers = [OwnServer(id: "s0", wg: wg)]
        here.apps = ["org.example.a": "r0", "org.example.b": BLOCK]
        here.sites = ["example.com": "r0", "tracker.example": BLOCK]
        here.prefs.killLevel = .home; here.prefs.alwaysOn = true; here.prefs.lan = false
        here.prefs.filter = Filter(id: "quad9", routes: true, direct: true, directApps: true, apps: ["org.example.c": true])
        here.opts["nord"] = ["protect": "on"]
        here = try JSONDecoder().decode(Setup.self, from: JSONEncoder().encode(here))
        XCTAssertEqual(Backup.weakens(here, here), [])
        let cases: [(String, (inout Setup) -> Void)] = [
            ("kill switch off", { $0.prefs.killLevel = .off }), ("kill switch home to internet", { $0.prefs.killLevel = .internet }),
            ("connect on demand off", { $0.prefs.alwaysOn = false }), ("filter off", { $0.prefs.filter = Filter() }),
            ("filter another server", { $0.prefs.filter.id = "adguard" }), ("filter no longer on routes", { $0.prefs.filter.routes = false }),
            ("filter no longer on Direct", { $0.prefs.filter.direct = false }), ("filter no longer for Direct apps", { $0.prefs.filter.directApps = false }),
            ("filter no longer for one app", { $0.prefs.filter.apps = ["org.example.c": false] }),
            ("filter off for an app that inherited it", { $0.prefs.filter.apps["org.example.z"] = false }),
            ("local network allowed", { $0.prefs.lan = true }),
            ("blocked app unblocked", { $0.apps["org.example.b"] = DIRECT }), ("blocked app removed", { $0.apps["org.example.b"] = nil }),
            ("blocked website unblocked", { $0.sites["tracker.example"] = DIRECT }), ("blocked website removed", { $0.sites["tracker.example"] = nil }),
            ("NordVPN Threat Protection off", { $0.opts["nord"] = ["protect": "off"] }),
            ("a provider route's own blocking off", { $0.routes[2].filter = false }),
            ("default route from a VPN to Direct", { $0.defaultRoute = DIRECT }),
            ("an app from a VPN to Direct", { $0.apps["org.example.a"] = DIRECT }),
            ("a website from a VPN to Direct", { $0.sites["example.com"] = DIRECT }),
            ("an own server elsewhere under its name", { $0.servers[0].wg?.endpoint = "198.51.100.9:51820" }),
        ]
        let unsaid = cases.filter { name, change in Backup.weakens(here, here.with(change)).isEmpty }.map(\.0)
        XCTAssertEqual(unsaid, [])
    }

    /// A server the import would warn about as weak is named with the import's own warning, and waits for the user to
    /// accept it, unless this Mac already has that very config.
    func testAWeakServerIsSaidAsTheImportSaysIt() throws {
        var weak = full()
        let cfb = try Manual.parseSs("ss://aes-128-cfb:pw@203.0.113.5:8388", name: "Old box")
        weak.servers[2].ss = cfb; weak.routes[3].ss = cfb
        let why = try XCTUnwrap(Manual.weakness(cfb))
        let plan = Backup.plan(onto: Setup(), from: try read(weak), keepPrevious: false, now: .now)
        XCTAssertEqual(plan.weak, ["Old box: \(why)"])
        XCTAssertEqual(BackupTexts.weakCaption(plan.weak), "Weak security in Old box: \(why)")
        XCTAssertEqual(Backup.plan(onto: weak, from: try read(weak), keepPrevious: true, now: .now).weak, [])
        XCTAssertEqual(Backup.plan(onto: Setup(), from: try read(full()), keepPrevious: false, now: .now).weak, [])
        // Saved without keys: nothing to judge until its config is added again, through the import.
        XCTAssertEqual(Backup.plan(onto: Setup(), from: try read(weak, keys: false), keepPrevious: false, now: .now).weak, [])
    }

    /// A file can't make the check cost more than its size: app choices are capped, and profiles that choose the same
    /// are built once.
    func testValidationWorkIsBounded() throws {
        var many = full()
        many.apps = Dictionary(uniqueKeysWithValues: (0...Backup.maxApps).map { ("org.example.app\($0)", BLOCK) })
        XCTAssertEqual(refused(many), "it holds more than unbraid keeps")
        var same = full()
        same.apps = Dictionary(uniqueKeysWithValues: (0..<Backup.maxApps).map { ("org.example.app\($0)", $0 % 2 == 0 ? BLOCK : DIRECT) })
        same.profiles = (0..<Setup.maxProfiles).map { Profile(name: "P\($0)", defaultRoute: "nl", apps: same.apps) }
        same.profile = nil
        let start = ContinuousClock.now
        XCTAssertNoThrow(try Backup.valid(same))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(20))
    }

    func testNewerAndAndroidBackupsAreToldApart() throws {
        let newer = try edited(full()) { $0["version"] = Setup.format + 1 }
        XCTAssertEqual(failure { try Backup.read(newer) }, .newer)
        var top = try XCTUnwrap(JSONSerialization.jsonObject(with: Backup.export(full(), app: "", created: .now, keys: true)) as? [String: Any])
        top["format"] = 2
        XCTAssertEqual(failure { try Backup.read(JSONSerialization.data(withJSONObject: top)) }, .newer)
        XCTAssertEqual(Backup.Failure.newer.message, "This backup was made by a newer unbraid. Update unbraid to restore it.")
        // Made by the Android app: the real file it wrote, and the shape of a full one.
        let android = try BackupFile.open(Fixture.data("backup/default.unbraidbackup"), passphrase: "correct horse battery staple")
        XCTAssertEqual(failure { try Backup.read(android) }, .otherPlatform)
        let androidSetup = plain(#"{"format":1,"app":"2.9.1","created":1700000000000,"keys":true,"setup":{"version":2,"routes":[{"id":"nl","loc":{"provider":"nord"}}],"defaultRoute":"nl"}}"#)
        XCTAssertEqual(failure { try Backup.read(androidSetup) }, .otherPlatform)
        // A newer Android file too: who made it is said first.
        XCTAssertEqual(failure { try Backup.read(self.plain(#"{"format":2,"setup":{}}"#)) }, .otherPlatform)
        XCTAssertEqual(failure { try Backup.read(self.plain(#"{"format":1,"platform":"android","mac":{}}"#)) }, .otherPlatform)
        XCTAssertEqual(failure { try Backup.read(self.plain(#"{"format":1,"platform":"mac","setup":{},"mac":{}}"#)) }, .otherPlatform)
        XCTAssertEqual(Backup.Failure.otherPlatform.message, "This backup was made by unbraid for Android. Moving a setup from Android isn't supported yet.")
        // Android names its backups .unbraid: such a file can be chosen and opened, so this message is what the user
        // reads. Anything else under that name is told it isn't a backup, before any passphrase is asked for.
        let dir = FileManager.default.temporaryDirectory.appending(path: "android-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = dir.appending(path: "unbraid-backup-2026-11-17.unbraid")
        try Fixture.data("backup/default.unbraidbackup").write(to: made)
        XCTAssertTrue(BackupFile.named(made)); XCTAssertTrue(BackupFile.named(URL(fileURLWithPath: "/x/B.UNBRAIDBACKUP")))
        XCTAssertFalse(BackupFile.named(URL(fileURLWithPath: "/x/b.conf")))
        XCTAssertEqual(Backup.unlock(try BackupFile.readChosen(made), passphrase: "correct horse battery staple").error?.message, Backup.Failure.otherPlatform.message)
        let other = dir.appending(path: "notes.unbraid")
        try Data("something else".utf8).write(to: other)
        XCTAssertThrowsError(try BackupFile.readChosen(other)) { XCTAssertEqual($0 as? BackupFile.Failure, .notABackup) }
    }

    // MARK: Restoring

    func testRestoreReplacesButKeepsThisMacsTailscaleConsentAndSalt() throws {
        var here = Setup(routes: [Route(id: "de", loc: Location(countryId: 81, countryCode: "DE", country: "Germany"))], defaultRoute: "de",
                         home: Home(tailscale: true, tsAuthKey: "here-key", tsEnrolled: "here-node", tsControlUrl: "https://mine.example", subnets: ["10.1.0.0/16"]))
        here.profileSalt = "here-salt"
        here.pendingSwitch = ProfileSwitch(id: UUID(), target: "x", from: nil, when: .now, switched: Profile(name: "x", defaultRoute: "de"))
        let b = try read(full())
        let plan = Backup.plan(onto: here, from: b, keepPrevious: false, now: .now)
        let r = plan.setup
        XCTAssertEqual(r.routes, b.setup.routes); XCTAssertEqual(r.apps, b.setup.apps); XCTAssertEqual(r.sites, b.setup.sites)
        XCTAssertEqual(r.profiles, b.setup.profiles); XCTAssertEqual(r.profile, "Home"); XCTAssertEqual(r.servers, b.setup.servers)
        XCTAssertEqual(r.favorites, b.setup.favorites); XCTAssertEqual(r.opts, b.setup.opts); XCTAssertEqual(r.defaultRoute, "nl")
        var home = here.home; home.wg = b.setup.home.wg
        XCTAssertEqual(r.home, home)
        XCTAssertFalse(r.prefs.stats)
        XCTAssertEqual(r.prefs.filter, b.setup.prefs.filter); XCTAssertEqual(r.prefs.killLevel, .home); XCTAssertTrue(r.prefs.alwaysOn)
        XCTAssertEqual(r.profileSalt, "here-salt"); XCTAssertNil(r.pendingSwitch); XCTAssertTrue(r.testing.isEmpty)
        XCTAssertTrue(plan.protectionChanges)
        XCTAssertEqual(plan.replaces, Backup.Summary(routes: 1))
        XCTAssertEqual(plan.holds, b.summary)
        XCTAssertNoThrow(try Backup.valid(r))
        // Consent given here stays given; the same protection is no change.
        var agreed = here; agreed.prefs.stats = true; agreed.prefs.killLevel = .home; agreed.prefs.alwaysOn = true
        let again = Backup.plan(onto: agreed, from: b, keepPrevious: false, now: .now)
        XCTAssertTrue(again.setup.prefs.stats); XCTAssertFalse(again.protectionChanges)
        // Without keys, this Mac's Home WireGuard tunnel stays, and isn't counted as replaced.
        var withHome = here; withHome.home.wg = homeWg
        let keyless = Backup.plan(onto: withHome, from: try read(full(), keys: false), keepPrevious: false, now: .now)
        XCTAssertEqual(keyless.setup.home.wg, homeWg); XCTAssertFalse(keyless.replaces.homeTunnel)
        XCTAssertTrue(Backup.plan(onto: withHome, from: b, keepPrevious: false, now: .now).replaces.homeTunnel)
    }

    func testRestoreCanKeepTheSetupInUseAsAProfile() throws {
        var mineWg = wg; mineWg.name = "Mine"
        let mine = Route(id: "w1", wg: mineWg, own: "s1") // the backup's ids, other content
        let only = Route(id: "only", loc: Location(countryId: 228, countryCode: "US", country: "United States"))
        let here = Setup(routes: [nl(), mine, only], defaultRoute: "w1", apps: ["org.example.z": "only", "org.example.y": DIRECT],
                         sites: ["example.net": "w1"], servers: [OwnServer(id: "s1", wg: mineWg)])
        let b = try read(full())
        let plan = Backup.plan(onto: here, from: b, keepPrevious: true, now: .now)
        let r = plan.setup
        XCTAssertNoThrow(try Backup.valid(r))
        XCTAssertEqual(plan.keptAs, "Previous"); XCTAssertFalse(plan.unkept)
        let kept = try XCTUnwrap(r.profiles.first { $0.name == "Previous" })
        // The route the backup also calls "w1" got a new id, with its server; "nl" is the same route in both and is shared.
        let moved = try XCTUnwrap(r.route(kept.defaultRoute))
        XCTAssertNotEqual(moved.id, "w1"); XCTAssertEqual(moved.name, "Mine")
        XCTAssertEqual(r.route("w1")?.name, "Home box")
        let movedServer = try XCTUnwrap(r.servers.first { $0.id == moved.own })
        XCTAssertNotEqual(movedServer.id, "s1"); XCTAssertEqual(movedServer.wg, mineWg)
        XCTAssertEqual(r.servers.first { $0.id == "s1" }?.wg, wg)
        XCTAssertEqual(kept.apps, ["org.example.z": "only", "org.example.y": DIRECT])
        XCTAssertEqual(kept.sites, ["example.net": moved.id])
        XCTAssertEqual(r.routes.count, b.setup.routes.count + 2)
        XCTAssertEqual(r.servers.count, b.setup.servers.count + 1)
        XCTAssertEqual(r.profile, "Home")
        XCTAssertEqual(plan.replaces, Backup.Summary(routes: 3, apps: 2, websites: 1, servers: 1))
        // Switching to it gives back what ran here.
        var back = r
        back.use("Previous")
        XCTAssertEqual(back.route(back.defaultRoute)?.wg, mineWg)
        XCTAssertEqual(back.apps, ["org.example.z": "only", "org.example.y": DIRECT])
        // A backup's own "Previous" stays; this one gets a number, within the name limit.
        let b2 = b.with { $0.setup.profiles.append(Profile(name: "Previous", defaultRoute: "nl")) }
        XCTAssertEqual(Backup.plan(onto: here, from: b2, keepPrevious: true, now: .now).keptAs, "Previous 2")
        let b10 = b.with { c in c.setup.profiles += [Profile(name: "previous", defaultRoute: "nl")] + (2...9).map { Profile(name: "Previous \($0)", defaultRoute: "nl") } }
        let p10 = Backup.plan(onto: here, from: b10, keepPrevious: true, now: .now)
        XCTAssertEqual(p10.keptAs, "Previous 10"); XCTAssertNoThrow(try Backup.valid(p10.setup))
        // No room: the plan says so before anything changes, and restores without it.
        let full20 = b.with { c in c.setup.profiles = (1...Setup.maxProfiles).map { Profile(name: "P\($0)", defaultRoute: "nl") }; c.setup.profile = nil }
        let none = Backup.plan(onto: here, from: full20, keepPrevious: true, now: .now)
        XCTAssertTrue(none.unkept); XCTAssertNil(none.keptAs)
        XCTAssertEqual(none.setup, Backup.plan(onto: here, from: full20, keepPrevious: false, now: .now).setup)
        // A new install has nothing to keep.
        XCTAssertEqual(Backup.plan(onto: Setup(), from: b, keepPrevious: true, now: .now), Backup.plan(onto: Setup(), from: b, keepPrevious: false, now: .now))
        XCTAssertFalse(Backup.setUp(Setup())); XCTAssertTrue(Backup.setUp(here))
        // Every route and server of this Mac comes along, those no app uses too, shared where they are the very same.
        let spare = Route(id: "spare", ss: ss, own: "sp")
        let alsoHere = here.with { $0.routes.append(spare); $0.servers.append(OwnServer(id: "sp", ss: self.ss)) }
        let r2 = Backup.plan(onto: alsoHere, from: b, keepPrevious: true, now: .now).setup
        XCTAssertEqual(r2.route("spare"), spare); XCTAssertTrue(r2.servers.contains(OwnServer(id: "sp", ss: ss)))
        XCTAssertNoThrow(try Backup.valid(r2))
        let same = Backup.plan(onto: full(), from: b, keepPrevious: true, now: .now).setup
        XCTAssertEqual(same.routes, b.setup.routes); XCTAssertEqual(same.servers, b.setup.servers)
        XCTAssertEqual(same.profiles.last, Profile(name: "Previous", defaultRoute: "nl", apps: full().apps, sites: full().sites))
    }

    /// This Mac's own backup restored with its setup kept: every route and server is the same one, shared rather than
    /// copied, a pinned provider server and an own server an older build saved (an MTU the import now reads otherwise)
    /// included. Restored again, still no copies.
    func testRestoringThisMacsOwnBackupMakesNoCopies() throws {
        var here = full()
        here.routes[4].loc.pinned = Server(name: "se-got-wg-001", host: "se-got-wg-001.relays.example", ip: "203.0.113.66", publicKey: peerKey, load: 12)
        var old = wg; old.mtu = 1600
        here.routes[1].wg = old; here.servers[0].wg = old
        let b = try read(here)
        XCTAssertNotEqual(b.setup.routes[1].wg, old)
        let once = Backup.plan(onto: here, from: b, keepPrevious: true, now: .now)
        XCTAssertEqual(once.keptAs, "Previous")
        XCTAssertEqual(once.setup.routes, b.setup.routes)
        XCTAssertEqual(once.setup.servers, b.setup.servers)
        XCTAssertEqual(once.setup.profiles.last, Profile(name: "Previous", defaultRoute: "nl", apps: here.apps, sites: here.sites))
        XCTAssertNoThrow(try Backup.valid(once.setup))
        // Again, onto what that restore left, once the provider's list has named the pinned server's address again.
        var after = once.setup
        after.routes[4].loc.pinned?.ip = "203.0.113.66"; after.routes[4].loc.pinned?.load = 30
        let twice = Backup.plan(onto: after, from: b, keepPrevious: true, now: .now)
        XCTAssertEqual(twice.setup.routes, b.setup.routes)
        XCTAssertEqual(twice.setup.servers, b.setup.servers)
        XCTAssertEqual(twice.setup.profiles.map(\.name), ["Work", "Home", "Previous"])
        // Saved without keys: the same.
        let keyless = Backup.plan(onto: here, from: try read(here, keys: false), keepPrevious: true, now: .now)
        XCTAssertEqual(keyless.setup.routes.map(\.id), b.setup.routes.map(\.id))
        XCTAssertEqual(keyless.setup.servers.map(\.id), b.setup.servers.map(\.id))
    }

    func testARestoredSetupCompilesAndPassesTheEnginesCheck() throws {
        let r = Backup.restored(onto: Setup(), from: try read(full(), keys: false), keepPrevious: false, now: .now)
        var links: [String: Link] = [:]
        for route in r.activeRoutes where !LinkPicker.keyLeftOut(route, in: r) { links[route.id] = LinkPicker.imported(route) }
        let blocked = Set(r.activeRoutes.map(\.id)).subtracting(links.keys)
        let config = try Compiler.compile(Compiler.Input(setup: r, links: links, blocked: blocked,
                                                         apps: Dictionary(uniqueKeysWithValues: r.apps.keys.map { ($0, [Compiler.pattern(forPath: "/Applications/\($0).app", ignoringCase: true)]) }),
                                                         selfPattern: Compiler.pattern(forPath: "/Applications/unbraid.app", ignoringCase: true)))
        XCTAssertNoThrow(try ConfigVet.check(config))
        if let engine = try ProviderFixtures.engine() { XCTAssertNil(ProviderFixtures.engineRefusal(config, engine)) }
    }

    // MARK: Encoding unchanged

    /// Captured from the synthesized encoding before `keyless` existed: a setup without it is written exactly as before.
    func testRoutesAndServersWithoutKeylessAreWrittenAsBefore() throws {
        let k = "aGVsbG8taGVsbG8taGVsbG8taGVsbG8taGVsbG8tMTI="
        let wg = WgPeer(name: "Home box", privateKey: k, address: ["10.0.0.2/32"], publicKey: k, presharedKey: k, endpoint: "203.0.113.1:51820", allowedIps: ["0.0.0.0/0"], dns: ["10.0.0.1"], keepalive: 25)
        let wg2 = WgPeer(name: "Plain", privateKey: k, address: ["10.0.0.3/32"], publicKey: k, endpoint: "203.0.113.4:51820", allowedIps: ["0.0.0.0/0"])
        let ov = OvpnProfile(name: "Office", config: "client\n", username: "u", password: "p")
        let ss = SsProfile(name: "Outline", server: "2001:db8::1", port: 8388, method: "chacha20-ietf-poly1305", password: "pw", plugin: "obfs-local", pluginOpts: "obfs=http")
        let ss2 = SsProfile(name: "Bare", server: "203.0.113.5", port: 8388, method: "aes-256-gcm", password: "pw")
        let w = #"{"address":["10.0.0.2\/32"],"allowedIps":["0.0.0.0\/0"],"dns":["10.0.0.1"],"endpoint":"203.0.113.1:51820","keepalive":25,"mtu":1420,"name":"Home box","presharedKey":"\#(k)","privateKey":"\#(k)","publicKey":"\#(k)"}"#
        let w2 = #"{"address":["10.0.0.3\/32"],"allowedIps":["0.0.0.0\/0"],"dns":[],"endpoint":"203.0.113.4:51820","mtu":1420,"name":"Plain","privateKey":"\#(k)","publicKey":"\#(k)"}"#
        let o = #"{"config":"client\n","name":"Office","password":"p","username":"u"}"#
        let x = #"{"method":"chacha20-ietf-poly1305","name":"Outline","password":"pw","plugin":"obfs-local","pluginOpts":"obfs=http","port":8388,"server":"2001:db8::1"}"#
        let x2 = #"{"method":"aes-256-gcm","name":"Bare","password":"pw","port":8388,"server":"203.0.113.5"}"#
        let routes: [(Route, String)] = [
            (Route(id: "nl", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands")),
             #"{"hue":0,"id":"nl","loc":{"country":"Netherlands","countryCode":"NL","countryId":153,"provider":"nord"}}"#),
            (Route(id: "pin", loc: Location(provider: "mullvad", countryCode: "SE", country: "Sweden", city: "Gothenburg", region: "se-got", group: "g", proto: "openvpn_udp",
                                            pinned: Server(name: "se-got-wg-001", host: "h", ip: "198.51.100.1", publicKey: k, load: 3)), hue: 2, filter: true),
             #"{"filter":true,"hue":2,"id":"pin","loc":{"city":"Gothenburg","country":"Sweden","countryCode":"SE","group":"g","pinned":{"city":"","country":"","host":"h","ip":"198.51.100.1","load":3,"name":"se-got-wg-001","publicKey":"\#(k)"},"protocol":"openvpn_udp","provider":"mullvad","region":"se-got"}}"#),
            (Route(id: "w1", wg: wg, hue: 1, own: "s1", checkInternet: false), #"{"checkInternet":false,"hue":1,"id":"w1","loc":{"provider":"nord"},"own":"s1","wg":\#(w)}"#),
            (Route(id: "w2", wg: wg2), #"{"hue":0,"id":"w2","loc":{"provider":"nord"},"wg":\#(w2)}"#),
            (Route(id: "o1", ovpn: ov, own: "s2"), #"{"hue":0,"id":"o1","loc":{"provider":"nord"},"ovpn":\#(o),"own":"s2"}"#),
            (Route(id: "x1", ss: ss, own: "s3", checkInternet: true), #"{"checkInternet":true,"hue":0,"id":"x1","loc":{"provider":"nord"},"own":"s3","ss":\#(x)}"#),
            (Route(id: "x2", ss: ss2), #"{"hue":0,"id":"x2","loc":{"provider":"nord"},"ss":\#(x2)}"#),
            (Route(id: "t1", tsExit: "100.64.0.1", tsName: "box"), #"{"hue":0,"id":"t1","loc":{"provider":"nord"},"tsExit":"100.64.0.1","tsName":"box"}"#),
            (Route(id: "t2", tsExit: "100.64.0.2"), #"{"hue":0,"id":"t2","loc":{"provider":"nord"},"tsExit":"100.64.0.2"}"#),
        ]
        let servers: [(OwnServer, String)] = [
            (OwnServer(id: "s1", wg: wg), #"{"id":"s1","wg":\#(w)}"#), (OwnServer(id: "s4", wg: wg2), #"{"id":"s4","wg":\#(w2)}"#),
            (OwnServer(id: "s2", ovpn: ov), #"{"id":"s2","ovpn":\#(o)}"#), (OwnServer(id: "s3", ss: ss), #"{"id":"s3","ss":\#(x)}"#),
            (OwnServer(id: "s5", ss: ss2), #"{"id":"s5","ss":\#(x2)}"#),
        ]
        let sorted = JSONEncoder(); sorted.outputFormatting = [.sortedKeys]
        func keys(_ d: Data) throws -> Set<String> { Set(try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any]).keys) }
        for (r, before) in routes {
            XCTAssertEqual(String(decoding: try sorted.encode(r), as: UTF8.self), before, r.id)
            XCTAssertEqual(try keys(JSONEncoder().encode(r)), try keys(Data(before.utf8)), r.id)
            XCTAssertEqual(try JSONDecoder().decode(Route.self, from: Data(before.utf8)), r)
            var k = r; k.keyless = true
            let marked = try sorted.encode(k)
            XCTAssertEqual(try keys(marked), try keys(Data(before.utf8)).union(["keyless"]))
            XCTAssertEqual(try JSONDecoder().decode(Route.self, from: marked), k)
        }
        for (s, before) in servers {
            XCTAssertEqual(String(decoding: try sorted.encode(s), as: UTF8.self), before, s.id)
            XCTAssertEqual(try JSONDecoder().decode(OwnServer.self, from: Data(before.utf8)), s)
            var k = s; k.keyless = true
            XCTAssertEqual(try keys(sorted.encode(k)), try keys(Data(before.utf8)).union(["keyless"]))
            XCTAssertEqual(try JSONDecoder().decode(OwnServer.self, from: try sorted.encode(k)), k)
        }
        // Read strictly, a malformed mark fails like any other value.
        XCTAssertThrowsError(try SavedDecoding.$strict.withValue(true) { try JSONDecoder().decode(OwnServer.self, from: Data(#"{"id":"s","keyless":"yes"}"#.utf8)) })
    }

    // MARK: Parsers written back

    func testWireGuardAndShadowsocksRoundTripThroughTheirParsers() throws {
        XCTAssertEqual(try WgConf.parse(WgConf.text(wg), name: wg.name), wg)
        XCTAssertEqual(try WgConf.parse(WgConf.text(homeWg), name: homeWg.name), homeWg)
        var off = wg; off.keepalive = 0; off.presharedKey = nil; off.dns = []
        XCTAssertEqual(try WgConf.parse(WgConf.text(off), name: off.name), off)
        XCTAssertEqual(try Manual.parseSs(Manual.ssLink(ss), name: ss.name), ss)
        var bare = ss; bare.plugin = nil; bare.pluginOpts = nil; bare.server = "203.0.113.5"
        XCTAssertEqual(try Manual.parseSs(Manual.ssLink(bare), name: bare.name), bare)
        // Up to U+02FF: a password that starts with a combining mark joins the colon before it into one character, so
        // no import could have made it.
        var g = SystemRandomNumberGenerator()
        for i in 0..<200 {
            let pw = String(String.UnicodeScalarView((0...Int.random(in: 0..<30, using: &g)).compactMap { _ in Unicode.Scalar(UInt32.random(in: 0x21...0x2FF, using: &g)) }))
            var p = ss; p.password = pw; p.pluginOpts = "obfs=tls;obfs-host=\(i).example"
            XCTAssertEqual(try Manual.parseSs(Manual.ssLink(p), name: p.name), p, pw)
        }
    }

    // MARK: Words

    func testTheSheetsSentences() {
        let design = Backup.Summary(routes: 4, apps: 11, websites: 5, profiles: 2, servers: 1)
        XCTAssertEqual(Backup.holds(design), "It holds 4 routes, 11 app choices, 5 websites, 2 profiles and 1 own server.")
        XCTAssertEqual(Backup.inBackup(Backup.Summary(routes: 4, apps: 11, websites: 5, profiles: 2, servers: 1, keyless: 1)),
                       "4 routes, 11 app choices, 5 websites, 2 profiles, 1 own server without its keys")
        XCTAssertEqual(Backup.replaces(Backup.Summary(routes: 3, apps: 8, profiles: 1)),
                       "Your 3 routes, 8 app choices and 1 profile on this Mac. Provider sign-ins, your Tailscale sign-in and statistics stay as they are.")
        // Singular, plural, and nothing said of what there is none of.
        XCTAssertEqual(Backup.holds(Backup.Summary(routes: 1)), "It holds 1 route.")
        XCTAssertEqual(Backup.holds(Backup.Summary(routes: 1, websites: 2)), "It holds 1 route and 2 websites.")
        XCTAssertEqual(Backup.holds(Backup.Summary(apps: 1, servers: 3, homeTunnel: true)), "It holds 1 app choice, 3 own servers and the Home WireGuard tunnel.")
        XCTAssertEqual(Backup.holds(Backup.Summary()), "It holds your preferences.")
        XCTAssertEqual(Backup.inBackup(Backup.Summary(routes: 2, servers: 3, keyless: 3)), "2 routes, 3 own servers without their keys")
        XCTAssertEqual(Backup.inBackup(Backup.Summary(routes: 2, servers: 3, keyless: 1)), "2 routes, 3 own servers (1 without keys)")
        XCTAssertEqual(Backup.inBackup(Backup.Summary(routes: 1, profiles: 1, servers: 2, homeTunnel: true)), "1 route, 1 profile, 2 own servers, the Home WireGuard tunnel")
        XCTAssertEqual(Backup.inBackup(Backup.Summary()), "Preferences only")
        XCTAssertEqual(Backup.replaces(Backup.Summary(routes: 1, apps: 1, websites: 1, profiles: 2, servers: 1, homeTunnel: true)),
                       "Your 1 route, 1 app choice, 1 website, 2 profiles, 1 own server and Home WireGuard tunnel on this Mac. Provider sign-ins, your Tailscale sign-in and statistics stay as they are.")
        XCTAssertEqual(Backup.replaces(Backup.Summary()), "Nothing set up on this Mac yet. Provider sign-ins, your Tailscale sign-in and statistics stay as they are.")
    }

    func testPassphraseStrengthIsAndroidsRule() {
        XCTAssertEqual(Backup.strength(""), .easy)
        XCTAssertEqual(Backup.strength("abc123"), .easy)
        XCTAssertEqual(Backup.strength("abcdefghij"), .easy)
        XCTAssertEqual(Backup.strength("qjxv7mwz3k"), .fair)
        XCTAssertEqual(Backup.strength("Tr0ub4dor&3"), .hard)
        XCTAssertEqual(Backup.strength("correct horse battery staple"), .hard)
        XCTAssertEqual(Backup.strength("ab cd ef gh"), .fair)
        XCTAssertEqual(Backup.strength("ab cd"), .easy)
        XCTAssertEqual(Backup.Strength.hard.text, "Hard to guess")
        XCTAssertTrue(Backup.Strength.easy.text.hasPrefix("Easy to guess"))
        // Length alone is no sign of a passphrase picked at random: repeats, runs, repeated words and common passwords
        // add almost nothing, and never let keys into the file.
        for trivial in ["aaaaaaaaaaaaaaaa", "aaaa aaaa aaaa aaaa", "horse horse horse horse", "abcdefghijk1", "abcdefghijklmnopqrstuvwxyz",
                        "1234567890123456", "password1234", "Password1234!", "qwertyqwertyqwerty", "abcabcabcabcabcabc", "zyxwvutsrqponmlk", "aaa bbb ccc ddd"] {
            XCTAssertEqual(Backup.strength(trivial), .easy, trivial)
            XCTAssertFalse(BackupTexts.saveCheck(trivial, trivial, keys: true).ready, trivial)
        }
        XCTAssertEqual(Backup.strength("correct horse battery staple"), .hard)
    }

    // MARK: The sheets' rules

    func testSaveBackupWaitsForTwoMatchingPassphrases() {
        let hard = "correct horse battery staple"
        XCTAssertEqual(BackupTexts.saveCheck("", "", keys: false), .init(ready: false))
        XCTAssertEqual(BackupTexts.saveCheck(hard, "", keys: false), .init(ready: false))
        // Still typing the second: nothing said yet.
        XCTAssertEqual(BackupTexts.saveCheck(hard, "correct", keys: false), .init(ready: false))
        XCTAssertEqual(BackupTexts.saveCheck(hard, "correct horse battery stapel", keys: false), .init(ready: false, problem: "The passphrases don't match"))
        XCTAssertEqual(BackupTexts.saveCheck(hard, hard + "s", keys: false), .init(ready: false, problem: "The passphrases don't match"))
        XCTAssertEqual(BackupTexts.saveCheck(hard, hard, keys: false), .init(ready: true))
        // Easy to guess is only a hint, until keys go in the file; but never shorter than 8 characters, said once the
        // second field is being typed.
        XCTAssertEqual(BackupTexts.saveCheck("abc", "abc", keys: false), .init(ready: false, problem: "Use 8 or more characters"))
        XCTAssertEqual(BackupTexts.saveCheck("abc", "", keys: false), .init(ready: false))
        XCTAssertEqual(BackupTexts.saveCheck("abcd1234", "abcd1234", keys: false), .init(ready: true))
        XCTAssertEqual(BackupTexts.saveCheck("abc", "abc", keys: true), .init(ready: false, problem: "Choose a passphrase that is harder to guess to include keys"))
        XCTAssertEqual(BackupTexts.saveCheck("abc", "", keys: true).ready, false)
        XCTAssertEqual(BackupTexts.saveCheck("qjxv7mwz3k", "qjxv7mwz3k", keys: true), .init(ready: true))
        XCTAssertEqual(BackupTexts.saveCheck(hard, hard, keys: true), .init(ready: true))
        XCTAssertEqual([Backup.Strength.easy, .fair, .hard].map(BackupTexts.segments), [1, 2, 3])
    }

    func testTheSheetsWords() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(BackupTexts.fileName(Date(timeIntervalSince1970: 1_794_960_000), calendar: utc), "unbraid-backup-2026-11-18.unbraidbackup")
        XCTAssertEqual(BackupTexts.fileName(Date(timeIntervalSince1970: 1_767_225_600), calendar: utc), "unbraid-backup-2026-01-01.unbraidbackup")
        let c = try read(full())
        XCTAssertEqual(BackupTexts.restoreFacts(file: "b.unbraidbackup", c, locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!),
                       "b.unbraidbackup · saved 14 Nov 2023 with unbraid 1.2.0")
        // The version comes from the file: shown only when it is a short plain version string.
        for odd in ["1.2.0 \u{202E}checked and safe", String(repeating: "9", count: 40), "safe to restore", "", "\n1.2"] {
            var top = try XCTUnwrap(JSONSerialization.jsonObject(with: Backup.export(full(), app: "1.2.0", created: Date(timeIntervalSince1970: 1_700_000_000), keys: true)) as? [String: Any])
            top["app"] = odd
            let shown = try Backup.read(JSONSerialization.data(withJSONObject: top))
            XCTAssertEqual(shown.app, "", odd)
            XCTAssertEqual(BackupTexts.restoreFacts(file: "b.unbraidbackup", shown, locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!),
                           "b.unbraidbackup · saved 14 Nov 2023 with unbraid", odd)
        }
        XCTAssertEqual(Backup.version("2.9.1-beta+3"), "2.9.1-beta+3")
        XCTAssertEqual(BackupTexts.openFailure(.wrongPassphrase), "That passphrase doesn't open this backup")
        XCTAssertEqual(BackupTexts.openFailure(.damaged), "This backup is damaged and can't be opened")
        XCTAssertEqual(BackupTexts.openFailure(.notABackup), "That isn't an unbraid backup")
        // Every failure has its own sentence.
        let all: [BackupFile.Failure] = [.tooLarge, .notABackup, .newer, .damaged, .wrongPassphrase, .memory]
        XCTAssertEqual(Set(all.map(BackupTexts.openFailure)).count, all.count)
        XCTAssertEqual(BackupTexts.saveFailure(BackupFile.Failure.tooLarge), "This setup is too large for a backup")
        XCTAssertEqual(BackupTexts.saveFailure(CocoaError(.fileWriteNoPermission)), "The backup couldn't be saved there. Choose another folder and try again.")
        XCTAssertEqual(BackupTexts.keepTitle(nil), "Keep my current setup as the profile \"Previous\"")
        XCTAssertEqual(BackupTexts.keepTitle("Previous 2"), "Keep my current setup as the profile \"Previous 2\"")
        // What the kept profile holds, and the way out when the backup's own profiles leave no room (deleting one here can't).
        XCTAssertEqual(BackupTexts.keepCaption, "It keeps your routes and your app and website choices, not your settings. You can switch back to it from Profiles.")
        XCTAssertEqual(BackupTexts.keepUnavailable, "No room to keep it: this backup already has 20 profiles. Restore without keeping it.")
        XCTAssertEqual(BackupTexts.wrongKind("OpenVPN", needs: "WireGuard"), "That is an OpenVPN config; this server needs a WireGuard one")
        XCTAssertEqual(BackupTexts.wrongKind("Shadowsocks", needs: "OpenVPN"), "That is a Shadowsocks config; this server needs an OpenVPN one")
        XCTAssertEqual(BackupTexts.restoredNotice(signedIn: true), "Settings restored.")
        XCTAssertTrue(BackupTexts.isGood(BackupTexts.restoredNotice(signedIn: false)))
        XCTAssertTrue(BackupTexts.isGood("Backup saved."))
        XCTAssertFalse(BackupTexts.isGood("Backup saved.\nSomething else"))
        // Notices queue one per line: each is judged by itself, and one said twice shows once.
        let queued = BackupTexts.lines("Backup saved.\nBackup saved.\nSettings restored.\nThe backup wasn't restored. Nothing changed.")
        XCTAssertEqual(queued.map(\.text), ["Backup saved.", "Settings restored.", "The backup wasn't restored. Nothing changed."])
        XCTAssertEqual(queued.map(\.good), [true, true, false])
        XCTAssertEqual(BackupTexts.lines("Couldn't switch.\nBackup saved.").map(\.good), [false, true])
        // What the save sheet says the file holds follows the keys switch: the Home WireGuard tunnel only with keys.
        XCTAssertTrue(BackupTexts.saveFacts(full(), keys: true).hasSuffix("3 own servers and the Home WireGuard tunnel."))
        XCTAssertTrue(BackupTexts.saveFacts(full(), keys: false).hasSuffix("and 3 own servers."))
        XCTAssertTrue(BackupTexts.saveFacts(full(), keys: false).hasPrefix("One file, locked with a passphrase you choose. It holds 6 routes"))
    }

    func testTheRestoreNotesSayOnlyWhatIsTrue() throws {
        let mullvad = ["mullvad": "blob"]
        // The backup without keys, onto this Mac with nothing set up: three servers wait, the provider route waits for a
        // sign-in, and protection changes.
        let c = try read(full(), keys: false)
        let plan = Backup.plan(onto: Setup(), from: c, keepPrevious: true, now: .now)
        XCTAssertEqual(BackupTexts.restoreNotes(plan, accounts: [:], tunnelUp: true), [
            "\"Home box\", \"Office\" and \"Outline é\" need their config again before their apps can connect.",
            "Routes on a provider you aren't signed in to stay blocked until you sign in.",
            "The kill switch or Connect on Demand setting changes, so the VPN restarts.",
        ])
        // The "nl" route has no provider set: the default one, which has to be signed in to as well.
        let nlProvider = try XCTUnwrap(c.setup.route("nl")).loc.provider
        XCTAssertEqual(BackupTexts.restoreNotes(plan, accounts: [nlProvider: "a", "mullvad": "b"], tunnelUp: false).count, 1)
        // With keys and the same protection, connected: only the reconnect.
        var here = full()
        here.prefs = c.setup.prefs
        let same = Backup.plan(onto: here, from: try read(full()), keepPrevious: false, now: .now)
        XCTAssertFalse(same.protectionChanges)
        XCTAssertEqual(BackupTexts.restoreNotes(same, accounts: [nlProvider: "a"].merging(mullvad) { $1 }, tunnelUp: true), ["The VPN reconnects for a moment."])
        XCTAssertEqual(BackupTexts.restoreNotes(same, accounts: [nlProvider: "a"].merging(mullvad) { $1 }, tunnelUp: false), [])
        // One server: singular.
        var one = full()
        one.servers = [OwnServer(id: "s1", wg: wg)]; one.routes.removeAll { $0.id == "o1" || $0.id == "x1" }
        one.apps = one.apps.filter { $0.value != "x1" && $0.value != "o1" }; one.sites = [:]; one.profiles = []; one.profile = nil
        let single = Backup.plan(onto: Setup(), from: try read(one, keys: false), keepPrevious: false, now: .now)
        XCTAssertEqual(BackupTexts.restoreNotes(single, accounts: [nlProvider: "a", "mullvad": "b"], tunnelUp: false),
                       ["\"Home box\" needs its config again before its apps can connect."])
        // A backup with keys and no Home WireGuard tunnel removes this Mac's: said by name. Without keys it stays.
        var noHome = full()
        noHome.home.wg = nil
        let withHome = here.with { $0.home.wg = self.homeWg }
        let dropped = Backup.plan(onto: withHome, from: try read(noHome), keepPrevious: true, now: .now)
        XCTAssertTrue(dropped.dropsHome)
        XCTAssertEqual(BackupTexts.restoreNotes(dropped, accounts: [nlProvider: "a"].merging(mullvad) { $1 }, tunnelUp: false),
                       ["The Home WireGuard tunnel on this Mac is removed: this backup has none."])
        XCTAssertFalse(Backup.plan(onto: withHome, from: try read(noHome, keys: false), keepPrevious: true, now: .now).dropsHome)
        XCTAssertFalse(Backup.plan(onto: withHome, from: try read(full()), keepPrevious: true, now: .now).dropsHome)
    }

    func testUnlockTellsAWrongPassphraseFromTheRest() throws {
        let file = try BackupFile.seal(Backup.export(full(), app: "1.2.0", created: .now, keys: false), passphrase: "right one", logN: 10, r: 8, p: 1)
        XCTAssertEqual(try Backup.unlock(file, passphrase: "right one").get().setup, Backup.contents(full(), keys: false))
        XCTAssertEqual(Backup.unlock(file, passphrase: "wrong one").error, Backup.Refusal(message: "That passphrase doesn't open this backup", wrongPassphrase: true))
        var cut = file; cut.removeLast()
        XCTAssertEqual(Backup.unlock(cut, passphrase: "right one").error, Backup.Refusal(message: "This backup is damaged and can't be opened"))
        // Opens, but what is inside isn't this Mac's.
        let android = try BackupFile.seal(Data(#"{"format":1,"app":"2.9.1","created":1,"setup":{"version":2}}"#.utf8), passphrase: "p", logN: 10, r: 8, p: 1)
        XCTAssertEqual(Backup.unlock(android, passphrase: "p").error?.message, Backup.Failure.otherPlatform.message)
        XCTAssertEqual(Backup.unlock(android, passphrase: "p").error?.wrongPassphrase, false)
    }

    func testABackupIsWrittenInOneStepForTheUserOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: BackupTexts.fileName(.now))
        try BackupFile.save(full(), app: "1.2.0", keys: false, passphrase: "correct horse battery staple", to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let data = try BackupFile.readChosen(url)
        let c = try Backup.read(BackupFile.open(data, passphrase: "correct horse battery staple"))
        XCTAssertEqual(c.setup, Backup.contents(full(), keys: false))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Home box"))
        // Saved again over it: replaced whole, nothing left beside it.
        try BackupFile.write(Data("UNBRAID-BACKUP\nsecond".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("UNBRAID-BACKUP\nsecond".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [url.lastPathComponent])
        XCTAssertTrue(BackupFile.looksLikeBackup(at: url))
        // A name as long as a file name may be (255 bytes): the file beside it while writing has a short name of its own.
        let longest = dir.appending(path: String(repeating: "b", count: 255 - BackupFile.fileExtension.count - 1) + "." + BackupFile.fileExtension)
        try BackupFile.write(Data("UNBRAID-BACKUP\nlong".utf8), to: longest)
        XCTAssertEqual(try Data(contentsOf: longest), Data("UNBRAID-BACKUP\nlong".utf8))
        try FileManager.default.removeItem(at: longest)
        // A folder that can't be written: an error, and nothing written.
        XCTAssertThrowsError(try BackupFile.write(Data("x".utf8), to: dir.appending(path: "missing/file")))
        // Chosen files that aren't backups, or are too large to be, are refused before being read whole.
        let other = dir.appending(path: "other.conf")
        try Data("[Interface]\n".utf8).write(to: other)
        XCTAssertFalse(BackupFile.looksLikeBackup(at: other))
        XCTAssertThrowsError(try BackupFile.readChosen(other)) { XCTAssertEqual($0 as? BackupFile.Failure, .notABackup) }
        let big = dir.appending(path: "big.unbraidbackup")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(BackupFile.maxSize + 1)); try h.close()
        XCTAssertThrowsError(try BackupFile.readChosen(big)) { XCTAssertEqual($0 as? BackupFile.Failure, .tooLarge) }
    }
}

private extension Setup {
    func with(_ change: (inout Setup) -> Void) -> Setup { var s = self; change(&s); return s }
}

private extension Result {
    var error: Failure? { if case .failure(let e) = self { e } else { nil } }
}

private extension Backup.Content {
    func with(_ change: (inout Backup.Content) -> Void) -> Backup.Content { var c = self; change(&c); return c }
}
