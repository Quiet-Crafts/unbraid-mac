import Foundation

/// Identifiers shared by the app, the tunnel extension and the widgets.
nonisolated enum AppGroup {
    static let team = signing.team
    /// The app's bundle ID; the extension's and the widgets' add ".tunnel" and ".widgets".
    static let prefix = signing.prefix
    static let id = "\(team).\(prefix)"
    /// The extension's XPC service (NEMachServiceName), which runs the engine's commands for the app. Suffixed with the
    /// build number: after an extension upgrade launchd keeps the old version's endpoint, so a fixed name would reach it.
    static let machService = "\(id).tunnel.\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")"
    static let tunnelBundle = "\(prefix).tunnel"
    /// Code requirement for the only client the extension serves: unbraid, signed by this team. Release builds accept
    /// only the Developer ID chain, so a development-signed (debuggable) copy can't drive a released extension.
    static let appRequirement = requirement(prefix, team: team)
    /// The app's check of the service it reaches: unbraid's own extension, on the same terms.
    static let tunnelRequirement = requirement(tunnelBundle, team: team)

    static func requirement(_ identifier: String, team: String) -> String {
        #if DEBUG
        "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        #else
        "identifier \"\(identifier)\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
        #endif
    }

    /// The team and bundle-ID prefix this build is signed for (Config/Signing.xcconfig), read from its own Info.plist,
    /// which the code signature covers, so a build under another team or prefix trusts its own app and extension. A
    /// build without valid ones stops here rather than fall back to another team's; only the host-less tests, whose
    /// runner has no such keys, take the maintainer's.
    private static let signing: (team: String, prefix: String) = {
        if let s = validSigning(Bundle.main.infoDictionary) { return s }
        guard NSClassFromString("XCTestCase") != nil else { fatalError("Info.plist has no valid UnbraidTeam and UnbraidBundlePrefix") }
        return ("28PLDKCR52", "app.unbraid")
    }()

    /// A ten-character team ID and a reverse-DNS prefix, nothing else: both end up inside code requirements.
    static func validSigning(_ info: [String: Any]?) -> (team: String, prefix: String)? {
        guard let team = info?["UnbraidTeam"] as? String, team.wholeMatch(of: /[A-Z0-9]{10}/) != nil,
              let prefix = info?["UnbraidBundlePrefix"] as? String,
              prefix.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) != nil else { return nil }
        return (team, prefix)
    }

    /// The widgets' read-only view of the app (see Snapshot). Nil outside an app-group entitled process.
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }
}

/// A widget button's request to the app: written by the widget, read once by the app within a few seconds. There is
/// one slot: a press replaces an earlier one the app hasn't taken.
nonisolated enum WidgetAction {
    static let note = "app.unbraid.widget"
    static var file: URL? { AppGroup.container?.appending(path: "widget-action") }

    /// How a request handed over from the widget extension went. `superseded`: not taken, because a later request
    /// replaced it before the app got to it.
    enum Handed: Equatable { case taken, notTaken, superseded, notWritten }

    /// The request: the action and, handed over from the widget extension, the press's id on a second line. False when
    /// it couldn't be written (no app-group container): nothing is sent then.
    @discardableResult
    static func send(_ action: String, press: String? = nil, to file: URL? = file, post: () -> Void = WidgetAction.post) -> Bool {
        written(action, press: press, to: file, post: post) != nil
    }

    /// `send`, giving when the request was written: its modification date, which every rename keeps, so requests can
    /// be told apart by age wherever they were moved. Written aside and renamed into the slot, so it is never seen half
    /// written.
    private static func written(_ action: String, press: String?, to file: URL?, post: () -> Void) -> Date? {
        let text = [action, press].compactMap { $0 }.joined(separator: "\n")
        guard let file else { return nil }
        let draft = file.deletingLastPathComponent().appending(path: "\(file.lastPathComponent).\(UUID().uuidString)")
        guard (try? Data(text.utf8).write(to: draft)) != nil, let date = small(draft)?.written, rename(draft.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: draft)
            return nil
        }
        post()
        return date
    }

    static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(note as CFString), nil, nil, true)
    }

    /// Sends the request and waits up to `wait` for the app to take it. Not taken by then, the press is settled as
    /// failed, so the app can't act on it later (a later launch included). No process lookup: what a sandboxed widget
    /// extension may see of running apps is not something to depend on; the app's answer for this very press is.
    static func hand(_ action: String, to file: URL? = file, wait: Duration = .seconds(2), post: () -> Void = WidgetAction.post) async -> Handed {
        let id = UUID().uuidString
        guard let file, let sent = written(action, press: id, to: file, post: post) else { return .notWritten }
        let deadline = ContinuousClock.now + wait
        while ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
            if answer(id, file) == taken {
                try? FileManager.default.removeItem(at: answerFile(id, file))
                return .taken
            }
        }
        // Ours still in the slot: taken back, the app never has it. A later press's: back in the slot for it, and the
        // app woken again (it may have looked while the slot was empty), unless an even later one is there.
        var replaced = false
        if let claimed = claim(file) {
            let request = Request(claimed)
            if request?.press == id {
                try? FileManager.default.removeItem(at: claimed)
                return .notTaken
            }
            // Only a request read as one, written after ours, says ours was replaced: one put back by another press's
            // widget can be older. Both dates are files' own, set when written. The app may still have ours: the settle
            // below tells.
            replaced = request.map { $0.written > sent } == true
            if renamex_np(claimed.path, file.path, UInt32(RENAME_EXCL)) == 0 { post() } else { try? FileManager.default.removeItem(at: claimed) }
        }
        // Gone, replaced or not movable: the app took it, or never will once this press is settled as failed.
        if settle(id, failed, file) { return replaced ? .superseded : .notTaken }
        let outcome = answer(id, file)
        try? FileManager.default.removeItem(at: answerFile(id, file))
        return outcome == taken ? .taken : .notTaken
    }

    /// The pending request's action, if fresh: written less than 10 seconds ago (one read at launch), or 3 for a press
    /// from the widget extension, whose widget normally gives up on it after 2, and not after now (a clock set back must not
    /// keep an old one fresh); from a widget, only if its press isn't settled as failed already. Claimed first, so the
    /// app and a widget taking it back can't both have it, then removed so it can't be replayed.
    static func take(from file: URL? = file, now: Date? = nil) -> String? {
        guard let file else { return nil }
        sweep(file)
        guard let claimed = claim(file) else { return nil }
        defer { try? FileManager.default.removeItem(at: claimed) }
        guard let r = Request(claimed), (0..<(r.press == nil ? 10 : 3)).contains((now ?? .now).timeIntervalSince(r.written)) else { return nil }
        if let press = r.press, !settle(press, taken, file) {
            try? FileManager.default.removeItem(at: answerFile(press, file)) // its widget gave up first
            return nil
        }
        return r.action
    }

    private static let taken = "taken", failed = "failed"
    /// What a request can ask (see `WidgetActions` in the app).
    static let actions: Set<String> = ["connect", "pause"]

    static func profileAction(name: String, generation: String) -> String {
        "profile:" + generation + ":" + Data(name.utf8).base64EncodedString()
    }

    /// Empty slots and snapshots without a valid generation cannot offer a switch.
    static func profileSlot(_ index: Int, names: [String]?, generation: String?) -> (name: String, generation: String)? {
        guard let names, names.indices.contains(index), let generation else { return nil }
        return profileRequest(profileAction(name: names[index], generation: generation))
    }

    static func profileRequest(_ action: String) -> (name: String, generation: String)? {
        let parts = action.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "profile", parts[1].count == 64,
              parts[1].allSatisfy({ $0.isHexDigit }), let bytes = Data(base64Encoded: String(parts[2])),
              let name = String(data: bytes, encoding: .utf8), !name.isEmpty, name.count <= 12 else { return nil }
        return (name, String(parts[1]))
    }

    enum ProfileDecision: Equatable { case reject, switchTo(String), pause, connect }

    static func profileDecision(_ action: String, generation: String, names: [String], current: String?, connected: Bool, lastSwitch: String? = nil) -> ProfileDecision {
        guard action != lastSwitch, let request = profileRequest(action), request.generation == generation, names.contains(request.name) else { return .reject }
        if request.name == current { return connected ? .pause : .connect }
        return .switchTo(request.name)
    }

    private struct Request {
        var action: String
        var press: String?
        /// Its file's modification date, which every rename keeps.
        var written: Date

        /// Nil for anything else: an action the app knows, and a press's id is a UUID (it names the press's answer file).
        init?(_ file: URL) {
            guard let (data, written) = small(file) else { return nil }
            self.written = written
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let action = lines.first, (WidgetAction.actions.contains(action) || WidgetAction.profileRequest(action) != nil), lines.count <= 2 else { return nil }
            self.action = action
            if lines.count == 2 {
                guard UUID(uuidString: lines[1]) != nil else { return nil }
                press = lines[1]
            }
        }
    }

    /// Settles a press for good, as taken by the app or failed by its widget, whichever comes first: the answer file is
    /// put in place by an exclusive rename. True when `outcome` is the answer.
    private static func settle(_ id: String, _ outcome: String, _ file: URL) -> Bool {
        let draft = file.deletingLastPathComponent().appending(path: "\(file.lastPathComponent).\(UUID().uuidString)")
        guard (try? Data(outcome.utf8).write(to: draft)) != nil else { return false }
        if renamex_np(draft.path, answerFile(id, file).path, UInt32(RENAME_EXCL)) == 0 { return true }
        try? FileManager.default.removeItem(at: draft)
        return false
    }

    private static func answer(_ id: String, _ file: URL) -> String? {
        small(answerFile(id, file)).map { String(decoding: $0.data, as: UTF8.self) }
    }

    /// A request's or an answer's bytes and modification date: only a regular file of at most 2048 bytes, opened without
    /// following a link or waiting on a pipe. Only unbraid's own targets can write the folder, but nothing put there must
    /// hang or bloat its reader.
    private static func small(_ url: URL) -> (data: Data, written: Date)? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, (0...2048).contains(info.st_size) else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 2049)
        while data.count <= 2048 {
            let n = read(fd, &buffer, buffer.count)
            guard n >= 0 else { return nil }
            if n == 0 { break }
            data.append(contentsOf: buffer[..<n])
        }
        guard data.count <= 2048 else { return nil }
        // Converted as Foundation converts a file's dates, so it equals what the file's resource values say.
        let t = info.st_mtimespec
        return (data, Date(timeIntervalSinceReferenceDate: TimeInterval(t.tv_sec) - Date.timeIntervalBetween1970AndReferenceDate
                                                           + 1.0e-9 * TimeInterval(t.tv_nsec)))
    }

    private static func answerFile(_ id: String, _ file: URL) -> URL {
        file.deletingLastPathComponent().appending(path: "\(file.lastPathComponent).answer.\(id)")
    }

    /// Moves the request to a name of its own (an atomic rename): of several callers, one gets it.
    private static func claim(_ file: URL) -> URL? {
        let claimed = file.deletingLastPathComponent().appending(path: "\(file.lastPathComponent).\(UUID().uuidString)")
        return rename(file.path, claimed.path) == 0 ? claimed : nil
    }

    /// Answers and claimed requests left behind by a widget or an app that went away mid-way: gone after 10 minutes.
    private static func sweep(_ file: URL) {
        let dir = file.deletingLastPathComponent(), prefix = file.lastPathComponent + "."
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            let url = dir.appending(path: name)
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               Date.now.timeIntervalSince(date) > 600 { try? FileManager.default.removeItem(at: url) }
        }
    }
}
