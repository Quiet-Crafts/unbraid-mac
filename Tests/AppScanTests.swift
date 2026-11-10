import XCTest

final class AppScanTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "appscan-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A test may have locked a folder.
        if let e = FileManager.default.enumerator(atPath: root) {
            for case let p as String in e { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/" + p) }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    private func app(_ path: String, id: String?, name: String? = nil) throws {
        let contents = root + path + "/Contents"
        try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
        guard let id else { return }
        var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"]
        if let name { info["CFBundleName"] = name }
        XCTAssertTrue(NSDictionary(dictionary: info).write(toFile: contents + "/Info.plist", atomically: true))
    }

    func testAppsCopiesAndVendorFolders() throws {
        try app("/A/Foo.app", id: "com.foo", name: "Foo")
        try app("/A/Vendor/Bar.app", id: "com.bar")
        try app("/B/Foo Beta.app", id: "com.foo")
        try app("/S/Sys.app", id: "com.sys")
        try app("/S/Group/Inner.app", id: "com.inner")
        FileManager.default.createFile(atPath: root + "/A/.DS_Store", contents: Data())
        try FileManager.default.createDirectory(atPath: root + "/A/Empty", withIntermediateDirectories: true)
        try app("/A/Self.app", id: "app.self")
        let r = AppScan.scan([(root + "/A", false), (root + "/B", false), (root + "/S", true), (root + "/None", false)], skip: "app.self")
        XCTAssertEqual(r.apps.map(\.id).sorted(), ["com.bar", "com.foo", "com.inner", "com.sys"])
        XCTAssertEqual(r.apps.first { $0.id == "com.foo" }?.name, "Foo")
        XCTAssertEqual(r.apps.first { $0.id == "com.foo" }?.path, root + "/A/Foo.app")
        XCTAssertEqual(r.apps.first { $0.id == "com.sys" }?.system, true)
        XCTAssertEqual(r.copies, ["com.foo": [root + "/B/Foo Beta.app"]])
        // Vendor folders of the user's folders only; a missing root is no failure.
        XCTAssertEqual(r.vendors, [root + "/A/Vendor"])
        XCTAssertTrue(r.complete)
    }

    func testAFolderThatCantBeReadMakesTheScanIncomplete() throws {
        try app("/A/Foo.app", id: "com.foo")
        try app("/A/Vendor/Bar.app", id: "com.bar")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/A/Vendor")
        let r = AppScan.scan([(root + "/A", false)], skip: nil)
        XCTAssertFalse(r.complete)
        XCTAssertEqual(r.failed, [root + "/A/Vendor"])
        XCTAssertEqual(r.apps.map(\.id), ["com.foo"])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/A")
        XCTAssertEqual(AppScan.scan([(root + "/A", false), (root + "/None", false)], skip: nil).failed, [root + "/A"])
    }

    func testABundleWithoutAnIdIsSkipped() throws {
        try app("/A/Half.app", id: nil)
        let r = AppScan.scan([(root + "/A", false)], skip: nil)
        XCTAssertEqual(r.apps, [])
        // Noted: the app a routed one went missing as might be this one.
        XCTAssertEqual(r.unreadable, [root + "/A/Half.app"])
        XCTAssertTrue(r.complete)
        XCTAssertNil(AppScan.id(at: root + "/A/Half.app"))
    }

    func testTheIdIsReadAsTheBundleIsNowNotAsFirstSeen() throws {
        try app("/A/Foo.app", id: "com.foo")
        XCTAssertEqual(AppScan.bundle(URL(fileURLWithPath: root + "/A/Foo.app"), system: false)?.id, "com.foo")
        // Another app takes the same path: Bundle caches the first, the id read here doesn't.
        try FileManager.default.removeItem(atPath: root + "/A/Foo.app")
        try app("/A/Foo.app", id: "com.other")
        XCTAssertEqual(AppScan.id(at: root + "/A/Foo.app"), "com.other")
        XCTAssertNil(AppScan.id(at: root + "/A/Nothing.app"))
        // And so does a scan; while the new one has no Info.plist yet (being installed), it is unreadable, never the old.
        XCTAssertEqual(AppScan.scan([(root + "/A", false)], skip: nil).apps.map(\.id), ["com.other"])
        try FileManager.default.removeItem(atPath: root + "/A/Foo.app/Contents/Info.plist")
        let r = AppScan.scan([(root + "/A", false)], skip: nil)
        XCTAssertEqual(r.apps, [])
        XCTAssertEqual(r.unreadable, [root + "/A/Foo.app"])
    }
}
