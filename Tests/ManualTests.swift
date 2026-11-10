import XCTest

final class ManualTests: XCTestCase {
    private func fixture(_ name: String) -> String { Fixture.text("ovpn/\(name)") }

    private func ovpn(_ file: String, _ text: String, _ user: String = "u", _ pass: String = "p") throws -> J {
        let p = try Manual.parseOvpn(text, name: file, username: user, password: pass)
        XCTAssertEqual(text, p.config)
        return try vetted(Manual.ovpnEndpoint("ovpn-\(file)", p))
    }

    /// Every endpoint an import writes is one the tunnel extension runs.
    private func vetted(_ e: J, file: StaticString = #filePath, line: UInt = #line) -> J {
        XCTAssertNoThrow(try ConfigVet.check(ConfigVetTests.around(e)), file: file, line: line)
        return e
    }

    private func rejects(_ why: String, file: StaticString = #filePath, line: UInt = #line, _ block: () throws -> Void) {
        do { try block() } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains(why), "'\(error.localizedDescription)' should mention '\(why)'", file: file, line: line)
            return
        }
        XCTFail("expected rejection mentioning '\(why)'", file: file, line: line)
    }

    private func parse(_ text: String, user: String = "u", pass: String = "p") throws { _ = try Manual.parseOvpn(text, name: "x", username: user, password: pass) }

    private func ss(_ link: String, _ name: String = "") throws -> J {
        let o = Manual.ssOutbound("ss-x", try Manual.parseSs(link, name: name))
        XCTAssertNoThrow(try ConfigVet.check(ConfigVetTests.around(o)), link)
        return o
    }

    private func b64(_ s: String, url: Bool = false) -> String {
        let t = Data(s.utf8).base64EncodedString()
        return url ? t.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") : t
    }

    func testWireGuardDetectionRequiresAnInterfaceHeaderLine() {
        XCTAssertTrue(WgConf.hasInterface("\u{FEFF}  [InTeRfAcE] # comment\nPrivateKey = x"))
        XCTAssertFalse(WgConf.hasInterface("# [Interface]\nremote example.com\nsetenv note [Interface]"))
        XCTAssertFalse(WgConf.hasInterface("[Interface] extra"))
    }

    func testWeakSecurityRequiresConfirmationOfTheSameWarning() {
        var confirmation = Manual.WarningConfirmation()
        XCTAssertFalse(confirmation.allows("first"))
        XCTAssertFalse(confirmation.allows("changed"))
        XCTAssertTrue(confirmation.allows("changed"))
        confirmation.clear()
        XCTAssertFalse(confirmation.allows("changed"))
        XCTAssertTrue(confirmation.allows(nil))
        XCTAssertNil(confirmation.warning)
    }

    func testWeakSecurityWarnings() throws {
        let base = fixture("expressvpn.ovpn").split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("remote-cert-tls") && !$0.hasPrefix("verify-x509-name") && !$0.hasPrefix("ns-cert-type") }.joined(separator: "\n")
        func warning(_ extra: String) throws -> String? {
            try Manual.weakness(Manual.parseOvpn(base + "\n" + extra, name: "x", username: "u", password: "p"))
        }
        XCTAssertTrue(try XCTUnwrap(warning("")).contains("right server"))
        for directive in ["remote-cert-tls server", "remote-cert-eku serverAuth", "ns-cert-type server", "verify-x509-name vpn.example name"] {
            XCTAssertNil(try warning(directive), directive)
        }
        XCTAssertTrue(try XCTUnwrap(warning("remote-cert-tls client")).contains("right server"))
        for (directive, expected) in [("tls-version-min 1.0", "TLS 1.0"), ("tls-version-min 1.1", "TLS 1.0"),
                                      ("tls-cipher RC4-SHA", "RC4"), ("tls-cipher DES-CBC3-SHA", "3DES"),
                                      ("tls-cert-profile insecure", "certificates")] {
            XCTAssertTrue(try XCTUnwrap(warning("remote-cert-tls server\n" + directive)).contains(expected), directive)
        }
        for method in ["aes-128-ctr", "aes-256-cfb", "rc4-md5", "chacha20-ietf", "xchacha20"] {
            let profile = try Manual.parseSs("ss://\(b64(method + ":pw"))@h.example:1")
            XCTAssertNotNil(Manual.weakness(profile), method)
        }
        let good = try Manual.parseSs("ss://\(b64("aes-256-gcm:pw"))@h.example:1")
        XCTAssertNil(Manual.weakness(good))
    }

    func testX509UsernameFieldOnlyAllowsCNForNameChecks() throws {
        let base = fixture("expressvpn.ovpn").split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("verify-x509-name") }.joined(separator: "\n")
        for type in ["name", "name-prefix"] {
            let named = base + "\nverify-x509-name gw.example \(type)"
            try parse(named)
            try parse(named + "\nx509-username-field cn")
            for field in ["OU", "emailAddress", "ext:subjectAltName", "CN OU"] {
                rejects("only the certificate's CN") { try parse(named + "\nx509-username-field \(field)") }
            }
        }
        try parse(base + "\nx509-username-field OU")
        try parse(base + "\nverify-x509-name gw.example subject\nx509-username-field OU")
    }

    func testExpressVpn() throws {
        let e = try ovpn("expressvpn", fixture("expressvpn.ovpn"))
        XCTAssertEqual(e["type"]?.str, "openvpn-client")
        XCTAssertEqual(e["server"]?.str, "usa-new-york-1-ca-version-2.expressnetw.com")
        XCTAssertEqual(e["server_port"]?.int, 1195)
        XCTAssertEqual(e["network"]?.str, "udp")
        XCTAssertEqual(e["username"]?.str, "u"); XCTAssertEqual(e["password"]?.str, "p")
        XCTAssertEqual(e["auth"]?.str, "SHA512")
        XCTAssertNil(e["data_ciphers"]); XCTAssertNil(e["data_ciphers_fallback"])
        XCTAssertEqual(e["compression_lzo"]?.str, "no")
        XCTAssertNil(e["allow_compression"])
        XCTAssertEqual(e["fragment"]?.int, 1300); XCTAssertEqual(e["mss_fix"]?.int, 1200); XCTAssertEqual(e["mtu"]?.int, 1500)
        XCTAssertEqual(e["route_no_pull"]?.bool, true)
        let tls = try XCTUnwrap(e["tls"])
        XCTAssertEqual(tls["server_name"]?.str, "Server"); XCTAssertEqual(tls["server_name_type"]?.str, "name-prefix")
        XCTAssertEqual(tls["ns_certificate_type"]?.str, "server")
        XCTAssertTrue(tls["certificate"]?.str?.hasPrefix("-----BEGIN CERTIFICATE-----") == true)
        XCTAssertNil(tls["client_certificate"])
        let wrap = try XCTUnwrap(tls["control_wrap"])
        XCTAssertEqual(wrap["type"]?.str, "tls_auth"); XCTAssertEqual(wrap["direction"]?.str, "client")
        XCTAssertTrue(wrap["key"]?.str?.hasPrefix("-----BEGIN OpenVPN Static key V1-----") == true)
        XCTAssertFalse(wrap["key"]?.str?.contains("#") ?? true)
    }

    func testCyberGhost() throws {
        let e = try ovpn("cyberghost", fixture("cyberghost.ovpn"))
        XCTAssertEqual(e["server"]?.str, "87-1-nl.cg-dialup.net"); XCTAssertEqual(e["server_port"]?.int, 443)
        XCTAssertNil(e["data_ciphers_fallback"]); XCTAssertNil(e["data_ciphers"])
        XCTAssertEqual(e["auth"]?.str, "SHA256")
        XCTAssertEqual(e["ping_interval"]?.str, "5s"); XCTAssertEqual(e["ping_restart"]?.str, "20s")
        XCTAssertEqual(e["renegotiate_disabled"]?.bool, true); XCTAssertEqual(e["explicit_exit_notify"]?.int, 2)
        XCTAssertEqual(e["compression_lzo"]?.str, "adaptive"); XCTAssertEqual(e["allow_compression"]?.str, "asym")
        let tls = try XCTUnwrap(e["tls"])
        XCTAssertEqual(tls["remote_certificate_tls"]?.str, "server")
        XCTAssertTrue(tls["client_certificate"]?.str?.contains("BEGIN CERTIFICATE") == true)
        XCTAssertTrue(tls["client_key"]?.str?.contains("BEGIN PRIVATE KEY") == true)
        let wrap = try XCTUnwrap(tls["control_wrap"])
        XCTAssertEqual(wrap["type"]?.str, "tls_crypt"); XCTAssertNil(wrap["direction"])
    }

    func testSelfHosted() throws {
        let e = try ovpn("selfhosted", fixture("selfhosted.ovpn"))
        XCTAssertNil(e["server"])
        let servers = e["servers"]?.list ?? []
        XCTAssertEqual(servers.compactMap { $0["server"]?.str }, ["vpn.example.net", "vpn2.example.net", "203.0.113.10"])
        XCTAssertEqual(servers.compactMap { $0["server_port"]?.int }, [443, 8443, 1194])
        XCTAssertEqual(servers.compactMap { $0["network"]?.str }, ["tcp", "tcp", "udp"])
        XCTAssertEqual(e["remote_random"]?.bool, true)
        XCTAssertEqual(e["data_ciphers"]?.strs, ["AES-256-GCM", "AES-128-GCM", "CHACHA20-POLY1305"])
        XCTAssertEqual(e["data_ciphers_fallback"]?.str, "AES-128-CBC")
        XCTAssertEqual(e["renegotiate_interval"]?.str, "3600s")
        XCTAssertEqual(e["ping_interval"]?.str, "10s"); XCTAssertEqual(e["ping_restart"]?.str, "60s")
        let tls = try XCTUnwrap(e["tls"])
        XCTAssertEqual(tls["server_name"]?.str, "vpn.example.net"); XCTAssertEqual(tls["server_name_type"]?.str, "name")
        XCTAssertEqual(tls["version_min"]?.str, "1.2")
        XCTAssertEqual(tls["control_wrap"]?["direction"]?.str, "client")
        XCTAssertNil(e["redirect_gateway"])
    }

    func testOvpnRejections() throws {
        let ex = fixture("expressvpn.ovpn")
        func with(_ extra: String) -> String { ex + "\n" + extra }
        func without(_ re: String) -> String { ex.replacing(try! Regex(re), with: "") }
        let cert = "<cert>\n-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n</cert>"
        rejects("username and password") { try parse(ex, user: "", pass: "") }
        rejects("username and password") { try parse(ex, user: "u", pass: "") }
        rejects("too large") { try parse(ex + String(repeating: "#", count: 300_000)) }
        rejects("no 'remote'") { try parse(without("remote [^\\n]+\\n")) }
        rejects("client profile") { try parse(without("tls-client\\n")) }
        rejects("<ca>") { try parse(without("(?s)<ca>.*?</ca>\\n")) }
        rejects("tun") { try parse(ex.replacingOccurrences(of: "dev tun", with: "dev tap")) }
        rejects("cipher") { try parse(ex.replacingOccurrences(of: "AES-256-CBC", with: "BF-CBC")) }
        rejects("auth digest") { try parse(ex.replacingOccurrences(of: "SHA512", with: "MD5")) }
        rejects("PKCS#12") { try parse(with("<pkcs12>\nAAAA\n</pkcs12>")) }
        rejects("PKCS#12") { try parse(with("pkcs12 client.p12")) }
        rejects("inline") { try parse(without("(?s)<ca>.*?</ca>\\n") + "\nca ca.crt") }
        rejects("inline") { try parse(with("cert client.crt")) }
        rejects("both <cert> and <key>") { try parse(with(cert)) }
        rejects("compress lzo") { try parse(with("compress lzo")) }
        rejects("proxy") { try parse(with("http-proxy 10.0.0.1 8080")) }
        rejects("2FA") { try parse(with("static-challenge \"Code\" 1")) }
        rejects("fragment only works over UDP") { try parse(ex.replacingOccurrences(of: "proto udp", with: "proto tcp")) }
        rejects("Unsupported OpenVPN option: frobnicate") { try parse(with("frobnicate 1")) }
        rejects("Encrypted private key") {
            try parse(with(cert + "\n<key>\n-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nAA==\n-----END RSA PRIVATE KEY-----\n</key>"))
        }
        rejects("Unterminated") { try parse(with("<ca>\nxx")) }
    }

    func testTlsCipherIsEnforcedAndTls13SuitesAreRefused() throws {
        let ex = fixture("expressvpn.ovpn")
        let e = try ovpn("tls-cipher", ex + "\ntls-cipher ECDHE-RSA-AES256-GCM-SHA384:TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256")
        XCTAssertEqual(e["tls"]?["cipher"]?.str, "ECDHE-RSA-AES256-GCM-SHA384:TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256")
        XCTAssertNil(try ovpn("no-tls-cipher", ex)["tls"]?["cipher"])
        rejects("tls-cipher") { try parse(ex + "\ntls-cipher DEFAULT") }
        rejects("tls-cipher") { try parse(ex + "\ntls-cipher TLS-DHE-RSA-WITH-AES-256-GCM-SHA384") }
        rejects("tls-ciphersuites") { try parse(ex + "\ntls-ciphersuites TLS_AES_256_GCM_SHA384") }
        // OpenVPN's dash form of the IANA names becomes the engine's underscore form; order and other names stay.
        let dashed = try ovpn("tls-cipher-dashed", ex + "\ntls-cipher TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256")
        XCTAssertEqual(dashed["tls"]?["cipher"]?.str, "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384:ECDHE-RSA-AES128-GCM-SHA256:TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256")
        rejects("tls-cipher") { try parse(ex + "\ntls-cipher TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384:") }
    }

    /// `block-ipv6` keeps its meaning: the endpoint drops IPv6 sent into it.
    func testBlockIpv6IsKept() throws {
        let ex = fixture("expressvpn.ovpn")
        XCTAssertEqual(try ovpn("block-ipv6", ex + "\nblock-ipv6")["block_ipv6"]?.bool, true)
        XCTAssertNil(try ovpn("no-block-ipv6", ex)["block_ipv6"])
    }

    /// The imported count is bounded (the engine waits a second for each while it stops), and a pushed one is ignored.
    func testExplicitExitNotifyIsBoundedAndNeverPushed() throws {
        let ex = fixture("expressvpn.ovpn").replacingOccurrences(of: "explicit-exit-notify\n", with: "")
        func count(_ line: String) throws -> Int? { try ovpn("een", ex + line)["explicit_exit_notify"]?.int }
        XCTAssertNil(try count(""))
        XCTAssertEqual(try count("\nexplicit-exit-notify"), 1)
        XCTAssertEqual(try count("\nexplicit-exit-notify 0"), 0)
        XCTAssertEqual(try count("\nexplicit-exit-notify 5"), 5)
        XCTAssertEqual(try count("\nexplicit-exit-notify 3600"), 5)
        XCTAssertEqual(try count("\nexplicit-exit-notify 9223372036854775807"), 5)
        rejects("explicit-exit-notify") { try parse(ex + "\nexplicit-exit-notify -1") }
        rejects("explicit-exit-notify") { try parse(ex + "\nexplicit-exit-notify 99999999999999999999") }
        let f = try ovpn("een-filter", ex + "\npull-filter accept explicit")["pull_filters"]?.list ?? []
        XCTAssertEqual(f.map { "\($0["action"]?.str ?? "")|\($0["text"]?.str ?? "")" }, ["ignore|explicit-exit-notify", "accept|explicit"])
    }

    func testNcpDisableWinsOverAnExplicitCipherList() throws {
        let ex = fixture("expressvpn.ovpn")
        let e = try ovpn("ncp-disable", ex + "\nncp-disable\ndata-ciphers AES-128-GCM:CHACHA20-POLY1305\ndata-ciphers-fallback AES-128-CBC")
        XCTAssertEqual(e["data_ciphers"]?.strs, ["AES-256-CBC"])
        XCTAssertEqual(e["data_ciphers_fallback"]?.str, "AES-256-CBC")
        let gcm = try ovpn("ncp-disable-gcm", fixture("cyberghost.ovpn") + "\nncp-disable\nncp-ciphers AES-128-GCM")
        XCTAssertEqual(gcm["data_ciphers"]?.strs, ["AES-256-GCM"])
        XCTAssertEqual(gcm["data_ciphers_fallback"]?.str, "AES-256-GCM")
        rejects("ncp-disable needs a cipher") { try parse(ex.replacingOccurrences(of: "cipher AES-256-CBC\n", with: "") + "\nncp-disable") }
    }

    func testPingRestartZeroDisablesTheRestartTimeout() throws {
        let ex = fixture("expressvpn.ovpn")
        let off = try ovpn("ping-restart-0", ex + "\nping-restart 0")
        XCTAssertEqual(off["ping_restart_disabled"]?.bool, true); XCTAssertNil(off["ping_restart"])
        let keepalive = try ovpn("keepalive-0", ex + "\nkeepalive 10 0")
        XCTAssertEqual(keepalive["ping_restart_disabled"]?.bool, true); XCTAssertEqual(keepalive["ping_interval"]?.str, "10s")
        XCTAssertNil(try ovpn("ping-restart-default", ex)["ping_restart_disabled"])
        XCTAssertNil(try ovpn("ping-restart-30", ex + "\nping-restart 30")["ping_restart_disabled"])
    }

    func testOvpnWithoutLoginNeedsNone() throws {
        let text = fixture("cyberghost.ovpn").replacingOccurrences(of: "auth-user-pass\n", with: "")
        let e = try vetted(Manual.ovpnEndpoint("t", Manual.parseOvpn(text, name: "x", username: "", password: "")))
        XCTAssertNil(e["username"])
    }

    func testInlineLoginIsUsedWhenNothingWasTyped() throws {
        let base = fixture("cyberghost.ovpn")
        let text = base.replacingOccurrences(of: "auth-user-pass\n", with: "<auth-user-pass>\n  alice \npass word \n</auth-user-pass>\n")
        let e = try vetted(Manual.ovpnEndpoint("t", Manual.parseOvpn(text, name: "x", username: "", password: "")))
        XCTAssertEqual(e["username"]?.str, "alice"); XCTAssertEqual(e["password"]?.str, "pass word ")
        let typed = try vetted(Manual.ovpnEndpoint("t", Manual.parseOvpn(text, name: "x", username: "bob", password: " s p ")))
        XCTAssertEqual(typed["username"]?.str, "bob"); XCTAssertEqual(typed["password"]?.str, " s p ")
        rejects("username and password") { try parse(base.replacingOccurrences(of: "auth-user-pass\n", with: "<auth-user-pass>\nalice\n</auth-user-pass>\n"), user: "", pass: "") }
        rejects("username and password") { try parse(base, user: "", pass: "") }
    }

    func testExtraCertsExtendTheClientChain() throws {
        let base = fixture("cyberghost.ovpn")
        let ca = try XCTUnwrap(base.firstMatch(of: /(?s)<ca>\s*(.*?)\s*<\/ca>/)?.1)
        let e = try ovpn("extra-certs", base.replacingOccurrences(of: "<key>", with: "<extra-certs>\n\(ca)\n</extra-certs>\n<key>"))
        let chain = try XCTUnwrap(e["tls"]?["client_certificate"]?.str)
        XCTAssertEqual(chain.ranges(of: "BEGIN CERTIFICATE").count, 2)
        XCTAssertTrue(chain.hasSuffix(ca.split(separator: "\n").last!.trimmingCharacters(in: .whitespaces)))
        XCTAssertEqual(try XCTUnwrap(ovpn("no-extra-certs", base)["tls"]?["client_certificate"]?.str).ranges(of: "BEGIN CERTIFICATE").count, 1)
        rejects("extra-certs") { try parse(fixture("expressvpn.ovpn") + "\n<extra-certs>\n\(ca)\n</extra-certs>") }
    }

    private var base: String { fixture("expressvpn.ovpn").replacingOccurrences(of: "ns-cert-type server\n", with: "") }

    private func tls(_ name: String, _ extra: String) throws -> J { try XCTUnwrap(ovpn(name, base + "\n" + extra)["tls"]) }

    func testBareRemoteCertKuKeepsTheExtensionRequirementAlongsideEku() throws {
        let server = try tls("ku-eku-server", "remote-cert-ku\nremote-cert-eku \"TLS Web Server Authentication\"")
        XCTAssertEqual(server["remote_certificate_tls"]?.str, "server"); XCTAssertNil(server["remote_certificate_eku"])
        let client = try tls("ku-eku-client", "remote-cert-eku 1.3.6.1.5.5.7.3.2\nremote-cert-ku")
        XCTAssertEqual(client["remote_certificate_tls"]?.str, "client"); XCTAssertNil(client["remote_certificate_eku"])
        let tlsPlusEku = try tls("tls-eku", "remote-cert-tls client\nremote-cert-eku clientAuth")
        XCTAssertEqual(tlsPlusEku["remote_certificate_tls"]?.str, "client"); XCTAssertNil(tlsPlusEku["remote_certificate_eku"])
        rejects("can't be combined") { try parse(base + "\nremote-cert-ku\nremote-cert-eku 1.3.6.1.5.5.7.3.3") }
        // Alone, a bare remote-cert-ku demands a key-usage extension the engine can't express: refused, not dropped.
        rejects("bare remote-cert-ku") { try parse(base + "\nremote-cert-ku") }
        rejects("can't be combined") { try parse(base + "\nremote-cert-tls server\nremote-cert-eku 1.3.6.1.5.5.7.3.3") }
        let values = try tls("ku-values-eku", "remote-cert-ku a0 88\nremote-cert-eku 1.3.6.1.5.5.7.3.3")
        XCTAssertEqual(values["remote_certificate_ku"]?.strs, ["a0", "88"]); XCTAssertEqual(values["remote_certificate_eku"]?.str, "1.3.6.1.5.5.7.3.3")
        let eku = try tls("eku-only", "remote-cert-eku 1.3.6.1.5.5.7.3.3")
        XCTAssertEqual(eku["remote_certificate_eku"]?.str, "1.3.6.1.5.5.7.3.3"); XCTAssertNil(eku["remote_certificate_tls"])
        XCTAssertEqual(try tls("tls-only", "remote-cert-tls server")["remote_certificate_tls"]?.str, "server")
        XCTAssertEqual(try tls("eku-after-tls-ku", "remote-cert-tls server\nremote-cert-ku a0\nremote-cert-eku 1.3.6.1.5.5.7.3.3")["remote_certificate_eku"]?.str, "1.3.6.1.5.5.7.3.3")
    }

    func testCipherAloneNeverWidensNegotiation() throws {
        let lone = try ovpn("cipher-only", base)
        XCTAssertNil(lone["data_ciphers"]); XCTAssertNil(lone["data_ciphers_fallback"])
        let withList = try ovpn("cipher-list", base + "\ndata-ciphers AES-128-GCM")
        XCTAssertEqual(withList["data_ciphers"]?.strs, ["AES-128-GCM"]); XCTAssertNil(withList["data_ciphers_fallback"])
        let fb = try ovpn("cipher-fallback", base + "\ndata-ciphers-fallback AES-128-CBC")
        XCTAssertNil(fb["data_ciphers"]); XCTAssertEqual(fb["data_ciphers_fallback"]?.str, "AES-128-CBC")
        let noCipher = base.replacingOccurrences(of: "cipher AES-256-CBC\n", with: "")
        let flipped = try ovpn("fallback-then-cipher", noCipher + "\ndata-ciphers-fallback AES-128-CBC\ncipher AES-192-CBC")
        XCTAssertEqual(flipped["data_ciphers_fallback"]?.str, "AES-192-CBC")
        let onlyFallback = try ovpn("fallback-only", noCipher + "\ndata-ciphers-fallback AES-128-CBC")
        XCTAssertEqual(onlyFallback["data_ciphers_fallback"]?.str, "AES-128-CBC")
    }

    func testCompatModeRestoresTheLegacyCipherOnlyWhereOpenVpnDoes() throws {
        let c24 = try ovpn("compat-2.4.0", base + "\ncompat-mode 2.4.0")
        XCTAssertEqual(c24["data_ciphers"]?.strs, ["AES-256-GCM", "AES-128-GCM", "CHACHA20-POLY1305", "AES-256-CBC"])
        XCTAssertNil(c24["data_ciphers_fallback"])
        let c24Fixed = try ovpn("compat-2.4.0-list", base + "\ncompat-mode 2.4.0\ndata-ciphers AES-128-GCM")
        XCTAssertEqual(c24Fixed["data_ciphers"]?.strs, ["AES-128-GCM", "AES-256-CBC"])
        let c24Gcm = try ovpn("compat-2.4.0-gcm", base.replacingOccurrences(of: "AES-256-CBC", with: "AES-256-GCM") + "\ncompat-mode 2.4.0")
        XCTAssertNil(c24Gcm["data_ciphers"])
        let c25 = try ovpn("compat-2.5.0", base + "\ncompat-mode 2.5.0")
        XCTAssertNil(c25["data_ciphers"]); XCTAssertNil(c25["data_ciphers_fallback"])
        let c23 = try ovpn("compat-2.3.0", base + "\ncompat-mode 2.3.0")
        XCTAssertEqual(c23["data_ciphers_fallback"]?.str, "AES-256-CBC")
        XCTAssertEqual(c23["data_ciphers"]?.strs, ["AES-256-GCM", "AES-128-GCM", "CHACHA20-POLY1305", "AES-256-CBC"])
        rejects("compat-mode") { try parse(base + "\ncompat-mode 2.4") }
        rejects("needs a cipher") { try parse(base.replacingOccurrences(of: "cipher AES-256-CBC\n", with: "") + "\ncompat-mode 2.3.0") }
        rejects("Invalid data-ciphers-fallback") { try parse(base + "\ndata-ciphers-fallback AES-128-CBC:AES-256-CBC") }
    }

    func testPullFiltersKeepTheirOrderAndRouteNoPullStaysOn() throws {
        let e = try ovpn("pull-filters", base + "\npull-filter accept \"dhcp-option DNS 10.\"\npull-filter ignore \"dhcp-option\"\npull-filter reject redirect-gateway")
        let f = e["pull_filters"]?.list ?? []
        XCTAssertEqual(f.map { "\($0["action"]?.str ?? "")|\($0["text"]?.str ?? "")" },
                       ["ignore|explicit-exit-notify", "accept|dhcp-option DNS 10.", "ignore|dhcp-option", "reject|redirect-gateway"])
        XCTAssertEqual(e["route_no_pull"]?.bool, true)
        XCTAssertEqual(try ovpn("no-pull-filters", base)["pull_filters"]?.list?.count, 1)
        let shipped = try XCTUnwrap(ovpn("selfhosted-filters", fixture("selfhosted.ovpn"))["pull_filters"]?.list?.dropFirst().first)
        XCTAssertEqual(shipped["action"]?.str, "ignore"); XCTAssertEqual(shipped["text"]?.str, "route-ipv6")
        rejects("pull-filter") { try parse(base + "\npull-filter drop foo") }
        rejects("pull-filter") { try parse(base + "\npull-filter ignore") }
        rejects("pull-filter") { try parse(base + "\npull-filter ignore a b") }
    }

    func testPortAndRportFollowDirectiveOrderForRemotesWithoutAPort() throws {
        let noPort = base.replacingOccurrences(of: "remote usa-new-york-1-ca-version-2.expressnetw.com 1195", with: "remote a.example.net\nremote b.example.net 8443")
        func ports(_ extra: String) throws -> [Int] { try (ovpn("ports", noPort + "\n" + extra)["servers"]?.list ?? []).compactMap { $0["server_port"]?.int } }
        XCTAssertEqual(try ports(""), [1194, 8443])
        XCTAssertEqual(try ports("port 1194\nrport 443"), [443, 8443])
        XCTAssertEqual(try ports("rport 443\nport 1194"), [1194, 8443])
        XCTAssertEqual(try ports("rport 443"), [443, 8443])
        XCTAssertEqual(try ports("port 1195"), [1195, 8443])
        XCTAssertEqual(try ports("port 1194\nremote-random\nrport 443"), [443, 8443])
        rejects("Invalid port") { try parse(noPort + "\nrport x") }
    }

    func testWireGuardImportRulesForRoutesAndAmnezia() throws {
        let key = String(repeating: "A", count: 43) + "="
        func conf(_ allowed: String, _ extra: String = "") -> String {
            "[Interface]\nPrivateKey = \(key)\nAddress = 10.0.0.2/32\n\(extra)\n[Peer]\nPublicKey = \(key)\nEndpoint = 203.0.113.1:51820\nAllowedIPs = \(allowed)\n"
        }
        let full = try WgConf.parse(conf("0.0.0.0/0, ::/0"), name: "x")
        try WgConf.requireFullTunnel(full)
        XCTAssertEqual(full.allowedIps, ["0.0.0.0/0"])
        let subnet = try WgConf.parse(conf("10.0.0.0/24, 192.168.1.0/24"), name: "x")
        XCTAssertEqual(subnet.allowedIps, ["10.0.0.0/24", "192.168.1.0/24"])
        rejects("only reaches 10.0.0.0/24, 192.168.1.0/24; import it under Settings → Home") { try WgConf.requireFullTunnel(subnet) }
        // Split default and the WireGuard apps' "exclude private IPs" list carry every public address: an exit.
        try WgConf.requireFullTunnel(try WgConf.parse(conf("0.0.0.0/1, 128.0.0.0/1, ::/1, 8000::/1"), name: "x"))
        let excludePrivate = "0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, "
            + "168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, "
            + "192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, "
            + "192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, ::/0"
        try WgConf.requireFullTunnel(try WgConf.parse(conf(excludePrivate), name: "x"))
        XCTAssertTrue(WgConf.coversPublicIPv4(["128.0.0.0/1", "bogus", "0.0.0.0/1", "300.0.0.0/8", "1.2.3.4/33"]))
        XCTAssertTrue(WgConf.coversPublicIPv4(["0.0.0.1/1", "128.0.0.0/1"]))
        // One public address missing anywhere, the very first or the very last included, is not an exit.
        XCTAssertFalse(WgConf.coversPublicIPv4(["0.0.0.0/1"]))
        XCTAssertFalse(WgConf.coversPublicIPv4(["1.0.0.1/32", "1.0.0.2/31", "1.0.0.4/30", "1.0.0.8/29", "1.0.0.16/28", "1.0.0.32/27", "1.0.0.64/26",
            "1.0.0.128/25", "1.0.1.0/24", "1.0.2.0/23", "1.0.4.0/22", "1.0.8.0/21", "1.0.16.0/20", "1.0.32.0/19", "1.0.64.0/18", "1.0.128.0/17",
            "1.1.0.0/16", "1.2.0.0/15", "1.4.0.0/14", "1.8.0.0/13", "1.16.0.0/12", "1.32.0.0/11", "1.64.0.0/10", "1.128.0.0/9", "2.0.0.0/7",
            "4.0.0.0/6", "8.0.0.0/5", "16.0.0.0/4", "32.0.0.0/3", "64.0.0.0/2", "128.0.0.0/1"]))
        XCTAssertTrue(WgConf.coversPublicIPv4(["1.0.0.0/32", "1.0.0.1/32", "1.0.0.2/31", "1.0.0.4/30", "1.0.0.8/29", "1.0.0.16/28", "1.0.0.32/27", "1.0.0.64/26",
            "1.0.0.128/25", "1.0.1.0/24", "1.0.2.0/23", "1.0.4.0/22", "1.0.8.0/21", "1.0.16.0/20", "1.0.32.0/19", "1.0.64.0/18", "1.0.128.0/17",
            "1.1.0.0/16", "1.2.0.0/15", "1.4.0.0/14", "1.8.0.0/13", "1.16.0.0/12", "1.32.0.0/11", "1.64.0.0/10", "1.128.0.0/9", "2.0.0.0/7",
            "4.0.0.0/6", "8.0.0.0/5", "16.0.0.0/4", "32.0.0.0/3", "64.0.0.0/2", "128.0.0.0/1"]))
        XCTAssertFalse(WgConf.coversPublicIPv4(["0.0.0.0/1", "128.0.0.0/2"]))
        // Multicast and reserved space (224/3) aren't needed.
        XCTAssertTrue(WgConf.coversPublicIPv4(["0.0.0.0/1", "128.0.0.0/2", "192.0.0.0/3"]))
        XCTAssertFalse(WgConf.coversPublicIPv4(["223.255.255.254/31", "0.0.0.0/1", "128.0.0.0/2", "192.0.0.0/4", "208.0.0.0/5", "216.0.0.0/6", "220.0.0.0/7", "222.0.0.0/8", "223.0.0.0/9"]))
        XCTAssertFalse(WgConf.coversPublicIPv4([]))
        // Exits compile to 0.0.0.0/0 whatever the profile listed.
        XCTAssertEqual(try WgConf.parse(conf("0.0.0.0/1, 128.0.0.0/1"), name: "x").allowedIps, ["0.0.0.0/1", "128.0.0.0/1"])
        for k in ["Jc", "Jmin", "Jmax", "S1", "S2", "H1", "H2", "H3", "H4", "I1", "I5"] {
            rejects("Obfuscated (AmneziaWG) configs aren't supported") { _ = try WgConf.parse(conf("0.0.0.0/0", "\(k) = 5"), name: "x") }
        }
        rejects("AmneziaWG") { _ = try WgConf.parse(conf("0.0.0.0/0").replacingOccurrences(of: "Endpoint", with: "jc = 4\nEndpoint"), name: "x") }
        // Endpoints: an IPv6 address needs brackets, or "2001:db8::1" would read as port 1.
        func endpoint(_ e: String) throws -> String {
            try WgConf.parse(conf("0.0.0.0/0").replacingOccurrences(of: "203.0.113.1:51820", with: e), name: "x").endpoint
        }
        for ok in ["203.0.113.1:51820", "vpn.example.net:443", "[2001:db8::1]:51820"] { XCTAssertEqual(try endpoint(ok), ok) }
        for bad in ["2001:db8::1", "[2001:db8::1]", "[]:51820", ":51820", "203.0.113.1", "203.0.113.1:0", "203.0.113.1:65536", "[2001:db8::1:51820", "a]:1"] {
            rejects("Endpoint needs host:port") { _ = try endpoint(bad) }
        }
        // The interface address must be an IPv4 address with a prefix; DNS keeps IPv4 servers only.
        func interface(_ lines: String) throws -> WgPeer {
            try WgConf.parse(conf("0.0.0.0/0").replacingOccurrences(of: "Address = 10.0.0.2/32", with: lines), name: "x")
        }
        XCTAssertEqual(try interface("Address = 10.0.0.2, 10.0.0.3/24, fd00::2/64").address, ["10.0.0.2/32", "10.0.0.3/24"])
        for bad in ["10.0.0.2/99", "not an ip", "10.0.0.2/33", "0.0.0.0/0", "10.0.0.256", "010.0.0.2", "10.0.0.2/"] {
            rejects("Address has an invalid value") { _ = try interface("Address = \(bad)") }
        }
        let dns = try interface("Address = 10.0.0.2/32\nDNS = 10.64.0.1, 1dns.example.com, \u{663}.1.1.1, fd00::1, corp.example, 9.9.9.9")
        XCTAssertEqual(dns.dns, ["10.64.0.1", "9.9.9.9"])
    }

    func testSsSip002Base64() throws {
        let userinfo = b64("chacha20-ietf-poly1305:pa:ss/w0rd+1", url: true)
        let o = try ss("ss://\(userinfo)@ss.example.net:8388/?outline=1#Outline%20NL")
        XCTAssertEqual(o["type"]?.str, "shadowsocks")
        XCTAssertEqual(o["server"]?.str, "ss.example.net"); XCTAssertEqual(o["server_port"]?.int, 8388)
        XCTAssertEqual(o["method"]?.str, "chacha20-ietf-poly1305"); XCTAssertEqual(o["password"]?.str, "pa:ss/w0rd+1")
        XCTAssertNil(o["plugin"])
        XCTAssertEqual(try Manual.parseSs("ss://\(userinfo)@ss.example.net:8388#Outline%20NL").name, "Outline NL")
        XCTAssertEqual(try Manual.parseSs("ss://\(userinfo)@ss.example.net:8388#x", name: "Mine").name, "Mine")
        XCTAssertEqual(try Manual.parseSs("ss://\(userinfo)@ss.example.net:8388").name, "ss.example.net")
        // v2ray-plugin's cert= would make the engine read a file on this device.
        rejects("certRaw") { _ = try Manual.parseSs("ss://\(userinfo)@ss.example.net:8388/?plugin=v2ray-plugin%3Btls%3Bcert%3D%2Fdev%2Fzero#x") }
        rejects("certRaw") { _ = try Manual.parseSs("ss://\(userinfo)@ss.example.net:8388/?plugin=v2ray-plugin%3Btls%3Bc%5Cert%3D%2Fdev%2Fzero#x") }
        XCTAssertEqual(try Manual.parseSs("ss://\(userinfo)@ss.example.net:8388/?plugin=v2ray-plugin%3Btls%3Bhost%3Da.example#x").pluginOpts, "tls;host=a.example")
    }

    func testSsSip002PlainWithPlugin() throws {
        let key32 = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 * 13 + 1) }).base64EncodedString()
        let o = try ss("ss://2022-blake3-aes-256-gcm:\(Http.enc(key32))@[2001:db8::1]:443/?plugin=v2ray-plugin%3Bhost%3Dcdn.example.net%3Bpath%3D%2Fws#IPv6")
        XCTAssertEqual(o["server"]?.str, "2001:db8::1"); XCTAssertEqual(o["server_port"]?.int, 443)
        XCTAssertEqual(o["method"]?.str, "2022-blake3-aes-256-gcm"); XCTAssertEqual(o["password"]?.str, key32)
        XCTAssertEqual(o["plugin"]?.str, "v2ray-plugin"); XCTAssertEqual(o["plugin_opts"]?.str, "host=cdn.example.net;path=/ws")
    }

    func testSsLegacy() throws {
        let body = b64("aes-128-gcm:s3cret@legacy.example.net:8443")
        let o = try ss("ss://\(body)#Legacy%20box")
        XCTAssertEqual(o["server"]?.str, "legacy.example.net"); XCTAssertEqual(o["server_port"]?.int, 8443)
        XCTAssertEqual(o["method"]?.str, "aes-128-gcm"); XCTAssertEqual(o["password"]?.str, "s3cret")
        XCTAssertEqual(try Manual.parseSs("ss://\(body)#Legacy%20box").name, "Legacy box")
    }

    func testSsObfs() throws {
        let key16 = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 * 11 + 5) }).base64EncodedString()
        let userinfo = b64("2022-blake3-aes-128-gcm:\(key16)")
        let o = try ss("ss://\(userinfo)@203.0.113.7:8388/?plugin=obfs-local%3Bobfs%3Dtls%3Bobfs-host%3Dcdn.example.com")
        XCTAssertEqual(o["plugin"]?.str, "obfs-local"); XCTAssertEqual(o["plugin_opts"]?.str, "obfs=tls;obfs-host=cdn.example.com")
        XCTAssertEqual(try Manual.parseSs("ss://\(userinfo)@h.example:1/?plugin=simple-obfs%3Bobfs%3Dhttp").plugin, "obfs-local")
    }

    func testSsRejections() {
        let ok = b64("aes-256-gcm:pw")
        func bad(_ why: String, _ link: String) { rejects(why) { _ = try Manual.parseSs(link) } }
        bad("ss://", "vmess://abc")
        bad("ssconf", "ssconf://example.com/key")
        bad("cipher", "ss://" + b64("bf-cfb:pw") + "@h.example:1")
        bad("cipher", "ss://none:pw@h.example:1")
        bad("port", "ss://\(ok)@h.example:0")
        bad("port", "ss://\(ok)@h.example:70000")
        bad("port", "ss://\(ok)@h.example")
        bad("host", "ss://\(ok)@:8388")
        bad("empty password", "ss://aes-256-gcm:@h.example:1")
        bad("plugin", "ss://\(ok)@h.example:1/?plugin=kcptun%3Bkey%3Dx")
        bad("prefix", "ss://\(ok)@h.example:1/?prefix=%16%03%01")
        bad("malformed", "ss://%%%@h.example:1")
        bad("decode", "ss://!!!notbase64!!!")
    }

    func testSsSizeLimits() throws {
        let ok = b64("aes-256-gcm:pw")
        func bad(_ why: String, _ link: String, name: String = "") { rejects(why) { _ = try Manual.parseSs(link, name: name) } }
        bad("too long", "ss://\(ok)@h.example:1/?plugin=" + String(repeating: "a", count: 9000))
        bad("credentials are too long", "ss://\(b64("aes-256-gcm:" + String(repeating: "p", count: 2000)))@h.example:1")
        bad("credentials are too long", "ss://aes-256-gcm:" + String(repeating: "p", count: 2000) + "@h.example:1")
        bad("name is too long", "ss://\(ok)@h.example:1#" + String(repeating: "n", count: 200))
        bad("name is too long", "ss://\(ok)@h.example:1", name: String(repeating: "n", count: 200))
        bad("host is too long", "ss://\(ok)@" + String(repeating: "h", count: 300) + ":1")
        XCTAssertEqual(try Manual.parseSs("ss://\(ok)@h.example:1#" + String(repeating: "n", count: 128)).name.count, 128)
    }

    func testJsonValueSerializesDeterministically() {
        let v: J = ["b": [1, true, "x\"\n"], "a": ["z": 2, "y": J.strings([])]]
        XCTAssertEqual(v.string, #"{"a":{"y":[],"z":2},"b":[1,true,"x\"\n"]}"#)
        var w = v
        w["c"] = "d"
        XCTAssertEqual(w["c"]?.str, "d"); XCTAssertEqual(w["b"]?[0]?.int, 1); XCTAssertNil(v["c"])
    }
}
