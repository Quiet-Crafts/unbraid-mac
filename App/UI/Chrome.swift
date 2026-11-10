import AppKit
import SwiftUI

/// The connection, pinned to the foot of the sidebar: same place and size on every page and in every state, so the
/// one control people use most never moves. Status above, one capsule button below.
struct ConnectionDock: View {
    private let model = AppModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The menu bar panel shows the state in its own header: there the dock is the button alone.
    var compact = false

    var body: some View {
        let v = model.vpn.state
        VStack(alignment: .leading, spacing: 10) {
            if !compact { status(v).font(.caption).lineLimit(1).frame(height: 16, alignment: .leading) }
            button(v).controlSize(.large).buttonBorderShape(.capsule).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, compact ? 0 : 16).padding(.vertical, compact ? 0 : 12)
        .frame(height: compact ? nil : 88)
        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: v.phase)
    }

    @ViewBuilder private func status(_ v: VpnState) -> some View {
        HStack(spacing: 6) {
            if let name = model.switchingProfile {
                ProgressView().controlSize(.mini)
                Text("Switching to \(name) · apps reconnect for a moment").foregroundStyle(.secondary).help("Switching to \(name) · apps reconnect for a moment")
            } else { switch v.phase {
            case .off where v.error != nil:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.failed)
                Text("Connection failed").foregroundStyle(.secondary).help("Connection failed")
            case .off:
                StatusDot(color: Ink.off)
                Text("VPN off").foregroundStyle(.secondary).help("VPN off")
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("Connecting routes…").foregroundStyle(.secondary).help("Connecting routes…")
            case .on:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.connected)
                // No running clock: a ticking timer costs a redraw a second and says little. The time it began is in help.
                let exits = Set(model.vpn.tags.values).count
                Text("\(v.runState.protection(blocked: Set(v.blocked.keys)).map { $0 ? "Protected" : "Connected" } ?? "Connected") · \(exits) VPN exit\(exits == 1 ? "" : "s")").foregroundStyle(.secondary)
                    .help("\(v.runState.protection(blocked: Set(v.blocked.keys)).map { $0 ? "Protected" : "Connected" } ?? "Connected") · \(exits) VPN exit\(exits == 1 ? "" : "s"). Connected since \(v.since.formatted(date: .omitted, time: .shortened))")
            case .paused:
                Image(systemName: "pause.circle.fill").foregroundStyle(Ink.paused)
                Text(v.pausedUntil.map { "Resumes at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Paused until resumed")
                    .foregroundStyle(.secondary).help(v.pausedUntil.map { "Resumes at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Paused until resumed")
            } }
        }
        .contentTransition(.opacity)
        .symbolEffect(.bounce, options: .nonRepeating, isActive: !reduceMotion && v.phase == .on)
    }

    @ViewBuilder private func button(_ v: VpnState) -> some View {
        switch v.phase {
        case .off:
            Button { model.connect() } label: { wide(v.error == nil ? "Connect" : "Try Again", v.error == nil ? "power" : "arrow.clockwise") }
                .modifier(DockButtonStyle(compact: compact, prominent: true)).keyboardShortcut("k")
        case .connecting:
            Button { model.disconnect() } label: { wide("Cancel", "xmark") }
                .modifier(DockButtonStyle(compact: compact)).help("Stop connecting")
        case .on:
            // A full-width button with its options beside it: the same width as Connect, so nothing jumps.
            GlassEffectContainer(spacing: 6) { HStack(spacing: 6) {
                Button { model.pause(15) } label: { wide("Pause", "pause.fill") }
                    .modifier(DockButtonStyle(compact: compact)).help("Pause for 15 minutes")
                options {
                    Section("Pause") {
                        Button("5 Minutes") { model.pause(5) }
                        Button("15 Minutes") { model.pause(15) }
                        Button("1 Hour") { model.pause(60) }
                        Button("Until Resumed") { model.pause(0) }
                    }
                    Divider()
                    Button("Disconnect", role: .destructive) { model.disconnect() }
                }
            } }
        case .paused:
            GlassEffectContainer(spacing: 6) { HStack(spacing: 6) {
                Button { model.connect() } label: { wide("Resume", "play.fill") }.modifier(DockButtonStyle(compact: compact, prominent: true))
                options { Button("Disconnect", role: .destructive) { model.disconnect() } }
            } }
        }
    }

    /// The chevron beside Pause and Resume: pause lengths and Disconnect.
    private func options(@ViewBuilder _ items: () -> some View) -> some View {
        GlassMenu(glass: !compact, chevron: false, circle: true, content: items) { Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)) }
            .accessibilityLabel("Connection Options")
    }

    /// Label stretched to the full width, so every state has the same geometry.
    private func wide(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
    }
}

private struct DockButtonStyle: ViewModifier {
    let compact: Bool
    var prominent = false
    @ViewBuilder func body(content: Content) -> some View {
        if compact { content.contentButton(prominent: prominent) }
        else if prominent { content.buttonStyle(.glassProminent).tint(Ink.accent).prominentForeground() }
        else { content.buttonStyle(.glass) }
    }
}

/// A route's mark: a circle with the country's flag (or a symbol for Direct, Block, own servers and Tailscale) and a
/// short tab in the route's colour, cut at the angle of the logo's slash.
struct RouteBadge: View {
    let route: Route?
    var id = ""
    var size: CGFloat = 28
    var dimmed = false

    var body: some View {
        ZStack {
            Circle().fill(.quaternary)
            content
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let c = route?.color {
                Capsule().fill(c).frame(width: size * 0.16, height: size * 0.42)
                    .rotationEffect(.degrees(22)).offset(x: size * 0.06, y: size * 0.04)
                    .shadow(color: .black.opacity(0.15), radius: 0.5)
            }
        }
        .saturation(dimmed ? 0.7 : 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        let symbol = Font.system(size: size * 0.46, weight: .medium)
        if let r = route {
            if r.tsExit != nil { Image(systemName: "point.3.connected.trianglepath.dotted").font(symbol).foregroundStyle(r.color) }
            else if r.imported { Image(systemName: "server.rack").font(symbol).foregroundStyle(r.color) }
            else if let c = r.loc.countryCode?.lowercased(), NSImage(named: "flag-\(c)") != nil {
                // Square vector flags (flag-icons, MIT), cropped round with a hairline so white flags keep an edge.
                Image("flag-\(c)").resizable().clipShape(.circle).overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            }
            else if let flag = countryFlag(r.loc.countryCode) { Text(flag).font(.system(size: size * 0.7)) }
            else { Image(systemName: "globe.europe.africa").font(symbol).foregroundStyle(r.color) }
        } else if id == BLOCK {
            Image(systemName: "nosign").font(symbol).foregroundStyle(Ink.failed)
        } else {
            Image(systemName: "globe").font(symbol).foregroundStyle(.secondary)
        }
    }

}

/// The system search field, for search placed in the middle of the toolbar (SwiftUI's own search sits at the trailing
/// edge). Filters as people type; Escape clears; ⌘F focuses it.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt = "Search"

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = prompt
        f.sendsSearchStringImmediately = true
        f.delegate = context.coordinator
        context.coordinator.observe(f)
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) { if f.stringValue != text { f.stringValue = text } }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        private weak var field: NSSearchField?
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ n: Notification) { text.wrappedValue = (n.object as? NSSearchField)?.stringValue ?? "" }

        /// ⌘F (the Find command) focuses the field. Selector observers go away with the coordinator.
        func observe(_ f: NSSearchField) {
            field = f
            NotificationCenter.default.addObserver(self, selector: #selector(focus), name: SearchField.focus, object: nil)
        }

        @objc private func focus() { _ = field?.window?.makeFirstResponder(field) }
    }

    static let focus = Notification.Name("app.unbraid.focusSearch")
}
