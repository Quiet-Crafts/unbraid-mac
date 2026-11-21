import Foundation

/// The update check, on by default from 1.3.7 (new versions often carry security fixes) and off whenever the user turns it
/// off. While on and once the terms are accepted, unbraid asks unbraid.app for one small file holding the newest
/// Mac version number, at most once a day (an hour later after a check that got no answer), and only tells the user:
/// it downloads and installs nothing. The request is a plain GET with a generic user agent and no cookies, caches,
/// identifiers or setup data, over the Mac's normal connection like unbraid's other own requests. The answer is
/// treated as hostile: size-capped, strictly parsed, and it can never choose where a click goes.
nonisolated enum UpdateCheck {
    /// The answer is `{"versionName": "1.2.3"}`; any other field is ignored.
    static let url = "https://unbraid.app/version/mac.json"
    /// Where "Download" goes: always this page, never a link from the answer.
    static let releasePage = "https://unbraid.app/download/"
    static let maxBytes = 4096
    static let successInterval: TimeInterval = 86_400
    static let failureInterval: TimeInterval = 3_600

    /// A release number of two to four parts of up to three ASCII digits each, without leading zeros ("1.2", "1.10.3").
    /// Anything else (a pre-release tag, a sign, spaces, other scripts' digits) is not a version.
    struct Version: Comparable, Hashable, Sendable, CustomStringConvertible {
        let parts: [Int]

        init?(_ text: String) {
            let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
            guard (2...4).contains(pieces.count) else { return nil }
            var parts: [Int] = []
            for p in pieces {
                guard (1...3).contains(p.utf8.count), p.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                      p.utf8.count == 1 || p.utf8.first != 0x30, let n = Int(p) else { return nil }
                parts.append(n)
            }
            self.parts = parts
        }

        /// Missing parts count as zero, so 1.1 and 1.1.0 are the same release.
        static func < (a: Version, b: Version) -> Bool {
            for i in 0..<max(a.parts.count, b.parts.count) {
                let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
                if x != y { return x < y }
            }
            return false
        }
        static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
        func hash(into h: inout Hasher) {
            var p = parts
            while p.count > 1, p.last == 0 { p.removeLast() }
            h.combine(p)
        }
        var description: String { parts.map(String.init).joined(separator: ".") }
    }

    /// The newest version an answer names, or nil for anything that isn't exactly a small JSON object whose
    /// `versionName` is a version string.
    static func parse(_ data: Data) -> Version? {
        guard !data.isEmpty, data.count <= maxBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["versionName"] as? String else { return nil }
        return Version(name)
    }

    /// What the check remembers between launches. Not secret: no answer is kept beyond the version number it named.
    struct State: Codable, Equatable, Sendable {
        /// Checks run only while on (`onByDefault` turns them on once per install).
        var enabled = false
        /// The user saw the notice that checks are on (or changed the setting), so it isn't shown again.
        var asked = false
        var lastAttempt: Date?
        /// The last attempt got no valid answer: the next one comes an hour later instead of a day.
        var failed = false
        /// The newest version the last valid answer named.
        var latest: String?
        /// The notice was closed for this version: it comes back only for a newer one.
        var dismissed: String?
        /// Checks were turned on by default for this install (`onByDefault`): once, so turning them off stays off.
        var turnedOn = false

        init(enabled: Bool = false, asked: Bool = false, lastAttempt: Date? = nil, failed: Bool = false, latest: String? = nil,
             dismissed: String? = nil, turnedOn: Bool = false) {
            (self.enabled, self.asked, self.lastAttempt, self.failed) = (enabled, asked, lastAttempt, failed)
            (self.latest, self.dismissed, self.turnedOn) = (latest, dismissed, turnedOn)
        }

        /// A file from an earlier version has no `turnedOn`, which takes its default, so a new field never makes an older
        /// file unreadable. `enabled`, `asked` and `failed`, which every version has written, must be there: a file
        /// without them is damaged, not a choice to read as "off" and then turn on.
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            enabled = try c.decode(Bool.self, forKey: .enabled)
            asked = try c.decode(Bool.self, forKey: .asked)
            lastAttempt = try c.decodeIfPresent(Date.self, forKey: .lastAttempt)
            failed = try c.decode(Bool.self, forKey: .failed)
            latest = try c.decodeIfPresent(String.self, forKey: .latest)
            dismissed = try c.decodeIfPresent(String.self, forKey: .dismissed)
            turnedOn = try c.decodeIfPresent(Bool.self, forKey: .turnedOn) ?? false
        }
    }

    /// Checks on by default, once per install, for a new install and an earlier one alike, also one that chose not to
    /// check before: the window then says so once, with a one-click Turn Off. An install whose checks were already on
    /// and acknowledged keeps its state; once turned on, turning them off stays off.
    static func onByDefault(_ s: State) -> State {
        guard !s.turnedOn else { return s }
        var s = s
        if !(s.enabled && s.asked) { s.enabled = true; s.asked = false }
        s.turnedOn = true
        return s
    }

    /// Whether an automatic check is due: on, and a day after the last attempt (an hour after one that failed). A last
    /// attempt in the future (the clock was set back) doesn't hold checks off for good.
    static func due(_ s: State, now: Date) -> Bool {
        guard s.enabled else { return false }
        guard let last = s.lastAttempt else { return true }
        return now < last || now.timeIntervalSince(last) >= (s.failed ? failureInterval : successInterval)
    }

    /// The newest known release if it is newer than the one installed, else nil. An installed version that can't be
    /// read is never offered an update, so nothing can talk it into a prompt.
    static func newer(_ s: State, installed: Version?) -> Version? {
        guard let installed, let latest = s.latest.flatMap(Version.init), latest > installed else { return nil }
        return latest
    }

    /// Whether the main window shows the notice: on, a newer release is known, and it wasn't closed for that one or
    /// a later one.
    static func showNotice(_ s: State, installed: Version?) -> Bool {
        guard s.enabled, let newer = newer(s, installed: installed) else { return false }
        return s.dismissed.flatMap(Version.init).map { newer > $0 } ?? true
    }

    /// The state after an attempt: a valid answer replaces what was known; none keeps it and marks the attempt failed.
    static func record(_ s: State, answer: Version?) -> State {
        var s = s
        s.failed = answer == nil
        if let answer { s.latest = answer.description }
        return s
    }

    /// Whether a link is the release page: only that https address on unbraid.app, nothing else is ever opened.
    static func isReleasePage(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return c.scheme == "https" && c.host == "unbraid.app" && c.port == nil && c.user == nil && c.password == nil
            && c.path == "/download/" && c.query == nil
    }

    /// The saved state, checks on by default (`onByDefault`). A saved state that can't be read stays off and is never
    /// turned on: what the user chose there is unknown.
    static func load(_ defaults: UserDefaults) -> State {
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        // Turned on by default already (its own key, which no earlier version writes, so going back to one and returning
        // can't undo a Turn Off): the saved state is the user's, and one that can't be read stays off.
        if defaults.bool(forKey: onByDefaultKey) {
            var s = saved ?? State(asked: true)
            s.turnedOn = true
            return s
        }
        // The first launch of 1.3.7 or later. Nothing saved at all is a new install; something saved that isn't a
        // readable state (damaged, or another type) is not, and stays off.
        guard defaults.object(forKey: key) != nil else { return onByDefault(State()) }
        guard let saved else { return State(asked: true, turnedOn: true) }
        return onByDefault(saved)
    }
    static func save(_ s: State, _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
    }
    private static let key = "updateCheck"
    /// Set once checks were turned on by default for this install (`load`), in a key of its own.
    static let onByDefaultKey = "updateCheckOnByDefault"
    /// The terms are accepted (`Store.termsAccepted`, the same defaults): no automatic check runs before.
    static let termsKey = "termsAccepted"

    /// Its own session: no cookies, caches or stored credentials, redirects refused (to another host or not), short
    /// timeouts, and headers that say only "unbraid" and its version ("unbraid/1.2.0"), so the site can tell how many
    /// installs run each version.
    static let agent = "unbraid/" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 20
        c.waitsForConnectivity = false
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": agent, "Accept-Language": "en"]
        return URLSession(configuration: c, delegate: Http.NoRedirect(), delegateQueue: nil)
    }()

    /// The answer's bytes, or nil for anything but a 200 from unbraid.app within the size cap: no network, a timeout,
    /// a redirect or an error status all end here, silently. unbraid's own process always goes out directly (the
    /// compiled rules send it to the direct outbound before any route, and the kill switch and blocked-app refusals
    /// leave it out), so this request is not held back by them.
    @concurrent static func fetch() async -> Data? {
        #if DEBUG
        // Debug builds can read a local answer instead (`defaults write app.unbraid debugUpdateAnswer <file>`, or
        // `offline` for no answer), so every case can be tried without publishing anything.
        if let fake = UserDefaults.standard.string(forKey: "debugUpdateAnswer") {
            return fake == "offline" ? nil : FileManager.default.contents(atPath: fake).flatMap { $0.count <= maxBytes ? $0 : nil }
        }
        if (try? PerfFake.offline()) == nil { return nil }
        #endif
        guard let u = URL(string: url) else { return nil }
        var r = URLRequest(url: u)
        r.httpShouldHandleCookies = false
        do {
            let (bytes, response) = try await session.bytes(for: r)
            guard let h = response as? HTTPURLResponse, h.statusCode == 200, h.url?.host == "unbraid.app",
                  h.expectedContentLength <= Int64(maxBytes) else { return nil }
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count > maxBytes { return nil }
            }
            return data
        } catch { return nil }
    }
}

/// Runs the check: at most once a day while on, right away when turned on, and when the user asks. Keeps its state in
/// the defaults and never reports a failed automatic check.
@MainActor @Observable
final class Updates {
    static let shared = live()
    private static func live() -> Updates {
        let installed = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(UpdateCheck.Version.init)
        return Updates(defaults: .standard, installed: installed, now: { Date() }, fetch: { await UpdateCheck.fetch() })
    }

    enum Outcome: Equatable { case newer(UpdateCheck.Version), current, failed }

    private(set) var state: UpdateCheck.State
    private(set) var checking = false
    /// What the last check the user asked for found, for Settings; nil until one finishes.
    private(set) var lastManual: Outcome?
    let installed: UpdateCheck.Version?
    private let defaults: UserDefaults
    private let fetch: @Sendable () async -> Data?
    private let now: () -> Date
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var current: Task<Void, Never>?
    @ObservationIgnored private var attempt = 0

    init(defaults: UserDefaults, installed: UpdateCheck.Version?, now: @escaping () -> Date, fetch: @escaping @Sendable () async -> Data?) {
        self.defaults = defaults
        self.installed = installed
        self.now = now
        self.fetch = fetch
        state = UpdateCheck.load(defaults)
        // Saved at once, so checks turned on by default stay a one-time step even if nothing else changes.
        if defaults.data(forKey: "updateCheck").flatMap({ try? JSONDecoder().decode(UpdateCheck.State.self, from: $0) }) != state {
            UpdateCheck.save(state, defaults)
        }
        defaults.set(true, forKey: UpdateCheck.onByDefaultKey)
    }

    var newer: UpdateCheck.Version? { UpdateCheck.newer(state, installed: installed) }
    var showNotice: Bool { UpdateCheck.showNotice(state, installed: installed) }
    /// The notice that checks are on is still owed (shown in the window until OK or Turn Off).
    var askPending: Bool { !state.asked && state.enabled }

    /// Checks when due, starting a little after launch (not while the app is still opening) and then looking hourly.
    func start(after delay: Duration = .seconds(30)) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                guard let self else { return }
                if UpdateCheck.due(self.state, now: self.now()) { await self.check(user: false) }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// The answer to the one-time notice that checks are on (OK is yes, Turn Off is no): either way it is not shown again,
    /// and no is never undone by a later version. Yes checks right away when checks were off.
    func answer(_ on: Bool) {
        let was = state.enabled
        change { $0.enabled = on; $0.asked = true }
        if on && !was { Task { await check(user: false, force: true) } }
    }

    /// The Settings switch counts as an answer too. Turning it on checks right away.
    func setEnabled(_ on: Bool) { answer(on) }

    /// Closes the notice until a newer release than the one shown.
    func dismiss() {
        guard let newer else { return }
        change { $0.dismissed = newer.description }
    }

    /// Check Now: one request the user asked for, whatever the setting; its result shows in Settings.
    func checkNow() async { await check(user: true, force: true) }

    /// One attempt at a time: a second caller waits for the running one. The attempt is recorded before the request,
    /// so a crash or quit mid-check still counts. An automatic check sends nothing once the user turned checks off,
    /// and one whose answer arrives after that records nothing.
    func check(user: Bool, force: Bool = false) async {
        if let running = current {
            await running.value
            // An automatic check that found one running has nothing left to do.
            if !user { return }
        }
        // A running attempt clears `current` itself before it ends, so this never waits on a finished one.
        while let running = current { await running.value }
        guard force || UpdateCheck.due(state, now: now()) else { return }
        // Nothing automatic leaves the Mac before the terms are accepted; a check the user asks for is theirs.
        guard user || defaults.bool(forKey: UpdateCheck.termsKey) else { return }
        if user { lastManual = nil }
        attempt += 1
        let id = attempt
        let task = Task { [fetch] in
            defer {
                checking = false
                if attempt == id { current = nil }
            }
            guard user || state.enabled else { return }
            checking = true
            change { $0.lastAttempt = now() }
            let answer = await fetch().flatMap(UpdateCheck.parse)
            if !user && !state.enabled { return }
            change { $0 = UpdateCheck.record($0, answer: answer) }
            if user { lastManual = answer.map { a in installed.map { a > $0 } == true ? .newer(a) : .current } ?? .failed }
        }
        current = task
        await task.value
    }

    private func change(_ f: (inout UpdateCheck.State) -> Void) {
        var s = state
        f(&s)
        guard s != state else { return }
        state = s
        UpdateCheck.save(s, defaults)
    }

    #if DEBUG
    /// Back to a fresh install's state, for testing the notice that checks are on.
    func resetForTesting() {
        // As a first launch leaves it: turned on by default, the step recorded, the notice owed.
        state = UpdateCheck.onByDefault(UpdateCheck.State()); lastManual = nil
        UpdateCheck.save(state, defaults)
        defaults.set(true, forKey: UpdateCheck.onByDefaultKey)
    }
    /// A given state, for the test copy's pictures.
    func setForTesting(_ s: UpdateCheck.State) { state = s; lastManual = nil }
    #endif
}
