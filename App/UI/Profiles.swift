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
                    ForEach(Array(counts.prefix(3)), id: \.key) { id, count in Text("\(model.setup.label(id)) · \(count) apps") }
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

private struct ManageProfilesSheet: View {
    private let model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var rename: String?
    @State private var name = ""
    @State private var deleting: String?

    var body: some View {
        SheetFrame(title: "Manage Profiles", subtitle: "\(model.setup.profiles.count) of 20", width: SheetWidth.form) {
            VStack(alignment: .leading, spacing: 12) {
                List {
                    ForEach(model.setup.saved) { p in
                        HStack {
                            VStack(alignment: .leading) {
                                HStack { Text(p.name); if p.name == model.setup.profile { Text("In use").font(.caption).foregroundStyle(.secondary) } }
                                Text("\(model.setup.label(p.defaultRoute)) · \(p.apps.count) exceptions").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { model.store.update { $0.move(p.name, by: -1) } } label: { Image(systemName: "arrow.up") }
                                .accessibilityLabel("Move \(p.name) Up")
                            Button { model.store.update { $0.move(p.name, by: 1) } } label: { Image(systemName: "arrow.down") }
                                .accessibilityLabel("Move \(p.name) Down")
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
                if model.setup.profiles.count >= Setup.maxProfiles { Text("20 profiles is the most. Delete one to add another.") }
                Text("The first three are also in Control Center and the Shortcuts app.").foregroundStyle(.secondary)
            }.padding(.horizontal, Layout.gutter).padding(.bottom, Layout.inset)
        } actions: {
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).contentButton(prominent: true)
        }.frame(height: 420)
        .alert("Rename Profile", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
            TextField("Name", text: $name)
            Button("Save") { if let old = rename { model.store.update { $0.rename(old, name) } } }.disabled(model.setup.profileName(name, except: rename) == nil)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete Profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let name = deleting { model.store.update { $0.forget(name) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your routes stay as they are now.") }
    }
}
