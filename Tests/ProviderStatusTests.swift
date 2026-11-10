import XCTest

final class ProviderStatusTests: XCTestCase {
    func testFailedRefreshShowsOlderListEvenWhileConnected() {
        let fresh = ProviderStatus.listFresh(true, failed: true)
        let status = ProviderStatus.reduce(name: "IVPN", used: true, refused: false, settingUp: false,
                                           blocked: false, listFresh: fresh, connected: true)
        XCTAssertEqual(status.text, "Using an older server list")
        XCTAssertTrue(ProviderStatus.listFresh(true, failed: false))
    }

    func testPriority() {
        func status(_ used: Bool = true, _ refused: Bool = false, _ setting: Bool = false, _ blocked: Bool = false,
                    _ fresh: Bool = true, _ connected: Bool = false, _ dropping: String? = nil, _ old: String? = nil) -> ProviderStatus {
            ProviderStatus.reduce(name: "IVPN", used: used, refused: refused, settingUp: setting, blocked: blocked,
                                  listFresh: fresh, connected: connected, dropping: dropping, oldList: old)
        }
        XCTAssertEqual(status(false, true, true, true, false).tone, .bad)
        XCTAssertEqual(status(false).text, "Not used")
        XCTAssertEqual(status(true, false, true, true).text, "Setting up your key")
        XCTAssertEqual(status(true, false, false, true, false, true, "drop").text, "Can't reach its servers right now")
        XCTAssertEqual(status(true, false, false, false, false, true, "drop", "6 Aug 2026").text, "drop")
        XCTAssertEqual(status(true, false, false, false, true, true, nil, "6 Aug 2026").text, "Its server list is from 6 Aug 2026 and may be out of date")
        XCTAssertEqual(status(true, false, false, false, false, true).text, "Using an older server list")
        XCTAssertEqual(status(true, false, false, false, true, true).text, "Connected")
        XCTAssertEqual(status().text, "Server list up to date")
    }
    func testRemovedDeviceTakesPriority() {
        let status = ProviderStatus.reduce(name: "IVPN", used: true, refused: false, settingUp: true, blocked: true,
                                           listFresh: true, connected: false, removed: true)
        XCTAssertEqual(status.tone, .bad)
        XCTAssertEqual(status.text, "IVPN no longer has this Mac. Sign in again.")
    }
    func testAgeAndKeySetupBoundaries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(ProviderStatus.oldList(1_800_000_000 - 60 * 86_400, now: now))
        XCTAssertNotNil(ProviderStatus.oldList(1_800_000_000 - 60 * 86_400 - 1, now: now))
        XCTAssertTrue(ProviderStatus.settingUp(signedIn: now.addingTimeInterval(-89), seconds: 90, now: now))
        XCTAssertFalse(ProviderStatus.settingUp(signedIn: now.addingTimeInterval(-90), seconds: 90, now: now))
        XCTAssertFalse(ProviderStatus.settingUp(signedIn: nil, seconds: 90, now: now))
    }
    func testPublicationDate() {
        XCTAssertEqual(Catalog.timestamp(Data(#"{"timestamp":1785990858,"servers":[]}"#.utf8)), 1785990858)
        XCTAssertNil(Catalog.timestamp(Data(#"{"servers":[]}"#.utf8)))
        XCTAssertEqual(ProviderStatus.publishedOn(1785990858), "6 Aug 2026")
        XCTAssertEqual(ProviderStatus.publishedOn(.max), "an unknown date")
    }
    func testKeySetupEndsAfterNinetySeconds() {
        let created = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(ProviderStatus.keySettingUp(created: created, now: created.addingTimeInterval(89), seconds: 90))
        XCTAssertFalse(ProviderStatus.keySettingUp(created: created, now: created.addingTimeInterval(90), seconds: 90))
        XCTAssertFalse(ProviderStatus.keySettingUp(created: nil, now: created, seconds: 90))
        XCTAssertFalse(ProviderStatus.keySettingUp(created: created, now: created.addingTimeInterval(-1), seconds: 90))
    }

}

extension ProviderStatusTests {
    func testCatalogueDateFollowsAcceptedEntries() throws {
        let body = Data(#"{"timestamp":1785990858,"servers":[{"vpn":"openvpn","country":"Netherlands","hostname":"example.com","ips":["1.1.1.1"],"udp":true}]}"#.utf8)
        let rows = try Catalog.parse(body, vpn: "openvpn")
        XCTAssertEqual(rows.first?.published, 1785990858)
        let snapshot = Catalog.Pinned(rows, vpn: "openvpn")
        var live = rows
        live[0].published = 1786000000
        XCTAssertEqual(snapshot.refresh(live, { $0 }).first?.published, 1786000000)
        XCTAssertEqual(snapshot.refresh(nil, { $0 }).first?.published, 1785990858)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rows[0])) as? [String: Any])
        old.removeValue(forKey: "published")
        XCTAssertNil(try JSONDecoder().decode(Catalog.Entry.self, from: JSONSerialization.data(withJSONObject: old)).published)
    }
}
