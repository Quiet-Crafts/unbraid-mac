import XCTest

final class TsLoginTests: XCTestCase {
    func testPendingPersistsUntilRunning() {
        XCTAssertTrue(TsLogin.pending(authURL: "https://login.tailscale.com/a", backend: "NeedsLogin", was: false))
        XCTAssertTrue(TsLogin.pending(authURL: nil, backend: "Starting", was: true))
        XCTAssertFalse(TsLogin.pending(authURL: nil, backend: "Running", was: true))
        XCTAssertFalse(TsLogin.pending(authURL: nil, backend: "NeedsLogin", was: false))
    }

    private func v(_ url: String, _ control: String? = nil) -> TsLogin.Verdict { TsLogin.check(url, controlUrl: control).verdict }

    func testTailscaleLinksOpenWithTheDefaultServer() {
        XCTAssertEqual(v("https://login.tailscale.com/a/1a2b3c"), .open)
        XCTAssertEqual(v("https://LOGIN.Tailscale.com./a/1a2b3c"), .open)
        XCTAssertEqual(v("https://login.tailscale.com/a/x", "https://controlplane.tailscale.com"), .open)
        XCTAssertEqual(v("https://login.tailscale.com/a/x", "  "), .open)
    }

    func testHeadscaleLinksOpenOnlyOnItsOwnHost() {
        XCTAssertEqual(v("https://hs.example.net/register/nodekey:abc", "https://hs.example.net"), .open)
        XCTAssertEqual(v("https://hs.example.net:8443/oidc/register/x", "https://hs.example.net:8443/"), .open)
        XCTAssertEqual(v("https://login.tailscale.com/a/x", "https://hs.example.net"), .ask)
        XCTAssertEqual(v("https://idp.example.org/auth", "https://hs.example.net"), .ask)
        XCTAssertEqual(v("https://login.tailscale.com/a/x", "https://other.tailscale.com"), .ask)
    }

    func testAnUnreadableCustomServerTrustsNothing() {
        XCTAssertEqual(v("https://login.tailscale.com/a/x", "hs example net"), .ask)
        XCTAssertEqual(v("https://login.tailscale.com/a/x", "not-a-url"), .ask)
    }

    func testLookalikeHostsAsk() {
        XCTAssertEqual(v("https://login.tailscale.com.evil.example/a/x"), .ask)
        XCTAssertEqual(v("https://eviltailscale.com/a/x"), .ask)
        XCTAssertEqual(TsLogin.check("https://evil.example/a", controlUrl: nil).host, "evil.example")
        // A percent escape in the host decodes to a delimiter elsewhere: no real host has one.
        for escape in ["%5c", "%2f", "%40", "%23", "%3f", "%2e"] {
            XCTAssertEqual(v("https://evil.example\(escape).tailscale.com/a/x"), .refuse, escape)
            XCTAssertEqual(TsLogin.check("https://evil.example\(escape).hs.example.com/a", controlUrl: "https://evil.example\(escape).hs.example.com").verdict, .refuse, escape)
            XCTAssertNil(TsLogin.controlUrl("https://evil.example\(escape).hs.example.com"), escape)
        }
        // An IPv6 zone is written with one, and such a host never ends in a name.
        XCTAssertEqual(TsLogin.controlUrl("https://[fe80::1%25en0]:8443"), "https://[fe80::1%25en0]:8443")
        XCTAssertEqual(v("https://[fe80::1%25en0]:8443/a", "https://[fe80::1%25en0]:8443"), .open)
        XCTAssertEqual(v("https://[fe80::1%25en0]/a"), .ask)
    }

    func testTheLaunchedLinkIsTheCleanedOne() {
        let r = TsLogin.check("  HTTPS://login.tailscale.com/a/x?y=1  ", controlUrl: nil)
        XCTAssertEqual(r.verdict, .open)
        XCTAssertEqual(r.url, "https://login.tailscale.com/a/x?y=1")
    }

    func testNonWebOrMalformedLinksNeverOpen() {
        for u in [
            "http://login.tailscale.com/a/x", "intent://scan/#Intent;scheme=zxing;package=com.example;end",
            "javascript:alert(1)", "market://details?id=x", "https://user:pw@login.tailscale.com/a/x",
            "https:///a/x", "not a url", "https://login.tailscale.com:65536/a", "https://login.tailscale.com:0/a",
        ] {
            let r = TsLogin.check(u, controlUrl: nil)
            XCTAssertEqual(r.verdict, .refuse, u)
            XCTAssertNil(r.url, u)
        }
        XCTAssertEqual(v("https://login.tailscale.com:443/a"), .open)
        XCTAssertEqual(v("https://login.tailscale.com:1/a"), .open)
        XCTAssertEqual(v("https://login.tailscale.com:65535/a"), .open)
        // Internationalised hosts fail closed; their punycode form works.
        XCTAssertEqual(v("https://bücher.example/auth", "https://bücher.example"), .refuse)
        XCTAssertEqual(v("https://xn--bcher-kva.example/auth", "https://xn--bcher-kva.example"), .open)
    }

    /// A Headscale address is saved and compiled one way: scheme and host lowercased, the rest kept.
    func testControlUrlIsNormalised() {
        XCTAssertEqual(TsLogin.controlUrl("  HTTPS://HS.Example.COM/Path?x=Y "), "https://hs.example.com/Path?x=Y")
        XCTAssertEqual(TsLogin.controlUrl("https://hs.example.com:8443"), "https://hs.example.com:8443")
        XCTAssertEqual(TsLogin.controlUrl("https://203.0.113.7"), "https://203.0.113.7")
        XCTAssertEqual(TsLogin.controlUrl("https://[2001:DB8::7]:443"), "https://[2001:db8::7]:443")
        let once = TsLogin.controlUrl("HTTPS://Hs.Example.com")!
        XCTAssertEqual(TsLogin.controlUrl(once), once)
        for bad in ["", "http://hs.example.com", "hs.example.com", "https://", "https://user:pw@hs.example.com", "https://hs.example.com:0", "ftp://hs.example.com"] {
            XCTAssertNil(TsLogin.controlUrl(bad), bad)
        }
    }

    /// The same server however spelled keeps its auth key; another server never inherits it; nothing changed is no change.
    func testServerChangeKeepsTheKeyOnlyForTheSameServer() {
        XCTAssertNil(TsLogin.change(url: "https://hs.example.com", key: "k", to: "https://hs.example.com", authKey: nil))
        XCTAssertNil(TsLogin.change(url: "HTTPS://HS.example.com", key: "k", to: "https://hs.example.com", authKey: nil))
        XCTAssertNil(TsLogin.change(url: nil, key: nil, to: nil, authKey: nil))
        let newKey = TsLogin.change(url: "https://hs.example.com", key: "k", to: "https://hs.example.com", authKey: "k2")
        XCTAssertEqual(newKey?.url, "https://hs.example.com"); XCTAssertEqual(newKey?.key, "k2")
        let other = TsLogin.change(url: "https://hs.example.com", key: "k", to: "https://other.example.com", authKey: nil)
        XCTAssertEqual(other?.url, "https://other.example.com"); XCTAssertNil(other?.key)
        let toDefault = TsLogin.change(url: "https://hs.example.com", key: "k", to: nil, authKey: nil)
        XCTAssertNotNil(toDefault); XCTAssertNil(toDefault?.url); XCTAssertNil(toDefault?.key)
    }
}
