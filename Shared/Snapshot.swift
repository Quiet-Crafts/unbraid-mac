import Foundation

/// What the widgets show, written by the app into the shared app-group container. Nothing secret: route names, counts,
/// the connection state and this week's totals per route.
nonisolated struct Snapshot: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case on, connecting, paused, off
        var symbol: String {
            switch self { case .on: "checkmark.shield.fill"; case .paused: "pause.fill"; case .connecting: "shield.lefthalf.filled"; case .off: "shield.slash" }
        }
    }

    struct Route: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var code: String
        var hue: Int
        var apps: Int
        var isDefault: Bool
        /// ISO country code for provider routes only; absent in snapshots from older app versions.
        var country: String? = nil
        /// Websites with this route of their own; absent in older snapshots.
        var sites: Int? = nil
        /// Whether its tunnel works, only while connected: true once a check was answered, false when blocked or not
        /// answering; nil when not known (not connected, not checked or not yet, or an older snapshot).
        var ok: Bool? = nil
    }

    /// One day of this week: bytes per route id.
    struct Day: Codable, Equatable, Sendable {
        var date: Date
        var bytes: [String: Int64]
    }

    var phase = Phase.off
    var since: Date?
    var pausedUntil: Date?
    var exits = 0
    var routes: [Route] = []
    var direct = 0
    var blocked = 0
    /// Websites on Direct and Blocked; absent in older snapshots.
    var directSites: Int? = nil
    var blockedSites: Int? = nil
    var week: [Day] = []
    /// When the app last confirmed this; the widgets stop vouching for a state the app hasn't confirmed for 75 minutes.
    var updated = Date.distantPast
    /// The last change, connect, pause or resume failed (the app says why); nil when nothing failed. Never the error's
    /// text: it can name a server, and the widgets only need to send the user to the app.
    var failed: Bool? = nil
    /// The default route when it is Direct, which has no row in `routes`; nil otherwise and in older snapshots.
    var defaultRoute: String? = nil
    var profiles: [String]? = nil
    var profile: String? = nil
    var profileGeneration: String? = nil
    /// Whether a confirmed running configuration has a VPN route. Absent in older snapshots.
    var protected: Bool? = nil
    /// Tailscale as the widgets name it: "Tailscale on", "Tailscale off", or "Headscale on" for a self-hosted control
    /// server (an earlier build wrote "TS on"); nil when it isn't set up, and in older snapshots.
    var tailscale: String? = nil

    /// How many apps and websites take a route: "5 apps · 2 websites", "2 websites", or the apps alone.
    static func count(apps: Int, sites: Int) -> String {
        let a = "\(apps) app\(apps == 1 ? "" : "s")", w = websites(sites)
        return sites == 0 ? a : apps == 0 ? w : "\(a) · \(w)"
    }
    static func websites(_ n: Int) -> String { "\(n) website\(n == 1 ? "" : "s")" }

    /// Working routes of those whose health is known, only while connected: nil when there is nothing to vouch for, so
    /// no green from an earlier connection is ever shown.
    var health: (working: Int, total: Int)? {
        guard phase == .on else { return nil }
        let known = routes.compactMap(\.ok)
        return known.isEmpty ? nil : (known.filter { $0 }.count, known.count)
    }
    /// The first route that doesn't work, the one View Route opens.
    var failing: Route? { phase == .on ? routes.first { $0.ok == false } : nil }

    /// Under the count: "routes working", "working, 2 not checked" when the count leaves routes out (not checked yet,
    /// or never: an own server with its check off), or "1 route not answering".
    static func healthLine(working: Int, total: Int, unchecked: Int = 0) -> String {
        let down = total - working
        if down > 0 { return "\(down) route\(down == 1 ? "" : "s") not answering" }
        return unchecked > 0 ? "working, \(unchecked) not checked" : "route\(total == 1 ? "" : "s") working"
    }
    /// Routes listed while connected whose health isn't known, which the count leaves out.
    var unchecked: Int { phase == .on ? routes.filter { $0.ok == nil }.count : 0 }

    /// The profile in use and Tailscale, under the status: "Home · Tailscale on". Nil when there is neither.
    var statusLine: String? {
        let line = [profile, tailscale].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }
    /// The status line where all of it doesn't fit: the profile alone, else Tailscale.
    var statusShort: String? { profile ?? tailscale }

    /// The link View Route opens: the app's window on that route's page, nothing else.
    static func routeLink(_ id: String) -> URL {
        var c = URLComponents()
        c.scheme = "unbraid"; c.host = "route"; c.path = "/" + id
        return c.url ?? URL(string: "unbraid://open")!
    }
    /// The route a link names, only when it is one of `routes`: a link can come from anywhere, so it only ever selects a
    /// page that exists, and never changes the protection.
    static func linkedRoute(_ url: URL, routes: [String]) -> String? {
        guard url.scheme?.lowercased() == "unbraid", url.host?.lowercased() == "route",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.query == nil, c.fragment == nil else { return nil }
        let id = String(c.path.dropFirst())
        return c.path.hasPrefix("/") && !id.isEmpty && routes.contains(id) ? id : nil
    }

    var connectionTitle: String {
        switch phase {
        case .on: protected.map { $0 ? "Protected" : "Connected" } ?? "Connected"
        case .connecting: "Connecting"
        case .paused: "Paused"
        case .off: "VPN off"
        }
    }

    /// How long the widgets vouch for a snapshot the app hasn't confirmed again: a crash shows within this.
    static let trusted: TimeInterval = 75 * 60
    /// How often a running app confirms the snapshot when nothing changes (its half-hourly totals).
    static let heartbeat: TimeInterval = 30 * 60
    /// Room for a late heartbeat and a reload WidgetKit doesn't run at once.
    static let margin: TimeInterval = 10 * 60
    /// A snapshot dated later than this after now was written before the clock was set back: not vouched for.
    static let skew: TimeInterval = 60

    var fresh: Bool { fresh(at: .now) }
    func fresh(at date: Date) -> Bool { date.timeIntervalSince(updated) < Self.trusted && updated.timeIntervalSince(date) <= Self.skew }

    /// The widgets' timeline from `now`: this snapshot; "Connecting" when a timed pause ends, if the app still vouches
    /// for it then (only a running app resumes it); and the moment it stops vouching, which turns the widget into
    /// "Open unbraid" without waiting for WidgetKit's next reload.
    func timeline(now: Date) -> [(date: Date, snapshot: Snapshot)] {
        var entries = [(date: now, snapshot: self)]
        if phase == .paused, let until = pausedUntil, until > now, fresh(at: until) {
            var resumed = self
            resumed.phase = .connecting
            resumed.failed = nil
            entries.append((until, resumed))
        }
        let stale = updated.addingTimeInterval(Self.trusted)
        if stale > now { entries.append((stale, entries[entries.count - 1].snapshot)) }
        return entries
    }

    /// When the widgets read the snapshot again on their own: the moment it stops being vouched for, which a running
    /// app always forestalls with a reload (see `change`), so this only happens after a crash or a reload request
    /// WidgetKit dropped; hourly once it is stale. Reading more often would spend the reloads a running app needs.
    func nextRead(now: Date) -> Date {
        let stale = updated.addingTimeInterval(Self.trusted)
        return stale > now && fresh(at: now) ? stale : now.addingTimeInterval(60 * 60)
    }

    private static var url: URL? { AppGroup.container?.appending(path: "snapshot.json") }

    static func read() -> Snapshot { url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot() }

    /// Whether `self` should replace `old` at `now`: when the content changed or every 15 minutes to stay fresh. Reload
    /// when the widgets would show something else: the week's totals alone don't count, since a background app's
    /// reloads are rationed (connect and pause must not be the ones throttled). A snapshot the widgets no longer vouched
    /// for ("Open unbraid", after a quit) counts as shown.
    ///
    /// `lastReload` is when the snapshot the app last reloaded the widgets with was written. Whatever they read since is
    /// newer, so they vouch at least until `lastReload + trusted`; the app reloads them before that, while the next
    /// heartbeat may still be up to half an hour away. Idle, that is every second heartbeat, with the totals.
    func change(from old: Snapshot, now: Date, lastReload: Date) -> (write: Bool, reload: Bool) {
        var a = self, b = old
        a.updated = .distantPast; b.updated = .distantPast
        let changed = a != b
        // Totals appearing or vanishing (statistics turned on, off or deleted) are a visible change, not a refresh.
        let weekShown = a.week.isEmpty != b.week.isEmpty
        a.week = []; b.week = []
        let shown = a != b || weekShown || !old.fresh(at: now)
        let due = now.addingTimeInterval(Self.heartbeat + Self.margin) >= lastReload.addingTimeInterval(Self.trusted)
        let write = changed || due || now.timeIntervalSince(old.updated) > 15 * 60 || !old.fresh(at: now)
        return (write, write && (shown || due))
    }

    /// Writes when `change(from:now:lastReload:)` says so. When the widgets should reload, the time the snapshot was
    /// written at (the next `lastReload`).
    func write(lastReload: Date) -> Date? {
        let now = Date.now
        let (write, reload) = change(from: Self.read(), now: now, lastReload: lastReload)
        guard let url = Self.url, write else { return nil }
        var current = self
        current.updated = now
        return Self.save(current, to: url) && reload ? now : nil
    }

    /// After a quit: the same content, no longer vouched for, so the widgets offer "Open unbraid" instead of buttons
    /// that only a running app can act on.
    static func markStale() {
        var s = read()
        guard let url, s.updated != .distantPast else { return }
        s.updated = .distantPast
        _ = save(s, to: url)
    }

    private static func save(_ s: Snapshot, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(s) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
