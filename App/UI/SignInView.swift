import SwiftUI
import UniformTypeIdentifiers

/// What unbraid reads and where traffic goes, said before anything is set up and again under Settings › About.
enum Disclosure {
    static let text = """
        unbraid creates a VPN on this Mac to route each app through the exit you chose. It reads the list of installed apps only on this Mac, to let you assign them. Traffic goes to the exits you chose: VPN providers, your own servers or Tailscale. Apps set to Direct and your local network, if allowed, use your normal connection.

        unbraid has no servers of its own and no analytics. Its optional DNS filters contact dns.adguard-dns.com, family.adguard-dns.com, security.cloudflare-dns.com, family.cloudflare-dns.com, dns.nextdns.io or dns.quad9.net, or your own server. It contacts your VPN providers, DNS servers, Tailscale if you use it, and GitHub for some server lists. If you turn on the update check, it asks unbraid.app for the newest version number about once a day. unbraid's own requests to your providers and to unbraid.app use your normal connection, not the VPN. To check that a VPN still works, it asks Google or Cloudflare through that VPN, never over your normal connection. To show an exit address, it asks www.cloudflare.com or one.one.one.one through that exit while its page or the menu bar is open. With Direct as the default route, some lookups made through macOS, but not addresses, use your network’s DNS.

        AirVPN API-key sign-in sends your API key in a header to airvpn.org/api/ to list, add, rename and remove devices, read the generator config and your account information. IVPN sends your two-factor code or captcha answer to api.ivpn.net with your sign-in when required. Mullvad uses api.mullvad.net to read your account details and list, register, check and remove devices.
        """
}

/// First run (no Close, wordmark and pitch) or the same choices in a sheet: pick a provider and sign in, import a
/// server of your own, or use Tailscale only.
struct SignInView: View {
    var first: Bool
    /// Opened from the location picker: a server imported here is only saved, and the picker (which comes back) lists it.
    var saveOnly = false
    private let model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var choice: String?
    @State private var importer = Importer()

    var body: some View {
        NavigationStack {
            list
                .navigationDestination(item: $choice) { id in
                    if let p = Providers.get(id) { ProviderForm(provider: p, first: first) { dismiss() } }
                }
        }
        // A saved server also becomes the first route. First run needs no dismissal: signedIn flips and RootView swaps.
        .importFlow(importer, target: saveOnly ? nil : "") { if !first { dismiss() } }
        .frame(width: first ? nil : 520, height: first ? nil : 540)
        .background(CaptureExclusion())
    }

    private var list: some View {
        let providers = Providers.all.filter { model.accounts[$0.id] == nil }
        return VStack(alignment: .leading, spacing: 0) {
            if first {
                VStack(alignment: .leading, spacing: 6) {
                    Wordmark(size: 64)
                    Text("Every app, its own exit.").font(.title3).foregroundStyle(Ink.dim)
                }
                .accessibilityElement(children: .combine)
                .padding(.horizontal, Layout.gutter * 2).padding(.top, Layout.gutter)
            }
            Form {
                if model.notice != nil || (model.store.unsaved && !model.store.unsavedDismissed) {
                    Section {
                        if let n = model.notice { NoticeRow(text: n) }
                        // A failed sign-out would return after restart unless the change is saved.
                        if model.store.unsaved && !model.store.unsavedDismissed { UnsavedRow() }
                    }
                }
                Section("VPN providers") {
                    ForEach(providers, id: \.id) { p in
                        row(p.name, p.fields.map(\.label).joined(separator: " · "), initial: String(p.name.prefix(1)), chevron: true) { choice = p.id }
                    }
                }
                Section {
                    row("Import WireGuard or OpenVPN File…", ".conf or .ovpn, from any provider or your own server", symbol: "doc") { importer.file() }
                    row("Add Shadowsocks Link…", "Paste an ss:// access key", symbol: "link") { importer.shadowsocks() }
                    if first {
                        row("Use Tailscale Only", "No VPN provider, just your tailnet", symbol: "circle.grid.3x3", color: IconTile.Tile.indigo) { model.useTailscaleOnly() }
                    }
                } header: {
                    Text("My Servers")
                } footer: {
                    if let e = importer.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Ink.failedText) }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
        }
        .frame(maxWidth: first ? 640 : nil).frame(maxWidth: .infinity)
        .modifier(WelcomeGround(first: first))
        .navigationTitle(first ? "Welcome to unbraid" : "Add a Provider")
        .toolbar { if !first { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } }
    }

    private func row(_ title: String, _ sub: String, initial: String? = nil, symbol: String? = nil,
                     color: Color = IconTile.Tile.blue, chevron: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let initial { IconTile(text: initial, color: IconTile.Tile.gray, size: Measure.rowIcon) }
                else if let symbol { IconTile(symbol: symbol, color: color, size: Measure.rowIcon) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).lineLimit(1)
                    Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if chevron { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary) }
            }
            .frame(maxWidth: .infinity, minHeight: Measure.listRow, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(.plain).help("\(title)\n\(sub)").accessibilityLabel("\(title), \(sub)")
    }
}

private struct WelcomeGround: ViewModifier {
    let first: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if first { content.pageGround() } else { content.background(Ink.ground) }
    }
}

/// The where-to-find-it pages the providers' help text names.
private let keyPages = [
    "nord": "https://my.nordaccount.com/", "mullvad": "https://mullvad.net/account", "proton": "https://account.protonvpn.com/",
    "proton-free": "https://account.protonvpn.com/", "surfshark": "https://my.surfshark.com/",
    "expressvpn": "https://www.expressvpn.com/setup#manual", "windscribe": "https://windscribe.com/", "airvpn": "https://airvpn.org/apisettings/",
]

/// One provider's fields, its help and Sign In. Typed values live only in this view's state and go with it.
private struct ProviderForm: View {
    let provider: any Provider
    let first: Bool
    let done: () -> Void
    private let model = AppModel.shared
    @State private var values: [String: String] = [:]
    @State private var pastedQR: (key: String, value: String, changeCount: Int)?
    @State private var picking = false
    @State private var revealedFiles: Set<String> = []
    /// The field the file is for; kept apart from `picking`, which the picker resets before it reports.
    @State private var fileField: Field?

    private var busy: Bool { model.signing.contains(provider.id) }
    private var ready: Bool { (provider.fields + [model.challenges[provider.id]?.field].compactMap { $0 }).allSatisfy { !(values[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    var body: some View {
        let id = provider.id
        Form {
            Section {
                ForEach(provider.fields, id: \.key) { f in field(f) }
            } header: { Text("Enter your details") }
            if let challenge = model.challenges[id] {
                Section {
                    Text(challenge.message)
                    if let data = challenge.image, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 150) }
                    field(challenge.field)
                    Button("Cancel") { clearPastedSecrets(); model.closeProviderForm(id); values[challenge.field.key] = nil }
                }
            }
            if let e = model.formError[id] {
                Section {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Ink.failedText)
                    if let url = model.formErrorURL[id].flatMap(URL.init(string:)) {
                        SwiftUI.Link("Open the \(provider.name) Client Area", destination: url)
                    }
                }
            }
            Section {
                Text("\(provider.help) Stored encrypted on this Mac.").foregroundStyle(.secondary)
                if let u = keyPages[id].flatMap(URL.init(string:)) { SwiftUI.Link("Where to Find It", destination: u) }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).background(Ink.ground)
        .navigationTitle(provider.name)
        .toolbar {
            // Escape leaves the whole sheet from here too, not only from the list behind.
            if !first { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) } }
            ToolbarItem(placement: .confirmationAction) {
                Button { submit() } label: {
                    if busy { ProgressView().controlSize(.small).accessibilityLabel("Working") } else { Text("Sign In") }
                }
                .buttonStyle(.glassProminent).tint(Ink.accent).prominentForeground().keyboardShortcut(.defaultAction).disabled(!ready || busy)
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: Importer.types) { r in
            guard let f = fileField, case .success(let url) = r else { return }
            switch readConfig(url) {
            case .success(let text): values[f.key] = text; model.formError[id] = nil
            case .failure(let e): model.formError[id] = e.errorDescription
            }
        }
        // A finished sign-in closes a sheet; on first run RootView swaps to the app by itself.
        .onChange(of: model.accounts[id] != nil) { _, signedIn in if signedIn && !first { done() } }
        // Leaving the form discards what was typed (secrets) and its error.
        .onDisappear { clearPastedSecrets(); values = [:]; revealedFiles = []; model.closeProviderForm(id) }
    }

    /// A secret pasted into the form and then abandoned must not stay on the clipboard.
    private func clearPastedSecrets() {
        let fields = provider.fields + [model.challenges[provider.id]?.field].compactMap { $0 }
        for f in fields where f.secret { if let v = values[f.key], !v.isEmpty { model.clearClipboardIf(v) } }
        // A pasted QR image is cleared too, if the clipboard still holds that paste.
        if let qr = pastedQR, values[qr.key] == qr.value, NSPasteboard.general.changeCount == qr.changeCount { NSPasteboard.general.clearContents() }
    }

    @ViewBuilder private func field(_ f: Field) -> some View {
        let text = Binding(get: { values[f.key] ?? "" }, set: {
            values[f.key] = $0; model.formError[provider.id] = nil
            if let challenge = model.challenges[provider.id], f.key != challenge.field.key { model.closeProviderForm(provider.id); values[challenge.field.key] = nil }
        })
        let prompt = Text(f.hint.isEmpty ? f.label : f.hint)
        if f.file {
            // Configs contain private keys. Paste/load keeps every line without revealing them.
            let reveal = !f.secret || revealedFiles.contains(f.key)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(f.label)
                    Spacer()
                    if f.secret {
                        Button { if reveal { revealedFiles.remove(f.key) } else { revealedFiles.insert(f.key) } } label: {
                            Image(systemName: reveal ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.quiet).help("\(reveal ? "Hide" : "Show") \(f.label)")
                        .accessibilityLabel("\(reveal ? "Hide" : "Show") \(f.label)")
                    }
                }
                if reveal {
                    TextEditor(text: text).font(.system(.callout, design: .monospaced)).frame(height: 96)
                        .overlay(alignment: .topLeading) { if text.wrappedValue.isEmpty { prompt.foregroundStyle(.tertiary).padding(6).allowsHitTesting(false) } }
                        .scrollContentBackground(.hidden).background(Ink.surface, in: .rect(cornerRadius: Corner.mark))
                        .accessibilityLabel(f.label)
                } else {
                    HStack {
                        Text(text.wrappedValue.isEmpty ? "Paste or choose a config file" : "Config hidden").foregroundStyle(.secondary)
                        Spacer()
                        Button("Paste") { if let value = NSPasteboard.general.string(forType: .string) { text.wrappedValue = value } }
                    }
                }
                HStack {
                    Text(text.wrappedValue.contains("\n") ? "Config file loaded" : "Or load the downloaded file").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose File…") { fileField = f; picking = true }
                }
            }
        } else if f.qr {
            VStack(alignment: .leading) {
                SecretField(f.label, text: text, prompt: prompt).onSubmit(submit)
                HStack {
                    Button("Choose a Picture…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) { readQR(image, into: f.key) }
                    }
                    Button("Paste Image") {
                        let count = NSPasteboard.general.changeCount
                        if let image = NSImage(pasteboard: .general) { readQR(image, into: f.key, changeCount: count) }
                    }
                }
            }.onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                guard let item = providers.first else { return false }
                let type = item.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL.identifier : UTType.image.identifier
                _ = item.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        let image: NSImage?
                        if type == UTType.fileURL.identifier, let url = URL(dataRepresentation: data, relativeTo: nil) { image = NSImage(contentsOf: url) }
                        else { image = NSImage(data: data) }
                        if let image { readQR(image, into: f.key) }
                    }
                }
                return true
            }
        } else if f.secret {
            SecretField(f.label, text: text, prompt: prompt).onSubmit(submit)
        } else {
            TextField(f.label, text: text, prompt: prompt).onSubmit(submit)
        }
    }

    private func readQR(_ image: NSImage, into key: String, changeCount: Int? = nil) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let value = QR.decode(cg) else {
            model.formError[provider.id] = "No QR code found in the picture"
            return
        }
        values[key] = value
        pastedQR = changeCount.map { (key, value, $0) }
        model.formError[provider.id] = nil
    }

    private func submit() {
        guard ready, !busy else { return }
        let input = values
        if let key = model.challenges[provider.id]?.field.key { values[key] = nil }
        let formVersion = model.providerFormVersion(provider.id)
        let count = pastedQR.flatMap { input[$0.key] == $0.value ? $0.changeCount : nil }
        Task { await model.signIn(provider, input, formVersion: formVersion, clipboardImageChangeCount: count) }
    }
}

/// A warning with a Dismiss, for `model.notice`.
struct NoticeRow: View {
    private let model = AppModel.shared
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Ink.failedText)
            Spacer()
            Button("Dismiss") { model.notice = nil }
        }
    }
}

struct UnsavedRow: View {
    private let model = AppModel.shared
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Changes couldn't be saved and would be lost when unbraid restarts.", systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(Ink.failedText)
            Spacer()
            Button("Retry Save") { model.store.retrySave() }
            Button("Dismiss") { model.store.unsavedDismissed = true }
        }
    }
}
