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
    /// The sort and the system-apps switch outlive the page, so leaving for Traffic and coming back keeps them.
    @Bindable private var filter = AppsFilter.shared
    @State private var selection = Set<String>()
    /// The route's websites, listed under its apps, and their own selection and order.
    @State private var siteSelection = Set<String>()
    @State private var siteSort = AppsSort(terms: [.init(key: .name, ascending: true)])
    /// The websites' own `rank`: sorting one list doesn't reorder the other.
    @State private var siteRank = WeekBytes.shared.bytes
    /// Bytes per app this week, from the statistics. Outlives the page, so coming back shows the numbers at once.
    private let week = WeekBytes.shared
    /// The week's bytes when the list was last sorted: rows keep their places while the numbers refresh underneath,
    /// so nothing moves under the pointer. Sorting again (a column header) takes the latest.
    @State private var rank = WeekBytes.shared.bytes
    /// The page's height, what sits above its lists and the Websites heading: what the choice between the fitted and
    /// the scrolling layout is made from. The page's height comes from the window, not the content. The other two are
    /// laid out at the page's width in both layouts (with macOS's overlay scroll bars), so they measure the same in
    /// either and the choice never changes its own inputs. With scroll bars always shown, the scrolling layout is a
    /// scroll bar narrower, so its text can only grow: that keeps the page scrolling, and the next switch back to the
    /// fitted layout measures the same or less, which still fits. One switch at most, never a loop.
    @State private var room: CGFloat = 0
    @State private var top: CGFloat = 0
    @State private var sitesHeading: CGFloat = 0

    var body: some View {
        let s = model.setup
        let rows = shown(s)
        let siteRows = route.map { SitesTable.rows(s, route: $0, sort: siteSort, rank: siteRank) } ?? []
        lists(s, rows, siteRows)
        // Exactly the page's height, whatever the content asks: an overflow can only run off the bottom, never push the
        // bands above the page under the toolbar.
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { room = $0 }
        // A route's page carries its colour: a soft light from the top, under the clear toolbar.
        .background(alignment: .top) { if let id = route, !reduceTransparency { RouteGlow(color: s.color(id)) } }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let id = route {
                    if s.route(id) != nil {
                        // A symbol like the items beside it, so the Settings gear keeps its place in a narrow window; its
                        // name is its tooltip and what VoiceOver reads, and texts that point to it call it the pin.
                        Button { Presentation.shared.picker = PickerTarget(id: id) } label: { Label(Self.changeLocation, systemImage: "mappin.and.ellipse") }
                            .help(Self.changeLocation)
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
                    Toggle("Include System Apps", isOn: $filter.showSystem)
                } label: {
                    Label("Filter", systemImage: filter.showSystem ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                }
                .help("Filter apps")
                Button(action: add) { Label("Add App…", systemImage: "plus") }.help("Add an app or command-line tool")
                    .disabled(!model.store.disclosed)
            }
        }
        // The menu commands read the selection in a child, so a click redraws that child and not the whole list.
        .background(AppsActions(selection: $selection, sites: $siteSelection, add: model.store.disclosed ? { add() } : nil))
        // Apps and the route's websites are two lists: selecting in one clears the other, so Move To, its shortcuts and
        // Delete act on the list the user last picked from.
        .onChange(of: selection) { if !selection.isEmpty, !siteSelection.isEmpty { siteSelection = [] } }
        .onChange(of: siteSelection) { if !siteSelection.isEmpty, !selection.isEmpty { selection = [] } }
        // Only the route's websites on screen stay selected, also once its last one has moved away and the list is gone:
        // Move To must never act on a website the page no longer shows.
        .onChange(of: shownSites) { _, shown in siteSelection.formIntersection(shown) }
        // A new page starts afresh: no selection, no search left over from the last one.
        .onAppear { ExitCheck.shared.watch(exitWatch, visible: route != DIRECT && route != BLOCK) }
        .onDisappear { ExitCheck.shared.watch(exitWatch, visible: false) }
        .onChange(of: route) {
            selection = []; siteSelection = []; query = ""
            ExitCheck.shared.watch(exitWatch, visible: route != DIRECT && route != BLOCK)
        }
        // Only what is on screen stays selected, so Move To never acts on apps the search or a move has hidden.
        // Pruned against the rows as they are now, not the ids this update captured: a reveal made in the same
        // update (see `add`) would otherwise be undone by the previous page's rows.
        .onChange(of: rows.map(\.id)) { selection.formIntersection(shown(model.setup).map(\.id)) }
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
                if siteRank.isEmpty || totals.isEmpty { siteRank = totals }
                // Every 15 s while unbraid is in front; once a minute behind other apps or minimised.
                try? await Task.sleep(for: .seconds(NSApp.isActive ? 15 : 60))
            }
            if !Task.isCancelled && !model.setup.prefs.stats { week.bytes = [:] }
        }
        .onChange(of: filter.sort) { rank = week.bytes }
        .onChange(of: siteSort) { siteRank = week.bytes }
    }

    /// The websites this route's page lists.
    private var shownSites: [String] { route.map { SiteEdits.applied($0, in: model.setup) } ?? [] }

    // MARK: Header

    @ViewBuilder private func header(_ s: Setup) -> some View {
        if let id = route {
            // With websites on it, the line says how many of each: first on Direct and Blocked, whose line is a sentence.
            let sites = SiteEdits.applied(id, in: s).count
            let count = sites == 0 ? nil : Snapshot.count(apps: model.apps.count(on: id), sites: sites)
            let parts = id == DIRECT || id == BLOCK ? [count, about(id, s)] : [about(id, s), count]
            PageHeader(title: s.label(id), subtitle: parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), slash: s.color(id),
                       status: model.vpn.state.health(id) == .silent ? (RouteHealth.status, Ink.failed) : nil)
        } else {
            let custom = s.apps.keys.filter { model.apps.app($0) != nil }.count
            PageHeader(title: "All Apps", subtitle: "\(model.apps.listed.count) apps · " + (custom == 0 ? "all on the default route" : "\(custom) with their own route"))
        }
    }

    /// One line on what a route is: where it leaves and through which server, or what Direct and Blocked mean.
    private func about(_ id: String, _ s: Setup) -> String {
        switch id {
        case DIRECT: return "No VPN: these apps use your normal connection"
        case BLOCK: return s.blockedReach
        default:
            guard let r = s.route(id) else { return "" }
            let live = model.vpn.state.phase == .on ? model.vpn.state.servers[id] : nil
            let p = place(r, model.vpn.state.servers, tcp: model.vpn.state.autoTcp, routes: s.routes)
            return [live.map { "\(p) · \(serverId(r, $0))" } ?? p, id == s.defaultRoute ? "every app that follows the default" : nil]
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

    /// What sits above the lists, and the lists: fitted into the page's height when it holds two whole rows of each
    /// list, else one page that scrolls.
    @ViewBuilder private func lists(_ s: Setup, _ rows: [Row], _ siteRows: [Row]) -> some View {
        let plan = fit(apps: rows.isEmpty ? Self.emptyRows : rows.count, sites: min(siteRows.count, 4))
        if let plan {
            VStack(spacing: 0) {
                above(s)
                // With websites under them, the apps take only the rows the page has room for (the empty state's
                // room when there are none), so the two lists sit together and a short window shrinks both.
                if siteRows.isEmpty { table(rows).frame(maxHeight: .infinity).layoutPriority(1) }
                else {
                    table(rows).frame(height: SitesTable.height(plan.apps))
                    sites(siteRows, rowsShown: plan.sites)
                    Spacer(minLength: 0)
                }
            }
        } else {
            // Too short for two whole rows of each list: one page that scrolls, every part at its natural height.
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    above(s)
                    table(rows).frame(height: SitesTable.height(rows.isEmpty ? Self.emptyRows : rows.count))
                    if !siteRows.isEmpty { sites(siteRows, rowsShown: siteRows.count) }
                }
            }
            // Each route's page starts at its top.
            .id(route)
        }
    }

    /// The page's title, its address line, a route's health cards and live strip, and All Apps' notes: what sits
    /// above the lists.
    private func above(_ s: Setup) -> some View {
        aboveParts(s).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { top = $0 }
    }

    private func aboveParts(_ s: Setup) -> some View {
        VStack(spacing: 0) {
            header(s)
            if let id = route {
                // Every route's page keeps the address line's room, with or without an address (Direct, Blocked, a
                // route still being checked or without apps), so its title, graph and list sit where the others' do.
                ZStack(alignment: .leading) {
                    ExitLine.room
                    ExitLine(route: id)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.gutter).padding(.bottom, 10).pageWidth()
            } else if s.route(s.defaultRoute) != nil {
                // On All Apps it's the default route's exit, so it says whose it is.
                ExitLine(route: s.defaultRoute, prefix: "\(s.route(s.defaultRoute)?.name ?? "Default route") exits as")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Layout.gutter).padding(.bottom, 10).pageWidth()
            }
            if let id = route, let r = s.route(id) { RouteHealthCards(route: r) }
            if let id = route, id == DIRECT || s.route(id) != nil { LiveStrip(route: id, color: s.color(id), week: week) }
            banners(s)
        }
    }

    /// The route's websites under its apps, only when it has any: the same rows as the Websites page.
    private func sites(_ rows: [Row], rowsShown: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Websites").overline().padding(.horizontal, Layout.gutter).accessibilityAddTraits(.isHeader)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sitesHeading = $0 }
            SitesTable(rows: rows, selection: $siteSelection, sort: $siteSort).frame(height: SitesTable.height(rowsShown))
        }
        .padding(.top, 10).padding(.bottom, Layout.gutter)
        .onChange(of: rows.map(\.id)) { siteSelection.formIntersection(rows.map(\.id)) }
    }

    static let changeLocation = "Change Location…"

    /// The empty state's room, in rows, when a route with websites has no apps.
    private static let emptyRows = 6

    /// How the page's height is shared (see `PageRoom`); nil: the page scrolls. All Apps always fits (its list fills
    /// the page), and so does a page not measured yet.
    private func fit(apps: Int, sites: Int) -> PageRoom.Plan? {
        guard route != nil else { return .init(apps: apps, sites: sites) }
        let lists = sites == 0 ? SitesTable.height(0) : SitesTable.height(0) * 2 + 10 + sitesHeading + 6 + Layout.gutter
        return PageRoom.plan(room: room, top: top, chrome: lists, row: AppsTable.rowHeight, apps: apps, sites: sites)
    }

    // MARK: Table

    private func table(_ rows: [Row]) -> some View {
        // Icons and the tools' patterns can change without the list of apps changing.
        let _ = (model.apps.revision, model.apps.patternRevision)
        return AppsTable(rows: rows, week: week.bytes, peak: week.peak, page: route ?? "", selection: $selection, sort: $filter.sort)
            .background { if rows.isEmpty { Color.clear.tourAnchor(2) } }
            // Step 3 of the tour points at the first row's route, in the Route column.
            .overlay(alignment: .topLeading) {
                if !rows.isEmpty { Color.clear.frame(width: 140, height: 28).offset(x: 335, y: 36).allowsHitTesting(false).accessibilityHidden(true).tourAnchor(2) }
            }
            .pageWidth()
            .overlay { empty(rows) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // A few matches are listed, but others are among the hidden system apps.
                let hidden = hiddenSystemMatches(model.setup)
                if !rows.isEmpty && hidden > 0 {
                    HStack(spacing: 6) {
                        Text("\(hidden) macOS \(hidden == 1 ? "app matches" : "apps match") too.")
                        Button("Show System Apps") { filter.showSystem = true }.contentButton()
                    }
                    .font(.system(size: 12)).foregroundStyle(Ink.dim).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                }
            }
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
            else if !query.isEmpty {
                let hidden = hiddenSystemMatches(model.setup)
                if hidden > 0 {
                    // Mail, Messages, App Store and the like are system apps, hidden unless asked for.
                    ContentUnavailableView {
                        Label("No Results for “\(query)”", systemImage: "magnifyingglass")
                    } description: {
                        Text("\(hidden) macOS \(hidden == 1 ? "app matches" : "apps match"), but system apps are hidden.")
                    } actions: {
                        Button("Show System Apps") { filter.showSystem = true }
                    }
                } else { ContentUnavailableView.search(text: query) }
            }
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
            (a.missing ? s.apps[a.id] != nil : filter.showSystem || !a.system || s.apps[a.id] != nil) && (route == nil || s.routeOf(a.id) == route)
                && AppSearch.matches(name: a.name, id: a.id, query: q)
        }
        .map { a in Row(id: a.id, name: a.name, routeName: s.label(s.routeOf(a.id)), week: rank[a.id] ?? 0) }
        .sorted(by: filter.sort.inOrder)
    }

    /// Apps from macOS itself that match the search but are hidden, so the page can say so instead of "No Results".
    private func hiddenSystemMatches(_ s: Setup) -> Int {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !filter.showSystem else { return 0 }
        return model.apps.apps.filter { a in
            a.system && !a.missing && s.apps[a.id] == nil && (route == nil || s.routeOf(a.id) == route)
                && AppSearch.matches(name: a.name, id: a.id, query: q)
        }.count
    }

    /// Any app or command-line tool, wherever it lives. It is listed (searched by name, so it is easy to find) and its
    /// Route menu does the rest; a tool is remembered once it has a route.
    private func add() {
        let p = NSOpenPanel()
        p.message = "Choose an app or a command-line tool. An interpreter such as python3 routes every script it runs; a script such as pip3 runs as its interpreter, so its own path routes nothing. Press ⇧⌘G to type a path such as /usr/bin/curl."
        p.prompt = "Add"
        // A tool picked through a link (Homebrew) keeps the link path, which survives upgrades.
        p.resolvesAliases = false
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK, let url = p.url else { return }
        // An app, or a program that can run: any other file would be listed and route nothing.
        guard AppScan.bundle(url, system: false) != nil || FileManager.default.isExecutableFile(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "That file isn't an app or a program."
            alert.informativeText = "Choose an app, or a command-line tool such as /usr/bin/curl."
            alert.runModal()
            return
        }
        let key = model.apps.add(url)
        // From a route's page the app goes onto that route and is shown there.
        if let route { model.move([key], to: route, undo: undo) { if $0 { reveal(key) } } } else { reveal(key) }
    }

    /// Finds an added app in the list and selects it.
    private func reveal(_ key: String) {
        // A listed system app stays one; without a route it is listed only with system apps, so show them.
        if model.apps.app(key)?.system == true, model.setup.apps[key] == nil { filter.showSystem = true }
        query = model.apps.app(key)?.name ?? ""; selection = [key]
    }
}

/// The apps list's sort and system-apps switch. Kept outside the page so they survive a visit to another page.
@Observable final class AppsFilter {
    static let shared = AppsFilter()
    var sort = AppsSort()
    var showSystem = false
}

/// The Apps menu and Find for this page. Reads the selection itself, so selecting rows redraws only this. On a route's
/// page Move To moves the selected websites when those are what is selected (the two selections never coexist), and
/// Follow Default, which a website has no meaning for, is then off.
private struct AppsActions: View {
    @Binding var selection: Set<String>
    @Binding var sites: Set<String>
    let add: (() -> Void)?
    @Environment(\.undoManager) private var undo

    var body: some View {
        let move: ((String?) -> Void)? = !sites.isEmpty ? { to in if let to { AppModel.shared.moveSites(Array(sites), to: to, undo: undo) } }
            : selection.isEmpty ? nil : { AppModel.shared.move(Array(selection), to: $0, undo: undo) }
        Color.clear.focusedSceneValue(\.sceneActions, SceneActions(
            addApp: add,
            find: { NotificationCenter.default.post(name: SearchField.focus, object: nil) },
            move: move, followDefault: sites.isEmpty))
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
    /// Off for websites, which have no default to follow.
    var followDefault = true
    let move: (String?) -> Void

    var body: some View {
        let ids = model.setup.sidebarRoutes
        ForEach(Array(ids.enumerated()), id: \.element) { i, id in
            let b = Button(model.setup.label(id)) { move(id) }
            if i < 9 { b.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option]) } else { b }
        }
        Divider()
        Button("Follow Default") { move(nil) }.keyboardShortcut("0", modifiers: [.command, .option]).disabled(!followDefault)
    }
}

/// Under a route's header: while its server isn't answering, what that means for its apps and websites; and for an
/// own server, the switch for its internet check.
private struct RouteHealthCards: View {
    let route: Route
    private let model = AppModel.shared
    @Environment(\.openPicker) private var openPicker

    /// The exit device the running route goes through, while Tailscale runs and lists it as offline: its apps have no
    /// internet until it is back or the route gets another exit.
    private var offlineDevice: RouteHealth.ExitDevice? {
        let v = model.vpn.state
        guard v.phase == .on, TailscaleStatus(v.tsState) == .connected, let ip = route.tsExit,
              model.vpn.running?.routes.first(where: { $0.id == route.id })?.tsExit == ip else { return nil }
        return RouteHealth.offlineExit(ip: ip, nodes: v.tsExitNodes.map { RouteHealth.ExitDevice(name: $0.name, ip: $0.ip, online: $0.online, id: $0.id) })
    }

    var body: some View {
        let silent = model.vpn.state.health(route.id) == .silent
        let check = RouteHealth.offersInternetCheck(route)
        let offline = offlineDevice
        if silent || check || offline != nil {
            VStack(spacing: 12) {
                if let offline {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Ink.failedText).frame(width: Measure.slashColumn)
                        Text(RouteHealth.offlineExitText(offline.name)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(RouteHealth.chooseExit) { openPicker(route.id) }.controlSize(.small)
                    }
                    .padding(.horizontal, Layout.inset).padding(.vertical, 14).card()
                }
                if silent {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Ink.failedText).frame(width: Measure.slashColumn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(RouteHealth.title).font(.system(size: 13, weight: .semibold))
                            Text(RouteHealth.explanation(route, apps: model.apps.count(on: route.id),
                                                        sites: SiteEdits.applied(route.id, in: model.setup).count,
                                                        othersAnswer: model.vpn.state.answering.contains { $0 != route.id }))
                                .font(.system(size: 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Layout.inset).padding(.vertical, 14).card()
                    .accessibilityElement(children: .combine)
                }
                if check {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(RouteHealth.checkTitle).font(.system(size: 13))
                            Text(RouteHealth.checkCaption).font(.system(size: 12)).foregroundStyle(Ink.dim).lineLimit(2).help(RouteHealth.checkCaption)
                        }
                        .layoutPriority(1)
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(get: { route.checksInternet }, set: { model.setCheckInternet(route.id, $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .accessibilityLabel(RouteHealth.checkTitle).accessibilityHint(RouteHealth.checkCaption)
                    }
                    .padding(.horizontal, Layout.inset).padding(.vertical, 8).frame(minHeight: Measure.listRow).card()
                }
            }
            .padding(.horizontal, Layout.gutter).padding(.bottom, 14).pageWidth()
        }
    }
}

private extension View {
    func card() -> some View { background(Ink.surface, in: .rect(cornerRadius: Corner.card, style: .continuous)) }
}

/// A route's speed now, its last minute and its week, under the page header while connected with statistics on.
/// Direct has one too, so every page with apps that go somewhere looks the same.
private struct LiveStrip: View {
    let route: String
    let color: Color
    /// Read here rather than by the page, so the week's refresh redraws the strip and not the list.
    let week: WeekBytes
    private let model = AppModel.shared

    var body: some View {
        if model.vpn.state.phase == .on && model.setup.prefs.stats {
            let series = route == DIRECT ? Stats.shared.live.direct : Stats.shared.live.down[route] ?? []
            let week = self.week.routes[route] ?? 0, apps = model.apps.count(on: route), sites = SiteEdits.applied(route, in: model.setup).count
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
                    Text(Snapshot.count(apps: apps, sites: sites)).font(.system(size: 12)).foregroundStyle(Ink.dim)
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

    /// The height of one address line in either of its fonts, kept by a route's page while it shows none.
    static var room: some View {
        ZStack {
            Text(verbatim: "0").font(.system(size: 12))
            Text(verbatim: "0").font(.system(size: 12, design: .monospaced))
        }
        .hidden().accessibilityHidden(true)
    }

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
