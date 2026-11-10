import Foundation

// A provider's status in words and a tone (good, warning, problem, idle), as Settings › Providers shows it.

nonisolated enum StatusTone: Equatable, Sendable { case good, warn, bad, idle }

nonisolated struct ProviderStatus: Equatable, Sendable {
    var tone: StatusTone
    var text: String

    static func reduce(name: String, used: Bool, refused: Bool, settingUp: Bool, blocked: Bool,
                       listFresh: Bool, connected: Bool, dropping: String? = nil, oldList: String? = nil, removed: Bool = false) -> Self {
        if removed { return .init(tone: .bad, text: "\(name) no longer has this Mac. Sign in again.") }
        if refused { return .init(tone: .bad, text: "\(name) refused this Mac. Sign in again") }
        if !used { return .init(tone: .idle, text: "Not used") }
        if settingUp { return .init(tone: .warn, text: "Setting up your key") }
        if blocked { return .init(tone: .warn, text: "Can't reach its servers right now") }
        if let dropping { return .init(tone: .warn, text: dropping) }
        if let oldList { return .init(tone: .warn, text: "Its server list is from \(oldList) and may be out of date") }
        if !listFresh { return .init(tone: .warn, text: "Using an older server list") }
        if connected { return .init(tone: .good, text: "Connected") }
        return .init(tone: .good, text: "Server list up to date")
    }

    static func listFresh(_ fresh: Bool, failed: Bool) -> Bool { fresh && !failed }

    static func oldList(_ epoch: Int64?, now: Date = .now) -> String? {
        guard let epoch, epoch > 0, now.timeIntervalSince1970 - Double(epoch) > 60 * 86_400 else { return nil }
        return publishedOn(epoch)
    }

    static func settingUp(signedIn: Date?, seconds: Int, now: Date = .now) -> Bool {
        guard let signedIn, seconds > 0 else { return false }
        return now >= signedIn && now.timeIntervalSince(signedIn) < Double(seconds)
    }

    static func keySettingUp(created: Date?, now: Date, seconds: Int) -> Bool {
        settingUp(signedIn: created, seconds: seconds, now: now)
    }

    static func publishedOn(_ epoch: Int64) -> String {
        guard epoch > 0, epoch < 253_402_300_800 else { return "an unknown date" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "d MMM yyyy"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
