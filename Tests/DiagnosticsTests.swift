import XCTest

final class DiagnosticsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testNextDNSProfileIsRedactedFromEngineErrors() {
        let config = #"{"dns":{"servers":[{"type":"https","server":"45.90.28.0","path":"/AliceProfile"}]}}"#
        let values = Diagnostics.values(of: config)
        XCTAssertTrue(values.contains("AliceProfile"))
        XCTAssertFalse(Diagnostics.clean("profile AliceProfile refused", values: values).contains("AliceProfile"))
        let shortConfig = #"{"dns":{"servers":[{"server":"45.90.28.0","path":"/ab"}]}}"#
        XCTAssertFalse(Diagnostics.clean("profile ab refused", values: Diagnostics.values(of: shortConfig)).contains("ab"))
    }

    func testCleaningDropsAddressesHostsAccountsAndSecrets() {
        let raw = """
        dial tcp 185.65.134.1:51820 and 10.64.0.0/10 via fd7a:115c:a1e0::1%utun4, ::ffff:192.168.1.2 and fe80::1/64; \
        login https://user:pw@hs.example.com/register/abc at vpn.example.com(offline) for mac.tail1234.ts.net, \
        account=1234567890123456 Bearer abc.def invalid key: c2VjcmV0YWJjZGVmZ2g= in /Users/alice/x mail me@home.lan
        """
        let out = Diagnostics.clean(raw)
        for leak in ["185.65", "51820", "10.64", "fd7a", "utun4", "192", "168.1.2", "fe80", "hs.example", "user:pw", "vpn.example", ".com",
                     "tail1234", "1234567890123456", "abc.def", "c2VjcmV0", "alice", "me@home"] {
            XCTAssertFalse(out.contains(leak), "\(leak) in \(out)")
        }
        XCTAssertTrue(out.hasPrefix("dial tcp [address]"), out)
    }

    func testCleaningDropsAnImportedConfigsOwnWords() {
        let out = Diagnostics.clean(#"initialize endpoints[1]: parse address: netip.ParseAddr("alice-pc"): unable to parse IP; peer YWJjZGVmYWJjZGVm on alice-pc2 via dns.home and route.local"#)
        for leak in ["alice", "YWJj", "dns.home", "route.local"] { XCTAssertFalse(out.contains(leak), "\(leak) in \(out)") }
        XCTAssertTrue(out.hasPrefix("initialize endpoints[1]: parse address:"), out)
    }

    func testAQuoteLeftOpenByTheCutHidesTheRest() {
        let engine = Redact.clean("parse address: netip.ParseAddr(\"" + String(repeating: "alice home private ", count: 10) + "\"): bad")
        let out = Diagnostics.clean(engine)
        XCTAssertFalse(out.contains("alice"), out)
        XCTAssertTrue(out.hasPrefix("parse address: [host]([value]"), out) // a Go package path reads as a host: masked too
    }

    func testCleaningKeepsWhatSupportNeeds() {
        XCTAssertEqual(Diagnostics.clean("decode config at route.rules[3].process_path_regex: missing field"),
                       "decode config at route.rules[3].process_path_regex: missing field")
        XCTAssertEqual(Diagnostics.clean("initialize outbounds[2]: parse wireguard: invalid private key"),
                       "initialize outbounds[2]: parse wireguard: invalid private key")
        XCTAssertEqual(Diagnostics.clean("missing ipv4 address for tcp4"), "missing ipv4 address for tcp4")
        XCTAssertEqual(Diagnostics.clean(nil), "")
    }

    /// The extension already cut the engine's text at 160 characters (Redact), possibly inside an address.
    func testAnAddressCutBeforeItArrivesIsStillHidden() {
        for cut in 150..<165 {
            let engine = Redact.clean(String(repeating: "x", count: 5) + String(repeating: " y", count: (cut - 5) / 2) + " 203.0.113.77 rest")
            let out = Diagnostics.clean(engine)
            XCTAssertFalse(out.contains("203."), out)
            XCTAssertFalse(out.contains("113"), out)
        }
    }

    func testLongInputStaysFast() {
        let start = Date()
        _ = Diagnostics.clean(String(repeating: "a", count: 50_000))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        // Hundreds of values of many words (a real setup has under a hundred values), and text full of what Redact hid.
        let values = (0..<300).map { n in (0..<40).map { "w\(n)x\($0)" }.joined(separator: " ") }
        let text = Redact.clean(String(repeating: "password w7x0 w7x1 w7x2 ", count: 40))
        let many = Date()
        XCTAssertTrue(Diagnostics.clean(text, values: values).hasPrefix("[hidden] [value] [hidden] [value]"))
        XCTAssertLessThan(Date().timeIntervalSince(many), 2)
        // Values sharing most of their words.
        let alike = (0..<300).map { "v\($0) " + String(repeating: "a ", count: 39) + "end" }
        let same = Date()
        XCTAssertEqual(Diagnostics.clean(Redact.clean("password v1 " + String(repeating: "a ", count: 30) + "is wrong"), values: alike),
                       "[hidden] [value] is wrong")
        XCTAssertLessThan(Date().timeIntervalSince(same), 2)
    }

    func testFailuresKeepOnlyTheirKindTypeAndCode() {
        Diagnostics.noteFailure("Could not connect", NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSLocalizedDescriptionKey: "vpn.example.com 10.0.0.1"]), at: t0)
        XCTAssertEqual(Diagnostics.lastFailure, Diagnostics.Failure(at: t0, kind: "Could not connect", facts: "NSURLErrorDomain -1009"))
        Diagnostics.noteFailure("Change not applied", Fail("No server for My Home Route"), at: t0)
        XCTAssertEqual(Diagnostics.lastFailure?.facts, "Fail 1")
        Diagnostics.noteStop(NSError(domain: "com.example.private", code: 7), at: t0)
        XCTAssertEqual(Diagnostics.lastStop?.kind, "stopped")
        XCTAssertEqual(Diagnostics.lastStop?.facts, "NSError 7")
    }

    /// What failed is copied in the app's own words: a fixed fallback names it, any other one (a restore's, the earlier
    /// message, which can name a route) is reported as a restore.
    func testAFailureIsCopiedAsItsKind() {
        XCTAssertEqual(Diagnostics.failureKind("Could not connect"), "Could not connect")
        XCTAssertEqual(Diagnostics.failureKind("Could not update blocked apps"), "Could not update blocked apps")
        XCTAssertEqual(Diagnostics.failureKind("the engine didn't take them"), "Blocked-app changes not applied")
        XCTAssertEqual(Diagnostics.failureKind("No server for My Home Route"), "Restoring after a failure")
        XCTAssertEqual(Diagnostics.failureKind(""), "Restoring after a failure")
        for (fallback, kind) in Diagnostics.failureKinds { XCTAssertEqual(Diagnostics.failureKind(fallback), kind) }
        Diagnostics.noteFailure("Could not erase the extension's copy", facts: "not confirmed", at: t0)
        XCTAssertEqual(Diagnostics.lastFailure, Diagnostics.Failure(at: t0, kind: "Could not erase the extension's copy", facts: "not confirmed"))
    }

    /// Every fallback Connection reports a failure with is either fixed wording known here or a restore's earlier message
    /// (`failure`): a new one can't be copied as a restore by mistake.
    func testEveryFallbackConnectionUsesIsAKnownKind() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "App/Engine/Connection.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let calls = source.components(separatedBy: "message(").count - 1 - source.components(separatedBy: "func message(").count + 1
        let call = try NSRegularExpression(pattern: #"\bmessage\(\w+,\s*(?:"((?:[^"\\]|\\.)*)"|(failure))\)"#)
        let found = call.matches(in: source, range: NSRange(source.startIndex..., in: source))
        XCTAssertGreaterThan(calls, 10)
        XCTAssertEqual(found.count, calls, "a call to message() whose fallback is neither a literal nor `failure`")
        // A restore's fallback only where a restore after a failure is reported: a failed pause restore and a failed change.
        XCTAssertEqual(found.filter { $0.range(at: 2).location != NSNotFound }.count, 2)
        for m in found {
            guard let r = Range(m.range(at: 1), in: source) else { continue }
            XCTAssertNotNil(Diagnostics.failureKinds[String(source[r])], String(source[r]))
        }
        // Every erase of the extension's copy goes through the one that records its failure.
        XCTAssertEqual(source.components(separatedBy: "erasePending()").count - 1, 2, "erasePending() called other than by erasePendingNoted()")
    }

    func testTheReportNamesOnlyKnownProvidersAndAgesWhatFailed() {
        let report = DiagnosticsReport(
            app: "1.0 (7)", system: "macOS 26.1", extensionState: "ready", extensionAnswers: true, phase: "on",
            killSwitch: true, killSwitchApplied: false, onDemand: false, onDemandApplied: nil, onDemandUnavailable: true,
            providers: ["mullvad", "nord", "mullvad", "evil.example.com"], imported: 1, home: "Tailscale", runningDiffers: true,
            failure: Diagnostics.Failure(at: t0, kind: "Change not applied", facts: "Fail 1"), stop: nil,
            rejection: Diagnostics.Rejection(at: t0, text: Diagnostics.clean("outbounds[2]: bad key for nl.example.net")))
        let text = report.text(now: t0.addingTimeInterval(600)) { ["mullvad": "Mullvad", "nord": "NordVPN"][$0] }
        XCTAssertTrue(text.contains("Providers in the setup: Mullvad, NordVPN, 1 other, 1 own server"), text)
        XCTAssertTrue(text.contains("VPN: on, running an earlier setup"), text)
        XCTAssertTrue(text.contains("Kill switch: on (applied: off)"), text)
        XCTAssertTrue(text.contains("Connect on Demand: off (applied: unknown), unavailable"), text)
        XCTAssertTrue(text.contains("Last failure (10 min ago): Change not applied, Fail 1"), text)
        XCTAssertTrue(text.contains("Engine refused a setup (10 min ago): outbounds[2]: bad key for [host]"), text)
        XCTAssertTrue(text.contains("Extension: ready, answers on this build"), text)
        XCTAssertFalse(text.contains("evil"), text)
    }

    /// The setup that was checked, as the compiler writes it: the user's own values among the engine's words.
    private let config = #"""
    {"outbounds": [{"type": "wireguard", "tag": "r-r1a2b3c4", "server": "homeserver", "private_key": "Ab+/Cd=="},
                   {"type": "socks", "tag": "r-r5e6f7a8", "server": "nas", "username": "robin", "password": "secretpw"}],
     "route": {"rules": [{"process_path": ["/Volumes/Robin Backup/x"], "outbound": "direct"}], "final": "r-r1a2b3c4"},
     "dns": {"servers": [{"type": "local", "tag": "local"}], "strategy": "ipv4_only"}, "wifi": "HomeWifi-Robin"}
    """#
    /// Stand-ins for the account, full, host and computer names, as the app takes them.
    private let mac = Diagnostics.localNames(people: ["robin", "Robin Quill"], mac: ["robins-mbp.local", "robins-mbp", "Robin's MacBook Pro"])

    /// The Mac's names' words that name no one (the engine's, a Mac model's, the local domain's) aren't masked; whole
    /// names are, and every word of the user's own.
    func testTheMacsNamesWithoutTheirGenericWords() {
        XCTAssertEqual(Set(mac), ["robin", "Robin Quill", "robins-mbp.local", "robins-mbp", "Robin's MacBook Pro", "Robin", "Quill",
                                  "robins", "mbp"])
        XCTAssertEqual(Set(Diagnostics.localNames(people: [], mac: ["Studio", "Mac mini", "iMac", "MACBOOK-AIR.LOCAL", "Anna's Mac Studio",
                                                                     "Alice-DIRECT-https.local"])),
                       ["Studio", "Mac mini", "iMac", "MACBOOK-AIR.LOCAL", "Anna's Mac Studio", "Anna", "Alice-DIRECT-https.local", "Alice"])
        XCTAssertEqual(Diagnostics.clean("dns: local server refused; resolve local domain", values: mac),
                       "dns: local server refused; resolve local domain")
        XCTAssertEqual(Diagnostics.clean("MacBook Pro mini Air Studio: tcp direct block", values: mac), "MacBook Pro mini Air Studio: tcp direct block")
        XCTAssertEqual(Diagnostics.clean("user robin on Robin's MacBook Pro", values: mac), "user [value] on [value]")
        XCTAssertEqual(Diagnostics.clean("host robins-mbp.local", values: mac), "host [value]")
        // The user's own words, even when they read like the engine's or a Mac's.
        let anna = Diagnostics.localNames(people: ["ablock", "Anna Block", "Mini Johnson"], mac: ["Anna-Block-MBP.local"])
        XCTAssertEqual(Diagnostics.clean("user Block not permitted; Mini said hi", values: anna), "user [value] not permitted; [value] said hi")
        XCTAssertEqual(Diagnostics.clean("direct DIRECT https", values: Diagnostics.localNames(people: [], mac: ["Alice-DIRECT-https.local"])),
                       "direct DIRECT https")
        // A whole name stays masked, whatever its words.
        let generic = Diagnostics.localNames(people: ["local"], mac: ["MacBook Pro"])
        XCTAssertEqual(Diagnostics.clean("local MacBook Pro", values: generic), "[value] [value]")
        XCTAssertEqual(Diagnostics.clean("a MacBook or a Pro", values: generic), "a MacBook or a Pro")
    }

    func testTheSetupsOwnValuesAreItsStringsButNotTheEnginesWords() {
        let values = Set(Diagnostics.values(of: config))
        XCTAssertEqual(values, ["homeserver", "Ab+/Cd==", "socks", "nas", "robin", "secretpw", "/Volumes/Robin Backup/x", "HomeWifi-Robin"])
        XCTAssertEqual(Diagnostics.values(of: nil), [])
        XCTAssertEqual(Diagnostics.values(of: "{not json"), [])
    }

    /// Text no mask recognises, from the review's probes: the setup's own values and the Mac's names catch it.
    func testTheSetupsOwnValuesAndTheMacsNamesAreMaskedWhereverTheEngineQuotesThem() {
        let values = Diagnostics.values(of: config) + mac
        for (raw, leaks) in [
            ("lookup homeserver: no such host", ["homeserver"]),
            ("dial tcp robins-mbp:51820", ["robins", "51820"]),
            ("user robin not permitted", ["robin"]),
            ("proxy socks5 robin:secretpw@1.2.3.4", ["robin", "secretpw", "1.2.3.4"]),
            ("key=Ab+/Cd== rejected", ["Ab+/", "Cd=="]),
            ("ssid HomeWifi-Robin unknown", ["Robin", "HomeWifi"]),
            ("open /Volumes/Robin Backup/x: denied", ["Robin", "Backup"]),
            ("server nas refused", [" nas "]),
            ("host Robin's MacBook Pro.local", ["Robin", "MacBook"]),
        ] {
            let out = Diagnostics.clean(raw, values: values)
            for leak in leaks { XCTAssertFalse(out.contains(leak), "\(leak) in \(out)") }
        }
        // A value on either side of a credential doesn't leave the rest of it showing.
        for known in [["secretpw"], ["1.2.3.4"], ["hs.example.com"], ["robin"], ["robin", "hs.example.com"], ["example"]] {
            for raw in ["proxy robin:secretpw@1.2.3.4", "proxy robin:secretpw@hs.example.com", "proxy robin.smith:secretpw@hs.example.com"] {
                let out = Diagnostics.clean(raw, values: known)
                for leak in ["robin", "smith", "secretpw", "1.2.3", "hs.", "example"] { XCTAssertFalse(out.contains(leak), "\(leak) in \(out) for \(known)") }
                XCTAssertEqual(out, "proxy [email]", "for \(known)")
            }
        }
        // Short values only as words of their own; the engine's words stay.
        XCTAssertEqual(Diagnostics.clean("dynasty of nas", values: values), "dynasty of [value]")
        XCTAssertEqual(Diagnostics.clean("initialize outbounds[2]: parse wireguard: invalid private key", values: values),
                       "initialize outbounds[2]: parse wireguard: invalid private key")
        XCTAssertEqual(Diagnostics.clean("decode config at route.rules[3].process_path: missing ipv4 address for tcp4", values: values),
                       "decode config at route.rules[3].process_path: missing ipv4 address for tcp4")
    }

    /// The same probes with no values to go by (an engine quoting what isn't in the config): the masks alone.
    func testMasksCatchCredentialsDigitGroupsByteListsShortKeysLookupsAndDials() {
        for (raw, leaks) in [
            ("lookup homeserver: no such host", ["homeserver"]),
            ("lookup homeserver on 192.168.1.1:53: no such host", ["homeserver", "192.168"]),
            ("dial tcp robins-mbp:51820: refused", ["robins", "51820"]),
            ("dial udp6 [fd7a::1]:41641: refused", ["fd7a", "41641"]),
            ("proxy socks5 robin:secretpw@1.2.3.4", ["robin", "secretpw", "1.2.3.4"]),
            ("account 1234 5678 9012 3456", ["5678", "9012"]),
            ("account 1234-5678-9012-3456", ["5678", "9012"]),
            ("invalid key [12 34 56 78 90 12]", ["34 56", "78"]),
            ("key=Ab+/Cd==", ["Ab+/", "Cd=="]),
            ("open /Volumes/Robin Backup/x", ["Robin", "Backup"]),
        ] {
            let out = Diagnostics.clean(raw)
            for leak in leaks { XCTAssertFalse(out.contains(leak), "\(leak) in \(out)") }
        }
        XCTAssertEqual(Diagnostics.clean("lookup homeserver: no such host"), "lookup [host]: no such host")
        XCTAssertEqual(Diagnostics.clean("dial udp6 [fd7a::1]:41641"), "dial udp6 [address]")
        XCTAssertEqual(Diagnostics.clean("invalid key [12 34 56 78 90 12]"), "invalid key [bytes]")
        for kept in ["network=tcp4", "type=wireguard", "outbounds[2]", "route.rules[3]", "missing ipv4 address for tcp4"] {
            XCTAssertEqual(Diagnostics.clean(kept), kept)
        }
    }

    /// The extension cut the text in the middle of a value: what is left of it goes with the cut-off last word.
    func testAValueCutBeforeItArrivesIsStillHidden() {
        let values = Diagnostics.values(of: config)
        var partial = 0
        for cut in 150..<165 {
            let engine = Redact.clean(String(repeating: "x", count: 5) + String(repeating: " y", count: (cut - 5) / 2) + " homeserver rest")
            let out = Diagnostics.clean(engine, values: values)
            // Whatever of the value arrived, whole or cut ("ho", "home"), is gone.
            for word in engine.split(separator: " ").map(String.init) where word.count >= 2 && "homeserver".hasPrefix(word) {
                if word != "homeserver" { partial += 1 }
                XCTAssertFalse(out.split(separator: " ").contains { $0.hasPrefix(word) }, out)
            }
        }
        XCTAssertGreaterThan(partial, 0, "no cut went through the value")
    }

    /// The cut went through a value of several words: the words of it before the cut go too.
    func testTheWordsLeftOfAValueTheCutWentThroughAreHidden() {
        let values = ["Acme Secret Office", "/Volumes/Robin Backup/x"]
        for tail in ["ssid Acme Secret Office rest", "open /Volumes/Robin Backup/x now"] {
            for cut in 150..<170 {
                let engine = Redact.clean(String(repeating: "x", count: 5) + String(repeating: " y", count: (cut - 5) / 2) + " " + tail)
                let out = Diagnostics.clean(engine, values: values)
                for leak in ["Acme", "Secret", "Robin"] { XCTAssertFalse(out.contains(leak), "\(leak) in \(out)") }
            }
        }
        // A shorter value inside the cut one doesn't hide its start; nor a cut credential's host.
        for cut in 150..<170 {
            let pad = String(repeating: "x", count: 5) + String(repeating: " y", count: (cut - 5) / 2)
            let ssid = Diagnostics.clean(Redact.clean(pad + " ssid Acme Secret Office rest"), values: ["Acme Secret Office", "Secret"])
            XCTAssertFalse(ssid.contains("Acme"), ssid)
            let proxy = Diagnostics.clean(Redact.clean(pad + " proxy bob:pw@Acme Secret Office rest"), values: ["Acme Secret Office"])
            for leak in ["bob", "Acme", "Secret", "Office"] { XCTAssertFalse(proxy.contains(leak), proxy) }
        }
        // Not cut: a value's first word alone is not the value.
        XCTAssertEqual(Diagnostics.clean("ssid Acme", values: values), "ssid Acme")
    }

    /// Redact hides a secret's key and first word only: the rest of a value of several words, after it, goes too.
    func testTheRestOfAValueRedactHidOnlyTheStartOfIsMasked() {
        let values = ["correct horse battery staple", "tskey abc def"]
        for (raw, kept) in [("invalid password correct horse battery staple", "invalid [hidden] [value]"),
                            ("password=correct horse battery staple rejected", "[hidden] [value] rejected"),
                            ("auth_key: tskey abc def: bad key", "[hidden] [value]: bad key"),
                            ("PASSWORD Correct HORSE\tbattery  Staple", "[hidden] [value]")] {
            let out = Diagnostics.clean(Redact.clean(raw), values: values)
            for leak in ["horse", "battery", "staple", "abc", "def"] { XCTAssertFalse(out.localizedCaseInsensitiveContains(leak), "\(leak) in \(out)") }
            XCTAssertEqual(out, kept)
        }
        // A shorter value inside it, or another value sharing its last words, doesn't break the run up.
        for others in [["battery"], ["my battery staple"], ["horse battery"], ["staple"]] {
            let out = Diagnostics.clean(Redact.clean("invalid password correct horse battery staple"), values: values + others)
            for leak in ["horse", "battery", "staple"] { XCTAssertFalse(out.contains(leak), "\(leak) in \(out) for \(others)") }
        }
        // Regex punctuation in a value is taken literally.
        XCTAssertEqual(Diagnostics.clean(Redact.clean("password a.b (c+ d*e"), values: ["a.b (c+ d*e"]), "[hidden] [value]")
        XCTAssertEqual(Diagnostics.clean("[hidden] abXc+ d", values: ["a.b (c+ d*e"]), "[hidden] abXc+ d")
        // Only right after what Redact hid: the same words elsewhere are the engine's.
        XCTAssertEqual(Diagnostics.clean("the horse battery is low", values: values), "the horse battery is low")
        XCTAssertEqual(Diagnostics.clean("[hidden] horsepower", values: values), "[hidden] horsepower")
        // The longest run any value has wins, wherever an earlier word repeats; and values of many words.
        let repeated = "first horse " + String(repeating: "z", count: 41) + " horse staple"
        XCTAssertEqual(Diagnostics.clean(Redact.clean("password " + repeated), values: [repeated]), "[hidden] [value]")
        // Redact hides a long run of letters inside a value too: the value is matched as Redact left it.
        let z = String(repeating: "z", count: 41)
        for value in ["first horse \(z):cedar staple", "first horse \(z):x staple", "first horse \(z):cedar:\(z) staple",
                      "first horse maple:\(z):cedar", "first \(z) staple"] {
            let out = Diagnostics.clean(Redact.clean("password " + value + " rejected"), values: [value])
            XCTAssertEqual(out, "[hidden] [value] rejected", value)
        }
        XCTAssertEqual(Diagnostics.clean(Redact.clean("key " + z + ":cedar, bad"), values: [z + ":cedar"]), "key [value], bad")
        // A whole value with a hidden run inside it, next to the tail of another; a secret inside a value.
        XCTAssertEqual(Diagnostics.clean(Redact.clean("invalid key: maple \(z) cedar staple"), values: ["maple \(z) cedar staple"]),
                       "invalid key: [value]")
        XCTAssertEqual(Diagnostics.clean(Redact.clean("invalid key: maple\n\(z) cedar staple"), values: ["maple\n\(z) cedar staple"]),
                       "invalid key: [value]")
        let inner = "first horse maple:password=hunter cedar staple"
        XCTAssertEqual(Diagnostics.clean(Redact.clean("password " + inner), values: [inner]), "[hidden] [value]")
        XCTAssertEqual(Diagnostics.clean(Redact.clean("token " + z), values: [z]), "token [hidden]")
        // Case is folded as Foundation compares it.
        XCTAssertEqual(Diagnostics.clean("[hidden] STRASSE staple", values: ["correct Straße staple"]), "[hidden] [value]")
        XCTAssertEqual(Diagnostics.clean("[hidden] ΟΔΟΣ ΤΕΛΟΣ", values: ["η οδος τελος"]), "[hidden] [value]")
        let long = "aa " + String(repeating: "b ", count: 63) + "finalword"
        XCTAssertFalse(Diagnostics.clean(Redact.clean("password " + long), values: [long]).contains("finalword"))
        // Cut by the extension anywhere in the later words: what is left of them goes. Redacted, "[hidden]" ends at
        // column pad + 9; the cut at 160 then falls j characters into " horse battery staple".
        for j in 0...21 {
            let pad = String(String(repeating: "y ", count: 80).prefix(151 - j))
            let engine = Redact.clean(pad + " password correct horse battery staple and more")
            XCTAssertEqual(engine.count, 160)
            let out = Diagnostics.clean(engine, values: values)
            for leak in ["ho", "ba", "st"] { XCTAssertFalse(out.contains(leak), "\(leak) in \(out) at \(j)") }
            if j >= 8 { XCTAssertTrue(out.contains("[hidden] [value]"), "\(out) at \(j)") }
        }
        // The same with tabs between the words.
        let tabbed = "first\thorse\tbattery\tstaple"
        for j in 0...21 {
            let pad = String(String(repeating: "y\t", count: 80).prefix(150 - j))
            let out = Diagnostics.clean(Redact.clean(pad + "\tpassword=" + tabbed), values: [tabbed])
            for leak in ["ho", "ba", "st"] { XCTAssertFalse(out.contains(leak), "\(leak) in \(out) at \(j)") }
        }
    }

    /// The real account name, as the app collects it.
    func testARejectionMasksTheUsersOwnName() throws {
        let user = NSUserName()
        try XCTSkipIf(user.count < 3)
        Diagnostics.noteRejection("user \(user) not permitted for homeserver", config: config, at: t0)
        let text = try XCTUnwrap(Diagnostics.lastRejection?.text)
        XCTAssertFalse(text.localizedCaseInsensitiveContains(user), text)
        XCTAssertFalse(text.contains("homeserver"), text)
    }

    func testTheLatestRejectionIsKept() {
        Diagnostics.noteRejection("first 192.0.2.1", at: t0)
        Diagnostics.noteRejection("second", at: t0.addingTimeInterval(5))
        XCTAssertEqual(Diagnostics.lastRejection, Diagnostics.Rejection(at: t0.addingTimeInterval(5), text: "second"))
    }
}
