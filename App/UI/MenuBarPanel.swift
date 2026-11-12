import AppKit
import SwiftUI

/// The menu bar extra: the state, live speed, the app you came from with one-click routes for it, the routes, and the one
/// connection control. No diagram: numbers and names answer faster.
struct MenuBarPanel: View {
    private let model = AppModel.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var front = FrontApp.shared
    /// The app in front when the panel opened. Held while it is open, so a click always edits the app the person meant.
    @State private var target: AppInfo?
    @State private var watchId = UUID()
    @State private var exitWatch = UUID()

    var body: some View {
        let v = model.vpn.state
        VStack(alignment: .leading, spacing: 0) {
            header(v)
            if v.phase == .on && model.setup.prefs.stats { PanelLive().padding(.top, 12) }
            if let e = v.error { Text(e).font(.caption).foregroundStyle(Ink.failedText).fixedSize(horizontal: false, vertical: true).padding(.top, 8) }
            if model.signedIn {
                // Choosing a route for an app comes after the disclosure, like everywhere else.
                if model.store.disclosed, let app = target ?? front.app { section { FrontRoute(app: app) } }
                section {
                    HStack {
                        Text("Profile").overline()
                        Spacer()
                        ProfileMenu(none: "None").menuStyle(.button).buttonStyle(.bordered).buttonBorderShape(.capsule).fixedSize()
                    }
                }
                section { routes(v) }
                // The same control as the window's sidebar, so it reads and behaves the same everywhere.
                ConnectionDock(compact: true).padding(.top, 14)
            } else {
                // Before any sign-in the setup is a placeholder: no routes to show, nothing to connect.
                section {
                    Button { AppDelegate.openMain() } label: { Text("Set Up unbraid").frame(maxWidth: .infinity) }
                        .contentButton(prominent: true).controlSize(.large)
                }
            }
            Divider().padding(.top, 12)
            VStack(alignment: .leading, spacing: 2) {
                MenuRow(title: "Open unbraid", key: "⌘O", shortcut: "o") { AppDelegate.openMain() }
                MenuRow(title: "Settings…", key: "⌘,", shortcut: ",") { NSApp.activate(); openSettings() }
                MenuRow(title: "Quit unbraid", key: "⌘Q", shortcut: "q") { NSApp.terminate(nil) }
            }
            // The rows' hover fill reaches past the text, so the text lines up with the content above.
            .padding(.top, 6).padding(.horizontal, -6)
        }
        .padding(Layout.gutter)
        .frame(width: 360)
        // While the panel is open, live numbers move every second, as they do on a visible statistics page.
        .onAppear { target = front.app; Stats.shared.watch(watchId, visible: true); ExitCheck.shared.watch(exitWatch, visible: true) }
        .onDisappear { target = nil; Stats.shared.watch(watchId, visible: false); ExitCheck.shared.watch(exitWatch, visible: false) }
        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: v.phase)
    }

    private func section(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) { Divider().padding(.bottom, 12); content() }.padding(.top, 14)
    }

    private func header(_ v: VpnState) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(color: v.phase == .on ? Ink.connected : v.phase == .paused ? Ink.paused : v.error != nil ? Ink.failed : Ink.off)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(v)).font(.system(size: 13, weight: .semibold))
                Text(detail(v)).font(.system(size: 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Wordmark(size: 18)
        }
        .accessibilityElement(children: .combine)
    }

    /// Each VPN route with its server and, connected, its download now. A click opens its apps in the window.
    private func routes(_ v: VpnState) -> some View {
        let s = v.phase == .on && v.runState.standIn == .none ? (v.runState.appliedSetup ?? model.setup) : model.setup
        let showRate = v.phase == .on && s.prefs.stats
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Routes").overline()
                Spacer()
                if showRate { Text("Download").overline() }
            }
            .padding(.bottom, 4)
            ForEach(s.sidebarRoutes.filter { s.route($0) != nil }, id: \.self) { id in
                VStack(alignment: .leading, spacing: 0) {
                Button {
                    Presentation.shared.page = .apps(id)
                    AppDelegate.openMain()
                } label: {
                    HStack(spacing: 8) {
                        Slash(color: s.color(id)).frame(width: Measure.slashColumn)
                        Text(s.label(id)).lineLimit(1)
                        if v.phase == .on, let server = v.servers[id], let r = s.route(id) {
                            Text(serverId(r, server)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.dim).lineLimit(1)
                        }
                        if let reason = v.blocked[id] {
                            Text("Not working").font(.system(size: 11)).foregroundStyle(Ink.failedText).help(reason)
                        }
                        Spacer(minLength: 8)
                        if showRate && v.blocked[id] == nil { RouteRate(route: id) }
                    }
                    .frame(height: Measure.tableRow).contentShape(.rect)
                }
                .buttonStyle(.plain).help("Show the apps on \(s.label(id))")
                if let reason = v.blocked[id] {
                    Text("Apps on \(s.label(id)) are blocked: \(reason)" + (v.retryAt[id].map { ". Next try at \($0.formatted(date: .omitted, time: .standard))." } ?? ""))
                        .font(.caption).foregroundStyle(Ink.failedText).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Measure.slashColumn + 8).padding(.bottom, 4)
                } else {
                    ExitLine(route: id).padding(.leading, Measure.slashColumn + 8).padding(.bottom, 4)
                }
                }
            }
        }
    }

    private func title(_ v: VpnState) -> String {
        switch v.phase {
        case .on: v.runState.protection(blocked: Set(v.blocked.keys)).map { $0 ? "Protected" : "Connected" } ?? "Connected"
        case .connecting: "Connecting"
        case .paused: "Paused"
        case .off: v.error == nil ? "VPN off" : "Connection failed"
        }
    }

    private func detail(_ v: VpnState) -> String {
        if let name = model.switchingProfile { return "Switching to \(name) · apps reconnect for a moment" }
        switch v.phase {
        case .on:
            let n = Set(model.vpn.tags.values).count
            // A connection from an earlier day names the weekday: "since Tue 14:05" never reads as today.
            let since = Calendar.current.isDateInToday(v.since) ? v.since.formatted(date: .omitted, time: .shortened)
                : v.since.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            return "\(n) VPN route\(n == 1 ? "" : "s") · since \(since)"
        case .connecting: return "Setting up your routes"
        case .paused:
            return v.pausedUntil.map { "Resumes at \($0.formatted(date: .omitted, time: .shortened)). Blocked apps stay blocked." }
                ?? "Until you resume. Blocked apps stay blocked."
        // Off means off: the tunnel is down, so nothing is blocked either.
        case .off: return "Apps connect without the VPN, blocked apps included."
        }
    }
}

/// The app you came from and where it goes: up to three routes as one-click buttons, every other choice behind More.
private struct FrontRoute: View {
    private let model = AppModel.shared
    let app: AppInfo

    var body: some View {
        let s = model.setup
        let current = s.apps[app.id]
        VStack(alignment: .leading, spacing: 10) {
            Text("App in front").overline()
            HStack(spacing: 10) {
                AppIconView(app: app, size: Measure.rowIcon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(current.map(s.label) ?? s.defaultLabel).font(.system(size: 12)).foregroundStyle(Ink.dim).lineLimit(1)
                }
            }
            // As many routes as fit at their full names, never a truncated one; the rest are behind More.
            ViewThatFits(in: .horizontal) {
                ForEach([3, 2, 1], id: \.self) { n in
                    HStack(spacing: 6) {
                        ForEach(quick(s, current, n), id: \.self) { id in button(id, on: current == id, s) }
                        Spacer(minLength: 0)
                        GlassMenu(glass: false, chevron: false, circle: true) { RouteMenuItems(app: app.id) } label: { Image(systemName: "ellipsis") }
                            .help("More routes").accessibilityLabel("More Routes for \(app.name)")
                    }
                }
            }
        }
    }

    /// Follow Default first, then routes in sidebar order; the app's own route is always among them.
    private func quick(_ s: Setup, _ current: String?, _ n: Int) -> [String?] {
        var ids: [String?] = Array(([nil] + s.sidebarRoutes.filter { $0 != BLOCK }.map { $0 }).prefix(n))
        if let current, !ids.contains(current) { ids[ids.count - 1] = current }
        return ids
    }

    private func button(_ id: String?, on: Bool, _ s: Setup) -> some View {
        Button { if !on { model.move([app.id], to: id, undo: nil) } } label: {
            HStack(spacing: 5) {
                if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                else { Slash(color: s.color(id ?? s.defaultRoute), height: 12) }
                Text(id.map(s.label) ?? "Default").lineLimit(1)
            }
            .font(.system(size: 12, weight: on ? .semibold : .regular)).padding(.horizontal, 2)
        }
        .contentButton().controlSize(.large).fixedSize()
        .accessibilityLabel(id.map(s.label) ?? "Follow the default route").accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A plain menu-style row with its shortcut, as in a native menu.
private struct MenuRow: View {
    let title: String
    let key: String
    let shortcut: KeyEquivalent
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack { Text(title); Spacer(); Text(key).foregroundStyle(Ink.dim) }
                .padding(.horizontal, 6).frame(height: 24).contentShape(.rect)
                .background(hover ? Ink.accentText.opacity(0.16) : .clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain).keyboardShortcut(shortcut, modifiers: .command).onHover { hover = $0 }
    }
}

/// Every route an app can take, checked: Default, each route, Direct, Block, and New Route.
struct RouteMenuItems: View {
    private let model = AppModel.shared
    let app: String

    var body: some View {
        let s = model.setup
        let current = s.apps[app]
        Picker("Route", selection: Binding(get: { current ?? "" }, set: { v in if v != (current ?? "") { model.move([app], to: v.isEmpty ? nil : v, undo: nil) } })) {
            Text(s.defaultLabel).tag("")
            Divider()
            ForEach(s.sidebarRoutes, id: \.self) { Text(s.label($0)).tag($0) }
        }
        .pickerStyle(.inline).labelsHidden()
        Divider()
        Button("New Route…") {
            Presentation.shared.picker = PickerTarget(id: "app:\(app)")
            AppDelegate.openMain()
        }
    }
}

/// The app the user is working in, other than unbraid itself: the menu bar panel offers to route it.
@Observable
final class FrontApp {
    static let shared = FrontApp()
    private(set) var app: AppInfo?

    private init() {
        update(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { FrontApp.shared.update(a) }
        }
    }

    #if DEBUG
    /// Pictures from the test copy show a made-up app, never the one really in front.
    func perfShow(_ shown: AppInfo?) { app = shown }
    #endif

    private func update(_ a: NSRunningApplication?) {
        #if DEBUG
        if PerfHost.active { return }
        #endif
        guard let a, a.bundleIdentifier != Bundle.main.bundleIdentifier, let id = a.bundleIdentifier else { return }
        app = AppCatalog.shared.app(id) ?? a.bundleURL.map { AppInfo(id: id, name: a.localizedName ?? $0.lastPathComponent, path: $0.path, system: false) }
    }
}

/// Download and upload now, and the last minute of download across every exit, in a neutral grey. Its own view, so the
/// second-by-second numbers redraw this alone and not the whole panel.
private struct PanelLive: View {
    var body: some View {
        let l = Stats.shared.live
        let series = l.down.values.reduce(into: [Float]()) { sum, s in
            for (i, x) in s.suffix(60).enumerated() { if i < sum.count { sum[i] += x } else { sum.append(x) } }
        }
        VStack(spacing: 4) {
            HStack {
                Text("↓ " + Units.rate(Double(l.downNow)))
                Spacer()
                Text("↑ " + Units.rate(Double(l.upNow))).foregroundStyle(Ink.dim)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            if series.count > 1 { Sparkline(values: series, color: Ink.dim).frame(height: 32) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Download \(Units.rate(Double(l.downNow))), upload \(Units.rate(Double(l.upNow)))")
    }
}

/// A route's download now, beside its name in the panel; redraws on its own every second.
private struct RouteRate: View {
    let route: String
    var body: some View {
        if let now = Stats.shared.live.down[route]?.last {
            Text(Units.rate(Double(now))).font(.system(size: 12, design: .monospaced))
        }
    }
}
