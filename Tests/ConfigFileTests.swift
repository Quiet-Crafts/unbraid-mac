import XCTest

/// Picked config files say why they can't be used: unreadable, too large, or not text unbraid reads.
final class ConfigFileTests: XCTestCase {
    private func message(_ f: () throws -> String) -> String? {
        do { _ = try f(); return nil } catch { return (error as? Fail)?.errorDescription }
    }

    func testTextEncodings() throws {
        let conf = "[Interface]\nPrivateKey = x\n"
        XCTAssertEqual(try ConfigFile.text(Data(conf.utf8)), conf)
        XCTAssertEqual(try ConfigFile.text(Data([0xEF, 0xBB, 0xBF]) + Data(conf.utf8)).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")), conf)
        XCTAssertEqual(try ConfigFile.text(Data([0xFF, 0xFE]) + conf.data(using: .utf16LittleEndian)!), conf)
        XCTAssertEqual(try ConfigFile.text(Data([0xFE, 0xFF]) + conf.data(using: .utf16BigEndian)!), conf)
        // UTF-16 without a byte-order mark, or bytes that are no text: said so, not "too large".
        XCTAssertEqual(message { try ConfigFile.text(conf.data(using: .utf16LittleEndian)!) }, "That file isn't text unbraid can read. Save it as UTF-8 and try again.")
        XCTAssertEqual(message { try ConfigFile.text(Data([0xC3, 0x28, 0xFF])) }, "That file isn't text unbraid can read. Save it as UTF-8 and try again.")
        XCTAssertNotNil(message { try ConfigFile.text(Data([0xFF, 0xFE]) + "a\0b".data(using: .utf16LittleEndian)!) })
        XCTAssertNotNil(message { try ConfigFile.text(Data([0xFE, 0xFF]) + "a\0b".data(using: .utf16BigEndian)!) })
    }

    func testSizeLimitIsInBytes() throws {
        XCTAssertEqual(try ConfigFile.text(Data(repeating: 0x61, count: 65_536)).count, 65_536)
        XCTAssertEqual(message { try ConfigFile.text(Data(repeating: 0x61, count: 65_537)) }, "That file is over 64 KB, too large for a config file.")
    }

    func testReadingAFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ConfigFileTests-\(UUID().uuidString).conf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x61, count: 200_000).write(to: url)
        XCTAssertEqual(message { try ConfigFile.read(url) }, "That file is over 64 KB, too large for a config file.")
        try Data("ok".utf8).write(to: url)
        XCTAssertEqual(try ConfigFile.read(url), "ok")
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(message { try ConfigFile.read(url) }, "Couldn't read that file.")
    }
}
