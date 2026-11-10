import Foundation

/// FIFO file work, submitted synchronously from the main actor. Reads and shutdown barriers share the same queue,
/// so neither can overtake an earlier save. Encoding, keychain access, encryption and disk I/O stay off MainActor.
nonisolated final class FileWork: Sendable {
    static let shared = FileWork()
    private let queue = DispatchQueue(label: "app.unbraid.files", qos: .utility)

    func submit(_ body: @escaping @Sendable () -> Void) { queue.async(execute: body) }
    func read<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in queue.async { c.resume(returning: body()) } }
    }
    func drain() async { await read {} }
}
