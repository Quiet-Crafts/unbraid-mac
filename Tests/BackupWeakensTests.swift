import XCTest

/// What a restore says it weakens, judged by what each app, website and the default route effectively get, and how hard
/// a passphrase is to guess: generated pairs and passphrases, plus the cases that were missed before.
final class BackupWeakensTests: XCTestCase {
    private struct RNG: RandomNumberGenerator {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func pick<T>(_ a: [T]) -> T { a[Int.random(in: 0..<a.count, using: &self)] }
        mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &self) }
        mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
    }

    private let key = String(repeating: "A", count: 42) + "E=", peer = String(repeating: "B", count: 42) + "E="
    private func wg(_ endpoint: String = "203.0.113.1:51820", dns: String = "10.0.0.1") -> WgPeer {
        try! WgConf.parse("[Interface]\nPrivateKey = \(key)\nAddress = 10.0.0.2/32\nDNS = \(dns)\n[Peer]\nPublicKey = \(peer)\nEndpoint = \(endpoint)\nAllowedIPs = 0.0.0.0/0\n", name: "Work")
    }

    /// Routes: Nord (blocking on), Mullvad (blocking off), an own WireGuard server.
    private func base() -> Setup {
        var s = Setup()
        s.routes = [Route(id: "nl", loc: Location(countryId: 153, countryCode: "NL", country: "Netherlands")),
                    Route(id: "m1", loc: Location(provider: "mullvad", countryCode: "SE", country: "Sweden")),
                    Route(id: "w1", wg: wg(), own: "s1")]
        s.servers = [OwnServer(id: "s1", wg: wg())]
        s.opts = ["nord": ["protect": "on"], "mullvad": ["protect": "off"]]
        return s
    }

    // MARK: Generated pairs

    private func random(_ g: inout RNG) -> Setup {
        var s = base()
        let targets = ["nl", "m1", "w1", DIRECT, BLOCK, "gone"]
        s.defaultRoute = g.pick(["nl", "m1", "w1", DIRECT])
        for a in ["a", "b", "c", "d"] where g.chance(0.6) { s.apps["org.example.\(a)"] = g.pick(targets.filter { $0 != "gone" }) }
        for n in ["example.com", "cdn.example.com", "a.cdn.example.com", "tracker.example", "x.tracker.example", "nas.lan"] where g.chance(0.5) {
            s.sites[n] = g.pick(targets.filter { $0 != "gone" })
        }
        if g.chance(0.5) {
            s.prefs.filter = Filter(id: g.pick(["quad9", "adguard"]), routes: g.chance(0.5), direct: g.chance(0.5), directApps: g.chance(0.5),
                                    apps: g.chance(0.5) ? ["org.example.\(g.pick(["a", "b", "e"]))": g.chance(0.5)] : [:])
        }
        if g.chance(0.3) { s.opts["mullvad"] = ["protect": "on"] }
        if g.chance(0.3) { s.routes[0].filter = false }
        return s
    }

    /// The model: anything that gets weaker produces a note; a restore that changes nothing the traffic gets, and no
    /// setting, produces none.
    func testEveryWeakeningIsSaidAndNothingElse() {
        var g = RNG(0x7E57)
        var problems: [String] = []
        for _ in 0..<4000 {
            let here = random(&g)
            // Half the time a small change of here, half another setup.
            var next = here
            if g.chance(0.5) { next = random(&g) } else {
                switch g.int(0...3) {
                case 0: next.apps["org.example.\(g.pick(["a", "b", "e"]))"] = g.pick(["nl", "m1", "w1", DIRECT, BLOCK])
                case 1: next.sites[g.pick(["example.com", "cdn.example.com", "x.tracker.example", "nas.lan"])] = g.pick(["nl", "m1", DIRECT, BLOCK])
                case 2: next.prefs.filter.apps["org.example.\(g.pick(["a", "c"]))"] = g.chance(0.5)
                default: next.defaultRoute = g.pick(["nl", "m1", "w1", DIRECT])
                }
            }
            let said = Backup.weakens(here, next)
            let l = Backup.lost(here, next)
            let weaker = l.defaultRoute != nil || !l.apps.isEmpty || !l.sites.isEmpty
            if weaker && said.isEmpty { problems.append("weaker but nothing said: \(here.apps) \(here.sites) → \(next.apps) \(next.sites)") }
            // Nothing the traffic gets changed, and no setting: nothing to say.
            let apps = Set(here.apps.keys).union(next.apps.keys).union(here.prefs.filter.apps.keys).union(next.prefs.filter.apps.keys)
            let sites = Set(Sites.applied(here).keys).union(Sites.applied(next).keys)
            if Backup.traffic(here, apps: apps, sites: sites) == Backup.traffic(next, apps: apps, sites: sites), here.prefs == next.prefs, here.opts == next.opts,
               here.routes == next.routes, !said.isEmpty {
                problems.append("nothing changed but said \(said): \(here.apps) \(here.sites) → \(next.apps) \(next.sites)")
            }
        }
        XCTAssertEqual(problems.count, 0, problems.prefix(5).joined(separator: "\n"))
    }

    /// Every nesting of website rules: "blocked" is said exactly when some name blocked here (or under one) would no
    /// longer be, by the most specific applied rule.
    func testRestoresThatOpenAHoleUnderABlockInEveryNesting() {
        var g = RNG(0x401E)
        let chain = ["n.example", "b.n.example", "c.b.n.example", "d.c.b.n.example", "o.example", "nas.lan", "x.nas.lan"]
        let probes = chain.flatMap { [$0, "zz9." + $0, "q.zz9." + $0] }
        func gets(_ name: String, _ rules: [String: String]) -> String? {
            Sites.applied(Setup(routes: [], defaultRoute: DIRECT, apps: [:], sites: rules)).filter { Sites.under(name, $0.key) }.max { $0.key.count < $1.key.count }?.value
        }
        var problems: [String] = []
        for _ in 0..<3000 {
            var here = base(), next = here
            for name in chain {
                if g.chance(0.5) { here.sites[name] = g.pick([BLOCK, BLOCK, DIRECT, "nl", "w1"]) }
                if g.chance(0.5) { next.sites[name] = g.chance(0.6) ? here.sites[name] ?? g.pick([BLOCK, DIRECT, "nl"]) : g.pick([BLOCK, DIRECT, "nl", "w1"]) }
            }
            let opened = probes.filter { gets($0, here.sites) == BLOCK && gets($0, next.sites) != BLOCK }
            let said = Backup.weakens(here, next).filter { $0.contains("blocked") }
            if !opened.isEmpty && said.isEmpty { problems.append("opens \(opened) but says nothing: \(here.sites) → \(next.sites)") }
            if opened.isEmpty && !said.isEmpty { problems.append("opens nothing but says \(said): \(here.sites) → \(next.sites)") }
        }
        XCTAssertEqual(problems.count, 0, problems.prefix(5).joined(separator: "\n"))
    }

    // MARK: Cases missed before

    func testWebsitesByWhatTheyEffectivelyGet() {
        var here = base()
        here.defaultRoute = "nl"
        here.sites = ["example.com": "nl", "nas.lan": "nl"]
        // A child added on a route without blocking, or on Direct: the part under it loses what it had.
        XCTAssertEqual(Backup.weakens(here, here.with { $0.sites["cdn.example.com"] = "m1" }), ["1 website loses the provider's ad and tracker blocking it has now."])
        XCTAssertEqual(Backup.weakens(here, here.with { $0.sites["cdn.example.com"] = DIRECT }), ["1 website goes from a VPN route to Direct."])
        // A rule removed: it goes as its app does.
        XCTAssertEqual(Backup.weakens(here.with { $0.defaultRoute = DIRECT }, here.with { $0.defaultRoute = DIRECT; $0.sites["example.com"] = nil }),
                       ["1 website loses its own VPN route and goes as its app does."])
        // A rule that never applies (a name on the own network) changes no traffic: nothing said.
        XCTAssertEqual(Backup.weakens(here, here.with { $0.sites["nas.lan"] = DIRECT }), [])
    }

    func testAnAppLeavingTheFilteredDirectScopeIsSaid() {
        var here = base()
        here.defaultRoute = "nl"
        here.apps = ["com.example.browser": DIRECT]
        here.prefs.filter = Filter(id: "quad9", routes: false, directApps: true)
        XCTAssertEqual(Backup.weakens(here, here.with { $0.apps["com.example.browser"] = "m1" }), ["1 app loses the DNS filter."])
        XCTAssertEqual(Backup.weakens(here, here.with { $0.apps["com.example.browser"] = "nl" }), ["1 app loses the DNS filter."])
        XCTAssertEqual(Backup.weakens(here.with { $0.prefs.filter.routes = true }, here.with { $0.prefs.filter.routes = true; $0.apps["com.example.browser"] = "m1" }), [])
    }

    func testLongHostsAreComparedWhole() {
        let long = String(repeating: "a", count: 63) + "." + String(repeating: "b", count: 30)
        var here = base()
        here.routes.append(Route(id: "x1", ss: SsProfile(name: "Shadow", server: long + ".old.example", port: 8388, method: "chacha20-ietf-poly1305", password: "pw")))
        let next = here.with { $0.routes[3].ss?.server = long + ".new.example" }
        let said = Backup.weakens(here, next)
        XCTAssertEqual(said.count, 1)
        XCTAssertTrue(said[0].hasPrefix("\"Shadow\" connects to …"), said[0])
        XCTAssertTrue(said[0].contains("new.example instead of …"), said[0])
        // A bound route changed on its own, the server entry as it was.
        XCTAssertEqual(Backup.weakens(here, here.with { $0.routes[2].wg?.endpoint = long + ".new.example:51820" }).count, 1)
    }

    // MARK: Passphrases

    func testThePassphraseJudge() {
        var g = RNG(0x9A55)
        var wrong: [String] = []
        let stems = ["horse", "pass", "word", "test", "summer", "london", "Pass", "ab12", "password"]
        let seps = [" ", "-", "_", ".", ",", "/", "+", "|", ":", ";", "*", "~", "", "  ", "\t", "!", "#", "@", "=", "\\"]
        for _ in 0..<4000 {
            let stem = g.pick(stems), sep = g.pick(seps), n = g.int(4...10)
            let p = (1...n).map { stem + (g.chance(0.5) ? String($0 % 10) : "") }.joined(separator: sep)
            if Backup.strength(p) == .hard { wrong.append("repeat: \(p.debugDescription)") }
        }
        let trivial = ["password1 password2 password3 password4 password5 password6 password7 password8 password9 password0",
                       "word1 word2 word3 word4 word5 word6 word7 word8", "horse1+horse2+horse3+horse4+horse5+horse6",
                       "qwertyuiop", "asdfghjkl;", "zxcvbnm,./", "1qaz2wsx3edc4rfv", "!QAZ2wsx#EDC4rfv", "zaq1xsw2cde3vfr4", "qazwsxedcrfvtgbyhn",
                       "1q2w3e4r5t6y7u8i", "qwertzuiopasdfgh", "azertyuiopqsdfgh", "poiuytrewqlkjhgf", "mnbvcxzlkjhgfdsa", "1234qwerasdfzxcv",
                       "q1w2e3r4t5y6u7i8o9p0", "aaaaaaaaaaaaaaaaaaaaaaaa", "abcabcabcabcabcabc", "Password1234!", "qwertyqwertyqwerty",
                       "unbraid unbraid unbraid unbraid", "1234567890123456", "abcdefghijklmnopqrstuvwxyz", "Aa1!Aa1!Aa1!Aa1!"]
        for p in trivial where Backup.strength(p) == .hard { wrong.append("trivial: \(p)") }
        // Canonically equivalent spellings.
        let pairs = [("caf\u{E9} cr\u{E8}me br\u{FB}l\u{E9}e na\u{EF}ve", "cafe\u{301} cre\u{300}me bru\u{302}le\u{301}e nai\u{308}ve"),
                     ("\u{1E69}\u{1E69}\u{1E69}Zebra42!", "s\u{323}\u{307}s\u{307}\u{323}\u{1E61}\u{323}Zebra42!"), ("\u{F1}and\u{FA} p\u{E9}rez", "n\u{303}andu\u{301} pe\u{301}rez")]
        for (a, b) in pairs where Backup.strength(a) != Backup.strength(b) || BackupTexts.saveCheck(a, a, keys: true) != BackupTexts.saveCheck(b, b, keys: true) {
            wrong.append("equivalent forms judged apart: \(a)")
        }
        // Random passphrases, word phrases (one word repeated), other scripts and emoji: hard.
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!#$%&*+-=?@")
        let random = (0..<500).filter { _ in Backup.strength(String((0..<16).map { _ in g.pick(alphabet) })) != .hard }.count
        XCTAssertLessThan(random, 25)
        let syll = ["ba", "ko", "ri", "tem", "lu", "mor", "vash", "pel", "dri", "qua", "zon", "fi", "gut", "hes", "jor", "nix", "sal", "wey"]
        var list = Set<String>()
        while list.count < 300 { list.insert(g.pick(syll) + g.pick(syll) + (g.chance(0.5) ? g.pick(syll) : "")) }
        let words = Array(list).sorted()
        for _ in 0..<1000 {
            var phrase = (0..<g.int(5...7)).map { _ in g.pick(words) }
            phrase.insert(phrase[g.int(0...(phrase.count - 1))], at: g.int(0...phrase.count))
            let p = phrase.joined(separator: g.pick([" ", "-", " "]))
            if Backup.strength(p) != .hard { wrong.append("word phrase not hard: \(p)") }
        }
        let han = Array("春湖雲島夢舟雪鳥星野森雨月風花海山川空石竹松梅桜光")
        let flags = ["🇳🇱", "🇯🇵", "🇧🇷", "🇲🇦", "🇳🇿", "🇫🇮", "🇲🇽", "🇰🇷", "🇵🇹", "🇨🇦", "🇮🇳", "🇬🇭", "🇳🇴", "🇨🇱", "🇵🇭", "🇩🇪", "🇮🇹", "🇪🇸", "🇸🇪", "🇦🇷"]
        let cyrillic = Array("абвгдежзиклмнопрстуфхцчшщэюя")
        for _ in 0..<200 {
            let a = String((0..<16).map { _ in g.pick(han) }), b = (0..<16).map { _ in g.pick(flags) }.joined()
            let c = (0..<5).map { _ in String((0..<6).map { _ in g.pick(cyrillic) }) }.joined(separator: " ")
            for p in [a, b, c] where Backup.strength(p) != .hard { wrong.append("other script not hard: \(p)") }
        }
        XCTAssertEqual(Backup.strength("🇳🇱🇯🇵🇧🇷🇲🇦🇳🇿🇫🇮🇲🇽🇰🇷🇵🇹🇨🇦🇮🇳🇬🇭🇳🇴🇨🇱🇵🇭🇩🇪"), .hard)
        XCTAssertEqual(Backup.strength("春湖雲島夢舟雪鳥星野森雨月風花海"), .hard)
        // One character of another kind doesn't lift the rest.
        XCTAssertEqual(Backup.strength("dog€x"), .easy)
        XCTAssertEqual(Backup.strength("summer😀"), .easy)
        XCTAssertNotEqual(Backup.strength("summer2024€"), .hard)
        let t = Date()
        _ = Backup.strength(String(repeating: "correct horse ", count: 20_000))
        XCTAssertLessThan(Date().timeIntervalSince(t), 1)
        XCTAssertEqual(wrong.prefix(20), [])
    }
}

private extension Setup {
    func with(_ change: (inout Setup) -> Void) -> Setup { var s = self; change(&s); return s }
}
