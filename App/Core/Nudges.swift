import Foundation

/// What the support card remembers, on this Mac only: nothing of it is sent anywhere.
nonisolated struct NudgeState: Codable, Equatable, Sendable {
    /// When unbraid was first opened on this Mac.
    var installedAt: Date?
    /// Days (since 1970) on which unbraid connected; three are all the rule needs.
    var connectedDays: [Int] = []
    /// When the card was shown, the last few times.
    var shownAt: [Date] = []
    var snoozeUntil: Date?
    /// The user said never to ask again.
    var disabled = false

    init() {}
    /// Whatever is missing or can't be read is as if never recorded, except "never again", which is kept if it reads.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        installedAt = c(.installedAt, nil); connectedDays = c(.connectedDays, []); shownAt = c(.shownAt, [])
        snoozeUntil = c(.snoozeUntil, nil); disabled = c(.disabled, false)
    }
}

/// When the support card may show: rare, never in a first week, and never again once turned off. All of it is a pure
/// function of `NudgeState`.
nonisolated enum Nudges {
    static let day: TimeInterval = 86_400
    private static let minDays = 3
    private static let kept = 4

    static func epochDay(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / day).rounded(.down)) }

    /// Notes when unbraid was first opened; kept once set.
    static func installed(_ s: NudgeState, now: Date) -> NudgeState {
        guard s.installedAt == nil else { return s }
        var s = s; s.installedAt = now; return s
    }

    /// Notes that unbraid was connected today.
    static func connectedDay(_ s: NudgeState, now: Date) -> NudgeState {
        let today = epochDay(now)
        guard !s.connectedDays.contains(today), s.connectedDays.count < minDays else { return s }
        var s = s; s.connectedDays.append(today); return s
    }

    /// Whether to ask now; `calm` says the window is quiet enough (nothing else is asking, nothing is going wrong).
    static func due(_ s: NudgeState, now: Date, calm: Bool) -> Bool {
        // Days later than today (the clock was set back since) don't count yet.
        let today = epochDay(now)
        guard !s.disabled, calm, let installed = s.installedAt, now.timeIntervalSince(installed) >= 7 * day,
              s.snoozeUntil.map({ now >= $0 }) ?? true, Set(s.connectedDays.filter { $0 <= today }).count >= minDays else { return false }
        // A date in the future (the clock was set back) counts as just shown.
        let since = s.shownAt.map { max(0, now.timeIntervalSince($0)) }
        return !since.contains { $0 < 90 * day } && since.filter { $0 < 365 * day }.count < kept
    }

    /// Records that the card showed, and rests it for 90 days (also what closing it means).
    static func shown(_ s: NudgeState, now: Date) -> NudgeState {
        var s = s
        s.shownAt = Array((s.shownAt + [now]).suffix(kept)); s.snoozeUntil = now.addingTimeInterval(90 * day)
        return s
    }

    static func disable(_ s: NudgeState) -> NudgeState { var s = s; s.disabled = true; return s }
}

extension NudgeState {
    static let key = "supportCard"

    /// Reads the state kept in `defaults`; anything missing or unreadable is a new state.
    static func load(_ defaults: UserDefaults) -> NudgeState {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(NudgeState.self, from: $0) } ?? NudgeState()
    }

    func save(_ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// What the main window is doing, as far as the support card cares: it shows only while nothing else is asking for
/// attention and nothing is going wrong.
nonisolated struct WindowCalm: Equatable, Sendable {
    var termsAccepted = false
    var signedIn = false
    /// The update question or the update notice is showing.
    var updateShowing = false
    /// Another notice, a connection error or an unsaved-changes row is showing above the page.
    var noticeShowing = false
    /// A sheet, an alert or a question (login item, limit) is up, or the tour is running or about to be offered.
    var asking = false
    var phase = Snapshot.Phase.off
    var error = false

    var isCalm: Bool {
        termsAccepted && signedIn && !updateShowing && !noticeShowing && !asking && !error && (phase == .on || phase == .off)
    }
}
