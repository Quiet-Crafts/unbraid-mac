import Accessibility
import SwiftUI

/// The window's places: the apps (all of them, or those on one route), and the three insights.
enum Page: Hashable {
    /// nil = all apps; else a route id, DIRECT or BLOCK.
    case apps(String?)
    case traffic, activity, speed
}

/// Opens the location picker for a target: "" = new route, a route id = change it, "app:<key>" = new route for an app.
struct PickerTarget: Identifiable, Hashable {
    var id: String
}

/// Shared by the main window and the menu bar scene, including when the window is closed.
@Observable final class Presentation {
    static let shared = Presentation()
    var picker: PickerTarget?
    /// The page on show, or to show when the window next appears (a route clicked in the menu bar panel). Kept here and
    /// not in the window's state, so only the sidebar's selection and the page itself redraw when it changes.
    var page: Page? = .apps(nil)
    /// The route being renamed. Its alert lives in the window, since menus drop the modifiers that would host it.
    var renaming: String?
    /// The route about to be removed: its apps go back to the default and it can't be brought back, so it is confirmed first.
    var removing: String?
    /// The first app was just blocked: ask whether Block covers the home network too.
    var blockScope = false
    var settingsTab: Int?
    var tourStep: Int?
    func startTour() { page = .apps(nil); tourStep = 0; AppDelegate.openMain() }
    func nextTour() {
        guard let step = tourStep else { return }
        if step == 4 { tourStep = nil; return }
        if step == 1 { page = .apps(nil) }
        tourStep = step + 1
    }
}

extension EnvironmentValues {
    // Defaults, never set per view: a closure set in a body is a new value each time, and redraws everything reading it.
    @Entry var openPicker: (String) -> Void = { Presentation.shared.picker = PickerTarget(id: $0) }
    @Entry var navigate: (Page) -> Void = { Presentation.shared.page = $0 }
    @Entry var addProvider: () -> Void = {}
}

extension View {
    func tourAnchor(_ step: Int) -> some View {
        let presentation = Presentation.shared
        return popover(isPresented: Binding(get: { presentation.tourStep == step }, set: { if !$0 && presentation.tourStep == step { presentation.tourStep = nil } })) {
            TourCard(step: step)
        }
    }
}

private struct TourCard: View {
    let step: Int
    private let titles = ["Your routes", "Connect, pause, stop", "Choose per app", "Speed Test", "Settings"]
    private let bodies = [
        "Every app uses the default route unless you give it another. Add a route to choose another exit.",
        "Connect here. Once connected, you can pause or disconnect.",
        "Choose a route for each app in the Route column. Direct skips the VPN.",
        "Test the speed of a route. M-Lab publishes speed test results.",
        "Add connections and change protection here. Show this tour again from Help."
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(step + 1) / 5").font(.caption).foregroundStyle(.secondary)
            Text(titles[step]).font(.headline).accessibilityAddTraits(.isHeader)
            Text(bodies[step])
            HStack {
                Button("Close") { Presentation.shared.tourStep = nil }
                Spacer()
                Button(step == 4 ? "Done" : "Next") { Presentation.shared.nextTour() }.keyboardShortcut(.defaultAction)
            }
        }.padding(Layout.inset).frame(width: 300)
    }
}

/// The main window. Like Mail: the sidebar lists routes as mailboxes, the content is the apps on the selected one.
/// Dropping apps on a route moves them there. The connection sits at the sidebar's foot on every page.
struct RootView: View {
    private let model = AppModel.shared
    private let loginItem = LoginItem.shared
    @Bindable private var presentation = Presentation.shared
    @State private var adding = false
    @State private var addAfterPicker = false
    /// The picker's target while "Add a Provider" is open, so the picker comes back for it afterwards.
    @State private var resumePicker: String?
    @State private var newName = ""

    /// Another sheet or question is up.
    private var busy: Bool {
        model.disclosure || presentation.blockScope || presentation.renaming != nil || presentation.removing != nil
            || presentation.picker != nil || adding || addAfterPicker
    }

    var body: some View {
        Group {
            if model.signedIn {
                NavigationSplitView {
                    Sidebar()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
                } detail: {
                    // Pages switch without a cross-fade: a table kept on screen through a fade while its rows are torn
                    // down aborts inside SwiftUI (AppKitOutlineTableCoordinator).
                    DetailPage().frame(minWidth: 560, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                        // What needs attention shows above every page, not only the one it was raised on.
                        .safeAreaInset(edge: .top, spacing: 0) { VStack(spacing: 0) { Attention(); SafetyNotice() } }
                        .foregroundStyle(Ink.text).pageGround()
                        .toolbar(removing: .title)
                        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                        // Settings at the toolbar's trailing edge on every page, besides ⌘, and the app menu. Declared in
                        // an overlay, after the page, so it comes after the page's own items and never moves.
                        // The page's own items sit between this spacer and the gear, at the trailing side.
                        .toolbar { ToolbarSpacer(.flexible) }
                        .overlay { Color.clear.allowsHitTesting(false).accessibilityHidden(true).toolbar { SettingsToolbarItem() } }
                }
            } else {
                SignInView(first: true).frame(minWidth: 720, minHeight: 560)
            }
        }
        .focusedSceneValue(\.goTo, goTo)
        // A route removed while its page is open or kept for later: back to All Apps rather than an empty page.
        .onChange(of: model.setup.sidebarRoutes, initial: true) { _, ids in
            if case .apps(let id?) = presentation.page, !ids.contains(id) { presentation.page = .apps(nil) }
        }
        .alert("Over your plan's limit", isPresented: Binding(get: { model.limitAsk != nil }, set: { if !$0 { model.limitAsk = nil } })) {
            if let ask = model.limitAsk {
                if let server = ask.server, let share = ask.share {
                    Button("Use \(server) for Both Routes") { model.limitAsk = nil; share() }
                }
                Button("Change Anyway") { model.limitAsk = nil; ask.confirm() }
                Button("Cancel", role: .cancel) { model.limitAsk = nil }
            }
        } message: { Text(model.limitAsk?.text ?? "") }
        .alert("Rename Route", isPresented: Binding(get: { presentation.renaming != nil }, set: { if !$0 { presentation.renaming = nil } })) {
            TextField("Name", text: $newName, prompt: Text("e.g. Home VPS"))
            Button("Save") { if let id = presentation.renaming { model.renameRoute(id, newName) } }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: presentation.renaming) { _, id in newName = id.flatMap { model.setup.route($0)?.name } ?? "" }
        .alert("Block from your home network too?", isPresented: $presentation.blockScope) {
            Button("Block Home Network Too") { model.chooseBlockScope(.home) }
            Button("Internet Only") { model.chooseBlockScope(.internet) }
            Button("Decide Later", role: .cancel) {}
        } message: {
            Text("Blocked apps can't reach the internet. Should they also be kept away from devices on your home network, like your printer?\n\nBlocking turns on the kill switch: nothing goes online while unbraid reconnects. Change this in Settings › Protection.")
        }
        .alert("Remove \(presentation.removing.map(model.setup.label) ?? "this route")?",
               isPresented: Binding(get: { presentation.removing != nil }, set: { if !$0 { presentation.removing = nil } })) {
            Button("Remove Route", role: .destructive) { if let id = presentation.removing { model.removeRoute(id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            let n = presentation.removing.map(model.apps.count(on:)) ?? 0
            let profiles = model.setup.saved.filter { p in p.defaultRoute == presentation.removing || p.apps.values.contains(presentation.removing ?? "") }.map(\.name)
            let apps = n == 0 ? "No apps use this route." : "\(n) app\(n == 1 ? " goes" : "s go") back to the default route (\(model.setup.label(model.setup.defaultRoute)))."
            Text(apps + (profiles.isEmpty ? "" : " Used by profiles: \(profiles.joined(separator: ", ")).") + " This can't be undone.")
        }
        .sheet(item: $presentation.picker, onDismiss: {
            if addAfterPicker { addAfterPicker = false; adding = true }
        }) { item in
            PickerSheet(target: item.id).environment(model)
                .environment(\.addProvider) { resumePicker = item.id; addAfterPicker = true; presentation.picker = nil }
        }
        // The picker comes back for what the user was choosing a place for, with the new provider or server listed.
        .sheet(isPresented: $adding, onDismiss: {
            if let id = resumePicker { resumePicker = nil; presentation.picker = PickerTarget(id: id) }
        }) { SignInView(first: false, target: resumePicker ?? "") }
        // Asked once, after the first connection works, when nothing else is on screen; only an answer settles it (closing
        // the window keeps it for next time).
        .alert("Open unbraid at login?", isPresented: Binding(get: { loginItem.offer && !busy }, set: { _ in })) {
            Button("Open at Login") { loginItem.answer(true) }
            Button("Not Now", role: .cancel) { loginItem.answer(false) }
        } message: { Text("unbraid lives in the menu bar. It can open automatically when you log in. You can change this in Settings › General.") }
        .sheet(isPresented: Binding(get: { model.disclosure }, set: { if !$0 { model.cancelDisclosure() } })) {
            DisclosureSheet(model: model)
        }
        .alert("Show Tour?", isPresented: Binding(get: { model.signedIn && model.store.tourPending && !busy }, set: { _ in })) {
            Button("Show Tour") { model.store.tourPending = false; presentation.startTour() }
            Button("Not Now", role: .cancel) { model.store.tourPending = false }
        } message: { Text("Take a quick tour of unbraid. You can show it again from Help.") }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugHooks.pageNote)) { n in
            switch n.object as? String {
            case "traffic", "overview", "flows": presentation.page = .traffic
            case "activity": presentation.page = .activity
            case "speed": presentation.page = .speed
            case "route": presentation.page = .apps(model.setup.routes.first { $0.id != model.setup.defaultRoute }?.id ?? model.setup.defaultRoute)
            case let s? where s.hasPrefix("route:"): presentation.page = .apps(String(s.dropFirst(6)))
            default: presentation.page = .apps(nil)
            }
        }
        #endif
    }

    private var goTo: (Page) -> Void { { Presentation.shared.page = $0 } }
}

/// The open page. Its own view, so a page change doesn't reach the window's sheets and alerts.
private struct DetailPage: View {
    var body: some View {
        switch Presentation.shared.page ?? .apps(nil) {
        case .apps(let route): AppsView(route: route)
        case .traffic: TrafficView()
        case .activity: ActivityView()
        case .speed: SpeedTestView()
        }
    }
}

private struct DisclosureSheet: View {
    let model: AppModel
    @State private var accepted = false
    var body: some View {
        SheetFrame(title: "Before you start", width: SheetWidth.form) {
            VStack(alignment: .leading, spacing: 16) {
                if model.store.disclosed && !model.store.termsAccepted {
                    Text("Updated").font(.headline).accessibilityAddTraits(.isHeader)
                    Text("unbraid now has Terms of Use. Accept them once to go on; your routes and connection stay as they are.")
                } else {
                    Text(Disclosure.text)
                }
                Toggle("I accept the Terms of Use and have read the Privacy Policy", isOn: $accepted).toggleStyle(.checkbox)
                HStack {
                    SwiftUI.Link("Terms of Use", destination: URL(string: "https://unbraid.app/terms")!)
                    SwiftUI.Link("Privacy Policy", destination: URL(string: "https://unbraid.app/privacy")!)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Layout.gutter).padding(.bottom, Layout.inset)
        } actions: {
            Button("Not Now") { model.cancelDisclosure() }.keyboardShortcut(.cancelAction)
            Button("Continue") { model.acceptDisclosure() }.disabled(!accepted).keyboardShortcut(.defaultAction).contentButton(prominent: true)
        }
    }
}

/// All Apps, the routes (default first, then the others, Direct and Blocked), the insights, and the connection.
private struct Sidebar: View {
    private let model = AppModel.shared
    @Bindable private var presentation = Presentation.shared
    @Environment(\.openPicker) private var openPicker
    @Environment(\.undoManager) private var undo

    var body: some View {
        let s = model.setup
        // A list lets ⌘-click clear the selection; the page on show stays selected instead.
        List(selection: Binding(get: { presentation.page }, set: { if let page = $0 { presentation.page = page } })) {
            Label { Text("All Apps") } icon: { Image(systemName: "square.grid.2x2").foregroundStyle(Ink.accentText) }
                .badge(model.apps.listed.count).tag(Page.apps(nil))
            Section {
                ForEach(s.sidebarRoutes, id: \.self) { id in
                    RouteSidebarRow(id: id).tag(Page.apps(id))
                        .dropDestination(for: String.self) { items, _ in
                            // Only app keys: text dragged in from elsewhere is not an app.
                            let apps = items.filter { model.apps.app($0) != nil }
                            model.move(apps, to: id, undo: undo)
                            return !apps.isEmpty
                        }
                        .contextMenu { RouteActions(id: id) }
                }
            } header: {
                HStack {
                    Text("Routes")
                    Spacer()
                    Button { openPicker("") } label: { Image(systemName: "plus") }
                        .buttonStyle(.quiet).help("Add a route").accessibilityLabel("Add Route")
                }.tourAnchor(0)
            }
            Section("Insights") {
                Label { Text("Traffic") } icon: { Image(systemName: "chart.bar.xaxis").foregroundStyle(Ink.accentText) }.tag(Page.traffic)
                Label { Text("Activity") } icon: { Image(systemName: "calendar").foregroundStyle(Ink.accentText) }.tag(Page.activity)
                Label { Text("Speed Test") } icon: { Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(Ink.accentText) }.tag(Page.speed).tourAnchor(3)
            }
        }
        // The wordmark heads the sidebar; the connection sits at its foot, the same on every page.
        .safeAreaInset(edge: .top, spacing: 0) {
            Wordmark(size: 28).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 14)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ConnectionDock().tourAnchor(1) }
        .sidebarGround()
    }
}

/// A route in the sidebar: its slash and name, "Default" for the default, and how many apps leave through it.
private struct RouteSidebarRow: View {
    private let model = AppModel.shared
    let id: String

    var body: some View {
        let s = model.setup
        Label {
            HStack(spacing: 8) {
                Text(s.label(id)).lineLimit(1).layoutPriority(1)
                if id == s.defaultRoute {
                    ViewThatFits(in: .horizontal) {
                        Text("DEFAULT").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.6).foregroundStyle(Ink.dim)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Ink.high, in: RoundedRectangle(cornerRadius: Corner.mark))
                        Image(systemName: "checkmark.circle").font(.system(size: 12)).foregroundStyle(Ink.dim)
                            .help("Default route").accessibilityLabel("Default")
                    }
                }
            }
        } icon: { Slash(color: s.color(id)).frame(width: Measure.slashColumn) }
        .badge(model.apps.count(on: id))
        .help(s.route(id).map { place($0, model.vpn.state.servers) } ?? (id == DIRECT ? "Apps here skip the VPN" : s.blockedReach))
        .accessibilityLabel(id == s.defaultRoute ? "\(s.label(id)), default route" : s.label(id))
    }
}

/// What can be done to a route, for its sidebar row's context menu and its page's actions menu.
struct RouteActions: View {
    private let model = AppModel.shared
    let id: String
    @Environment(\.openPicker) private var openPicker

    var body: some View {
        let s = model.setup
        let r = s.route(id)
        if r != nil { Button("Change Location…") { openPicker(id) } }
        if r?.imported == true { Button("Rename…") { Presentation.shared.renaming = id } }
        if id != s.defaultRoute && id != BLOCK { Button("Make Default") { model.setDefault(id) } }
        if let r, !r.imported, let provider = Providers.get(r.loc.provider), provider.protection != nil {
            Menu(providerProtectionAvailable(s.prefs.effectiveFilter) ? "\(provider.name) blocking" : "\(provider.name) blocking (Off while unbraid’s filter is on for VPN routes)") {
                Button { model.setFilter(id, nil) } label: { Label("As Set for \(provider.name) in Settings", systemImage: r.filter == nil ? "checkmark" : "") }
                Button { model.setFilter(id, true) } label: { Label("On for This Route", systemImage: r.filter == true ? "checkmark" : "") }
                Button { model.setFilter(id, false) } label: { Label("Off for This Route", systemImage: r.filter == false ? "checkmark" : "") }
            }.disabled(!providerProtectionAvailable(s.prefs.effectiveFilter))
        }
        if r != nil && id != s.defaultRoute {
            Divider()
            Button("Remove Route…", role: .destructive) {
                Presentation.shared.removing = id
            }
        }
    }
}

extension Setup {
    /// What Block covers, by the kill switch's level: said plainly wherever Blocked is described.
    var blockedReach: String {
        prefs.killLevel == .home ? "No internet, tailnet or home network while unbraid is connected or paused (pings to local addresses aside)"
            : "No internet or tailnet while unbraid is connected or paused. Devices on your home network stay reachable (Settings › Protection)"
    }

    /// The sidebar's order: the default route, the other routes as added, then Direct and Blocked.
    var sidebarRoutes: [String] {
        [defaultRoute] + routes.map(\.id).filter { $0 != defaultRoute } + [DIRECT, BLOCK].filter { $0 != defaultRoute }
    }
}

extension AppCatalog {
    /// The apps the lists show: system apps, and routed apps no longer installed, only while they have a route of their own.
    var listed: [AppInfo] {
        let s = AppModel.shared.setup
        return apps.filter { !($0.system || $0.missing) || s.apps[$0.id] != nil }
    }

    /// Listed apps that leave through `route`, counting those that inherit the default.
    func count(on route: String) -> Int {
        let s = AppModel.shared.setup
        return listed.filter { s.routeOf($0.id) == route }.count
    }
}

/// The window's page, for the View menu's Go commands.
private struct GoToKey: FocusedValueKey { typealias Value = (Page) -> Void }
extension FocusedValues {
    var goTo: ((Page) -> Void)? {
        get { self[GoToKey.self] }
        set { self[GoToKey.self] = newValue }
    }
}

/// Notices, a connection error and unsaved changes, above whichever page is open.
private struct Attention: View {
    private let model = AppModel.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let error = model.vpn.state.error, unsaved = model.store.unsaved && !model.store.unsavedDismissed
            let names = keySetupNames(now: context.date)
            if model.notice != nil || error != nil || unsaved || !model.vpn.state.blocked.isEmpty || model.switchingProfile != nil || model.refusedProfile != nil || !names.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let name = model.switchingProfile { Text("Switching to \(name) · apps reconnect for a moment") }
                    if let name = model.refusedProfile {
                        HStack { Text("Couldn't switch to \(name). \(model.setup.profile ?? "Your previous setup") is still in use."); Button("Try Again") { model.switchProfile(name) }.contentButton() }
                    }
                    if let n = model.notice { NoticeRow(text: n).contentButton() }
                    if !names.isEmpty { Text("\(names.joined(separator: " and ")) is setting up your key. Its routes can take a minute to work.") }
                    if let e = error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Ink.failedText) }
                    ForEach(model.vpn.state.blocked.keys.sorted(), id: \.self) { id in
                        if let reason = model.vpn.state.blocked[id] {
                            Label("Apps on \((model.vpn.state.runState.appliedSetup ?? model.setup).label(id)) are blocked: \(reason)" + (model.vpn.state.retryAt[id].map { ". Next try at \($0.formatted(date: .omitted, time: .standard))." } ?? ""), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Ink.failedText)
                        }
                    }
                    if unsaved { UnsavedRow().contentButton() }
                }
                .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.gutter).padding(.vertical, 10).background(Ink.surface)
                .overlay(alignment: .bottom) { Hairline() }
                .fadesIn()
                .onAppear { announceKeySetup(names) }
                .onChange(of: names) { _, names in announceKeySetup(names) }
            }
        }
        .onChange(of: model.store.unsaved && !model.store.unsavedDismissed) { _, unsaved in
            if unsaved { AccessibilityNotification.Announcement("Changes couldn't be saved.").post() }
        }
    }

    private func announceKeySetup(_ names: [String]) {
        if !names.isEmpty {
            AccessibilityNotification.Announcement("\(names.joined(separator: " and ")) is setting up your key. Its routes can take a minute to work.").post()
        }
    }

    private func keySetupNames(now: Date) -> [String] {
        guard model.vpn.state.phase == .on, model.vpn.state.runState.standIn == .none,
              let setup = model.vpn.state.runState.appliedSetup else { return [] }
        let ids = Set(setup.activeRoutes.filter { !$0.imported }.map { $0.loc.provider })
        return ids.sorted().compactMap { id in
            guard let provider = Providers.get(id) else { return nil }
            let created = id == "ivpn" ? model.accounts[id].flatMap { try? Ivpn.account($0).createdAt } : nil
            return ProviderStatus.settingUp(signedIn: model.signedInAt[id], seconds: provider.keySetup, now: now)
                || ProviderStatus.keySettingUp(created: created, now: now, seconds: provider.keySetup) ? provider.name : nil
        }
    }
}

private struct SafetyNotice: View {
    private let model = AppModel.shared
    @Environment(\.openSettings) private var openSettings
    @State private var show = false
    private var buttons: some View {
        HStack {
            Button("Set Up") { Presentation.shared.settingsTab = 2; openSettings() }
            Button("Not Now") { model.store.snoozeSafety(); show = false }
            Button("Don't Remind Me Again") { model.store.safetyNever = true; show = false }
        }.contentButton().controlSize(.small).fixedSize(horizontal: true, vertical: false)
    }

    var body: some View {
        Group {
            if show {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Label("Apps go online without unbraid when it's off", systemImage: "shield").fixedSize()
                        Spacer(minLength: 8)
                        buttons
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Apps go online without unbraid when it's off", systemImage: "shield")
                        buttons
                    }
                }
                .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.gutter).padding(.vertical, 10).background(Ink.surface)
                .overlay(alignment: .bottom) { Hairline() }
                .fadesIn()
            }
        }
        .onChange(of: show) { _, show in
            if show { AccessibilityNotification.Announcement("Apps go online without unbraid when it's off").post() }
        }
        .task(id: model.vpn.state.phase) {
            if model.vpn.state.phase == .on && model.vpn.running != nil { model.store.safetyConnected = true }
            while !Task.isCancelled {
                let profile = await model.vpn.tunnel.protectionProfile()
                guard !Task.isCancelled else { return }
                show = Store.safetyDue(connected: model.store.safetyConnected, never: model.store.safetyNever,
                                       until: model.store.safetyUntil, now: .now,
                                       onDemand: profile?.onDemand, killSwitch: profile?.killSwitch)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

/// The gear: the last item on the toolbar on every page, on its own, in the accent colour so it's quick to find.
private struct SettingsToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            SettingsLink {
                Label { Text("Settings") } icon: { Image(systemName: "gearshape.fill").foregroundStyle(Ink.accentText) }
            }
            .help("Settings (⌘,)").tourAnchor(4)
        }
    }
}
