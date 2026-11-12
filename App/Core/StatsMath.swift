import Foundation
import CryptoKit

// The pure half of local statistics: day and hour numbers, roll-up sums, reconciling the engine's
// per-connection events, the live window, the read model the Stats views draw, and number formatting. No I/O and no
// libbox, so all of it is unit tested (Tests/StatsMathTests.swift). Stats.kt and StatsScreen.kt's View, ported.

// MARK: - Plain values

/// Bytes sent and received.
nonisolated struct Traffic: Hashable, Sendable {
    var up: Int64 = 0
    var down: Int64 = 0
    var total: Int64 { up + down }
    static func + (a: Traffic, b: Traffic) -> Traffic { Traffic(up: a.up + b.up, down: a.down + b.down) }
}

/// The busiest second per day and exit, download and upload apart (bits/s and when, in ms).
nonisolated struct Peak: Hashable, Sendable {
    var down: Int64 = 0
    var downAt: Int64 = 0
    var up: Int64 = 0
    var upAt: Int64 = 0
}

/// One saved speed test: speeds in bits/s, `idle` is the ping in ms.
nonisolated struct TestResult: Hashable, Sendable {
    var at: Int64
    var exit: String
    var via: String
    var server: String
    var ip: String
    var down: Int64
    var up: Int64
    var idle: Int
    var busyDown = 0
    var busyUp = 0
    var grp: Int64? = nil
    var n = 0
}

/// A stretch of protected or paused time, in ms.
nonisolated struct Span: Hashable, Sendable {
    var start: Int64
    var end: Int64
    var paused: Bool
}

/// An exit's label as it was when used, kept so history survives renames and removed routes.
nonisolated struct StoredExit: Hashable, Sendable {
    var id: String
    var code: String
    var name: String
    var hue: Int
    var via: String
}

/// An exit as the views show it: the route's current look if it still exists, else the label it had when used.
nonisolated struct ExitInfo: Hashable, Sendable, Identifiable {
    /// Which colour to draw it in: a route's hue, or one of the neutral tones (route colours mean exits only).
    enum Tone: Hashable, Sendable { case route(Int), neutral, direct, faint }
    var id: String
    var code: String
    var name: String
    var via: String
    var tone: Tone
}

nonisolated struct ExitBytes: Hashable, Sendable { var exit: String; var bytes: Traffic }
nonisolated struct AppBytes: Hashable, Sendable { var app: String; var exit: String; var bytes: Int64 }
nonisolated struct ServerBytes: Hashable, Sendable { var name: String; var bytes: Int64 }

/// The last 60 one-second samples of download per exit (bits/s), plus the current totals; only while watched.
nonisolated struct Live: Hashable, Sendable {
    var down: [String: [Float]] = [:]
    var downNow: Int64 = 0
    var upNow: Int64 = 0
    /// Download through Direct, for its page's graph. Kept apart from `down`, so the totals and the per-exit charts
    /// stay about the exits.
    var direct: [Float] = []
}

nonisolated enum Period: Int, CaseIterable, Sendable {
    case day, week, month
    var label: String { ["Day", "Week", "Month"][rawValue] }

    /// The first and last day number (see `StatsMath.dayOf`) of the period that contains `today`; weeks start on Monday.
    func range(today: Int64) -> (from: Int64, to: Int64) {
        switch self {
        case .day: return (today, today)
        case .week: let monday = today - Int64(StatsMath.weekday(today)); return (monday, monday + 6)
        case .month:
            let c = StatsMath.civil(today)
            let first = today - Int64(c.d - 1)
            return (first, first + Int64(StatsMath.monthLength(c.y, c.m)) - 1)
        }
    }
}

/// What the hub and the sections read for one period (StatsScreen.kt's View), loaded off the main thread.
nonisolated struct StatsView: Sendable, Equatable {
    /// First and last day number of the period.
    var from: Int64
    var to: Int64
    var exits: [String: ExitInfo]
    /// Largest first.
    var byExit: [ExitBytes]
    var total: Traffic
    /// Bars of the usage chart (24 hours, or one per day) and their labels.
    var columns: [[String: Traffic]]
    var labels: [String]
    /// The bar for now.
    var selected: Int
    var apps: [AppBytes]
    /// The period's busiest seconds per exit.
    var peaks: [String: Peak]
    /// Download peaks by day number and exit.
    var dailyPeaks: [Int64: [String: Int64]]
    /// Each exit's fastest speed test in the period (by download).
    var tests: [String: TestResult]
    /// Hours protected per day: this week's seven days, and the last 13 weeks (91 days from `heatStart`; -1 = future).
    var week: [Float]
    var weekMs: Int64
    var heat: [Float]
    /// Day number of the heat map's first day (a Monday).
    var heatStart: Int64

    /// An exit's best speed test in the period.
    func fastestDown(_ exit: String) -> Int64 { tests[exit]?.down ?? 0 }

    /// The five busiest apps on an exit and the remaining apps.
    func appLane(_ exit: String) -> (top: [AppBytes], rest: [AppBytes]) {
        let rows = apps.filter { $0.exit == exit && $0.bytes > 0 }.sorted {
            $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.app < $1.app
        }
        return (Array(rows.prefix(5)), Array(rows.dropFirst(5)))
    }

    /// Bytes per provider, largest first.
    func byProvider() -> [(name: String, bytes: Int64)] {
        var sums: [String: Int64] = [:]
        for e in byExit { sums[StatsMath.providerOf(e.exit, exits[e.exit]), default: 0] += e.bytes.total }
        return sums.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

/// Where `StatsMath.view` reads from: the stats file, in production.
nonisolated struct StatsSource {
    var exits: () -> [String: StoredExit]
    var perDay: (_ from: Int64, _ to: Int64) -> [Int64: [String: Traffic]]
    var perHour: (_ day: Int64) -> [Int64: [String: Traffic]]
    var apps: (_ from: Int64, _ to: Int64) -> [AppBytes]
    var peaks: (_ from: Int64, _ to: Int64) -> [(day: Int64, exit: String, peak: Peak)]
    var tests: () -> [TestResult]
    var spans: (_ fromMs: Int64, _ toMs: Int64) -> [Span]
}

// MARK: - Calendar, formatting, attribution

nonisolated enum StatsMath {
    static let hour: Int64 = 3_600_000
    /// Exit id of the home network (Tailscale and the home WireGuard).
    static let home = "home"
    /// Exit ids of Tailscale exit nodes tested without a route: this and the node's tailnet IP.
    static let tsNode = "ts:"
    static let testsKept = 100

    /// Identifies the carrier without keeping credentials in the statistics file.
    static func idOf(_ route: Route) -> String {
        let l = route.loc
        let parts: [String]
        if let wg = route.wg { parts = ["wg", wg.endpoint, wg.publicKey] }
        else if let ov = route.ovpn {
            parts = ["ovpn"] + ovpnServers(ov.config)
        } else if let ss = route.ss { parts = ["ss", ss.server, String(ss.port)] }
        else if let ts = route.tsExit { parts = ["ts", ts] }
        else { parts = [l.provider, l.countryCode ?? "", l.countryId.map(String.init) ?? "", l.cityId.map(String.init) ?? "", l.city ?? "", l.region ?? "", l.group ?? "", l.proto ?? "", l.pinned?.host ?? ""] }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8))
        return route.id + "@" + digest.prefix(5).map { String(format: "%02x", $0) }.joined()
    }

    /// The server directives outside inline blocks, including the default port and protocol.
    static func ovpnServers(_ config: String) -> [String] {
        var block: String?, remotes: [String] = [], port: String?, proto: String?
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = block { if line == "</\(open)>" { block = nil }; continue }
            if line.hasPrefix("<"), line.hasSuffix(">"), !line.hasPrefix("</") {
                block = String(line.dropFirst().dropLast()); continue
            }
            var words: [String] = [], word = "", quote: Character?, escaped = false, active = false
            for c in line {
                if escaped { word.append(c); escaped = false; active = true; continue }
                if c == "\\" { escaped = true; active = true; continue }
                if let q = quote { if c == q { quote = nil } else { word.append(c) }; continue }
                if c == "\"" || c == "'" { quote = c; active = true; continue }
                if c.isWhitespace { if active { words.append(word); word = ""; active = false }; continue }
                if !active && (c == "#" || c == ";") { break }
                word.append(c); active = true
            }
            if active { words.append(word) }
            guard let first = words.first else { continue }
            let key = first.hasPrefix("--") ? String(first.dropFirst(2)) : first
            let args = Array(words.dropFirst())
            switch key {
            case "remote": remotes.append(args.joined(separator: " "))
            case "port", "rport": port = args.first
            case "proto": proto = args.first
            default: break
            }
        }
        return remotes + [port, proto].compactMap { $0 }
    }

    static func idOf(_ id: String, setup: Setup) -> String { setup.route(id).map(idOf) ?? id }
    static func legacy(_ id: String) -> Bool { !id.contains("@") && id != home && id != DIRECT && !id.hasPrefix(tsNode) }
    static func routeId(_ id: String) -> String { String(id.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)[0]) }
    static func matchingRoute(_ id: String, setup: Setup) -> Route? {
        setup.routes.first { idOf($0) == id }
    }

    static func historyRuns(_ rows: [TestResult]) -> [TestResult] {
        rows.filter { $0.grp == nil || $0.exit == "all" }
    }

    static func bestSingleTest(_ rows: [TestResult]) -> TestResult? {
        rows.lazy.filter { $0.grp == nil }.max { $0.down < $1.down }
    }

    static func historyLegs(_ run: TestResult, rows: [TestResult]) -> [TestResult] {
        guard run.exit == "all", let group = run.grp else { return [] }
        return rows.filter { $0.grp == group && $0.exit != "all" }
    }

    static let testMigration = ["ALTER TABLE test ADD COLUMN grp INTEGER", "ALTER TABLE test ADD COLUMN n INTEGER NOT NULL DEFAULT 0"]

    static func pruneCommands(now: Int64, today: Int64) -> [(String, [Int64])] {
        [
            ("DELETE FROM hourly WHERE h < ?", [(today - 8) * 24]),
            ("DELETE FROM daily WHERE d < ?", [today - 400]),
            ("DELETE FROM server WHERE d < ?", [today - 400]),
            ("DELETE FROM peak", []),
            ("DELETE FROM span WHERE start < ?", [now - 400 * 24 * hour]),
            ("DELETE FROM test WHERE COALESCE(grp, at) NOT IN (SELECT COALESCE(grp, at) FROM test GROUP BY COALESCE(grp, at) HAVING MAX(at) >= ? ORDER BY MAX(at) DESC LIMIT \(testsKept))", [now - 400 * 24 * hour]),
            ("DELETE FROM exit WHERE id NOT IN (SELECT exit FROM hourly UNION SELECT exit FROM daily UNION SELECT exit FROM server UNION SELECT exit FROM test WHERE exit IS NOT NULL)", []),
        ]
    }

    /// Local hour and day numbers, so "today" and "Monday" match the Mac's calendar.
    static func hourOf(_ ms: Int64, tz: TimeZone = .current) -> Int64 {
        (ms + Int64(tz.secondsFromGMT(for: Date(timeIntervalSince1970: Double(ms) / 1000))) * 1000) / hour
    }
    static func dayOf(_ ms: Int64, tz: TimeZone = .current) -> Int64 {
        let h = hourOf(ms, tz: tz)
        return h >= 0 ? h / 24 : -((-h + 23) / 24)
    }

    /// Civil date of a day number (days since 1970-01-01) and back; Howard Hinnant's algorithms.
    static func civil(_ day: Int64) -> (y: Int, m: Int, d: Int) {
        let z = day + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let m = mp < 10 ? mp + 3 : mp - 9
        return (Int(yoe + era * 400 + (m <= 2 ? 1 : 0)), Int(m), Int(doy - (153 * mp + 2) / 5 + 1))
    }
    static func epochDay(_ y: Int, _ m: Int, _ d: Int) -> Int64 {
        let y = Int64(m <= 2 ? y - 1 : y)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * Int64(m > 2 ? m - 3 : m + 9) + 2) / 5 + Int64(d) - 1
        return era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
    }
    /// 0 = Monday … 6 = Sunday (1970-01-01 was a Thursday).
    static func weekday(_ day: Int64) -> Int { Int((((day + 3) % 7) + 7) % 7) }
    static func monthLength(_ y: Int, _ m: Int) -> Int {
        Int(epochDay(m == 12 ? y + 1 : y, m == 12 ? 1 : m + 1, 1) - epochDay(y, m, 1))
    }

    /// Local midnight of a day number, in ms (23 or 25 h days included: ask for the next day's start for the end).
    static func dayStartMs(_ day: Int64, tz: TimeZone = .current) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = civil(day)
        guard let noon = cal.date(from: DateComponents(year: c.y, month: c.m, day: c.d, hour: 12)) else { return day * 86_400_000 }
        return Int64(cal.startOfDay(for: noon).timeIntervalSince1970 * 1000)
    }
    static func date(ofDay day: Int64, tz: TimeZone = .current) -> Date { Date(timeIntervalSince1970: Double(dayStartMs(day, tz: tz)) / 1000) }

    /// Narrow weekday names, Monday first.
    static func dayNames(_ locale: Locale = .current) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = locale
        let s = cal.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { s[($0 + 1) % 7] }
    }

    // MARK: Formatting

    /// Java's `%.nf` rounds half up; C's does not.
    private static func fixed(_ x: Double, _ decimals: Int) -> String {
        let k = pow(10.0, Double(decimals))
        return String(format: "%.\(decimals)f", (x * k).rounded(.toNearestOrAwayFromZero) / k)
    }

    /// A byte count as a number and its unit: 1.2 GB, 340 MB, 12 kB.
    static func bytes(_ b: Int64) -> (String, String) {
        switch Double(b) {
        case 1e9...: (fixed(Double(b) / 1e9, 1), "GB")
        case 1e6...: (fixed(Double(b) / 1e6, 0), "MB")
        default: (fixed(Double(b) / 1e3, 0), "kB")
        }
    }
    static func bytesText(_ b: Int64) -> String { let t = bytes(b); return "\(t.0) \(t.1)" }

    /// A live speed: kbps under 1 Mbps so small transfers don't read as zero.
    static func rate(_ bps: Int64) -> (String, String) {
        if bps >= 1_000_000 { return (mbps(bps), "Mbps") }
        if bps >= 100 { let s = fixed(Double(bps) / 1e3, 0); return (s == "0" ? "0.1" : s, "kbps") }
        return ("0", "kbps")
    }
    static func mbps(_ bps: Int64) -> String {
        let x = Double(bps) / 1e6
        return x < 100 ? fixed(x, 1) : String(Int(x))
    }
    /// 3 h 20 m, or 45 m under an hour.
    static func hm(_ ms: Int64) -> String { let m = ms / 60_000; return m >= 60 ? "\(m / 60) h \(m % 60) m" : "\(m) m" }
    static func hmParts(_ ms: Int64) -> [(String, String)] {
        let m = ms / 60_000
        return m >= 60 ? [("\(m / 60)", "h"), ("\(m % 60)", "m")] : [("\(m)", "m")]
    }

    /// The overline of the hub: "TODAY · 20 OCT", or the week's or month's first and last day: "19–25 OCT", and
    /// "27 OCT – 2 NOV" for a week across two months.
    static func rangeLabel(_ p: Period, today: Int64, tz: TimeZone = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = tz
        f.dateFormat = "d MMM"
        let (a, b) = p.range(today: today)
        let last = f.string(from: date(ofDay: b, tz: tz))
        switch p {
        case .day: return "Today · \(f.string(from: date(ofDay: today, tz: tz)))".uppercased()
        default:
            if civil(a).m != civil(b).m { return "\(f.string(from: date(ofDay: a, tz: tz))) – \(last)".uppercased() }
            return "\(civil(a).d)–\(last)".uppercased()
        }
    }

    /// The label an exit is stored under: its route as edited (a rename wins) or the home network as set up now, else
    /// the label captured when its traffic was counted (the route was removed since), else the one already stored (a
    /// route removed from the edited setup but still running keeps its last name), else the route the engine still runs,
    /// else the home network or a Tailscale node (its name while it is listed). Nil for anything else (Direct, Block, an
    /// unknown id).
    static func exitLabel(_ id: String, setup: Setup, running: Setup, tsNames: [String: String], captured: StoredExit?,
                          stored: StoredExit? = nil) -> StoredExit? {
        if let known = capturedLabel(id, setup: setup, tsNames: tsNames) { return known }
        if let captured { return captured }
        if let stored { return stored }
        if let r = matchingRoute(id, setup: running) { return StoredExit(id: id, code: r.code, name: r.name, hue: r.hue, via: r.source) }
        if id == home { return StoredExit(id: id, code: "HM", name: "Home network", hue: 3, via: "Tailscale") }
        if id.hasPrefix(tsNode) { return StoredExit(id: id, code: "TS", name: String(id.dropFirst(tsNode.count)), hue: -1, via: "Tailscale") }
        return nil
    }

    /// What to capture when an exit's traffic is counted: only what the user set up, the route as edited, the home
    /// network while it is set up (how it is reached now: a stored label must not keep Tailscale after a switch to
    /// WireGuard; once removed, the last one stands; a Tailscale exit node used by a route is not how home is reached)
    /// or a listed Tailscale node. Never the running setup's copy, which may still carry a name the user changed.
    static func capturedLabel(_ id: String, setup: Setup, tsNames: [String: String]) -> StoredExit? {
        if let r = matchingRoute(id, setup: setup) { return StoredExit(id: id, code: r.code, name: r.name, hue: r.hue, via: r.source) }
        if id == home {
            let via = [setup.home.tailscale ? "Tailscale" : nil, setup.home.wg != nil ? "WireGuard" : nil].compactMap { $0 }.joined(separator: " & ")
            return via.isEmpty ? nil : StoredExit(id: id, code: "HM", name: "Home network", hue: 3, via: via)
        }
        if id.hasPrefix(tsNode), let name = tsNames[id] { return StoredExit(id: id, code: "TS", name: name, hue: -1, via: "Tailscale") }
        return nil
    }

    /// Who carried an exit's data: its provider's name, "Own servers" for imported configs (only their protocol is
    /// known), Tailscale, or the home network. Drawn in neutral tones: route colours mean exits only.
    static func providerOf(_ id: String, _ ex: ExitInfo?) -> String {
        if id == DIRECT { return "Direct, no VPN" }
        if id == home { return "Home network" }
        guard let ex, !ex.via.isEmpty else { return "Other" }
        if ["WireGuard", "OpenVPN", "Shadowsocks"].contains(ex.via) { return "Own servers" }
        return Providers.all.first { Providers.short($0.id) == ex.via }?.name ?? ex.via
    }

    // MARK: Attribution

    /// The tunnel tag says which tunnel; when routes share it, the app's own route among them says which route.
    static func exitOf(tag: String?, app: String, setup: Setup, tags: [String: String]) -> String {
        guard let tag, tag != "direct" else { return DIRECT }
        if tag == "home-wg" { return home }
        let candidates = tags.filter { $0.value == tag }.keys.sorted()
        if candidates.isEmpty { return tag == Compiler.tsTag ? home : tag.hasPrefix("r-") ? String(tag.dropFirst(2)) : tag }
        let own = setup.routeOf(app) // the running setup's assignment, not one still being edited
        return candidates.contains(own) ? own : tag == Compiler.tsTag ? home : candidates[0]
    }

    /// The row for programs that run from temporary or cache folders (a build's executable, an npx or updater helper):
    /// each run starts from a new folder, so they are counted together rather than as a new row each time.
    static let otherPrograms = "?other"

    /// The key a process's traffic is counted under: the listed app or added tool that holds it, else the app bundle it
    /// sits in, else its own path (a program outside any app, such as ssh or a background service of macOS, named after
    /// its file), with the home folder written as "~" so the account's name isn't kept, else `otherPrograms` for a
    /// program in a temporary or cache folder, else "?" when the engine didn't say.
    static func ownerKey(path: String, bundles: [(prefix: String, id: String)], tools: Set<String>, toolPatterns: [String: [String]] = [:], home: String = NSHomeDirectory(), bundleId: (String) -> String?) -> String {
        if let k = appKey(path: path, bundles: bundles, tools: tools, toolPatterns: toolPatterns) ?? outerApp(path).flatMap(bundleId) { return k }
        guard path.hasPrefix("/") else { return "?" }
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        let volatile = ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/", "/private/var/tmp/", "/var/tmp/"]
            + (h.count > 1 ? [h + "/Library/Caches/", h + "/.cache/", h + "/.npm/"] : [])
        if volatile.contains(where: { path.hasPrefix($0) }) { return otherPrograms }
        if h.count > 1, path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    /// The path of the outermost app bundle a process lives in ("/Applications/Foo.app" for a helper deep inside it).
    static func outerApp(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// The app key (bundle identifier, or the path of a tool the user added) for the process at `path`: the listed app
    /// whose bundle contains it (longest match), a tool the user routes, else nil. A tool reached through a link
    /// (Homebrew's bin/curl, a /usr/bin shim) runs from the file the link points to, so a process also belongs to the
    /// tool whose routing patterns (`toolPatterns`, as the engine matches them) hold its path; the longest key wins.
    static func appKey(path: String, bundles: [(prefix: String, id: String)], tools: Set<String>, toolPatterns: [String: [String]] = [:]) -> String? {
        if path.isEmpty { return nil }
        if tools.contains(path) { return path }
        if let t = tools.filter({ toolPatterns[$0].map { AppPaths.matches($0, path) } ?? false }).max(by: { $0.count != $1.count ? $0.count < $1.count : $0 > $1 }) { return t }
        var best: (prefix: String, id: String)?
        for b in bundles where path == b.prefix || path.hasPrefix(b.prefix + "/") {
            if best == nil || b.prefix.count > best!.prefix.count { best = b }
        }
        return best?.id
    }

    // MARK: Reading

    /// Everything a period shows, from `source`. `now` fixes "today" and the current hour (StatsScreen.kt `load`).
    static func view(_ p: Period, now: Date, tz: TimeZone = .current, locale: Locale = .current, setup: Setup, source: StatsSource) -> StatsView {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let today = dayOf(nowMs, tz: tz)
        let (from, to) = p.range(today: today)
        let stored = source.exits()
        var exits: [String: ExitInfo] = [:]
        for id in Set(stored.keys).union(setup.routes.map(idOf)).union([DIRECT]) {
            if let r = matchingRoute(id, setup: setup) { exits[id] = ExitInfo(id: id, code: r.code, name: r.name, via: r.source, tone: .route(r.hue)) }
            else if id == DIRECT { exits[id] = ExitInfo(id: id, code: "··", name: "Direct", via: "outside the VPN", tone: .direct) }
            // The home network as reached now, even before its next traffic rewrites the stored label.
            else if id == home, let h = capturedLabel(id, setup: setup, tsNames: [:]) {
                exits[id] = ExitInfo(id: id, code: h.code, name: h.name, via: h.via, tone: .route(h.hue))
            }
            else if let s = stored[id] { exits[id] = ExitInfo(id: id, code: s.code, name: s.name + (legacy(id) ? " (older data)" : ""), via: legacy(id) ? "Unknown (older data)" : s.via, tone: s.hue < 0 ? .neutral : .route(s.hue)) }
            else { exits[id] = ExitInfo(id: id, code: "?", name: id, via: "", tone: .faint) }
        }
        let days = source.perDay(from, to)
        var byExit: [String: Traffic] = [:]
        for m in days.values { for (e, v) in m { byExit[e, default: Traffic()] = byExit[e, default: Traffic()] + v } }
        let columns: [[String: Traffic]]
        let labels: [String]
        if p == .day {
            let hours = source.perHour(from)
            columns = (0..<24).map { hours[Int64($0)] ?? [:] }
            labels = (0..<24).map { $0 % 6 == 0 ? String(format: "%02d", $0) : "" }
        } else {
            let names = dayNames(locale)
            columns = (from...to).map { days[$0] ?? [:] }
            labels = (from...to).map { d in p == .week ? names[weekday(d)] : civil(d).d % 7 == 1 ? "\(civil(d).d)" : "" }
        }
        // The period's busiest seconds per exit, download and upload each at its own best.
        var peaks: [String: Peak] = [:]
        var daily: [Int64: [String: Int64]] = [:]
        for (d, e, v) in source.peaks(from, to) {
            if let b = peaks[e] {
                peaks[e] = Peak(down: max(b.down, v.down), downAt: v.down > b.down ? v.downAt : b.downAt, up: max(b.up, v.up), upAt: v.up > b.up ? v.upAt : b.upAt)
            } else { peaks[e] = v }
            daily[d, default: [:]][e] = v.down
        }
        let a = dayStartMs(from, tz: tz), b = dayStartMs(to + 1, tz: tz)
        var tests: [String: TestResult] = [:]
        for t in source.tests() where t.exit != "all" && t.at >= a && t.at < b {
            if let k = tests[t.exit], k.down >= t.down { continue }
            tests[t.exit] = t
        }
        // Hours protected per day, the last 13 weeks ending this Sunday; this week's days for the hub.
        let heatStart = today - Int64(weekday(today)) - 84
        let spans = source.spans(dayStartMs(heatStart, tz: tz), dayStartMs(today + 1, tz: tz)).filter { !$0.paused }
        let heat: [Float] = (0..<91).map { i in
            let d = heatStart + Int64(i)
            if d > today { return -1 }
            let s = dayStartMs(d, tz: tz), e = dayStartMs(d + 1, tz: tz)
            return Float(spans.reduce(Int64(0)) { $0 + max(0, min($1.end, e) - max($1.start, s)) }) / 3_600_000
        }
        let week = Array(heat.suffix(7))
        let hourNow = Int(((hourOf(nowMs, tz: tz) % 24) + 24) % 24)
        return StatsView(
            from: from, to: to, exits: exits,
            byExit: byExit.sorted { $0.value.total != $1.value.total ? $0.value.total > $1.value.total : $0.key < $1.key }.map { ExitBytes(exit: $0.key, bytes: $0.value) },
            total: byExit.values.reduce(Traffic(), +), columns: columns, labels: labels,
            selected: p == .day ? hourNow : Int(today - from),
            apps: source.apps(from, to), peaks: peaks, dailyPeaks: daily, tests: tests,
            week: week, weekMs: Int64(week.filter { $0 > 0 }.reduce(0, +) * 3_600_000), heat: heat, heatStart: heatStart)
    }
}

// MARK: - Roll-up sums

/// Bytes accepted but not yet written: per hour and exit, per day, app and exit, per day, exit and server, plus the
/// Written in one transaction every ~25 s.
nonisolated struct Pending {
    struct Sum: Hashable { var up: Int64 = 0; var down: Int64 = 0 }
    struct HourKey: Hashable { var h: Int64; var exit: String }
    struct DayKey: Hashable { var d: Int64; var app: String; var exit: String }
    struct ServerKey: Hashable { var d: Int64; var exit: String; var name: String }

    var hourly: [HourKey: Sum] = [:]
    var daily: [DayKey: Sum] = [:]
    var servers: [ServerKey: Int64] = [:]
    /// Each exit's label when its traffic was first counted here, in case its route is gone by the time it is written.
    var labels: [String: StoredExit] = [:]

    var isEmpty: Bool { hourly.isEmpty && daily.isEmpty }
    /// The exits these sums name, for labelling.
    var exits: [String] {
        Array(Set(daily.keys.map(\.exit)).union(hourly.keys.map(\.exit)).union(servers.keys.map(\.exit))).sorted()
    }

    mutating func add(now: Int64, app: String, exit: String, server: String?, up: Int64, down: Int64, tz: TimeZone = .current) {
        if up <= 0 && down <= 0 { return }
        let hk = HourKey(h: StatsMath.hourOf(now, tz: tz), exit: exit)
        hourly[hk, default: Sum()].up += up
        hourly[hk, default: Sum()].down += down
        let d = StatsMath.dayOf(now, tz: tz)
        let dk = DayKey(d: d, app: app, exit: exit)
        daily[dk, default: Sum()].up += up
        daily[dk, default: Sum()].down += down
        if let server { servers[ServerKey(d: d, exit: exit, name: server), default: 0] += up + down }
    }

    mutating func clear() { self = Pending() }
}

// MARK: - Reconciling the engine's events

/// The engine's connection events, reconciled per connection id. New and Closed carry a connection's cumulative totals,
/// Update the change since the last one; a reset replays active and recent connections, which must not count twice.
/// A connection's app, exit and server are fixed when it is first seen (Stats.kt `Collector.apply`).
nonisolated struct Ledger {
    enum Kind: Sendable { case new, update, closed }
    struct Ev: Sendable {
        var kind: Kind
        var id: String
        var total: Traffic?
        var delta: Traffic
        /// Path of the owning process; empty when the engine doesn't know it.
        var path: String
        /// The outbound tag the connection left through.
        var tag: String?
        var closed: Bool
        /// When it began, in ms.
        var created: Int64
        /// Opened through the app's own probe inbound.
        var own: Bool
    }
    struct Conn { var app: String; var exit: String; var server: String?; var up: Int64 = 0; var down: Int64 = 0 }
    /// What an event adds to the sums.
    struct Counted: Equatable, Sendable { var app: String; var exit: String; var server: String?; var up: Int64; var down: Int64; var kind: Kind }

    /// Connections counted up to their close: a replay lists recently closed ones again, and they mustn't count twice.
    struct Recent {
        private var ids = Set<String>()
        private var order: [String] = []
        private var head = 0
        func contains(_ id: String) -> Bool { ids.contains(id) }
        mutating func add(_ id: String) {
            guard ids.insert(id).inserted else { return }
            order.append(id)
            if ids.count > 4096 { ids.remove(order[head]); head += 1 }
            if head > 8192 { order.removeFirst(head); head = 0 }
        }
        var count: Int { ids.count }
    }

    var seen: [String: Conn] = [:]
    var done = Recent()
    /// Connections first seen in a replay are counted in full if they began after this (a resubscription gap), else baselined.
    var countFrom = Int64.max
    /// When this subscription began (ms).
    var startedAt: Int64 = 0

    mutating func clear() { seen = [:]; done = Recent() }

    /// `open` gives a new connection its app, exit and server. Returns what to add to the sums, and whether the batch
    /// held live updates (a traffic batch).
    mutating func apply(_ events: [Ev], reset: Bool, open: (Ev) -> Conn) -> (counted: [Counted], batch: Bool) {
        var out: [Counted] = []
        var replayed = Set<String>()
        var batch = false
        for e in events {
            var up: Int64, down: Int64
            var c: Conn
            switch e.kind {
            case .new:
                guard let t = e.total else { continue }
                replayed.insert(e.id)
                if let known = seen[e.id] {
                    // Replayed and already counted: add only what it did while we weren't listening.
                    up = max(t.up - known.up, 0); down = max(t.down - known.down, 0); c = known
                    if e.closed { seen[e.id] = nil; done.add(e.id) } else { seen[e.id]?.up = t.up; seen[e.id]?.down = t.down }
                } else {
                    if done.contains(e.id) { continue }
                    // Unknown in a replay: born during a resubscription gap → count it; open since before recording → baseline.
                    let fresh = !reset || e.created >= countFrom
                    if e.closed && !fresh { continue }
                    c = open(e)
                    c.up = t.up; c.down = t.down
                    if e.closed { done.add(e.id) } else { seen[e.id] = c }
                    if !fresh { continue }
                    up = t.up; down = t.down
                }
            case .update:
                batch = true
                guard var s = seen[e.id] else { continue }
                up = e.delta.up; down = e.delta.down
                s.up += up; s.down += down
                seen[e.id] = s
                c = s
            case .closed:
                guard let t = e.total else { continue }
                // The engine's event queue can drop a New: a connection born while listening still counts in full.
                if let s = seen.removeValue(forKey: e.id) { c = s }
                else if !done.contains(e.id) && e.created >= startedAt { c = open(e) }
                else { continue }
                done.add(e.id)
                up = max(t.up - c.up, 0); down = max(t.down - c.down, 0)
            }
            out.append(Counted(app: c.app, exit: c.exit, server: c.server, up: up, down: down, kind: e.kind))
        }
        // After a reload the old engine's connections never close: a full replay says which ones still exist.
        if reset { seen = seen.filter { replayed.contains($0.key) }; countFrom = .max }
        return (out, batch)
    }
}

// MARK: - The live window

/// What flowed in the second being collected. The engine sends one traffic batch per second with that second's
/// bytes, so a batch is one sample whenever it arrives.
nonisolated struct LiveWindow {
    private var window: [String: Int64] = [:]
    private var upBy: [String: Int64] = [:]
    private var up: Int64 = 0
    private var closing: [String: Int64] = [:]
    private var closingUp: Int64 = 0
    private var direct: Int64 = 0

    mutating func update(exit: String, up: Int64, down: Int64) {
        if exit == DIRECT { direct += down; return }
        window[exit, default: 0] += down; upBy[exit, default: 0] += up; self.up += up
    }
    mutating func close(exit: String, up: Int64, down: Int64) {
        if exit == DIRECT { direct += down; return }
        closing[exit, default: 0] += down; closingUp += up
    }

    /// Closes the window into a new `Live`, filling quiet seconds and updating the headline.
    mutating func sample(prev: Live, seconds: Int, active: Set<String> = []) -> Live {
        let s = Int64(max(seconds, 1))
        let n = min(Int(s), 60)
        var down: [String: [Float]] = [:]
        for k in Set(prev.down.keys).union(window.keys).union(closing.keys) {
            let bps = (window[k] ?? 0) * 8 / s
            let upBps = (upBy[k] ?? 0) * 8 / s
            let shown = bps + (closing[k] ?? 0) * 8 / s
            down[k] = Array((prev.down[k] ?? [Float](repeating: 0, count: 60)).dropFirst(n)) + [Float](repeating: Float(shown), count: n)
            // Retired exits disappear only after their history drains; keep upload-only and configured exits.
            if !active.contains(k), upBps == 0, down[k]?.allSatisfy({ $0 == 0 }) == true { down[k] = nil }
        }
        let direct = Array((prev.direct.isEmpty ? [Float](repeating: 0, count: 60) : prev.direct).dropFirst(n))
            + [Float](repeating: Float(self.direct * 8 / s), count: n)
        let live = Live(down: down, downNow: Int64(down.values.reduce(0.0) { $0 + Double($1.last ?? 0) }), upNow: (up + closingUp) * 8 / s,
                        direct: direct)
        self = LiveWindow()
        return live
    }
}
