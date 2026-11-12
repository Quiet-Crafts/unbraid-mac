import AppIntents
import SwiftUI
import WidgetKit

// The widget extension: the status widget in three sizes and the Control Center controls (Connect or Pause, and
// the first three profiles). Widgets only read the snapshot the app publishes; a button writes a request the app
// carries out (see WidgetActions in the app).

@main
struct UnbraidWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        ProfileControl<ProfileSlot1>()
        ProfileControl<ProfileSlot2>()
        ProfileControl<ProfileSlot3>()
        ConnectionControl()
    }
}

/// Connection state with one action; medium adds the routes, large adds this week's data per route.
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "status", provider: Provider()) { WidgetView(s: $0.snapshot, live: $0.snapshot.fresh(at: $0.date)) }
            .configurationDisplayName("unbraid")
            .description("Connected, paused or off, your routes, and one button to connect, pause or resume.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct Entry: TimelineEntry {
    var date = Date.now
    var snapshot: Snapshot
}

/// The app writes a new snapshot and reloads the widgets on every change, and in time to keep vouching for itself, so
/// one entry is enough; a pause that ends on its own gets an entry at its resume time, and the moment the app stops
/// vouching for the snapshot one that says "Open unbraid" (Snapshot.timeline).
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(snapshot: Snapshot(phase: .on, exits: 3, updated: .now)) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(snapshot: Snapshot.read())) }
    /// Read again on their own only when the app didn't reload them in time (Snapshot.nextRead).
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date.now
        let s = Snapshot.read()
        let entries = s.timeline(now: now).map { Entry(date: $0.date, snapshot: $0.snapshot) }
        completion(Timeline(entries: entries, policy: .after(s.nextRead(now: now))))
    }
}

struct WidgetView: View {
    let s: Snapshot
    /// The app still vouches for the snapshot at this entry's date.
    let live: Bool
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Group {
            switch family {
            // Medium and large list the routes as the app does: a slash, the name, how many apps it carries.
            case .systemMedium: HStack(spacing: 14) { status.frame(width: 112); Divider(); routes }
            case .systemLarge:
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) { status.frame(width: 112); Divider(); routes }.frame(height: 142)
                    Divider()
                    week
                }
            default: status
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder private var status: some View {
        if live { current } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("unbraid").font(.caption).foregroundStyle(.secondary)
                Text("Open unbraid").font(.headline).padding(.top, 6)
                Text("to see the connection").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Link(destination: URL(string: "unbraid://open")!) { Text("Open").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
    }

    private var current: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 8, height: 8).widgetAccentable()
                Text("unbraid").font(.caption).foregroundStyle(.secondary)
            }
            Text(title).font(.headline).padding(.top, 8)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(failed ? 1 : 2)
            // Which action failed is the app's to say (connect, change, pause, disconnect): the snapshot knows one did.
            if failed { Label("Last action failed", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(renderingMode == .fullColor ? Palette.block : .primary).lineLimit(1) }
            // A widget is a picture taken earlier: it says when, rather than pretend to be live.
            Text("Updated \(s.updated.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
            Spacer(minLength: 6)
            action
        }
    }

    /// The same control as the app's: accent to connect or resume, neutral to pause.
    @ViewBuilder private var action: some View {
        Group {
            switch s.phase {
            case .on: Button(intent: PauseIntent()) { wide("Pause 15 min", "pause.fill") }.buttonStyle(.bordered).tint(renderingMode == .fullColor ? .secondary : nil)
            case .connecting: SwiftUI.Link(destination: URL(string: "unbraid://open")!) { wide("Connecting", "ellipsis") }.buttonStyle(.bordered).tint(renderingMode == .fullColor ? .secondary : nil)
            case .paused: connectButton("Resume", "play.fill")
            case .off: connectButton("Connect", "power")
            }
        }
        .buttonBorderShape(.capsule)
    }

    @ViewBuilder private func connectButton(_ title: String, _ symbol: String) -> some View {
        if renderingMode == .fullColor {
            Button(intent: ConnectIntent()) { wide(title, symbol).foregroundStyle(Palette.onAccent) }.buttonStyle(.borderedProminent).tint(Palette.accent)
        } else {
            Button(intent: ConnectIntent()) { wide(title, symbol) }.buttonStyle(.bordered)
        }
    }

    private func wide(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
    }

    /// The default route first (Direct when that is the default), then the others with apps, then Direct and Blocked
    /// when they hold any: five rows at most.
    private var routes: some View {
        let def = s.routes.filter(\.isDefault), other = s.routes.filter { !$0.isDefault && $0.apps > 0 }
        let directDefault = s.defaultRoute == "direct"
        var rows: [(id: String, name: String, color: Color, note: String)] = directDefault ? [("direct", "Direct", Palette.direct, "Default")] : []
        rows += (def + other).map { ($0.id, $0.name, Palette.mark($0.hue), $0.isDefault ? "Default" : count($0.apps)) }
        if s.direct > 0, !directDefault { rows.append(("direct", "Direct", Palette.direct, count(s.direct))) }
        if s.blocked > 0 { rows.append(("block", "Blocked", Palette.block, count(s.blocked))) }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.prefix(5), id: \.id) { r in
                HStack(spacing: 8) {
                    Slash(color: r.color, height: 13).widgetAccentable()
                    Text(r.name).font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    Text(r.note).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(height: 26)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func count(_ n: Int) -> String { "\(n) app\(n == 1 ? "" : "s")" }

    @ViewBuilder private var week: some View {
        // Only what the bars draw: the active VPN routes (never Direct, home or a route since removed).
        let ids = Set(s.routes.map(\.id))
        let days = s.week.map { d in d.bytes.reduce(Int64(0)) { $0 + (ids.contains($1.key) ? $1.value : 0) } }
        let max = days.max() ?? 0
        if max > 0 {
            let total = days.reduce(0, +)
            HStack(alignment: .firstTextBaseline) {
                Text("VPN traffic this week").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Units.bytes(total)).font(.system(size: 15, weight: .semibold, design: .monospaced))
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(s.week, id: \.date) { d in
                    VStack(spacing: 4) {
                        Group {
                            if renderingMode == .fullColor {
                                VStack(spacing: 0) {
                                    ForEach(s.routes.filter { d.bytes[$0.id] ?? 0 > 0 }) { r in
                                        Rectangle().fill(Palette.mark(r.hue)).frame(height: CGFloat(d.bytes[r.id] ?? 0) / CGFloat(max) * 80)
                                    }
                                }
                            } else {
                                let day = d.bytes.reduce(Int64(0)) { $0 + (ids.contains($1.key) ? $1.value : 0) }
                                Rectangle().frame(height: CGFloat(day) / CGFloat(max) * 80).widgetAccentable()
                            }
                        }
                        .frame(maxWidth: 28, maxHeight: 80, alignment: .bottom).clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                        Text(d.date.formatted(.dateTime.weekday(.narrow))).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityLabel("VPN traffic per day this week, \(Units.bytes(total)) in total")
        } else {
            Text("No VPN traffic recorded this week.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var failed: Bool { s.failed == true }

    private var tint: Color {
        switch s.phase { case .on: Color(nsColor: .systemGreen); case .paused: Color(nsColor: .systemOrange); case .connecting, .off: Palette.dim }
    }

    private var title: String {
        s.connectionTitle
    }

    private var subtitle: String {
        switch s.phase {
        case .on: "\(s.exits) VPN route\(s.exits == 1 ? "" : "s")"
        case .connecting: "Setting up routes"
        case .paused: s.pausedUntil.map { "Resumes at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Until resumed"
        case .off: "Own connection"
        }
    }
}

struct ControlSnapshotProvider: ControlValueProvider {
    var previewValue: Snapshot { Snapshot() }
    func currentValue() async throws -> Snapshot { Snapshot.read() }
}

protocol ProfileSlot { static var index: Int { get } }
struct ProfileSlot1: ProfileSlot { static let index = 0 }
struct ProfileSlot2: ProfileSlot { static let index = 1 }
struct ProfileSlot3: ProfileSlot { static let index = 2 }

struct ProfileControl<Slot: ProfileSlot>: ControlWidget {
    let slot = Slot.index
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "profile-\(slot)", provider: ControlSnapshotProvider()) { snapshot in
            let profile = WidgetAction.profileSlot(slot, names: snapshot.profiles, generation: snapshot.profileGeneration)
            let name = profile?.name ?? "No profile"
            ControlWidgetButton(action: SwitchProfileIntent(profile: ProfileEntity(id: name, generation: profile?.generation ?? ""))) {
                Label(name, systemImage: "person.crop.square")
            }
            .disabled(profile == nil)
            .tint(Palette.accent)
        }
        .displayName("Profile \(slot + 1)")
        .description("Switch to a saved profile.")
    }
}

struct ConnectionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "connection", provider: ControlSnapshotProvider()) { snapshot in
            // A snapshot no running app keeps fresh says nothing about now: Connect (macOS launches unbraid for it), never Pause.
            let on = snapshot.phase == .on && snapshot.fresh(at: .now)
            ControlWidgetButton(action: ConnectPauseIntent()) {
                Label(on ? "Pause" : "Connect", systemImage: on ? "pause.fill" : "power")
            }
            .tint(Palette.accent)
        }
        .displayName("Connect or Pause")
        .description("Connect or pause unbraid for 15 minutes.")
    }
}
