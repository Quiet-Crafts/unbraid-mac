import SwiftUI

/// Add Proxy Server: a SOCKS5 proxy on this Mac or elsewhere. The logic (the pasted link, the errors, the remote
/// warning's two steps) is `ProxyForm`; this view only shows it. `add` saves the server, or holds it for later, and
/// says why it couldn't; `note` is the sheet's footer.
struct ProxySheet: View {
    var note: String?
    let add: (PendingProxy) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var form = ProxyForm()
    @State private var saveError: String?

    var body: some View {
        SheetFrame(title: "Add Proxy Server", subtitle: "Paste a socks5:// link into Address to fill the fields.") {
            Form {
                Section {
                    field(form.hostError) {
                        TextField("Address", text: Binding(get: { form.address }, set: { form.setAddress($0) }), prompt: Text("127.0.0.1"))
                    }
                    field(form.portError) { TextField("Port", text: $form.port, prompt: Text("1080")) }
                }
                Section {
                    field(form.usernameError) { TextField("Username (optional)", text: $form.username) }
                    field(form.passwordError, note: form.passwordNote) { SecretField("Password (optional)", text: $form.password) }
                    TextField("Name (optional)", text: $form.name, prompt: Text(form.host.isEmpty ? "e.g. Office" : form.displayName))
                } footer: { if let note { Text(note) } }
                if form.remote {
                    Section {
                        Label { Text(ProxyForm.remoteWarning) } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                        }
                    }
                }
                if let e = saveError { Section { ErrorLine(text: e) } }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
        } status: {
            Text(form.status).lineLimit(1)
        } actions: {
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(form.primaryTitle, action: submit).keyboardShortcut(.defaultAction).contentButton(prominent: true)
        }
        .frame(height: 470)
        // The password field and a pasted link stay out of screen recordings, as in the importer.
        .background(CaptureExclusion())
        // A new attempt starts clean: the old error no longer describes what is typed.
        .onChange(of: [form.address, form.port, form.username, form.password, form.name]) { saveError = nil }
    }

    /// A field with its error, or its note, under it.
    private func field(_ error: String?, note: String? = nil, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
            if let error { Text(error).font(.caption).foregroundStyle(Ink.failedText) }
            else if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func submit() {
        guard let p = form.add() else { return }
        if let e = add(p) { saveError = e; return }
        dismiss()
    }
}

/// A route that asks which app runs its proxy: before it becomes the default, or to change the app.
struct ProxyAppAsk: Identifiable, Hashable {
    let id: String
    let makeDefault: Bool
}

/// "Which app runs this proxy?": the app (or a helper or command-line tool) that is the proxy on this Mac goes Direct,
/// so its own traffic never comes back into it. Nothing changes until Make Default (or Save); Cancel keeps the default.
struct ProxyAppSheet: View {
    let ask: ProxyAppAsk
    private let model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chosen: String?

    init(ask: ProxyAppAsk) {
        self.ask = ask
        _chosen = State(initialValue: AppModel.shared.setup.route(ask.id)?.socks5?.proxyApp)
    }

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let apps = model.apps.apps.filter { !$0.missing && AppSearch.matches(name: $0.name, id: $0.id, query: q) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        SheetFrame(title: "Which app runs this proxy?", subtitle: "This app will use Direct so it can connect without going through itself.") {
            HStack {
                TextField("Search Apps", text: $query).textFieldStyle(.roundedBorder)
                Button("Choose Executable…", action: chooseExecutable).contentButton()
            }
            .padding(.horizontal, Layout.gutter).padding(.bottom, 12)
            List(selection: $chosen) {
                // A program chosen with Choose Executable… (or hidden by the search) is named at the top, ticked.
                if let c = chosen, !apps.contains(where: { $0.id == c }) { row(model.apps.app(c), name: model.appName(c), id: c) }
                ForEach(apps) { row($0, name: $0.name, id: $0.id) }
            }
        } status: {
            Text(ask.makeDefault ? "Change it later with Change Proxy App… on the route's page." : chosen.map { model.appName($0) } ?? "").lineLimit(1)
        } actions: {
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(ask.makeDefault ? "Make Default" : "Save") {
                if let chosen { model.setProxyApp(ask.id, chosen, makeDefault: ask.makeDefault) }
                dismiss()
            }
            .keyboardShortcut(.defaultAction).contentButton(prominent: true).disabled(chosen == nil)
        }
        .frame(height: 520)
    }

    /// An app or program, ticked while it is the choice.
    private func row(_ app: AppInfo?, name: String, id: String) -> some View {
        HStack(spacing: 8) {
            AppIconView(app: app)
            Text(name)
            Spacer()
            if id == chosen { Image(systemName: "checkmark").foregroundStyle(Ink.accentText).accessibilityLabel("Chosen") }
        }
        .tag(id)
    }

    /// A helper or a command-line proxy that isn't in the list: listed from now on, and chosen.
    private func chooseExecutable() {
        let p = NSOpenPanel()
        p.message = "Choose the app or command-line tool that runs this proxy."
        p.prompt = "Choose"
        p.resolvesAliases = false
        guard p.runModal() == .OK, let url = p.url,
              AppScan.bundle(url, system: false) != nil || FileManager.default.isExecutableFile(atPath: url.path) else { return }
        chosen = model.apps.add(url)
        query = ""
    }
}
