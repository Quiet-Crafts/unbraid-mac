import XCTest

/// Log's String overload is private as a whole, prefix included: a message built at run time would read as <private>
/// in a sysdiagnose. Every call names what happened in a plain literal and passes the rest as a detail, facts or an
/// error (see Log).
final class LogCallTests: XCTestCase {
    /// A call whose message isn't one plain, single-line literal: interpolated, multi-line, raw or computed. A call in a
    /// comment counts too: none should be left lying around to be uncommented.
    private static let call = try! NSRegularExpression(pattern: #"\bLog\s*\.\s*(?:info|error)\s*\(\s*+(?!"(?:[^"\\\n]|\\[^(\n])*"\s*[,)])"#)

    /// The lines the offending calls start on.
    private static func offending(_ text: String) -> [Int] {
        call.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            Range(m.range, in: text).map { text[..<$0.lowerBound].filter { $0 == "\n" }.count + 1 }
        }
    }

    func testTheScanTellsALiteralFromAMessageBuiltAtRunTime() {
        for fine in [#"Log.info("connected")"#, #"Log.error("check", detail: Redact.clean(error))"#,
                     #"Log.info("health", facts: "\(dead.count)")"#, #"Log.error("say \"no\"", error: error)"#,
                     #"Log.error("a\nb")"#, #"Log.error( "spaced")"#, #"log.error("\(s, privacy: .private)")"#,
                     "Log.error(\n    \"wrapped\",\n    error: error)"] {
            XCTAssertEqual(Self.offending(fine), [], fine)
        }
        for bad in [#"Log.error("store: \(name) not deleted")"#, #"Log.info( "x \(y)")"#, #"Log.error(text)"#,
                     #"Log.error("a" + b)"#, "Log.error(\"\"\"", ##"Log.error(#"raw"#)"##, #"// Log.error("old \(x)")"#,
                     "Log.error (text)", "Log . error(text)", "Log\n    .error(text)", "Log.error(\n    \"x \\(y)\")"] {
            XCTAssertEqual(Self.offending(bad), [1], bad)
        }
    }

    func testEveryLogMessageIsAPlainLiteral() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var found: [String] = [], files = 0
        for dir in ["App", "Shared", "Tunnel", "Widgets"] {
            let folder = root.appending(path: dir)
            var isDir: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue, dir)
            let all = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) { url, error in
                XCTFail("\(url.path): \(error)")
                return true
            })
            while let url = all.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                files += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                found += Self.offending(text).map { "\(url.path.dropFirst(root.path.count + 1)):\($0)" }
            }
        }
        XCTAssertGreaterThan(files, 20, "the sources weren't found")
        XCTAssertEqual(found, [], found.joined(separator: "\n"))
    }
}
