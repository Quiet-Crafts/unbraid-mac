import XCTest

final class RedactTests: XCTestCase {
    private let key = "aGVsbG8taGVsbG8taGVsbG8taGVsbG8taGVsbG8tMTI="

    func testKeysAndConfigFragmentsAreRemoved() {
        let raw = "decode config: {\"type\":\"wireguard\",\"private_key\":\"\(key)\",\"peers\":[{\"public_key\":\"\(key)\"}]} password=hunter2"
        let out = Redact.clean(raw)
        XCTAssertFalse(out.contains(key))
        XCTAssertFalse(out.contains("hunter2"))
        XCTAssertFalse(out.contains("private_key\":\"a"))
        XCTAssertTrue(out.hasPrefix("decode config"))
    }

    func testQuotedSecretsGoWhole() {
        let out = Redact.clean("auth failed: password=\"alpha beta gamma\" for user x")
        XCTAssertFalse(out.contains("beta"))
        XCTAssertFalse(out.contains("gamma"))
        XCTAssertTrue(out.hasSuffix("for user x"))
    }

    func testEscapedQuotesDontEndTheSecret() {
        let out = Redact.clean("bad: password=\"alpha\\\"bravo\\\\charlie\" ok")
        XCTAssertFalse(out.contains("bravo"))
        XCTAssertFalse(out.contains("charlie"))
        XCTAssertTrue(out.hasSuffix(" ok"))
    }

    func testSecretsInBackslashEscapedJsonAreHidden() {
        // Fake values only: a config quoted as a string (%q, debugDescription) escapes its quotes.
        let json = Redact.clean(#"json: {\"type\":\"shadowsocks\",\"password\":\"fake pass\",\"server\":\"192.0.2.1\"} bad"#)
        XCTAssertFalse(json.contains("fake"), json)
        XCTAssertFalse(json.contains("pass\\"), json)
        XCTAssertTrue(json.contains(#"\"server\":\"192.0.2.1\"} bad"#), json)
        for (input, leak) in [(#"unknown field \"password\": fakepass"#, "fakepass"), (#"{\\\"token\\\":\\\"fake-token\\\"}"#, "fake-token"),
                              (#"{\"private_key\":\"fake-key\""#, "fake-key")] {
            XCTAssertFalse(Redact.clean(input).contains(leak), input)
        }
    }

    func testAQuoteInsideAnEscapedSecretDoesNotEndIt() {
        func escaped(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        for c in [",", "}", "]", " "] {
            // The fake password itself holds a quote followed by c; once and twice quoted as a string.
            let plain = "{\"password\":\"fake\\\"\(c)tail\",\"server\":\"192.0.2.1\"}"
            for text in [escaped(plain), escaped(escaped(plain))] {
                let out = Redact.hiding("err: \(text) done")
                XCTAssertFalse(out.contains("fake") || out.contains("tail"), out)
                XCTAssertTrue(out.contains("192.0.2.1") && out.hasSuffix(" done"), out)
            }
        }
        XCTAssertFalse(Redact.clean(#"err: {\"password\":\"fake\\\"tail"#).contains("tail"))
        XCTAssertFalse(Redact.clean(#"err: {\"password\":\"fake tail"#).contains("tail"))
        // Formatted JSON quoted as a string: its line breaks and tabs around the colon are escaped too.
        for text in [#"{\n\t\"password\":\n\t\"fake tail\"\n}"#, #"{\"password\"\n:\t\"fake tail\"}"#, #"{\\\"password\\\":\\n\\\"fake tail\\\"}"#] {
            let out = Redact.hiding("err: \(text) done")
            XCTAssertFalse(out.contains("fake") || out.contains("tail"), out)
        }
    }

    func testALoginMatchNeverTakesASecretsName() {
        for text in [#"{\"url\":\"https://example.com\",\"password\":\"FAKE@LEAKTAIL\"}"#, #"{"url":"https://example.com","password":"FAKE@LEAKTAIL"}"#] {
            let out = Redact.hiding(text)
            XCTAssertFalse(out.contains("LEAKTAIL") || out.contains("FAKE"), out)
        }
        XCTAssertFalse(Redact.clean("dial ss://aes-256-gcm:s3cr3t@192.0.2.1:8388 password=fakepass").contains("fakepass"))
        XCTAssertTrue(Redact.clean("dial ss://aes-256-gcm:s3cr3t@192.0.2.1:8388 failed").contains("192.0.2.1"))
        // A key word inside a URL's login never splits it.
        for text in ["dial https://fakeuser:fakepre-token=x@192.0.2.1/ failed", #"{"url":"https://fakeuser:fakepre-token=x@192.0.2.1/"}"#,
                     #"{\"url\":\"https://fakeuser:fakepre-token=x@192.0.2.1/\"}"#, "dial ss://fakeuser:fake'pre@192.0.2.1 failed"] {
            let out = Redact.hiding(text)
            XCTAssertFalse(out.contains("fakeuser") || out.contains("fakepre") || out.contains("pre@"), out)
            XCTAssertTrue(out.contains("192.0.2.1"), out)
        }
    }

    // MARK: each way a secret got through before (fake values only)

    func testAQuoteOrBackslashBeforeAKeyWordInALoginHidesTheLoginWhole() {
        for c in ["'", "\\", "\""] {
            let out = Redact.hiding("dial https://FAKEUSER:FAKEPRE\(c)POST-token=FAKETAIL@192.0.2.1/ failed")
            XCTAssertEqual(out, "dial https://[hidden]@192.0.2.1/ failed")
            let json = Redact.hiding(escaped(#"{"url":"https://FAKEUSER:FAKEPRE\#(c)POST-token=FAKETAIL@192.0.2.1/","password":"FAKENEXT"}"#))
            XCTAssertFalse(["FAKEUSER", "FAKEPRE", "FAKETAIL", "FAKENEXT"].contains { json.contains($0) }, json)
        }
    }

    func testEveryItemOfAListValueIsHidden() {
        for gap in [",", ", ", ",\n"] {
            let out = Redact.hiding(#"{"credentials":["FAKEHEAD"\#(gap)"FAKETAIL"]}"#)
            XCTAssertFalse(out.contains("FAKEHEAD") || out.contains("FAKETAIL"), out)
        }
    }

    func testALoginInAURLWithEscapedSlashesIsHidden() {
        for level in 0...2 {
            let text = escaped(#"{"url":"https:\/\/FAKEUSER:FAKEPASS@192.0.2.1/","token":"FAKENEXT"}"#, level)
            let out = Redact.hiding(text)
            XCTAssertFalse(["FAKEUSER", "FAKEPASS", "FAKENEXT"].contains { out.contains($0) }, out)
        }
    }

    func testAnAtSignInsideAPasswordHidesItWhole() {
        XCTAssertEqual(Redact.hiding("dial https://FAKEUSER:FAKEPRE@FAKETAIL@192.0.2.1/ failed"), "dial https://[hidden]@192.0.2.1/ failed")
        XCTAssertEqual(Redact.hiding("dial ss://FAKE@USER:FAKE@PASS@[2001:db8::1]:443/ failed"), "dial ss://[hidden]@[2001:db8::1]:443/ failed")
    }

    func testABackslashBeforeALineBreakDoesNotEndAQuotedSecret() {
        for brk in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}", "\u{85}"] {
            for q in ["\"", "'"] {
                for text in ["password=\(q)FAKEHEAD\\\(brk)FAKETAIL\(q)", "password=\(q)FAKEHEAD\(brk)FAKETAIL\(q)", "password=FAKEHEAD\\\(brk)FAKETAIL"] {
                    let out = Redact.hiding(text)
                    XCTAssertFalse(out.contains("FAKEHEAD") || out.contains("FAKETAIL"), out.debugDescription)
                }
            }
        }
    }

    func testANameWrittenWithUnicodeEscapesIsFound() {
        for text in [#"{"pass\u0077ord":"FAKEHEAD FAKETAIL"}"#, #"{"\u0074oken":"FAKEHEAD FAKETAIL"}"#, #"{\"pass\\u0077ord\":\"FAKEHEAD FAKETAIL\"}"#,
                     #"{"PASS\u0057ORD":"FAKEHEAD FAKETAIL"}"#] {
            let out = Redact.hiding(text)
            XCTAssertFalse(out.contains("FAKEHEAD") || out.contains("FAKETAIL"), out)
        }
    }

    func testBlanksWrittenAsUnicodeEscapesAroundTheColon() {
        for text in [#"{\"password\":\u0020\"FAKEHEAD FAKETAIL\"}"#, #"{\"password\"\u0020:\"FAKEHEAD FAKETAIL\"}"#,
                     #"{"password":\u0009"FAKEHEAD FAKETAIL"}"#, #"{\\\"password\\\":\\u0020\\\"FAKEHEAD FAKETAIL\\\"}"#] {
            let out = Redact.hiding(text)
            XCTAssertFalse(out.contains("FAKEHEAD") || out.contains("FAKETAIL"), out)
        }
    }

    func testAValueInEscapedSingleQuotesIsHiddenWhole() {
        var text = "{'password':'FAKEHEAD FAKETAIL'}"
        for _ in 0...3 {
            let out = Redact.hiding(text)
            XCTAssertFalse(out.contains("FAKEHEAD") || out.contains("FAKETAIL"), out)
            text = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        }
    }

    func testAURLWrittenWithUnicodeEscapesOrDeeplyEscapedSlashesKeepsNoLogin() {
        for text in [#"{"url":"https://FAKEUSER:FAKEPASS@vpn.example/path"}"#, #"{"url":"https://FAKEUSER:FAKEPASS@vpn.example/path"}"#,
                     #"{"url":"https://FAKEUSER:FAKEPASS@vpn.example/path"}"#,
                     "https:" + String(repeating: "\\", count: 32) + "/" + String(repeating: "\\", count: 32) + "/FAKEUSER:FAKEPASS@vpn.example/"] {
            let out = Redact.hiding(text)
            XCTAssertFalse(out.contains("FAKEUSER") || out.contains("FAKEPASS"), out)
            XCTAssertTrue(out.contains("vpn.example"), out)
        }
    }

    func testAnEscapedSingleQuoteInsideAJSONStringDoesNotEndTheValue() {
        let out = Redact.hiding(#"{"error":"password='FAKEHEAD\\'FAKETAIL'"}"#)
        XCTAssertFalse(out.contains("FAKEHEAD") || out.contains("FAKETAIL"), out)
        XCTAssertFalse(Redact.hiding(#"password:\f\"FAKEHEAD FAKETAIL\""#).contains("FAKETAIL"))
    }

    func testCombiningMarksAndLetterFormsChangeNothing() {
        // As the patterns this replaced read them: a quote or blank with a mark on it is another character.
        for text in ["token \u{345} =FAKEHEAD", "password \u{345} FAKEHEAD", "password=\"FAKEHEAD\"\u{301}FAKETAIL\"",
                     "password:'\u{345}FAKEHEAD'=FAKETAIL", "\u{2460}password FAKEHEAD", "\u{17F}ecret=FAKEHEAD", "pa\u{17F}\u{17F}word FAKEHEAD",
                     "private_\u{212A}ey=FAKEHEAD", "pr\u{130}vate_key=FAKEHEAD", "https://FAKEUSER:FAKEPASS/\u{345}@vpn.example/"] {
            let out = Redact.hiding(text)
            XCTAssertFalse(["FAKEHEAD", "FAKETAIL", "FAKEUSER", "FAKEPASS"].contains { out.contains($0) }, out)
        }
    }

    func testAURLCutOffInItsLoginHidesTheRestUnlessAnAddressFollows() {
        for text in ["https://FAKEUSER", "https://fake.FAKEUSER", "https://FAKEUSER:FAKEPA", "https://FAKEUSER:FAKEPRE@FAKETAIL",
                     "https://FAKEUSER:FAKEHEAD@FAKEZ.example", "https://FAKEUSER:FAKEHEAD@[FADE]", "https://FAKEUSER:FAKEHEAD@[FACE:FEED]",
                     "https://FAKEUSER:FAKEHEAD@[::FADE:]", "https://FAKEUSER:FAKEHEAD@[:FADE:FACE:FEED:CAFE:BABE:DEAD:BEEF:ABCD]",
                     "https://FAKEUSER:FAKEHEAD@[FADE::FACE:FEED:CAFE:BABE:DEAD:BEEF:ABCD]", "https://FAKEUSER:FAKEHEAD@192.0.2.1:99999",
                     "https://FAKEUSER:FAKEHEAD@192.0.2.1?FAKETAIL", "https://vpn.example"] {
            XCTAssertEqual(Redact.hiding(text), "https://[hidden]", text)
        }
        for text in ["https://192.0.2.1:443", "https://[2001:db8::1]", "https://vpn.example/", "dial https://vpn.example:443 failed"] {
            XCTAssertEqual(Redact.hiding(text), text)
        }
        XCTAssertEqual(Redact.hiding("ss://aes:pw@192.0.2.1"), "ss://[hidden]@192.0.2.1")
        XCTAssertEqual(Redact.hiding("ss://aes:pw@[2001:db8::1]:443"), "ss://[hidden]@[2001:db8::1]:443")
    }

    // MARK: every family, generated

    /// A fake secret planted across the forms engine and library errors quote configurations in, at four depths of
    /// quoting: no part of it ever shows.
    func testAPlantedSecretNeverShows() {
        let names = ["private_key", "PrivateKey", "PRE_SHARED_KEY", "presharedkey", "PSK", "auth_key", "ApiKey", "credential", "CREDENTIALS",
                     "password", "Passwd", "secret", "token", "ToKeN", #"pass\u0077ord"#, #"\u0074oken"#,
                     "secret_key", "private-key", "x-api-key", "client_key", "access_key", "passphrase", "pt", "pass", "uuid",
                     "account_number", "account_id", "Authorization"]
        let values = ["FAKEHEAD FAKETAIL", "FAKEHEAD\"FAKETAIL", "FAKEHEAD\",FAKETAIL", "FAKEHEAD\"}FAKETAIL", "FAKEHEAD\"]FAKETAIL",
                      "FAKEHEAD\" FAKETAIL", "FAKEHEAD\\FAKETAIL", "FAKEHEAD\\\"FAKETAIL", "FAKEHEAD/FAKETAIL", "FAKEHEAD\nFAKETAIL",
                      "FAKEHEAD\tFAKETAIL", "FAKEHEAD\r\nFAKETAIL", "FAKEHEAD☃FAKETAIL", "FAKEHEAD'FAKETAIL", "FAKEHEAD@FAKETAIL", "FAKEHEAD\\"]
        let blanks = ["", " ", "\n", "\t", "\r\n", " \n\t"]
        var texts: [String] = []
        for name in names {
            for value in values {
                let v = json(value)
                texts += [#"{"\#(name)":\#(v),"server":"192.0.2.1"}"#, #"{"\#(name)":\#(v)"#, #"[{"\#(name)":\#(v)}]"#, #"{"\#(name)":[\#(v), \#(v)]}"#]
            }
            for blank in blanks { texts.append(#"{"\#(name)"\#(blank):\#(blank)"FAKEHEAD FAKETAIL"}"#) }
            texts += ["\(name)=FAKEHEAD", "\(name): FAKEHEAD", "\(name)='FAKEHEAD FAKETAIL'", "\(name)=\"FAKEHEAD FAKETAIL\""]
        }
        for pass in ["FAKEPASS", "FAKEPRE-token=FAKETAIL", "FAKEPRE'POST-token=FAKETAIL", "FAKEPRE\\POST-token=FAKETAIL", "FAKEPRE\"POST-token=FAKETAIL",
                     "FAKEPRE@FAKETAIL", "FAKEPRE:FAKETAIL", "FAKEPRE%40FAKETAIL", "FAKEPRE%3AFAKETAIL"] {
            for host in ["192.0.2.1", "[2001:db8::1]:443"] {
                let url = "https://FAKEUSER:\(pass)@\(host)/"
                texts += ["dial \(url) failed", #"{"url":\#(json(url)),"password":"FAKENEXT"}"#, #"{"password":"FAKENEXT","url":\#(json(url))}"#,
                          #"{"url":\#(json(url).replacingOccurrences(of: "/", with: "\\/"))}"#]
            }
        }
        var checked = 0
        for text in texts {
            for level in 0...3 {
                let quoted = escaped(text, level)
                // Whole, and cut anywhere after the secret starts (a truncated message).
                let start = quoted.range(of: "FAKE")?.lowerBound ?? quoted.endIndex
                var cuts = [quoted]
                var i = start
                while i < quoted.endIndex { cuts.append(String(quoted[..<i])); i = quoted.index(i, offsetBy: 5, limitedBy: quoted.endIndex) ?? quoted.endIndex }
                for cut in cuts {
                    let out = Redact.hiding(cut)
                    for marker in ["FAKEHEAD", "FAKETAIL", "FAKEUSER", "FAKEPASS", "FAKEPRE", "FAKENEXT"] where cut.contains(marker) {
                        XCTAssertFalse(out.contains(marker), "\(cut.debugDescription) -> \(out.debugDescription)")
                    }
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 10_000)
    }

    /// Shapes the providers and the engine really write: headers, query values, account fields, wrapped and escaped keys.
    func testProviderAndWrappedKeyShapesAreHidden() {
        let hexA = "6acef03f62675b4b1bbd03e53b187727", hexB = "1bbd03e53b1877276acef03f62675b4b"
        let slashKey = "+//7//v/+//7//v/+//7//v/+//7//v/+//7//v/+/8="
        let cases: [(String, [String])] = [
            ("Authorization: Bearer FAKESHORT7", ["FAKESHORT7"]),
            ("Authorization: Basic eDpGYWtlUGFzczc=", ["eDpGYWtlUGFzczc="]),
            (#"{"Authorization":"Bearer FAKESHORT7"}"#, ["FAKESHORT7"]),
            ("got Bearer FAKESHORT7 back", ["FAKESHORT7"]),
            ("https://192.0.2.20:1337/addKey?pt=FAKESHORT7&pubkey=dummy", ["FAKESHORT7"]),
            ("https://192.0.2.20:1337/addKey?pt=Fake%2FPass%2B7 end", ["Fake%2FPass%2B7"]),
            (#"{"account_number":"1234567890123456"}"#, ["1234567890123456"]),
            ("account_id=i-FAKE-1234-5678", ["i-FAKE-1234-5678"]),
            ("key: " + hexA, [hexA]),
            ("uuid: 1b2c3d4e-0000-4000-8000-123456789abc", ["1b2c3d4e-0000"]),
            (#"{"control_wrap":{"key":"-----BEGIN OpenVPN Static key V1-----\n"# + hexA + #"\n"# + hexB + #"\n-----END OpenVPN Static key V1-----"}}"#, [hexA, hexB]),
            ("-----BEGIN OpenVPN Static key V1-----\n" + hexA + "\n" + hexB + "\n-----END OpenVPN Static key V1-----", [hexA, hexB]),
            ("-----BEGIN PRIVATE KEY-----\n" + String(repeating: "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7", count: 2) + "\nQ2pFakeTailAbc12==\n-----END PRIVATE KEY-----", ["Q2pFakeTail"]),
            ("PrivateKey = FAKEFAKEFAKEFAKEFAKEFA\nKEFAKEFAKEFAKEFAKEFAK=", ["FAKEFAKEFAKEFAKEFAKEFA", "KEFAKEFAKEFAKEFAKEFAK"]),
            ("bad key \"" + slashKey.replacingOccurrences(of: "/", with: "\\/") + "\"", ["+\\/\\/7\\/\\/v", "+\\/8="]),
            ("bad key " + slashKey.map { String(format: "\\u%04x", $0.asciiValue!) }.joined(), ["\\u002b\\u002f"]),
            ("AwoRGB8mLTQ7QklQV15l\u{0301}bHN6gYiPlp2kq7K5wMfO1dw=", ["bHN6gYiPlp2kq7K5wMfO1dw="]),
            ("parse \"https://FAKEUSER:FAKEPA/SS@192.0.2.1/\": invalid port", ["FAKEUSER", "SS@"]),
            ("dial ss://YWVzLTI1Ni1nY206cHc/Png=@192.0.2.1:8388 failed", ["YWVzLTI1Ni1nY206cHc", "Png="]),
            ("password is FAKESECRET1", ["FAKESECRET1"]),
            (#"password is "FakeFirst7 FakeLast9""#, ["FakeFirst7", "FakeLast9"]),
            (#"Authorization: Digest username="FakeUser", response="0123456789abcdef0123456789abcdef""#, ["0123456789abcdef"]),
            (#"Authorization: B\u0061sic RmFrZTpTZWNyZXQ="#, ["RmFrZTpTZWNyZXQ="]),
            ("Authorization\u{FF1A}Basic RmFrZTpTZWNyZXQ=", ["RmFrZTpTZWNyZXQ="]),
            ("Authorization: AWS4-HMAC-SHA256 Credential=FAKEKEY7/20260101", ["FAKEKEY7"]),
            ("Abcd0123Efgh4567Ijkl8901Mnop2345\nQrst6789Uvwx0123Yzab4567Cdef8901\nFakeTail7", ["FakeTail7"]),
            (#"Abcd0123Efgh4567Ijkl8901Mnop2345\u000aQrst6789Uvwx0123Yzab4567Cdef8901\u000aFakeTail7"#, ["FakeTail7"]),
            (#"line one\npassword=FAKESECRET1"#, ["FAKESECRET1"]),
            (#"a\tpt=FAKESECRET1 b"#, ["FAKESECRET1"]),
            (#"a\u0020pt=FAKESECRET1 b"#, ["FAKESECRET1"]),
            ("password\u{FF1A}FAKESECRET1", ["FAKESECRET1"]),
        ]
        for (input, leaks) in cases {
            let out = Redact.hiding(input)
            for leak in leaks { XCTAssertFalse(out.contains(leak), "\(input.debugDescription) -> \(out.debugDescription)") }
        }
        // The words on the line after a key stay.
        let blob = "Abcd0123Abcd0123Abcd0123Abcd0123Abcd0123"
        for rest in ["/etc/hosts missing", "api.example.invalid failed", "12ms remaining"] {
            XCTAssertEqual(Redact.hiding(blob + "\n" + rest), "[hidden]\n" + rest)
        }
        // The host after a login, and what stands around a hidden value, stay.
        XCTAssertEqual(Redact.hiding("dial ss://YWVzLTI1Ni1nY206cHc/Png=@192.0.2.1:8388 failed"), "dial ss://[hidden]@192.0.2.1:8388 failed")
        XCTAssertEqual(Redact.hiding("got Bearer FAKESHORT7 back"), "got [hidden] back")
        XCTAssertEqual(Redact.hiding("https://FAKEUSER:FAKEPASS@invalid.example/path"), "https://[hidden]@invalid.example/path")
    }

    func testTextWithoutSecretsIsReturnedUnchanged() {
        for text in ["", "ordinary message", "token expired", "Sign in to Mullvad for Sweden", "https://example.invalid/path",
                     "route to [2001:db8::1] failed", #"{"server":"192.0.2.1"}"#, #""a\\b\"c""#, "line one\nline two", "authentication failed",
                     "dial tcp 192.0.2.1:443: connect: connection refused", #"decode config: json: unknown field "mtu_size""#,
                     "user@example.com not found", "https://example.com/@scope/pkg", "missing token", "tokens: 5",
                     "public_key: abc", "bypass: 3", "no key found", "sort key", "mtu 1500, port: 443", "ptr: 5", "Authorization failed",
                     "first line of a message\nsecond line of a message", "https://example.com:8443/a/b@c",
                     "retry in 15s\nretry in 30s", "public-key=diagnostic-algorithm", "dial tcp 192.0.2.1:443\nconnect: refused",
                     String(repeating: "\\", count: 100_000), String(repeating: "\"", count: 100_000), String(repeating: "@", count: 1_000)] {
            XCTAssertEqual(Redact.hiding(text), text)
        }
    }

    /// The patterns this replaced gave these; the scan gives them byte for byte.
    func testEarlierOutputsStayTheSame() {
        let raw = "decode config: {\"type\":\"wireguard\",\"private_key\":\"\(key)\",\"peers\":[{\"public_key\":\"\(key)\"}]} password=hunter2"
        XCTAssertEqual(Redact.clean(raw), #"decode config: {"type":"wireguard","[hidden],"peers":[{"public_key":"[hidden]"}]} [hidden]"#)
        for (input, output) in [("auth failed: password=\"alpha beta gamma\" for user x", "auth failed: [hidden] for user x"),
                                ("bad: password=\"alpha\\\"bravo\\\\charlie\" ok", "bad: [hidden] ok"), ("psk=abc123", "[hidden]"),
                                ("api_key: k-99", "[hidden]"), ("password hunter2", "[hidden]"), ("credentials=xyz", "[hidden]"),
                                ("dial ss://aes-256-gcm:s3cr3t@1.2.3.4:8388 failed", "dial ss://[hidden]@1.2.3.4:8388 failed"),
                                ("ss://aes:pw@1.2.3.4", "ss://[hidden]@1.2.3.4")] {
            XCTAssertEqual(Redact.clean(input), output)
        }
    }

    /// One pass over the text: 200 kB of each pattern that made the earlier patterns slow (or never finish).
    func testLongTextIsScannedInLinearTime() {
        let size = 200_000
        func fill(_ unit: String) -> String { String(repeating: unit, count: size / unit.unicodeScalars.count) }
        let patterns = [fill("FAKE"), fill("\\"), fill("\""), fill("'"), fill(" "), fill("token="), fill("password:\""), fill("password=\\\""),
                        fill(#"\u0070assword:\""#), fill("://"), fill("a://"), fill(#"a:\/\/"#), fill("@"), "https://" + fill("x@"),
                        "password" + fill(" "), "password" + fill("\\"), fill("password=["), fill("password x "), fill("AAAA="), fill("\\u0020"),
                        "ss:\\/\\/" + String(repeating: "password=\"", count: size / 20) + "@" + fill("x"), fill("token=\"password a b\""),
                        fill("\\\n"), fill("AbC1dEf2GhI3jKl4\n"), fill("AbC1dEf2GhI3jKl4MnO5pQr6StU7vWx8\r\n"), fill("AbC1dEf2GhI3jKl4\\n"),
                        fill("a\n"), fill("Authorization: "), fill("password is "), fill("Bearer "), fill("key="), fill("ss://x/"),
                        fill("x://") + "/", fill(#"a\u003a\u002f\u002f"#) + "/ ", fill(#"a:\/\/"#) + "/", fill("ss://xx") + "/",
                        String(repeating: "authorization=", count: size / 28) + String(repeating: "X", count: size / 2) + " ",
                        fill(#"a\nkey="#), fill("AbC1dEf2GhI3jKl4\n") + "FakeTail7"]
        for text in patterns {
            let start = Date()
            _ = Redact.hiding(text)
            let seconds = Date().timeIntervalSince(start)
            // (Debug build on a busy machine: about 0.5-2.5 s; a scan that rereads the text for each place takes 10 s or more.)
            XCTAssertLessThan(seconds, 4,String(text.prefix(20)))
        }
    }

    private func escaped(_ s: String, _ times: Int = 1) -> String {
        var s = s
        for _ in 0..<times { s = String(json(s).dropFirst().dropLast()) }
        return s
    }

    /// [s] as a JSON string, non-ASCII written as `\u` escapes.
    private func json(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 || c.value > 0x7E {
                    for unit in String(c).utf16 { out += String(format: "\\u%04x", unit) }
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        return out + "\""
    }

    func testLongBlobsGoButOrdinaryWordsStay() {
        XCTAssertEqual(Redact.clean(String(repeating: "a", count: 40)), "[hidden]")
        XCTAssertEqual(Redact.clean("Sign in to Mullvad for Sweden"), "Sign in to Mullvad for Sweden")
    }

    func testOutputIsShortAndSingleLine() {
        let out = Redact.clean("line one\nline two " + String(repeating: "word ", count: 100))
        XCTAssertLessThanOrEqual(out.count, 160)
        XCTAssertFalse(out.contains("\n"))
    }

    func testMoreSecretFormsAreHidden() {
        for (input, leak) in [("psk=abc123", "abc123"), ("api_key: k-99", "k-99"), ("password hunter2", "hunter2"),
                              ("dial ss://aes-256-gcm:s3cr3t@1.2.3.4:8388 failed", "s3cr3t"), ("credentials=xyz", "xyz")] {
            XCTAssertFalse(Redact.clean(input).contains(leak), input)
        }
        XCTAssertTrue(Redact.clean("ss://aes:pw@1.2.3.4").contains("1.2.3.4"))
        XCTAssertEqual(Redact.clean("token expired"), "token expired")
    }

    func testCatalogueTakesOnlyPublicIPv4() {
        XCTAssertTrue(Catalog.Entry.publicIPv4("185.65.134.1"))
        for s in ["10.0.0.1", "192.168.1.1", "127.0.0.1", "100.64.0.1", "evil.example.com", "1.2.3", "300.1.1.1", "fd00::1"] {
            XCTAssertFalse(Catalog.Entry.publicIPv4(s), s)
        }
    }

    func testNilIsEmpty() {
        XCTAssertEqual(Redact.clean(nil), "")
    }

    // Android's RedactTest.messageChoosesAFixedTextForUnknownClasses covers Redact.message/log, which classify
    // Kotlin exception types. Swift has no such overloads (errors are Fail / AuthError / LocalizedError), so it has no port.
}
