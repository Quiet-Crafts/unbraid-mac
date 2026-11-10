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

/// Copies the report for support: nothing leaves the Mac unless the user pastes it somewhere.
struct CopyDiagnosticsButton: View {
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy Diagnostics") {
            Task {
                let text = await DiagnosticsReport.collect().text(now: .now, names: DiagnosticsReport.providerName)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
        .help("Copies versions, the connection's state and what last failed, with keys, addresses, host names and your setup's own values masked, to paste into a message to support. Read it before you send it.")
    }
}
