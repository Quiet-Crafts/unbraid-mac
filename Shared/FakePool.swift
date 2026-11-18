import Foundation

/// When the extension moves a running engine to the next block of stand-in addresses (`ConfigVet.fakeRanges`). The
/// engine never hands an address to a second name while its block stays (a program still holding it would have its new
/// connections taken for the other name's, and routed as that name is), so a block running low is replaced by the
/// next. At most once per `spacing`: a flood of lookups can then only make new lookups fail until the next move is
/// due, never move anyone's traffic, and a block comes back only after the seven others.
nonisolated enum FakePool {
    enum Step: Equatable {
        case nothing
        case rotate
        /// Running low, but the last move was too recent; `exhausted` once lookups of new names fail.
        case wait(exhausted: Bool)
    }

    /// Addresses one block hands out: all but the network address, the engine's starting point after it, and the
    /// broadcast address.
    static let capacity: Int = {
        let bits = Int(ConfigVet.fakeRanges[0].split(separator: "/").last ?? "") ?? 32
        return (1 << (32 - bits)) - 3
    }()
    /// Below this many left, the block is replaced.
    static let low = capacity / 4
    static let spacing: Duration = .seconds(600)
    /// How often the extension asks the engine how many are left.
    static let every: Duration = .seconds(15)

    /// [remaining]: what the engine can still hand out (negative while it runs no store). [since]: the time since the
    /// block last changed in this process (a start or a move), nil if it never did.
    static func step(remaining: Int, since: Duration?) -> Step {
        guard remaining >= 0, remaining < low else { return .nothing }
        if let since, since < spacing { return .wait(exhausted: remaining == 0) }
        return .rotate
    }

    /// Whether a check tries a failed move's reload again: only while the engine is down because of it. A running
    /// engine (a reload succeeded since) or a failure the app's own reload left is not the extension's to repair.
    static func retries(failedRotation: Bool, engineRunning: Bool) -> Bool { failedRotation && !engineRunning }

    /// Whether an engine start within a connection (a reload, or a move tried again) takes a new table, the next block
    /// from a deleted cache file, instead of the block and cache file it has. [ran]: an engine ran on this block, so
    /// programs may hold its addresses: it is kept only with the cache file that names them, never from an empty one.
    /// [refused]: the engine's last start refused the cache file as damaged (it never replaces one, which could bring
    /// an empty table to a block in use), so no start on that file can work.
    /// [cacheBytes]: the size of the cache file, 0 when there is none.
    static func needsNewTable(ran: Bool, cacheBytes: Int, refused: Bool) -> Bool {
        refused || ran && cacheBytes <= 0
    }

    /// Whether [error], a start the engine refused, says its cache file is damaged: the engine patch's wording
    /// (tools/sing-box-fakeip-no-reuse.patch) at the step that opens the file. Found anywhere in the text, whatever the
    /// engine puts before it: taking another error for this one only costs a block, missing this one would have every
    /// later start meet the same file.
    static func refusedCache(_ error: String) -> Bool { error.contains("initialize cache-file: \(damagedCache): ") }
    static let damagedCache = "damaged cache file kept"
}
