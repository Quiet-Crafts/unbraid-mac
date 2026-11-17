import SwiftUI

// Profiles in the window and the menu bar: the menu that switches between saved setups, and the sheets that save a
// new one and rename or delete them.

struct ProfileMenu: View {
    /// The label while no profile is in use.
    var none = "Profiles"
    private let model = AppModel.shared
    @State private var saving = false
    @State private var managing = false

    var body: some View {
        Menu {
            ForEach(model.setup.profiles) { profile in
                Button { model.switchProfile(profile.name) } label: {
                    if model.setup.profile == profile.name { Label(profile.name, systemImage: "checkmark") }
                    else { Text(profile.name) }
                }
                .accessibilityValue(model.setup.profile == profile.name ? "In use" : "")
            }
            if !model.setup.profiles.isEmpty { Divider() }
            Button("Save as Profile…") { saving = true }.disabled(model.setup.profiles.count >= Setup.maxProfiles)
            Button("Manage Profiles…") { managing = true }
        } label: { Label(model.setup.profile ?? none, systemImage: "person.crop.square") }
        .sheet(isPresented: $saving) { SaveProfileSheet() }
        .sheet(isPresented: $managing) { ManageProfilesSheet() }
    }
}

private struct SaveProfileSheet: View {
    private let model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        SheetFrame(title: "Save as Profile", subtitle: "Keeps your default route and every app’s choice") {
            VStack(alignment: .leading, spacing: 12) {
                HStack { TextField("Name", text: $name); Text("\(name.count)/12").foregroundStyle(.secondary) }
                if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   model.setup.profiles.contains(where: { $0.name.compare(name.trimmingCharacters(in: .whitespacesAndNewlines), options: .caseInsensitive) == .orderedSame }) {
                    Text("You already have a profile with this name").foregroundStyle(Ink.failedText)
                }
                Card(spacing: 8) {
                    Text("What it keeps").font(.headline)
                    Text("Default route · \(model.setup.label(model.setup.defaultRoute))")
                    let counts = Dictionary(grouping: model.setup.apps.values, by: { $0 }).mapValues(\.count).sorted { $0.key < $1.key }
                    ForEach(Array(counts.prefix(3)), id: \.key) { id, count in Text("\(model.setup.label(id)) · \(count) app\(count == 1 ? "" : "s")") }
                    if counts.count > 3 { Text("+\(counts.count - 3) more") }
                    Text("Routes are shared: changing a route's location changes it in every profile that uses it.").foregroundStyle(.secondary)
                }
            }.padding(.horizontal, Layout.gutter).padding(.bottom, Layout.inset)
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { model.store.update { $0.saveAs(name) }; dismiss() }
                .disabled(model.setup.profileName(name) == nil).keyboardShortcut(.defaultAction).contentButton(prominent: true)
        }
    }
}

struct ManageProfilesSheet: View {
    private let model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var rename: String?
    @State private var name = ""
    @State private var deleting: String?

    var body: some View {
        SheetFrame(title: "Manage Profiles", subtitle: "\(model.setup.profiles.count) of 20", width: SheetWidth.form) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    List {
                        ForEach(model.setup.saved) { p in
                            HStack {
                                VStack(alignment: .leading) {
                                    HStack { Text(p.name); if p.name == model.setup.profile { Text("In use").font(.caption).foregroundStyle(.secondary) } }
                                    Text("\(model.setup.label(p.defaultRoute)) · \(p.apps.count) with their own route").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { model.store.update { $0.move(p.name, by: -1) } } label: { Image(systemName: "arrow.up") }
                                    .help("Move Up").accessibilityLabel("Move \(p.name) Up")
                                Button { model.store.update { $0.move(p.name, by: 1) } } label: { Image(systemName: "arrow.down") }
                                    .help("Move Down").accessibilityLabel("Move \(p.name) Down")
                                Button("Rename") { rename = p.name; name = p.name }.accessibilityLabel("Rename \(p.name)")
                                Button("Delete", role: .destructive) { deleting = p.name }.accessibilityLabel("Delete \(p.name)")
                            }
                            .accessibilityAction(named: "Move Up") { model.store.update { $0.move(p.name, by: -1) } }
                            .accessibilityAction(named: "Move Down") { model.store.update { $0.move(p.name, by: 1) } }
                        }.onMove { source, destination in
                            var names = model.setup.profiles.map(\.name)
                            names.move(fromOffsets: source, toOffset: destination)
                            model.store.update { s in s.profiles.sort { (names.firstIndex(of: $0.name) ?? 0) < (names.firstIndex(of: $1.name) ?? 0) } }
                        }
                    }
                    // Its own scrolling, inside the sheet's: as tall as a few rows.
                    .frame(height: CGFloat(min(max(model.setup.profiles.count, 2), 5)) * 54 + 12)
                    if model.setup.profiles.count >= Setup.maxProfiles { Text("20 profiles is the most. Delete one to add another.") }
                    Text("The first three are also in Control Center and the Shortcuts app.").foregroundStyle(.secondary)
                    SwitchByItself().padding(.top, 12)
                }.padding(.horizontal, Layout.gutter).padding(.bottom, Layout.inset)
            }
        } actions: {
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).contentButton(prominent: true)
        }.frame(height: 680)
        .onExitCommand { dismiss() }
        .alert("Rename Profile", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
            TextField("Name", text: $name)
            Button("Save") {
                guard let old = rename, let new = model.setup.profileName(name, except: old) else { return }
                model.store.update { $0.rename(old, new) }
                // The networks that switch to it follow it.
                if model.setup.profiles.contains(where: { $0.name == new }) { model.store.updateNetworks { $0.renamed(old, to: new) } }
            }.disabled(model.setup.profileName(name, except: rename) == nil)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete Profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                guard let name = deleting else { return }
                model.store.update { $0.forget(name) }
                model.store.updateNetworks { $0.deleted(name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your routes stay as they are now.") }
    }
}

/// Profiles › Switch by Itself: the networks unbraid remembers, the profile for each and for any other network.
private struct SwitchByItself: View {
    private let model = AppModel.shared
    @State private var remembering: String?
    @State private var name = ""

    private var rules: NetworkRules { model.store.networks }
    private static let footer = "While unbraid is connected, it switches a few seconds after your Mac joins another network; apps reconnect for a moment. A network it can't recognise counts as any other network after about 20 seconds. A profile you pick by hand stays until the network changes or unbraid starts again. unbraid recognises a network by its router, without reading your location or the Wi-Fi's name. Another network can pretend to be one you remembered, so don't give a remembered network a profile that protects less than you'd accept anywhere."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Switch by Itself").overline().accessibilityAddTraits(.isHeader)
            if model.setup.profiles.isEmpty {
                Text("Save a profile first: a network switches to a profile.").foregroundStyle(.secondary)
            } else {
                Card(spacing: 0, padding: 0) {
                    ForEach(rules.known) { n in
                        row("wifi", n.name, caption(n), profile: n.profile, set: { p in model.store.updateNetworks { r in
                            if let i = r.known.firstIndex(where: { $0.id == n.id }) { r.known[i].profile = p }
                        } }) {
                            Button { model.store.updateNetworks { $0.forget(network: n.id) } } label: { Image(systemName: "minus") }
                                .buttonStyle(.quiet).foregroundStyle(.secondary)
                                .help("Forget \(n.name)").accessibilityLabel("Forget \(n.name)")
                        }
                        Hairline().padding(.leading, Layout.inset + Measure.rowIcon + 12)
                    }
                    row("globe", "Any other network", unusable(rules.elsewhere) ?? "Cafés, hotels, and networks unbraid can't recognise", profile: rules.elsewhere,
                        set: { p in model.store.updateNetworks { $0.elsewhere = p } }) {
                        // Its menu in line with the ones above, which have Forget beside them.
                        if !rules.known.isEmpty { Color.clear.frame(width: 24, height: 24) }
                    }
                }
                HStack(spacing: 10) {
                    Button("Remember This Network…") {
                        remembering = model.autoSwitch.mark
                        name = rules.known.isEmpty ? "Home network" : ""
                    }.contentButton().disabled(why != nil)
                    if let why { Text(why).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
            }
            Text(Self.footer).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .alert("Remember This Network", isPresented: Binding(get: { remembering != nil }, set: { if !$0 { remembering = nil } })) {
            TextField("Name", text: $name)
            Button("Remember") { if let mark = remembering { model.store.updateNetworks { $0.remember(mark, name: name, profile: nil) } } }
                .disabled(rules.name(name) == nil)
            Button("Cancel", role: .cancel) {}
        } message: { Text("A name for the network your Mac is on now.") }
    }

    /// Why this network can't be remembered now; nil when it can.
    private var why: String? {
        // A network whose router has nothing of its own that unbraid may read (no IPv6, or a router that calls itself
        // "1"): said as it is, not as "no network".
        guard let mark = model.autoSwitch.mark else {
            return model.autoSwitch.online ? "unbraid can't tell this network apart from others, so it can't be remembered" : "No network to remember right now"
        }
        if let known = rules.known.first(where: { $0.id == mark }) { return "Already remembered as \(known.name)" }
        return rules.known.count >= NetworkRules.max ? "\(NetworkRules.max) networks is the most. Forget one to remember another." : nil
    }

    private func caption(_ n: NetworkRules.Known) -> String {
        unusable(n.profile) ?? "Remembered \(n.added.formatted(.dateTime.day().month(.abbreviated)))" + (n.id == model.autoSwitch.mark ? " · this is the network you're on" : "")
    }

    /// A profile whose default route is gone can't be switched to: said where the caption is.
    private func unusable(_ profile: String?) -> String? {
        guard let p = profile, let saved = model.setup.saved.first(where: { $0.name == p }) else { return nil }
        return saved.defaultRoute == DIRECT || model.setup.route(saved.defaultRoute) != nil ? nil : "This profile needs a default route first"
    }

    private func row(_ symbol: String, _ title: String, _ caption: String, profile: String?, set: @escaping (String?) -> Void,
                     @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Ink.dim).frame(width: Measure.rowIcon).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(caption).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }.layoutPriority(1).accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            GlassMenu(glass: false) {
                ForEach(model.setup.profiles) { p in
                    Button { set(p.name) } label: { if profile == p.name { Label(p.name, systemImage: "checkmark") } else { Text(p.name) } }
                }
                Divider()
                Button { set(nil) } label: { if profile == nil { Label("Don't Switch", systemImage: "checkmark") } else { Text("Don't Switch") } }
            } label: { Text(profile ?? "Don't Switch").lineLimit(1) }
            .accessibilityLabel("Profile on \(title)").accessibilityValue(profile ?? "Don't Switch")
            trailing()
        }
        .padding(.horizontal, Layout.inset).padding(.vertical, 6).frame(minHeight: Measure.listRow)
    }
}
