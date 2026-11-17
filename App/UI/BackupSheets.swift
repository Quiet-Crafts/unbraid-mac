import SwiftUI
import UniformTypeIdentifiers

// Back Up Settings and Restore Settings: the flow that every way in shares (Settings › General, the File menu, the
// sign-in page, a backup picked where a config is imported, a backup file opened in the Finder), and its three sheets.

extension UTType {
    /// Declared in the app's Info.plist, so the Finder opens these files with unbraid.
    static let unbraidBackup = UTType(exportedAs: "app.unbraid.backup", conformingTo: .data)
}

/// Which backup sheet is up, in which window, and the file being restored. The chosen file and the opened backup are
/// held only while a sheet is up and dropped when it closes; the passphrase lives in the sheets' own state.
@Observable
final class BackupFlow {
    static let shared = BackupFlow()
    enum Step: Equatable { case save, passphrase, restore }

    private(set) var step: Step?
    /// The window the sheet shows in; nil: the main window, whenever it appears.
    private(set) var host: ObjectIdentifier?
    private(set) var fileName = ""
    /// The backup opened and checked whole: this Mac's setup hasn't changed yet.
    private(set) var content: Backup.Content?
    /// The sealed file (not secret, cleared anyway).
    @ObservationIgnored private(set) var file = Data()
    /// Moves on whenever the flow closes, so an answer that comes back for a sheet already gone is dropped.
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private var windows: [ObjectIdentifier: (window: Weak, main: Bool)] = [:]
    private struct Weak { weak var window: NSWindow? }
    #if DEBUG
    /// The test copy's pictures: what the save sheet's fields start with.
    @ObservationIgnored var perfPassphrase: String?
    #endif

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    /// A window that can show the sheets (see `backupSheets`).
    func register(_ w: NSWindow, main: Bool) {
        windows = windows.filter { $0.value.window.window != nil }
        windows[ObjectIdentifier(w)] = (Weak(window: w), main)
    }

    /// Nothing may change the setup while it is a stand-in, nor before the terms are accepted.
    private var refusal: String? {
        if AppModel.shared.store.setupStandIn { return BackupTexts.refusedForStandIn }
        if AppModel.shared.disclosure { return BackupTexts.refusedForTerms }
        return nil
    }

    /// Said where the user looks next: the notice that Settings, the window and the sign-in page show.
    static func notice(_ text: String) {
        let model = AppModel.shared
        model.notice = [model.notice, text].compactMap { $0 }.joined(separator: "\n")
    }

    func startSave() {
        if AppModel.shared.store.setupStandIn { Self.notice(BackupTexts.refusedForStandIn); return }
        _ = begin(.save, refuse: Self.notice)
    }

    /// The open panel for backups, then the restore flow.
    func chooseFile(refuse: @escaping @MainActor (String) -> Void = BackupFlow.notice) {
        if let why = refusal { refuse(why); return }
        let panel = NSOpenPanel()
        // Android's backups too (a file of an older registration may not know that type): the restore says why it can't
        // take them, which a greyed-out file never could.
        panel.allowedContentTypes = [.unbraidBackup] + [UTType(filenameExtension: BackupFile.androidExtension, conformingTo: .data)].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, refuse: refuse)
    }

    /// The restore flow for a file already chosen: it asks for the passphrase next. A file that is too large or isn't a
    /// backup is refused before its passphrase is asked for.
    func open(_ url: URL, refuse: @escaping @MainActor (String) -> Void = BackupFlow.notice) {
        if let why = refusal { refuse(why); return }
        let data: Data
        do { data = try BackupFile.readChosen(url) } catch {
            refuse((error as? BackupFile.Failure).map(BackupTexts.openFailure) ?? BackupTexts.unreadable); return
        }
        guard begin(.passphrase, refuse: refuse) else { return }
        file = data
        fileName = url.lastPathComponent
    }

    /// Opened with the right passphrase: on to the restore sheet, unless the flow was left meanwhile.
    func opened(_ c: Backup.Content, generation g: Int) {
        guard g == generation, step == .passphrase else { return }
        content = c
        step = .restore
    }

    func close() {
        file.withUnsafeMutableBytes { if let p = $0.baseAddress { _ = memset_s(p, $0.count, 0, $0.count) } }
        (step, host, content, file, fileName) = (nil, nil, nil, Data(), "")
        generation += 1
    }

    /// Shows `step` in the key window when it can show a sheet now, else in the main window. Refused while another sheet
    /// is up where it would go, or another backup sheet is open.
    private func begin(_ next: Step, refuse: (String) -> Void) -> Bool {
        guard step == nil else { refuse(BackupTexts.refusedBusy); return false }
        windows = windows.filter { $0.value.window.window != nil }
        if let key = NSApp.keyWindow, windows[ObjectIdentifier(key)] != nil, key.attachedSheet == nil {
            host = ObjectIdentifier(key)
        } else if let main = windows.values.first(where: \.main)?.window.window, main.isVisible {
            guard main.attachedSheet == nil else { refuse(BackupTexts.refusedBusy); return false }
            host = ObjectIdentifier(main)
            AppDelegate.openMain()
        } else {
            host = nil
            AppDelegate.openMain()
        }
        step = next
        return true
    }

    #if DEBUG
    /// The test copy's pictures: a sheet in `window` with made-up contents.
    func perfShow(_ next: Step?, in window: NSWindow, fileName name: String = "", content c: Backup.Content? = nil) {
        close()
        guard let next else { return }
        register(window, main: false)
        (host, fileName, content, step) = (ObjectIdentifier(window), name, c, next)
    }
    #endif
}

extension View {
    /// Shows the backup sheets in this view's window when the flow was started there; with `main`, also when it was
    /// started where no window could show them (the File menu with no window open, a file opened in the Finder).
    func backupSheets(main: Bool = false) -> some View { modifier(BackupSheets(main: main)) }
}

private struct BackupSheets: ViewModifier {
    let main: Bool
    @State private var window: ObjectIdentifier?

    func body(content: Content) -> some View {
        let flow = BackupFlow.shared
        content
            .background(WindowProbe { w in
                window = ObjectIdentifier(w)
                flow.register(w, main: main)
            })
            .sheet(isPresented: Binding(get: { flow.step != nil && (flow.host.map { $0 == window } ?? main) }, set: { if !$0 { flow.close() } })) {
                BackupSheet()
            }
    }
}

/// Reports the window it lands in.
private struct WindowProbe: NSViewRepresentable {
    let found: (NSWindow) -> Void
    func makeNSView(context: Context) -> Probe { Probe(found: found) }
    func updateNSView(_ view: Probe, context: Context) { view.found = found }

    final class Probe: NSView {
        var found: (NSWindow) -> Void
        init(found: @escaping (NSWindow) -> Void) { self.found = found; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Not during the view update that placed it.
            if let window { DispatchQueue.main.async { [found] in found(window) } }
        }
    }
}

/// One sheet for the whole flow: going from the passphrase to the restore sheet changes what it shows, without a sheet
/// closing and another opening. Kept out of window capture, as the sign-in and key sheets are.
private struct BackupSheet: View {
    var body: some View {
        let flow = BackupFlow.shared
        Group {
            switch flow.step {
            case .save: SaveSheet()
            case .passphrase: PassphraseSheet()
            case .restore: if let c = flow.content { RestoreSheet(content: c) }
            case nil: EmptyView()
            }
        }
        .background(CaptureExclusion())
    }
}

// MARK: - Back Up Settings

private struct SaveSheet: View {
    private let model = AppModel.shared
    private let flow = BackupFlow.shared
    @State private var passphrase = ""
    @State private var again = ""
    @State private var keys = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Bool

    var body: some View {
        let s = model.setup
        let check = BackupTexts.saveCheck(passphrase, again, keys: keys)
        SheetFrame(title: "Back Up Settings", subtitle: BackupTexts.saveFacts(s, keys: keys)) {
            VStack(alignment: .leading, spacing: 10) {
                PassField(label: "Passphrase", text: $passphrase).focused($focus)
                PassField(label: "Type it again", text: $again)
                StrengthLine(strength: passphrase.isEmpty ? nil : Backup.strength(passphrase))
                if let p = check.problem { ErrorLine(text: p) }
                if Backup.hasSecrets(s) {
                    SwitchCard(title: BackupTexts.keysTitle, caption: keys ? BackupTexts.keysOn : BackupTexts.keysOff, isOn: $keys).padding(.top, 6)
                }
                Text(BackupTexts.never).font(.system(size: 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                if let error { ErrorLine(text: error) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.gutter).padding(.bottom, 16)
            .disabled(busy)
        } status: {
            if busy { Working(text: "Locking the backup…") }
        } actions: {
            Button("Cancel") { flow.close() }.keyboardShortcut(.cancelAction).disabled(busy)
            Button("Save Backup…") { save() }.keyboardShortcut(.defaultAction).contentButton(prominent: true).disabled(!check.ready || busy)
        }
        .onAppear {
            focus = true
            #if DEBUG
            if let p = flow.perfPassphrase { passphrase = p; again = p }
            #endif
        }
        .onChange(of: passphrase + "\u{0}" + again) { error = nil }
        .onChange(of: keys) { error = nil }
        // Swift can't wipe a String's storage; dropping the only copies is what is left.
        .onDisappear { passphrase = ""; again = "" }
    }

    /// Asks where, and only then derives the key and writes, away from the main actor.
    private func save() {
        guard BackupTexts.saveCheck(passphrase, again, keys: keys).ready, !busy else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = BackupTexts.fileName(.now)
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.unbraidBackup]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        error = nil
        let (setup, keys, pass, app, generation) = (model.setup, keys, passphrase, BackupFlow.appVersion, flow.generation)
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try BackupFile.save(setup, app: app, keys: keys, passphrase: pass, to: url); return nil } catch { return BackupTexts.saveFailure(error) }
            }.value
            busy = false
            guard flow.generation == generation else { return }
            if let failure { error = failure } else { flow.close(); BackupFlow.notice(BackupTexts.saved) }
        }
    }
}

/// A passphrase field under its label, as in the design: no prompt text, nothing remembered by the system.
private struct PassField: View {
    let label: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).overline().accessibilityHidden(true)
            SecureField(label, text: $text, prompt: Text("")).labelsHidden().textFieldStyle(.roundedBorder)
        }
    }
}

/// Three segments and the words; before anything is typed, only that a forgotten passphrase can't be recovered.
private struct StrengthLine: View {
    let strength: Backup.Strength?
    var body: some View {
        let lit = strength.map(BackupTexts.segments) ?? 0
        let tone = strength.map { s -> Color in switch s { case .easy: Ink.failedText; case .fair: Ink.warningText; case .hard: Ink.successText } } ?? Ink.off
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in Capsule().fill(i < lit ? tone : Ink.separator).frame(width: 22, height: 4) }
            }.alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }.accessibilityHidden(true)
            Text((strength.map { $0.text + " · " } ?? "") + BackupTexts.unrecoverable)
                .font(.system(size: 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A switch in a card, with its title and caption.
private struct SwitchCard: View {
    let title: String, caption: String
    @Binding var isOn: Bool
    var enabled = true
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(caption).font(.system(size: 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!enabled).accessibilityHint(caption)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.surface, in: .rect(cornerRadius: Corner.inner, style: .continuous))
    }
}

private struct Working: View {
    let text: String
    var body: some View { HStack(spacing: 6) { ProgressView().controlSize(.small); Text(text) }.accessibilityElement(children: .combine) }
}

// MARK: - The passphrase

private struct PassphraseSheet: View {
    private let flow = BackupFlow.shared
    @State private var passphrase = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Bool

    var body: some View {
        SheetFrame(title: "Open Backup", subtitle: flow.fileName) {
            VStack(alignment: .leading, spacing: 10) {
                PassField(label: "Passphrase", text: $passphrase).focused($focus).onSubmit(open)
                if let error { ErrorLine(text: error) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.gutter).padding(.bottom, 16)
            .disabled(busy)
        } status: {
            if busy { Working(text: "Opening…") }
        } actions: {
            Button("Cancel") { flow.close() }.keyboardShortcut(.cancelAction)
            Button("Open") { open() }.keyboardShortcut(.defaultAction).contentButton(prominent: true).disabled(passphrase.isEmpty || busy)
        }
        .onAppear { focus = true }
        .onChange(of: passphrase) { if !passphrase.isEmpty { error = nil } }
        .onDisappear { passphrase = "" }
    }

    private func open() {
        guard !passphrase.isEmpty, !busy else { return }
        let (file, pass, generation) = (flow.file, passphrase, flow.generation)
        busy = true
        error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Backup.unlock(file, passphrase: pass) }.value
            busy = false
            guard flow.generation == generation else { return }
            switch result {
            case .success(let c):
                passphrase = ""
                flow.opened(c, generation: generation)
            case .failure(let why):
                // Another try starts from an empty field, still focused.
                if why.wrongPassphrase { passphrase = ""; focus = true }
                error = why.message
            }
        }
    }
}

// MARK: - Restore Settings

private struct RestoreSheet: View {
    let content: Backup.Content
    private let model = AppModel.shared
    private let flow = BackupFlow.shared
    @State private var keep = true
    /// Weak servers in the backup were accepted, as the import asks for them.
    @State private var weakAccepted = false

    var body: some View {
        let current = model.setup
        let here = Backup.setUp(current)
        // Worked out again for every change, of the switch or of this Mac's setup meanwhile.
        let keeping = Backup.plan(onto: current, from: content, keepPrevious: true, now: .now)
        let canKeep = here && !keeping.unkept
        let plan = canKeep && keep ? keeping : Backup.plan(onto: current, from: content, keepPrevious: false, now: .now)
        let phase = model.vpn.state.phase
        let notes = BackupTexts.restoreNotes(plan, accounts: model.accounts, tunnelUp: phase == .on || phase == .paused)
        SheetFrame(title: "Restore Settings", subtitle: BackupTexts.restoreFacts(file: flow.fileName, content)) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("In this backup").overline()
                    Text(Backup.inBackup(content.summary)).fixedSize(horizontal: false, vertical: true)
                    Text("It replaces").overline().padding(.top, 4)
                    Text(Backup.replaces(plan.replaces)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.surface, in: .rect(cornerRadius: Corner.inner, style: .continuous))
                .accessibilityElement(children: .combine)
                if here {
                    SwitchCard(title: BackupTexts.keepTitle(keeping.keptAs), caption: canKeep ? BackupTexts.keepCaption : BackupTexts.keepUnavailable,
                               isOn: canKeep ? $keep : .constant(false), enabled: canKeep)
                }
                if !plan.weak.isEmpty {
                    SwitchCard(title: BackupTexts.weakTitle, caption: BackupTexts.weakCaption(plan.weak), isOn: $weakAccepted)
                }
                if !notes.isEmpty {
                    Label { Text(notes.joined(separator: " ")).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "info.circle").foregroundStyle(Ink.warningText)
                    }
                    .font(.system(size: 12)).foregroundStyle(Ink.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.gutter).padding(.bottom, 16)
        } actions: {
            Button("Cancel") { flow.close() }.keyboardShortcut(.cancelAction)
            Button("Restore") {
                model.restoreBackup(content, keepPrevious: canKeep && keep)
                flow.close()
            }.keyboardShortcut(.defaultAction).contentButton(prominent: true).disabled(!plan.weak.isEmpty && !weakAccepted)
        }
    }
}
