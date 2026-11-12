import Foundation
import Observation
import SQLite3

// Local traffic statistics. Off until the user agrees; then the engine's per-connection byte counts are
// summed per hour, day, app and exit into ~/Library/Application Support/unbraid/stats.db. Never uploaded; no
// destinations kept. The maths is in App/Core/StatsMath.swift; this file is the SQLite file, the engine subscription
// and the main-actor face the views read. Stats.kt, ported.

/// What the writer needs from the main actor, read when it needs it (so it matches what the engine runs).
nonisolated struct StatsContext: Sendable {
    var setup: Setup
    /// What the engine runs (not the one being edited): traffic is attributed against it.
    var running: Setup
    var tags: [String: String]
    /// Exit id → name of the VPN server it uses.
    var servers: [String: String]
    /// "ts:<ip>" → name of a Tailscale exit node.
    var tsNames: [String: String]
    var testExit: String?
    var testTag: String?
    var testTags: [String: String]
    /// Command-line tools the user routes, by path.
    var tools: Set<String>
    var own: String

    /// The exit a running speed test measures through `tag`, so its traffic is counted there.
    func exitOn(_ tag: String?) -> String? { guard let tag else { return nil }; return testTags[tag] ?? (tag == testTag ? testExit : nil) }
    var liveExits: Set<String> {
        Set(setup.routes.map(\.id) + running.activeRoutes.map(\.id)
            + (running.home.tailscale || running.home.wg != nil ? [StatsMath.home] : []) + [testExit].compactMap { $0 } + Array(testTags.values))
    }
}

/// The main-actor face: what the views read and the lifecycle calls.
@Observable
final class Stats {
    static let shared = Stats()
    static let home = StatsMath.home

    /// The last 60 seconds per exit; moves only while `watching`.
    fileprivate(set) var live = Live() { didSet { liveAt = Date.now.timeIntervalSinceReferenceDate } }
    /// When the last reading arrived, for the graphs that keep moving between readings.
    @ObservationIgnored private(set) var liveAt = 0.0
    /// A statistics view is on screen (in a visible window, frontmost or not): sample every second (live chart),
    /// else every 15 s.
    private(set) var watching = false {
        didSet { if oldValue != watching { let v = watching; enqueue { await StatsWriter.shared.setWatching(v) } } }
    }
    @ObservationIgnored private var visibleViews: Set<UUID> = []
    @ObservationIgnored private var cooling: Task<Void, Never>?
    #if DEBUG
    /// How many views say they are on screen (tools/debug.sh watchers).
    var visibleCount: Int { visibleViews.count }
    #endif
    func watch(_ id: UUID, visible: Bool) {
        if visible { visibleViews.insert(id) } else { visibleViews.remove(id) }
        cooling?.cancel()
        cooling = nil
        if !visibleViews.isEmpty { watching = true; return }
        // Every change of rate resubscribes and replays the open connections: a glance at the menu bar panel or a
        // switch between windows keeps the 1 s rate for half a minute rather than flipping twice.
        cooling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, visibleViews.isEmpty else { return }
            watching = false
        }
    }
    /// Bumped by every delete: a speed test started before one must not write its result after it.
    private(set) var epoch = 0

    private var tail: Task<Void, Never>?
    private var changes: AsyncStream<(VpnState.Phase, Bool)>.Continuation?

    private init() {
        Task { for await l in StatsWriter.shared.liveStream { live = l } }
    }

    /// Everything the writer is told runs in order, like the one worker thread of the Kotlin.
    @discardableResult
    private func enqueue(_ f: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let prev = tail
        let t = Task { await prev?.value; await f() }
        tail = t
        return t
    }

    /// Statistics follow the connection while they're on: sessions from the phase, traffic from the running engine.
    /// Call once at launch.
    func follow() {
        guard changes == nil else { return }
        let (stream, cont) = AsyncStream<(VpnState.Phase, Bool)>.makeStream()
        changes = cont
        Task { for await (p, on) in stream { await StatsWriter.shared.apply(phase: on ? p : .off, recording: on) } }
        Task { await StatsWriter.shared.pruneAtLaunch() }
        track()
    }

    private var lastSent: (VpnState.Phase, Bool)?

    private func track() {
        let now = withObservationTracking { (Connection.shared.state.phase, Store.shared.setup.prefs.stats) } onChange: {
            Task { @MainActor [weak self] in self?.track() }
        }
        guard lastSent?.0 != now.0 || lastSent?.1 != now.1 else { return }
        lastSent = now
        changes?.yield(now)
    }

    fileprivate func context() -> StatsContext {
        let c = Connection.shared, t = SpeedTest.shared
        let setup = Store.shared.setup
        let running = c.running ?? setup
        let testExit = t.testing ? t.run?.exit : nil
        return StatsContext(
            setup: setup, running: running, tags: c.tags, servers: c.state.servers.mapValues(\.name),
            tsNames: Dictionary(c.state.tsExitNodes.map { (SpeedTest.node + $0.ip, $0.name) }) { $1 },
            testExit: testExit, testTag: testExit.map { $0.hasPrefix(SpeedTest.node) ? Compiler.tsTag : c.tags[$0] ?? "" },
            testTags: t.testing ? Dictionary((t.all?.legs ?? []).compactMap { leg in c.tags[leg.exit].map { ($0, leg.exit) } }, uniquingKeysWith: { first, _ in first }) : [:],
            tools: Set((Array(setup.apps.keys) + Array(running.apps.keys)).filter { $0.hasPrefix("/") }),
            own: Bundle.main.bundleIdentifier ?? "app.unbraid")
    }

    /// Where each installed app lives, under its listed path and its real one, for attributing a process to its app.
    fileprivate func bundles() -> [BundleRoot] {
        AppCatalog.shared.apps.filter { !$0.missing }.flatMap { a in
            Set([a.path, URL(fileURLWithPath: a.path).resolvingSymlinksInPath().path]).map { BundleRoot(prefix: $0, id: a.id) }
        }
    }

    #if DEBUG
    /// The smoothness matrix: a month of traffic in the throwaway copy's own file.
    /// `exits`: the route each app's traffic went through, in the order of `apps` (else they take turns).
    func seedForPerf(apps: [String], routes: [String], exits: [String]? = nil) {
        // Kept under each route's statistics id, as real traffic is.
        let setup = Store.shared.setup
        let id = { (r: String) in StatsMath.idOf(r, setup: setup) }
        Task { await StatsWriter.shared.seedForPerf(apps: apps, routes: routes.map(id), exits: exits?.map(id)) }
        var l = Live()
        for r in routes { l.down[r] = (0..<60).map { Float(($0 * 37) % 90) * 100_000 } }
        l.direct = (0..<60).map { Float(($0 * 23) % 70) * 100_000 }
        l.downNow = 2_000_000
        l.upNow = 240_000
        live = l
    }

    func perfPokeLive() {
        var l = live
        for k in l.down.keys { l.down[k]?.append(Float.random(in: 0..<9_000_000)); l.down[k]?.removeFirst() }
        if !l.direct.isEmpty { l.direct.append(Float.random(in: 0..<9_000_000)); l.direct.removeFirst() }
        l.downNow += 1
        live = l
    }
    #endif

    // MARK: Reading

    /// Everything the hub and the sections show for one period: writes pending sums first, so it sees the latest and
    /// never races a delete.
    func view(_ p: Period) async -> StatsView {
        await tail?.value
        return await StatsWriter.shared.view(p, now: .now, context: context())
    }

    /// Small consumers avoid exits, tests and the 91-day session heatmap.
    func appTotals(_ p: Period) async -> [String: Int64] { await tail?.value; return await StatsWriter.shared.appTotals(p, now: .now) }
    func week() async -> [Snapshot.Day] { await tail?.value; return await StatsWriter.shared.week(now: .now) }

    /// Spans overlapping [from, to) ms: protected and paused time. The open span counts up to now.
    func spans(from: Int64, to: Int64) async -> [Span] { await tail?.value; return await StatsWriter.shared.spans(from, to) }

    /// Bytes per VPN server of one exit over days [from, to], largest first.
    func servers(exit: String, from: Int64, to: Int64) async -> [ServerBytes] { await tail?.value; return await StatsWriter.shared.servers(exit, from, to) }

    /// Saved speed tests, newest first.
    func tests() async -> [TestResult] { await tail?.value; return await StatsWriter.shared.tests() }

    /// The stats file's size in bytes; 0 if there is none.
    func size() -> Int64 { StatsWriter.size() }

    // MARK: Writing

    /// Erases everything: the file and its journal. Recording, if on, carries on from now.
    func delete() async {
        epoch += 1
        await enqueue { await StatsWriter.shared.delete() }.value
    }

    func saveTest(_ t: TestResult, startedIn: Int, attempt: Int) {
        enqueue { await StatsWriter.shared.saveTest(t, startedIn: startedIn, attempt: attempt) }
    }

    func saveTests(_ tests: [TestResult], startedIn: Int, attempt: Int) {
        enqueue { await StatsWriter.shared.saveTests(tests, startedIn: startedIn, attempt: attempt) }
    }

    /// Quitting: the open session up to now and the sums not yet written, after everything queued before.
    func close() async {
        await enqueue { await StatsWriter.shared.close() }.value
    }
}

struct BundleRoot: Sendable { var prefix: String; var id: String }

// MARK: - The writer

/// One serial owner of the file, the pending sums, the sessions and the engine subscription: engine callbacks only
/// copy what they need into `post`, lifecycle calls are actor calls, and a callback from a stopped or deleted
/// recording (an older `gen`) is dropped. Only the callback mailbox needs a lock.
actor StatsWriter {
    static let shared = StatsWriter()

    static let dir = URL.applicationSupportDirectory.appending(path: "unbraid")
    static let file = dir.appending(path: "stats.db")
    private static let day: Int64 = 24 * StatsMath.hour

    nonisolated let liveStream: AsyncStream<Live>
    private nonisolated let liveOut: AsyncStream<Live>.Continuation
    private nonisolated let post = StatsInbox()
    private var pump: Task<Void, Never>?

    private var database: SQL?
    private var recording = false
    private var pending = Pending()
    private var prunedDay: Int64 = -1
    private var epoch = 0
    /// The open span: when it began and whether it is a pause.
    private var open: (start: Int64, paused: Bool)?
    /// Keeps a paused span's end current: there is no engine subscription to do it while paused.
    private var ticker: Task<Void, Never>?

    // The engine subscription (Collector in Stats.kt).
    private var gen = 0
    private var client: EngineLink.Stream?
    private var interval: Int64 = 0
    private var watching = false
    private var ledger = Ledger()
    private var window = LiveWindow()
    private var live = Live()
    private var lastFlush: Int64 = 0
    private var lastTick: Int64 = 0
    /// When the engine last spoke (ms), to count what began while a resubscription was under way.
    private var heard: Int64 = 0
    private var retries = 0
    private var owners: [String: String] = [:]
    private var bundles: [BundleRoot] = []
    private var bundlesAt: Int64 = 0

    private var fast: Bool { interval == 1_000_000_000 }

    init() {
        (liveStream, liveOut) = AsyncStream.makeStream(of: Live.self, bufferingPolicy: .bufferingNewest(1))
    }

    private static func wall() -> Int64 { Int64(Date.now.timeIntervalSince1970 * 1000) }

    #if DEBUG
    func seedForPerf(apps: [String], routes: [String], exits: [String]? = nil) {
        guard let d = try? db() else { return }
        let today = StatsMath.dayOf(Int64(Date.now.timeIntervalSince1970 * 1000))
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        for offset in 0..<30 {
            let day = today - Int64(offset)
            for (i, a) in apps.enumerated() {
                let exit = exits?[i] ?? routes[i % routes.count]
                try? d.run("INSERT OR REPLACE INTO daily VALUES(?,?,?,?,?)", [day, a, exit, Int64((i + 1) * 40_000 + offset * 900), Int64((i + 1) * 1_500_000)])
            }
            for (i, r) in routes.enumerated() {
                try? d.run("INSERT OR REPLACE INTO server VALUES(?,?,?,?)", [day, r, "srv-\(i)", Int64((i + 1) * 90_000_000)])
                for h in 0..<24 { try? d.run("INSERT OR REPLACE INTO hourly VALUES(?,?,?,?)", [day * 24 + Int64(h), r, Int64(h * 2_000), Int64(h * 3_000_000)]) }
            }
            try? d.run("INSERT OR REPLACE INTO span VALUES(?,?,?)", [now - Int64(offset) * 86_400_000 - 7_200_000, now - Int64(offset) * 86_400_000, false])
        }
    }
    #endif

    // MARK: Lifecycle

    /// On every change of phase or of the setting: sessions follow the phase, traffic the running engine.
    func apply(phase p: VpnState.Phase, recording on: Bool) async {
        recording = on
        let now = Self.wall()
        if let (start, paused) = open { writeSpan(start, now, paused) }
        open = on ? (p == .on ? (now, false) : p == .paused ? (now, true) : nil) : nil
        ticker?.cancel()
        ticker = nil
        if open?.paused == true {
            ticker = Task {
                while true {
                    try? await Task.sleep(for: .seconds(30))
                    if Task.isCancelled { return }
                    checkpoint()
                }
            }
        }
        if on && p == .on {
            await startCollector()
            prune()
        } else {
            stopCollector()
            await flush(force: true)
        }
    }

    /// Quitting: the open span ends now in the file (it stays open here, in case the quit is cancelled) and the
    /// pending sums are written.
    func close() async {
        checkpoint()
        await flush(force: true)
    }

    func setWatching(_ v: Bool) async {
        guard watching != v else { return }
        watching = v
        if client != nil { await startCollector(retime: true) } // a new sampling rate needs a new subscription
    }

    /// Erases everything: the file and its journal. Recording, if on, carries on from now.
    func delete() async {
        epoch += 1
        let wasOn = client != nil
        stopCollector()
        pending.clear()
        open = open.map { (Self.wall(), $0.paused) }
        database = nil
        for suffix in ["", "-journal", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: Self.file.path + suffix) }
        if wasOn && recording { await startCollector() }
    }

    func saveTest(_ t: TestResult, startedIn: Int, attempt: Int) async {
        await saveTests([t], startedIn: startedIn, attempt: attempt)
    }

    func saveTests(_ tests: [TestResult], startedIn: Int, attempt: Int) async {
        guard recording, startedIn == epoch else { return }
        let ctx = await Stats.shared.context()
        guard recording, startedIn == epoch else { return }
        if tests.contains(where: { $0.exit.contains("@") && StatsMath.idOf(StatsMath.routeId($0.exit), setup: ctx.running) != $0.exit }) {
            await SpeedTest.shared.routeChanged(attempt)
            return
        }
        do {
            let d = try db()
            try d.transaction {
                for t in tests {
                    try d.run("INSERT OR REPLACE INTO test VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", [t.at, t.exit, t.via, t.server, t.ip, t.down, t.up, t.idle, t.busyDown, t.busyUp, t.grp.map { $0 as any SQLValue } ?? Null(), t.n])
                }
                try labelExits(d, tests.map(\.exit), ctx)
            }
        } catch { fail(error) }
        prune()
    }

    /// The database with its write-ahead log, where recent writes sit until a checkpoint.
    nonisolated static func size() -> Int64 {
        ["", "-wal", "-shm"].reduce(0) { sum, suffix in
            sum + (((try? FileManager.default.attributesOfItem(atPath: Self.file.path + suffix)[.size]) as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// SQLite's own result code for its failures: a Swift struct error bridges to NSError code 1 whatever the cause.
    private func fail(_ e: Error) { Log.error("stats", facts: "\(type(of: e)) \((e as? SQL.Failure).map { Int($0.code) } ?? (e as NSError).code)") }

    // MARK: The file

    private static let schema = [
        "CREATE TABLE IF NOT EXISTS hourly(h INTEGER, exit TEXT, up INTEGER, down INTEGER, PRIMARY KEY(h, exit)) WITHOUT ROWID",
        "CREATE TABLE IF NOT EXISTS daily(d INTEGER, app TEXT, exit TEXT, up INTEGER, down INTEGER, PRIMARY KEY(d, app, exit)) WITHOUT ROWID",
        "CREATE TABLE IF NOT EXISTS server(d INTEGER, exit TEXT, name TEXT, bytes INTEGER, PRIMARY KEY(d, exit, name)) WITHOUT ROWID",
        "CREATE TABLE IF NOT EXISTS peak(d INTEGER, exit TEXT, bps INTEGER, at INTEGER, up INTEGER NOT NULL DEFAULT 0, up_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(d, exit)) WITHOUT ROWID",
        "CREATE TABLE IF NOT EXISTS span(start INTEGER PRIMARY KEY, end INTEGER, paused INTEGER)",
        "CREATE TABLE IF NOT EXISTS exit(id TEXT PRIMARY KEY, code TEXT, name TEXT, hue INTEGER, via TEXT)",
        "CREATE TABLE IF NOT EXISTS test(at INTEGER PRIMARY KEY, exit TEXT, via TEXT, server TEXT, ip TEXT, down INTEGER, up INTEGER, idle INTEGER, busy_down INTEGER, busy_up INTEGER, grp INTEGER, n INTEGER NOT NULL DEFAULT 0)",
    ]

    /// The open file, created on first use. Version 2: peaks keep upload apart (bps/at stay the download's).
    private func db() throws -> SQL {
        if let database { return database }
        try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        guard let d = SQL(path: Self.file.path) else { throw Fail("The statistics file can't be opened") }
        // It names apps and exits: readable by this user only, like the sealed files.
        for suffix in ["", "-wal", "-shm"] { chmod(Self.file.path + suffix, 0o600) }
        // Sums are written every half minute while connected: a write-ahead log turns each into one append rather than
        // a journal created, synced and deleted. The -wal and -shm files take the database's own permissions.
        _ = try? d.all("PRAGMA journal_mode=WAL") { $0.text(0) }
        try? d.run("PRAGMA synchronous=NORMAL")
        // The log holds recent rows while the file is open: kept out of backups like the database itself.
        for suffix in ["-wal", "-shm"] {
            var u = URL(fileURLWithPath: Self.file.path + suffix)
            try? u.setResourceValues({ var v = URLResourceValues(); v.isExcludedFromBackup = true; return v }())
        }
        let version = try d.all("PRAGMA user_version") { Int($0.int(0)) }.first ?? 0
        try d.transaction {
            if version == 0 { for s in Self.schema { try d.run(s) } }
            else if version < 2 { for s in ["ALTER TABLE peak ADD COLUMN up INTEGER NOT NULL DEFAULT 0", "ALTER TABLE peak ADD COLUMN up_at INTEGER NOT NULL DEFAULT 0"] { try d.run(s) } }
            if version > 0 && version < 3 { for sql in StatsMath.testMigration { try d.run(sql) } }
            if version < 3 { try d.run("PRAGMA user_version = 3") }
        }
        var url = Self.file
        try? url.setResourceValues({ var v = URLResourceValues(); v.isExcludedFromBackup = true; return v }())
        database = d
        return d
    }

    private func rows<T>(_ sql: String, _ args: [any SQLValue] = [], _ read: (SQL.Row) -> T) -> [T] {
        guard FileManager.default.fileExists(atPath: Self.file.path) else { return [] }
        return (try? db().all(sql, args, read)) ?? []
    }

    /// Pending sums and the exits' labels in one transaction.
    private func flush(force: Bool = false) async {
        guard (recording || force), !pending.isEmpty else { return }
        let ctx = await Stats.shared.context()
        guard !pending.isEmpty else { return }
        do {
            let d = try db()
            try d.transaction {
                for (k, s) in pending.hourly { try d.run("INSERT INTO hourly VALUES(?,?,?,?) ON CONFLICT(h, exit) DO UPDATE SET up=up+excluded.up, down=down+excluded.down", [k.h, k.exit, s.up, s.down]) }
                for (k, s) in pending.daily { try d.run("INSERT INTO daily VALUES(?,?,?,?,?) ON CONFLICT(d, app, exit) DO UPDATE SET up=up+excluded.up, down=down+excluded.down", [k.d, k.app, k.exit, s.up, s.down]) }
                for (k, b) in pending.servers { try d.run("INSERT INTO server VALUES(?,?,?,?) ON CONFLICT(d, exit, name) DO UPDATE SET bytes=bytes+excluded.bytes", [k.d, k.exit, k.name, b]) }
                try labelExits(d, pending.exits, ctx)
            }
            pending.clear()
            maybePrune()
        } catch { fail(error) }
    }

    /// Exits keep the label they had when used, so history survives renames and removed routes: the one captured
    /// when their traffic was counted stands in for a route removed since.
    private func labelExits(_ d: SQL, _ ids: [String], _ ctx: StatsContext) throws {
        for id in Set(ids) {
            let captured = pending.labels[id]
            // Read only when nothing better is at hand: a route gone from the edited setup keeps its stored name.
            var stored: StoredExit?
            if captured == nil, StatsMath.capturedLabel(id, setup: ctx.setup, tsNames: ctx.tsNames) == nil {
                stored = try d.all("SELECT code, name, hue, via FROM exit WHERE id = ?", [id]) {
                    StoredExit(id: id, code: $0.text(0), name: $0.text(1), hue: Int($0.int(2)), via: $0.text(3))
                }.first
            }
            guard let l = StatsMath.exitLabel(id, setup: ctx.setup, running: ctx.running, tsNames: ctx.tsNames, captured: captured, stored: stored) else { continue }
            try d.run("INSERT OR REPLACE INTO exit(id, code, name, hue, via) VALUES(?,?,?,?,?)", [id, l.code, l.name, l.hue, l.via])
        }
    }

    /// Retention runs once a day whatever else happens: on writes and before reads.
    private func maybePrune() {
        let d = StatsMath.dayOf(Self.wall())
        if d != prunedDay { prunedDay = d; prune() }
    }

    /// Keeps what the consent text promises, whatever else happens: hourly 8 days, daily ~13 months, sessions 400
    /// days, the last 100 speed tests.
    func pruneAtLaunch() { prune() }

    private func prune() {
        guard FileManager.default.fileExists(atPath: Self.file.path), let d = try? db() else { return }
        let now = Self.wall()
        for (sql, args) in StatsMath.pruneCommands(now: now, today: StatsMath.dayOf(now)) { try? d.run(sql, args) }
    }

    // MARK: Sessions

    private func writeSpan(_ start: Int64, _ end: Int64, _ paused: Bool) {
        do { try db().run("INSERT OR REPLACE INTO span VALUES(?,?,?)", [start, end, paused]) } catch { fail(error) }
    }

    /// Keeps the open span's end current, so a killed process loses at most half a minute.
    private func checkpoint() { if recording, let (s, p) = open { writeSpan(s, Self.wall(), p) } }

    // MARK: Reading

    func view(_ p: Period, now: Date, context: StatsContext) async -> StatsView {
        await flush()
        maybePrune()
        let source = StatsSource(
            exits: { Dictionary(self.rows("SELECT id, code, name, hue, via FROM exit") { StoredExit(id: $0.text(0), code: $0.text(1), name: $0.text(2), hue: Int($0.int(3)), via: $0.text(4)) }.map { ($0.id, $0) }) { $1 } },
            perDay: { from, to in
                self.dayRows(from, to)
            },
            perHour: { day in
                Self.group(self.rows("SELECT h, exit, up, down FROM hourly WHERE h BETWEEN ? AND ?", [day * 24, day * 24 + 23]) { ($0.int(0) - day * 24, $0.text(1), Traffic(up: $0.int(2), down: $0.int(3))) })
            },
            apps: { from, to in
                self.rows("SELECT app, exit, SUM(up)+SUM(down) b FROM daily WHERE d BETWEEN ? AND ? GROUP BY app, exit ORDER BY b DESC", [from, to]) { AppBytes(app: $0.text(0), exit: $0.text(1), bytes: $0.int(2)) }
            },
            peaks: { from, to in
                self.rows("SELECT d, exit, bps, at, up, up_at FROM peak WHERE d BETWEEN ? AND ?", [from, to]) { ($0.int(0), $0.text(1), Peak(down: $0.int(2), downAt: $0.int(3), up: $0.int(4), upAt: $0.int(5))) }
            },
            tests: { self.testRows() },
            spans: { self.spanRows($0, $1) })
        return StatsMath.view(p, now: now, setup: context.setup, source: source)
    }

    func appTotals(_ p: Period, now: Date) async -> [String: Int64] {
        await flush()
        maybePrune()
        let (from, to) = p.range(today: StatsMath.dayOf(Int64(now.timeIntervalSince1970 * 1000)))
        return Dictionary(rows("SELECT app, SUM(up)+SUM(down) FROM daily WHERE d BETWEEN ? AND ? GROUP BY app", [from, to]) { ($0.text(0), $0.int(1)) }) { $1 }
    }

    func week(now: Date) async -> [Snapshot.Day] {
        await flush()
        maybePrune()
        let (from, to) = Period.week.range(today: StatsMath.dayOf(Int64(now.timeIntervalSince1970 * 1000)))
        let days = dayRows(from, to)
        // Per route, whatever carried it: the widgets and a route's page show a route's week, and its history is
        // recorded under one id per provider, place or server it used.
        return (from...to).map { d in
            Snapshot.Day(date: StatsMath.date(ofDay: d), bytes: (days[d] ?? [:]).reduce(into: [:]) { $0[StatsMath.routeId($1.key), default: 0] += $1.value.total })
        }
    }

    private func dayRows(_ from: Int64, _ to: Int64) -> [Int64: [String: Traffic]] {
        Self.group(rows("SELECT d, exit, SUM(up), SUM(down) FROM daily WHERE d BETWEEN ? AND ? GROUP BY d, exit", [from, to]) { ($0.int(0), $0.text(1), Traffic(up: $0.int(2), down: $0.int(3))) })
    }

    func spans(_ from: Int64, _ to: Int64) async -> [Span] {
        await flush()
        maybePrune()
        return spanRows(from, to)
    }

    func servers(_ exit: String, _ from: Int64, _ to: Int64) async -> [ServerBytes] {
        await flush()
        maybePrune()
        return rows("SELECT name, SUM(bytes) b FROM server WHERE exit = ? AND d BETWEEN ? AND ? GROUP BY name ORDER BY b DESC", [exit, from, to]) { ServerBytes(name: $0.text(0), bytes: $0.int(1)) }
    }

    func tests() async -> [TestResult] {
        await flush()
        maybePrune()
        return testRows()
    }

    private func testRows() -> [TestResult] {
        rows("SELECT at, exit, via, server, ip, down, up, idle, busy_down, busy_up, grp, n FROM test ORDER BY at DESC") {
            TestResult(at: $0.int(0), exit: $0.text(1), via: $0.text(2), server: $0.text(3), ip: $0.text(4), down: $0.int(5), up: $0.int(6),
                       idle: Int($0.int(7)), busyDown: Int($0.int(8)), busyUp: Int($0.int(9)), grp: $0.isNull(10) ? nil : $0.int(10), n: Int($0.int(11)))
        }
    }

    /// Spans overlapping [from, to) ms: start, end, paused. The open span counts up to now.
    private func spanRows(_ from: Int64, _ to: Int64) -> [Span] {
        let stored = rows("SELECT start, end, paused FROM span WHERE end > ? AND start < ? ORDER BY start", [from, to]) { Span(start: $0.int(0), end: $0.int(1), paused: $0.int(2) == 1) }
        let live = open.map { Span(start: $0.start, end: Self.wall(), paused: $0.paused) }
        return (stored.filter { $0.start != live?.start } + [live].compactMap { $0 })
            .map { Span(start: max($0.start, from), end: min($0.end, to), paused: $0.paused) }.filter { $0.end > $0.start }
    }

    private static func group(_ r: [(Int64, String, Traffic)]) -> [Int64: [String: Traffic]] {
        var out: [Int64: [String: Traffic]] = [:]
        for (k, e, t) in r { out[k, default: [:]][e] = t }
        return out
    }

    // MARK: The engine subscription

    private func startCollector(retime: Bool = false) async {
        let now = Self.wall()
        // A resubscription counts what began since the last one stopped hearing (kept across failed attempts until a
        // replay lands); a fresh start baselines what's open.
        ledger.countFrom = retime && client != nil ? min(ledger.countFrom, (heard > 0 ? heard : now) - 2_000) : .max
        stopClient()
        ledger.startedAt = now
        interval = watching ? 1_000_000_000 : 15_000_000_000
        if pump == nil { pump = Task { [self] in for await _ in self.post.wakeups { while let m = self.post.next() { await handle(m) } } } }
        let g = gen, post = post, interval = interval
        var logs = false
        #if DEBUG
        logs = DebugHooks.engineLog
        #endif
        client = EngineLink.subscribe(Collector(gen: g, post: post), lost: { post.send(.lost(gen: g)) }) {
            $0.subscribeStats(interval: interval, logs: logs, reply: $1)
        }
    }

    /// A subscription the engine dropped (not one we stopped) comes back after a growing pause, the ledger kept.
    private func retry(_ g: Int) {
        let wait = Double(2_000 << min(retries, 5)) / 1000
        let post = post
        Task { try? await Task.sleep(for: .seconds(wait)); post.send(.retry(gen: g)) }
    }

    private func stopClient() {
        client?.close()
        client = nil
        gen += 1
        post.advance(to: gen)
        lastTick = 0; heard = 0; window = LiveWindow(); live = Live()
        liveOut.yield(live)
    }

    /// Recording ends: the ledger goes too (a later start baselines whatever is open then).
    private func stopCollector() { stopClient(); ledger.clear(); retries = 0 }

    private func handle(_ m: StatsMessage) async {
        switch m {
        case .events(let g, let list, let reset):
            guard g == gen else { return }
            heard = Self.wall(); retries = 0
            await apply(list, reset: reset, gen: g)
        case .status(let g):
            guard g == gen else { return }
            let now = Self.wall()
            heard = now
            // Quiet seconds bring no traffic batch: the status tick moves the live chart on by the seconds missed.
            let mono = Ndt7.uptimeMs()
            if lastTick == 0 { lastTick = mono }
            let quiet = mono - lastTick
            if fast && quiet > 1_600 {
                let ctx = await Stats.shared.context()
                guard g == gen else { return }
                sample(now, Int((quiet + 500) / 1000), active: ctx.liveExits)
            }
            if now - lastFlush > 25_000 { lastFlush = now; await flush(); checkpoint() }
        case .lost(let g): if g == gen { retry(g) }
        case .retry(let g): if g == gen && client != nil { retries += 1; await startCollector(retime: true) }
        }
    }

    /// New and Closed carry a connection's totals, Update the change since the last one. A connection's app, exit and
    /// server are fixed when it is first seen, against the configuration the engine actually runs.
    private func apply(_ events: [Ledger.Ev], reset: Bool, gen g: Int) async {
        let ctx = await Stats.shared.context()
        if bundlesAt == 0 || Self.wall() - bundlesAt > (bundles.isEmpty ? 30_000 : 300_000) {
            bundles = await Stats.shared.bundles()
            bundlesAt = Self.wall()
            owners.removeAll(keepingCapacity: true)
        }
        guard g == gen else { return }
        let now = Self.wall()
        let (counted, batch) = ledger.apply(events, reset: reset) { e in
            let app = e.own ? ctx.own : appOf(e.path, ctx)
            let exit = (e.own ? ctx.exitOn(e.tag) : nil) ?? StatsMath.exitOf(tag: e.tag, app: app, setup: ctx.running, tags: ctx.tags)
            return Ledger.Conn(app: app, exit: StatsMath.idOf(exit, setup: ctx.running), server: ctx.servers[exit])
        }
        for c in counted {
            pending.add(now: now, app: c.app, exit: c.exit, server: c.server, up: c.up, down: c.down)
            if pending.labels[c.exit] == nil { pending.labels[c.exit] = StatsMath.capturedLabel(c.exit, setup: ctx.setup, tsNames: ctx.tsNames) ?? StatsMath.capturedLabel(c.exit, setup: ctx.running, tsNames: ctx.tsNames) }
            // The live window takes only what flowed just now: never a replay's catch-up or a New's backlog. Direct
            // goes in too, kept apart for its page's graph (see `LiveWindow`).
            guard fast, !reset else { continue }
            if c.app == ctx.own || c.kind == .closed { window.close(exit: StatsMath.routeId(c.exit), up: c.up, down: c.down) }
            else if c.kind == .update { window.update(exit: StatsMath.routeId(c.exit), up: c.up, down: c.down) }
        }
        if fast && batch { sample(now, 1, active: ctx.liveExits) }
    }

    /// Closes the live window: the series and headline come from it. The engine sends one traffic batch per
    /// second with that second's bytes, so a batch is one sample whenever it arrives (timing it here would turn a late
    /// batch and the one after into a spike and a gap). Quiet seconds send none: status ticks fill them in.
    private func sample(_ now: Int64, _ seconds: Int, active: Set<String>) {
        lastTick = Ndt7.uptimeMs()
        live = window.sample(prev: live, seconds: seconds, active: active)
        liveOut.yield(live)
    }

    /// The app key of the process at `path`: the installed app whose bundle holds it, else the bundle it sits in, else
    /// "?" (the engine didn't say, or it's not an app).
    private func appOf(_ path: String, _ ctx: StatsContext) -> String {
        if let k = owners[path] { return k }
        // Paths can include a fresh version directory on every app update. Bound both successful and failed lookups.
        if owners.count >= 4096 { owners.removeAll(keepingCapacity: true) }
        let key = StatsMath.appKey(path: path, bundles: bundles.map { ($0.prefix, $0.id) }, tools: ctx.tools)
            ?? StatsMath.outerApp(path).flatMap { Bundle(path: $0)?.bundleIdentifier } ?? "?"
        owners[path] = key
        return key
    }
}

/// The extension's stream arrives on XPC's queue: decode it and queue it with this subscription's generation.
private nonisolated final class Collector: NSObject, EngineEventsProtocol, @unchecked Sendable {
    private let gen: Int
    private let post: StatsInbox
    init(gen: Int, post: StatsInbox) { self.gen = gen; self.post = post }

    func connectionEvents(_ data: Data) {
        guard let events = try? JSONDecoder().decode(EngineWire.Events.self, from: data) else { return }
        let list = events.list.map { e in
            let c = e.connection
            #if DEBUG
            if e.kind == .new, let c, let t = c.trace { DebugHooks.trace(["conn \(t) proc=\(c.path.isEmpty ? "-" : c.path)"]) }
            #endif
            return Ledger.Ev(
                kind: Self.kind(e.kind), id: e.id, total: c.map { Traffic(up: $0.up, down: $0.down) },
                delta: Traffic(up: e.deltaUp, down: e.deltaDown), path: c?.path ?? "",
                tag: c.flatMap { Self.first($0.chain) }, closed: (c?.closedAt ?? 0) > 0, created: c?.createdAt ?? 0,
                own: c?.inbound == Compiler.probeTag)
        }
        post.send(.events(gen: gen, list, reset: events.reset))
    }

    func status() { post.send(.status(gen: gen)) }
    func lost() { post.send(.lost(gen: gen)) }
    func tailscale(_ data: Data) {}
    func logs(_ lines: [String]) {
        #if DEBUG
        DebugHooks.trace(lines)
        #endif
    }

    private static func kind(_ k: EngineWire.Event.Kind) -> Ledger.Kind {
        switch k {
        case .new: .new
        case .update: .update
        case .closed: .closed
        }
    }

    /// The tunnel the connection left through: the first of its chain that is one of ours.
    private static func first(_ chain: [String]) -> String? {
        chain.first { $0.hasPrefix("r-") || $0.hasPrefix("home-") || $0 == "direct" }
    }
}

// MARK: - SQLite

private nonisolated struct Null: SQLValue { func bind(_ s: OpaquePointer, _ i: Int32) { sqlite3_bind_null(s, i) } }

private nonisolated protocol SQLValue { func bind(_ s: OpaquePointer, _ i: Int32) }
nonisolated extension Int64: SQLValue { func bind(_ s: OpaquePointer, _ i: Int32) { sqlite3_bind_int64(s, i, self) } }
nonisolated extension Int: SQLValue { func bind(_ s: OpaquePointer, _ i: Int32) { sqlite3_bind_int64(s, i, Int64(self)) } }
nonisolated extension Bool: SQLValue { func bind(_ s: OpaquePointer, _ i: Int32) { sqlite3_bind_int64(s, i, self ? 1 : 0) } }
nonisolated extension String: SQLValue {
    func bind(_ s: OpaquePointer, _ i: Int32) { sqlite3_bind_text(s, i, self, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } // SQLITE_TRANSIENT
}

/// The system's SQLite, just enough: statements with bound values, rows, transactions.
private nonisolated final class SQL: @unchecked Sendable { // used only from the StatsWriter actor
    struct Row {
        let s: OpaquePointer
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(s, i) == SQLITE_NULL }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(s, i) }
        func text(_ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
    }
    struct Failure: Error { let code: Int32 }

    private var h: OpaquePointer?

    init?(path: String) {
        guard sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { sqlite3_close(h); return nil }
        sqlite3_busy_timeout(h, 2_000)
    }
    deinit { sqlite3_close(h) }

    private func prepare(_ sql: String, _ args: [any SQLValue]) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &s, nil) == SQLITE_OK, let s else { sqlite3_finalize(s); throw Failure(code: sqlite3_errcode(h)) }
        for (i, a) in args.enumerated() { a.bind(s, Int32(i + 1)) }
        return s
    }

    func run(_ sql: String, _ args: [any SQLValue] = []) throws {
        let s = try prepare(sql, args)
        defer { sqlite3_finalize(s) }
        var r = sqlite3_step(s)
        while r == SQLITE_ROW { r = sqlite3_step(s) }
        guard r == SQLITE_DONE else { throw Failure(code: r) }
    }

    func all<T>(_ sql: String, _ args: [any SQLValue] = [], _ read: (Row) -> T) throws -> [T] {
        let s = try prepare(sql, args)
        defer { sqlite3_finalize(s) }
        var out: [T] = []
        while true {
            let r = sqlite3_step(s)
            if r == SQLITE_ROW { out.append(read(Row(s: s))) } else if r == SQLITE_DONE { return out } else { throw Failure(code: r) }
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN")
        do { try body(); try run("COMMIT") } catch { try? run("ROLLBACK"); throw error }
    }
}
