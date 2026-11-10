import SwiftUI
import UniformTypeIdentifiers

/// The text of a config file the user picked, or why it can't be used (see `ConfigFile.read`).
func readConfig(_ url: URL) -> Result<String, Fail> {
    do { return .success(try ConfigFile.read(url)) } catch { return .failure(error as? Fail ?? Fail("Couldn't read that file.")) }
}

/// Imports a WireGuard or OpenVPN file or a Shadowsocks link as a saved server. State lives here, in memory only: the
/// prompts hold keys and passwords. Attach it to a screen with `.importFlow(_:target:done:)`.
@Observable
final class Importer {
    enum Kind { case any, wg, ovpn }
    /// The prompt waiting for input. Identified by kind only, so typing never re-presents the sheet.
    enum Prompt: Identifiable {
        case wg(String), ovpn(String), ss
        var id: String { switch self { case .wg: "wg"; case .ovpn: "ovpn"; case .ss: "ss" } }
    }

    /// .data admits any file; the named types only help the panel when the system knows them.
    static let types = [UTType.data] + ["conf", "ovpn"].compactMap { UTType(filenameExtension: $0) }

    var picking = false
    var prompt: Prompt?
    var name = ""
    var user = ""
    var pass = ""
    var link = ""
    /// Why the last file was refused (shown by the screen that opened the picker) and why the open prompt failed.
    var error: String?
    var promptError: String?
    private var confirmation = Manual.WarningConfirmation()
    private var kind = Kind.any
    private var prefix: String?

    /// Opens the file picker. `prefix` names the server "<prefix> · <file>" (provider guides).
    func file(_ kind: Kind = .any, prefix: String? = nil) {
        error = nil
        self.kind = kind
        self.prefix = prefix
        picking = true
    }

    func shadowsocks() { error = nil; clear(); prompt = .ss }

    func clear() { prompt = nil; name = ""; user = ""; pass = ""; link = ""; promptError = nil; confirmation.clear() }

    func picked(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let read = readConfig(url)
        guard case .success(let text) = read else { if case .failure(let f) = read { error = f.errorDescription }; return }
        let file = String(url.deletingPathExtension().lastPathComponent.prefix(40))
        let base = file.trimmingCharacters(in: .whitespaces).isEmpty ? "Imported" : file
        let named = prefix.map { "\($0) · \(base)" } ?? base
        clear()
        name = named
        // A broken config fails here, before the user is asked to name it.
        do {
            if kind == .wg || (kind == .any && WgConf.hasInterface(text)) {
                try WgConf.requireFullTunnel(try WgConf.parse(text, name: named))
                prompt = .wg(text)
            } else {
                // Placeholder login: everything but the login is checked before the prompt asks for one.
                _ = try Manual.parseOvpn(text, name: named, username: "check", password: "check")
                prompt = .ovpn(text)
            }
        } catch {
            clear()
            self.error = Self.why(error)
        }
    }

    /// Saves what the open prompt holds. True when done; otherwise `promptError` says why and the typed text stays.
    func commit(_ model: AppModel, target: String?) -> Bool {
        guard let prompt else { return false }
        func named(_ fallback: String) -> String {
            let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            return n.isEmpty ? fallback : n
        }
        do {
            let server: OwnServer
            let secrets: [String]
            let weakness: String?
            switch prompt {
            case .wg(let text):
                server = OwnServer(id: "", wg: try WgConf.parse(text, name: named("WireGuard")))
                secrets = [text]
                weakness = nil
            case .ovpn(let text):
                let login = user.trimmingCharacters(in: .whitespacesAndNewlines)
                let profile = try Manual.parseOvpn(text, name: named("OpenVPN"), username: login, password: pass)
                server = OwnServer(id: "", ovpn: profile)
                weakness = try Manual.weakness(profile)
                secrets = [text, pass]
            case .ss:
                var p = try Manual.parseSs(link.trimmingCharacters(in: .whitespacesAndNewlines))
                p.name = named(p.name.isEmpty ? p.server : p.name)
                server = OwnServer(id: "", ss: p)
                secrets = [link]
                weakness = Manual.weakness(p)
            }
            if !confirmation.allows(weakness), let weakness {
                promptError = "Weak security: \(weakness) Import anyway?"
                return false
            }
            model.importServer(target, server, secrets: secrets)
            clear()
            return true
        } catch {
            promptError = Self.why(error)
            return false
        }
    }

    func resetWarning() { confirmation.clear() }

    var importTitle: String { confirmation.warning == nil ? "Import" : "Import Anyway" }

    /// Parser messages are written to be shown; anything else gets a fixed line so no input is echoed.
    static func why(_ error: Error) -> String { (error as? Fail)?.errorDescription ?? "Couldn't read that config" }
}

extension View {
    /// File picker and input prompts for `importer`. `target`: nil saves the server only, "" also makes it a new route.
    func importFlow(_ importer: Importer, target: String?, done: @escaping () -> Void = {}) -> some View {
        modifier(ImportFlow(importer: importer, target: target, done: done))
    }
}

private struct ImportFlow: ViewModifier {
    private let model = AppModel.shared
    @Bindable var importer: Importer
    let target: String?
    let done: () -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $importer.picking, allowedContentTypes: Importer.types) { importer.picked($0) }
            .sheet(item: $importer.prompt, onDismiss: importer.clear) { prompt in
                ImportPrompt(importer: importer, prompt: prompt) {
                    if importer.commit(model, target: target) { done() }
                }
            }
    }
}

/// "Name this server", the OpenVPN login, or the Shadowsocks link.
private struct ImportPrompt: View {
    @Bindable var importer: Importer
    let prompt: Importer.Prompt
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FormSheet(title: title) {
            switch prompt {
            case .wg:
                Section {
                    TextField("Name", text: $importer.name, prompt: Text("e.g. Home VPS"))
                } footer: { Text("Shown on your routes and in Apps. You can rename it later.") }
            case .ovpn:
                Section {
                    TextField("Name", text: $importer.name, prompt: Text("e.g. Office"))
                }
                Section {
                    TextField("Username", text: $importer.user)
                    SecretField("Password", text: $importer.pass)
                } footer: { Text("Leave the login empty if the config has its own.") }
            case .ss:
                Section {
                    SecretField("Link", text: $importer.link, prompt: Text("ss://…"))
                    TextField("Name (optional)", text: $importer.name, prompt: Text("e.g. Outline"))
                }
            }
            if let e = importer.promptError {
                Section { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Ink.failedText) }
            }
        } actions: {
            Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(importer.importTitle, action: save).keyboardShortcut(.defaultAction)
                .contentButton(prominent: true)
                .disabled(prompt.isLink && importer.link.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        // A new attempt starts clean: the old error no longer describes what is typed.
        .background(CaptureExclusion())
        .onChange(of: importer.name + importer.user + importer.pass + importer.link) { importer.promptError = nil; importer.resetWarning() }
    }

    private var title: String {
        switch prompt {
        case .wg: "WireGuard Server"
        case .ovpn: "OpenVPN Server"
        case .ss: "Shadowsocks Link"
        }
    }
}

private extension Importer.Prompt {
    var isLink: Bool { if case .ss = self { true } else { false } }
}
