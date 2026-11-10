import XCTest

final class AppPathsTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        // The real path, as the kernel reports processes: /var/folders is /private/var/folders.
        root = AppPaths.real(NSTemporaryDirectory()) + "/apppaths-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    private func file(_ path: String) throws {
        let full = root + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: full, contents: Data())
    }

    private func link(_ path: String, to target: String) throws {
        let full = root + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: full, withDestinationPath: target)
    }

    // MARK: Bundles

    func testOnlyCopiesSeenMatchNotOtherAppsOfTheSameName() {
        let p = AppPaths.bundle(["/Applications/Foo Bar.app", "/Volumes/Foo Bar 2.1/Foo Bar.app"])
        XCTAssertTrue(AppPaths.matches(p, "/Applications/Foo Bar.app/Contents/MacOS/Foo Bar"))
        XCTAssertTrue(AppPaths.matches(p, "/Volumes/Foo Bar 2.1/Foo Bar.app/Contents/MacOS/Foo Bar"))
        XCTAssertFalse(AppPaths.matches(p, "/Volumes/Other/Foo Bar.app/Contents/MacOS/Foo Bar"))
        XCTAssertFalse(AppPaths.matches(p, "/private/var/folders/x7/k2/T/AppTranslocation/0B6E1C2A/d/Foo Bar.app/Contents/MacOS/Foo Bar"))
        XCTAssertFalse(AppPaths.matches(p, "/Applications/Foo Bar.app"))
    }

    func testEveryKnownCopyOfABundleMatches() throws {
        try file("/Elsewhere/Foo.app/Contents/MacOS/Foo")
        try link("/Linked/Foo.app", to: root + "/Elsewhere/Foo.app")
        let p = AppPaths.bundle(["/Applications/Foo.app", root + "/Linked/Foo.app"])
        XCTAssertTrue(AppPaths.matches(p, "/Applications/Foo.app/Contents/MacOS/Foo"))
        XCTAssertTrue(AppPaths.matches(p, root + "/Linked/Foo.app/Contents/MacOS/Foo"))
        XCTAssertTrue(AppPaths.matches(p, root + "/Elsewhere/Foo.app/Contents/MacOS/Foo"))
        XCTAssertFalse(AppPaths.matches(p, "/Applications/Foo.app2/x"))
        XCTAssertEqual(p, p.sorted())
        XCTAssertEqual(AppPaths.bundle([]), [])
    }

    func testBlockedTranslocationMatchesOnlyTheEscapedBundleName() {
        let p = AppPaths.blockedTranslocations(["/Applications/Foo [1].app"])
        XCTAssertTrue(AppPaths.matches(p, "/private/var/folders/a/T/AppTranslocation/uuid/d/Foo [1].app/Contents/MacOS/Foo"))
        XCTAssertFalse(AppPaths.matches(p, "/private/var/folders/a/T/AppTranslocation/uuid/d/Foo 1.app/Contents/MacOS/Foo"))
        XCTAssertFalse(AppPaths.matches(p, "/private/var/folders/a/T/AppTranslocation/uuid/other/Foo [1].app/Contents/MacOS/Foo"))
        XCTAssertFalse(AppPaths.matches(p, "/Applications/Foo [1].app/Contents/MacOS/Foo"))
        XCTAssertTrue(AppPaths.blockedTranslocations(["/tmp/tool"]).isEmpty)
    }

    // MARK: Missing apps

    func testAMissingAppKeepsItsRememberedPlacesUnlessAnotherAppIsThere() throws {
        try app("/A/Foo.app", id: "com.foo")
        try app("/A/Bar.app", id: "com.bar")
        try FileManager.default.createDirectory(atPath: root + "/A/Half.app/Contents/Frameworks", withIntermediateDirectories: true)
        let places = [root + "/A/Foo.app", root + "/A/Gone.app", root + "/A/Half.app", root + "/A/Bar.app", ""]
        // Itself, gone, or being copied in (no Info.plist yet): kept. Another app there, or nothing remembered: not.
        XCTAssertEqual(AppPaths.claims("com.foo", places), [root + "/A/Foo.app", root + "/A/Gone.app", root + "/A/Half.app"])
        // So a blocked app reinstalled where it was is matched from its first start.
        let p = AppPaths.bundle(AppPaths.claims("com.foo", [root + "/A/Half.app"]))
        XCTAssertTrue(AppPaths.matches(p, root + "/A/Half.app/Contents/MacOS/Foo"))
        XCTAssertTrue(AppPaths.matches(p, root + "/A/Half.app/Contents/Library/LaunchAgents/helper"))
        XCTAssertEqual(AppPaths.claims("com.foo", ["/x"], holder: { _ in "com.other" }), [])
        XCTAssertEqual(AppPaths.claims("com.foo", ["/x"], holder: { _ in nil }), ["/x"])
    }

    func testAPlaceSeenTakenStaysTakenWhileTheOtherAppCantBeRead() {
        // Foo runs from P; Bar replaces it there; then Bar is updated (P unreadable a while): Foo's running copy at P
        // doesn't count again, or Bar would follow Foo's route. Read as Foo again, P is Foo's.
        var taken = Set<String>()
        var holder: String? = "com.bar"
        XCTAssertEqual(AppPaths.claims("com.foo", ["/P.app"], taken: &taken, holder: { _ in holder }), [])
        holder = nil
        XCTAssertEqual(AppPaths.claims("com.foo", ["/P.app"], taken: &taken, holder: { _ in holder }), [])
        XCTAssertEqual(AppPaths.claims("com.foo", ["/Q.app"], taken: &taken, holder: { _ in holder }), ["/Q.app"])
        holder = "com.foo"
        XCTAssertEqual(AppPaths.claims("com.foo", ["/P.app"], taken: &taken, holder: { _ in holder }), ["/P.app"])
        holder = nil
        XCTAssertEqual(AppPaths.claims("com.foo", ["/P.app"], taken: &taken, holder: { _ in holder }), ["/P.app"])
        XCTAssertEqual(taken, [])
    }

    private func app(_ path: String, id: String) throws {
        let contents = root + path + "/Contents"
        try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
        XCTAssertTrue(NSDictionary(dictionary: ["CFBundleIdentifier": id]).write(toFile: contents + "/Info.plist", atomically: true))
    }

    func testAnAppWhoseProgramLinksOutOfItsBundleIsNotMatchedAsThatFile() throws {
        // The engine sees the file the link leads to, which other apps may run too (a shared runtime): a bundle's patterns
        // stay inside it. Such an app's starts rescan once at most (see `UnmatchedStarts`).
        try file("/runtime/bin/launcher")
        try FileManager.default.createDirectory(atPath: root + "/A/Foo.app/Contents/MacOS", withIntermediateDirectories: true)
        XCTAssertTrue(NSDictionary(dictionary: ["CFBundleIdentifier": "com.foo", "CFBundleExecutable": "Foo"])
            .write(toFile: root + "/A/Foo.app/Contents/Info.plist", atomically: true))
        try link("/A/Foo.app/Contents/MacOS/Foo", to: root + "/runtime/bin/launcher")
        let p = AppPaths.bundle([root + "/A/Foo.app"])
        XCTAssertFalse(AppPaths.matches(p, root + "/runtime/bin/launcher"))
        XCTAssertFalse(AppPaths.matches(p, AppPaths.real(root + "/runtime/bin/launcher")))
        XCTAssertTrue(AppPaths.matches(p, root + "/A/Foo.app/Contents/MacOS/Foo"))
        XCTAssertTrue(p.allSatisfy { $0.hasSuffix("/") })
    }

    // MARK: Tools

    func testHomebrewToolMatchesAnyVersionOfItsFormula() throws {
        try file("/brew/Cellar/node/26.7.0/bin/node")
        try link("/brew/bin/node", to: "../Cellar/node/26.7.0/bin/node")
        let p = AppPaths.tool(root + "/brew/bin/node", developerDirs: [])
        XCTAssertTrue(AppPaths.matches(p, root + "/brew/bin/node"))
        XCTAssertTrue(AppPaths.matches(p, root + "/brew/Cellar/node/26.7.0/bin/node"))
        // After `brew upgrade`, before any rescan.
        XCTAssertTrue(AppPaths.matches(p, root + "/brew/Cellar/node/26.8.1_1/bin/node"))
        // The literal path stays beside the wildcard, for the compiler's nesting order.
        XCTAssertTrue(p.contains(Compiler.pattern(forPath: root + "/brew/Cellar/node/26.7.0/bin/node")))
        XCTAssertFalse(AppPaths.matches(p, root + "/brew/Cellar/node/26.8.1/bin/npx"))
        XCTAssertFalse(AppPaths.matches(p, root + "/brew/Cellar/nodenv/1.0/bin/node"))
        XCTAssertFalse(AppPaths.matches(p, root + "/brew/Cellar/node/26.8.1/sub/bin/node"))
    }

    func testFrameworkPythonAlsoMatchesThePythonAppItReExecs() throws {
        let versions = "/brew/Cellar/python@3.14/3.14.5/Frameworks/Python.framework/Versions/3.14"
        try file(versions + "/bin/python3.14")
        try file(versions + "/Resources/Python.app/Contents/MacOS/Python")
        try link("/brew/bin/python3", to: "../Cellar/python@3.14/3.14.5/Frameworks/Python.framework/Versions/3.14/bin/python3.14")
        let p = AppPaths.tool(root + "/brew/bin/python3", developerDirs: [])
        XCTAssertTrue(AppPaths.matches(p, root + versions + "/bin/python3.14"))
        XCTAssertTrue(AppPaths.matches(p, root + versions + "/Resources/Python.app/Contents/MacOS/Python"))
        // The interpreter itself matches any version of the formula; its Python.app (a folder pattern, which nested
        // routes are ordered against) stays the one resolved until the relink re-resolves it.
        XCTAssertTrue(AppPaths.matches(p, root + "/brew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/bin/python3.14"))
        XCTAssertFalse(AppPaths.matches(p, root + "/brew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python"))
        XCTAssertFalse(p.contains { $0.hasSuffix("/") && $0.contains("[^/]") })
        // Not every Python: another formula's stays on its own route.
        XCTAssertFalse(AppPaths.matches(p, root + "/brew/Cellar/python@3.11/3.11.15/Frameworks/Python.framework/Versions/3.11/Resources/Python.app/Contents/MacOS/Python"))
    }

    func testXcodeShimsMatchTheActiveDeveloperFoldersTools() throws {
        let dev = root + "/Xcode.app/Contents/Developer"
        try file("/usr/bin/git")
        try file("/usr/bin/clang")
        try file("/usr/bin/curl")
        try file("/Xcode.app/Contents/Developer/usr/bin/git")
        try file("/Xcode.app/Contents/Developer/usr/libexec/git-core/git-remote-https")
        try file("/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang")
        let git = AppPaths.tool(root + "/usr/bin/git", developerDirs: [dev], shims: root + "/usr/bin")
        XCTAssertTrue(AppPaths.matches(git, root + "/usr/bin/git"))
        XCTAssertTrue(AppPaths.matches(git, dev + "/usr/bin/git"))
        XCTAssertTrue(AppPaths.matches(git, dev + "/usr/libexec/git-core/git-remote-https"))
        XCTAssertFalse(AppPaths.matches(git, dev + "/usr/bin/gitk"))
        XCTAssertFalse(AppPaths.matches(git, dev + "/usr/libexec/other/x"))
        let clang = AppPaths.tool(root + "/usr/bin/clang", developerDirs: [dev], shims: root + "/usr/bin")
        XCTAssertTrue(AppPaths.matches(clang, dev + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"))
        // Not a shim (nothing of that name in the developer folder): the file alone.
        XCTAssertEqual(AppPaths.tool(root + "/usr/bin/curl", developerDirs: [dev], shims: root + "/usr/bin"),
                       [Compiler.pattern(forPath: root + "/usr/bin/curl")])
        // Outside the shim folder nothing is looked up in the developer folder.
        try file("/other/git")
        XCTAssertFalse(AppPaths.matches(AppPaths.tool(root + "/other/git", developerDirs: [dev], shims: root + "/usr/bin"), dev + "/usr/bin/git"))
        // No developer folder selected: the shim alone.
        XCTAssertEqual(AppPaths.tool(root + "/usr/bin/git", developerDirs: [], shims: root + "/usr/bin"), [Compiler.pattern(forPath: root + "/usr/bin/git")])
    }

    func testXcodeShimsMatchTheToolInEveryDeveloperFolderKnown() throws {
        // `xcode-select -s` (or DEVELOPER_DIR) picks another Xcode without any rescan: a blocked git stays blocked.
        let xcode = root + "/Xcode.app/Contents/Developer", beta = root + "/Xcode-beta.app/Contents/Developer"
        let clt = root + "/CommandLineTools", none = root + "/NotInstalled"
        try file("/usr/bin/git")
        for d in ["/Xcode.app/Contents/Developer", "/Xcode-beta.app/Contents/Developer", "/CommandLineTools"] {
            try file(d + "/usr/bin/git")
            try file(d + "/usr/libexec/git-core/git-remote-https")
        }
        let git = AppPaths.tool(root + "/usr/bin/git", developerDirs: [beta, xcode, clt, none], shims: root + "/usr/bin")
        for d in [xcode, beta, clt] {
            XCTAssertTrue(AppPaths.matches(git, d + "/usr/bin/git"), d)
            XCTAssertTrue(AppPaths.matches(git, d + "/usr/libexec/git-core/git-remote-https"), d)
        }
        XCTAssertFalse(AppPaths.matches(git, none + "/usr/bin/git"))
        XCTAssertFalse(AppPaths.matches(git, root + "/Xcode.app/Contents/Developer/usr/bin/gitk"))
        // The same set whatever the order, and where each may lead is listed for watching, there or not.
        XCTAssertEqual(git, AppPaths.tool(root + "/usr/bin/git", developerDirs: [none, clt, xcode, beta], shims: root + "/usr/bin"))
        XCTAssertEqual(AppPaths.shimTargets("/usr/bin/git", [xcode, none]),
                       [xcode + "/usr/bin/git", xcode + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/git",
                        none + "/usr/bin/git", none + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/git"])
    }

    // MARK: Remembered places

    func testAnotherAppStartingAtARememberedPlaceIsFoundByAnySpellingOfIt() throws {
        try file("/A/Foo.app/Contents/Info.plist")
        try link("/Linked/Foo.app", to: root + "/A/Foo.app")
        let places = AppPaths.Places(["com.foo": [root + "/Linked/Foo.app", ""], "com.bar": [root + "/B/Bar.app"]], ignoresCase: { _ in true })
        // Started where Foo is remembered (through the link, or where it leads): Foo's place, not Bar's.
        let claim = AppPaths.Places.Claim(owner: "com.foo", path: root + "/Linked/Foo.app")
        XCTAssertEqual(places.others("com.other", at: root + "/Linked/Foo.app"), [claim])
        XCTAssertEqual(places.others("com.other", at: root + "/A/Foo.app"), [claim])
        XCTAssertEqual(places.others("com.other", at: (root + "/A/FOO.app")), [claim], "same file on a volume that ignores case")
        // Foo itself starting there takes nothing; nor does an app elsewhere, or of a similar name.
        XCTAssertEqual(places.others("com.foo", at: root + "/A/Foo.app"), [])
        XCTAssertEqual(places.others("com.other", at: root + "/A/Foo2.app"), [])
        XCTAssertEqual(places.others("com.other", at: root + "/B"), [])
        // On a case-sensitive volume, another case is another app.
        let exact = AppPaths.Places(["com.bar": [root + "/B/Bar.app"]], ignoresCase: { _ in false })
        XCTAssertEqual(exact.others("com.other", at: root + "/B/bar.app"), [])
        XCTAssertEqual(exact.others("com.other", at: root + "/B/Bar.app"), [AppPaths.Places.Claim(owner: "com.bar", path: root + "/B/Bar.app")])
        XCTAssertEqual(AppPaths.Places([:]).others("com.other", at: root + "/B/Bar.app"), [])
        // A place taken is dropped under any spelling: a link to it would bring it back through its resolution.
        let gone = AppPaths.Places(["com.foo": [root + "/A/Foo.app"]], ignoresCase: { _ in true })
        XCTAssertTrue(gone.contains(root + "/Linked/Foo.app"))
        XCTAssertTrue(gone.contains(root + "/a/foo.APP"))
        XCTAssertFalse(gone.contains(root + "/A/Foo2.app"))
        XCTAssertFalse(AppPaths.Places(["com.bar": [root + "/B/Bar.app"]], ignoresCase: { _ in false }).contains(root + "/b/bar.APP"))
    }

    /// The place an app is remembered at is gone, but a folder on the way is a link: a copy installed there again
    /// reports where the link leads, and is known there without another scan.
    func testARememberedPlaceThroughALinkedFolderIsKnownWhereTheLinkLeadsWhileNothingIsThere() throws {
        try FileManager.default.createDirectory(atPath: root + "/Ext/Apps", withIntermediateDirectories: true)
        try link("/Home/Applications", to: "../Ext/Apps")
        let place = root + "/Home/Applications/Sub/Foo.app"
        XCTAssertEqual(AppPaths.resolved(place), root + "/Ext/Apps/Sub/Foo.app")
        let places = AppPaths.Places(["com.foo": [place]], ignoresCase: { _ in false })
        let patterns = AppPaths.bundle([place])
        try file("/Ext/Apps/Sub/Foo.app/Contents/MacOS/Foo")
        let started = root + "/Ext/Apps/Sub/Foo.app"
        XCTAssertEqual(places.others("com.other", at: started), [AppPaths.Places.Claim(owner: "com.foo", path: place)])
        XCTAssertTrue(AppPaths.matches(patterns, started + "/Contents/MacOS/Foo"))
        XCTAssertTrue(AppPaths.matches(patterns, place + "/Contents/MacOS/Foo"))
        XCTAssertEqual(places.others("com.other", at: root + "/Ext/Apps/Sub/Foo2.app"), [])
        XCTAssertFalse(AppPaths.matches(patterns, root + "/Ext/Apps/Sub/Foo2.app/Contents/MacOS/Foo"))
        // Through a link to the root folder: no doubled slash. Nothing linked on the way: the path as it is.
        try link("/Top", to: "/")
        XCTAssertTrue(AppPaths.resolved(root + "/Top/no-such-folder-\(UUID().uuidString)/Foo.app").hasPrefix("/no-such-folder-"))
        XCTAssertEqual(AppPaths.resolved(root + "/Plain/Foo.app"), root + "/Plain/Foo.app")
        XCTAssertEqual(AppPaths.resolved("relative/Foo.app"), "relative/Foo.app")
        XCTAssertEqual(AppPaths.resolved(""), "")
    }

    func testAnAppStartedAtARememberedPlaceTakesItFromTheAppRememberedThere() {
        // A place read as another app is taken, persistently, and stays taken while it can't be read.
        var taken = Set<String>()
        XCTAssertEqual(AppPaths.claims("com.foo", ["/Applications/Foo.app"], taken: &taken) { _ in "com.store" }, [])
        XCTAssertEqual(taken, ["/Applications/Foo.app"])
        XCTAssertEqual(AppPaths.claims("com.foo", ["/Applications/Foo.app"], taken: &taken) { _ in nil }, [])
        // Foo installed there again and read as Foo: its own again.
        XCTAssertEqual(AppPaths.claims("com.foo", ["/Applications/Foo.app"], taken: &taken) { _ in "com.foo" }, ["/Applications/Foo.app"])
        XCTAssertEqual(taken, [])
    }

    func testShimToFrameworkPythonFollowsEveryStep() throws {
        // /usr/bin/python3 → Xcode's usr/bin/python3 → a link into Python3.framework → its Python.app.
        let dev = root + "/Xcode.app/Contents/Developer"
        let versions = "/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9"
        try file("/usr/bin/python3")
        try file(versions + "/bin/python3")
        try file(versions + "/Resources/Python.app/Contents/MacOS/Python")
        try link("/Xcode.app/Contents/Developer/usr/bin/python3", to: "../../Library/Frameworks/Python3.framework/Versions/3.9/bin/python3")
        let p = AppPaths.tool(root + "/usr/bin/python3", developerDirs: [dev], shims: root + "/usr/bin")
        XCTAssertTrue(AppPaths.matches(p, root + "/usr/bin/python3"))
        XCTAssertTrue(AppPaths.matches(p, root + versions + "/bin/python3"))
        XCTAssertTrue(AppPaths.matches(p, root + versions + "/Resources/Python.app/Contents/MacOS/Python"))
    }

    func testPythonHelperScriptsDontTakeTheInterpreter() throws {
        let versions = "/py/Python.framework/Versions/3.14"
        try file(versions + "/bin/python3-config")
        try file(versions + "/Resources/Python.app/Contents/MacOS/Python")
        let p = AppPaths.tool(root + versions + "/bin/python3-config", developerDirs: [])
        XCTAssertFalse(AppPaths.matches(p, root + versions + "/Resources/Python.app/Contents/MacOS/Python"))
    }

    func testACellarPathChosenAsSuchStaysThatVersion() throws {
        try file("/brew/Cellar/node/26.7.0/bin/node")
        let p = AppPaths.tool(root + "/brew/Cellar/node/26.7.0/bin/node", developerDirs: [])
        XCTAssertTrue(AppPaths.matches(p, root + "/brew/Cellar/node/26.7.0/bin/node"))
        XCTAssertFalse(AppPaths.matches(p, root + "/brew/Cellar/node/27.0.0/bin/node"))
    }

    func testRegexCharactersInNamesAreLiteral() throws {
        try file("/brew/Cellar/c++.tool/1.0/bin/c++")
        try link("/brew/bin/c++", to: "../Cellar/c++.tool/1.0/bin/c++")
        let p = AppPaths.tool(root + "/brew/bin/c++", developerDirs: [])
        XCTAssertTrue(AppPaths.matches(p, root + "/brew/Cellar/c++.tool/2.0/bin/c++"))
        XCTAssertFalse(AppPaths.matches(p, root + "/brew/Cellar/cc+xtool/2.0/bin/c++"))
        XCTAssertFalse(AppPaths.matches(p, root + "/brew/Cellar/c++.tool/2.0/bin/cc"))
    }

    func testTheFoldersALinkChainDependsOnAreWatched() throws {
        try file("/brew/Cellar/node/26.7.0/bin/node")
        try link("/brew/bin/node", to: "../Cellar/node/26.7.0/bin/node")
        try link("/brew/opt/node", to: "../Cellar/node/26.7.0")
        let bin = root + "/brew/Cellar/node/26.7.0/bin"
        XCTAssertEqual(AppPaths.linkFolders(root + "/brew/bin/node"), [bin, root + "/brew/bin"].sorted())
        XCTAssertEqual(AppPaths.linkFolders(root + "/brew/opt/node/bin/node"), [bin, root + "/brew/opt"].sorted())
        // A link whose destination runs through another link: both folders count.
        try link("/brew/bin/node2", to: "../opt/node/bin/node")
        XCTAssertEqual(AppPaths.linkFolders(root + "/brew/bin/node2"), [bin, root + "/brew/bin", root + "/brew/opt"].sorted())
        // A plain file: its own folder. A loop of links ends.
        XCTAssertEqual(AppPaths.linkFolders(bin + "/node"), [bin])
        try link("/loop/a", to: "b")
        try link("/loop/b", to: "a")
        XCTAssertEqual(AppPaths.linkFolders(root + "/loop/a"), [root + "/loop"])
    }

    // MARK: Older images of a relinked tool

    func testAToolsEarlierPatternsStayOnlyWhileAProcessRunsFromThem() throws {
        let old: Set = [Compiler.pattern(forPath: "/brew/Cellar/python@3.13/3.13.9/bin/python3.13"),
                        Compiler.pattern(forPath: "/brew/Cellar/python@3.13/3.13.9/Frameworks/Python.framework/Versions/3.13/Resources/Python.app")]
        let python = "/brew/Cellar/python@3.13/3.13.9/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python"
        // The old interpreter still runs a script: its rule stays. Nothing of it runs: none does.
        XCTAssertEqual(AppPaths.running(old, ["/sbin/launchd", python]), [old.first { $0.hasSuffix("/") }!])
        XCTAssertEqual(AppPaths.running(old, ["/sbin/launchd", "/brew/Cellar/python@3.14/3.14.5/bin/python3.14"]), [])
        XCTAssertEqual(AppPaths.running(old, []), [])
    }

    func testAProcessListWithOneUnreadableIsUnknown() {
        let paths: [pid_t: (String?, Int32)] = [1: ("/sbin/launchd", 0), 2: (nil, ESRCH), 3: ("/bin/zsh", 0), 5: (nil, ENOENT)]
        XCTAssertEqual(AppPaths.images([0, 1, 2, 3]) { paths[$0]! }, .init(images: ["/sbin/launchd", "/bin/zsh"]))
        // A process whose program file was deleted or replaced while it runs: counted, not named (the engine can't).
        XCTAssertEqual(AppPaths.images([1, 5, 3]) { paths[$0]! }, .init(images: ["/sbin/launchd", "/bin/zsh"], unnamed: 1))
        // Any other error (a process that can't be read): unknown, so every earlier pattern is kept.
        XCTAssertNil(AppPaths.images([1, 4]) { $0 == 4 ? (nil, EPERM) : paths[$0]! })
        XCTAssertEqual(AppPaths.images([]) { _ in (nil, EPERM) }, .init(images: []))
    }

    func testTheProcessesRunningCanBeRead() throws {
        // A live smoke check: a process this Mac won't let be read makes the list unknown, which is no failure here.
        guard let images = AppPaths.runningImages()?.images else { throw XCTSkip("a process couldn't be read") }
        XCTAssertTrue(images.contains("/sbin/launchd"))
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        XCTAssertGreaterThan(proc_pidpath(getpid(), &buf, UInt32(buf.count)), 0)
        XCTAssertTrue(images.contains(buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }))
    }

    // MARK: Tools leading to one program

    func testToolsLeadingToOneProgramOnDifferentRoutesAreFlagged() throws {
        let versions = "/brew/Cellar/python@3.14/3.14.5/Frameworks/Python.framework/Versions/3.14"
        try file(versions + "/bin/python3.14")
        try file(versions + "/Resources/Python.app/Contents/MacOS/Python")
        try link("/brew/bin/python3", to: "../Cellar/python@3.14/3.14.5/Frameworks/Python.framework/Versions/3.14/bin/python3.14")
        try link("/brew/bin/python3.14", to: "../Cellar/python@3.14/3.14.5/Frameworks/Python.framework/Versions/3.14/bin/python3.14")
        try file("/brew/Cellar/git/2.51.0/bin/git")
        try file("/brew/Cellar/git/2.51.0/libexec/git-core/git-remote-https")
        try link("/brew/bin/git", to: "../Cellar/git/2.51.0/bin/git")
        try file("/brew/Cellar/git-lfs/3.7.0/bin/git-lfs")
        try link("/brew/bin/git-lfs", to: "../Cellar/git-lfs/3.7.0/bin/git-lfs")
        let keys = ["/brew/bin/python3", "/brew/bin/python3.14", "/brew/bin/git", "/brew/bin/git-lfs"].map { root + $0 }
        let patterns = Dictionary(uniqueKeysWithValues: keys.map { ($0, AppPaths.tool($0, developerDirs: [])) })
        let (py, py314, git, lfs) = (keys[0], keys[1], keys[2], keys[3])
        XCTAssertEqual(AppPaths.sharing(patterns, routes: [py: "work", py314: BLOCK, git: "a", lfs: "z"]), [py: [py314], py314: [py]])
        // On the same route they agree; git and git-lfs never shared anything.
        XCTAssertEqual(AppPaths.sharing(patterns, routes: [py: "work", py314: "work", git: "a", lfs: "z"]), [:])
        // A third alias on yet another route: each lists both others.
        let p3 = root + "/brew/bin/python3.14-copy"
        try link("/brew/bin/python3.14-copy", to: "python3.14")
        var more = patterns
        more[p3] = AppPaths.tool(p3, developerDirs: [])
        let r = AppPaths.sharing(more, routes: [py: "a", py314: "b", p3: "c", git: "a", lfs: "a"])
        XCTAssertEqual(r[py], [py314, p3].sorted())
        XCTAssertEqual(r[p3], [py, py314].sorted())
        XCTAssertNil(r[git])
        XCTAssertEqual(AppPaths.sharing([:], routes: [:]), [:])
    }

    // MARK: Folders waited for

    func testAFolderWaitedForIsWatchedFromTheNearestOneAndOnlyComesCloserWhenOneOnTheWayAppears() throws {
        let home = root + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let apps = home + "/Applications/Sub"
        XCTAssertEqual(AppPaths.nearest(apps), home)
        let awaited = [apps: home]
        // A shell history save in the home folder: nothing came closer, no rewatch.
        FileManager.default.createFile(atPath: home + "/.zsh_history", contents: Data())
        XCTAssertFalse(AppPaths.closer(awaited, home))
        // Another folder's event is no reason either.
        XCTAssertFalse(AppPaths.closer(awaited, root))
        // A file of that name is no folder; nor a link to nowhere.
        FileManager.default.createFile(atPath: home + "/Applications", contents: Data())
        XCTAssertFalse(AppPaths.closer(awaited, home))
        XCTAssertEqual(AppPaths.nearest(apps), home)
        try FileManager.default.removeItem(atPath: home + "/Applications")
        try FileManager.default.createSymbolicLink(atPath: home + "/Applications", withDestinationPath: root + "/nowhere")
        XCTAssertFalse(AppPaths.closer(awaited, home))
        try FileManager.default.removeItem(atPath: home + "/Applications")
        // Two folders waited on from the same one: either coming closer counts.
        XCTAssertFalse(AppPaths.closer([apps: home, home + "/Tools/bin": home], home))
        try FileManager.default.createDirectory(atPath: home + "/Tools", withIntermediateDirectories: true)
        XCTAssertTrue(AppPaths.closer([apps: home, home + "/Tools/bin": home], home))
        // ~/Applications appears: closer; then the folder itself.
        try FileManager.default.createDirectory(atPath: home + "/Applications", withIntermediateDirectories: true)
        XCTAssertTrue(AppPaths.closer(awaited, home))
        XCTAssertFalse(AppPaths.closer([apps: home + "/Applications"], home + "/Applications"))
        try FileManager.default.createDirectory(atPath: apps, withIntermediateDirectories: true)
        XCTAssertTrue(AppPaths.closer([apps: home + "/Applications"], home + "/Applications"))
        XCTAssertEqual(AppPaths.nearest("/"), "/")
    }

    func testAFolderInVolumesIsNoDiskUnlessOneIsMountedThere() throws {
        XCTAssertTrue(AppPaths.mounted("/"))
        XCTAssertFalse(AppPaths.mounted(root))
        XCTAssertFalse(AppPaths.mounted(root + "/nowhere"))
        // The startup disk's name in /Volumes links to "/".
        try link("/Startup", to: "/")
        XCTAssertTrue(AppPaths.mounted(root + "/Startup"))
    }

    func testOnlyNothingThereIsAbsentNotAPlaceThatCantBeSearched() throws {
        try file("/Locked/vendor/Foo.app/Contents/Info.plist")
        XCTAssertFalse(AppPaths.absent(root + "/Locked/vendor/Foo.app"))
        XCTAssertTrue(AppPaths.absent(root + "/Locked/vendor/Bar.app"))
        XCTAssertTrue(AppPaths.absent(root + "/Locked/vendor/Foo.app/Contents/Info.plist/x"))
        try link("/Dangling.app", to: root + "/nowhere")
        XCTAssertTrue(AppPaths.absent(root + "/Dangling.app"))
        // A folder on the way that can't be searched (renamed and locked, say): can't tell, so not absent.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/Locked")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/Locked") }
        XCTAssertFalse(AppPaths.absent(root + "/Locked/vendor/Foo.app"))
        XCTAssertFalse(AppPaths.absent(root + "/Locked/vendor/Bar.app"))
    }

    func testMissingToolStillMatchesItsPath() {
        XCTAssertEqual(AppPaths.tool("/nowhere/tool", developerDirs: []), [Compiler.pattern(forPath: "/nowhere/tool")])
    }
}
