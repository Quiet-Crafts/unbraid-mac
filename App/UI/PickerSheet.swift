import SwiftUI

/// What the sheet would apply: a place at a provider, one of the user's saved servers, or a Tailscale exit node.
private enum Choice: Hashable {
    case loc(Location)
    case own(String)
    case ts(ip: String, name: String)
}

private let nordProtocols: [(key: String?, label: String, note: String)] = [
    (nil, "NordLynx", "Fastest. Built on WireGuard"),
    ("openvpn_udp", "OpenVPN UDP", "Wider compatibility"),
    ("openvpn_tcp", "OpenVPN TCP", "For networks that block VPNs"),
]

/// Double VPN and Onion only run over OpenVPN: UDP unless TCP was chosen. Other providers have no choice.
private func effectiveProtocol(_ provider: String?, group: String?, choice: String?) -> String? {
    guard provider == "nord" else { return nil }
    return group.map(Nord.openVpnOnly.contains) == true ? (choice?.hasPrefix("openvpn") == true ? choice : "openvpn_udp") : choice
}

/// A city saved before regions were stored: Mullvad, IVPN and PIA can't tell which city it was, so it is picked again.
private func stale(_ l: Location) -> Bool { l.provider != "nord" && l.city != nil && l.region == nil }

/// A node name, or a Tailscale address (100.64.0.0/10, so the second octet is 64 to 127).
private func validNode(_ s: String) -> Bool {
    guard s.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,62}/) != nil else { return false }
    guard s.wholeMatch(of: /[0-9.]+/) != nil else { return true }
    let o = s.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
    return o.count == 4 && o.allSatisfy { (0...255).contains($0) } && o[0] == 100 && (64...127).contains(o[1])
}

/// Where a route, or an app's new route, leaves: a provider place, one of the user's servers, or a Tailscale device.
/// Nothing changes until "Use": the place, a Nord route's protocol and provider blocking are all applied together, so
/// Cancel leaves the route as it was.
struct PickerSheet: View {
    let target: String

    private let model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.addProvider) private var addProvider
    @Environment(\.openSettings) private var openSettings
    @State private var chosen: String?
    @State private var query = ""
    @State private var groupChoice: String?
    @State private var protocolChoice: String?
    @State private var mine: Bool
    @State private var optionsOpen = false
    @State private var expanded: Set<Int> = []
    @State private var selection: Choice?
    /// Countries offering the chosen Nord server type; nil while unknown.
    @State private var allowed: Set<String>?
    @State private var timedOut = false
    /// Provider blocking chosen for this route in the sheet (nil = untouched; then nil = as set in Settings), applied on "Use".
    @State private var filterChoice: Bool??
    /// A retry is under way: the earlier failure is not shown again until the new try has ended.
    @State private var retrying = false
    private var catalogFailed: Bool { !retrying && (provider.map { model.catalogFailures.contains($0.id) } ?? false) }

    init(target: String) {
        self.target = target
        let m = AppModel.shared
        let s = m.setup
        let route = s.route(target)
        let current = route.flatMap { $0.imported ? nil : $0.loc }
        let signed = Providers.all.filter { m.accounts[$0.id] != nil }
        // A route that already uses a Tailscale exit or a saved server opens on "My Servers".
        _mine = State(initialValue: route?.imported == true || signed.isEmpty && (s.tailscale || !s.servers.isEmpty))
        _groupChoice = State(initialValue: current?.group)
        _protocolChoice = State(initialValue: current?.proto)
        // Preselect the current place with the protocol the rows will carry, so its row is highlighted.
        var l = current.flatMap { stale($0) ? nil : $0 }
        let proto = effectiveProtocol(l?.provider, group: l?.group, choice: l?.proto)
        l?.proto = proto
        _selection = State(initialValue: l.map(Choice.loc) ?? route.flatMap { r in r.own.map(Choice.own) ?? r.tsExit.map { Choice.ts(ip: $0, name: r.tsName ?? $0) } })
    }

    // MARK: Derived

    private var signed: [any Provider] { Providers.all.filter { model.accounts[$0.id] != nil } }
    private var route: Route? { model.setup.route(target) }
    private var current: Location? { route.flatMap { $0.imported ? nil : $0.loc } }
    private var provider: (any Provider)? {
        let ids = Set(signed.map(\.id))
        return (chosen.flatMap { ids.contains($0) ? $0 : nil } ?? current.flatMap { ids.contains($0.provider) ? $0.provider : nil } ?? signed.first?.id).flatMap(Providers.get)
    }
    private var group: String? { provider?.id == "nord" ? groupChoice : nil }
    private var proto: String? { effectiveProtocol(provider?.id, group: group, choice: protocolChoice) }
    private var catalog: [Country] { provider.map { model.countries[$0.id] ?? [] } ?? [] }
    /// Specialty groups exist in a few countries only: list just those.
    private var countries: [Country] { allowed.map { a in catalog.filter { a.contains($0.code) } } ?? catalog }
    private var hasLoad: Bool { provider?.hasLoad == true }
    private var q: String { query.trimmingCharacters(in: .whitespaces) }
    private var selectedLocation: Location? { if case .loc(let l) = selection { l } else { nil } }
    private func hit(_ s: String) -> Bool { q.isEmpty || s.localizedStandardContains(q) }

    private func place(_ country: Country, _ city: City? = nil) -> Location {
        Location(provider: provider?.id ?? "", countryId: country.id, countryCode: country.code, country: country.name,
                 cityId: city?.id, city: city?.name, region: city?.key, group: group, proto: proto)
    }

    private var anywhere: Location { Location(provider: provider?.id ?? "", group: group, proto: proto) }

    // MARK: Body

    var body: some View {
        SheetFrame(title: title, subtitle: subtitle, width: SheetWidth.browser) {
            sourceRow
            if !mine { controls }
            if mine { searchRow }
            Divider()
            content
        } status: {
            status
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(existingRoute != nil ? "Show \(picked ?? "…")" : "Use \(picked ?? "…")") { apply() }
                .contentButton(prominent: true).keyboardShortcut(.defaultAction).disabled(picked == nil)
        }
        .frame(height: 620)
        .task(id: "\(provider?.id ?? "")\(group ?? "")") {
            allowed = nil
            if provider?.id == "nord", let g = group {
                let countries = await model.nordGroupCountries(g)
                // A lookup cancelled by a newer group comes back nil; it must not overwrite the newer filter.
                guard !Task.isCancelled else { return }
                allowed = countries
            }
        }
        .task(id: "\(provider?.id ?? "")\(catalog.isEmpty)") { await load() }
    }

    /// An empty catalogue is fetched; a fetch that never lands is reported after a while.
    private func load() async {
        timedOut = false
        guard let p = provider, catalog.isEmpty else { return }
        model.refreshCountries(p.id)
        // Cancelled by a switch to another provider: that one's own wait decides, not this late wake-up.
        guard (try? await Task.sleep(for: .seconds(10))) != nil else { return }
        timedOut = true
        retrying = false
    }

    private var title: String {
        if target.hasPrefix("app:") { let k = String(target.dropFirst(4)); return "Route for \(model.apps.app(k)?.name ?? k)" }
        return route.map { "Location for \($0.name)" } ?? "New Route"
    }

    private var subtitle: String {
        if route?.tsExit != nil { return "Tailscale exit node" }
        if route?.imported == true { return "Your own server" }
        guard let c = current else { return "Pick where this route exits" }
        return [Providers.get(c.provider)?.name ?? route?.source, c.pinned?.name ?? c.city, c.pinned == nil ? (hasLoad ? "fastest server" : "automatic server") : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private var sourceRow: some View {
        HStack {
            Spacer()
            Picker("Source", selection: Binding(get: { mine }, set: { mine = $0; query = ""; keepSelection(mine: $0, provider: provider?.id) })) {
                Text("Providers").tag(false)
                Text("My Servers").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .padding(.horizontal, Layout.gutter).padding(.bottom, 12)
    }

    /// Only a choice that belongs to the list now on show stays selected, so "Use" never applies one that is out of sight.
    private func keepSelection(mine: Bool, provider: String?) {
        switch selection {
        case .loc(let l): if mine || l.provider != provider { selection = nil }
        case .own, .ts: if !mine { selection = nil }
        case nil: break
        }
    }

    private var searchRow: some View {
        HStack { Spacer(); search("Server or device") }.padding(.horizontal, Layout.gutter).padding(.bottom, 10)
    }

    private func search(_ prompt: String) -> some View {
        TextField(prompt, text: $query, prompt: Text(prompt)).textFieldStyle(.roundedBorder).frame(width: 230).labelsHidden()
    }

    // MARK: Providers controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let p = provider {
                    Menu {
                        Picker("Provider", selection: Binding(get: { p.id }, set: { chosen = $0; expanded = []; keepSelection(mine: false, provider: $0) })) {
                            ForEach(signed, id: \.id) { Text($0.name).tag($0.id) }
                        }.pickerStyle(.inline)
                        Divider()
                        Button("Add a Provider…", action: addProvider)
                    } label: { Text(p.name) }
                        .fixedSize().accessibilityLabel("Provider")
                    if p.id == "nord" {
                        Button { withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) { optionsOpen.toggle() } } label: {
                            HStack(spacing: 4) {
                                Text("Options: \(nordProtocols.first { $0.key == proto }?.label ?? ""), \(group == nil ? "standard" : nordGroups.first { $0.key == group }?.label ?? "") servers")
                                Image(systemName: "chevron.right").imageScale(.small).rotationEffect(.degrees(optionsOpen ? 90 : 0))
                            }
                            .foregroundStyle(.secondary).font(.callout)
                        }.buttonStyle(.plain)
                            .accessibilityLabel("\(optionsOpen ? "Hide" : "Show") Options for \(p.name)")
                            .accessibilityValue(optionsOpen ? "Expanded" : "Collapsed")
                    } else {
                        Text(p.proto).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                search("Country or city")
            }
            if optionsOpen, provider?.id == "nord" { nordOptions }
            HStack {
                if let r = route, !r.imported, r.loc.provider == provider?.id, let p = provider, p.protection != nil {
                    let shown: Bool? = filterChoice ?? r.filter
                    Menu(providerProtectionAvailable(model.setup.prefs.effectiveFilter) ? "\(p.name) blocking" : "Off while unbraid’s filter is on for VPN routes") {
                        Button { filterChoice = .some(nil) } label: { Label("As Set for \(p.name) in Settings", systemImage: shown == nil ? "checkmark" : "") }
                        Button { filterChoice = .some(true) } label: { Label("On for This Route", systemImage: shown == true ? "checkmark" : "") }
                        Button { filterChoice = .some(false) } label: { Label("Off for This Route", systemImage: shown == false ? "checkmark" : "") }
                    }.disabled(!providerProtectionAvailable(model.setup.prefs.effectiveFilter))
                }
                Spacer()
                Button("\(provider?.name ?? "Provider") Settings…") { Presentation.shared.settingsTab = 0; openSettings() }.buttonStyle(.link)
            }
        }
        .padding(.horizontal, Layout.gutter).padding(.bottom, 10)
    }

    /// The protocol rides on the pending place; server type only narrows the next place picked.
    private var nordOptions: some View {
        let openVpnOnly = group.map(Nord.openVpnOnly.contains) ?? false
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Protocol").font(.caption).foregroundStyle(.secondary)
                ForEach(nordProtocols, id: \.label) { p in
                    let ok = p.key != nil || !openVpnOnly
                    Button { setProtocol(p.key) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: proto == p.key ? "checkmark.circle.fill" : "circle").foregroundStyle(proto == p.key ? AnyShapeStyle(Ink.accentText) : AnyShapeStyle(.secondary))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(p.label)
                                Text(ok ? p.note : "Double VPN and Onion use OpenVPN").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain).disabled(!ok)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Server type").font(.caption).foregroundStyle(.secondary)
                Picker("Server type", selection: Binding(get: { groupChoice }, set: { setGroup($0) })) {
                    ForEach(nordGroups, id: \.label) { Text($0.label).tag($0.key) }
                }.labelsHidden().fixedSize()
                Text("Lists only the countries that offer it. Pick a location to use it.").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).frame(width: 240, alignment: .leading)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.surface, in: .rect(cornerRadius: Corner.inner))
    }

    /// The pending Nord place follows the options, so "Use" applies what the sheet shows.
    private func retag() {
        guard case .loc(var l) = selection, l.provider == "nord" else { return }
        l.group = groupChoice
        l.proto = effectiveProtocol("nord", group: groupChoice, choice: protocolChoice)
        // A server found over OpenVPN may have no NordLynx key: under NordLynx it is picked again instead.
        if l.proto == nil, l.pinned?.publicKey.isEmpty == true { l.pinned = nil }
        selection = .loc(l)
    }

    private func setProtocol(_ p: String?) {
        protocolChoice = p
        // Double VPN and Onion only run over OpenVPN: NordLynx goes back to standard servers.
        if p == nil, groupChoice.map(Nord.openVpnOnly.contains) == true { groupChoice = nil }
        retag()
    }

    private func setGroup(_ g: String?) { groupChoice = g; retag() }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if mine { myServers } else if provider == nil { noProvider } else { locations }
    }

    private var noProvider: some View {
        VStack(spacing: 10) {
            Text("No providers signed in. Sign in to browse their locations.").foregroundStyle(.secondary)
            Button("Add a Provider…", action: addProvider)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var locations: some View {
        if catalog.isEmpty {
            VStack(spacing: 10) {
                if catalogFailed, let p = provider {
                    Text("Couldn't get \(p.name)'s server list.").foregroundStyle(.secondary)
                    Button("Retry") { retrying = true; Task { await load() } }
                } else if timedOut {
                    Text("Server list unavailable. Check the connection.").foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                } else { ProgressView("Loading locations") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                if q.isEmpty { browse } else { results }
            }
        }
    }

    @ViewBuilder private var browse: some View {
        Label { Text(hasLoad ? "Fastest anywhere" : "Automatic") } icon: { Image(systemName: "bolt.fill").foregroundStyle(Ink.dim) }.tag(Choice.loc(anywhere)).help("Any country, picked on connect")
        let favs = favourites
        if !favs.isEmpty { Section("Favourites") { ForEach(favs, id: \.favKey) { f in favourite(f) } } }
        Section("All Countries · \(countries.count)") {
            ForEach(countries) { c in
                country(c, open: Binding(get: { expanded.contains(c.id) }, set: { if $0 { expanded.insert(c.id) } else { expanded.remove(c.id) } }))
                if expanded.contains(c.id) { ForEach(c.cities, id: \.id) { city($0, in: c) } }
            }
        }
    }

    /// Search covers favourites, countries and cities of the chosen provider.
    @ViewBuilder private var results: some View {
        let favs = favourites.filter { hit($0.label) }
        let byName = countries.filter { hit($0.name) || hit($0.code) }
        let cities = countries.filter { c in !byName.contains(c) }.flatMap { c in c.cities.filter { hit($0.name) }.map { (c, $0) } }
        if favs.isEmpty && byName.isEmpty && cities.isEmpty {
            Text("No matches").foregroundStyle(.secondary)
        } else {
            if !favs.isEmpty { Section("Favourites") { ForEach(favs, id: \.favKey) { favourite($0) } } }
            Section("Locations") {
                ForEach(byName) { country($0, open: nil) }
                ForEach(cities, id: \.1.id) { c, ct in city(ct, in: c, subtitle: c.name) }
            }
        }
    }

    private var favourites: [Location] {
        var seen = Set<Location>()
        return model.setup.favorites.filter { $0.provider == provider?.id && !stale($0) && seen.insert($0.favKey).inserted }
    }

    private func favourite(_ f: Location) -> some View {
        var l = f
        l.group = group
        l.proto = proto
        return PlaceRow(loc: l, title: f.label, code: f.code, source: source, selected: selectedLocation) { choose($0) }.tag(Choice.loc(l))
    }

    private func country(_ c: Country, open: Binding<Bool>?) -> some View {
        let l = place(c)
        return PlaceRow(loc: l, title: c.name, code: c.code, count: c.serverCount, expanded: c.cities.isEmpty ? nil : open, source: source, selected: selectedLocation) { choose($0) }
            .tag(Choice.loc(l))
    }

    private func city(_ ct: City, in c: Country, subtitle: String? = nil) -> some View {
        let l = place(c, ct)
        return PlaceRow(loc: l, title: ct.name, subtitle: subtitle, code: subtitle == nil ? nil : c.code, indent: subtitle == nil, source: source, selected: selectedLocation) { choose($0) }
            .tag(Choice.loc(l))
    }

    private var source: (any Provider, String)? { provider.flatMap { p in model.accounts[p.id].map { (p, $0) } } }

    /// A server picked from a list pins the place to it.
    private func choose(_ l: Location) { selection = .loc(l) }

    // MARK: My servers

    private var myServers: some View {
        let s = model.setup
        let nodes = model.vpn.state.tsExitNodes.sorted { $0.online && !$1.online }
        let devices = nodes.filter { hit($0.name) || hit($0.ip) }
        let own = s.servers.filter { hit($0.name) || hit($0.kind) }
        let exit = s.routes.first { $0.tsExit != nil }
        let typed = s.tailscale && !q.isEmpty && validNode(q) && !nodes.contains { $0.ip == q || $0.name.caseInsensitiveCompare(q) == .orderedSame } ? q : nil
        return List(selection: $selection) {
            if s.tailscale {
                Section("Tailscale Exit Node") {
                    let note = [nodes.isEmpty ? "Connect and sign in to Tailscale to see your devices." : nil,
                                (exit?.tsName ?? exit?.tsExit).map { "One exit node at a time. Choosing another replaces \($0)." }].compactMap { $0 }.joined(separator: " ")
                    if !note.isEmpty && q.isEmpty { Text(note).font(.callout).foregroundStyle(.secondary) }
                    ForEach(devices, id: \.ip) { n in
                        let used = s.routes.filter { $0.tsExit == n.ip }.count
                        HStack(spacing: 8) {
                            StatusDot(color: n.online ? Ink.successText : Ink.off)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(n.name).foregroundStyle(n.online ? .primary : .secondary)
                                Text("\(n.ip) · \(n.online ? "online" : "offline") · " + (used == 0 ? "not used" : "used by \(used) route\(used == 1 ? "" : "s")")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.tag(Choice.ts(ip: n.ip, name: n.name))
                    }
                    // A device the tailnet hasn't listed yet (not connected, or just added) can still be named.
                    if let t = typed {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Use \(t)")
                            Text("As this route's Tailscale exit node").font(.caption).foregroundStyle(.secondary)
                        }.tag(Choice.ts(ip: t, name: t))
                    }
                }
            }
            if !own.isEmpty {
                Section("My Servers") {
                    ForEach(own) { o in
                        HStack(spacing: 10) {
                            Text(o.code).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).frame(width: 34)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(o.name)
                                Text(o.kind).font(.caption).foregroundStyle(.secondary)
                            }
                        }.tag(Choice.own(o.id))
                    }
                }
            }
            if devices.isEmpty && own.isEmpty && typed == nil && !q.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            if q.isEmpty {
                Section {
                    HStack {
                        Text(!s.tailscale && s.servers.isEmpty
                             ? "No servers yet. Add a WireGuard, OpenVPN or Shadowsocks server, or turn on Tailscale, in Settings."
                             : "Add or manage servers in Settings.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Settings") { Presentation.shared.settingsTab = 0; openSettings() }
                    }
                }.selectionDisabled()
            }
        }
    }

    // MARK: Footer

    private var picked: String? {
        switch selection {
        case .loc(let l): return l.pinned?.name ?? l.country.map { _ in l.label } ?? (hasLoad ? "Fastest anywhere" : "Automatic")
        case .own(let id): return model.setup.servers.first { $0.id == id }?.name
        case .ts(_, let name): return name
        case nil: return nil
        }
    }

    /// "New Route" on a place that already is one.
    private var existingRoute: Route? {
        guard target.isEmpty, let l = selectedLocation else { return nil }
        return model.setup.routes.first { !$0.imported && $0.loc.ident == l.ident }
    }

    private var status: some View {
        let who = target.hasPrefix("app:") ? model.apps.app(String(target.dropFirst(4)))?.name ?? "This app" : "This route"
        if existingRoute != nil, let picked { return Text("\(picked) is already a route.").lineLimit(1) }
        return Text(picked.map { "\(who) will leave through \($0)." } ?? "Pick where this route exits").lineLimit(1)
    }

    /// Follows Android: "" adds a route, a route id changes it, "app:<key>" adds one and moves the app onto it.
    private func apply() {
        switch selection {
        case .loc(var l):
            // A Nord server found over OpenVPN may have no NordLynx key: it is kept only where it can be used.
            l.pinned = l.pinned.flatMap { l.provider != "nord" || l.proto != nil || !$0.publicKey.isEmpty ? $0 : nil }
            if target.isEmpty {
                // A place that is already a route is shown instead of added twice.
                if let existing = existingRoute { Presentation.shared.page = .apps(existing.id) } else { model.addRoute(l) }
            }
            else if target.hasPrefix("app:") { model.addRouteForApp(String(target.dropFirst(4)), l) }
            else {
                model.setLocation(target, l)
                if let choice = filterChoice, let r = model.setup.route(target), !r.imported, r.loc.provider == l.provider { model.setFilter(target, choice) }
            }
        case .own(let id): if let s = model.setup.servers.first(where: { $0.id == id }) { model.useServer(target, s) }
        case .ts(let ip, let name): model.addTsExit(target, ip: ip, name: name)
        case nil: return
        }
        dismiss()
    }
}

/// One place: country, city or favourite, with server and favourite actions.
private struct PlaceRow: View {
    private let model = AppModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let loc: Location
    let title: String
    var subtitle: String?
    var code: String?
    var count = 0
    var indent = false
    var expanded: Binding<Bool>?
    let source: (any Provider, String)?
    let selected: Location?
    let onServer: (Location) -> Void
    @State private var servers = false

    var body: some View {
        let fav = model.setup.favorites.contains { $0.favKey == loc.favKey }
        HStack(spacing: 8) {
            if let expanded {
                Button { withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) { expanded.wrappedValue.toggle() } } label: {
                    Image(systemName: "chevron.right").imageScale(.small).rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                        .frame(width: 28, height: 28).contentShape(.rect)
                }.buttonStyle(.quiet).help(expanded.wrappedValue ? "Hide Cities" : "Show Cities")
                    .accessibilityLabel("\(expanded.wrappedValue ? "Hide" : "Show") Cities in \(title)")
                    .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
            } else { Color.clear.frame(width: indent ? 50 : 28, height: 1) }
            if let code { Text(code).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).frame(width: 26, alignment: .leading) }
            Text(title)
            if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            Spacer()
            if loc.pinned == nil, loc.country != nil, source != nil {
                Button("Pick a Server…") { servers = true }.buttonStyle(.borderless).foregroundStyle(Ink.accentText)
                    .accessibilityLabel("Pick a Server in \(loc.label)")
                    .popover(isPresented: $servers, arrowEdge: .leading) {
                        if let (p, account) = source {
                            ServerList(provider: p, account: account, loc: loc, selected: selected) { s in
                                var l = loc
                                l.pinned = s
                                servers = false
                                onServer(l)
                            }
                        }
                    }
            }
            if count > 0 { Text("\(count.formatted()) servers").font(.callout).foregroundStyle(.secondary) }
            Button { model.toggleFavorite(loc) } label: { Image(systemName: fav ? "star.fill" : "star") }
                .buttonStyle(.quiet).foregroundStyle(fav ? AnyShapeStyle(Ink.warningText) : AnyShapeStyle(.secondary))
                .help(fav ? "Remove from Favourites" : "Add to Favourites")
                .accessibilityLabel("\(fav ? "Remove" : "Add") \(loc.label) \(fav ? "from" : "to") Favourites")
                .accessibilityValue(fav ? "Favourite" : "Not a Favourite")
        }
        .contentShape(.rect)
    }
}

/// Up to 20 Nord servers or 200 elsewhere, lowest load first (unknown last).
private struct ServerList: View {
    private let model = AppModel.shared
    let provider: any Provider
    let account: String
    let loc: Location
    let selected: Location?
    let pick: (Server) -> Void
    @State private var list: [Server]?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if failed {
                VStack(spacing: 10) {
                    Text("Couldn't load servers. Check the connection.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Retry") { failed = false; attempt += 1 }
                }.padding()
            } else if let list {
                if list.isEmpty { Text("No servers found").foregroundStyle(.secondary) } else {
                    List(Array(list.enumerated()), id: \.offset) { _, s in
                        let pinned = pinned(s)
                        let fav = model.setup.favorites.contains { $0.favKey == pinned.favKey }
                        HStack {
                            Button { pick(s) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(s.name)
                                        Text([s.city.nilIfEmpty, provider.hasLoad && s.load >= 0 ? "\(s.load)% load" : nil].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selected?.provider == provider.id, selected?.pinned?.name == s.name {
                                        Image(systemName: "checkmark").foregroundStyle(Ink.accentText).accessibilityLabel("Selected")
                                    }
                                }.contentShape(.rect)
                            }.buttonStyle(.plain)
                            Button { model.toggleFavorite(pinned) } label: { Image(systemName: fav ? "star.fill" : "star") }
                                .buttonStyle(.quiet).foregroundStyle(fav ? AnyShapeStyle(Ink.warningText) : AnyShapeStyle(.secondary))
                                .help(fav ? "Remove from Favourites" : "Add to Favourites")
                                .accessibilityLabel("\(fav ? "Remove" : "Add") \(s.name) \(fav ? "from" : "to") Favourites")
                                .accessibilityValue(fav ? "Favourite" : "Not a Favourite")
                        }
                    }
                }
            } else { ProgressView("Loading servers") }
        }
        .frame(width: 300, height: 320)
        .task(id: attempt) {
            let result = try? await provider.servers(loc, account, limit: provider.id == "nord" ? 20 : 200, opts: model.setup.opts[provider.id] ?? [:])
            guard !Task.isCancelled else { return }
            guard let found = result else { failed = true; return }
            list = found.sorted { ($0.load < 0 ? .max : $0.load) < ($1.load < 0 ? .max : $1.load) }
        }
    }

    private func pinned(_ server: Server) -> Location {
        var l = loc
        l.pinned = server
        return l
    }
}
