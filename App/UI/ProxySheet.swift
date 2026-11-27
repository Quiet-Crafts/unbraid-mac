import SwiftUI

/// Add Proxy Server: a SOCKS5 proxy on this Mac or elsewhere. The logic (the pasted link, the errors, the remote
/// warning's two steps) is `ProxyForm`; this view only shows it. `added` gets the server once its password is kept.
struct ProxySheet: View {
    let added: (Socks5Profile) -> Void

    private let model = AppModel.shared
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
                }
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
            Button(form.primaryTitle, action: add).keyboardShortcut(.defaultAction).contentButton(prominent: true)
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

    private func add() {
        guard let p = form.add() else { return }
        if let e = model.keepProxy(p) { saveError = e; return }
        added(p.profile)
        dismiss()
    }
}
