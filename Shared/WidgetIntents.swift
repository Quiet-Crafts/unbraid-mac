import AppIntents

/// Tells the app to connect or to pause for 15 minutes (it lives in the menu bar). Widget buttons only: not offered
/// to Shortcuts or Spotlight.
///
/// Built into the app as well as the widgets, as Apple's widget guide asks: an intent that may continue in the
/// foreground can then be run by macOS in the app itself, which it launches when the app isn't running. Where macOS
/// runs it in the widget extension instead, the app is reached through `WidgetAction`, and a button the app doesn't
/// answer (it isn't running) fails rather than leave a request behind.
nonisolated struct ConnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect unbraid"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    func perform() async throws -> some IntentResult { try await WidgetAction.request("connect"); return .result() }
}

nonisolated struct PauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause unbraid for 15 minutes"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    func perform() async throws -> some IntentResult { try await WidgetAction.request("pause"); return .result() }
}

/// Not taken in time: unbraid isn't running, or didn't get to it (busy, or App Nap with no window open).
nonisolated struct NotAnswered: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "unbraid didn't answer. Open it and try again." }
}

nonisolated struct RequestNotWritten: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "unbraid couldn't take the request." }
}

extension WidgetAction {
    /// The app's own bundle ID (Config/Signing.xcconfig), so a build under another prefix still recognises itself.
    nonisolated static let appBundle = AppGroup.prefix

    /// The request, handed to the app the one way it takes them (see `WidgetActions` in the app): run in the app, it
    /// is read at once (at launch when macOS started the app for it); run in the widget extension, the app has to take
    /// it within 2 seconds, or the button fails and nothing is left for a later launch to act on.
    nonisolated static func request(_ action: String) async throws {
        if Bundle.main.bundleIdentifier == appBundle {
            guard send(action) else { throw RequestNotWritten() }
            return
        }
        switch await hand(action) {
        case .taken: return
        // A later press (or the app's own request) replaced it: that one's outcome is what counts, so no error here.
        case .superseded: return
        case .notTaken: throw NotAnswered()
        case .notWritten: throw RequestNotWritten()
        }
    }
}

nonisolated struct ProfileEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Profile"
    static let defaultQuery = ProfileQuery()
    var id: String
    var generation: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

nonisolated struct ProfileQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ProfileEntity] {
        let snapshot = Snapshot.read()
        guard let generation = snapshot.profileGeneration else { return [] }
        return (snapshot.profiles ?? []).filter { identifiers.contains($0) }.map { ProfileEntity(id: $0, generation: generation) }
    }
    func suggestedEntities() async throws -> [ProfileEntity] {
        let snapshot = Snapshot.read()
        guard let generation = snapshot.profileGeneration else { return [] }
        return (snapshot.profiles ?? []).map { ProfileEntity(id: $0, generation: generation) }
    }
}

struct SwitchProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Profile"
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    @Parameter(title: "Profile") var profile: ProfileEntity
    init() {}
    init(profile: ProfileEntity) { self.profile = profile }
    func perform() async throws -> some IntentResult {
        let action = WidgetAction.profileAction(name: profile.id, generation: profile.generation)
        guard WidgetAction.profileRequest(action) != nil else { throw RequestNotWritten() }
        try await WidgetAction.request(action)
        return .result()
    }
}

nonisolated struct ConnectPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect or Pause"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult {
        let s = Snapshot.read()
        try await WidgetAction.request(s.phase == .on && s.fresh(at: .now) ? "pause" : "connect")
        return .result()
    }
}
