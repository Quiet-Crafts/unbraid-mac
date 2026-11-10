import Charts
import SwiftUI

/// What went through the VPN: the period's total, data per day or hour by exit, each exit's share, the apps that sent it,
/// the last minute live, and each exit's speeds. Android's Overview, App flows, Usage by provider and Tunnels, on one page.
struct TrafficView: View {
    private let model = AppModel.shared
    @Environment(\.navigate) private var navigate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var scale
    @State private var feed = StatsFeed()
    @State private var only: String?
    @State private var all = false
    @State private var detail: String?
    @State private var sort = Sort.data
    @State private var column: String?
    @State private var ascending = false
    private enum Sort: String, CaseIterable { case app = "App", exit = "Route", data = "Data" }

    var body: some View {
        StatsPage(feed: feed, title: "Traffic", subtitle: { v in
            "Traffic through unbraid · " + range(v)
        }, content: content)
        .sheet(item: Binding(get: { detail.map { PickerTarget(id: $0) } }, set: { detail = $0?.id })) { t in
            if let v = feed.view { ExitDetail(v: v, exit: t.id, period: feed.period) }
        }
    }

    private func range(_ v: StatsView) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateTemplate = "d MMMM"
        return formatter.string(from: StatsMath.date(ofDay: v.from), to: StatsMath.date(ofDay: v.to))
    }

    private func content(_ v: StatsView) -> some View {
        let exits = v.byExit.filter { $0.exit != DIRECT && $0.bytes.total > 0 }
        let total = max(1, exits.reduce(0) { $0 + $1.bytes.total })
        return ScrollView {
            VStack(alignment: .leading, spacing: Layout.gap) {
                summary(v, v.byExit.filter { $0.bytes.total > 0 }, max(1, v.total.total))
                if exits.filter({ Double($0.bytes.total) / Double(total) >= 0.005 }).count > 1 { RouteSplit(v: v, exits: exits, total: total) }
                UsageCard(v: v, selected: $column)
                if !exits.isEmpty {
                    Card {
                        Text("Routes · Direct traffic not shown").overline()
                        ForEach(exits, id: \.exit) { e in
                            ExitRow(v: v, exit: e.exit, bytes: e.bytes.total, share: Double(e.bytes.total) / Double(total), biggest: exits.first?.bytes.total ?? 1, selected: only == e.exit) {
                                filter(e.exit)
                            } info: { detail = e.exit }
                            if e.exit != exits.last?.exit { Hairline() }
                        }
                    }
                    apps(v)
                }
                LiveCard(v: v)
                if !v.byExit.isEmpty { providers(v) }
                tunnels(v)
            }
            .pageContent()
        }
    }

    /// The period's one big number, then the facts beside it, set like a measurement: down, up, the busiest exit.
    private func summary(_ v: StatsView, _ exits: [ExitBytes], _ total: Int64) -> some View {
        let traffic = exits.reduce(Traffic()) { $0 + $1.bytes }
        let t = StatsMath.bytes(traffic.total)
        let busiest = exits.max { $0.bytes.total < $1.bytes.total }
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 4) {
            GridRow {
                Text(feed.period == .day ? "Today" : "This \(feed.period.label.lowercased())").overline().padding(.trailing, 28)
                summaryCell { Text("Down").overline() }
                summaryCell { Text("Up").overline() }
                if busiest != nil { summaryCell { Text("Busiest route").overline() } }
            }
            GridRow(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(t.0).font(.heroNumeral)
                    Text(t.1).font(.system(size: 13, design: .monospaced)).foregroundStyle(Ink.dim)
                }
                .accessibilityElement(children: .combine)
                .padding(.trailing, 28)
                summaryCell { Figure(value: StatsMath.bytes(traffic.down).0, unit: StatsMath.bytes(traffic.down).1).lineLimit(1) }
                summaryCell { Figure(value: StatsMath.bytes(traffic.up).0, unit: StatsMath.bytes(traffic.up).1).lineLimit(1) }
                if let b = busiest {
                    summaryCell {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Slash(color: v.exits[b.exit]?.color ?? Ink.dim, height: 18)
                            Text(v.exits[b.exit]?.name ?? "Removed route")
                        }.font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    }
                }
            }
            GridRow {
                Text(" ").hidden()
                summaryCell { Text(" ") }
                summaryCell { Text(" ") }
                if let b = busiest {
                    summaryCell {
                        Text("\(StatsMath.bytesText(b.bytes.total)) · \((Double(b.bytes.total) / Double(total)).formatted(.percent.precision(.fractionLength(0))))")
                    }
                }
            }.font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryCell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(.horizontal, 20)
            .overlay(alignment: .leading) { Rectangle().fill(Ink.separator).frame(width: 1 / scale) }
    }

    private func tunnels(_ v: StatsView) -> some View {
        func speed(_ id: String) -> Int64 { v.tests[id]?.down ?? 0 }
        let ids = Set(model.vpn.tags.keys.map { StatsMath.idOf($0, setup: model.setup) }).union(v.tests.keys).union(v.byExit.map(\.exit)).filter { $0 != DIRECT }.sorted {
            speed($0) != speed($1) ? speed($0) > speed($1) : (v.exits[$0]?.name ?? $0) < (v.exits[$1]?.name ?? $1)
        }
        return Card {
            Text("Tunnels").overline()
            if ids.allSatisfy({ speed($0) == 0 }) {
                Text("No speeds yet. Run a speed test.").foregroundStyle(Ink.dim)
            }
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 12) {
                    RouteDot(color: v.exits[id]?.color ?? .gray)
                    Button(v.exits[id]?.name ?? model.setup.route(id)?.name ?? id) { detail = id }.buttonStyle(.plain)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        if let t = v.tests[id] { Text("Test ↓\(StatsMath.mbps(t.down)) ↑\(StatsMath.mbps(t.up)) Mbps") }
                        if v.tests[id] == nil { Text("–").foregroundStyle(Ink.dim) }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    Button { detail = id } label: { Image(systemName: "info.circle").frame(width: 28, height: 28) }
                        .buttonStyle(.quiet).help("Exit Details").accessibilityLabel("Details for \(v.exits[id]?.name ?? id)")
                }
            }
            Text("Speed-test results: download (↓) and upload (↑).")
                .font(.system(size: 12)).foregroundStyle(Ink.dim)
            Button("Speed Test") { navigate(.speed) }.contentButton().controlSize(.small)
        }
    }

    private func providers(_ v: StatsView) -> some View {
        let rows = v.byProvider()
        let sum = max(1, rows.reduce(0) { $0 + $1.bytes })
        return Card {
            Text("By provider").overline()
            Text("Data that passes through unbraid. Apps set to Direct can skip it and are not counted when they do. Apps that follow a Direct default route are counted when they pass through unbraid.")
                .font(.system(size: 12)).foregroundStyle(Ink.dim)
            ForEach(rows, id: \.name) { r in
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Text(r.name); Spacer()
                        Text(StatsMath.bytesText(r.bytes)).foregroundStyle(Ink.dim)
                        Text((Double(r.bytes) / Double(sum)).formatted(.percent.precision(.fractionLength(0))))
                            .frame(width: 64, alignment: .trailing)
                    }
                    GeometryReader { g in
                        Rectangle().fill(Ink.high)
                        Rectangle().fill(Ink.dim).frame(width: g.size.width * Double(r.bytes) / Double(sum))
                    }.frame(height: 4).accessibilityHidden(true)
                }.font(.system(size: 12, design: .monospaced))
            }
        }
    }

    private func filter(_ exit: String) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { only = only == exit ? nil : exit; all = false }
    }

    private func apps(_ v: StatsView) -> some View {
        let rows = v.apps.filter { $0.exit != DIRECT && (only == nil || $0.exit == only) }.sorted { a, b in
            if a == b { return false }
            let first: Bool
            switch sort {
            case .app: first = (model.appName(a.app), a.exit, a.app) < (model.appName(b.app), b.exit, b.app)
            case .exit: first = (v.exits[a.exit]?.name ?? a.exit, a.app) < (v.exits[b.exit]?.name ?? b.exit, b.app)
            case .data: first = a.bytes != b.bytes ? a.bytes < b.bytes : (a.app, a.exit) < (b.app, b.exit)
            }
            return ascending ? first : !first
        }
        return Card {
            HStack(spacing: 12) {
                Text("Apps").overline(); Spacer()
                GlassMenu(glass: false) {
                    Button("All Routes") { only = nil; all = false }
                    ForEach(v.byExit.filter { $0.exit != DIRECT }, id: \.exit) { e in
                        Button(v.exits[e.exit]?.name ?? "Removed route") { only = e.exit; all = false }
                    }
                } label: { Text(only.flatMap { v.exits[$0]?.name } ?? "All Routes") }
                .accessibilityLabel("Filter apps by route")
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    sortButton(.app).frame(maxWidth: .infinity, alignment: .leading)
                    sortButton(.exit).frame(minWidth: 128, maxWidth: .infinity, alignment: .leading)
                    sortButton(.data).frame(width: 108, alignment: .trailing)
                }.padding(.bottom, 12)
                ForEach(rows.prefix(all ? rows.count : 12), id: \.self) { a in
                    Hairline().gridCellColumns(3)
                    GridRow {
                        HStack(spacing: 12) {
                            AppIconView(app: model.apps.app(a.app), size: Measure.tableIcon)
                            Text(model.appName(a.app)).lineLimit(1)
                        }.frame(maxWidth: .infinity, minHeight: Measure.tableRow, alignment: .leading).layoutPriority(-1)
                        Button { filter(a.exit) } label: {
                            HStack(spacing: 8) {
                                RouteDot(color: v.exits[a.exit]?.color ?? Ink.dim)
                                Text(v.exits[a.exit]?.name ?? "Removed route").lineLimit(1)
                            }.fixedSize(horizontal: true, vertical: false).frame(minWidth: 128, maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).help("Show only this route")
                        Text(StatsMath.bytesText(a.bytes)).font(.system(size: 12, design: .monospaced))
                            .frame(width: 108, alignment: .trailing)
                    }
                }
            }
            if rows.isEmpty { Text("No apps sent data through this route in this period.").foregroundStyle(Ink.dim) }
            if rows.count > 12 {
                Button(all ? "Show Fewer" : "Show All \(rows.count)") {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { all.toggle() }
                }.contentButton().controlSize(.small)
            }
        }
    }

    private func sortButton(_ column: Sort) -> some View {
        Button {
            if sort == column { ascending.toggle() } else { sort = column; ascending = column != .data }
        } label: {
            HStack(spacing: 4) {
                Text(column.rawValue)
                if sort == column { Image(systemName: ascending ? "chevron.up" : "chevron.down") }
            }.font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.dim)
        }.buttonStyle(.plain).accessibilityLabel("Sort by \(column.rawValue)")
            .accessibilityValue(sort == column ? (ascending ? "Ascending" : "Descending") : "Not sorted")
    }
}

/// Exit selection, measured speeds and details remain reachable beside the ribbon stage.
private struct ExitRow: View {
    let v: StatsView
    let exit: String
    let bytes: Int64
    let share: Double
    let biggest: Int64
    let selected: Bool
    let tap: () -> Void
    let info: () -> Void
    private func laneLabel(_ name: String?, _ top: [AppBytes], _ rest: Int, _ restBytes: Int64) -> String {
        let apps = top.map { "\(AppModel.shared.appName($0.app)), \(StatsMath.bytesText($0.bytes))" }.joined(separator: ", ")
        let more = rest == 0 ? "" : ", \(rest) other apps, \(StatsMath.bytesText(restBytes))"
        return "Filter by \(name ?? "Exit"), \(bytes.formatted()) bytes. " + apps + more
    }

    var body: some View {
        let ex = v.exits[exit]
        let lane = v.appLane(exit)
        let restBytes = lane.rest.reduce(Int64(0)) { $0 + $1.bytes }
        return HStack(spacing: 12) {
            Button(action: tap) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            RouteDot(color: ex?.color ?? Ink.dim)
                            Text(ex?.name ?? "Removed route").font(.system(size: 13, weight: .semibold))
                            // The filter in use shows by a mark, not by a shade alone.
                            if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.accentText) }
                        }
                        let senders = v.apps.filter { $0.exit == exit }.count
                        Text("\(ex?.via ?? "") · \(senders) app\(senders == 1 ? "" : "s") sent data").font(.system(size: 12)).foregroundStyle(Ink.dim)
                        LaneBar(top: lane.top, rest: lane.rest, bytes: bytes, biggest: biggest, color: ex?.color ?? Ink.dim)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 8) {
                        Text("\(StatsMath.bytesText(bytes)) · \(share.formatted(.percent.precision(.fractionLength(0))))")
                        if let t = v.tests[exit] { Text("Test ↓\(StatsMath.mbps(t.down)) ↑\(StatsMath.mbps(t.up)) Mbps").foregroundStyle(Ink.dim) }
                    }.font(.system(size: 12, design: .monospaced))
                }.contentShape(.rect)
            }.buttonStyle(.plain)
                .accessibilityLabel(laneLabel(ex?.name, lane.top, lane.rest.count, restBytes))
                .accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: info) { Label("Exit Details", systemImage: "info.circle").labelStyle(.iconOnly).frame(width: 28, height: 28) }
                .buttonStyle(.quiet).help("Details for \(ex?.name ?? "this exit")")
                .accessibilityLabel("Details for \(ex?.name ?? "this exit")")
        }
        .padding(.vertical, 8).padding(.horizontal, 8).background(selected ? Ink.high : .clear, in: .rect(cornerRadius: Corner.inner, style: .continuous))
    }
}

private struct LaneBar: View {
    let top: [AppBytes]
    let rest: [AppBytes]
    let bytes: Int64
    let biggest: Int64
    let color: Color

    var body: some View {
        let restBytes = rest.reduce(Int64(0)) { $0 + $1.bytes }
        let segments = top.map(\.bytes) + (restBytes > 0 ? [restBytes] : [])
        let total = max(1, segments.reduce(0, +))
        if !segments.isEmpty {
            GeometryReader { g in
                let width = g.size.width * CGFloat(bytes) / CGFloat(max(1, biggest))
                let room = max(0, width - CGFloat(segments.count - 1) * 2)
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { i, value in
                        Rectangle().fill(color.opacity(i < top.count ? 0.95 - Double(i) * 0.12 : 0.25))
                            .frame(width: room * CGFloat(value) / CGFloat(total))
                    }
                }.clipShape(Capsule())
            }.frame(height: 14).accessibilityHidden(true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(top, id: \.self) { a in
                        Text(AppModel.shared.appName(a.app) + " " + StatsMath.bytesText(a.bytes)).fixedSize()
                    }
                    if !rest.isEmpty { Text("+\(rest.count) apps \(StatsMath.bytesText(restBytes))").foregroundStyle(Ink.dim).fixedSize() }
                }.font(.system(size: 12))
            }
        }
    }
}

/// One exit in depth: its fastest speed test and how its data split across servers.
private struct ExitDetail: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.navigate) private var navigate
    let v: StatsView
    let exit: String
    let period: Period
    @State private var servers: [ServerBytes] = []

    var body: some View {
        let ex = v.exits[exit]
        let test = v.tests[exit]
        SheetFrame(title: ex?.name ?? "Exit", subtitle: "\(ex?.via ?? "") · \(period.label)", width: SheetWidth.form) {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    Text("Speed test download").overline()
                    Figure(value: test.map { StatsMath.mbps($0.down) } ?? "–", unit: "Mbps")
                    Text("↑ \(test.map { StatsMath.mbps($0.up) } ?? "–") Mbps upload")
                        .font(.system(size: 12)).foregroundStyle(Ink.dim)
                }
                Card {
                    Text("Servers · share of this exit's data").overline()
                    let sum = max(1, servers.reduce(0) { $0 + $1.bytes })
                    if servers.isEmpty { Text("No data in this period yet.").foregroundStyle(Ink.dim) }
                    ForEach(servers, id: \.name) { s in
                        HStack(spacing: 12) { Text(s.name).monospaced(); Spacer(); Text("\(Int(100 * s.bytes / sum))%").monospacedDigit().foregroundStyle(Ink.dim) }
                    }
                }
            }.padding(.horizontal, Layout.gutter).padding(.bottom, Layout.gap)
        } actions: {
            Button("Speed Test") { dismiss(); navigate(.speed) }.contentButton()
            Button("Done") { dismiss() }.contentButton(prominent: true).keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 13)).monospacedDigit()
        .task { servers = await Stats.shared.servers(exit: exit, from: v.from, to: v.to) } // epoch days
    }
}

/// The period's traffic as one bar split by route, each part in its colour with its slash and share below.
private struct RouteSplit: View {
    let v: StatsView
    let exits: [ExitBytes]
    let total: Int64

    var body: some View {
        // Routes under half a percent would be slivers: they stay in the Routes card below, not in the split.
        let parts = exits.filter { Double($0.bytes.total) / Double(total) >= 0.005 }.sorted { $0.bytes.total > $1.bytes.total }
        let shown = max(1, parts.reduce(0) { $0 + $1.bytes.total })
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                let room = max(0, g.size.width - CGFloat(parts.count - 1) * 2)
                HStack(spacing: 2) {
                    ForEach(parts, id: \.exit) { e in
                        Capsule().fill(v.exits[e.exit]?.color ?? Ink.dim).frame(width: room * CGFloat(e.bytes.total) / CGFloat(shown))
                    }
                }
            }
            .frame(height: 8)
            // One line when the routes fit, else one per line: names are never cut to "Uni…".
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { legend(parts) }
                VStack(alignment: .leading, spacing: 4) { legend(parts) }
            }
            .font(.system(size: 12)).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Traffic by route: " + parts.map { "\(v.exits[$0.exit]?.name ?? "Removed route") \((Double($0.bytes.total) / Double(total)).formatted(.percent.precision(.fractionLength(0))))" }.joined(separator: ", "))
    }

    private func legend(_ parts: [ExitBytes]) -> some View {
        ForEach(parts, id: \.exit) { e in
            HStack(spacing: 6) {
                RouteDot(color: v.exits[e.exit]?.color ?? Ink.dim)
                Text(v.exits[e.exit]?.name ?? "Removed route").fixedSize()
                Text((Double(e.bytes.total) / Double(total)).formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim)
            }
        }
    }
}
