import SwiftUI

/// Websites with a route of their own: a website's route comes before its app's, in every app. Moving one is the same
/// gesture as moving an app: its Route menu, a drag onto a route in the sidebar, or Move To in its context menu.
struct WebsitesView: View {
    private let model = AppModel.shared
    @Environment(\.undoManager) private var undo
    @State private var query = ""
    @State private var selection = Set<String>()
    @State private var sort = AppsSort(terms: [.init(key: .name, ascending: true)])
    /// The week's bytes when the list was last sorted, as on the apps pages: rows keep their places while the numbers
    /// refresh. Sorting again (a column header) takes the latest.
    @State private var rank = WeekBytes.shared.bytes

    var body: some View {
        let s = model.setup
        let q = query.trimmingCharacters(in: .whitespaces)
        let rows = SitesTable.rows(s, sort: sort, rank: rank).filter { r in q.isEmpty || Sites.readings(r.id).contains { $0.localizedStandardContains(q) } }
        VStack(spacing: 0) {
            PageHeader(title: "Websites", subtitle: "\(Snapshot.websites(s.sites.count)) · A website's route comes before its app's")
            if s.sites.isEmpty {
                ContentUnavailableView {
                    Label("No websites yet", systemImage: "globe")
                } description: {
                    Text("Give a website its own route, Direct or Block. It applies whatever app opens it.")
                } actions: {
                    Button("Add Website…") { Presentation.shared.addSite = SiteTarget() }
                }
                .frame(maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: query).frame(maxHeight: .infinity)
            } else {
                SitesTable(rows: rows, selection: $selection, sort: $sort).layoutPriority(1)
                // Said only while a rule here isn't applied, so the page never promises a route a name doesn't take.
                let unapplied = s.sites.count != Sites.applied(s).count
                Text("A rule covers the address and every address under it. It applies in every app that looks names up through macOS, Direct apps included, while unbraid is connected; a blocked website stays blocked during a pause. A browser that uses its own secure DNS keeps its app's route." + (unapplied ? " A rule for a name your network or tailnet answers itself is not applied while it does." : ""))
                    .font(.system(size: 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    .padding(Layout.inset).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.surface, in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
                    .padding(.horizontal, Layout.gutter).padding(.top, 12).padding(.bottom, Layout.gutter)
                Spacer(minLength: 0)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                SearchField(text: $query, prompt: "Search websites").frame(minWidth: 150, idealWidth: 260, maxWidth: 320)
            }
            // Its own item: grouped with the search field, the two are drawn as one control.
            ToolbarItem(placement: .primaryAction) {
                let full = s.sites.count >= Sites.max
                Button { Presentation.shared.addSite = SiteTarget() } label: { Label("Add Website…", systemImage: "plus") }
                    .help(full ? SiteEdits.full : "Add a website").disabled(full)
            }
        }
        // ⌥⌘1…9 and Find act on this page's websites; Follow Default has no meaning for one.
        .background(SitesActions(selection: $selection))
        .onChange(of: rows.map(\.id)) { selection.formIntersection(rows.map(\.id)) }
        // The week's numbers, as the apps pages keep them: every 15 s in front, once a minute behind other apps.
        .task(id: model.setup.prefs.stats) {
            let week = WeekBytes.shared
            while !Task.isCancelled, model.setup.prefs.stats {
                let totals = await Stats.shared.appTotals(.week)
                guard !Task.isCancelled else { return }
                if totals != week.bytes { week.bytes = totals }
                // Statistics deleted while the order still leaned on them start it afresh.
                if rank.isEmpty || totals.isEmpty { rank = totals }
                try? await Task.sleep(for: .seconds(NSApp.isActive ? 15 : 60))
            }
            if !Task.isCancelled && !model.setup.prefs.stats { week.bytes = [:] }
        }
        .onChange(of: sort) { rank = WeekBytes.shared.bytes }
    }
}

/// The Apps menu's Move To and Find for the Websites page. Reads the selection itself, so a click redraws only this.
private struct SitesActions: View {
    @Binding var selection: Set<String>
    @Environment(\.undoManager) private var undo

    var body: some View {
        Color.clear.focusedSceneValue(\.sceneActions, SceneActions(
            find: { NotificationCenter.default.post(name: SearchField.focus, object: nil) },
            move: selection.isEmpty ? nil : { to in if let to { AppModel.shared.moveSites(Array(selection), to: to, undo: undo) } },
            followDefault: false))
    }
}

/// Websites in the apps table: on the Websites page, and under a route's apps on its page.
struct SitesTable: View {
    let rows: [Row]
    @Binding var selection: Set<String>
    @Binding var sort: AppsSort

    /// The rows: every website, or those on `route`, in `sort`'s order, each with its bytes this week when statistics
    /// count them, as they were in `rank` (the totals when the list was last sorted).
    static func rows(_ s: Setup, route: String? = nil, sort: AppsSort, rank: [String: Int64]) -> [Row] {
        let week = Self.week(rank)
        // A route's page lists the websites whose rules put them there; the Websites page lists every one saved.
        let listed = route == nil ? s.sites : Sites.applied(s)
        return listed.filter { route == nil || $0.value == route }
            .map { Row(id: $0.key, name: Sites.shown($0.key), routeName: s.label($0.value), week: week[$0.key] ?? 0) }
            .sorted(by: sort.inOrder)
    }

    /// The week's bytes per website address, out of the statistics' totals (which count a website under its own key).
    static func week(_ totals: [String: Int64]) -> [String: Int64] {
        totals.reduce(into: [:]) { out, e in if let site = StatsMath.site(e.key) { out[site] = e.value } }
    }

    /// The height that shows `count` rows under the header, so a short list doesn't hold an empty band.
    static func height(_ count: Int) -> CGFloat { 28 + AppsTable.rowHeight * CGFloat(count) + 8 }

    var body: some View {
        let week = Self.week(WeekBytes.shared.bytes)
        AppsTable(rows: rows, week: week, peak: week.values.max() ?? 0, page: "sites", selection: $selection, sort: $sort, sites: true)
            .frame(maxHeight: Self.height(rows.count)).pageWidth()
    }
}

/// Add Website: an address (a pasted link is fine) and the route it takes.
struct AddWebsiteSheet: View {
    let target: SiteTarget
    /// The main window's: the sheet's own goes with it.
    let undo: UndoManager?
    private let model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var choice: String
    @FocusState private var focused: Bool

    init(target: SiteTarget, undo: UndoManager?) {
        self.target = target
        self.undo = undo
        _address = State(initialValue: target.address)
        _choice = State(initialValue: SiteEdits.preselected(target.route, in: AppModel.shared.setup))
    }

    var body: some View {
        let s = model.setup
        let check = SiteEdits.check(address, in: s.sites)
        SheetFrame(title: "Add Website", subtitle: "The address and every address under it take the route you choose.") {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Address").overline()
                    TextField("Address", text: $address, prompt: Text("netflix.com, or paste a link"))
                        .textFieldStyle(.roundedBorder).labelsHidden().focused($focused).onSubmit(add)
                        .accessibilityLabel("Address")
                        .onKeyPress(.upArrow) { step(-1, s) }
                        .onKeyPress(.downArrow) { step(1, s) }
                    feedback(check).font(.system(size: 12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    // Taken, but in this setup its own resolver answers it: said before it is saved, as its row will say.
                    if case .valid(let name) = check, let why = Sites.notApplied(name, choice, in: s, tailnet: Sites.tailnet(of: s)) {
                        Text("Not applied now: \(why)").font(.system(size: 12)).foregroundStyle(Ink.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Route").overline()
                    // Up to eight rows show; more scroll. Up and Down choose from the address field too.
                    let routes = s.sidebarRoutes
                    ScrollViewReader { scroll in
                        ScrollView {
                            VStack(spacing: 0) {
                                // Each hairline is drawn over its row's top edge, so the rows are exactly a row tall
                                // apiece and eight fit the frame below without a sliver to scroll.
                                ForEach(Array(routes.enumerated()), id: \.element) { i, id in
                                    routeRow(id, s).id(id)
                                        .overlay(alignment: .top) { if i > 0 { Hairline().padding(.leading, 12 + Measure.slashColumn + 8) } }
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: Measure.tableRow * CGFloat(min(routes.count, 8)))
                        .onChange(of: choice) { withAnimation(nil) { scroll.scrollTo(choice) } }
                    }
                    .background(Ink.surface, in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Layout.gutter).padding(.bottom, Layout.inset)
        } status: {
            Text("\(s.sites.count) of \(Sites.max) websites")
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Add Website", action: add).keyboardShortcut(.defaultAction).contentButton(prominent: true)
                .disabled(!valid(check))
        }
        .onAppear { focused = true }
    }

    /// Up and Down in the address field choose the route above or below, as in a list.
    private func step(_ by: Int, _ s: Setup) -> KeyPress.Result {
        let routes = s.sidebarRoutes
        guard let i = routes.firstIndex(of: choice) ?? routes.indices.first else { return .ignored }
        choice = routes[max(0, min(routes.count - 1, i + by))]
        return .handled
    }

    @ViewBuilder private func feedback(_ check: SiteEdits.Check) -> some View {
        switch check {
        case .empty: Text("A rule covers the address and every address under it.").foregroundStyle(Ink.dim)
        case .valid(let name):
            let shown = Sites.shown(name), also = Sites.shown(SiteEdits.also(name))
            Text("Saved as \(Text(shown).fontWeight(.semibold)) · also covers \(also)").foregroundStyle(Ink.dim)
                .help("Saved as \(shown), also covers \(also)")
        case .refused(let why): Text(why).foregroundStyle(Ink.failedText).help(why)
        }
    }

    private func routeRow(_ id: String, _ s: Setup) -> some View {
        let chosen = id == choice
        let name = s.label(id) + (id == s.defaultRoute ? " · Default" : "")
        return Button { choice = id } label: {
            HStack(spacing: 8) {
                Slash(color: s.color(id)).frame(width: Measure.slashColumn)
                Text(name).lineLimit(1)
                Spacer(minLength: 8)
                if chosen { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.accentText) }
            }
            .padding(.horizontal, 12).frame(height: Measure.tableRow).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }

    private func valid(_ check: SiteEdits.Check) -> Bool { if case .valid = check { return true }; return false }

    private func add() {
        guard valid(SiteEdits.check(address, in: model.setup.sites)) else { return }
        if model.addSite(address, to: choice, undo: undo) == nil { dismiss() }
    }
}
