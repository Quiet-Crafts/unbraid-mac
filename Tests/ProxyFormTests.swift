import XCTest

/// The Add Proxy Server sheet's logic: the pasted link, the errors beside the fields, the remote warning's two steps and
/// what is saved.
final class ProxyFormTests: XCTestCase {
    func testALinkFillsEveryFieldAndLeavesOnlyTheHostInAddress() {
        var f = ProxyForm()
        XCTAssertTrue(f.fill(link: " socks5://alice:p%40ss:word@proxy.example.net:1081 "))
        XCTAssertEqual(f.address, "proxy.example.net")
        XCTAssertEqual(f.port, "1081")
        XCTAssertEqual(f.username, "alice")
        XCTAssertEqual(f.password, "p@ss:word")
        XCTAssertFalse(f.address.contains("p@ss"))

        var v6 = ProxyForm()
        XCTAssertTrue(v6.fill(link: "SOCKS5H://[::1]:9050/"))
        XCTAssertEqual(v6.address, "::1")
        XCTAssertEqual(v6.port, "9050")
        XCTAssertEqual(v6.username, "")

        var bare = ProxyForm()
        XCTAssertTrue(bare.fill(link: "socks5://10.0.0.2"))
        XCTAssertEqual(bare.address, "10.0.0.2")
        XCTAssertEqual(bare.port, "1080", "no port in the link keeps the default")
    }

    func testTextThatIsNotASocks5LinkChangesNothing() {
        var f = ProxyForm()
        f.username = "kept"
        for text in ["proxy.example.net", "ss://abc@host:8388", "http://u:p@host:8080", "socks4://host:1080"] {
            XCTAssertFalse(f.fill(link: text), text)
        }
        XCTAssertEqual(f, { var k = ProxyForm(); k.username = "kept"; return k }())
    }

    func testErrorsShowBesideTheirFieldsOnlyOnceAddWasTriedAndKeepWhatWasTyped() {
        var f = ProxyForm()
        f.port = "70000"
        XCTAssertNil(f.hostError)
        XCTAssertNil(f.portError)
        XCTAssertNil(f.add())
        XCTAssertEqual(f.hostError, "Enter a host name or IP address.")
        XCTAssertEqual(f.portError, "Enter a port from 1 to 65535.")
        XCTAssertEqual(f.port, "70000")
        for bad in ["0", "", "abc", "-1"] { f.port = bad; XCTAssertNotNil(f.portError, bad) }
        f.port = "65535"
        XCTAssertNil(f.portError)
        for bad in ["exa mple.com", "http://x", "-bad.example", "[::1"] { f.address = bad; XCTAssertNotNil(f.hostError, bad) }
        for good in ["127.0.0.1", "localhost", "proxy.example.net", "::1", "[::1]", "fd00::5"] { f.address = good; XCTAssertNil(f.hostError, good) }
    }

    func testALoginNeedsItsPasswordAndAPasswordAloneIsNotSaved() {
        var f = ProxyForm()
        f.address = "127.0.0.1"
        f.username = "bob"
        XCTAssertNil(f.add())
        XCTAssertEqual(f.passwordError, "Enter the password for this username.")
        f.password = "secret"
        let p = f.add()
        XCTAssertEqual(p?.profile.username, "bob")
        XCTAssertEqual(p?.password, "secret")

        var alone = ProxyForm()
        alone.address = "127.0.0.1"
        alone.password = "orphan"
        let saved = alone.add()
        XCTAssertNil(saved?.profile.username)
        XCTAssertNil(saved?.password, "SOCKS5 sends a password only with a username")
        XCTAssertEqual(saved?.secrets, [])
    }

    func testARemoteProxyTakesAddServerThenAddAnywayAndAnEndpointEditAsksAgain() {
        var f = ProxyForm()
        f.address = "proxy.example.net"
        XCTAssertTrue(f.remote)
        XCTAssertEqual(f.primaryTitle, "Add Server")
        XCTAssertNil(f.add(), "the first Add shows the warning")
        XCTAssertEqual(f.primaryTitle, "Add Anyway")
        f.username = "changed login"; f.name = "Office"
        XCTAssertEqual(f.primaryTitle, "Add Anyway", "only the address and port clear the acceptance")
        f.port = "1081"
        XCTAssertEqual(f.primaryTitle, "Add Server")
        XCTAssertNil(f.add())
        f.address = "other.example.net"
        f.password = "pw"
        XCTAssertEqual(f.primaryTitle, "Add Server")
        XCTAssertNil(f.add())
        XCTAssertEqual(f.add()?.profile.host, "other.example.net")

        // A field error comes first, as in the importer: only a proxy that can be saved takes the warning step.
        var g = ProxyForm()
        g.address = "proxy.example.net"; g.username = "bob"
        XCTAssertNil(g.add())
        XCTAssertNotNil(g.passwordError)
        XCTAssertEqual(g.primaryTitle, "Add Server")
    }

    func testAPastedLinkFillsTheFieldsButTypingOneCharacterAtATimeDoesNot() {
        var f = ProxyForm()
        f.setAddress("socks5://alice:secret@proxy.example.net:1081")
        XCTAssertEqual(f.address, "proxy.example.net")
        XCTAssertEqual(f.password, "secret")
        XCTAssertEqual(f.port, "1081")

        var typed = ProxyForm()
        for c in "socks5://h" { typed.setAddress(typed.address + String(c)) }
        XCTAssertEqual(typed.address, "socks5://h", "a link typed by hand stays as typed, and gets the host error")
        typed.setAddress("10.0.0.2")
        XCTAssertEqual(typed.address, "10.0.0.2", "a host pasted over it is kept as it is")
    }

    func testTheKeychainNoteShowsBesideAPasswordThatWillBeKept() {
        var f = ProxyForm()
        f.password = "pw"
        XCTAssertNil(f.passwordNote, "without a username SOCKS5 sends no password")
        f.username = "bob"
        XCTAssertEqual(f.passwordNote, "Saved in Keychain when you add the server.")
        f.password = ""
        XCTAssertNil(f.passwordNote)
    }


    func testAProxyOnThisMacIsAddedInOneStepWithItsOwnName() {
        for host in ["127.0.0.1", "localhost", "::1", "[::1]"] {
            var f = ProxyForm()
            f.address = host
            XCTAssertTrue(f.onThisMac, host)
            XCTAssertFalse(f.remote, host)
            let p = f.add()
            XCTAssertEqual(p?.profile.name, "Proxy on this Mac", host)
            XCTAssertEqual(p?.profile.port, 1080)
            XCTAssertEqual(p?.profile.valid, true)
        }
    }

    func testTheNameDefaultsToTheHostAndATypedOneWins() {
        var f = ProxyForm()
        f.address = " proxy.example.net "
        XCTAssertEqual(f.displayName, "proxy.example.net")
        f.name = "  Office  "
        XCTAssertEqual(f.displayName, "Office")
        f.name = String(repeating: "n", count: 60)
        XCTAssertEqual(f.displayName.count, 40)
    }

    func testTheStatusLineAndTheListCaption() {
        var f = ProxyForm()
        XCTAssertEqual(f.status, "SOCKS5 · Port 1080")
        f.address = "proxy.example.net"
        XCTAssertEqual(f.status, "SOCKS5 · proxy.example.net · Port 1080")
        f.address = "127.0.0.1"; f.port = "9050"
        XCTAssertEqual(f.status, "SOCKS5 · This Mac · Port 9050")
        f.port = "x"
        XCTAssertEqual(f.status, "SOCKS5 · This Mac")
        XCTAssertEqual(Socks5Profile(name: "a", host: "proxy.example.net", port: 1080, item: "").caption, "SOCKS5 · proxy.example.net:1080")
        XCTAssertEqual(Socks5Profile(name: "a", host: "::1", port: 1080, item: "").caption, "SOCKS5 · [::1]:1080")
    }

    func testTheSavedProfileIsOneTheCompilerAcceptsWithAKeychainItemOfItsOwn() {
        var f = ProxyForm()
        XCTAssertTrue(f.fill(link: "socks5://u:pw@10.1.2.3:1080"))
        XCTAssertNil(f.add())
        guard let a = f.add(), let b = f.add() else { return XCTFail("Add Anyway saves") }
        XCTAssertTrue(a.profile.valid)
        XCTAssertNotEqual(a.profile.item, b.profile.item)
        XCTAssertNotNil(UUID(uuidString: a.profile.item))
        XCTAssertEqual(a.secrets, ["socks5://u:pw@10.1.2.3:1080", "pw"])
        XCTAssertNil(a.profile.proxyApp)
    }

    func testALinkPastedAtTheCursorNeverShowsItsPassword() {
        for (before, after) in [("proxy.example.net", ""), ("", "proxy.example.net"), ("proxy.", "example.net"), ("server", "")] {
            var f = ProxyForm()
            f.address = before + after
            f.setAddress(before + "socks5://alice:s3cret@10.0.0.9:1081" + after)
            XCTAssertFalse(f.address.contains("s3cret"), f.address)
            XCTAssertFalse(f.status.contains("s3cret"), f.status)
            XCTAssertEqual(f.password, "s3cret", before + "|" + after)
            XCTAssertEqual(f.port, "1081")
        }
    }

    func testTheLoginIsReadOnlyFromTheAuthority() {
        var f = ProxyForm()
        XCTAssertTrue(f.fill(link: "socks5://proxy.example.net:1080/path@evil.example"))
        XCTAssertEqual(f.address, "proxy.example.net")
        XCTAssertEqual(f.username, "")
        XCTAssertTrue(f.fill(link: "socks5://u:p@proxy.example.net:1080?x=a@b#c@d"))
        XCTAssertEqual(f.address, "proxy.example.net")
        XCTAssertEqual(f.password, "p")

        var two = ProxyForm()
        two.username = "kept"
        XCTAssertFalse(two.fill(link: "socks5://u:p@ss@proxy.example.net:1080"), "an unencoded @ in the login is refused")
        XCTAssertEqual(two.username, "kept")
        two.setAddress("socks5://u:p@ss@proxy.example.net:1080")
        XCTAssertFalse(two.address.contains("p@ss"), "a refused link isn't left showing in Address")
    }

    func testOnlyALoopbackAddressOrLocalhostCountsAsThisMac() {
        for host in ["127.0.0.1", "127.8.9.10", "localhost", "LOCALHOST", "::1", "[::1]", "0:0:0:0:0:0:0:1"] {
            var f = ProxyForm(); f.address = host
            XCTAssertTrue(f.onThisMac, host); XCTAssertFalse(f.remote, host)
        }
        for host in ["proxy.localhost", "localhost.example.net", "128.0.0.1", "::2", "::ffff:127.0.0.1", "mac.local"] {
            var f = ProxyForm(); f.address = host
            XCTAssertFalse(f.onThisMac, host); XCTAssertTrue(f.remote, host)
            XCTAssertNotEqual(f.displayName, "Proxy on this Mac", host)
        }
    }
}
