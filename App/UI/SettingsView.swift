import ServiceManagement
import SwiftUI

// The Settings window (⌘,): a sidebar of panes (General, Providers, Home access, Tailscale, Protection, Statistics,
// About), each a page of rows built from the shared SettingsPage and SettingsRow, and the sheets they open. Also
// `Site`, the unbraid.app addresses the app links to.

private enum Pane: Int, CaseIterable, Identifiable {
    case general = 5, providers = 0, home = 6, tailscale = 1, protection = 2, statistics = 3, about = 4
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .providers: "Providers"
        case .home: "Home access"
        case .tailscale: "Tailscale"
        case .protection: "Protection"
        case .statistics: "Statistics"
        case .about: "About"
        }
    }
    var color: Color {
        switch self {
        case .general, .about: IconTile.Tile.gray
        case .providers: IconTile.Tile.blue
        case .home: IconTile.Tile.green
        case .tailscale: IconTile.Tile.indigo
        case .protection: IconTile.Tile.red
        case .statistics: IconTile.Tile.purple
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .providers: "server.rack"
        case .home: "house.fill"
        case .tailscale: "circle.grid.3x3.fill"
        case .protection: "shield.fill"
        case .statistics: "chart.bar.fill"
        case .about: "info.circle.fill"
        }
    }
}

struct SettingsView: View {
    /// Opens where it was left. A setting's own link (`settingsTab`) goes first.
    @State private var pane: Pane? = (UserDefaults.standard.object(forKey: SettingsView.paneKey) as? Int).flatMap(Pane.init(rawValue:)) ?? .general
    private static let paneKey = "settingsPane"
    @State private var providerPath: [String] = []
    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section { row(.general) }
                Section { row(.providers); row(.home); row(.tailscale) }
                Section { row(.protection); row(.statistics) }
                Section { row(.about) }
            }.listStyle(.sidebar).tint(Ink.accent).sidebarGround()
                .toolbar(removing: .sidebarToggle).navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
        } detail: {
            let selected = pane ?? .general
            NavigationStack(path: $providerPath) {
                Group {
                    switch selected {
                    case .general: GeneralTab()
                    case .providers: ConnectionsTab(path: $providerPath)
                    case .home: HomeTab()
                    case .tailscale: TailscaleTab()
                    case .protection: ProtectionTab()
                    case .statistics: StatisticsTab()
                    case .about: AboutTab()
                    }
                }.navigationTitle(selected.title)
                .navigationDestination(for: String.self) { id in
                    if let provider = Providers.get(id) { ProviderDetail(provider: provider, path: $providerPath) }
                }
            }
        }
        .onChange(of: pane) { _, new in
            providerPath.removeAll()
            if let new { UserDefaults.standard.set(new.rawValue, forKey: Self.paneKey) }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(width: 860, height: 600)
        .onChange(of: Presentation.shared.settingsTab, initial: true) { _, target in
            if let target { if let value = Pane(rawValue: target) { pane = value }; Presentation.shared.settingsTab = nil }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugHooks.settingsNote)) {
            if let value = $0.object as? Int, let target = Pane(rawValue: value) { pane = target }
        }
        #endif
    }
    private func row(_ pane: Pane) -> some View {
        Label { Text(pane.title) } icon: { IconTile(symbol: pane.symbol, color: pane.color, size: 20) }.tag(pane)
    }
}

private struct SettingsTileKey: EnvironmentKey {
    static let defaultValue = IconTile.Tile.gray
}

private extension EnvironmentValues {
    var settingsTile: Color {
        get { self[SettingsTileKey.self] }
        set { self[SettingsTileKey.self] = newValue }
    }
}

private struct SettingsPage<Content: View, Actions: View>: View {
    let title: String, subtitle: String
    var tile: Color = IconTile.Tile.gray
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: title, subtitle: subtitle) { actions }
            Form { content }.formStyle(.grouped).scrollContentBackground(.hidden).environment(\.settingsTile, tile)
        }.pageGround()
    }
}

private extension SettingsPage where Actions == EmptyView {
    init(title: String, subtitle: String, tile: Color = IconTile.Tile.gray, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, tile: tile, content: content, actions: { EmptyView() })
    }
}

private struct SettingsRow<Accessory: View, Below: View>: View {
    let title: String
    var caption: String? = nil
    var symbol: String
    var tile: Color? = nil
    var mark: String? = nil
    var status: ProviderStatus? = nil
    var captionDot: Color? = nil
    var route: Route? = nil
    /// Long captions (the source offer) may need every line.
    var captionLines: Int? = 2
    @Environment(\.settingsTile) private var paneTile
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var below: Below
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Group {
                    if let route { RouteBadge(route: route) }
                    else if let mark { IconTile(text: mark, color: IconTile.Tile.gray, size: 24) }
                    else { IconTile(symbol: symbol, color: tile ?? paneTile, size: 24) }
                }.frame(width: Measure.rowIcon, height: Measure.rowIcon).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13))
                    if let status { ProviderStatusLine(status: status) }
                    else if let caption {
                        HStack(spacing: 5) {
                            if let captionDot { StatusDot(color: captionDot) }
                            Text(caption).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(captionLines).help(caption)
                        }
                    }
                }.frame(minWidth: 160, alignment: .leading).layoutPriority(1).accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                // A button keeps its whole title; the caption wraps instead.
                accessory.fixedSize()
            }
            if Below.self != EmptyView.self {
                below.padding(.leading, Measure.rowIcon + 12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // A row used as a button answers a click anywhere across it, not only on its text.
        .frame(minHeight: Measure.listRow).contentShape(.rect)
    }
}

private extension SettingsRow where Below == EmptyView {
    init(title: String, caption: String? = nil, symbol: String, tile: Color? = nil, mark: String? = nil,
         status: ProviderStatus? = nil, captionDot: Color? = nil, route: Route? = nil, captionLines: Int? = 2,
         @ViewBuilder accessory: () -> Accessory) {
        self.init(title: title, caption: caption, symbol: symbol, tile: tile, mark: mark, status: status,
                  captionDot: captionDot, route: route, captionLines: captionLines, accessory: accessory, below: { EmptyView() })
    }
}

private extension AppModel {
    func pref(_ key: WritableKeyPath<Prefs, Bool>) -> Binding<Bool> {
        Binding(get: { self.setup.prefs[keyPath: key] }, set: { v in self.setPrefs { $0[keyPath: key] = v } })
    }
    /// A running tunnel keeps the profile it started with; some options only reach it on the next connect.
    var tunnelUp: Bool { vpn.state.phase == .on || vpn.state.phase == .paused }
    /// What changing a profile option does now: connected, the VPN restarts at once (a moment without it).
    var appliesLater: String { vpn.state.phase == .on ? "Changing this restarts the VPN: for a moment apps may use your normal connection." : "Applies when you resume." }
}

// MARK: - General

private struct GeneralTab: View {
    private let model = AppModel.shared
    @AppStorage(Transparency.pageKey) private var pageClearness = 0.0
    @AppStorage(Transparency.sidebarKey) private var sidebarSolidity = 0.0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let ext = model.vpn.tunnel.ext
        let allowed = Transparency.allowed(reduceTransparency: reduceTransparency, contrast: contrast)
        let pagePercent = Int((Transparency.bounded(pageClearness) * 100).rounded())
        let sidebarPercent = Int((Transparency.bounded(sidebarSolidity) * 100).rounded())
        SettingsPage(title: "General", subtitle: "Appearance, transparency and startup") {
            Section { AppearanceTiles() } header: { Text("Appearance") } footer: { Text("System follows the Mac's light and dark setting.") }
            Section {
                TransparencyTiles(allowed: allowed)
                SettingsRow(title: "Page background", caption: pagePercent == 0 ? "Solid" : "See-through \(pagePercent)%", symbol: "rectangle.on.rectangle") {
                    EmptyView()
                } below: {
                    Slider(value: $pageClearness, in: 0...1) { Text("Page background") } minimumValueLabel: { end("Solid") } maximumValueLabel: { end("See-through") } ticks: { SliderTick(0); SliderTick(0.5); SliderTick(1) }
                        .labelsHidden().accessibilityValue("\(pagePercent) percent").disabled(!allowed)
                }
                SettingsRow(title: "Sidebar", caption: sidebarPercent == 0 ? "System glass" : "Solid \(sidebarPercent)%", symbol: "sidebar.left") {
                    EmptyView()
                } below: {
                    Slider(value: $sidebarSolidity, in: 0...1) { Text("Sidebar") } minimumValueLabel: { end("Glass") } maximumValueLabel: { end("Solid") } ticks: { SliderTick(0); SliderTick(0.5); SliderTick(1) }
                        .labelsHidden().accessibilityValue("\(sidebarPercent) percent").disabled(!allowed)
                }
                SettingsRow(title: "Liquid Glass", caption: "How clear the glass is: set in System Settings", symbol: "drop", tile: IconTile.Tile.teal) {
                    Button("Open Appearance Settings…") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.Appearance-Settings.extension") { NSWorkspace.shared.open(u) }
                    }.contentButton()
                }
            } header: { Text("Transparency") } footer: {
                Text(allowed ? "The page never goes so clear that text is hard to read, and cards stay solid. Reduce Transparency and Increase Contrast in Accessibility turn this off." : "Off while Reduce Transparency or Increase Contrast is on in Accessibility. Cards, lists and text stay solid.")
            }
            Section {
                LoginItemToggle()
                SettingsRow(title: "Network extension", caption: extensionStatus(ext).0, symbol: "puzzlepiece.extension", captionDot: extensionStatus(ext).1) {
                    Button("Open Login Items…") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(u) }
                    }.contentButton().help("Open Login Items & Extensions…")
                } below: {
                    if case .failed = ext { Button("Try Again") { model.vpn.tunnel.installExtension() }.contentButton() }
                }
            } header: { Text("Startup") } footer: { Text("macOS asks once to allow the extension. It runs the tunnel for every app.") }
        }
    }
    /// A slider's end label: small and quiet, one width for both sliders so their tracks line up.
    private func end(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Ink.dim).lineLimit(1).fixedSize().frame(width: 76)
    }
    private func extensionStatus(_ ext: TunnelControl.Extension) -> (String, Color) {
        switch ext {
        case .ready: ("Active", Ink.successText)
        case .installing, .unknown: ("Checking", Ink.off)
        case .needsApproval: ("Needs approval", Ink.warningText)
        case .needsRestart: ("Restart your Mac to finish installing", Ink.warningText)
        case .failed(let why): (why, Ink.failedText)
        }
    }
}

private struct SubToggle: View {
    let title: String, sub: String
    var symbol: String = "switch.2"
    @Binding var isOn: Bool
    init(_ title: String, _ sub: String, symbol: String = "switch.2", isOn: Binding<Bool>) {
        self.title = title; self.sub = sub; self.symbol = symbol; _isOn = isOn
    }
    var body: some View {
        SettingsRow(title: title, caption: sub, symbol: symbol) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(title).accessibilityHint(sub)
        }
    }
}

private struct ErrorLine: View {
    let text: String
    var body: some View { Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Ink.failedText) }
}

// MARK: - Connections

private struct ConnectionsTab: View {
    private let model = AppModel.shared
    @State private var adding = false
    @Binding var path: [String]
    @State private var importer = Importer()
    @State private var erasing = false
    @State private var now = Date.now

    var body: some View {
        let s = model.setup
        let signed = Providers.all.filter { model.accounts[$0.id] != nil }
        SettingsPage(title: "Providers", subtitle: "\(signed.count) provider\(signed.count == 1 ? "" : "s") · \(s.servers.count) server\(s.servers.count == 1 ? "" : "s") of your own", tile: IconTile.Tile.blue) {
            if let n = model.notice { Section { NoticeRow(text: n) } }
            Section("Signed in") {
                ForEach(signed, id: \.id) { p in
                    NavigationLink(value: p.id) {
                        SettingsRow(title: p.name, symbol: "person", mark: String(p.name.prefix(1)), status: status(p, s)) {
                            // The navigation link draws its own chevron.
                            EmptyView()
                        }
                    }
                }
                if signed.isEmpty {
                    SettingsRow(title: "No provider yet", caption: "Add one with Add Provider…", symbol: "person") { EmptyView() }
                }
            }
            Section("My Servers") {
                ForEach(s.servers) { ServerRow(server: $0) }
                Button { importer.file() } label: {
                    SettingsRow(title: "Import WireGuard or OpenVPN File…", symbol: "doc") { EmptyView() }
                }.buttonStyle(.plain)
                Button { importer.shadowsocks() } label: {
                    SettingsRow(title: "Add Shadowsocks Link…", symbol: "link") { EmptyView() }
                }.buttonStyle(.plain)
                if let e = importer.error { ErrorLine(text: e) }
            }
            Section {
                ForEach(Providers.imports, id: \.id) { g in
                    SettingsRow(title: g.name, caption: g.where, symbol: "person", mark: String(g.name.prefix(1))) {
                        if let u = URL(string: g.url) { SwiftUI.Link("Download Config", destination: u).contentButton().controlSize(.small) }
                        Button("Import File…") { importer.file(g.openVpn ? .ovpn : .wg, prefix: g.name) }.contentButton().controlSize(.small)
                    }
                }
            } header: { Text("Providers without an app here") } footer: { Text("Download a config from the provider, then import it.") }
            // The one action that forgets the setup: signing out of a single provider keeps it.
            Section {
                Button(role: .destructive) { erasing = true } label: {
                    SettingsRow(title: "Sign Out of Everything…", symbol: "rectangle.portrait.and.arrow.right", tile: IconTile.Tile.red) { EmptyView() }
                }.buttonStyle(.plain).foregroundStyle(Ink.failedText)
            } header: { Text("Sign out") } footer: { Text("Signs out of every provider and Tailscale, and forgets routes, app choices, your servers and the Home WireGuard on this Mac.") }
        }
        actions: { Button("Add Provider…") { adding = true }.contentButton() }
        .confirmationDialog("Sign out of everything?", isPresented: $erasing, titleVisibility: .visible) {
            Button("Sign Out of Everything", role: .destructive) { Task { await model.signOutAll() } }
        } message: { Text("You'll be back at sign-in with nothing set up.") }
        .task {
            while !Task.isCancelled {
                now = .now
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .sheet(isPresented: $adding) { SignInView(first: false) }
        // Saved servers made here are not routes yet: they are picked for a route in Routes.
        .importFlow(importer, target: nil)
    }

    private func status(_ p: any Provider, _ s: Setup) -> ProviderStatus {
        let used = s.routes.contains { !$0.imported && $0.loc.provider == p.id }
        let active = s.activeRoutes.filter { !$0.imported && $0.loc.provider == p.id }
        let v = model.vpn.state
        let messages = active.compactMap { v.blocked[$0.id] }
        let connected = v.phase == .on && !active.isEmpty && active.allSatisfy { route in
            v.servers[route.id] != nil && model.vpn.running?.route(route.id)?.loc == route.loc
        }
        return ProviderStatus.reduce(name: p.name, used: used,
                                     refused: messages.contains { $0 == "\(p.name) refused this Mac. Sign in again" },
                                     settingUp: ProviderStatus.settingUp(signedIn: model.signedInAt[p.id], seconds: p.keySetup, now: now),
                                     blocked: !messages.isEmpty,
                                     listFresh: ProviderStatus.listFresh(model.store.countriesFresh(p.id), failed: model.catalogFailures.contains(p.id)), connected: connected,
                                     dropping: active.first(where: { v.dropping.contains($0.id) }).map { Limits.dropping($0.name, p.name, p.id == "mullvad" || p.id == "ivpn" ? "device" : "connection") },
                                     oldList: p.listSource == nil ? nil : ProviderStatus.oldList(model.catalogDates[p.id], now: now),
                                     removed: messages.contains { $0 == "\(p.name) no longer has this Mac. Sign in again." })
    }

}

private func statusColor(_ tone: StatusTone) -> Color {
    switch tone {
    case .good: Ink.successText
    case .warn: Ink.warningText
    case .bad: Ink.failedText
    case .idle: .secondary
    }
}

/// A saved server: its kind and use, with rename and remove.
private struct ServerRow: View {
    let server: OwnServer
    private let model = AppModel.shared
    @State private var renaming = false
    @State private var removing = false
    @State private var name = ""

    /// What removing does. When a route using the server is the default, the apps that follow it move: to the first
    /// route left, which is how `removeServer` picks the new default, or to Direct when none is.
    private func removalNote(_ n: Int) -> String {
        if n == 0 { return "It isn't used by any route." }
        let s = model.setup
        let current = s.route(s.defaultRoute)
        guard current?.own == server.id else { return "The routes using it are removed too; apps set to them follow the default route." }
        let next = s.routes.first { $0.own != server.id }
        return "\(current?.name ?? "This route") is your default route. Everything that follows the default will "
            + (next.map { "use \($0.name)." } ?? "go Direct.") + " The routes using \(server.name) are removed too, and apps set to them follow the default."
    }

    var body: some View {
        let n = model.setup.routes.filter { $0.own == server.id }.count
        SettingsRow(title: server.name, caption: "\(server.kind) · " + (n == 0 ? "not in use" : "used by \(n) route\(n == 1 ? "" : "s")"), symbol: "server.rack", mark: server.code) {
            Menu {
                Button("Rename…") { name = server.name; renaming = true }
                Button("Remove…", role: .destructive) { removing = true }
            } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(.rect) }
                .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).tint(.secondary).help("Server actions")
                .accessibilityLabel("Actions for \(server.name)")
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $name, prompt: Text("e.g. Home VPS"))
            Button("Save") { model.renameServer(server.id, name) }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove \(server.name)?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { model.removeServer(server.id) }
        } message: {
            Text(removalNote(n))
        }
    }
}

private struct HomeTab: View {
    private let model = AppModel.shared
    var body: some View {
        let home = model.setup.home
        SettingsPage(title: "Home access", subtitle: "This network: \(model.setup.prefs.lan ? "On" : "Off") · Tailscale: \(home.tailscale ? "On" : "Off") · WireGuard: \(home.wg == nil ? "Not set up" : "On")", tile: IconTile.Tile.green) {
            LocalAccess()
        }
    }
}

/// LAN, home through Tailscale or a WireGuard tunnel, and the home subnets.
private struct LocalAccess: View {
    private let model = AppModel.shared
    @State private var editing = false

    var body: some View {
        let h = model.setup.home
        Section {
            SettingsRow(title: "Reach devices on this network", caption: "Printers, network drives and your router stay reachable from every app", symbol: "wifi") {
                Toggle("", isOn: model.pref(\.lan)).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("Reach devices on this network")
            }
        } header: { Text("This network") } footer: {
            Text("Blocked apps too, unless the kill switch covers your home network."
                 + (model.tunnelUp && model.setup.prefs.killLevel == .off ? " " + model.appliesLater : ""))
        }
        Section {
            SubToggle("Home through Tailscale", (h.subnets.isEmpty ? "Your Tailscale devices" : "Your Tailscale devices and \(h.subnets.joined(separator: ", "))") + " from every app except blocked apps", symbol: "house",
                      isOn: Binding(get: { h.tailscale }, set: { v in model.setHome { $0.tailscale = v } }))
            SettingsRow(title: "Home subnets through Tailscale", caption: (h.subnets.isEmpty ? "None" : h.subnets.joined(separator: ", ")) + " · a WireGuard tunnel uses its own config's ranges", symbol: "network") {
                Button("Edit…") { editing = true }.contentButton()
            }
            HomeWireGuardRow()
        } header: { Text("From anywhere") } footer: {
            Text(model.tunnelUp ? model.appliesLater + " A WireGuard tunnel can connect to your router (e.g. a FRITZ!Box)."
                 : "A WireGuard tunnel can connect to your router (e.g. a FRITZ!Box).")
        }
        .sheet(isPresented: $editing) { SubnetsEditor() }
    }
}

private struct HomeWireGuardRow: View {
    private let model = AppModel.shared
    @State private var picking = false
    @State private var error: String?
    @State private var removing: WgPeer?

    var body: some View {
        let wg = model.setup.home.wg
        VStack(alignment: .leading, spacing: 4) {
            SettingsRow(title: "Home WireGuard tunnel", caption: wg.map { "\($0.name) · \($0.endpoint)" } ?? "Not set up · import your router's .conf", symbol: "network") {
                Button(wg == nil ? "Import…" : "Replace…") { error = nil; picking = true }.contentButton()
                if let wg { Button("Remove", role: .destructive) { removing = wg }.contentButton() }
            }
            if let error { ErrorLine(text: error) }
        }
        .confirmationDialog("Remove home WireGuard tunnel?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { peer in
            Button("Remove", role: .destructive) { model.setHome { if $0.wg == peer { $0.wg = nil } } }
        } message: { _ in Text("You'll need to import the config again to use it.") }
        .fileImporter(isPresented: $picking, allowedContentTypes: Importer.types) { r in
            guard case .success(let url) = r else { return }
            switch readConfig(url) {
            case .success(let text): error = model.importHomeWireGuard(text)
            case .failure(let f): error = f.errorDescription
            }
        }
    }
}

private struct SubnetsEditor: View {
    private let model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var list: [String] { text.split(whereSeparator: { ", \t\n".contains($0) }).map(String.init) }
    /// Private IPv4 ranges in CIDR notation only; the engine sends these through Tailscale.
    private var valid: Bool { list.allSatisfy { $0.contains("/") && Compiler.isPrivate($0) } }

    var body: some View {
        FormSheet(title: "Home Subnets") {
            Section {
                TextField("Subnets", text: $text, prompt: Text("192.168.1.0/24"))
                if !valid { ErrorLine(text: "Use a private range such as 192.168.1.0/24") }
            } footer: { Text("Separate several with commas.") }
        } actions: {
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { model.setHome { $0.subnets = list.compactMap(Compiler.canonical).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }; dismiss() }.keyboardShortcut(.defaultAction).contentButton(prominent: true).disabled(!valid)
        }
        .onAppear { text = model.setup.home.subnets.joined(separator: ", ") }
    }
}

/// One signed-in provider: what uses it, its options, and sign-out last.
private struct ProviderDetail: View {
    let provider: any Provider
    private let model = AppModel.shared
    @Binding var path: [String]
    @State private var confirming = false
    @State private var plan: String?
    @State private var device: String?
    @State private var facts: String?
    @State private var deviceCount: Int?
    @State private var listDate: Int64?
    @State private var revoked = false
    @State private var limit: Limit?
    @State private var editingLimit = false
    @State private var limitText = ""
    @State private var runningLinks: [String: Link] = [:]
    @State private var runningSetup: Setup?
    @State private var advanced = false
    @State private var options: [ProviderOption] = []

    var body: some View {
        let s = model.setup
        let id = provider.id
        let routes = s.routes.filter { !$0.imported && $0.loc.provider == id }
        let live = model.vpn.state.phase == .on ? model.vpn.state.servers : [:]
        VStack(alignment: .leading, spacing: 0) {
        Button { if !path.isEmpty { path.removeLast() } } label: {
            Label("Providers", systemImage: "chevron.left").font(.system(size: 13)).foregroundStyle(Ink.accentText)
        }
        .buttonStyle(.borderless).keyboardShortcut("[", modifiers: .command).accessibilityLabel("Back to Providers")
        .padding(.horizontal, Layout.gutter).padding(.top, Layout.header)
        SettingsPage(title: provider.name, subtitle: revoked ? "Device removed. Sign in again" : "Signed in · \(routes.count) route\(routes.count == 1 ? "" : "s")", tile: IconTile.Tile.blue) {
                if id == "ivpn", let blob = model.accounts[id], let account = try? Ivpn.account(blob), let created = account.createdAt {
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        if ProviderStatus.keySettingUp(created: created, now: context.date, seconds: provider.keySetup) {
                            Text("IVPN is setting up your key. Its routes can take a minute to work.").foregroundStyle(.secondary)
                        }
                    }
                }
                if revoked || plan != nil {
                    Section("Account") {
                        if revoked { SettingsRow(title: "Status", caption: "Device removed. Sign in again", symbol: "person") { EmptyView() } }
                        if let plan { SettingsRow(title: "Plan", caption: plan, symbol: "creditcard") { EmptyView() } }
                    }
                }
                if let limit {
                    let links = runningLinks.filter { route, _ in s.route(route)?.loc == runningSetup?.route(route)?.loc }
                    let n = limit.perTunnel ? Limits.tunnels(s, id, links: links) : 1
                    Section("Limit") {
                        SettingsRow(title: limit.unit == "device" ? "Devices" : "Connections", caption: Limits.line(provider.name, Limits.effective(limit, s.opt(id, "limit")), limit.unit, n, all: deviceCount), symbol: "number") {
                            Button("Edit Limit…") { limitText = s.opt(id, "limit") ?? ""; editingLimit = true }.contentButton()
                        }
                    }
                }
                if provider.listSource != nil {
                    Section("Server list") {
                        SettingsRow(title: "Server list", caption: "From gluetun's public list" + (model.catalogDates[id].map { ", published \(ProviderStatus.publishedOn($0))" } ?? ""), symbol: "server.rack") { EmptyView() }
                    }
                }
                if let device {
                    Section("This Mac") {
                        SettingsRow(title: "This Mac", caption: device, symbol: "desktopcomputer") {
                            if let url = provider.deviceURL.flatMap(URL.init(string:)) { SwiftUI.Link("Open the \(provider.name) Client Area", destination: url).contentButton() }
                        }
                    }
                }
                Section("\(provider.name) settings") {
                    if let protection = provider.protection {
                        SubToggle(protection.label, providerProtectionAvailable(s.prefs.effectiveFilter) ? (["mullvad", "pia"].contains(id) ? "Ads, trackers and malware" : "Blocks ads and trackers") : "Off while unbraid’s filter is on for VPN routes",
                                  isOn: Binding(get: { s.opt(id, "protect") == "on" }, set: { model.setOpt(id, "protect", $0 ? "on" : "off") }))
                            .disabled(!providerProtectionAvailable(s.prefs.effectiveFilter))
                    } else {
                        SettingsRow(title: "\(provider.name) blocking", caption: provider.blockingNote, symbol: "shield") {
                            if let url = provider.blockingUrl.flatMap(URL.init(string:)) { SwiftUI.Link("Open the \(provider.name) Client Area", destination: url).contentButton() }
                        }
                    }
                    ForEach((provider.commonOptions + options).filter { !$0.advanced && $0.key != "protect" }, id: \.key) { option in
                        optionRow(option, s)
                    }
                }
                if let (note, address) = provider.configHelp, let url = URL(string: address) {
                    Section("In your \(provider.name) account") {
                        SettingsRow(title: "In your \(provider.name) account", caption: note, symbol: "person") { SwiftUI.Link("Open the Client Area", destination: url).contentButton() }
                    }
                }
                if !routes.isEmpty {
                    Section("Used by") {
                        ForEach(routes) { r in
                            let apps = s.apps.values.filter { $0 == r.id }.count
                            SettingsRow(title: r.name, caption: ([s.defaultRoute == r.id ? "Default route" : "\(apps) app\(apps == 1 ? "" : "s")"] + [live[r.id].map { serverId(r, $0) }].compactMap { $0 }).joined(separator: " · "), symbol: "point.topleft.down.curvedto.point.bottomright.up", route: r) { EmptyView() }
                        }
                    }
                }
                Section {
                    DisclosureGroup(isExpanded: $advanced) {
                        if let (message, url) = provider.configHelp, let link = URL(string: url) { SwiftUI.Link(message, destination: link).contentButton() }
                        ForEach((provider.commonOptions + options).filter { $0.advanced && $0.key != "limit" }, id: \.key) { option in
                            let filterOff = id == "mullvad" && ["adult", "gambling", "social"].contains(option.key) && !providerProtectionAvailable(s.prefs.effectiveFilter)
                            optionRow(option, s).disabled(filterOff)
                                .help(filterOff ? "Off while unbraid's filter is on for VPN routes" : option.help)
                        }
                        if let facts { SettingsRow(title: "Set in your config", caption: facts.isEmpty ? "Not known" : facts, symbol: "doc.text") { EmptyView() } }
                        if let help = provider.configHelp, let url = URL(string: help.1) { SwiftUI.Link(help.0, destination: url).contentButton() }
                    } label: {
                        let changed = (provider.commonOptions + options).filter { $0.advanced && $0.key != "limit" && (s.opt(id, $0.key) ?? $0.defaultValue) != $0.defaultValue }
                        SettingsRow(title: "Advanced settings", caption: changed.isEmpty ? nil : changed.map { "\($0.label): \(optionValue($0, s))" }.joined(separator: " · "), symbol: "gearshape") { EmptyView() }
                    }
                    .accessibilityLabel("Advanced settings")
                    .accessibilityValue(advanced ? "Expanded" : advancedSummary(s))
                } header: { Text("Advanced settings") }
                Section {
                    Button(role: .destructive) { confirming = true } label: {
                        SettingsRow(title: "Sign Out of \(provider.name)…", symbol: "rectangle.portrait.and.arrow.right", tile: IconTile.Tile.red) { EmptyView() }
                    }.buttonStyle(.plain).foregroundStyle(Ink.failedText)
                } header: { Text("Sign out") } footer: { Text(signOutNote(s, routes.count)) }
        }
        }
        // The back button sits on the page's ground too, not on the window's default background.
        .background(Ink.ground)
        .navigationBarBackButtonHidden(true)
        .onExitCommand { if !path.isEmpty { path.removeLast() } }
        .task(id: model.vpn.running) {
            let running = model.vpn.running
            let record = model.vpn.state.phase == .on ? await Running.load() : nil
            if running == model.vpn.running, record?.setup == running, record?.accounts == Running.fingerprints(model.accounts), model.vpn.state.phase == .on {
                runningSetup = record?.setup; runningLinks = (record?.links ?? [:]).filter { id, link in model.vpn.state.servers[id] == link.server }
            } else { runningSetup = nil; runningLinks = [:] }
        }
        .task(id: model.accounts[id]) {
            guard let account = model.accounts[id] else { return }
            plan = try? await provider.plan(account)
            device = try? await provider.device(account)
            limit = try? await provider.limit(account)
            options = (try? await provider.options(account)) ?? provider.linkOptions
            facts = try? await provider.facts(account)
            deviceCount = try? await provider.deviceCount(account)
            listDate = try? await provider.listDate(account)
            revoked = (try? await provider.revoked(account)) ?? false
        }
        .sheet(isPresented: $editingLimit) {
            FormSheet(title: "Connection Limit", width: 400) {
                Section {
                    TextField("Your plan's limit", text: $limitText, prompt: Text("1–999"))
                }
            } actions: {
                Button("Cancel", role: .cancel) { editingLimit = false }.keyboardShortcut(.cancelAction)
                Button("Save") { model.setOpt(id, "limit", limitText); editingLimit = false }
                    .keyboardShortcut(.defaultAction).contentButton(prominent: true)
                    .disabled(!limitText.isEmpty && !(Int(limitText).map { (1...999).contains($0) } ?? false))
            }
        }
        .confirmationDialog("Sign out of \(provider.name)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { model.signOut(id); path.removeAll() }
        } message: { Text("Its routes and app choices stay on this Mac for when you sign in to \(provider.name) again.") }
        // Signed out elsewhere (sign out of everything): nothing left to show.
        .onChange(of: model.accounts[id] == nil, initial: true) { _, gone in if gone { path.removeAll() } }
    }

    @ViewBuilder private func optionRow(_ option: ProviderOption, _ s: Setup) -> some View {
        switch option.kind {
        case .choice(let choices):
            SettingsRow(title: option.label, symbol: "slider.horizontal.3") {
                Picker(option.label, selection: Binding(get: { s.opt(provider.id, option.key) ?? option.defaultValue }, set: { model.setOpt(provider.id, option.key, $0, offered: option) })) {
                    ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                }.labelsHidden().accessibilityLabel(option.label).help(option.help)
            }
        case .number:
            SettingsRow(title: option.label, symbol: "slider.horizontal.3") { EmptyView() } below: {
                TextField(option.label, text: Binding(get: { s.opt(provider.id, option.key) ?? "" }, set: { model.setOpt(provider.id, option.key, $0, offered: option) })).labelsHidden().accessibilityLabel(option.label)
            }
        case .toggle:
            SettingsRow(title: option.label, symbol: "slider.horizontal.3") {
                Toggle("", isOn: Binding(get: { s.opt(provider.id, option.key) == "on" }, set: { model.setOpt(provider.id, option.key, $0 ? "on" : "off", offered: option) })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(option.label)
            }
        }
    }

    private func advancedSummary(_ setup: Setup) -> String {
        let values = (provider.commonOptions + options).filter {
            $0.advanced && $0.key != "limit" && (setup.opt(provider.id, $0.key) ?? $0.defaultValue) != $0.defaultValue
        }.map { "\($0.label): \(optionValue($0, setup))" }.joined(separator: ", ")
        return values.isEmpty ? "Collapsed" : "Collapsed, \(values)"
    }

    private func optionValue(_ option: ProviderOption, _ setup: Setup) -> String {
        let value = setup.opt(provider.id, option.key) ?? option.defaultValue
        if case .choice(let choices) = option.kind { return choices.first { $0.value == value }?.label ?? value }
        return value
    }

    private func signOutNote(_ s: Setup, _ used: Int) -> String {
        if model.accounts.count == 1 && s.servers.isEmpty && !s.routes.contains(where: \.imported) && !s.tailscale && s.home.wg == nil {
            return "It's your only connection: the VPN stops and you'll be back at sign-in. Its routes and app choices are kept for when you sign in to it again; importing a server or choosing Tailscale only replaces them"
        }
        return used == 0 ? "No route uses it" : "Connecting fails until its \(used) route\(used == 1 ? " gets" : "s get") another connection, \(used == 1 ? "its" : "their") apps move, or you sign in again"
    }
}

// MARK: - Tailscale

private struct TailscaleTab: View {
    private let model = AppModel.shared
    @State private var server = false
    @State private var leaving = false
    @State private var removing: String?

    var body: some View {
        let s = model.setup
        let v = model.vpn.state
        let nodes = v.tsExitNodes.sorted { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }
        SettingsPage(title: "Tailscale", subtitle: "\(nodes.count) exit node\(nodes.count == 1 ? "" : "s") · \(model.store.tsSuffix ?? "no tailnet domain")", tile: IconTile.Tile.indigo) {
            if let n = model.notice { Section { NoticeRow(text: n) } }
            Section {
                SubToggle("Reach your tailnet", s.home.tailscale ? status(v, enabled: true)
                          : s.tailscale ? "Off · Tailscale still runs for your exit-node route" : "From every app, as with the Tailscale app", symbol: "circle.grid.3x3",
                          isOn: Binding(get: { s.home.tailscale }, set: { on in model.setHome { $0.tailscale = on } }))
                if let url = v.tsLoginUrl, s.tailscale {
                    SettingsRow(title: "Sign-in needed", caption: "Opens your browser", symbol: "person") { TailscaleSignIn(url: url).contentButton() }
                }
                if s.tailscale, let offered = model.store.tsSuffixOffered {
                    SettingsRow(title: "Tailnet domain “\(offered)”", caption: "Your control server names your tailnet’s devices under this domain.", symbol: "network") {
                        Button("Use") { model.store.acceptTsSuffix(offered) }.contentButton()
                    }
                }
                if s.home.tailscale, let domain = model.store.tsSuffix {
                    SettingsRow(title: "Tailnet domain “\(domain)”", caption: Compiler.officialTs(s.home) && Compiler.tsSuffixIsTailscales(domain) ? "Tailscale’s own: lookups of names under it go to your tailnet." : "You accepted it: lookups of names under it go to your tailnet.", symbol: "network") {
                        if !Compiler.officialTs(s.home) || !Compiler.tsSuffixIsTailscales(domain) { Button("Remove…") { removing = domain }.contentButton() }
                    }
                }
            } header: { Text("Tailnet") } footer: {
                if s.tailscale, model.store.tsSuffixOffered != nil {
                    Text("Once used, every app’s lookups of names under it go to your tailnet while you reach it. Use it only if the domain is your tailnet’s.")
                }
            }
            if s.tailscale && !nodes.isEmpty {
                Section {
                    ForEach(nodes, id: \.ip) { n in
                        let used = s.routes.filter { $0.tsExit == n.ip }.count
                        SettingsRow(title: n.name, caption: n.online ? "Online" : "Offline", symbol: "server.rack", captionDot: n.online ? Ink.successText : Ink.off) {
                            Text(used == 0 ? "Not used" : "Used by \(used) route\(used == 1 ? "" : "s")").foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Exit nodes") } footer: {
                    Text("Pick an exit node for a route in Routes. Reaching your home network through Tailscale is under Home access.")
                }
            }
            if s.tailscale {
                Section("Control server") {
                    SettingsRow(title: "Control server", caption: s.home.tsControlUrl ?? "Tailscale (default)", symbol: "clock") { EmptyView() }
                }
            }
            if s.tailscaleConfigured || s.home.tsEnrolled != nil {
                Section {
                    Button(role: .destructive) { leaving = true } label: {
                        SettingsRow(title: "Sign Out of Tailscale…", symbol: "rectangle.portrait.and.arrow.right", tile: IconTile.Tile.red) { EmptyView() }
                    }.buttonStyle(.plain).foregroundStyle(Ink.failedText)
                } header: { Text("Sign out") } footer: { Text("Its exit routes are removed; their apps follow the default route.") }
            }
        }
        actions: { if s.tailscale { Button("Change Control Server…") { server = true }.contentButton() } }
        .confirmationDialog("Stop using “\(removing ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { domain in
            Button("Remove", role: .destructive) { model.store.removeTsSuffix(domain) }
        } message: { _ in Text("Names of your tailnet’s devices under this domain may stop working until you use it again.") }
        .sheet(isPresented: $server) { ControlServerSheet() }
        .confirmationDialog("Sign out of Tailscale?", isPresented: $leaving, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await model.signOutTailscale() } }
        } message: { Text("Tailscale exit routes are removed. Their apps follow the default route.") }
    }

    private func status(_ v: VpnState, enabled: Bool) -> String {
        guard v.phase == .on else { return "Connects with unbraid" }
        switch TailscaleStatus(v.tsState) {
        case .signInNeeded: return "Sign-in needed"
        case .awaitingApproval: return "Waiting for approval in the Tailscale admin console"
        case .starting: return "Starting"
        case .connected: return "Connected"
        case .stopped: return "Stopped"
        case .unknown, nil: return "Reach your tailnet from every app"
        }
    }
}

/// A self-hosted Headscale: https only, with an optional auth key so no browser sign-in is needed.
private struct ControlServerSheet: View {
    private let model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var key = ""

    private var trimmed: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Saved as the engine gets it ("HTTPS://Example.com" becomes "https://example.com"): the compiler checks the same way.
    private var valid: Bool { trimmed.isEmpty || TsLogin.controlUrl(trimmed) != nil }

    var body: some View {
        FormSheet(title: "Control Server", width: 460) {
            Section {
                TextField("Server URL", text: $url, prompt: Text("https://headscale.example.com"))
                SecretField("Auth key (optional)", text: $key, prompt: Text("Signs in without a browser"))
                if !valid { ErrorLine(text: "Use a full https:// address") }
            } footer: {
                Text("For a self-hosted Headscale. Changing it gives this Mac a new Tailscale identity; with the VPN on, it also logs out of the current tailnet.")
            }
        } actions: {
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") {
                let (u, k) = (TsLogin.controlUrl(trimmed), key.trimmingCharacters(in: .whitespacesAndNewlines))
                Task { await model.setTailscaleServer(u, authKey: k.isEmpty ? nil : k) }
                dismiss()
            }
            .keyboardShortcut(.defaultAction).contentButton(prominent: true).disabled(!valid)
        }
        .background(CaptureExclusion())
        .onAppear { url = model.setup.home.tsControlUrl ?? "" }
        // The key is a secret: never left in state once the sheet is gone.
        .onDisappear { key = "" }
    }
}

// MARK: - Protection

/// What each kill switch level does, in plain words, as the code does it. Home-network reach depends on "Reach devices
/// on this network". Only the first level lets traffic skip the VPN while it is connected.
private func killNote(_ level: KillLevel, lan: Bool) -> String {
    let direct = " Apps set to Direct still use your normal connection, and nothing is covered while unbraid is disconnected."
    switch level {
    case .off:
        return "Apps that pick Wi-Fi or Ethernet themselves can skip the VPN, even while it is connected"
            + (lan ? ", and so can traffic to your home network" : "") + ". While a VPN reconnects, any app may use your normal connection."
    case .internet:
        return "Apps only go out the way you chose for them: while a VPN reconnects, its apps wait instead of using your normal connection." + direct
            + (lan ? " Devices on your home network stay reachable from every app, blocked apps included; AirPlay and other discovery may not work." : "")
    case .home:
        return "While a VPN reconnects, its apps wait instead of using your normal connection, and blocked apps can't reach your home network either"
            + (lan ? "; other apps still can. AirPlay and other discovery on your home network may not work." : ".") + direct
    }
}

private struct ProtectionTab: View {
    private let model = AppModel.shared
    @State private var dns = ""

    var body: some View {
        let s = model.setup
        let filter = s.prefs.effectiveFilter
        let saved = filter.value
        let level = s.prefs.killLevel == .off ? "Off" : s.prefs.killLevel == .internet ? "Internet" : "Internet and home network"
        let chosenName = filter.id == "own" ? "Your own server" : FilterServer.presets.first(where: { $0.id == filter.id })?.name ?? "None"
        // A filter that is chosen but not set up, or applied nowhere, filters nothing: the header says so.
        let working = filter.server != nil && (filter.routes || filter.direct || filter.directApps || filter.apps.values.contains(true))
        let filterName = filter.id == nil || working ? chosenName : chosenName + " (not used yet)"
        SettingsPage(title: "Protection", subtitle: "Kill switch: \(level) · Filter: \(filterName)", tile: IconTile.Tile.red) {
            if let n = model.notice { Section { NoticeRow(text: n) } }
            Section {
                let blocked = s.apps.values.contains(BLOCK)
                // While paused, a tunnel kept for blocked apps takes a new level at once; with none blocked it waits for Resume.
                // With a home network reached through a tunnel, the pause keeps blocked apps off it, so Internet waits for Resume.
                let remoteHome = s.home.wg != nil || (s.home.tailscale && !s.home.subnets.isEmpty)
                // Only turning it on or off changes the VPN's profile (and restarts it); the two levels are one profile.
                let restart = model.vpn.state.phase == .paused && blocked
                    ? (remoteHome ? "Internet and home network applies now. Internet applies when you resume: until then blocked apps stay off your home network." : "Applies now.")
                    : model.vpn.state.phase == .on ? "Turning this on or off restarts the VPN: for a moment apps may use your normal connection. Switching between Internet and Internet and home network doesn't."
                    : model.tunnelUp ? model.appliesLater : ""
                SettingsRow(title: "Block traffic outside the VPN", caption: killNote(s.prefs.killLevel, lan: s.prefs.lan) + (blocked ? " It stays on while any app is blocked." : "") + (restart.isEmpty ? "" : " " + restart), symbol: "shield", captionLines: nil) {
                    // A menu, like the filter's: three segments with these labels are wider than the card and pushed
                    // the whole page sideways.
                    Picker("Block traffic outside the VPN", selection: Binding(get: { s.prefs.killLevel }, set: { v in model.setPrefs { $0.killLevel = v } })) {
                        Text("Off").tag(KillLevel.off).selectionDisabled(blocked)
                        Text("Internet").tag(KillLevel.internet)
                        Text("Internet and home network").tag(KillLevel.home)
                    }.labelsHidden().accessibilityLabel("Block traffic outside the VPN")
                }
                SubToggle("Connect on demand", "macOS brings the VPN back after sleep, network changes and restarts.", symbol: "arrow.clockwise",
                          isOn: Binding(get: { model.setup.prefs.alwaysOn }, set: { v in
                              model.setPrefs { $0.alwaysOn = v }; model.vpn.onDemandChanged(v)
                          }))
                if s.prefs.alwaysOn, model.vpn.tunnel.onDemandUnavailable {
                    ErrorLine(text: "Unavailable: the VPN couldn't save its configuration. unbraid tries again with the next change.")
                }
            } header: { Text("Kill switch") }

            Section {
                SettingsRow(title: "unbraid's filter", symbol: "line.3.horizontal.decrease.circle") {
                Picker("unbraid's filter", selection: Binding(get: { filter.id ?? "" }, set: { id in
                    model.setPrefs { p in
                        let before = p.filter.id
                        p.filter.id = id.isEmpty ? nil : id
                        // A value typed for another server (a NextDNS profile) means nothing to this one.
                        if p.filter.id != before { p.filter.value = "" }
                        // Choosing a filter applies it to VPN routes, so it filters something at once; the switches
                        // below fine-tune where.
                        if before == nil, p.filter.id != nil, !(p.filter.routes || p.filter.direct || p.filter.directApps || p.filter.apps.values.contains(true)) { p.filter.routes = true }
                        p.customDns = []
                    }
                })) {
                    Text("None").tag("")
                    ForEach(FilterServer.presets, id: \.id) { Text("\($0.name) · \($0.blocks)").tag($0.id) }
                    Text("Your own server").tag("own")
                }.labelsHidden()
                }
                if filter.id == "nextdns" || filter.id == "own" {
                    SettingsRow(title: filter.id == "nextdns" ? "NextDNS profile ID" : "Your own server", symbol: "server.rack") { EmptyView() } below: {
                        HStack {
                        TextField(filter.id == "nextdns" ? "NextDNS profile ID" : "Your own server", text: $dns).labelsHidden().onSubmit(save)
                        Button("Save", action: save).contentButton().disabled(dns == saved || !validDns)
                        }
                    }
                    if !dns.isEmpty && !validDns { ErrorLine(text: filter.id == "nextdns" ? "Enter a profile ID of 1 to 32 letters or numbers" : "Enter an https:// or tls:// address, or one IPv4 address") }
                    if filter.id == "own" && FilterServer.ipv4(dns.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        Text("Not encrypted").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Filter") } footer: {
                Text("A filter blocks ads, trackers or adult sites by refusing to look up their addresses. With Direct as the default route, a few of macOS's own lookups may skip the filter.")
            }
            if filter.id != nil {
                Section {
                    SettingsRow(title: "Apps on VPN routes", symbol: "network") {
                        Toggle("", isOn: Binding(get: { filter.routes }, set: { v in model.setPrefs { $0.filter.routes = v; $0.customDns = [] } })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("Apps on VPN routes")
                    }
                    SettingsRow(title: "Apps on Direct", symbol: "arrow.right") {
                        Toggle("", isOn: Binding(get: { filter.direct }, set: { v in model.setPrefs { $0.filter.direct = v; $0.customDns = [] } })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("Apps on Direct")
                    }
                    SettingsRow(title: "Apps set to Direct", symbol: "app") {
                        Picker("Apps set to Direct", selection: Binding(get: { filter.directApps }, set: { v in model.setPrefs { $0.filter.directApps = v; $0.customDns = [] } })) {
                            Text("Not filtered").tag(false)
                            Text("Use this filter").tag(true)
                        }.labelsHidden()
                    }
                } header: { Text("Where it applies") } footer: {
                    Text("Apps on VPN routes ask the filter through their VPN. Apps on Direct ask it over your normal connection.")
                }
            }
        }
        .onAppear { dns = saved }
        .onChange(of: filter.id) { dns = model.setup.prefs.effectiveFilter.value }
    }

    private var validDns: Bool {
        let f = model.setup.prefs.effectiveFilter
        return Filter(id: f.id, value: dns).server != nil
    }

    private func save() {
        guard validDns else { return }
        model.setPrefs { $0.filter.value = dns.trimmingCharacters(in: .whitespacesAndNewlines); $0.customDns = [] }
    }
}

/// Open at login, read live: the user can also change it in System Settings.
private struct LoginItemToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SubToggle("Open at login", status == .requiresApproval ? "Waiting for approval in System Settings › Login Items"
                      : "unbraid lives in the menu bar and protects from login", symbol: "power",
                      isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: { set($0) }))
            if let error { ErrorLine(text: error) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in status = SMAppService.mainApp.status }
    }

    private func set(_ on: Bool) {
        LoginItem.shared.settingsChanged()
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch let e { error = "Couldn't change this: \(e.localizedDescription)" }
        status = SMAppService.mainApp.status
    }
}

// MARK: - Statistics

private struct StatisticsTab: View {
    private let model = AppModel.shared
    @State private var consent = false
    @State private var deleting = false
    @State private var size: Int64 = 0

    var body: some View {
        let on = model.setup.prefs.stats
        let amount = Units.bytes(size)
        let facts = on ? (size > 0 ? "Recording · \(amount) on this Mac" : "Recording") : (size > 0 ? "Off · \(amount) saved" : "Off")
        SettingsPage(title: "Statistics", subtitle: facts, tile: IconTile.Tile.purple) {
            if let n = model.notice { Section { NoticeRow(text: n) } }
            Section {
                SubToggle("Record usage statistics", "Only on this Mac, never uploaded. Turning it off keeps what's saved.", symbol: "chart.bar",
                          isOn: Binding(get: { on }, set: { if $0 { consent = true } else { model.setStats(false) } }))
                SettingsRow(title: "Saved history", caption: "Hourly for a week, daily for about a year", symbol: "clock") {
                    Text(amount).monospacedDigit().foregroundStyle(.secondary)
                }
            } header: { Text("Recording") } footer: { Text("Apps and programs (by their location on this Mac, home folder as ~; temporary and cache folders grouped as \"Other programs\"), routes, bytes, times, speeds and speed-test exit IPs. No browsing destinations, ever.") }
            Section {
                SubToggle("Test all routes at once", "Adds \u{201C}All\u{201D} to the Speed Test page: test 2 to 10 routes together.", symbol: "speedometer",
                          isOn: Binding(get: { model.setup.prefs.testAllRoutes }, set: { value in model.setPrefs { $0.testAllRoutes = value } }))
            } header: { Text("Speed test") }
            if size > 0 {
                Section {
                    Button(role: .destructive) { deleting = true } label: {
                        SettingsRow(title: "Delete Saved History…", symbol: "trash", tile: IconTile.Tile.red) { EmptyView() }
                    }.buttonStyle(.plain).foregroundStyle(Ink.failedText)
                } header: { Text("Delete") } footer: { Text("All recorded data, sessions and speed tests are erased from this Mac.") }
            }
        }
        .task { size = Stats.shared.size() }
        // The writer flushes a moment after a change: read the size once it has.
        .onChange(of: on) { Task { try? await Task.sleep(for: .milliseconds(800)); size = Stats.shared.size() } }
        .sheet(isPresented: $consent) {
            ConsentSheet(title: Text("Keep statistics?").font(.title2.bold()), rows: [
                ("desktopcomputer", "Statistics stay on this Mac. They are never uploaded."),
                ("clock", "Kept as hourly sums for a week and daily sums for about a year, with your last 100 speed tests."),
                ("nosign", "Only apps and programs (by their location on this Mac, with your home folder shown as ~), routes, bytes, times, speeds and speed-test exit IPs. Programs that run from temporary or cache folders are grouped as \"Other programs\". No browsing destinations, ever."),
                ("trash", "Turn off or delete everything in Settings at any time."),
            ], action: "Turn On", accept: { model.setStats(true) }) {}
        }
        .alert("Delete statistics?", isPresented: $deleting) {
            Button("Delete Statistics", role: .destructive) { Task { await Stats.shared.delete(); size = Stats.shared.size() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All recorded data, sessions and speed tests are erased from this Mac. This can't be undone." + (on ? " Recording stays on." : ""))
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    private let model = AppModel.shared
    @State private var licences = false

    private let credits = [
        ("sing-box 1.14.4", "GPL-3.0-or-later · nekohasekai (SagerNet). The VPN engine, with unbraid's patches, including its OpenVPN module"),
        ("Tailscale", "BSD-3-Clause · Tailscale Inc. and contributors"),
        ("wireguard-go", "MIT · WireGuard LLC"),
        ("gVisor", "Apache-2.0 · The gVisor Authors"),
        ("Go and its modules", "GPL-3.0, LGPL-3.0, MPL-2.0, Apache-2.0, BSD, MIT, ISC, Unlicense and CC0, each listed in the full texts"),
        ("Big Shoulders Display", "SIL Open Font License 1.1 · its project authors"),
        ("Material Symbols", "Apache-2.0 · Google. The route mark, adapted from alt_route"),
        ("gluetun", "MIT · Quentin McGaw. Server lists, and the ExpressVPN profile"),
        ("PIA manual-connections", "MIT · Private Internet Access, Inc."),
        ("Measurement Lab (M-Lab)", "Speed-test servers, used under M-Lab's acceptable use policy"),
    ]

    var body: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        SettingsPage(title: "About", subtitle: "Version \(version) (\(build))") {
            if let n = model.notice { Section { NoticeRow(text: n) } }
            Section {
                VStack(spacing: 6) {
                    Wordmark(size: 48)
                    Text("© 2026 the unbraid authors · GNU GPL v3.0 or later").font(.callout).foregroundStyle(.secondary)
                    Text("Free to use, share and change. No warranty.").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("All Licence Texts") { licences = true }.contentButton()
                        CopyDiagnosticsButton().contentButton()
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            UpdatesSection()
            Section("Links") {
                LinkRow("Website", "unbraid.app", Site.home, symbol: "globe")
                LinkRow("Support unbraid", "Made by one person. A donation keeps it going.", Site.donate, symbol: "heart")
                LinkRow("Contact", Site.email, Site.contact, symbol: "envelope")
                if let source = Site.source {
                    LinkRow("Source code", source.replacingOccurrences(of: "https://", with: ""), source, symbol: "chevron.left.forwardslash.chevron.right")
                } else {
                    LinkRow("Source code", "The complete source of this version, with the patched engine and the build scripts, is free on the download page: unbraid-\(version)-\(build)-source.tar.gz", Site.download, symbol: "chevron.left.forwardslash.chevron.right")
                }
                LinkRow("Privacy policy", "unbraid.app/privacy", Site.privacy, symbol: "lock")
                LinkRow("Terms of use", "unbraid.app/terms", Site.terms, symbol: "doc.text")
            }
            Section("Privacy") {
                Text("No analytics, no ads, no accounts with us and no servers of our own. Provider logins, keys and your setup are stored on this Mac, sealed with keys kept in the Keychain.")
                Text("Windows where you paste keys or sign in ask macOS to keep them out of screen sharing and captures. macOS may not always honour this.")
                Text(Disclosure.text).font(.callout).foregroundStyle(.secondary)
            }
            Section("Built with") {
                ForEach(credits, id: \.0) { name, sub in
                    SettingsRow(title: name, caption: sub, symbol: "shippingbox") { EmptyView() }
                }
            }
        }
        .sheet(isPresented: $licences) { LicencesSheet() }
    }
}

/// unbraid.app pages, at their canonical trailing-slash addresses (the bare ones answer with a 301).
enum Site {
    static let home = "https://unbraid.app/"
    static let guides = "https://unbraid.app/guides/"
    static let donate = "https://unbraid.app/donate/"
    static let contact = "https://unbraid.app/contact/"
    static let privacy = "https://unbraid.app/privacy/"
    static let terms = "https://unbraid.app/terms/"
    /// Where each release's DMG and its complete source archive are published.
    static let download = "https://unbraid.app/download/"
    static let email = "info@unbraid.app"
    /// The Mac app's public repository, shown in About. Nil would point that row to the source archive published
    /// beside each release's download instead.
    static let source: String? = "https://github.com/Quiet-Crafts/unbraid-mac"
}

/// The update check's switch, what it last found, Check Now and, when a newer release is out, Download.
private struct UpdatesSection: View {
    private let updates = Updates.shared

    var body: some View {
        Section {
            SubToggle("Check for updates", UpdateText.setting, symbol: "arrow.down.circle",
                      isOn: Binding(get: { updates.state.enabled }, set: { updates.setEnabled($0) }))
            SettingsRow(title: title, caption: caption, symbol: "shippingbox") {
                HStack {
                    if updates.newer != nil { Button("Download…") { UpdateText.openReleasePage() }.contentButton(prominent: true) }
                    Button("Check Now") { Task { await updates.checkNow() } }.contentButton().disabled(updates.checking)
                }
            }
        } header: { Text("Updates") } footer: {
            Text("unbraid never updates itself: download the new version and drag it over this one in Applications. Your setup stays.")
        }
    }

    private var title: String {
        if let newer = updates.newer { return "Version \(newer) is out" }
        if updates.lastManual == .current || updates.state.latest != nil { return "You have the latest version" }
        return "Version \(updates.installed?.description ?? "")"
    }

    private var caption: String {
        if updates.checking { return "Checking…" }
        if updates.lastManual == .failed { return "Couldn't reach unbraid.app. Try again later." }
        guard let last = updates.state.lastAttempt else { return "Not checked yet" }
        let when = last.formatted(.relative(presentation: .named))
        return updates.state.failed ? "Last tried \(when)" : "Last checked \(when)"
    }
}

private struct LinkRow: View {
    let title: String, sub: String, url: String, symbol: String
    init(_ title: String, _ sub: String, _ url: String, symbol: String) { self.title = title; self.sub = sub; self.url = url; self.symbol = symbol }
    var body: some View {
        if let u = URL(string: url) {
            SwiftUI.Link(destination: u) {
                SettingsRow(title: title, caption: sub, symbol: symbol, captionLines: nil) {
                    Image(systemName: "arrow.up.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                }.contentShape(.rect)
            }.buttonStyle(.plain)
        }
    }
}

nonisolated private struct Notice: Identifiable, Sendable {
    let id: Int
    let title: String
    let body: String
}

/// The bundled licence texts: one block per notice, headed by its first line.
private struct LicencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notices: [Notice]?

    var body: some View {
        SheetFrame(title: "Licences", width: SheetWidth.browser) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("NordVPN, Mullvad, Proton VPN, Surfshark, ExpressVPN, Private Internet Access, IVPN, Windscribe, AirVPN, Tailscale, WireGuard, sing-box and M-Lab are names or trademarks of their owners, used only to say what unbraid works with. unbraid is independent: none of them made, endorse or support it. Your provider accounts stay under their own terms. \"WireGuard\" and the \"WireGuard\" logo are registered trademarks of Jason A. Donenfeld.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let notices {
                        if notices.isEmpty { Text("The licence texts are not bundled with this build.").foregroundStyle(.secondary) }
                        ForEach(notices) { n in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(n.title).font(.headline)
                                Text(n.body).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else { ProgressView().frame(maxWidth: .infinity) }
                }
                .padding(16).textSelection(.enabled)
            }
        } actions: {
            Button("Done") { dismiss() }.contentButton(prominent: true).keyboardShortcut(.defaultAction)
        }
        .onExitCommand { dismiss() }
        .frame(height: 520)
        // About 200 KB of text: read and reflowed off the main thread.
        .task { notices = await Task.detached { Self.load() }.value }
    }

    nonisolated private static func load() -> [Notice] {
        guard let url = Bundle.main.url(forResource: "notices", withExtension: "txt"), let all = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        // Licence files are hard-wrapped near 80 columns: join each paragraph's lines, keeping list items apart.
        let wrapped = #"[ \t]*(?<!\n)\n(?!\n|[ \t]*([*•-]|\d+[.)]|\([a-z0-9]+\))\s)[ \t]*"#
        return all.components(separatedBy: "\n=== ").enumerated().map { i, n in
            let text = n.hasPrefix("=== ") ? String(n.dropFirst(4)) : n
            let title = text.prefix { $0 != "\n" }
            let body = text.dropFirst(title.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return Notice(id: i, title: String(title), body: body.replacingOccurrences(of: wrapped, with: " ", options: .regularExpression))
        }
    }
}

/// A provider's status in Connections: its coloured dot and words, read as one by VoiceOver.
private struct ProviderStatusLine: View {
    let status: ProviderStatus
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor(status.tone)).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(status.text).font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine).accessibilityLabel(status.text)
    }
}
