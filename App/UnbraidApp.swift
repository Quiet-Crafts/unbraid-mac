import ServiceManagement
import SwiftUI
import WidgetKit

// The app's entry point: its scenes (the main window, the menu bar extra, Settings) and menu commands, and the app
// delegate that installs the tunnel extension, shows the window when needed, quits cleanly, asks once about opening
// at login, and acts on widget and Control Center requests.

@main
struct UnbraidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// Nil in a copy that will only say it must be moved to Applications: it never reads the saved setup or sets up the
    /// connection, and its scenes stay empty.
    @State private var model: AppModel?

    init() {
        // Before the saved setup is loaded: a second copy must not read it, let alone write it.
        #if !DEBUG
        SingleCopy.handOverIfRunning()
        #endif
        _model = State(wrappedValue: SingleCopy.outsideApplications ? nil : AppModel.shared)
    }

    var body: some Scene {
        Window("unbraid", id: "main") {
            if let model { RootView().environment(model) }
        }
        .defaultSize(width: 1040, height: 700)
        .windowToolbarStyle(.unified)
        .commands { if let model { UnbraidCommands(model: model) } }

        MenuBarExtra(isInserted: .constant(model != nil)) {
            if let model { MenuBarPanel().environment(model) }
        } label: {
            if model != nil { MenuBarIcon() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let model { SettingsView().environment(model) }
        }
        .windowToolbarStyle(.unifiedCompact)
    }
}

/// One unbraid at a time: two would overwrite each other's saved setup and accounts, count every statistic twice and
/// both steer the one tunnel. A copy that finds another one with the better claim (see `InstallPlace.outranks`) asks it
/// to show its window and quits.
enum SingleCopy {
    static func handOverIfRunning() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        let mine = InstallPlace.Copy(path: Bundle.main.bundleURL.path, launched: me.launchDate, pid: me.processIdentifier)
        let winner = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { other in
            !other.isTerminated && InstallPlace.outranks(InstallPlace.Copy(path: other.bundleURL?.path ?? "", launched: other.launchDate, pid: other.processIdentifier), mine)
        }
        guard let winner else { return }
        // Opening the running copy by its own path reopens its window; no second copy starts.
        if let url = winner.bundleURL {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [url.path]
            if (try? open.run()) == nil { winner.activate() }
        } else {
            winner.activate()
        }
        exit(0)
    }

    /// Whether this copy runs from somewhere macOS can't install the VPN extension for (a disk image, Downloads). Debug
    /// builds run from the build folder, so they never count.
    static var outsideApplications: Bool {
        #if DEBUG
        return false
        #else
        return !InstallPlace.isInApplications(Bundle.main.bundleURL.path)
        #endif
    }

    /// A copy that macOS can't install the VPN extension for: said plainly, then it quits. The alert runs once the app
    /// has finished launching (a modal alert can't run earlier); the copy has already skipped loading anything.
    @MainActor static func refuseOutsideApplications() -> Bool {
        #if DEBUG
        return false
        #else
        guard outsideApplications else { return false }
        let alert = NSAlert()
        alert.messageText = "unbraid needs to be in your Applications folder"
        alert.informativeText = "Move unbraid to the Applications folder, then open it from there."
        alert.addButton(withTitle: "Quit")
        NSApp.activate()
        alert.runModal()
        return true
        #endif
    }
}

/// The menu bar glyph: the logo, with a small mark for paused and off so the state reads at a glance.
/// It lives as long as the app, so it also hands the app delegate SwiftUI's way to open the main window.
struct MenuBarIcon: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// Read here, not in the scene: a scene that reads the connection redraws the status item at every change of it.
    var body: some View {
        let state = Connection.shared.state
        let phase = state.phase
        let protection = state.runState.protection(blocked: Set(state.blocked.keys))
        Image(phase == .on ? "MenuBarOn" : phase == .paused ? "MenuBarPaused" : "MenuBarOff")
            .accessibilityLabel(phase == .on ? "unbraid, \(protection.map { $0 ? "protected" : "connected" } ?? "connected")" : phase == .paused ? "unbraid, paused" : "unbraid, not connected")
            .task {
                AppDelegate.openWindow = { openWindow(id: "main") }
                AppDelegate.openSettings = { openSettings() }
            }
    }
}

struct UnbraidCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.sceneActions) private var actions
    @FocusedValue(\.goTo) private var goTo

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open unbraid") { NSApp.setActivationPolicy(.regular); openWindow(id: "main"); NSApp.activate() }.keyboardShortcut("o")
            // From any page of the window: the route picker belongs to the window, not to a page.
            Button("New Route…") { Presentation.shared.picker = PickerTarget(id: "") }.keyboardShortcut("n").disabled(goTo == nil)
            Button("Add App…") { actions?.addApp?() }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(actions?.addApp == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { actions?.find?() }.keyboardShortcut("f").disabled(actions?.find == nil)
        }
        CommandGroup(after: .toolbar) {
            Section {
                Button("All Apps") { goTo?(.apps(nil)) }.keyboardShortcut("1")
                Button("Traffic") { goTo?(.traffic) }.keyboardShortcut("2")
                Button("Activity") { goTo?(.activity) }.keyboardShortcut("3")
                Button("Speed Test") { goTo?(.speed) }.keyboardShortcut("4")
            }.disabled(goTo == nil)
            Menu("Appearance") { AppearanceItems() }
            Menu("Period") {
                Picker("Period", selection: actions?.period ?? .constant(.week)) {
                    ForEach(Period.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }.disabled(actions?.period == nil)
            Button("History") { actions?.showHistory?() }.keyboardShortcut("y").disabled(actions?.showHistory == nil)
            Button("Turn On Statistics…") { actions?.recordStatistics?() }.disabled(actions?.recordStatistics == nil)
        }
        // Moving the selected apps, from any page that lists them: ⌥⌘ and the route's place in the sidebar.
        CommandMenu("Apps") {
            Menu("Move To") { MoveItems { actions?.move?($0) } }.disabled(actions?.move == nil)
        }
        CommandMenu("Connection") {
            Menu("Switch Profile") {
                ForEach(Array(model.setup.profiles.prefix(3).enumerated()), id: \.element.name) { index, profile in
                    Button(profile.name) { model.switchProfile(profile.name) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.control, .command])
                }
            }

            Button(model.vpn.state.phase == .off ? "Connect" : model.vpn.state.phase == .paused ? "Resume" : "Disconnect") {
                model.vpn.state.phase == .on || model.vpn.state.phase == .connecting ? model.disconnect() : model.connect()
            }.keyboardShortcut("k")
            if model.vpn.state.phase == .paused {
                Button("Disconnect") { model.disconnect() }
            }
            Button("Pause for 15 Minutes") { model.pause(15) }
                .keyboardShortcut("k", modifiers: [.command, .shift]).disabled(model.vpn.state.phase != .on)
            Menu("Pause") {
                ForEach([5, 15, 60], id: \.self) { m in Button(m == 60 ? "1 Hour" : "\(m) Minutes") { model.pause(m) } }
                Button("Until Resumed") { model.pause(0) }
            }.disabled(model.vpn.state.phase != .on)
        }
        // There is no Help book: Help opens the website.
        CommandGroup(replacing: .help) {
            Button("Show Tour") { Presentation.shared.startTour() }.disabled(!model.signedIn)
            Divider()
            SwiftUI.Link("unbraid Website", destination: URL(string: Site.home)!)
            SwiftUI.Link("Guides", destination: URL(string: Site.guides)!)
            SwiftUI.Link("Contact", destination: URL(string: Site.contact)!)
            Divider()
            // One check the user asked for, whatever the setting: its result shows in Settings › About.
            Button("Check for Updates…") {
                Presentation.shared.settingsTab = 4
                AppDelegate.openSettingsWindow()
                Task { await Updates.shared.checkNow() }
            }
            Divider()
            SwiftUI.Link("Privacy Policy", destination: URL(string: Site.privacy)!)
        }
    }
}

struct SceneActions {
    var addApp: (() -> Void)?
    var find: (() -> Void)?
    /// Moves the selected apps to a route (nil = follow the default).
    var move: ((String?) -> Void)?
    var period: Binding<Period>?
    var showHistory: (() -> Void)?
    var recordStatistics: (() -> Void)?
}

private struct SceneActionsKey: FocusedValueKey { typealias Value = SceneActions }
extension FocusedValues {
    var sceneActions: SceneActions? {
        get { self[SceneActionsKey.self] }
        set { self[SceneActionsKey.self] = newValue }
    }
}

/// Launch at login, the tunnel extension, widget actions, and the Dock icon only while the window is open.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the menu bar icon once SwiftUI is up.
    static var openWindow: (() -> Void)?
    static var openSettings: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.current.apply()
        #if DEBUG
        if PerfHost.active { PerfHost.start(); return }
        #endif
        // Left at once, not through the normal quit: that would also resume a pause the copy in Applications holds.
        if SingleCopy.refuseOutsideApplications() { exit(0) }
        Connection.shared.tunnel.installExtension()
        Task { await Connection.shared.restorePause() }
        LoginItem.shared.watch()
        let widgetRequest = WidgetActions.listen()
        Stats.shared.follow()
        #if DEBUG
        DebugHooks.install()
        #endif
        // The widgets' week: bytes per day and route, only while statistics are on.
        Snapshot.weekSource = {
            guard Store.shared.setup.prefs.stats else { return [] }
            return await Stats.shared.week()
        }
        Snapshot.startPublishing()
        // Only while the user has turned it on, at most once a day.
        Updates.shared.start()
        // Show the window on a first launch (nothing set up yet) or when opened by hand rather than at login.
        let atLogin = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        // Started to act on a widget, Control or Shortcut request: it runs without taking the screen, unless there is
        // nothing set up yet or a question waits in the window.
        let model = AppModel.shared
        if (!atLogin && !widgetRequest) || !model.signedIn || model.disclosure { Task { try? await Task.sleep(for: .milliseconds(200)); Self.openMain() } }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // The Dock icon goes with the last regular window: unbraid lives on in the menu bar. A minimized window
            // still counts, since the Dock is how it comes back.
            DispatchQueue.main.async {
                if !NSApp.windows.contains(where: { $0.isMiniaturized || $0.isVisible && $0.canBecomeMain }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.openMain() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Before anything awaits: the widgets' snapshot is no longer vouched for (their reload request then has the
        // whole quit to go out), nothing freshens it again, and no widget request is acted on from here on.
        Snapshot.retire()
        WidgetActions.stop()
        Task {
            // A sign-out still waiting for the VPN to stop finishes first, bounded.
            _ = await bounded(10) { await AppModel.shared.settleSignOuts() }
            // A Tailscale speed test leaves the routed apps on its test node until put back: bounded, the rest is done at
            // the next launch.
            await SpeedTest.shared.settle(within: .seconds(4))
            await Connection.shared.resumeBeforeQuit()
            // The open session up to now and the sums not yet written, bounded: a stuck write never holds up the quit.
            _ = await bounded(2) { await Stats.shared.close() }
            // An owed drop the disk didn't take yet is tried once more, so the next launch still makes it.
            Running.retryOwed()
            // Saves still queued (setup, accounts, records), bounded too: a write stuck on a stalled disk can't hold up the quit.
            _ = await bounded(10) { await FileWork.shared.drain() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// unbraid:// only opens the window: a link in a web page must never change the protection state.
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "unbraid" }) { Self.openMain() }
    }

    /// Settings, with the Dock icon and the app menu a window needs: from the menu bar panel the app may be an accessory.
    static func openSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        openSettings?()
    }

    /// Static, and not reached through NSApp.delegate: that is SwiftUI's own delegate, which only forwards to this one,
    /// so a cast of it to AppDelegate is always nil.
    static func openMain() {
        NSApp.setActivationPolicy(.regular)
        openWindow?()
        NSApp.activate()
    }
}

/// Open at login is asked once, after the first connection works, instead of being registered unasked at the first
/// launch: someone who only tries unbraid shouldn't find it at every login. Settings › General has the switch.
@Observable
final class LoginItem {
    static let shared = LoginItem()
    /// Ask now: the window shows the question when it is open, and keeps it until it is answered.
    private(set) var offer = false
    private static let key = "loginItemOffered"
    private var handled: Bool { UserDefaults.standard.bool(forKey: Self.key) }

    /// Follows the connection until the question has been asked and answered (or the switch was used in Settings).
    func watch() {
        guard !handled else { offer = false; return }
        let phase = withObservationTracking { Connection.shared.state.phase } onChange: {
            Task { @MainActor in LoginItem.shared.watch() }
        }
        if phase == .on, SMAppService.mainApp.status == .notRegistered { offer = true }
    }

    /// The answer, or a choice made in Settings: never asked again.
    func answer(_ open: Bool) {
        UserDefaults.standard.set(true, forKey: Self.key)
        offer = false
        guard open else { return }
        do {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
                AppModel.shared.notice = "To open unbraid at login, allow it in System Settings › General › Login Items."
            }
        } catch {
            AppModel.shared.notice = "unbraid couldn't add itself to your login items: \(error.localizedDescription) Try again in Settings › General."
        }
    }

    func settingsChanged() { UserDefaults.standard.set(true, forKey: Self.key); offer = false }
}

/// The widget's buttons: the request is a file in the app-group container (macOS keeps other apps out of it) and a
/// Darwin notification only wakes the app to read it, so posting the notification alone changes nothing. When macOS
/// runs a button in the app (launching it if needed, see ConnectIntent), the request is written here too and read at
/// once or at launch (if still fresh, see `take`).
enum WidgetActions {
    /// A Pause waiting for the running tunnel to be taken over after a launch.
    private static var waiting: Task<Void, Never>?
    /// Quitting: requests are left alone (a pause started now would outlive the app that resumes it).
    private static var stopped = false
    private static var lastProfileSwitch: (action: String, at: ContinuousClock.Instant)?

    /// True when the launch itself took a request (the app was started to act on it).
    @discardableResult
    static func listen() -> Bool {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task { @MainActor in WidgetActions.handle() }
        }, WidgetAction.note as CFString, nil, .deliverImmediately)
        return handle(atLaunch: true)
    }

    /// Both ways in, one at a time: the launch and the notification can't both act on one request. True if there was one.
    @discardableResult
    private static func handle(atLaunch: Bool = false) -> Bool {
        guard !stopped, let action = WidgetAction.take() else { return false }
        waiting?.cancel()
        waiting = nil
        switch action {
        case "connect": AppModel.shared.connect()
        case "pause":
            // Only a tunnel that is on pauses; at launch it is taken over a moment later, so wait for that, briefly.
            // Pause never connects.
            waiting = Task {
                let deadline = ContinuousClock.now + .seconds(15)
                while Connection.shared.state.phase != .on, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(500))
                    if Task.isCancelled { return }
                }
                guard !Task.isCancelled, !stopped, Connection.shared.state.phase == .on else { return }
                AppModel.shared.pause(15)
            }
        default:
            // The profile in use pauses a running tunnel and connects an off one. At launch a running tunnel is taken
            // over a moment later: until then it reads as off, so the request waits a little for it.
            let model = AppModel.shared
            if atLaunch, WidgetAction.profileRequest(action)?.name == model.setup.profile, WidgetActions.unsettled() {
                waiting = Task {
                    let deadline = ContinuousClock.now + .seconds(6)
                    while unsettled(), ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(250))
                        if Task.isCancelled { return }
                    }
                    guard !Task.isCancelled, !stopped else { return }
                    profileRequest(action)
                }
            } else {
                profileRequest(action)
            }
        }
        return true
    }

    /// Off or connecting: a running tunnel taken over after launch passes through both before it reads as on.
    private static func unsettled() -> Bool { [.off, .connecting].contains(Connection.shared.state.phase) }

    private static func profileRequest(_ action: String) {
        let model = AppModel.shared
        switch WidgetAction.profileDecision(action, generation: model.profileGeneration, names: model.setup.profiles.map(\.name), current: model.setup.profile, connected: model.vpn.state.phase == .on,
            lastSwitch: lastProfileSwitch.flatMap { ContinuousClock.now - $0.at < .seconds(2) ? $0.action : nil }) {
        case .reject: break
        case .pause: model.pause(15)
        case .connect: model.connect()
        case .switchTo(let name):
            lastProfileSwitch = (action, .now)
            model.switchProfile(name, connectIfOff: true, offeredGeneration: model.profileGeneration)
        }
    }

    /// Quitting: a Pause still waiting is dropped, and later requests are not read.
    static func stop() { stopped = true; waiting?.cancel(); waiting = nil }
}
