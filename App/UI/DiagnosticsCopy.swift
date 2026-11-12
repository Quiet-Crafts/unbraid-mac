import AppKit
import SwiftUI

// Settings › About › Copy Diagnostics: gathers the report (versions, the extension's state, the setup's shape, and
// the last failure, stop and refusal) and puts it on the clipboard, masked by DiagnosticsReport (App/Core).

extension DiagnosticsReport {
    /// The report as things stand: asks the extension whether this build's copy answers (3 s at most).
    static func collect() async -> DiagnosticsReport {
        let m = AppModel.shared
        let s = m.setup, t = m.vpn.tunnel
        let info = Bundle.main.infoDictionary
        var providers: [String] = []
        var imported = 0
        for r in s.activeRoutes {
            if r.tsExit != nil { providers.append("tailscale") } else if r.imported { imported += 1 } else { providers.append(r.loc.provider) }
        }
        let ext: String = switch t.ext {
        case .unknown: "unknown"
        case .installing: "installing"
        case .needsApproval: "needs approval"
        case .needsRestart: "needs restart"
        case .ready: "ready"
        case .failed: "failed"
        }
        // The extension's XPC service is named after its build, so an answer means this build's extension runs.
        let answers = await EngineLink.call(timeout: 3) { $0.revisions(reply: $1) } != nil
        let home = [s.home.tailscale ? "Tailscale" : nil, s.home.wg != nil ? "WireGuard" : nil].compactMap { $0 }.joined(separator: " & ")
        return DiagnosticsReport(
            app: "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
            system: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            extensionState: ext, extensionAnswers: answers, phase: m.vpn.state.phase.rawValue,
            killSwitch: s.prefs.killSwitch, killSwitchApplied: t.profile?.killSwitch,
            onDemand: s.prefs.alwaysOn, onDemandApplied: t.profile?.onDemand, onDemandUnavailable: t.onDemandUnavailable,
            providers: providers, imported: imported, home: home.isEmpty ? nil : home,
            runningDiffers: m.vpn.running.map { $0 != s },
            failure: Diagnostics.lastFailure, stop: Diagnostics.lastStop, rejection: Diagnostics.lastRejection)
    }

    static func providerName(_ id: String) -> String? { id == "tailscale" ? "Tailscale exit node" : Providers.get(id)?.name }
}

/// Shows the report, then copies it on request: nothing leaves the Mac unless the user pastes it somewhere.
struct CopyDiagnosticsButton: View {
    @State private var copied = false
    @State private var report: String?
    /// Counts clicks of Copy, so an earlier "Copied" timer never clears a later one.
    @State private var copies = 0

    var body: some View {
        Button(copied ? "Copied" : "Copy Diagnostics…") {
            Task { report = await DiagnosticsReport.collect().text(now: .now, names: DiagnosticsReport.providerName) }
        }
        .help("Shows what would be copied: versions, the connection's state and what last failed, for a message to support.")
        .sheet(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            if let report {
                SheetFrame(title: "Copy Diagnostics", subtitle: "Keys, addresses, host names and your setup's own values are hidden. It lists your app and macOS versions, your providers' names and what last failed.") {
                    ScrollView {
                        Text(report).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(Layout.gutter)
                    }
                    .frame(height: 320).background(Ink.surface)
                } actions: {
                    Button("Cancel", role: .cancel) { self.report = nil }.keyboardShortcut(.cancelAction).contentButton()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                        self.report = nil
                        copies += 1
                        let mine = copies
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            if copies == mine { copied = false }
                        }
                    }.keyboardShortcut(.defaultAction).contentButton(prominent: true)
                }
                .font(.system(size: 13))
            }
        }
    }
}
