import SwiftUI

/// The apps on this Mac and where each one leaves: all of them, or those on one route. Moving apps is one gesture
/// everywhere: the Route menu in a row, a drag onto a route in the sidebar, Move To in the context menu, or ⌥⌘1…9.
struct AppsView: View {
    /// nil = all apps; else a route id, DIRECT or BLOCK.
    let route: String?
    private let model = AppModel.shared
    @Environment(\.navigate) private var navigate
    @Environment(\.undoManager) private var undo
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var exitWatch = UUID()
    @State private var query = ""
    @State private var showSystem = false
    @State private var selection = Set<String>()
    @State private var sort = AppsSort()
    /// Bytes per app this week, from the statistics. Outlives the page, so coming back shows the numbers at once.
    private let week = WeekBytes.shared
    /// The week's bytes when the list was last sorted: rows keep their places while the numbers refresh underneath,
    /// so nothing moves under the pointer. Sorting again (a column header) takes the latest.
    @State private var rank = WeekBytes.shared.bytes

    var body: some View {
        let s = model.setup
        let rows = shown(s)
        VStack(spacing: 0) {
            header(s)
            if let id = route ?? (s.route(s.defaultRoute) == nil ? nil : s.defaultRoute) {
                // On All Apps it's the default route's exit, so it says whose it is.
                ExitLine(route: id, prefix: route == nil ? "\(s.route(id)?.name ?? "Default route") exits as" : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Layout.gutter).padding(.bottom, 10).pageWidth()
            }
            if let id = route, let r = s.route(id) {
                LiveStrip(route: r.id, color: r.color, week: week)
            }
            banners(s)
            table(rows)
        }
        // A route's page carries its colour: a soft light from the top, under the clear toolbar.
        .background(alignment: .top) { if let id = route, !reduceTransparency { RouteGlow(color: s.color(id)) } }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let id = route {
                    if s.route(id) != nil {
                        Button("Change Server…") { Presentation.shared.picker = PickerTarget(id: id) }
                    }
                    if s.route(id) != nil || (id != BLOCK && id != s.defaultRoute) {
                        Menu { RouteActions(id: id) } label: { Label("Actions for \(s.label(id))", systemImage: "ellipsis") }
                            .help("Route actions")
                    }
                } else { ProfileMenu() }
            }
            // One centred group: search over the list it filters (⌘F), then its filter and Add App.
            ToolbarItemGroup(placement: .principal) {
                SearchField(text: $query, prompt: "Search apps").frame(minWidth: 150, idealWidth: 260, maxWidth: 320)
                Menu {
                    Toggle("Include System Apps", isOn: $showSystem)
                } label: {
                    Label("Filter", systemImage: showSystem ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                }
                .help("Filter apps")
                Button(action: add) { Label("Add App…", systemImage: "plus") }.help("Add an app or command-line tool")
                    .disabled(!model.store.disclosed)
            }
        }
        // The menu commands read the selection in a child, so a click redraws that child and not the whole list.
        .background(AppsActions(selection: $selection, add: model.store.disclosed ? { add() } : nil))
        // A new page starts afresh: no selection, no search left over from the last one.
        .onAppear { ExitCheck.shared.watch(exitWatch, visible: route != DIRECT && route != BLOCK) }
        .onDisappear { ExitCheck.shared.watch(exitWatch, visible: false) }
        .onChange(of: route) {
            selection = []; query = ""
            ExitCheck.shared.watch(exitWatch, visible: route != DIRECT && route != BLOCK)
        }
        // Only what is on screen stays selected, so Move To never acts on apps the search or a move has hidden.
        .onChange(of: rows.map(\.id)) { _, ids in selection.formIntersection(ids) }
        // Keyed on the page too: one AppsView serves every route, and a task started on All Apps must not keep its nil.
        .task(id: "\(model.setup.prefs.stats)|\(route ?? "")") {
            // Every 15 s, like the writer's own sampling while nobody watches.
            while !Task.isCancelled, model.setup.prefs.stats {
                let totals = await Stats.shared.appTotals(.week)
                // A route's own week, for its page's strip: what left through it, not its apps' traffic elsewhere.
                let routes = route == nil ? week.routes : await Stats.shared.week().reduce(into: [String: Int64]()) { sum, d in
                    for (exit, b) in d.bytes { sum[exit, default: 0] += b }
                }
                // A page left while the query ran must not touch its table: rows updated as the table is torn down
                // abort inside SwiftUI (AppKitOutlineTableCoordinator).
                guard !Task.isCancelled else { return }
                if totals != week.bytes { week.bytes = totals }
                if routes != week.routes { week.routes = routes }
                // Statistics deleted while the page's order still leaned on them start it afresh.
                if rank.isEmpty || totals.isEmpty { rank = totals }
                // Every 15 s while unbraid is in front; once a minute behind other apps or minimised.
                try? await Task.sleep(for: .seconds(NSApp.isActive ? 15 : 60))
            }
            if !Task.isCancelled && !model.setup.prefs.stats { week.bytes = [:] }
        }
        .onChange(of: sort) { rank = week.bytes }
    }

    // MARK: Header

    @ViewBuilder private func header(_ s: Setup) -> some View {
        if let id = route {
            PageHeader(title: s.label(id), subtitle: about(id, s), slash: s.color(id))
        } else {
            let custom = s.apps.keys.filter { model.apps.app($0) != nil }.count
            PageHeader(title: "All Apps", subtitle: "\(model.apps.listed.count) apps · " + (custom == 0 ? "all on the default route" : "\(custom) with their own route"))
        }
    }

    /// One line on what a route is: where it leaves and through which server, or what Direct and Blocked mean.
    private func about(_ id: String, _ s: Setup) -> String {
        switch id {
        case DIRECT: return "No VPN: these apps use your own connection"
        case BLOCK: return s.blockedReach
        default:
            guard let r = s.route(id) else { return "" }
            let live = model.vpn.state.phase == .on ? model.vpn.state.servers[id] : nil
            let p = place(r, model.vpn.state.servers)
            return [live.map { "\(p) · \(serverId(r, $0))" } ?? p, id == s.defaultRoute ? "every app without its own route" : nil]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Home access and Nord's connection limit, above the list on All Apps only, so each route's page stays about its apps.
    @ViewBuilder private func banners(_ s: Setup) -> some View {
        if route == nil {
            VStack(alignment: .leading, spacing: 8) {
                if s.allAppsUseDefault {
                    HStack {
                        Text("All apps use the default route.")
                        Button("Add Route") { Presentation.shared.picker = PickerTarget(id: "") }
                            .disabled(!model.store.disclosed).contentButton()
                    }
                }
                if s.home.tailscale || s.home.wg != nil {
                    HomeCard()
                    // Keep the sign-in and domain consent actions available where they were raised.
                    if s.home.tailscale && (model.vpn.state.tsLoginUrl != nil || model.store.tsSuffixOffered != nil) {
                        HomeRow().contentButton()
                    }
                }
                if s.activeRoutes.filter({ !$0.imported && $0.loc.provider == "nord" }).count > 6 {
                    Text("NordVPN allows 10 connections per account; each active location uses one.").foregroundStyle(Ink.dim)
                }
            }
            .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Layout.gutter)
            .padding(.bottom, s.allAppsUseDefault || s.home.tailscale || s.home.wg != nil ? 12 : 0)
        }
    }

    // MARK: Table

    private func table(_ rows: [Row]) -> some View {
        // Icons and the tools' patterns can change without the list of apps changing.
        let _ = (model.apps.revision, model.apps.patternRevision)
        return AppsTable(rows: rows, week: week.bytes, peak: week.peak, page: route ?? "", selection: $selection, sort: $sort)
            .background { if rows.isEmpty { Color.clear.tourAnchor(2) } }
            // Step 3 of the tour points at the first row's route, in the Route column.
            .overlay(alignment: .topLeading) {
                if !rows.isEmpty { Color.clear.frame(width: 140, height: 28).offset(x: 335, y: 36).allowsHitTesting(false).accessibilityHidden(true).tourAnchor(2) }
            }
            .pageWidth()
            .overlay { empty(rows) }
    }

    @ViewBuilder private func empty(_ rows: [Row]) -> some View {
        if !model.store.disclosed {
            ContentUnavailableView {
                Label("Show my apps", systemImage: "square.grid.2x2")
            } description: {
                Text("unbraid needs the list of installed apps to route each one. It stays on this Mac.")
            } actions: {
                Button("Show My Apps") { model.requestDisclosure() }
            }
        } else if rows.isEmpty {
            if !model.apps.loaded { ProgressView().accessibilityLabel("Loading apps") }
            else if !query.isEmpty { ContentUnavailableView.search(text: query) }
            else {
                ContentUnavailableView {
                    Label("No apps on this route", systemImage: "app.dashed")
                } description: {
                    Text("Select apps in All Apps and drag them onto this route in the sidebar, or use Move To.")
                } actions: {
                    Button("Show All Apps") { navigate(.apps(nil)) }
                }
            }
        }
    }

    /// The apps to list: this page's route, the search, system apps only when asked or routed, in the frozen order.
    private func shown(_ s: Setup) -> [Row] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return model.apps.apps.filter { a in
            // One missing is listed only while it keeps a route of its own.
            (a.missing ? s.apps[a.id] != nil : showSystem || !a.system || s.apps[a.id] != nil) && (route == nil || s.routeOf(a.id) == route)
                && (q.isEmpty || a.name.localizedStandardContains(q) || a.id.localizedStandardContains(q))
        }
        .map { a in Row(id: a.id, name: a.name, routeName: s.label(s.routeOf(a.id)), week: rank[a.id] ?? 0) }
        .sorted(by: sort.inOrder)
    }

    /// Any app or command-line tool, wherever it lives. It is listed (searched by name, so it is easy to find) and its
    /// Route menu does the rest; a tool is remembered once it has a route.
    private func add() {
        let p = NSOpenPanel()
        p.message = "Choose an app or a command-line tool. An interpreter such as python3 routes every script it runs; a script such as pip3 runs as its interpreter, so its own path routes nothing."
        p.prompt = "Add"
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK, let url = p.url else { return }
        let key = model.apps.add(url)
        let show = {
            // A listed system app stays one; without a route it is listed only with system apps, so show them.
            if model.apps.app(key)?.system == true, model.setup.apps[key] == nil { showSystem = true }
            query = model.apps.app(key)?.name ?? ""; selection = [key]
        }
        // From a route's page, open All Apps first; the selection follows once that page has reset.
        if route != nil { navigate(.apps(nil)); Task { @MainActor in show() } } else { show() }
    }
}

/// The Apps menu and Find for this page. Reads the selection itself, so selecting rows redraws only this.
private struct AppsActions: View {
    @Binding var selection: Set<String>
    let add: (() -> Void)?
    @Environment(\.undoManager) private var undo

    var body: some View {
        Color.clear.focusedSceneValue(\.sceneActions, SceneActions(
            addApp: add,
            find: { NotificationCenter.default.post(name: SearchField.focus, object: nil) },
            move: selection.isEmpty ? nil : { AppModel.shared.move(Array(selection), to: $0, undo: undo) }))
    }
}

@Observable final class WeekBytes {
    static let shared = WeekBytes()
    var bytes: [String: Int64] = [:] { didSet { peak = bytes.values.max() ?? 0 } }
    /// The busiest app's bytes, which every row's bar is measured against.
    private(set) var peak: Int64 = 0
    /// Bytes per route this week (route pages only).
    var routes: [String: Int64] = [:]
}

/// Home access opens its settings from the whole row.
private struct HomeCard: View {
    private let model = AppModel.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let h = model.setup.home
        let v = model.vpn.state
        let on = v.phase == .on && (h.wg != nil || (h.tailscale && TailscaleStatus(v.tsState) == .connected))
        let via = h.tailscale ? "Tailscale" : "WireGuard · \(h.wg?.endpointHost ?? "")"
        Button {
            Presentation.shared.settingsTab = 6
            openSettings()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "house").font(.system(size: 24)).foregroundStyle(Ink.dim).frame(width: Measure.rowIcon)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Home network").font(.heading).foregroundStyle(Ink.text)
                    Text(([via] + (h.subnets.isEmpty ? [] : [h.subnets.joined(separator: ", ")]) + ["from every app"]).joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Ink.dim)
                }
                Spacer()
                StatusDot(color: on ? Ink.connected : Ink.off)
                Text(on ? "On" : "Off").font(.system(size: 12)).foregroundStyle(Ink.dim)
                Image(systemName: "chevron.right").foregroundStyle(Ink.dim)
            }
            .padding(Layout.inset).frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Home network, \(on ? "On" : "Off")")
        .help("Open Home access settings")
    }
}

/// The routes an app can move to, in sidebar order with ⌥⌘1…9, then Follow Default (⌥⌘0). Used by the context menu
/// and the Apps menu, so both list the same routes with the same shortcuts.
struct MoveItems: View {
    private let model = AppModel.shared
    let move: (String?) -> Void

    var body: some View {
        let ids = model.setup.sidebarRoutes
        ForEach(Array(ids.enumerated()), id: \.element) { i, id in
            let b = Button(model.setup.label(id)) { move(id) }
            if i < 9 { b.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option]) } else { b }
        }
        Divider()
        Button("Follow Default") { move(nil) }.keyboardShortcut("0", modifiers: [.command, .option])
    }
}

/// A route's speed now, its last minute and its week, under the page header while connected with statistics on.
private struct LiveStrip: View {
    let route: String
    let color: Color
    /// Read here rather than by the page, so the week's refresh redraws the strip and not the list.
    let week: WeekBytes
    private let model = AppModel.shared

    var body: some View {
        if model.vpn.state.phase == .on && model.setup.prefs.stats {
            let series = Stats.shared.live.down[route] ?? []
            let week = self.week.routes[route] ?? 0, apps = model.apps.count(on: route)
            let now = Units.rate(Double(series.last ?? 0))
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Now").overline()
                    Figure(value: series.isEmpty ? "–" : "↓ " + now, unit: "").lineLimit(1)
                }
                .frame(minWidth: 140, alignment: .leading)
                Sparkline(values: series, color: color).frame(maxWidth: .infinity).frame(height: 44)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("This week").overline()
                    Figure(value: Units.bytes(week), unit: "").lineLimit(1)
                    Text("\(apps) app\(apps == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(Ink.dim)
                }
            }
            .monospacedDigit().padding(.horizontal, Layout.inset).padding(.vertical, 14)
            .background(Ink.surface, in: .rect(cornerRadius: Corner.card, style: .continuous))
            .padding(.horizontal, Layout.gutter).padding(.bottom, 14).pageWidth()
            // One visibility token for the strip, whatever it shows: a token per state dropped out as the first second
            // arrived, which could restart sampling and empty the series again.
            .background(StatsVisibility())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(series.isEmpty ? "Live speed, waiting for the first second" : "Download now, \(now); this week, \(Units.bytes(week))")
        }
    }
}

/// The selected route's colour as a soft light from the top of its page, fading before the list begins.
private struct RouteGlow: View {
    let color: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        EllipticalGradient(colors: [color.opacity(scheme == .dark ? 0.24 : 0.14), color.opacity(0)],
                           center: UnitPoint(x: 0.18, y: 0), startRadiusFraction: 0, endRadiusFraction: 0.62)
            .frame(height: 320).ignoresSafeArea(edges: .top).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// An exit's address, or the progress of the check for it.
struct ExitLine: View {
    let route: String
    /// Words before the address where the page doesn't already name the route ("Netherlands exits as").
    var prefix: String? = nil
    private let checks = ExitCheck.shared
    var body: some View {
        if checks.state.routes[route] != nil {
            if let address = checks.state.answers[route] {
                HStack(spacing: 5) {
                    if let prefix { Text(prefix).font(.system(size: 12)) }
                    Text(address).textSelection(.enabled).font(.system(size: 12, design: .monospaced))
                        .contextMenu { Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string) } }
                }
                .foregroundStyle(Ink.dim)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(prefix.map { "\($0) " } ?? "Exit address, ")\(address)")
            } else {
                Text(checks.state.exhausted && !checks.checking ? "Couldn't check this exit's address" : "Checking the exit…")
                    .font(.system(size: 12)).foregroundStyle(Ink.dim)
            }
        }
    }
}
