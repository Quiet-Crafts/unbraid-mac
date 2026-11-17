import SwiftUI

/// Websites with a route of their own: a website's route comes before its app's, in every app. Moving one is the same
/// gesture as moving an app: its Route menu, a drag onto a route in the sidebar, or Move To in its context menu.
struct WebsitesView: View {
    private let model = AppModel.shared
    @Environment(\.undoManager) private var undo
    @State private var query = ""
    @State private var selection = Set<String>()
    @State private var sort = AppsSort(terms: [.init(key: .name, ascending: true)])

    var body: some View {
        let s = model.setup
        let q = query.trimmingCharacters(in: .whitespaces)
        let rows = SitesTable.rows(s, sort: sort).filter { q.isEmpty || $0.name.localizedStandardContains(q) }
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
                Text("A rule covers the address and every address under it. It applies in every app that looks names up through macOS, Direct apps included, while unbraid is connected. A browser that uses its own secure DNS keeps its app's route.")
                    .font(.system(size: 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    .padding(Layout.inset).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.surface, in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
                    .padding(.horizontal, Layout.gutter).padding(.top, 12).padding(.bottom, Layout.gutter)
                Spacer(minLength: 0)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                SearchField(text: $query, prompt: "Search websites").frame(minWidth: 150, idealWidth: 260, maxWidth: 320)
                Button { Presentation.shared.addSite = SiteTarget() } label: { Label("Add Website…", systemImage: "plus") }
                    .help("Add a website")
            }
        }
        // ⌥⌘1…9 and Find act on this page's websites; Follow Default has no meaning for one.
        .background(SitesActions(selection: $selection))
        .onChange(of: rows.map(\.id)) { selection.formIntersection(rows.map(\.id)) }
    }
}

/// The Apps menu's Move To and Find for the Websites page. Reads the selection itself, so a click redraws only this.
private struct SitesActions: View {
    @Binding var selection: Set<String>
    @Environment(\.undoManager) private var undo

    var body: some View {
        Color.clear.focusedSceneValue(\.sceneActions, SceneActions(
            find: { NotificationCenter.default.post(name: SearchField.focus, object: nil) },
            move: selection.isEmpty ? nil : { to in if let to { AppModel.shared.moveSites(Array(selection), to: to, undo: undo) } }))
    }
}

/// Websites in the apps table: on the Websites page, and under a route's apps on its page.
struct SitesTable: View {
    let rows: [Row]
    @Binding var selection: Set<String>
    @Binding var sort: AppsSort

    /// The rows: every website, or those on `route`, in `sort`'s order. A website has no week of its own yet.
    static func rows(_ s: Setup, route: String? = nil, sort: AppsSort) -> [Row] {
        s.sites.filter { route == nil || $0.value == route }
            .map { Row(id: $0.key, name: $0.key, routeName: s.label($0.value), week: 0) }
            .sorted(by: sort.inOrder)
    }

    /// The height that shows `count` rows under the header, so a short list doesn't hold an empty band.
    static func height(_ count: Int) -> CGFloat { 28 + AppsTable.rowHeight * CGFloat(count) + 8 }

    var body: some View {
        AppsTable(rows: rows, week: [:], peak: 0, page: "sites", selection: $selection, sort: $sort, sites: true)
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
                    feedback(check).font(.system(size: 12)).lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Route").overline()
                    VStack(spacing: 0) {
                        ForEach(Array(s.sidebarRoutes.enumerated()), id: \.element) { i, id in
                            if i > 0 { Hairline().padding(.leading, 12 + Measure.slashColumn + 8) }
                            routeRow(id, s)
                        }
                    }
                    .background(Ink.surface, in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
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
        .onAppear { focused = target.address.isEmpty }
    }

    @ViewBuilder private func feedback(_ check: SiteEdits.Check) -> some View {
        switch check {
        case .empty: Text("A rule covers the address and every address under it.").foregroundStyle(Ink.dim)
        case .valid(let name): Text("Saved as \(Text(name).fontWeight(.semibold)) · also covers \(SiteEdits.also(name))").foregroundStyle(Ink.dim)
        case .refused(let why): Text(why).foregroundStyle(Ink.failedText)
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
