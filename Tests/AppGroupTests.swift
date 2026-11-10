import Security
import XCTest

/// The signing team and bundle-ID prefix come from the build's Info.plist and go into code requirements.
final class AppGroupTests: XCTestCase {
    func testSigningIsReadFromTheInfoPlist() {
        let s = AppGroup.validSigning(["UnbraidTeam": "ABCDE12345", "UnbraidBundlePrefix": "com.example.unbraid"])
        XCTAssertEqual(s?.team, "ABCDE12345")
        XCTAssertEqual(s?.prefix, "com.example.unbraid")
    }

    func testOnlyATeamIdAndAReverseDnsPrefixAreAccepted() {
        let good = ["UnbraidTeam": "ABCDE12345", "UnbraidBundlePrefix": "app.unbraid"]
        XCTAssertNil(AppGroup.validSigning(nil))
        XCTAssertNil(AppGroup.validSigning([:]))
        for team in ["", "abcde12345", "ABCDE1234", "ABCDE123456", "$(DEVELOPMENT_TEAM)", "ABCDE1234\"", "ABCDE 1234"] {
            XCTAssertNil(AppGroup.validSigning(good.merging(["UnbraidTeam": team]) { $1 }), team)
        }
        for prefix in ["", "unbraid", "$(BUNDLE_PREFIX)", "app.unbraid\" or true", "app..unbraid", ".app.unbraid", "app.unbraid.",
                       "app.un braid", "app.unbraid\n"] {
            XCTAssertNil(AppGroup.validSigning(good.merging(["UnbraidBundlePrefix": prefix]) { $1 }), prefix)
        }
        XCTAssertNil(AppGroup.validSigning(["UnbraidTeam": 12345, "UnbraidBundlePrefix": "app.unbraid"]))
    }

    /// The tests' runner has no such keys: they get the maintainer's, which every derived name follows.
    func testDerivedNamesFollowTheSigning() {
        XCTAssertEqual(AppGroup.team, "28PLDKCR52")
        XCTAssertEqual(AppGroup.id, "28PLDKCR52.app.unbraid")
        XCTAssertEqual(AppGroup.tunnelBundle, "app.unbraid.tunnel")
        XCTAssertTrue(AppGroup.machService.hasPrefix("28PLDKCR52.app.unbraid.tunnel."))
        XCTAssertTrue(AppGroup.appRequirement.hasPrefix("identifier \"app.unbraid\" and anchor apple generic"))
        XCTAssertTrue(AppGroup.appRequirement.hasSuffix("certificate leaf[subject.OU] = \"28PLDKCR52\""))
        XCTAssertTrue(AppGroup.tunnelRequirement.hasPrefix("identifier \"app.unbraid.tunnel\" and anchor apple generic"))
    }

    /// Another team's build trusts only code that team signed, under its own bundle IDs.
    func testRequirementsNameTheBuildsTeamAndIdentifier() {
        let r = AppGroup.requirement("com.example.unbraid.tunnel", team: "ABCDE12345")
        XCTAssertTrue(r.hasPrefix("identifier \"com.example.unbraid.tunnel\" and anchor apple generic and "))
        XCTAssertTrue(r.hasSuffix(" and certificate leaf[subject.OU] = \"ABCDE12345\""))
        XCTAssertFalse(r.contains("28PLDKCR52"))
        var code: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(r as CFString, [], &code), errSecSuccess)
    }
}
