#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only, for automated testing (the Mac twin of Android's DebugHooks):
/// `defaults write app.unbraid debugNordTokenFile <path>` signs in to NordVPN from a file at launch, so the token never
/// passes through a text field, and
/// `tools/debug.sh state` runs a command. It writes the command to `debug.cmd` beside debug.txt and posts a distributed
/// notification, which only wakes the app: notifications reach every process and say nothing about their sender, so
/// they carry nothing. The app runs the file only if this user owns it, nobody else can read or write it (0600), it is
/// a plain file and seconds old; it is removed first, so it runs once. Its result goes to
/// ~/Library/Application Support/unbraid/debug.txt. Commands: state, connect, disconnect, pause:<min>,
/// setup:<json file>, assign:<app>=<route>, default:<route|direct>, health, test:<exit>, speed (the last test),
/// live:<seconds> (each change of the live rates), apps (today's bytes per app and exit).
enum DebugHooks {
    static func install() {
        if let f = UserDefaults.standard.string(forKey: "debugNordTokenFile"), AppModel.shared.accounts["nord"] == nil,
           let t = try? String(contentsOfFile: f, encoding: .utf8) {
            Task { await AppModel.shared.signIn(Nord(), ["token": t.trimmingCharacters(in: .whitespacesAndNewlines)]); out("signin \(AppModel.shared.formError["nord"] ?? "ok")") }
        }
        let dir = URL.applicationSupportDirectory.appending(path: "unbraid")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Older builds broadcast a token with each command; it is no longer used.
        try? FileManager.default.removeItem(at: dir.appending(path: "debug.token"))
        DistributedNotificationCenter.default().addObserver(forName: .init("app.unbraid.debug"), object: nil, queue: .main) { _ in
            guard let cmd = take(dir.appending(path: "debug.cmd")) else { return }
            _ = MainActor.assumeIsolated { Task { await run(cmd) } }
        }
    }

    /// The command file, claimed by renaming it and removed before it is read (one that can't be removed doesn't run, so
    /// none runs twice): only one this user wrote for this user alone (owner, 0600, a plain file, not a link), at most 10
    /// seconds old.
    private nonisolated static func take(_ url: URL) -> String? {
        let claimed = url.path + ".claimed"
        guard rename(url.path, claimed) == 0 else { return nil }
        let fd = open(claimed, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        let removed = unlink(claimed) == 0
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard removed, fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG,
              st.st_mode & 0o077 == 0, (0..<10).contains(Date.now.timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec)) else { return nil }
        guard let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 64 << 10) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    static let pageNote = Notification.Name("app.unbraid.debugPage")
    static let settingsNote = Notification.Name("app.unbraid.debugSettings")

    private static func run(_ cmd: String) async {
        let m = AppModel.shared
        let (name, arg) = cmd.split(separator: ":", maxSplits: 1).map(String.init).splitPair
        switch name {
        case "connect": await m.vpn.connect(); out(state())
        case "disconnect": await m.vpn.disconnect(); out(state())
        case "pause": await m.vpn.pause(minutes: Int(arg) ?? 1); out(state())
        case "setup":
            if let data = FileManager.default.contents(atPath: arg), let s = try? JSONDecoder().decode(Setup.self, from: data) { m.store.update { $0 = s }; out("setup ok") }
            else { out("setup failed") }
        case "assign":
            let p = arg.split(separator: "=").map(String.init)
            if p.count == 2 { m.assign(p[0], p[1] == "default" ? nil : p[1]) }
            out(state())
        case "default":
            // The default route, so a live test can keep everything Direct and send only one app through a tunnel.
            m.setDefault(arg == "direct" ? DIRECT : arg)
            out(state())
        case "health":
            var r: [String] = []
            for t in Set(m.vpn.tags.values) where t.hasPrefix("r-") { r.append("\(t)=\(await Health.reachable(t, probe: m.vpn.probe))") }
            out("health " + r.joined(separator: " "))
        case "nordkey":
            // Whether the stored NordLynx key is still the account's: compares, never prints either.
            guard let blob = m.accounts["nord"], let a = try? Nord.account(blob) else { out("nordkey no account"); break }
            do { let c = try await NordApi.credentials(a.token); out("nordkey \(c.key == a.key ? "same" : "different")") }
            catch { out("nordkey error \(error.localizedDescription)") }
        case "test": out("test started \(SpeedTest.shared.start(exit: arg))")
        case "speed":
            // The last test as the app shows it: phase, Mbps down and up, ping and the M-Lab server.
            guard let r = SpeedTest.shared.run else { out("speed none"); break }
            out("speed phase=\(r.phase) down=\(r.down.map { Units.mbps(Double($0)) } ?? "-") up=\(r.up.map { Units.mbps(Double($0)) } ?? "-") "
                + "ping=\(r.ping.map { "\($0.median)" } ?? "-") server=\(r.server?.machine ?? "-") error=\(r.error ?? "-")")
        case "live":
            // Every change of the live rates over `arg` seconds (default 10), sampled as if a statistics page were on
            // screen (this hook holds its own visibility token): when each came and what each exit read.
            let token = UUID(), t0 = Date.now
            let was = Stats.shared.watching
            Stats.shared.watch(token, visible: true)
            var last = Stats.shared.live, lines: [String] = ["watching before=\(was)"]
            while Date.now.timeIntervalSince(t0) < Double(Int(arg) ?? 10) {
                try? await Task.sleep(for: .milliseconds(20))
                let l = Stats.shared.live
                if l != last {
                    last = l
                    let exits = l.down.keys.sorted().map { "\($0)=\(Units.rate(Double(l.down[$0]?.last ?? 0)))" }.joined(separator: " ")
                    lines.append(String(format: "%.2f ", Date.now.timeIntervalSince(t0)) + "down=\(Units.rate(Double(l.downNow))) up=\(Units.rate(Double(l.upNow))) \(exits)")
                }
            }
            Stats.shared.watch(token, visible: false)
            out(lines.joined(separator: "\n"))
        case "size":
            let p = arg.split(separator: "x").compactMap { Double($0) }
            if p.count == 2, let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                var f = w.frame; f.size = NSSize(width: p[0], height: p[1]); w.setFrame(f, display: true, animate: false)
                out("size \(w.frame.size)")
            } else { out("no window") }
        case "appearance":
            NSApp.appearance = arg == "dark" ? NSAppearance(named: .darkAqua) : arg == "light" ? NSAppearance(named: .aqua) : nil
            out("appearance \(arg)")
        case "mini":
            // Minimizes the main window, to check what a minimized window keeps (the Dock icon).
            NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "unbraid" }?.miniaturize(nil)
            try? await Task.sleep(for: .milliseconds(600))
            out("minimized, policy \(NSApp.activationPolicy() == .accessory ? "accessory" : "regular")")
        case "closeother":
            // Closes the frontmost visible window that isn't the main one (Settings), as its red button does.
            NSApp.orderedWindows.first { $0.isVisible && $0.title != "unbraid" && $0.canBecomeKey && !($0 is NSPanel) }?.performClose(nil)
            try? await Task.sleep(for: .milliseconds(600))
            out("closed other, policy \(NSApp.activationPolicy() == .accessory ? "accessory" : "regular")")
        case "panelroute":
            // What a route row in the menu bar panel does: choose the page, then open the window.
            Presentation.shared.page = .apps(arg.isEmpty ? nil : arg)
            AppDelegate.openMain()
            out("panelroute \(arg)")
        case "page":
            AppDelegate.openMain()
            if !arg.isEmpty { NotificationCenter.default.post(name: pageNote, object: arg) }
            out("page \(arg)")
        case "testwg":
            // A throwaway setup for tunnel tests without a provider account: everything through one WireGuard file,
            // curl Direct. Back up setup.bin first; it replaces the routes and app choices.
            guard let text = try? String(contentsOfFile: arg, encoding: .utf8), let wg = try? WgConf.parse(text, name: "WG test") else { out("testwg bad file"); break }
            m.store.update { $0.routes = []; $0.apps = ["/usr/bin/curl": DIRECT]; $0.defaultRoute = DIRECT }
            m.importServer("", OwnServer(id: "", wg: wg))
            m.store.update { $0.defaultRoute = $0.routes.last?.id ?? DIRECT }
            out(state())
        case "profiles":
            // Saved profiles, the one in use and how a switch stands.
            out("profiles=\(m.setup.profiles.map { "\($0.name):\($0.defaultRoute):\($0.apps.count)" }) active=\(m.setup.profile ?? "-") "
                + "pending=\(m.setup.pendingSwitch?.target ?? "-") switching=\(m.switchingProfile ?? "-") refused=\(m.refusedProfile ?? "-") "
                + "default=\(m.setup.defaultRoute) apps=\(m.setup.apps) kill=\(m.setup.prefs.killLevel.rawValue)")
        case "profile":
            // save:<name>, use:<name> (as the toolbar does), forget:<name>.
            let (verb, name) = arg.split(separator: ":", maxSplits: 1).map(String.init).splitPair
            switch verb {
            case "save": m.store.update { $0.saveAs(name) }
            case "use": m.switchProfile(name)
            case "forget": m.store.update { $0.forget(name) }
            default: break
            }
            out("profile \(verb) \(name) active=\(m.setup.profile ?? "-") pending=\(m.setup.pendingSwitch?.target ?? "-")")
        case "control":
            // What a Control or a Shortcut sends: connect, pause, or a profile's name (with the generation it was offered).
            // "<name>*2" sends the same request twice, as a double press of one Control does.
            let target = arg.hasSuffix("*2") ? String(arg.dropLast(2)) : arg
            let action = target == "connect" || target == "pause" ? target : WidgetAction.profileAction(name: target, generation: m.profileGeneration)
            do {
                for _ in 0..<(arg.hasSuffix("*2") ? 2 : 1) { try await WidgetAction.request(action); try? await Task.sleep(for: .milliseconds(300)) }
                out("control sent \(arg)")
            } catch { out("control failed \(error)") }
        case "testall":
            // The parallel test over comma-separated route ids (M-Lab's terms must have been accepted in the app).
            out("testall started \(SpeedTest.shared.startAll(arg.split(separator: ",").map(String.init)))")
        case "all":
            guard let a = SpeedTest.shared.all else { out("all none"); break }
            func mbps(_ v: Int64?) -> String { v.map { Units.mbps(Double($0)) } ?? "-" }
            out("all phase=\(a.phase) metered=\(a.metered) down=\(mbps(a.down)) up=\(mbps(a.up)) window=\(a.windowMs)ms error=\(a.error ?? "-") notice=\(a.notice ?? "-") legs="
                + a.legs.map { "\($0.exit)[\($0.server?.machine ?? "-") down=\(mbps($0.down)) up=\(mbps($0.up)) missing=\($0.missing) limited=\($0.limited) error=\($0.error ?? "-")]" }.joined(separator: " "))
        case "allgo":
            // Answers the deciding sheet: go, with routes lacking an in-country server tested on the nearest one.
            SpeedTest.shared.goAll(nearest: Set(SpeedTest.shared.all?.legs.filter(\.missing).map(\.exit) ?? []))
            out("allgo")
        case "filter":
            // off, or <preset id>[,routes][,direct][,directapps]: unbraid's DNS filter and where it applies. Anything else
            // (or nothing) only prints it.
            let p = arg.split(separator: ",").map(String.init)
            if p.first == "off" || FilterServer.presets.contains(where: { $0.id == p.first }) { m.setPrefs {
                if p.first == "off" { $0.filter.id = nil; return }
                $0.filter.id = p.first; $0.customDns = []
                $0.filter.routes = p.contains("routes"); $0.filter.direct = p.contains("direct"); $0.filter.directApps = p.contains("directapps")
            } }
            let f = m.setup.prefs.filter
            out("filter id=\(f.id ?? "-") routes=\(f.routes) direct=\(f.direct) directApps=\(f.directApps)")
        case "ondemand":
            // Connect on Demand on or off, as the Settings toggle does.
            if arg == "on" || arg == "off" { m.setPrefs { $0.alwaysOn = arg == "on" }; m.vpn.onDemandChanged(arg == "on") }
            out("ondemand \(m.setup.prefs.alwaysOn)")
        case "settings":
            AppDelegate.openSettings?()
            try? await Task.sleep(for: .milliseconds(300))
            NotificationCenter.default.post(name: settingsNote, object: Int(arg) ?? 0)
            out("settings \(arg)")
        case "kill":
            // The kill switch level: prints it, and sets it when given (off, internet, home).
            let before = m.setup.prefs.killLevel.rawValue
            if let level = KillLevel(rawValue: arg) { m.setPrefs { $0.killLevel = level } }
            out("kill \(before) -> \(m.setup.prefs.killLevel.rawValue)")
        case "toolbar":
            // The main window's toolbar items by label, to check what each page puts there.
            let items = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })?.toolbar?.items ?? []
            out("toolbar " + items.map { "\($0.label.isEmpty ? $0.itemIdentifier.rawValue : $0.label)" }.joined(separator: " | "))
        case "panel":
            // The menu bar panel in a window parked off screen, for layout checks without opening the menu bar extra.
            let host = NSHostingView(rootView: MenuBarPanel())
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.appearance = NSApp.effectiveAppearance
            w.backgroundColor = .windowBackgroundColor
            w.contentView = host
            w.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            w.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(600))
            w.setContentSize(host.fittingSize)
            try? await Task.sleep(for: .milliseconds(200))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = URL.applicationSupportDirectory.appending(path: "unbraid/\(arg.isEmpty ? "panel" : arg).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                out("panel \(url.path)")
            } else { out("panel failed") }
            w.close()
        case "snap":
            // Draws the window itself into a PNG (works with the screen locked, unlike screen capture).
            // The frontmost titled window: the main window or Settings.
            guard let w = NSApp.orderedWindows.first(where: { $0.isVisible && !$0.title.isEmpty }), let v = w.contentView?.superview,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { out("no window"); break }
            v.cacheDisplay(in: v.bounds, to: rep)
            let url = URL.applicationSupportDirectory.appending(path: "unbraid/\(arg.isEmpty ? "snap" : arg).png")
            do { try rep.representation(using: .png, properties: [:])?.write(to: url); out("snap \(url.path)") } catch { out("snap failed") }
        case "win":
            out(NSApp.windows.filter(\.isVisible).map { "\($0.title) frame=\($0.frame.size) min=\($0.minSize) cmin=\($0.contentMinSize) max=\($0.maxSize)" }.joined(separator: "\n"))
        case "watchers":
            // Who asks for live data now: views on screen for statistics and exit addresses, the Dock icon, and the
            // app's windows. For checking that a closed panel or window lets go.
            let wins = NSApp.windows.filter { $0.isVisible || $0.isMiniaturized }.map {
                "\($0.className)\($0.title.isEmpty ? "" : " '\($0.title)'") visible=\($0.isVisible) mini=\($0.isMiniaturized) key=\($0.isKeyWindow)"
            }
            out("stats views=\(Stats.shared.visibleCount) watching=\(Stats.shared.watching) exit views=\(ExitCheck.shared.visibleCount) "
                + "policy=\(NSApp.activationPolicy() == .regular ? "regular" : "accessory")\n" + wins.joined(separator: "\n"))
        case "close":
            // Closes the main window as its red button does, to check what brings it back and that the Dock icon goes with it.
            NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })?.performClose(nil)
            try? await Task.sleep(for: .milliseconds(300))
            out("closed, policy \(NSApp.activationPolicy() == .accessory ? "accessory" : "regular")")
        case "apps":
            let v = await Stats.shared.view(.day)
            out(v.apps.prefix(30).map { "\($0.app) \($0.exit) \($0.bytes)" }.joined(separator: "\n"))
        default: out(state())
        }
    }

    private static func state() -> String {
        let m = AppModel.shared
        let v = m.vpn.state
        return "phase=\(v.phase) error=\(v.error ?? "-") tags=\(m.vpn.tags) servers=\(v.servers.mapValues(\.name)) apps=\(m.setup.apps) routes=\(m.setup.routes.map { "\($0.id):\($0.name)" }) default=\(m.setup.defaultRoute)"
    }

    /// With `defaults write app.unbraid debugEngineLog -bool true`, the engine logs at debug level and every line, plus
    /// each new connection, is appended to trace.txt beside debug.txt. Never on in release builds: lines name sites.
    nonisolated static var engineLog: Bool { UserDefaults.standard.bool(forKey: "debugEngineLog") }

    /// With `defaults write app.unbraid debugSlowReplies -float <seconds>`, every answer from the extension reaches the app
    /// that much later (`EngineLink.call`); one later than its call's timeout (3 s for ownership, 10 s for revisions, 30 s
    /// for a seal) is none, though the extension did what it was asked. Read at each call, so it holds from launch on: the
    /// two-user checks of a takeover or an interrupted sign-out with an extension that doesn't answer in time, and a seal
    /// whose answer is lost. `defaults delete app.unbraid debugSlowReplies` ends it.
    nonisolated static var slowReplies: Double { UserDefaults.standard.double(forKey: "debugSlowReplies") }

    nonisolated static func engineConfig(_ json: String) -> String {
        engineLog ? json.replacingOccurrences(of: #""level"\s*:\s*"warn""#, with: #""level":"debug""#, options: .regularExpression) : json
    }

    nonisolated static func trace(_ lines: [String]) {
        guard engineLog, !lines.isEmpty else { return }
        let url = URL.applicationSupportDirectory.appending(path: "unbraid/trace.txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private static func out(_ s: String) {
        let url = URL.applicationSupportDirectory.appending(path: "unbraid/debug.txt")
        // It names routes and apps: readable by this user only.
        FileManager.default.createFile(atPath: url.path, contents: Data((s + "\n").utf8), attributes: [.posixPermissions: 0o600])
    }
}

private extension Array where Element == String {
    var splitPair: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}
#endif
