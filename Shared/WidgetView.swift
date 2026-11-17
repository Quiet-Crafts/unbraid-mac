import AppIntents
import SwiftUI
import WidgetKit

/// The status widget in its three sizes. Built into the widget extension, and into the app only so its test copy can
/// take pictures of it (`size`, since only WidgetKit fills in the widget's own size).
struct WidgetView: View {
    let s: Snapshot
    /// The app still vouches for the snapshot at this entry's date.
    let live: Bool
    /// The size to draw at where WidgetKit doesn't say (pictures); nil: the widget's own.
    var size: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var family: WidgetFamily { size ?? widgetFamily }
    private var color: Bool { renderingMode == .fullColor }
    /// Route health only for a snapshot still vouched for, of a running connection (`Snapshot.health`): never a green
    /// left over from before.
    private var health: (working: Int, total: Int)? { live ? s.health : nil }
    private var failing: Snapshot.Route? { live ? s.failing : nil }
    /// Green that reads as text on a light background too.
    private static let good = Palette.adaptive((0x23703D, 0x30D158))

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
                SwiftUI.Link(destination: URL(string: "unbraid://open")!) { Text("Open").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
    }

    private var current: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 8, height: 8).widgetAccentable()
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let h = health {
                // Working routes of all: the count says it, the line under it says it in words, for every rendering.
                Text("\(h.working)/\(h.total)").font(.system(size: family == .systemSmall ? 30 : 26, weight: .bold, design: .monospaced))
                    .foregroundStyle(color ? (h.working == h.total ? Self.good : Palette.block) : .primary).padding(.top, 4)
                Text(Snapshot.healthLine(working: h.working, total: h.total)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if family != .systemSmall, let line = s.statusLine {
                    // In words, never abbreviated: where both don't fit, the profile alone.
                    ViewThatFits(in: .horizontal) {
                        Text(line)
                        Text(s.statusShort ?? line).minimumScaleFactor(0.8)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(title).font(.headline).padding(.top, 8)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(failed ? 1 : 2)
            }
            // Which action failed is the app's to say (connect, change, pause, disconnect): the snapshot knows one did.
            if failed { Label("Last action failed", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(color ? Palette.block : .primary).lineLimit(1) }
            // A widget is a picture taken earlier: it says when, rather than pretend to be live.
            Text("Updated \(s.updated.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
            Spacer(minLength: 4)
            action
        }
    }

    /// The same control as the app's: accent to connect or resume, neutral to pause; with a route not answering, the
    /// way to it.
    @ViewBuilder private var action: some View {
        Group {
            switch s.phase {
            case .on:
                if let f = failing { SwiftUI.Link(destination: Snapshot.routeLink(f.id)) { wide("View Route", "arrow.forward.circle") }.buttonStyle(.bordered).tint(color ? .secondary : nil) }
                else { Button(intent: PauseIntent()) { wide("Pause 15 min", "pause.fill") }.buttonStyle(.bordered).tint(color ? .secondary : nil) }
            case .connecting: SwiftUI.Link(destination: URL(string: "unbraid://open")!) { wide("Connecting", "ellipsis") }.buttonStyle(.bordered).tint(color ? .secondary : nil)
            case .paused: connectButton("Resume", "play.fill")
            case .off: connectButton("Connect", "power")
            }
        }
        .buttonBorderShape(.capsule)
    }

    @ViewBuilder private func connectButton(_ title: String, _ symbol: String) -> some View {
        if color {
            Button(intent: ConnectIntent()) { wide(title, symbol).foregroundStyle(Palette.onAccent) }.buttonStyle(.borderedProminent).tint(Palette.accent)
        } else {
            Button(intent: ConnectIntent()) { wide(title, symbol) }.buttonStyle(.bordered)
        }
    }

    private func wide(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
    }

    /// `short`: the note when it doesn't fit beside a dot ("5 · 2" for "5 apps · 2 websites").
    private struct Row { var id: String, name: String, color: Color, note: String, short: String? = nil, ok: Bool? = nil }
    private static func row(_ id: String, _ name: String, _ color: Color, apps: Int, sites: Int, ok: Bool? = nil) -> Row {
        Row(id: id, name: name, color: color, note: Snapshot.count(apps: apps, sites: sites), short: sites == 0 ? nil : "\(apps) · \(sites)", ok: ok)
    }

    /// The default route first (Direct when that is the default), then the others with apps or websites, then Direct
    /// and Blocked when they hold any: five rows at most. Connected, each VPN route has a dot: green working, red not.
    private var routes: some View {
        let def = s.routes.filter(\.isDefault), other = s.routes.filter { !$0.isDefault && $0.apps + ($0.sites ?? 0) > 0 }
        let directDefault = s.defaultRoute == "direct"
        let direct = (s.direct, s.directSites ?? 0), blocked = (s.blocked, s.blockedSites ?? 0)
        var rows: [Row] = directDefault ? [Row(id: "direct", name: "Direct", color: Palette.direct, note: "Default")] : []
        rows += (def + other).map {
            let ok = health == nil ? nil : $0.ok
            return $0.isDefault ? Row(id: $0.id, name: $0.name, color: Palette.mark($0.hue), note: "Default", ok: ok)
                : Self.row($0.id, $0.name, Palette.mark($0.hue), apps: $0.apps, sites: $0.sites ?? 0, ok: ok)
        }
        if direct.0 + direct.1 > 0, !directDefault { rows.append(Self.row("direct", "Direct", Palette.direct, apps: direct.0, sites: direct.1)) }
        if blocked.0 + blocked.1 > 0 { rows.append(Self.row("block", "Blocked", Palette.block, apps: blocked.0, sites: blocked.1)) }
        let shown = rows.prefix(5), dots = shown.contains { $0.ok != nil }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown, id: \.id) { r in
                let down = r.ok == false
                HStack(spacing: 8) {
                    Slash(color: r.color, height: 13).widgetAccentable()
                    Text(r.name).font(.system(size: 12, weight: down ? .semibold : .regular)).foregroundStyle(down && color ? Palette.block : .primary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 2)
                    // Not working says so in words, so it reads in accented and clear rendering too; it keeps its width.
                    Group {
                        if down { Text("Not answering").fixedSize() }
                        else if let short = r.short { ViewThatFits(in: .horizontal) { Text(r.note); Text(short) } }
                        else { Text(r.note) }
                    }
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(down ? (color ? Palette.block : .primary) : .secondary).lineLimit(1)
                    if dots {
                        Circle().fill(r.ok.map { $0 ? Self.good : Palette.block } ?? .clear).frame(width: 7, height: 7)
                            .opacity(r.ok == nil ? 0 : 1).widgetAccentable()
                    }
                }
                .frame(height: 26)
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

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
                            if color {
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
        switch s.phase {
        case .on: failing != nil ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen)
        case .paused: Color(nsColor: .systemOrange)
        case .connecting, .off: Palette.dim
        }
    }

    /// Beside the dot: "unbraid", or with route health the state itself, since the count takes the title's place
    /// ("Protected · Home" on the small widget, whose status has no line for the profile).
    private var caption: String {
        guard health != nil else { return "unbraid" }
        return family == .systemSmall ? ([s.connectionTitle] + [s.profile].compactMap { $0 }).joined(separator: " · ") : s.connectionTitle
    }

    private var title: String { s.connectionTitle }

    private var subtitle: String {
        switch s.phase {
        case .on: "\(s.exits) VPN route\(s.exits == 1 ? "" : "s")"
        case .connecting: "Setting up routes"
        case .paused: s.pausedUntil.map { "Resumes at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Until resumed"
        case .off: "Own connection"
        }
    }
}
