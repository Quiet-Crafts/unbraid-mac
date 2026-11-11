#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: the smoothness matrix. Times what a person does in the real window (switching pages, searching,
/// scrolling, resizing, moving an app, a sheet, background updates) and prints it, so "snappy" is a number before and
/// after a change. tools/perf.sh runs it. It only ever runs in a copy with a bundle id ending in `.perf`, built with no
/// signing (so no VPN entitlement and no keychain) and started with a throwaway home: it can't see the real setup, the
/// real statistics or the tunnel. Nothing here is compiled into a release.
private nonisolated final class MenuBox: @unchecked Sendable {
    let menu: NSMenu
    init(menu: NSMenu) { self.menu = menu }
}

/// Pictures for the README and the website (`SHOTS=<folder>`, or `UNBRAID_PERF_FAKE=1` with HOLD): made-up data only.
/// The apps are macOS's own, at their usual places, so the icons are real and nothing installed here shows.
nonisolated enum PerfFake {
    static let apps: [AppInfo]? = {
        let env = ProcessInfo.processInfo.environment
        guard env["UNBRAID_PERF"] != nil, env["UNBRAID_PERF_SHOTS"] != nil || env["UNBRAID_PERF_FAKE"] != nil else { return nil }
        let s = "/System/Applications/"
        let list: [(String, String, String)] = [
            ("com.apple.Safari", "Safari", "/Applications/Safari.app"), ("com.apple.mail", "Mail", s + "Mail.app"),
            ("com.apple.MobileSMS", "Messages", s + "Messages.app"), ("com.apple.FaceTime", "FaceTime", s + "FaceTime.app"),
            ("com.apple.Maps", "Maps", s + "Maps.app"), ("com.apple.Music", "Music", s + "Music.app"),
            ("com.apple.TV", "TV", s + "TV.app"), ("com.apple.podcasts", "Podcasts", s + "Podcasts.app"),
            ("com.apple.news", "News", s + "News.app"), ("com.apple.Photos", "Photos", s + "Photos.app"),
            ("com.apple.AppStore", "App Store", s + "App Store.app"), ("com.apple.iBooksX", "Books", s + "Books.app"),
            ("com.apple.iCal", "Calendar", s + "Calendar.app"), ("com.apple.Notes", "Notes", s + "Notes.app"),
            ("com.apple.weather", "Weather", s + "Weather.app"), ("com.apple.stocks", "Stocks", s + "Stocks.app"),
            ("com.apple.freeform", "Freeform", s + "Freeform.app"), ("com.apple.Home", "Home", s + "Home.app"),
            ("com.apple.reminders", "Reminders", s + "Reminders.app"), ("com.apple.Preview", "Preview", s + "Preview.app"),
            ("com.apple.QuickTimePlayerX", "QuickTime Player", s + "QuickTime Player.app"),
            ("com.apple.systempreferences", "System Settings", s + "System Settings.app"),
            ("com.apple.Terminal", "Terminal", s + "Utilities/Terminal.app"),
        ]
        return list.map { AppInfo(id: $0.0, name: $0.1, path: $0.2, system: false) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    /// The test copy never reaches a provider: its accounts are made up.
    static func offline() throws {
        if getenv("UNBRAID_PERF") != nil { throw Fail("No network in the test copy") }
    }
}

enum PerfCount {
    nonisolated(unsafe) static var ring = 0
    nonisolated(unsafe) static var curve = 0
}

enum PerfHost {
    static let active: Bool = {
        guard getenv("UNBRAID_PERF") != nil else { return false }
        let home = URL.applicationSupportDirectory.path
        guard Bundle.main.bundleIdentifier?.hasSuffix(".perf") == true, home.contains("/unbraid-perf-home/") else {
            fputs("[Perf] refused: not an isolated copy (\(Bundle.main.bundleIdentifier ?? "?"), \(home))\n", stderr)
            exit(2)
        }
        return true
    }()

    static func start() { Task { await PerfRun().run() } }
}

/// How long the main thread stays awake after a change, and how late the display's ticks land. Awake time is exact; a
/// tick only says when a frame could go out, so it is rounded to the display's refresh.
private final class Meter: NSObject {
    private var observer: CFRunLoopObserver?
    private var awake: Double = 0
    private var link: CADisplayLink?
    private(set) var busy: Double = 0
    private(set) var longest: Double = 0
    private(set) var longestAt: Double = 0
    private(set) var gaps: [Double] = []
    private var lastTick: Double = 0
    private var waiters: [(left: Int, go: CheckedContinuation<Void, Never>)] = []

    static var now: Double { CACurrentMediaTime() * 1000 }

    func start(_ window: NSWindow) {
        awake = Self.now
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue, true, 0) { [weak self] _, activity in
            guard let self else { return }
            if activity == .afterWaiting { awake = Self.now } else {
                let d = Self.now - awake
                busy += d
                if d > longest { longestAt = Self.now }
                longest = max(longest, d)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        observer = o
        let l = window.displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() {
        let t = Self.now
        if lastTick > 0 { gaps.append(t - lastTick) }
        lastTick = t
        for i in waiters.indices { waiters[i].left -= 1 }
        let done = waiters.filter { $0.left <= 0 }
        waiters.removeAll { $0.left <= 0 }
        done.forEach { $0.go.resume() }
    }

    func reset() { busy = 0; longest = 0; gaps = []; lastTick = 0 }
    func frames(_ n: Int) async { await withCheckedContinuation { waiters.append((n, $0)) } }
}

@MainActor private final class PerfRun {
    private struct Result { var name: String; var latency: [Double] = []; var busy: [Double] = []; var stall: [Double] = [] }
    private var results: [Result] = []
    private let meter = Meter()
    private let model = AppModel.shared
    private var window: NSWindow!
    private let only = ProcessInfo.processInfo.environment["UNBRAID_PERF_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    private let sampleName = ProcessInfo.processInfo.environment["UNBRAID_PERF_SAMPLE"]
    private let reps = Int(ProcessInfo.processInfo.environment["UNBRAID_PERF_REPS"] ?? "") ?? 12
    private var appKeys: [String] = []
    private var activity: NSObjectProtocol?

    func run() async {
        activity = ProcessInfo.processInfo.beginActivity(options: [.latencyCritical, .userInitiated, .idleSystemSleepDisabled], reason: "perf matrix")
        if PerfFake.apps != nil { seedShots() } else { seed() }
        NSApp.setActivationPolicy(.regular)
        for _ in 0..<200 where AppDelegate.openWindow == nil { try? await Task.sleep(for: .milliseconds(20)) }
        AppDelegate.openWindow?()
        for _ in 0..<500 {
            window = NSApp.windows.first { $0.canBecomeMain && $0.contentView != nil && $0.title == "unbraid" }
            if window != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard window != nil else { report("no window"); exit(3) }
        window.setFrame(NSRect(x: 80, y: 80, width: 1040, height: 700), display: true)
        window.orderFrontRegardless()
        meter.start(window)
        for _ in 0..<500 where !model.apps.loaded { try? await Task.sleep(for: .milliseconds(10)) }
        await meter.frames(30)
        let launched = Meter.now - ProcessInfo.processStartMs
        report(String(format: "[Perf] launch-to-first-list %.0f ms, apps %d", launched, model.apps.apps.count))
        appKeys = model.apps.apps.map(\.id)
        if PerfFake.apps != nil { seedShotTraffic() } else { await seedTraffic() }
        Connection.shared.perfConnected()
        if let dir = ProcessInfo.processInfo.environment["UNBRAID_PERF_SHOTS"] { await shots(dir); exit(0) }
        // Stay open with the fake data, to try things by hand in this copy.
        if getenv("UNBRAID_PERF_HOLD") != nil {
            NSApp.activate()
            if getenv("UNBRAID_PERF_DARK") != nil { NSApp.appearance = NSAppearance(named: .darkAqua) }
            // Rows already chosen, for trying a multi-row drag from outside: a window in the background can't be made to pick them.
            if let count = ProcessInfo.processInfo.environment["UNBRAID_PERF_SELECT"].flatMap(Int.init) {
                await meter.frames(60)
                for _ in 0..<80 where WeekBytes.shared.bytes.isEmpty { await meter.frames(6) }
                go("traffic"); await meter.frames(20); go("apps"); await meter.frames(40)
                appTable?.selectRowIndexes(IndexSet(0..<count), byExtendingSelection: false)
                await meter.frames(5)
                // Drawn as a window in front draws them, whichever window is in front.
                appTable?.enumerateAvailableRowViews { row, _ in row.isEmphasized = true }
            }
            return
        }
        if getenv("UNBRAID_PERF_CHECKS") != nil, getenv("UNBRAID_PERF_ONLY") == nil { await checks(); exit(0) }
        await bench()
        exit(0)
    }

    // MARK: Fake data

    private func route(_ id: String, _ name: String, _ hue: Int) -> Route {
        var r = Route(id: id)
        r.hue = hue
        r.wg = WgPeer(name: name, privateKey: "a", address: ["10.0.0.2/32"], publicKey: "b", endpoint: "198.51.100.1:51820", allowedIps: ["0.0.0.0/0"])
        return r
    }

    private func seed() {
        Store.shared.update { s in
            s.routes = [route("a", "Netherlands", 210), route("b", "Italy", 130), route("c", "Germany", 40), route("d", "Sweden", 280), route("e", "Home VPS", 340)]
            s.defaultRoute = "a"
            s.prefs.stats = true
        }
        Store.shared.disclosed = true
        Store.shared.termsAccepted = true
        Store.shared.tourPending = false
        model.acceptDisclosureForPerf()
    }

    /// A quarter of the apps on routes of their own, and a month of traffic per app and route for the charts.
    private func seedTraffic() async {
        let routes = ["a", "b", "c", "d", "e"]
        let keys = appKeys
        Store.shared.update { s in
            for (i, k) in keys.enumerated() where i % 4 == 1 { s.apps[k] = i % 3 == 0 ? DIRECT : routes[i % 5] }
        }
        Stats.shared.seedForPerf(apps: keys, routes: routes)
    }

    // MARK: Pictures (SHOTS)

    /// Made-up routes on made-up accounts, as in the Android screenshots: a free Proton default and three other providers.
    private static let shotRoutes: [(id: String, provider: String, code: String, country: String, city: String, hue: Int)] = [
        ("nl", "proton-free", "NL", "Netherlands", "Amsterdam", 0), ("us", "mullvad", "US", "United States", "New York", 4),
        ("it", "nord", "IT", "Italy", "Milan", 2), ("jp", "airvpn", "JP", "Japan", "Tokyo", 1),
    ]
    /// App → route; the rest follow the default.
    private static let shotApps: [String: String] = [
        "com.apple.Safari": "us", "com.apple.TV": "us", "com.apple.podcasts": "us", "com.apple.news": "us", "com.apple.stocks": "us",
        "com.apple.Maps": "it", "com.apple.weather": "it", "com.apple.Music": "jp", "com.apple.iBooksX": "jp",
        "com.apple.Photos": DIRECT, "com.apple.FaceTime": DIRECT,
    ]
    private static let shotCountries: [(code: String, name: String, cities: [String])] = [
        ("AU", "Australia", ["Sydney", "Melbourne"]), ("AT", "Austria", ["Vienna"]), ("BE", "Belgium", ["Brussels"]),
        ("BR", "Brazil", ["São Paulo"]), ("CA", "Canada", ["Toronto", "Montreal", "Vancouver"]), ("DK", "Denmark", ["Copenhagen"]),
        ("FI", "Finland", ["Helsinki"]), ("FR", "France", ["Paris", "Marseille"]), ("DE", "Germany", ["Frankfurt", "Berlin"]),
        ("IE", "Ireland", ["Dublin"]), ("IT", "Italy", ["Milan", "Rome", "Palermo"]), ("JP", "Japan", ["Tokyo", "Osaka"]),
        ("NL", "Netherlands", ["Amsterdam"]), ("NO", "Norway", ["Oslo"]), ("PL", "Poland", ["Warsaw"]), ("PT", "Portugal", ["Lisbon"]),
        ("SG", "Singapore", ["Singapore"]), ("ES", "Spain", ["Madrid", "Barcelona"]), ("SE", "Sweden", ["Stockholm", "Gothenburg"]),
        ("CH", "Switzerland", ["Zurich"]), ("GB", "United Kingdom", ["London", "Manchester"]),
        ("US", "United States", ["New York", "Los Angeles", "Chicago", "Miami"]),
    ]
    private static func cityKey(_ code: String, _ city: String) -> String { "\(code.lowercased())-\(city.lowercased().filter(\.isLetter).prefix(3))" }

    private func seedShots() {
        for p in Set(Self.shotRoutes.map(\.provider)) {
            // A free account has a few countries only.
            let list = Self.shotCountries.filter { p != "proton-free" || ["NL", "US", "JP", "PL", "CH"].contains($0.code) }
            model.seedCountriesForPerf(p, list.enumerated().map { i, c in
                Country(id: stableId("\(p)-\(c.code)"), name: c.name, code: c.code, serverCount: 6 + (i * 37 + c.name.count * 11) % 90,
                        cities: c.cities.map { City(id: stableId("\(p)-\(c.code)-\($0)"), name: $0, key: Self.cityKey(c.code, $0)) })
            })
            Store.shared.account(p, "perf-\(p)")
        }
        Store.shared.update { s in
            s.routes = Self.shotRoutes.map { r in
                var route = Route(id: r.id)
                route.hue = r.hue
                route.loc = Location(provider: r.provider, countryId: stableId("\(r.provider)-\(r.code)"), countryCode: r.code, country: r.country,
                                     cityId: stableId("\(r.provider)-\(r.code)-\(r.city)"), city: r.city, region: Self.cityKey(r.code, r.city))
                return route
            }
            s.defaultRoute = "nl"
            s.apps = Self.shotApps
            s.prefs.stats = true
        }
        Store.shared.disclosed = true
        Store.shared.termsAccepted = true
        Store.shared.tourPending = false
        model.acceptDisclosureForPerf()
    }

    /// A month of traffic: video and music heaviest, each app through its own route.
    private func seedShotTraffic() {
        let heavy = ["com.apple.TV", "com.apple.Music", "com.apple.Safari", "com.apple.Photos", "com.apple.podcasts", "com.apple.Maps", "com.apple.news", "com.apple.AppStore", "com.apple.mail"]
        let keys = appKeys.filter { !heavy.contains($0) } + heavy.reversed()
        let exits = keys.map { Self.shotApps[$0] ?? "nl" }
        Stats.shared.seedForPerf(apps: keys, routes: Self.shotRoutes.map(\.id), exits: exits)
    }

    /// Each page in light and dark, the location picker, and the menu bar panel: the real window as macOS draws it.
    private func shots(_ dir: String) async {
        window.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 760), display: true)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        FrontApp.shared.perfShow(model.apps.app("com.apple.TV"))
        for _ in 0..<80 where WeekBytes.shared.bytes.isEmpty { await meter.frames(6) }
        go("traffic"); await meter.frames(20)
        for (suffix, look) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: look); await meter.frames(30)
            Connection.shared.perfConnected()
            for (name, target) in [("apps", "apps"), ("route", "route:us"), ("traffic", "traffic")] {
                go(target); await meter.frames(90)
                await shoot(window, "\(dir)/\(name)\(suffix).png")
            }
            go("route:it"); await meter.frames(40)
            Presentation.shared.picker = PickerTarget(id: "it"); await meter.frames(120)
            // The window's picture holds its sheet. No blinking caret or focus ring in the search field.
            if let sheet = window.attachedSheet { sheet.makeFirstResponder(nil); await meter.frames(20) } else { report("[Perf] no picker sheet") }
            await shoot(window, "\(dir)/picker\(suffix).png")
            Presentation.shared.picker = nil; await meter.frames(45)
            openPanel(solid: true); await meter.frames(50)
            if let panel { await shoot(panel, "\(dir)/panel\(suffix).png") }
            closePanel()
        }
        NSApp.appearance = nil
        report("[Perf] shots in \(dir)")
    }

    /// With nothing really connected, the copy drifts back to connecting now and then: shown connected, with a fresh
    /// reading on the live graphs, for the picture.
    private func shoot(_ w: NSWindow, _ path: String) async {
        Connection.shared.perfConnected()
        Stats.shared.perfPokeLive()
        await meter.frames(15)
        capture(w, path)
    }

    /// One window as macOS draws it (`cacheDisplay` leaves the glass sidebar blank), without its shadow.
    private func capture(_ w: NSWindow, _ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(w.windowNumber), path]
        try? p.run(); p.waitUntilExit()
    }

    // MARK: The apps list, driven with real events

    private func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        report("[Check] \(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : " \(detail())")")
    }

    private func click(_ view: NSView, at point: NSPoint? = nil, right: Bool = false, modifiers: NSEvent.ModifierFlags = []) {
        let p = view.convert(point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        var events: [NSEvent] = []
        for type in right ? [NSEvent.EventType.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            events.append(e)
        }
        // Straight to the view the window would send it to: this copy never takes the front, so the window wouldn't pass
        // on a click. The release goes first in the queue, since a press waits for it.
        guard let frame = window.contentView?.superview, let hit = frame.hitTest(frame.superview?.convert(p, from: nil) ?? p), events.count == 2 else { return }
        NSApp.postEvent(events[1], atStart: false)
        if right { hit.rightMouseDown(with: events[0]) } else { hit.mouseDown(with: events[0]) }
        while NSApp.nextEvent(matching: [.leftMouseUp, .rightMouseUp], until: .distantPast, inMode: .default, dequeue: true) != nil {}
    }

    /// What a menu holds while it is open; `pick` then chooses an item by title. The click that opens it blocks until it closes.
    private func withMenu(_ open: () -> Void, pick: String? = nil, inside: String? = nil) -> [String] {
        // Written by the observer, which the menu posts to on the main thread while `open` blocks; read after it returns.
        nonisolated(unsafe) var titles: [String] = []
        let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
            guard let found = n.object as? NSMenu else { return }
            nonisolated(unsafe) let menu = found
            titles = menu.items.map { ($0.state == .on ? "✓" : "") + ($0.isSeparatorItem ? "-" : $0.title) }
            // Run by the menu's own event loop: the main queue doesn't always get a turn while a menu is open.
            let box = MenuBox(menu: menu)
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    let menu = box.menu
                    let holder = inside.flatMap { menu.item(withTitle: $0)?.submenu } ?? menu
                    menu.cancelTracking()
                    if let pick, let i = Optional(holder.indexOfItem(withTitle: pick)), i >= 0 { holder.performActionForItem(at: i) }
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        open()
        NotificationCenter.default.removeObserver(token)
        return titles
    }

    private func cell(_ table: NSTableView, _ row: Int, _ column: Int) -> NSView? { table.view(atColumn: column, row: row, makeIfNecessary: true) }
    private func names(_ table: NSTableView) -> [String] {
        (0..<min(table.numberOfRows, 8)).map { cell(table, $0, 0)?.accessibilityLabel() ?? "?" }
    }

    /// A drag of two or more rows has AppKit place each one from background threads, asking every view above it whether
    /// it is flipped. One of our views that answers on the main actor only stops the app there; a single row stays on the
    /// main thread and never shows it. This asks a row's whole way up the same way, without starting a real drag.
    private func checkDragPlacement(_ table: NSTableView) async {
        var chain: [NSView] = []
        var next = cell(table, 0, 0)
        while let view = next { chain.append(view); next = view.superview }
        nonisolated(unsafe) let views = chain
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let flipped = #selector(getter: NSView.isFlipped)
                for view in views {
                    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
                    _ = unsafeBitCast(class_getMethodImplementation(object_getClass(view), flipped), to: Getter.self)(view, flipped)
                }
                done.resume()
            }
        }
        check("a row's views answer a drag off the main thread", chain.count > 3, "only \(chain.count) views")
    }

    /// A selected row in front must tell its drawn cells, or their text stays dark on the accent colour. AppKit only
    /// tells its own cell classes; the window here is never in front, so the row is made to draw as if it were.
    private func checkSelectionReachesCells(_ table: NSTableView) async {
        table.selectRowIndexes([0], byExtendingSelection: false); await meter.frames(3)
        guard let row = table.rowView(atRow: 0, makeIfNecessary: false) else { check("selected row exists", false); return }
        row.isEmphasized = true; await meter.frames(3)
        let styles = row.subviews.map { ($0.value(forKey: "backgroundStyle") as? Int) ?? -1 }
        check("a selected row in front tells its cells", styles.count == 3 && styles.allSatisfy { $0 == NSView.BackgroundStyle.emphasized.rawValue }, "\(styles)")
        row.isEmphasized = false; await meter.frames(3)
        let after = row.subviews.map { ($0.value(forKey: "backgroundStyle") as? Int) ?? -1 }
        check("and that it no longer is", after.allSatisfy { $0 == NSView.BackgroundStyle.normal.rawValue }, "\(after)")
        table.deselectAll(nil); await meter.frames(3)
    }

    private func checks() async {
        // Redraws the list over and over: the text crash below came within a few hundred of these.
        if getenv("UNBRAID_PERF_STRESS") != nil {
            go("apps"); await meter.frames(60)
            for _ in 0..<80 where WeekBytes.shared.bytes.isEmpty { await meter.frames(6) }
            go("traffic"); await meter.frames(20); go("apps"); await meter.frames(40)
            guard let t = appTable else { return }
            for i in 0..<1500 {
                t.reloadData()
                t.enumerateAvailableRowViews { row, _ in row.needsDisplay = true; row.subviews.forEach { $0.needsDisplay = true } }
                await meter.frames(1)
                if i % 300 == 0 { report("[Check] stress \(i)") }
            }
            report("[Check] stress done"); exit(0)
        }
        go("apps"); await meter.frames(60)
        for _ in 0..<80 where WeekBytes.shared.bytes.isEmpty { await meter.frames(6) }
        go("traffic"); await meter.frames(20); go("apps"); await meter.frames(40)
        guard let table = appTable else { check("list exists", false); return }
        let listed = model.apps.listed.count
        check("all apps listed", table.numberOfRows == listed, "\(table.numberOfRows) vs \(listed)")
        check("fixed row height", table.rowHeight == AppsTable.rowHeight && !table.usesAutomaticRowHeights)
        let busiest = cell(table, 0, 2)?.accessibilityLabel() ?? ""
        check("week numbers show, busiest first", busiest != "–" && !busiest.isEmpty, busiest)
        await checkDragPlacement(table)
        await checkSelectionReachesCells(table)

        // Sorting by a column header, then back.
        guard let header = find(NSTableHeaderView.self) else { check("header exists", false); return }
        let nameRect = header.headerRect(ofColumn: 0)
        click(header, at: NSPoint(x: nameRect.midX, y: nameRect.midY)); await meter.frames(10)
        let az = names(table)
        check("App header sorts A to Z", az == az.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "\(az)")
        click(header, at: NSPoint(x: nameRect.midX, y: nameRect.midY)); await meter.frames(10)
        let za = names(table)
        check("App header again reverses", za != az && za == za.sorted { $0.localizedStandardCompare($1) == .orderedDescending }, "\(za)")
        let routeRect = header.headerRect(ofColumn: 1)
        click(header, at: NSPoint(x: routeRect.midX, y: routeRect.midY)); await meter.frames(10)
        check("Route header sorts", table.sortDescriptors.first?.key == "route", "\(table.sortDescriptors)")
        let weekRect = header.headerRect(ofColumn: 2)
        click(header, at: NSPoint(x: weekRect.midX, y: weekRect.midY)); await meter.frames(10)
        click(header, at: NSPoint(x: weekRect.midX, y: weekRect.midY)); await meter.frames(10)
        check("This Week header sorts", table.sortDescriptors.first?.key == "week", "\(table.sortDescriptors)")

        // The route chip's menu, its choice, and Undo.
        let first = model.apps.listed.first { app in names(table).first == app.name }?.id ?? ""
        guard let chip = cell(table, 0, 1) else { check("route cell", false); return }
        let before = model.setup.apps[first]
        var titles: [String] = withMenu({ click(chip, at: NSPoint(x: 30, y: chip.bounds.midY)) }, pick: "Sweden")
        await meter.frames(10)
        check("chip opens the route menu", titles.contains { $0.hasSuffix("· Default") } && titles.contains("Direct") && titles.contains("Blocked") && titles.contains("New Route…"), "\(titles)")
        check("its current route is ticked", titles.filter { $0.hasPrefix("✓") }.count == 1, "\(titles)")
        check("choosing moves the app", model.setup.apps[first] == "d", "\(model.setup.apps[first] ?? "nil")")
        check("the chip shows it", cell(table, 0, 1)?.accessibilityValue() as? String == "Sweden", "\(String(describing: cell(table, 0, 1)?.accessibilityValue()))")
        let undo = window.undoManager
        let coordinator = table.delegate as? AppsTable.Coordinator
        report("[Check] info undo manager in list \(coordinator?.undo != nil), window's \(undo != nil), same \(coordinator?.undo === undo), canUndo \(undo?.canUndo ?? false), app now \(model.setup.apps[first] ?? "nil")")
        await meter.frames(30)
        report("[Check] info later canUndo \(undo?.canUndo ?? false), app now \(model.setup.apps[first] ?? "nil")")
        check("the list hands moves the window's undo manager", coordinator?.undo != nil && coordinator?.undo === undo)
        undo?.undo(); await meter.frames(20)
        check("Undo puts it back", model.setup.apps[first] == before, "\(model.setup.apps[first] ?? "nil")")
        check("a chip click leaves the selection alone", table.selectedRowIndexes.isEmpty)

        // Selection with real clicks, and the context menu for it.
        guard let name0 = cell(table, 1, 0) else { check("cells", false); return }
        var chain: NSResponder? = name0
        while let next = chain, next !== table { chain = next.nextResponder }
        check("a click on a cell reaches the table, which selects and drags", chain === table)
        table.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false); await meter.frames(6)
        let keys = [1, 2].compactMap { row in model.apps.listed.first { $0.name == cell(table, row, 0)?.accessibilityLabel() }?.id }

        func contextMenu(_ row: Int) -> NSMenu? {
            let p = table.convert(NSPoint(x: 100, y: table.rect(ofRow: row).midY), to: nil)
            guard let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let menu = table.menu(for: e) else { return nil }
            menu.delegate?.menuNeedsUpdate?(menu)
            return menu
        }
        var menu = contextMenu(1)
        titles = menu?.items.map(\.title) ?? []
        check("right-click on the selection offers Move To", titles == ["Move To"], "\(titles)")
        if let routes = menu?.items.first?.submenu {
            check("Move To lists the routes, numbered, then Follow Default", routes.items.first?.keyEquivalent == "1" && routes.items.last?.title == "Follow Default", "\(routes.items.map(\.title))")
            routes.performActionForItem(at: routes.indexOfItem(withTitle: "Germany"))
        } else { check("Move To has a submenu", false) }
        await meter.frames(20)
        check("Move To moves the whole selection", keys.count == 2 && keys.allSatisfy { model.setup.apps[$0] == "c" }, "\(keys)")
        undo?.undo(); await meter.frames(20)
        menu = contextMenu(5)
        titles = menu?.items.map(\.title) ?? []
        check("right-click on another row: its own menu", titles.contains("Show in Finder") && titles.contains("New Route for This App…"), "\(titles)")
        table.deselectAll(nil); await meter.frames(6)

        // Dragging hands over the app's key as text, which is what the sidebar takes.
        let item = table.dataSource?.tableView?(table, pasteboardWriterForRow: 1) as? NSPasteboardItem
        check("a dragged row carries its app", item?.string(forType: .string).map { model.apps.app($0) != nil } == true, "\(String(describing: item?.types))")

        // Search and pages.
        if let field = find(NSSearchField.self) {
            field.stringValue = "safari"
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            await meter.frames(10)
            let hits = model.apps.listed.filter { $0.name.localizedStandardContains("safari") || $0.id.localizedStandardContains("safari") }.count
            check("search narrows the list", table.numberOfRows == hits && hits > 0, "\(table.numberOfRows) vs \(hits)")
            field.stringValue = ""
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            await meter.frames(10)
            check("clearing brings them back", table.numberOfRows == listed)
        } else { check("search field", false) }
        table.scrollRowToVisible(table.numberOfRows - 1); await meter.frames(6)
        go("route:b"); await meter.frames(20)
        let inRoute = model.apps.count(on: "b")
        let shown = appTable?.numberOfRows ?? -1
        check("a route page lists its apps", shown == inRoute, "\(shown) vs \(inRoute)")
        check("and starts at the top", (appTable?.rows(in: appTable?.visibleRect ?? .zero).location ?? 9) == 0)
        go("apps"); await meter.frames(20)
        check("All Apps again", appTable?.numberOfRows == listed)

        // Pages keep working after a round trip, with kept statistics on the first frame.
        go("traffic"); await meter.frames(2)
        check("window still has content", window.contentView != nil)
        go("apps"); await meter.frames(30)
        if let t = appTable, let clip = t.enclosingScrollView?.contentView {
            let columns = t.tableColumns.last.map { t.rect(ofColumn: t.tableColumns.count - 1).maxX <= clip.bounds.maxX + 1 && $0.width >= $0.minWidth } ?? false
            check("every column fits the window", columns, "\(t.tableColumns.map(\.width)) in \(clip.bounds.width)")
        }

        // A tool on a route shows its path; then the looks, light and dark.
        Store.shared.update { $0.apps["/usr/bin/python3"] = "b" }
        model.refreshAppsForPerf()
        await meter.frames(90)
        go("apps"); await meter.frames(30)
        if let dir = ProcessInfo.processInfo.environment["UNBRAID_PERF_CHECK_SHOTS"] {
            appTable?.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false); await meter.frames(10)
            NSApp.appearance = NSAppearance(named: .darkAqua); await meter.frames(20)
            snapshot("\(dir)/all-dark.png")
            go("route:b"); await meter.frames(30)
            snapshot("\(dir)/route-dark.png")
            go("traffic"); await meter.frames(40)
            snapshot("\(dir)/traffic-dark.png")
            NSApp.appearance = NSAppearance(named: .aqua); go("apps"); await meter.frames(30)
            snapshot("\(dir)/all-selected.png")
            // A see-through page: the header must not bring a band of its own.
            UserDefaults.standard.set(0.9, forKey: Transparency.pageKey)
            NSApp.appearance = NSAppearance(named: .darkAqua); await meter.frames(30)
            report("[Check] clear window \(window.windowNumber)")
            if let shot = ProcessInfo.processInfo.environment["UNBRAID_PERF_CHECK_SHOTS"] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", String(window.windowNumber), "\(shot)/clear-dark.png"]
                try? p.run(); p.waitUntilExit()
            }
            NSApp.appearance = NSAppearance(named: .aqua); await meter.frames(30)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", String(window.windowNumber), "\(dir)/clear-light.png"]
            try? p.run(); p.waitUntilExit()
            UserDefaults.standard.set(0.0, forKey: Transparency.pageKey)
            NSApp.appearance = nil
            if let t = appTable, let row = (0..<t.numberOfRows).first(where: { (cell(t, $0, 0)?.accessibilityLabel() ?? "").contains("python3") }) {
                t.scrollRowToVisible(row); await meter.frames(20)
                snapshot("\(dir)/tool-row.png")
            }
        }
    }

    private func snapshot(_ path: String) {
        guard let v = window.contentView?.superview, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: The matrix

    private var page = "apps"
    private func go(_ name: String) { page = name; NotificationCenter.default.post(name: DebugHooks.pageNote, object: name) }

    private func bench() async {
        go("apps"); await meter.frames(40)
        await step("switch.all→route", from: { self.go("apps") }) { self.go("route:b") }
        await step("switch.route→route", from: { self.go("route:b") }) { self.go("route:c") }
        await step("switch.route→all", from: { self.go("route:b") }) { self.go("apps") }
        await step("switch.all→traffic", from: { self.go("apps") }) { self.go("traffic") }
        await step("switch.traffic→activity", from: { self.go("traffic") }) { self.go("activity") }
        await step("switch.activity→speed", from: { self.go("activity") }) { self.go("speed") }
        await step("switch.speed→all", from: { self.go("speed") }) { self.go("apps") }

        go("apps"); await meter.frames(40)
        await typing()
        await step("select.row", settle: 6) { self.selectRow() }
        await scrolling("scroll.first")
        await scrolling("scroll.again")
        await step("move.app", settle: 12) { self.moveApp() }
        await step("publish.vpn.all", settle: 6) { Connection.shared.perfPoke() }
        go("route:b"); await meter.frames(40)
        await step("publish.vpn.route", settle: 6) { Connection.shared.perfPoke() }
        await step("publish.live.route", settle: 20) { Stats.shared.perfPokeLive() }
        go("traffic"); await meter.frames(60)
        await step("publish.live.traffic", settle: 20) { Stats.shared.perfPokeLive() }
        await resizing("resize.traffic")
        go("apps"); await meter.frames(40)
        await resizing("resize.all")
        await step("sheet.picker", from: { Presentation.shared.picker = nil }, settle: 45) { Presentation.shared.picker = PickerTarget(id: "") }
        Presentation.shared.picker = nil; await meter.frames(45)
        await step("panel.open", from: { self.closePanel() }, settle: 30) { self.openPanel() }
        closePanel()
        await step("settings.open", from: { self.closeSettings() }, settle: 45) { AppDelegate.openSettings?() }
        closeSettings()
        await speedRun()
        await liveRun("live.route", page: "route:b")
        await liveRun("live.traffic", page: "traffic")
        await idle()
    }

    /// A whole simulated speed test, watched frame by frame: smooth means every frame on time, with the main thread free.
    private func speedRun() async {
        guard wanted("speedtest") else { return }
        go("speed"); await meter.frames(60)
        let sampler = startSample("speedtest")
        meter.reset()
        let t0 = Meter.now
        PerfCount.ring = 0; PerfCount.curve = 0
        let dir = ProcessInfo.processInfo.environment["UNBRAID_PERF_CHECK_SHOTS"]
        let shoot = Task { @MainActor in
            for (name, wait) in [("speed-down", 6.0), ("speed-up", 9.0)] {
                try? await Task.sleep(for: .seconds(wait))
                guard let dir else { continue }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", String(window.windowNumber), "\(dir)/\(name).png"]
                try? p.run(); p.waitUntilExit()
            }
        }
        await SpeedTest.shared.perfSimulate(exit: "a")
        await shoot.value
        let span = Meter.now - t0
        let gaps = meter.gaps, refresh = gaps.sorted()[gaps.count / 2]
        let late = gaps.filter { $0 > refresh * 1.5 }.count
        report(String(format: "[Perf] speedtest %.0f s: %d frames, %d late (%.1f%%), longest %.0f ms, main thread awake %.1f%%, longest stall %.0f ms",
                      span / 1000, gaps.count, late, 100 * Double(late) / Double(gaps.count), gaps.max() ?? 0, 100 * meter.busy / span, meter.longest))
        report(String(format: "[Perf] speedtest redraws: ring %d, curve %d, longest stall at %.1f s", PerfCount.ring, PerfCount.curve, (meter.longestAt - t0) / 1000))
        sampler?.waitUntilExit()
        await meter.frames(30)
    }

    /// Six seconds of the live graphs at their real pace of one reading a second.
    private func liveRun(_ name: String, page: String) async {
        guard wanted("live") else { return }
        go(page); await meter.frames(60)
        meter.reset()
        let t0 = Meter.now
        for _ in 0..<6 {
            Stats.shared.perfPokeLive()
            try? await Task.sleep(for: .seconds(1))
        }
        let span = Meter.now - t0, gaps = meter.gaps, refresh = gaps.sorted()[gaps.count / 2]
        let late = gaps.filter { $0 > refresh * 1.5 }.count
        report(String(format: "[Perf] %@ %d frames, %d late, longest %.0f ms, main thread awake %.1f%%, longest stall %.0f ms",
                      name, gaps.count, late, gaps.max() ?? 0, 100 * meter.busy / span, meter.longest))
        guard let dir = ProcessInfo.processInfo.environment["UNBRAID_PERF_CHECK_SHOTS"] else { return }
        // The live card sits low on Traffic: bring it into view, then a picture of the real window.
        if page == "traffic", let scroll = find(NSScrollView.self, in: window.contentView), let doc = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.bounds.height - scroll.contentView.bounds.height) * 0.75))
            scroll.reflectScrolledClipView(scroll.contentView)
            await meter.frames(30)
        }
        Stats.shared.perfPokeLive()
        await meter.frames(20)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(window.windowNumber), "\(dir)/\(name).png"]
        try? p.run(); p.waitUntilExit()
    }

    private func wanted(_ name: String) -> Bool { only.map { set in set.contains { name.hasPrefix($0) } } ?? true }

    /// Repeats an action from the same starting point: how long until the display can show it, how long the main thread
    /// stayed awake for it, and its longest unbroken stretch (what is felt as a stall).
    private func step(_ name: String, from: (() -> Void)? = nil, settle: Int = 30, _ act: () -> Void) async {
        guard wanted(name) else { return }
        var r = Result(name: name)
        let sampler = startSample(name)
        var i = 0
        let until = Meter.now + (sampler != nil ? 5000 : 0)
        while i < reps || Meter.now < until {
            if let from { from(); await meter.frames(settle) }
            await meter.frames(2)
            meter.reset()
            let t0 = Meter.now
            act()
            await meter.frames(1)
            r.latency.append(Meter.now - t0)
            await meter.frames(settle)
            r.busy.append(meter.busy)
            r.stall.append(meter.longest)
            i += 1
        }
        sampler?.waitUntilExit()
        results.append(r)
        emit(r)
    }

    private func startSample(_ name: String) -> Process? {
        guard let sampleName, name.hasPrefix(sampleName) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        let file = NSTemporaryDirectory() + "unbraid-sample-\(name).txt"
        p.arguments = [String(getpid()), "5", "1", "-mayDie", "-file", file]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        report("[Sample] \(name) -> \(file)")
        return p
    }

    private func typing() async {
        guard wanted("search"), let field = find(NSSearchField.self) else { return }
        func set(_ s: String) {
            field.stringValue = s
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        var r = Result(name: "search.key")
        let sampler = startSample("search.key")
        let until = Meter.now + (sampler != nil ? 5000 : 0)
        var round = 0
        while round < reps / 3 || Meter.now < until {
            for s in ["a", "ap", "app", "appl", "apple", "appl", "app", "ap", "a", ""] {
                await meter.frames(2)
                meter.reset()
                let t0 = Meter.now
                set(s)
                await meter.frames(1)
                r.latency.append(Meter.now - t0)
                await meter.frames(6)
                r.busy.append(meter.busy)
                r.stall.append(meter.longest)
            }
            round += 1
        }
        sampler?.waitUntilExit()
        results.append(r); emit(r)
    }

    private func scrolling(_ name: String) async {
        guard wanted(name), let table = appTable, let scroll = table.enclosingScrollView else { return }
        var r = Result(name: name)
        let sampler = startSample(name)
        let until = Meter.now + (sampler != nil ? 5000 : 0)
        repeat {
            scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
            await meter.frames(6)
            let maxY = max(0, table.bounds.height - scroll.contentView.bounds.height)
            var y: CGFloat = 0
            while y < maxY {
                y += 48
                meter.reset()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(y, maxY)))
                scroll.reflectScrolledClipView(scroll.contentView)
                await meter.frames(1)
                r.latency.append(meter.gaps.last ?? 0)
                r.busy.append(meter.busy)
                r.stall.append(meter.longest)
            }
        } while Meter.now < until
        sampler?.waitUntilExit()
        results.append(r); emit(r)
    }

    private func resizing(_ name: String) async {
        guard wanted(name) else { return }
        var r = Result(name: name)
        let sampler = startSample(name)
        let until = Meter.now + (sampler != nil ? 5000 : 0)
        let base = window.frame
        repeat {
            for i in 0..<60 {
                let dx = CGFloat(i < 30 ? i : 60 - i) * 6
                meter.reset()
                let t0 = Meter.now
                window.setFrame(NSRect(x: base.minX, y: base.minY, width: base.width + dx, height: base.height), display: true)
                r.latency.append(Meter.now - t0)
                await meter.frames(1)
                r.busy.append(meter.busy)
                r.stall.append(meter.longest)
            }
        } while Meter.now < until
        window.setFrame(base, display: true)
        sampler?.waitUntilExit()
        results.append(r); emit(r)
        await meter.frames(20)
    }

    private func idle() async {
        guard wanted("idle") else { return }
        for (name, pageName) in [("idle.all", "apps"), ("idle.traffic", "traffic")] {
            go(pageName); await meter.frames(90)
            meter.reset()
            await meter.frames(180)
            let span = meter.gaps.reduce(0, +)
            report(String(format: "[Perf] %@ main thread awake %.1f%%", name, 100 * meter.busy / max(span, 1)))
        }
    }

    // MARK: Driving the window

    private func find<V: NSView>(_ type: V.Type, in root: NSView? = nil) -> V? {
        func walk(_ v: NSView) -> V? {
            if let hit = v as? V { return hit }
            for s in v.subviews { if let hit = walk(s) { return hit } }
            return nil
        }
        if let root { return walk(root) }
        return (window.contentView?.superview).flatMap(walk)
    }

    /// The app list, not the sidebar (also a table).
    private var appTable: NSTableView? {
        var best: NSTableView?
        func walk(_ v: NSView) {
            if let t = v as? NSTableView, t.delegate is AppsTable.Coordinator { best = t }
            v.subviews.forEach(walk)
        }
        window.contentView?.superview.map(walk)
        return best
    }

    private var flip = false
    private func selectRow() {
        guard let t = appTable, t.numberOfRows > 8 else { return }
        flip.toggle()
        t.selectRowIndexes(IndexSet(integer: flip ? 3 : 7), byExtendingSelection: false)
    }

    private var moved = false
    private func moveApp() {
        guard let key = appKeys.first else { return }
        moved.toggle()
        model.move([key], to: moved ? "c" : nil, undo: nil)
    }

    private var panel: NSPanel?
    /// The menu bar panel's contents in a window of their own: the status item can't be clicked from here.
    /// `solid`: for a picture, sized to the panel with its rounded corners on a plain background (nothing from behind it).
    private func openPanel(solid: Bool = false) {
        let p = NSPanel(contentRect: NSRect(x: 1100, y: 120, width: 340, height: 500), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: MenuBarPanel().environment(model))
        if solid {
            let size = host.fittingSize
            p.setContentSize(size)
            p.setFrameOrigin(NSPoint(x: window.frame.maxX - size.width - 20, y: window.frame.maxY - size.height - 40))
            p.isOpaque = false
            p.backgroundColor = .clear
            host.wantsLayer = true
            p.appearance = NSApp.appearance
            NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
            host.layer?.cornerRadius = 14
            host.layer?.masksToBounds = true
            host.layer?.borderWidth = 1
            NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { host.layer?.borderColor = NSColor.separatorColor.cgColor }
        }
        p.contentView = host
        p.orderFrontRegardless()
        panel = p
    }
    private func closePanel() { panel?.close(); panel?.contentView = nil; panel = nil }
    private func closeSettings() { NSApp.windows.first { $0.title.contains("General") || $0.identifier?.rawValue.contains("Settings") == true }?.close() }

    // MARK: Report

    private func report(_ s: String) { print(s); fflush(stdout) }
    private func emit(_ r: Result) {
        func med(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        func p95(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * 0.95))] }
        report(String(format: "[Perf] %-26@ busy %7.1f ms  p95 %7.1f  stall %7.1f  p95 %7.1f  to-frame %6.1f  n=%d",
                      r.name as NSString, med(r.busy), p95(r.busy), med(r.stall), p95(r.stall), med(r.latency), r.busy.count))
    }
}

extension ProcessInfo {
    /// When this process started, on the clock `CACurrentMediaTime` uses.
    fileprivate static var processStartMs: Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let t = info.kp_proc.p_starttime
        let age = Date.now.timeIntervalSince1970 - (Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
        return CACurrentMediaTime() * 1000 - age * 1000
    }
}
#endif
