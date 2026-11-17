import Foundation

/// The networks the user told unbraid to remember, and the profile to use on each: what switches profile by itself.
/// Kept apart from the setup: nothing here changes what the engine runs until a switch is made.
nonisolated struct NetworkRules: Codable, Equatable, Sendable {
    struct Known: Codable, Equatable, Identifiable, Sendable {
        /// The network's reading when it was remembered (`NetworkMark.current`): its routers' fingerprints.
        var id: String
        var name: String
        /// The profile to use here; nil = don't switch on this network.
        var profile: String?
        var added: Date
    }

    static let max = 20
    static let nameLimit = 24

    /// Scrambles this install's fingerprints, so they mean nothing anywhere else.
    var salt = UUID().uuidString
    var known: [Known] = []
    /// The profile for any network that isn't remembered; nil = don't switch there.
    var elsewhere: String?

    var isEmpty: Bool { elsewhere == nil && known.allSatisfy { $0.profile == nil } }

    /// The profile set for the network read as `mark`: its own if it is remembered (which may be none), else the one
    /// for any other network.
    func profile(on mark: String) -> String? { network(mark).map(\.profile) ?? elsewhere }

    /// The routers' fingerprints in a reading.
    static func members(_ mark: String) -> Set<Substring> { Set(mark.split(separator: ",")) }

    /// The remembered network read as `mark`: one whose routers include every router seen now. A home with two routers
    /// stays itself while one is away; a network with a router of its own beside one that looks like home's is never
    /// taken for home.
    func network(_ mark: String) -> Known? {
        let now = Self.members(mark)
        return now.isEmpty ? nil : known.first { now.isSubset(of: Self.members($0.id)) }
    }

    /// A name as it is kept: trimmed, without control or direction characters, not longer than the limit, not one
    /// already used. Nil when nothing usable is left.
    func name(_ raw: String, except id: String? = nil) -> String? {
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !Self.directional.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= Self.nameLimit,
              !known.contains(where: { $0.id != id && $0.name.compare(cleaned, options: [.caseInsensitive]) == .orderedSame }) else { return nil }
        return cleaned
    }

    private static let directional = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{061C}\u{2028}\u{2029}")

    /// Remembers the network with fingerprint `mark` under `name`. False when it is already remembered, the name
    /// can't be used, or no more fit.
    @discardableResult
    mutating func remember(_ mark: String, name raw: String, profile: String?, now: Date = .now) -> Bool {
        guard mark != AutoSwitch.unrecognised, !Self.members(mark).isEmpty, known.count < Self.max, network(mark) == nil, let name = name(raw) else { return false }
        known.append(Known(id: mark, name: name, profile: profile, added: now))
        return true
    }

    mutating func forget(network id: String) { known.removeAll { $0.id == id } }

    /// A profile was renamed: its rules follow it.
    mutating func renamed(_ old: String, to new: String) {
        for i in known.indices where known[i].profile == old { known[i].profile = new }
        if elsewhere == old { elsewhere = new }
    }

    /// A profile was deleted: nothing switches to it any more.
    mutating func deleted(_ profile: String) {
        for i in known.indices where known[i].profile == profile { known[i].profile = nil }
        if elsewhere == profile { elsewhere = nil }
    }

    /// Rules naming a profile that no longer exists switch nowhere (a setup restored or edited elsewhere).
    mutating func tidy(profiles: [String]) {
        for i in known.indices where known[i].profile.map({ !profiles.contains($0) }) == true { known[i].profile = nil }
        if let e = elsewhere, !profiles.contains(e) { elsewhere = nil }
    }
}

/// Decides when the profile set for the network the Mac is on is switched to. Only ever while connected, a few seconds
/// after the network changed, and never against a choice the user made by hand on this network.
nonisolated enum AutoSwitch {
    /// How long a network must last before a switch, so a handover or a short drop passes without one.
    static let settle: Duration = .seconds(5)
    /// How long the Mac must be on a network that gives no fingerprint before it counts as one unbraid can't recognise:
    /// long enough for a router that answers late (after joining or a wake), so a remembered network isn't taken for
    /// another one in between.
    static let unrecognisedAfter: Duration = .seconds(20)
    /// What a network that gives no fingerprint goes by: never a fingerprint (those are hex), so it is never remembered
    /// and its profile is the one for any other network. All such networks look the same.
    static let unrecognised = "unrecognised"

    /// What was last decided on: the network (a remembered one by its own name, so a router coming or going doesn't
    /// make it another) and the profile its rule named. Nothing more happens until either changes, so a profile picked
    /// by hand stays through a change to the rules of another network.
    struct Acted: Equatable, Sendable {
        var mark: String
        var profile: String?
        init(mark: String, rules: NetworkRules) { self.mark = rules.network(mark)?.id ?? mark; profile = rules.profile(on: mark) }
    }

    enum Step: Equatable, Sendable {
        case none
        case to(String)
        /// Not switched, and why, for one notification.
        case blocked(String)
    }

    /// On the network with fingerprint `mark`, with setup `s` and rules `rules`. `acted`: what was last decided on.
    /// `over`: whether using that profile takes a provider over its connection limit (the app would ask first, which
    /// nothing here can).
    static func decide(_ s: Setup, rules: NetworkRules, mark: String, acted: Acted?, over: (Setup) -> Bool) -> Step {
        guard acted != Acted(mark: mark, rules: rules), let name = rules.profile(on: mark), name != s.profile,
              let target = s.profiles.first(where: { $0.name == name }) else { return .none }
        // A profile whose default route is gone can't be used; the Profiles page says so on its row.
        guard target.defaultRoute == DIRECT || s.route(target.defaultRoute) != nil else { return .none }
        // A setup that is no profile yet would be replaced without a way back: it is the user's to save first.
        guard s.profile != nil else { return .blocked("Not switched to \(name): your current setup isn't saved as a profile. Save it as a profile, or switch in unbraid.") }
        var next = s
        next.use(name)
        return over(next) ? .blocked("Not switched to \(name): it needs more connections than a provider allows. Switch in unbraid to choose what to do.") : .to(name)
    }
}
