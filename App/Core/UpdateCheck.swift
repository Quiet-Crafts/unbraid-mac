import Foundation

/// The optional update check. When the user turns it on, unbraid asks unbraid.app for one small file holding the newest
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
        /// Checks run only while on; off until the user says yes.
        var enabled = false
        /// The user answered the one-time question (or changed the setting), so it is never asked again.
        var asked = false
        var lastAttempt: Date?
        /// The last attempt got no valid answer: the next one comes an hour later instead of a day.
        var failed = false
        /// The newest version the last valid answer named.
        var latest: String?
        /// The notice was closed for this version: it comes back only for a newer one.
        var dismissed: String?
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

    static func load(_ defaults: UserDefaults) -> State {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }
    static func save(_ s: State, _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
    }
    private static let key = "updateCheck"

    /// Its own session: no cookies, caches or stored credentials, redirects refused (to another host or not), short
    /// timeouts, and headers that say only "unbraid".
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
        c.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "unbraid", "Accept-Language": "en"]
        return URLSession(configuration: c, delegate: Http.NoRedirect(), delegateQueue: nil)
    }()

    /// The answer's bytes, or nil for anything but a 200 from unbraid.app within the size cap: no network, the kill
    /// switch or a blocked state holding the request back, a timeout, a redirect or an error status all end here,
    /// silently.
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
    }

    var newer: UpdateCheck.Version? { UpdateCheck.newer(state, installed: installed) }
    var showNotice: Bool { UpdateCheck.showNotice(state, installed: installed) }
    /// The one-time question is still owed.
    var askPending: Bool { !state.asked }

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

    /// The answer to the one-time question: either way it is not asked again. Yes checks right away.
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
    /// Back to a fresh install's state, for testing the one-time question.
    func resetForTesting() { state = UpdateCheck.State(); lastManual = nil; defaults.removeObject(forKey: "updateCheck") }
    /// A given state, for the test copy's pictures.
    func setForTesting(_ s: UpdateCheck.State) { state = s; lastManual = nil }
    #endif
}
