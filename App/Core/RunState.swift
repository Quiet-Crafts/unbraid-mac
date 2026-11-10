import CryptoKit
import Foundation

/// The user setup and any temporary configuration the engine runs in its place.
nonisolated struct RunState: Equatable, Sendable {
    /// A stable identity for a setup, independent of Swift's randomised hash seed.
    typealias Revision = String
    enum StandIn: Equatable, Sendable { case none, denyAll, pause, fallback, foreign }

    private(set) var engineStarts = 0
    private(set) var applied: Revision?
    private(set) var appliedSetup: Setup?
    private(set) var refusedSetup: Setup?
    private(set) var refused: Revision?
    private(set) var standIn = StandIn.none

    /// Nil when the running configuration is not confirmed as ours.
    func protection(blocked: Set<String>) -> Bool? {
        guard standIn == .none, let setup = appliedSetup else { return nil }
        let used = Set(setup.apps.values).union([setup.defaultRoute])
        return setup.activeRoutes.contains { used.contains($0.id) && !blocked.contains($0.id) }
    }

    static func revision(_ setup: Setup) -> Revision {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Setup contains only JSON values, so encoding cannot fail.
        let data = try! encoder.encode(setup)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    mutating func freshEngine() { engineStarts += 1 }
    mutating func committed(revision: Revision, setup: Setup, fresh: Bool, interim: Bool = false) {
        guard !interim else { return }
        applied = revision
        appliedSetup = setup
        standIn = .none
        if fresh { refused = nil; refusedSetup = nil }
    }
    mutating func refused(revision: Revision, setup: Setup? = nil) { refused = revision; refusedSetup = setup }
    mutating func storeMoved(to revision: Revision) { if refused != revision { refused = nil; refusedSetup = nil } }
    mutating func deniedAll() { standIn = .denyAll }
    mutating func pausedBlocking() { standIn = .pause }
    mutating func fallback() { standIn = .fallback }
    mutating func foreign() { standIn = .foreign }
    mutating func stopped() { standIn = .none }
}
