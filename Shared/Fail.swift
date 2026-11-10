import Foundation

/// A failure whose message unbraid wrote itself and that is safe to show as is.
nonisolated struct Fail: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

nonisolated extension Collection {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
