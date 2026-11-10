import Foundation

/// When the app catalogue rescans: on activation at most every 30 s; after a change (a folder, a launch, a disk) a moment
/// later, however recent the last scan; and once more after a scan a change arrived during.
nonisolated struct Rescans: Sendable {
    static let activationGap: TimeInterval = 30
    static let settle: TimeInterval = 2
    static let changeGap: TimeInterval = 5

    private(set) var loading = false
    private var again = false
    private var last = Date.distantPast

    /// Whether to start a scan now; a change during one is remembered for `finished`.
    mutating func start(changed: Bool, now: Date) -> Bool {
        if loading { again = again || changed; return false }
        guard changed || now.timeIntervalSince(last) > Self.activationGap else { return false }
        loading = true
        last = now
        return true
    }

    /// A scan ended. True: a change came in meanwhile, so scan again.
    mutating func finished() -> Bool {
        loading = false
        defer { again = false }
        return again
    }

    /// How long a change waits before it scans: until things settle, and not sooner than `changeGap` after the last scan.
    /// Measured from the first change of a burst, so a steady stream of changes can't put the scan off for ever.
    func delay(now: Date) -> TimeInterval { max(Self.settle, Self.changeGap - now.timeIntervalSince(last)) }
}

/// Scans again while one saw bundles it couldn't read: an app being copied in (Finder fills in Info.plist last, and
/// writes inside a bundle raise no event in the folder holding it). After 10, 30 and 120 s, then not again for the same
/// bundles, so one that stays unreadable can't keep scanning for ever; other bundles start over.
nonisolated struct Retries: Sendable {
    static let delays: [TimeInterval] = [10, 30, 120]

    private var pending: Set<String> = []
    private var step = 0
    private(set) var due: Date?

    /// A scan ended that couldn't read `pending`. Returns when to scan again, nil for not. Any scan ending once one is
    /// due counts as that one, so scans in between don't use the steps up.
    mutating func scanned(_ pending: Set<String>, now: Date) -> Date? {
        guard !pending.isEmpty else { self = Retries(); return nil }
        if pending != self.pending {
            (self.pending, step, due) = (pending, 0, now + Self.delays[0])
        } else if let d = due, now >= d {
            step += 1
            due = step < Self.delays.count ? now + Self.delays[step] : nil
        }
        return due
    }
}

/// Starts of routed apps their rules couldn't take in even rebuilt (a copy another app has taken, a program of macOS):
/// one rebuild and rescan each, not one at every start. A start is rebuilt again once it resolves elsewhere, once ten
/// minutes have passed, once it was matched, or once what decides that app's rules changed (`forget`): never left out
/// for good.
nonisolated struct UnmatchedStarts: Sendable {
    static let expiry: TimeInterval = 600

    private var seen: [String: Seen] = [:]

    private struct Seen: Sendable {
        var real: String
        var at: Date
    }

    /// The key of one start: the app, the copy and the program it ran.
    static func key(_ id: String, _ bundle: String, _ path: String) -> String { [id, bundle, path].joined(separator: "\n") }

    /// Whether this start is to be rebuilt: not if it was, recently, resolving to the same program.
    func due(_ start: String, real: String, now: Date) -> Bool {
        guard let s = seen[start], s.real == real else { return true }
        return now.timeIntervalSince(s.at) >= Self.expiry || now < s.at
    }

    mutating func rebuilt(_ start: String, real: String, now: Date) { seen[start] = Seen(real: real, at: now) }

    mutating func matched(_ start: String) { seen[start] = nil }

    /// Forgets the starts of app `id`, or those of its that `covered` says its rules now take in.
    mutating func forget(_ id: String, covered: ((String) -> Bool)? = nil) {
        seen = seen.filter { !($0.key.hasPrefix(id + "\n") && (covered?($0.value.real) ?? true)) }
    }
}

