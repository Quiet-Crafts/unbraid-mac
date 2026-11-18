#if DEBUG
import AppKit
import SwiftUI
import WidgetKit

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
nonisolated extension PerfFake {
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
        // EMPTY=1: the pictures without any traffic, to show the pages as they are on a first day.
        let emptyShots = getenv("UNBRAID_PERF_SHOTS") != nil && getenv("UNBRAID_PERF_EMPTY") != nil
        if PerfFake.apps != nil { if !emptyShots { seedShotTraffic() } } else { await seedTraffic() }
        Connection.shared.perfConnected()
        if let dir = ProcessInfo.processInfo.environment["UNBRAID_PERF_SHOTS"] { await shots(dir); exit(shotsMissing == 0 ? 0 : 4) }
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
        Updates.shared.setForTesting(Self.updatesAnswered)
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
        "com.apple.Home": "home", "com.apple.Notes": "home", "com.apple.reminders": "home",
    ]
    /// Website → route.
    private static let shotSites: [String: String] = [
        "netflix.com": "us", "bbc.co.uk": "us", "hulu.com": "us", "nytimes.com": "us", "pbs.org": "us", "rai.it": "it", "mybank.example": DIRECT, "tracker.example": BLOCK,
        "nas.example": "home",
    ]
    /// The user's own WireGuard server, the one shown not answering (`route-silent`, `panel-silent`, the widgets).
    private static let shotHome: Route = {
        var r = Route(id: "home", hue: 5)
        // Made-up keys of the right shape, so the made-up backup of this setup passes the same checks as a real one.
        r.wg = WgPeer(name: "Home server", privateKey: String(repeating: "A", count: 42) + "E=", address: ["10.0.0.2/32"],
                      publicKey: String(repeating: "B", count: 42) + "E=", endpoint: "192.0.2.10:51820", allowedIps: ["0.0.0.0/0"])
        return r
    }()
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
            } + [Self.shotHome]
            s.defaultRoute = "nl"
            s.apps = Self.shotApps
            s.sites = Self.shotSites
            s.prefs.stats = true
        }
        Store.shared.disclosed = true
        Store.shared.termsAccepted = true
        Store.shared.tourPending = false
        Updates.shared.setForTesting(Self.updatesAnswered)
        model.acceptDisclosureForPerf()
    }

    /// A month of traffic: video and music heaviest, each app through its own route, the websites through theirs.
    private func seedShotTraffic() {
        let heavy = ["com.apple.TV", "com.apple.Music", "com.apple.Safari", "com.apple.Photos", "com.apple.podcasts", "com.apple.Maps", "com.apple.news", "com.apple.AppStore", "com.apple.mail"]
        // A blocked website carries nothing, so it gets no traffic here either.
        let sites = Self.shotSites.filter { $0.value != BLOCK }.keys.sorted().compactMap(StatsMath.siteKey)
        let keys = appKeys.filter { !heavy.contains($0) } + sites + heavy.reversed()
        let exits = keys.map { StatsMath.site($0).flatMap { Self.shotSites[$0] } ?? Self.shotApps[$0] ?? "nl" }
        Stats.shared.seedForPerf(apps: keys, routes: Self.shotRoutes.map(\.id) + [Self.shotHome.id], exits: exits)
    }

    /// The Settings panes by the number the window takes to open one, in the order they are shot.
    private static let settingsPanes: [(name: String, tab: Int, title: String)] = [
        ("general", 5, "General"), ("providers", 0, "Providers"), ("home", 6, "Home access"), ("tailscale", 1, "Tailscale"),
        ("protection", 2, "Protection"), ("statistics", 3, "Statistics"), ("about", 4, "About"),
    ]

    /// Every main page (All Apps, a route, Direct, Blocked, Traffic, Activity, Speed Test) at the usual size and at the
    /// smallest the window goes, the location picker, the menu bar panel and every Settings pane, in light and dark: the
    /// real windows as macOS draws them. Everything is done by posting to this copy's own state, never by driving a
    /// window from outside. With no traffic (EMPTY) the pages and the panel are shot as they are on a first day.
    private func shots(_ dir: String) async {
        let empty = getenv("UNBRAID_PERF_EMPTY") != nil
        let prefix = empty ? "empty-" : ""
        let normal = NSRect(x: 80, y: 80, width: 1100, height: 760)
        window.setFrame(normal, display: true)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        FrontApp.shared.perfShow(model.apps.app("com.apple.TV"))
        if !empty { for _ in 0..<80 where WeekBytes.shared.bytes.isEmpty { await meter.frames(6) } }
        go("traffic"); await meter.frames(20)
        // `route`: five apps and five websites; `route-few`: two apps and a website, whose lists sit together;
        // `route-none`: apps only.
        let pages = [("apps", "apps"), ("websites", "websites"), ("route", "route:us"), ("route-few", "route:it"), ("route-none", "route:jp"), ("direct", "route:\(DIRECT)"), ("blocked", "route:\(BLOCK)"),
                     ("traffic", "traffic"), ("activity", "activity"), ("speed", "speed")]
        for (suffix, look) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: look); await meter.frames(30)
            Connection.shared.perfConnected()
            for (name, target) in pages {
                go(target); await meter.frames(90)
                await shoot(window, "\(dir)/\(prefix)\(name)\(suffix).png")
            }
            // Traffic's apps list, which sits below the fold: the websites' lines among the apps.
            go("traffic"); await meter.frames(60)
            if !empty, let scroll = find(NSScrollView.self, in: window.contentView), let doc = scroll.documentView {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.bounds.height - scroll.contentView.bounds.height) * 0.5))
                scroll.reflectScrolledClipView(scroll.contentView)
                await meter.frames(30)
                await shoot(window, "\(dir)/traffic-apps\(suffix).png")
            }
            await shrink()
            report("[Perf] minimum window \(Int(window.frame.width))x\(Int(window.frame.height))")
            for (name, target) in pages where name != "direct" && name != "blocked" {
                go(target); await meter.frames(60)
                await shoot(window, "\(dir)/\(prefix)min-\(name)\(suffix).png")
            }
            window.setFrame(normal, display: true); await meter.frames(45)
            if !empty {
                go("route:it"); await meter.frames(40)
                Presentation.shared.picker = PickerTarget(id: "it"); await meter.frames(120)
                // The window's picture holds its sheet. No blinking caret or focus ring in the search field.
                if let sheet = window.attachedSheet { sheet.makeFirstResponder(nil); await meter.frames(20) } else { report("[Perf] no picker sheet"); shotsMissing += 1 }
                await shoot(window, "\(dir)/picker\(suffix).png")
                Presentation.shared.picker = nil; await meter.frames(45)
                await websiteShots(dir, suffix)
            }
            openPanel(solid: true); await meter.frames(50)
            if let panel { await shoot(panel, "\(dir)/\(prefix)panel\(suffix).png") }
            closePanel()
            if !empty { await healthShots(dir, suffix) }
            await updateShots(dir, prefix, suffix, normal)
            await bandShots(dir, prefix, suffix, normal)
            if !empty { await profileShots(dir, suffix) }
            if !empty { await supportShots(dir, suffix) }
            if !empty { await settingsShots(dir, suffix) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.appearance = nil
        report("[Perf] shots in \(dir)")
    }

    /// The own server not answering: its page with the card and the internet check, and the menu bar panel; then the
    /// widget in its sizes, healthy and with that route failing, drawn from made-up snapshots.
    private func healthShots(_ dir: String, _ suffix: String) async {
        // Set again right before each picture: the copy drifting back to connecting clears it (nothing is known then).
        func silent() async { Connection.shared.perfConnected(); Connection.shared.perfSilent(["home"]); await meter.frames(30) }
        go("route:home"); await meter.frames(40)
        await silent()
        await shoot(window, "\(dir)/route-silent\(suffix).png")
        await silent(); openPanel(solid: true); await meter.frames(50)
        if let panel { await shoot(panel, "\(dir)/panel-silent\(suffix).png") }
        closePanel()
        Connection.shared.perfSilent([]); await meter.frames(20)
        let ok = Self.widgetSnapshot(failing: false), failing = Self.widgetSnapshot(failing: true)
        // Right after connecting: one route checked so far, then none.
        var partial = ok, unchecked = ok
        for i in partial.routes.indices where i > 0 { partial.routes[i].ok = nil }
        for i in unchecked.routes.indices { unchecked.routes[i].ok = nil }
        for (name, s, size) in [("small", ok, WidgetFamily.systemSmall), ("small-failing", failing, .systemSmall),
                                ("medium-partial", partial, .systemMedium), ("medium-unchecked", unchecked, .systemMedium),
                                ("medium-failing", failing, .systemMedium), ("large-failing", failing, .systemLarge)] {
            openWidget(s, size); await meter.frames(30)
            if let panel { await shoot(panel, "\(dir)/widget-\(name)\(suffix).png") }
            closePanel()
        }
    }

    /// What the widgets would read: the made-up routes connected, the home server working or not, a week of traffic.
    private static func widgetSnapshot(failing: Bool) -> Snapshot {
        let routes = shotRoutes.map { (r) -> Snapshot.Route in
            Snapshot.Route(id: r.id, name: r.country, code: r.code, hue: r.hue, apps: shotApps.values.filter { $0 == r.id }.count, isDefault: r.id == "nl",
                           country: r.code, sites: shotSites.values.filter { $0 == r.id }.count, ok: true)
        } + [Snapshot.Route(id: "home", name: "Home server", code: "WG", hue: shotHome.hue, apps: 3, isDefault: false, sites: 1, ok: !failing)]
        let today = Calendar.current.startOfDay(for: .now)
        let week = (0..<7).map { (i: Int) -> Snapshot.Day in
            var bytes: [String: Int64] = [:]
            for (n, r) in routes.enumerated() { bytes[r.id] = Int64((i * 7 + n * 5) % 11 + 2) * 90_000_000 }
            return Snapshot.Day(date: today.addingTimeInterval(Double(i - 6) * 86_400), bytes: bytes)
        }
        return Snapshot(phase: .on, since: .now, exits: routes.count, routes: routes, direct: 2, directSites: 1, week: week, updated: .now,
                        profile: "Home", protected: true, tailscale: "Tailscale on")
    }

    /// The widget at its real size (content margins included) in a window of its own, on the widget's rounded ground.
    private func openWidget(_ s: Snapshot, _ size: WidgetFamily) {
        let (w, h): (CGFloat, CGFloat) = size == .systemSmall ? (170, 170) : size == .systemMedium ? (364, 170) : (364, 382)
        let face = WidgetView(s: s, live: true, size: size).padding(16).frame(width: w, height: h)
            .background(Palette.surface, in: .rect(cornerRadius: 22, style: .continuous))
            .padding(20)
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w + 40, height: h + 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: face)
        host.wantsLayer = true
        p.appearance = NSApp.appearance
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        p.contentView = host
        p.setFrameOrigin(NSPoint(x: window.frame.maxX - w - 60, y: window.frame.maxY - h - 80))
        p.orderFrontRegardless()
        panel = p
    }

    /// Add Website with a pasted link, over the Websites page; and the page with no websites.
    private func websiteShots(_ dir: String, _ suffix: String) async {
        go("websites"); await meter.frames(40)
        Presentation.shared.addSite = SiteTarget(address: "https://www.example.org/news/today"); await meter.frames(90)
        if let sheet = window.attachedSheet { sheet.makeFirstResponder(nil); await meter.frames(20) } else { report("[Perf] no website sheet"); shotsMissing += 1 }
        await shoot(window, "\(dir)/add-website\(suffix).png")
        Presentation.shared.addSite = nil; await meter.frames(45)
        // A .local name, refused with why; and the sheet at the limit, which says so before anything is typed.
        Presentation.shared.addSite = SiteTarget(address: "nas.local"); await meter.frames(90)
        if let sheet = window.attachedSheet { sheet.makeFirstResponder(nil); await meter.frames(20) } else { report("[Perf] no website sheet"); shotsMissing += 1 }
        await shoot(window, "\(dir)/add-website-refused\(suffix).png")
        Presentation.shared.addSite = nil; await meter.frames(45)
        // A name the network answers while devices on it are reached: taken, with a note that it isn't applied now.
        Presentation.shared.addSite = SiteTarget(address: "printer.lan"); await meter.frames(90)
        if let sheet = window.attachedSheet { sheet.makeFirstResponder(nil); await meter.frames(20) } else { report("[Perf] no website sheet"); shotsMissing += 1 }
        await shoot(window, "\(dir)/add-website-note\(suffix).png")
        Presentation.shared.addSite = nil; await meter.frames(45)
        Store.shared.update { s in for i in 0..<(Sites.max - Self.shotSites.count) { s.sites["site\(i).example"] = DIRECT } }; await meter.frames(45)
        Presentation.shared.addSite = SiteTarget(); await meter.frames(90)
        if let sheet = window.attachedSheet { sheet.makeFirstResponder(nil); await meter.frames(20) } else { report("[Perf] no website sheet"); shotsMissing += 1 }
        await shoot(window, "\(dir)/add-website-full\(suffix).png")
        Presentation.shared.addSite = nil; await meter.frames(45)
        // A rule saved for a name on the home network before such names were refused: its row says it isn't applied.
        Store.shared.update { $0.sites = Self.shotSites.merging(["printer.lan": DIRECT, "nas.local": BLOCK]) { $1 } }; await meter.frames(60)
        await shoot(window, "\(dir)/websites-not-applied\(suffix).png")
        Store.shared.update { $0.sites = [:] }; await meter.frames(60)
        await shoot(window, "\(dir)/empty-websites\(suffix).png")
        Store.shared.update { $0.sites = Self.shotSites }; await meter.frames(45)
    }

    /// Manage Profiles with Switch by Itself: two remembered networks (the Mac on the first) and any other network set;
    /// then, in light only, none remembered yet. A made-up network: the copy never reads this Mac's own.
    private func profileShots(_ dir: String, _ suffix: String) async {
        let before = Store.shared.setup
        Store.shared.update { s in
            // Work keeps a rule for a printer the network answers, so its caption counts one not applied.
            for (name, route) in [("Home", "nl"), ("Work", "us"), ("Travel", "jp")] {
                s.profile = nil; s.defaultRoute = route; s.sites["printer.lan"] = name == "Work" ? DIRECT : nil; s.saveAs(name)
            }
            s.use("Home")
        }
        let day = { (d: Int) in Calendar.current.date(byAdding: .day, value: -d, to: .now) ?? .now }
        Store.shared.updateNetworks { r in
            r = NetworkRules()
            r.remember("perf-home", name: "Home network", profile: "Home", now: day(5))
            r.remember("perf-office", name: "Office", profile: "Work", now: day(14))
            r.elsewhere = "Travel"
        }
        model.autoSwitch.perfShow("perf-home")
        func shot(_ name: String) async {
            let sheet = NSHostingController(rootView: ManageProfilesSheet())
            window.contentViewController?.presentAsSheet(sheet); await meter.frames(90)
            if let s = window.attachedSheet { s.makeFirstResponder(nil); await meter.frames(20) } else { report("[Perf] no profiles sheet"); shotsMissing += 1 }
            await shoot(window, "\(dir)/\(name).png")
            window.contentViewController?.dismiss(sheet); await meter.frames(45)
        }
        go("apps"); await meter.frames(30)
        await shot("profiles-switch\(suffix)")
        if suffix.isEmpty {
            // The smallest window: the sheet must end above its bottom edge.
            let frame = window.frame
            window.setFrame(NSRect(x: 80, y: 80, width: 770, height: 564), display: true); await meter.frames(60)
            await shot("min-profiles-switch")
            window.setFrame(frame, display: true); await meter.frames(45)
            Store.shared.updateNetworks { $0 = NetworkRules() }
            model.autoSwitch.perfShow("perf-cafe")
            await shot("profiles-switch-empty")
        }
        Store.shared.updateNetworks { $0 = NetworkRules() }
        model.autoSwitch.perfShow(nil)
        Store.shared.update { $0 = before }; await meter.frames(30)
    }

    /// The update question answered with no, as the pictures start; and the check on with a newer release found.
    private static let updatesAnswered = UpdateCheck.State(asked: true)
    /// The release after this one (the next minor version), so the notice shows whatever version is being built.
    private static var updatesNewer: UpdateCheck.State {
        let v = Updates.shared.installed?.parts ?? [1, 0]
        return UpdateCheck.State(enabled: true, asked: true, lastAttempt: .now, latest: "\(v[0]).\(v.count > 1 ? v[1] + 1 : 1).0")
    }

    /// The update notice and the one-time question, each at the usual and the smallest size, over All Apps.
    private func updateShots(_ dir: String, _ prefix: String, _ suffix: String, _ normal: NSRect) async {
        go("apps"); await meter.frames(30)
        Updates.shared.setForTesting(Self.updatesNewer); await meter.frames(60)
        if !Updates.shared.showNotice { report("[Perf] no update notice"); shotsMissing += 1 }
        await shoot(window, "\(dir)/\(prefix)update-notice\(suffix).png")
        Updates.shared.setForTesting(UpdateCheck.State()); await meter.frames(90)
        await shoot(window, "\(dir)/\(prefix)update-ask\(suffix).png")
        Updates.shared.setForTesting(Self.updatesAnswered); await meter.frames(60)
    }

    /// Every page at the smallest size under each band (the update question, the update notice, the support card), as
    /// min-<band>-<page>: the band takes its room from the page, which shrinks; `shoot` checks the window kept its
    /// size, the band sits below the toolbar and no list runs past the window's bottom. "home" is the own server not
    /// answering, with its card.
    private func bandShots(_ dir: String, _ prefix: String, _ suffix: String, _ normal: NSRect) async {
        let pages = [("apps", "apps"), ("websites", "websites"), ("route", "route:us"), ("route-few", "route:it"), ("route-none", "route:jp"),
                     ("home", "route:home"), ("direct", "route:\(DIRECT)"),
                     ("blocked", "route:\(BLOCK)"), ("traffic", "traffic"), ("activity", "activity"), ("speed", "speed")]
        let bands: [(String, () -> Void, () -> Void)] = [
            ("update-ask", { Updates.shared.setForTesting(UpdateCheck.State()) }, { Updates.shared.setForTesting(Self.updatesAnswered) }),
            ("update-notice", { Updates.shared.setForTesting(Self.updatesNewer) }, { Updates.shared.setForTesting(Self.updatesAnswered) }),
            ("support-card", { SupportCardTesting.shared.force = true }, { SupportCardTesting.shared.force = false }),
        ]
        await shrink()
        for (band, on, off) in bands {
            on(); await meter.frames(60)
            for (name, target) in pages {
                go(target); await meter.frames(45)
                if name == "home" { Connection.shared.perfSilent(["home"]); await meter.frames(30) }
                if BandProbe.frame.height < 20 { report("[Perf] no \(band) band over \(name)"); shotsMissing += 1 }
                await shoot(window, "\(dir)/\(prefix)min-\(band)-\(name)\(suffix).png")
                await scrollsAsOne("min-\(band)-\(name)\(suffix)")
                if name == "home" { Connection.shared.perfSilent([]); await meter.frames(20) }
            }
            off(); await meter.frames(45)
        }
        window.setFrame(normal, display: true); go("apps"); await meter.frames(45)
    }

    /// The support card over All Apps (forced on; the rules are in the unit tests), and the sign-in page with its link to
    /// the providers, in a window of its own.
    private func supportShots(_ dir: String, _ suffix: String) async {
        go("apps"); window.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 760), display: true); await meter.frames(30)
        SupportCardTesting.shared.force = true; await meter.frames(60)
        window.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 760), display: true); await meter.frames(30)
        await shoot(window, "\(dir)/support-card\(suffix).png")
        SupportCardTesting.shared.force = false; await meter.frames(45)
        let w = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 720, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SignInView(first: true))
        w.appearance = NSApp.appearance
        w.orderFrontRegardless(); await meter.frames(60)
        await shoot(w, "\(dir)/signin-need-vpn\(suffix).png")
        w.close(); await meter.frames(20)
        window.makeKeyAndOrderFront(nil)
    }

    /// Each Settings pane, opened through this copy's own settings link and window opener.
    private func settingsShots(_ dir: String, _ suffix: String) async {
        let titles = Set(Self.settingsPanes.map(\.title))
        func settingsWindow() -> NSWindow? {
            NSApp.windows.first { $0 !== window && $0.canBecomeMain && $0.contentView != nil && (titles.contains($0.title) || $0.identifier?.rawValue.contains("Settings") == true) }
        }
        var last: NSWindow?
        for pane in Self.settingsPanes {
            Presentation.shared.settingsTab = pane.tab
            if settingsWindow() == nil { AppDelegate.openSettings?() }
            for _ in 0..<100 where settingsWindow() == nil { await meter.frames(3) }
            guard let w = settingsWindow() else { report("[Perf] no settings window for \(pane.name)"); shotsMissing += 1; continue }
            last = w
            w.appearance = NSApp.appearance
            w.orderFrontRegardless()
            await meter.frames(60)
            await shoot(w, "\(dir)/settings-\(pane.name)\(suffix).png")
        }
        // About again, with the update check on and a newer release found.
        if let w = last {
            Updates.shared.setForTesting(Self.updatesNewer)
            Presentation.shared.settingsTab = 4; await meter.frames(60)
            await shoot(w, "\(dir)/settings-about-update\(suffix).png")
            Updates.shared.setForTesting(Self.updatesAnswered)
        }
        if let w = last { await backupShots(w, dir, suffix) }
        last?.close()
        await meter.frames(20)
    }

    /// Settings › General scrolled to its Backup section, then the three backup sheets over it: saving (with an own
    /// server here, so the keys switch shows), the passphrase, and restoring a made-up backup saved without keys.
    private func backupShots(_ w: NSWindow, _ dir: String, _ suffix: String) async {
        Presentation.shared.settingsTab = 5; await meter.frames(60)
        func scrolls(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrolls) }
        // The pane's form: the scroll view furthest right (the sidebar's list is the other one).
        if let root = w.contentView, let form = scrolls(root).max(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }), let doc = form.documentView {
            form.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? max(0, doc.bounds.height - form.contentView.bounds.height) : 0))
            form.reflectScrolledClipView(form.contentView)
            await meter.frames(30)
            await shoot(w, "\(dir)/settings-general-backup\(suffix).png")
        } else { report("[Perf] no settings form to scroll"); shotsMissing += 1 }
        let before = Store.shared.setup
        let key = String(repeating: "A", count: 42) + "E=", peer = String(repeating: "B", count: 42) + "E="
        guard let wg = try? WgConf.parse("[Interface]\nPrivateKey = \(key)\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = \(peer)\nEndpoint = 192.0.2.10:51820\nAllowedIPs = 0.0.0.0/0\n", name: "Home server") else {
            report("[Perf] no made-up server for the backup sheets"); shotsMissing += 3; return
        }
        let flow = BackupFlow.shared
        func sheet(_ name: String) async {
            await meter.frames(60)
            if let sheet = w.attachedSheet { sheet.makeFirstResponder(nil); await meter.frames(20) } else { report("[Perf] no \(name) sheet"); shotsMissing += 1 }
            await shoot(w, "\(dir)/\(name)\(suffix).png")
        }
        // Restored without its keys: the save sheet's switch shows, and Providers says it needs its config again.
        Store.shared.update { $0.servers = [OwnServer(id: "s1", wg: wg).withoutSecrets()] }
        flow.perfPassphrase = "correct horse battery staple"
        flow.perfShow(.save, in: w); await sheet("backup-save")
        flow.perfPassphrase = nil
        flow.perfShow(nil, in: w)
        Presentation.shared.settingsTab = 0; await meter.frames(60)
        await shoot(w, "\(dir)/settings-providers-keyless\(suffix).png")
        Presentation.shared.settingsTab = 5; await meter.frames(30)
        Store.shared.update { $0 = before }
        let file = "unbraid-backup-2026-11-17.unbraidbackup"
        flow.perfShow(.passphrase, in: w, fileName: file); await sheet("backup-passphrase")
        // Another Mac's setup: some of the same routes, one on a provider not signed in to here, and an own server.
        var other = before
        other.routes = before.routes.filter { $0.id != "jp" } + [Route(id: "se", loc: Location(provider: "surfshark", countryCode: "SE", country: "Sweden"), hue: 5),
                                                                 Route(id: "hs", wg: wg, hue: 6, own: "s1")]
        other.servers = [OwnServer(id: "s1", wg: wg)]
        other.apps = before.apps.filter { $0.value != "jp" }.merging(["com.apple.Music": "se", "com.apple.mail": "hs"]) { $1 }
        other.profiles = [Profile(name: "Travel", defaultRoute: "us")]
        do {
            let content = try Backup.read(Backup.export(other, app: "1.2.0", created: Date(timeIntervalSince1970: 1_794_900_000), keys: false))
            flow.perfShow(.restore, in: w, fileName: file, content: content); await sheet("backup-restore")
        } catch { report("[Perf] made-up backup refused: \((error as? Backup.Failure)?.message ?? "\(error)")"); shotsMissing += 1 }
        // With keys, a server of weak security and a setup that protects less than this one: the acceptance the restore
        // waits for, and every note at once.
        do {
            var weaker = other
            let old = try Manual.parseSs("ss://aes-128-cfb:pw@192.0.2.20:8388", name: "Old box")
            let office = try Manual.parseOvpn("client\ndev tun\nproto udp\nremote vpn.example.net 1194\ntls-version-min 1.0\n<ca>\n-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n</ca>\n", name: "Office", username: "", password: "")
            weaker.servers += [OwnServer(id: "s2", ss: old), OwnServer(id: "s3", ovpn: office)]
            weaker.routes += [Route(id: "ob", ss: old, hue: 7, own: "s2"), Route(id: "of", ovpn: office, hue: 8, own: "s3")]
            weaker.defaultRoute = DIRECT
            weaker.apps = weaker.apps.mapValues { $0 == BLOCK ? $0 : DIRECT }.merging(["com.apple.Safari": "ob", "com.apple.Notes": "of"]) { $1 }
            (weaker.prefs.killLevel, weaker.prefs.alwaysOn, weaker.prefs.filter, weaker.prefs.lan) = (.off, false, Filter(), true)
            let content = try Backup.read(Backup.export(weaker, app: "1.2.0", created: Date(timeIntervalSince1970: 1_794_900_000), keys: true))
            flow.perfShow(.restore, in: w, fileName: file, content: content); await sheet("backup-restore-weak")
        } catch { report("[Perf] made-up weak backup refused: \((error as? Backup.Failure)?.message ?? "\(error)")"); shotsMissing += 1 }
        flow.perfShow(nil, in: w); await meter.frames(30)
    }

    /// Where the bands and every list are, to tell a settled layout from one still moving.
    private func layoutPrint(_ w: NSWindow) -> String {
        let lists = appTables(in: w).compactMap { $0.enclosingScrollView }.map { s -> String in
            let f = s.convert(s.bounds, to: nil)
            return "\(Int(f.minY)):\(Int(f.height))\(s.enclosingScrollView == nil ? "" : "s")"
        }
        return "band \(Int(BandProbe.frame.minY)):\(Int(BandProbe.frame.height)) lists " + lists.joined(separator: ",")
    }

    /// A route's page that scrolls as one moves under the wheel even with the pointer over a list (the lists show all
    /// their rows, so they have nothing to scroll themselves); then it goes back to the top for the next picture.
    private func scrollsAsOne(_ name: String) async {
        guard let table = appTables(in: window).first, let outer = table.enclosingScrollView?.enclosingScrollView else { return }
        // Only a page with something to scroll can show it moving.
        guard let doc = outer.documentView, doc.frame.height > outer.contentView.bounds.height + 10 else { return }
        let before = outer.contentView.bounds.origin.y
        report("[Perf] scrolls as one: \(name)")
        // A mouse wheel's notch, handed to the list's own scroll view, as the window does for a wheel turned over it.
        func wheel() -> NSEvent? {
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0).flatMap { NSEvent(cgEvent: $0) }
        }
        if let e = wheel() { table.enclosingScrollView?.scrollWheel(with: e) }
        await meter.frames(20)
        if outer.contentView.bounds.origin.y == before {
            if let e = wheel() { outer.scrollWheel(with: e) }
            await meter.frames(20)
            report("[Perf] the page didn't scroll under the wheel over a list for \(name) (straight to the page: \(outer.contentView.bounds.origin.y == before ? "no" : "yes"), \(type(of: outer)), next \(table.enclosingScrollView?.nextResponder.map { "\(type(of: $0))" } ?? "none"))"); shotsMissing += 1
        }
        outer.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? 0 : max(0, doc.frame.height - outer.contentView.bounds.height)))
        outer.reflectScrolledClipView(outer.contentView); await meter.frames(10)
    }

    /// The window at its smallest. The first time it asks for less than it can be (AppKit holds the frame at its
    /// minimum) and remembers what it got; after that it asks for exactly that, which `shoot` then checks.
    private func shrink() async {
        window.setFrame(NSRect(origin: NSPoint(x: 80, y: 80), size: smallest ?? NSSize(width: 770, height: 564)), display: true); await meter.frames(60)
        if smallest == nil { smallest = window.frame.size }
    }

    /// With nothing really connected, the copy drifts back to connecting now and then: shown connected, with a fresh
    /// reading on the live graphs, for the picture.
    private func shoot(_ w: NSWindow, _ path: String) async {
        Connection.shared.perfConnected()
        Stats.shared.perfPokeLive()
        await meter.frames(15)
        // No picture is taken taller than this: a taller window means something in it forced its height (a band whose
        // text was measured at no width), which pushes the real window off the screen.
        let name = (path as NSString).lastPathComponent
        if w.frame.height > 1400 {
            report("[Perf] window grew to \(Int(w.frame.height)) points for \(name)"); shotsMissing += 1
        }
        // At the smallest size, a band above the page takes its room from the page: the window stays as small as asked.
        if w === window, name.contains("min-"), let smallest, w.frame.size != smallest {
            report("[Perf] window \(Int(w.frame.width))x\(Int(w.frame.height)), not the \(Int(smallest.width))x\(Int(smallest.height)) asked, for \(name)"); shotsMissing += 1
        }
        if w === window, let content = w.contentView {
            // A band above the page lies wholly below the toolbar and inside the window.
            let band = BandProbe.frame, toolbar = content.bounds.height - w.contentLayoutRect.maxY
            if band.height > 0, band.minY < toolbar - 0.5 || band.maxY > content.bounds.height + 0.5 {
                report("[Perf] band at \(Int(band.minY))-\(Int(band.maxY)), toolbar ends at \(Int(toolbar)), window \(Int(content.bounds.height)) high, for \(name)"); shotsMissing += 1
            }
            // No list runs past the window's bottom edge, unless the page scrolls as one; and every list shows at least
            // two whole rows (or all it has) in its own view.
            for table in appTables(in: w) {
                guard let scroll = table.enclosingScrollView, !scroll.isHiddenOrHasHiddenAncestor else { continue }
                let bottom = scroll.convert(scroll.bounds, to: nil).minY
                if scroll.enclosingScrollView == nil, bottom < -0.5 { report("[Perf] a list runs \(Int(-bottom)) points past the window's bottom for \(name)"); shotsMissing += 1 }
                // In a page that scrolls as one, a list shows all its rows: it has nothing left to scroll itself.
                if scroll.enclosingScrollView != nil, table.numberOfRows > 0 {
                    let hidden = table.rect(ofRow: table.numberOfRows - 1).maxY - scroll.contentView.documentVisibleRect.maxY
                    if hidden > 0.5 { report("[Perf] a list in a scrolling page hides \(Int(hidden)) points of its rows for \(name)"); shotsMissing += 1 }
                }
                let need = CGFloat(min(table.numberOfRows, 2)) * AppsTable.rowHeight
                if scroll.contentView.bounds.height < need - 0.5 {
                    report("[Perf] a list of \(table.numberOfRows) rows has room for \(Int(scroll.contentView.bounds.height)) points for \(name)"); shotsMissing += 1
                }
            }
            // At the smallest size the page has settled: the same layout in three looks a few frames apart. A layout
            // that feeds on itself never settles; the copy's own state changing (it drifts back to connecting now and
            // then, which hides the live strip) settles at once, so one change is looked at again before it counts.
            // Timed, not counted in display frames, so a sleeping display can't hold the run here.
            if name.contains("min-") {
                func looks() async -> [String] {
                    var seen: [String] = []
                    for _ in 0..<3 { seen.append(layoutPrint(w)); try? await Task.sleep(for: .milliseconds(50)) }
                    return seen
                }
                var seen = await looks()
                if Set(seen).count > 1 { try? await Task.sleep(for: .milliseconds(300)); seen = await looks() }
                if Set(seen).count > 1 { report("[Perf] layout still changing for \(name): \(seen.joined(separator: " / "))"); shotsMissing += 1 }
            }
        }
        // The Settings gear stays on the toolbar on every page, whatever else goes into the overflow.
        if w === window, let bar = w.toolbar, !(bar.visibleItems ?? []).contains(where: { $0.label == "Settings" || $0.toolTip?.hasPrefix("Settings") == true }) {
            report("[Perf] Settings gear not on the toolbar for \(name) (shown: \((bar.visibleItems ?? []).map { $0.label.isEmpty ? $0.itemIdentifier.rawValue : $0.label }.joined(separator: ", ")))"); shotsMissing += 1
        }
        // Every column of an apps or websites table is in view: one made in a narrow window used to keep its widths
        // and push This Week out of sight.
        for table in appTables(in: w) {
            guard let clip = table.enclosingScrollView?.contentView, table.frame.width > clip.bounds.width + 1 else { continue }
            report("[Perf] table \(Int(table.frame.width)) wide in \(Int(clip.bounds.width)) for \((path as NSString).lastPathComponent)"); shotsMissing += 1
        }
        capture(w, path)
    }

    /// One window as macOS draws it (`cacheDisplay` leaves the glass sidebar blank), without its shadow. CACHE=1 draws
    /// it with `cacheDisplay` instead, on the window's own background, for a locked screen (where screencapture is
    /// black); a sheet over it is drawn beside it, as <name>-sheet.png.
    private func capture(_ w: NSWindow, _ path: String) {
        if getenv("UNBRAID_PERF_CACHE") != nil {
            draw(w, path)
            if let sheet = w.attachedSheet { draw(sheet, path.replacingOccurrences(of: ".png", with: "-sheet.png")) }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(w.windowNumber), path]
        try? p.run(); p.waitUntilExit()
    }

    private func draw(_ w: NSWindow, _ path: String) {
        guard let view = w.contentView?.superview ?? w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        (w.appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        rep.draw(in: view.bounds)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
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

    private var shotsMissing = 0
    /// The smallest the window goes with no band above the page, measured once: every later picture at the smallest
    /// size asks for exactly this and must get it, band or not.
    private var smallest: NSSize?
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

    /// Every apps or websites table in `w`.
    private func appTables(in w: NSWindow) -> [NSTableView] {
        var all: [NSTableView] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTableView, t.delegate is AppsTable.Coordinator { all.append(t) }
            v.subviews.forEach(walk)
        }
        w.contentView?.superview.map(walk)
        return all
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
