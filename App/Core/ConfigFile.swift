import Foundation

/// Config files the user picks (.conf, .ovpn): small text files, read with at most 64 KB + 1 bytes, never in full.
nonisolated enum ConfigFile {
    static let cap = 64 * 1024

    /// The file's text, or a Fail that says which: unreadable, too large, or not text unbraid reads.
    static func read(_ url: URL) throws -> String {
        // fileImporter hands out security-scoped URLs; the scope must be open while reading.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let h = try? FileHandle(forReadingFrom: url) else { throw Fail("Couldn't read that file.") }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: cap + 1) else { throw Fail("Couldn't read that file.") }
        return try text(data)
    }

    static func text(_ data: Data) throws -> String {
        guard data.count <= cap else { throw Fail("That file is over 64 KB, too large for a config file.") }
        // NULs aren't text: UTF-16 without a byte-order mark reads as "valid" UTF-8 full of them.
        if let s = String(data: data, encoding: .utf8), !s.contains("\0") { return s }
        // Windows tools often save UTF-16 with a byte-order mark.
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16), !s.contains("\0") { return s }
        throw Fail("That file isn't text unbraid can read. Save it as UTF-8 and try again.")
    }
}
