import XCTest

final class InstallPlaceTests: XCTestCase {
    func testOnlyApplicationsCountsAsInstalled() {
        for ok in ["/Applications/unbraid.app", "/Applications/Utilities/unbraid.app", "/Applications/../Applications/unbraid.app"] {
            XCTAssertTrue(InstallPlace.isInApplications(ok), ok)
        }
        for bad in ["/Volumes/unbraid 1.0.0/unbraid.app", "/Users/x/Downloads/unbraid.app", "/Users/x/Applications/unbraid.app",
                    "/private/var/folders/ab/cd/T/AppTranslocation/7C0E/d/unbraid.app", "/Applications", "/Applications/../Users/x/unbraid.app",
                    "/ApplicationsOld/unbraid.app", ""] {
            XCTAssertFalse(InstallPlace.isInApplications(bad), bad)
        }
    }

    func testOneOfTwoCopiesStartedTogetherYields() {
        let a = InstallPlace.Copy(path: "/Applications/unbraid.app", launched: Date(timeIntervalSince1970: 100), pid: 20)
        let b = InstallPlace.Copy(path: "/Applications/unbraid.app", launched: Date(timeIntervalSince1970: 100), pid: 30)
        XCTAssertTrue(InstallPlace.outranks(a, b))
        XCTAssertFalse(InstallPlace.outranks(b, a))
        XCTAssertFalse(InstallPlace.outranks(a, a))
        // Started earlier wins, whatever the process numbers.
        let early = InstallPlace.Copy(path: "/Applications/unbraid.app", launched: Date(timeIntervalSince1970: 50), pid: 99)
        XCTAssertTrue(InstallPlace.outranks(early, a))
        XCTAssertFalse(InstallPlace.outranks(a, early))
    }

    func testACopyInApplicationsBeatsOneRunFromAnotherPlace() {
        let image = InstallPlace.Copy(path: "/Volumes/unbraid/unbraid.app", launched: Date(timeIntervalSince1970: 10), pid: 5)
        let installed = InstallPlace.Copy(path: "/Applications/unbraid.app", launched: Date(timeIntervalSince1970: 200), pid: 50)
        // The copy on the disk image started first, but the one in Applications is the one that can work.
        XCTAssertTrue(InstallPlace.outranks(installed, image))
        XCTAssertFalse(InstallPlace.outranks(image, installed))
    }

    func testAMissingStartDateFallsBackToTheProcessNumber() {
        let dated = InstallPlace.Copy(path: "/Applications/unbraid.app", launched: Date(timeIntervalSince1970: 100), pid: 40)
        let low = InstallPlace.Copy(path: "/Applications/unbraid.app", launched: nil, pid: 10)
        let high = InstallPlace.Copy(path: "/Applications/unbraid.app", launched: nil, pid: 90)
        // Exactly one of any two yields, in either order, when a date is missing on one side or both.
        for (a, b) in [(dated, low), (dated, high), (low, high)] {
            XCTAssertNotEqual(InstallPlace.outranks(a, b), InstallPlace.outranks(b, a))
        }
        XCTAssertTrue(InstallPlace.outranks(low, high))
        // A copy with no known start date comes after every dated one.
        XCTAssertTrue(InstallPlace.outranks(dated, low))
        XCTAssertTrue(InstallPlace.outranks(dated, high))
    }

    func testTheOrderOfThreeCopiesIsConsistentWhenADateIsMissing() {
        let a = InstallPlace.Copy(path: "/Applications/unbraid.app", launched: Date(timeIntervalSince1970: 100), pid: 90)
        let b = InstallPlace.Copy(path: "/Applications/unbraid.app", launched: Date(timeIntervalSince1970: 200), pid: 10)
        let c = InstallPlace.Copy(path: "/Applications/unbraid.app", launched: nil, pid: 40)
        let d = InstallPlace.Copy(path: "/Applications/unbraid.app", launched: nil, pid: 20)
        let all = [a, b, c, d]
        // Exactly one copy outranks all the others, and sorting by it gives the same order from any start.
        XCTAssertEqual(all.filter { me in all.allSatisfy { $0 == me || InstallPlace.outranks(me, $0) } }, [a])
        let order = all.sorted { InstallPlace.outranks($0, $1) }
        XCTAssertEqual(order, [a, b, d, c])
        XCTAssertEqual(all.reversed().sorted { InstallPlace.outranks($0, $1) }, order)
    }
}
