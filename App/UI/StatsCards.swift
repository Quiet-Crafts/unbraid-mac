import Charts
import SwiftUI

/// Opaque grouped content, shared by Routes and Insights.
struct Card<Content: View>: View {
    var spacing: CGFloat = 16
    var padding: CGFloat = Layout.inset
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(padding)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
            // Cards stand off the page by a shade alone; with Increase Contrast they get an edge too.
            .overlay { if contrast == .increased { RoundedRectangle(cornerRadius: Corner.card, style: .continuous).strokeBorder(Ink.separator) } }
            .font(.system(size: 13)).foregroundStyle(Ink.text).monospacedDigit()
    }
}

extension ExitInfo {
    /// Chart colour: the route's identity, grey for Direct and exits that no longer exist.
    var color: Color {
        switch tone {
        case .route(let hue): Ink.mark(hue)
        case .neutral, .direct, .faint: Ink.dim
        }
    }
}

/// Loads a period's statistics and refreshes them every 30 seconds while shown; 1-second sampling while watched.
@Observable
final class StatsFeed {
    var period = Period.week { didSet { if period != oldValue { showKept() } } }
    private(set) var view: StatsView?
    private(set) var hasSavedData = false
    /// Counts the refreshes, for views that reload their own reads along with the feed.
    private(set) var revision = 0

    /// The last figures per period, so a page comes back with them on its first frame instead of a spinner, and refreshes
    /// quietly. Good until the statistics are deleted.
    private struct Kept { var epoch: Int; var view: StatsView; var saved: Bool }
    private static var kept: [Period: Kept] = [:]

    init() { showKept() }

    private func showKept() {
        // Nothing kept: no figures (a spinner) rather than the last period's under this one's name.
        guard let k = Self.kept[period], k.epoch == Stats.shared.epoch else { view = nil; return }
        view = k.view
        hasSavedData = k.saved
    }

    func run() async {
        while !Task.isCancelled {
            let epoch = Stats.shared.epoch
            let fresh = await Stats.shared.view(period)
            if Task.isCancelled { return }
            if view != fresh { view = fresh }
            hasSavedData = Stats.shared.size() > 0
            Self.kept[period] = Kept(epoch: epoch, view: fresh, saved: hasSavedData)
            revision += 1
            try? await Task.sleep(for: .seconds(30))
        }
    }
}

/// SwiftUI can retain a view in a minimized or covered window. Fast sampling requires an actually visible window,
/// frontmost or not (live rates are watched while another app makes the traffic); each mounted statistics view owns a
/// token so one disappearing view cannot stop another.
struct StatsVisibility: NSViewRepresentable {
    func makeNSView(context: Context) -> Watch { Watch() }
    func updateNSView(_ view: Watch, context: Context) {}
    static func dismantleNSView(_ view: Watch, coordinator: ()) { view.stop() }

    final class Watch: NSView {
        private let id = UUID()
        private var tokens: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            let notes = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                         NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         NSApplication.didHideNotification, NSApplication.didUnhideNotification]
            tokens = notes.map { note in
                NotificationCenter.default.addObserver(forName: note, object: nil, queue: .main) { [weak self] n in
                    let closingWindow = n.name == NSWindow.willCloseNotification ? n.object as? NSWindow : nil
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let closingWindow, closingWindow === self.window {
                            self.stop()
                        } else { self.refresh() }
                    }
                }
            }
            refresh()
        }
        private func refresh() {
            Stats.shared.watch(id, visible: !NSApp.isHidden && window?.isVisible == true
                && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true)
        }
        func stop() {
            tokens.forEach(NotificationCenter.default.removeObserver); tokens = []
            Stats.shared.watch(id, visible: false)
        }
    }
}

/// Statistics are off until the user agrees: what is kept, for how long, and how to delete it.
struct StatsOff: View {
    let enable: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Statistics are off", systemImage: "chart.bar.xaxis")
        } description: {
            Text("Turn them on to see how much each app and exit uses, live speeds and how long you were protected.")
        } actions: {
            Button("Turn On Statistics", action: enable).contentButton(prominent: true)
        }
    }
}

/// The Android consent sheet, for a Mac.
let consentText = """
Statistics stay on this Mac. They are never uploaded.
Kept as hourly sums for a week and daily sums for about a year, with your last 100 speed tests.
Only apps and programs (by their location on this Mac, with your home folder shown as ~), routes, bytes, times, speeds and speed-test exit IPs. Programs that run from temporary or cache folders are grouped as "Other programs". No browsing destinations, ever.
Turn off or delete everything in Settings at any time.
"""

struct PeriodPicker: View {
    @Binding var period: Period
    var body: some View {
        Picker("Period", selection: $period) { ForEach(Period.allCases, id: \.self) { Text($0.label).tag($0) } }
            .pickerStyle(.segmented).labelsHidden().controlSize(.large).frame(width: 200)
    }
}

/// Loading, saved-history access and refresh lifecycle are identical across the three statistics pages.
struct StatsPage<Content: View>: View {
    @Bindable var feed: StatsFeed
    let title: String
    var periodPicker = true
    let subtitle: (StatsView) -> String
    @ViewBuilder var content: (StatsView) -> Content
    @State private var asking = false
    private let model = AppModel.shared

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: title, subtitle: !model.setup.prefs.stats && feed.hasSavedData ? "Recording off · saved statistics" : feed.view.map(subtitle) ?? "")
            Group {
                if let v = feed.view {
                    if !model.setup.prefs.stats && !feed.hasSavedData { StatsOff { asking = true } }
                    else { content(v) }
                } else { ProgressView().accessibilityLabel("Loading").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .font(.system(size: 13)).monospacedDigit()
        // Page actions live in the toolbar; the header keeps the title and its line of facts.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !model.setup.prefs.stats && feed.hasSavedData { Button("Turn Back On") { asking = true } }
                if periodPicker { PeriodPicker(period: $feed.period) }
            }
        }
        .focusedSceneValue(\.sceneActions, SceneActions(period: periodPicker ? $feed.period : nil,
            recordStatistics: !model.setup.prefs.stats && feed.view != nil ? { asking = true } : nil))
        .alert("Keep statistics?", isPresented: $asking) {
            Button("Turn On") { model.setStats(true) }
            Button("Not Now", role: .cancel) {}
        } message: { Text(consentText) }
        .task(id: feed.period) { await feed.run() }
        .background(StatsVisibility())
    }
}

/// The period total stays put while the chart reveals exact counts for a selected day or hour.
struct UsageCard: View {
    let v: StatsView
    @Binding var selected: String?
    @Environment(\.displayScale) private var scale

    private struct Bar: Identifiable {
        var id: String { "\(index)|\(exit)" }
        var index: Int; var exit: String; var from: Int64; var to: Int64; var top: Bool
    }

    private var order: [String] { v.byExit.map(\.exit).sorted() }
    /// The legend reads like the split bar above the chart: biggest first, Direct last.
    private var legend: [String] {
        let bytes = Dictionary(v.byExit.map { ($0.exit, $0.bytes.total) }, uniquingKeysWith: +)
        return order.sorted { a, b in
            if (a == DIRECT) != (b == DIRECT) { return b == DIRECT }
            return bytes[a, default: 0] != bytes[b, default: 0] ? bytes[a, default: 0] > bytes[b, default: 0] : a < b
        }
    }
    private var hasData: Bool { v.columns.contains { usageTotal($0) > 0 } }
    private var bars: [Bar] {
        let order = order
        return v.columns.enumerated().flatMap { i, col in
            let exits = order.filter { (col[$0]?.total ?? 0) > 0 }
            var base: Int64 = 0
            return exits.map { e in
                let start = base
                base += col[e]?.total ?? 0
                return Bar(index: i, exit: e, from: start, to: base, top: e == exits.last)
            }
        }
    }
    private var pick: Int? { selected.flatMap(Int.init).flatMap { v.columns.indices.contains($0) ? $0 : nil } }
    /// A round scale: steps of 1, 2, 2.5 or 5 times a power of ten, at most four, so the axis reads 0, 0.5, 1.0 … GB.
    private var peak: Double { max(1, Double(v.columns.map { usageTotal($0) }.max() ?? 0)) }
    private var step: Double {
        let raw = peak / 4, mag = pow(10, floor(log10(raw)))
        return ([1, 2, 2.5, 5, 10].first { $0 * mag >= raw } ?? 10) * mag
    }
    private var ticks: Int { Int((peak * 1.05 / step).rounded(.up)) }
    private var ceiling: Double { step * Double(ticks) }

    var body: some View {
        Card(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(legend, id: \.self) { e in
                        HStack(spacing: 8) { RouteDot(color: v.exits[e]?.color ?? Ink.dim); Text(v.exits[e]?.name ?? "Removed route") }
                    }
                }.font(.system(size: 12)).foregroundStyle(Ink.dim)
            }
            chart
            Text("Apps on Direct are counted only when they pass through unbraid.").font(.system(size: 12)).foregroundStyle(Ink.dim)
        }
        .onChange(of: v.from) { selected = nil }
        .onChange(of: v.columns.count) { selected = nil }
    }

    private var chart: some View {
        Chart {
            ForEach(bars) { b in
                BarMark(x: .value("When", String(b.index)), yStart: .value("Bytes", b.from), yEnd: .value("Bytes", b.to),
                        width: .ratio(0.6))
                    .foregroundStyle(v.exits[b.exit]?.color ?? Ink.dim).cornerRadius(0)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: b.top ? 4 : 0, topTrailingRadius: b.top ? 4 : 0))
            }
            if let pick {
                RuleMark(x: .value("When", String(pick))).foregroundStyle(Ink.dim).lineStyle(StrokeStyle(lineWidth: 1 / scale))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .fit)) { Tooltip(v: v, column: pick, title: title(pick)) }
            }
        }
        .chartXSelection(value: $selected)
        .chartXScale(domain: v.columns.indices.map(String.init))
        .chartYScale(domain: 0...ceiling)
        .chartXAxis {
            AxisMarks(values: v.columns.indices.map(String.init)) { value in
                if let i = value.as(String.self).flatMap(Int.init), v.labels.indices.contains(i), !v.labels[i].isEmpty {
                    AxisValueLabel {
                        Text(period == .week ? StatsMath.date(ofDay: v.from + Int64(i)).formatted(.dateTime.weekday(.abbreviated)).uppercased() : v.labels[i])
                            .font(.system(size: 12, weight: period == .week && i == v.selected ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(period == .week && i == v.selected ? Ink.accentText : Ink.dim)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: (0...ticks).map { step * Double($0) }) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1 / scale)).foregroundStyle(Ink.separator)
                if hasData {
                    AxisValueLabel { Text(Units.axisBytes(value.as(Double.self) ?? 0, step: step, ceiling: ceiling)).foregroundStyle(Ink.dim) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Color.clear.contentShape(.rect).onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        if let frame = proxy.plotFrame, geo[frame].contains(point) {
                            selected = proxy.value(atX: point.x - geo[frame].minX, as: String.self)
                        } else { selected = nil }
                    case .ended: selected = nil
                    }
                }
            }
        }
        .focusable()
        .onMoveCommand { direction in
            let current = pick ?? v.selected
            if direction == .left { selected = String(max(0, current - 1)) }
            if direction == .right { selected = String(min(v.columns.count - 1, current + 1)) }
        }
        .onExitCommand { selected = nil }
        .font(.system(size: 12, design: .monospaced)).frame(height: 180)
        .accessibilityLabel("Data per \(period == .day ? "hour" : "day") by route")
        .accessibilityValue(pick.map { "\(title($0)), \(Units.bytes(usageTotal(v.columns[$0])))" } ?? "\(Units.bytes(v.columns.reduce(0) { $0 + usageTotal($1) })) in total")
        .accessibilityHint("Use Left and Right Arrow to select a column")
    }

    private var period: Period { v.columns.count == 24 ? .day : v.columns.count == 7 ? .week : .month }
    private func title(_ i: Int) -> String {
        period == .day ? String(format: "%02d:00", i) : StatsMath.date(ofDay: v.from + Int64(i)).formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

private struct Tooltip: View {
    let v: StatsView
    let column: Int
    let title: String
    var body: some View {
        let col = v.columns[column]
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(Units.bytes(usageTotal(col))).monospaced()
            ForEach(col.keys.sorted(), id: \.self) { e in
                HStack(spacing: 8) {
                    RouteDot(color: v.exits[e]?.color ?? Ink.dim)
                    Text(v.exits[e]?.name ?? "Removed route")
                    Spacer()
                    Text(Units.bytes(col[e]?.total ?? 0)).monospaced()
                }.foregroundStyle(Ink.dim)
            }
        }
        .font(.system(size: 12)).foregroundStyle(Ink.text)
        .frame(minWidth: 200).tooltipSurface()
    }
}

/// A chart column's traffic through unbraid.
private func usageTotal(_ col: [String: Traffic]) -> Int64 { col.reduce(0) { $0 + $1.value.total } }

/// The scale and time labels under the live graph. They redraw only when the scale changes.
private struct LiveAxes: View {
    let top: Double
    static let side: CGFloat = 68
    static let below: CGFloat = 20

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 0, y: 0, width: size.width - Self.side, height: size.height - Self.below)
            var grid = Path()
            for i in 0...2 {
                let y = plot.maxY - plot.height * CGFloat(i) / 2
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.draw(Text(Units.rate(top * Double(i) / 2 * 1e6)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim),
                             at: CGPoint(x: plot.maxX + 6, y: y), anchor: .leading)
            }
            context.stroke(grid, with: .color(Ink.separator), lineWidth: 1)
            for (seconds, x, anchor) in [(-60, plot.minX, UnitPoint.bottomLeading), (-30, plot.midX, .bottom), (0, plot.maxX, .bottomTrailing)] {
                context.draw(Text("\(seconds)s").font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim), at: CGPoint(x: x, y: size.height), anchor: anchor)
            }
        }
    }
}

/// The last minute, with a trace for each exit and a common time axis.
struct LiveCard: View {
    private let model = AppModel.shared
    @Environment(\.navigate) private var navigate
    let v: StatsView

    var body: some View {
        let live = Stats.shared.live
        let exits = live.down.keys.sorted()
        let down = Units.rateParts(Double(live.downNow))
        Card(spacing: 8) {
            HStack(spacing: 12) {
                Text("Live").overline(); Spacer()
                if model.vpn.state.phase == .on && model.setup.prefs.stats {
                    Text("Every second").font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim)
                }
            }
            if !model.setup.prefs.stats || model.vpn.state.phase != .on {
                let phase = model.vpn.state.phase
                VStack(spacing: 8) {
                    Text(!model.setup.prefs.stats ? "No live measurements" : phase == .paused ? "Paused" : phase == .connecting ? "Connecting…" : "No live measurements").font(.heading)
                    Text(!model.setup.prefs.stats ? "Turn on statistics to measure live traffic." : phase == .paused ? "Resume to measure traffic through your routes." : phase == .connecting ? "Live traffic appears once your routes are connected." : "Connect to measure traffic through your routes.")
                        .font(.system(size: 12)).foregroundStyle(Ink.dim)
                    if phase == .connecting {
                        ProgressView().controlSize(.small).frame(height: 30)
                    } else if phase != .on {
                        Button { model.connect() } label: { Text(phase == .paused ? "Resume" : "Connect") }
                            .contentButton(prominent: true)
                            .frame(height: 30)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 128)
            } else {
                Figure(value: down.0, unit: down.1).frame(maxWidth: .infinity, alignment: .leading)
                Text("↑ \(Units.rate(Double(live.upNow)))").font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim)
                let setup = model.vpn.running ?? model.setup
                let peak = Double(exits.compactMap { live.down[$0]?.max() }.max() ?? 0) / 1e6
                ZStack {
                    LiveAxes(top: speedCeiling(peak))
                    LiveGraph(lines: exits.map { exit in
                        .init(values: (live.down[exit] ?? []).map { $0 / 1e6 }, color: v.exits[StatsMath.idOf(exit, setup: setup)]?.color ?? Ink.dim)
                    }, top: speedCeiling(peak), fill: 0.1)
                    .padding(.trailing, LiveAxes.side).padding(.bottom, LiveAxes.below)
                }
                .font(.system(size: 12, design: .monospaced)).frame(height: 200).padding(.vertical, 8)
                .accessibilityLabel("Download over the last minute: \(Units.rate(Double(live.downNow))) now")
                Text("Per route · now").overline()
                ForEach(exits, id: \.self) { exit in
                    HStack(spacing: 12) {
                        RouteDot(color: v.exits[StatsMath.idOf(exit, setup: model.vpn.running ?? model.setup)]?.color ?? Ink.dim)
                        Text(v.exits[StatsMath.idOf(exit, setup: model.vpn.running ?? model.setup)]?.name ?? model.setup.route(exit)?.name ?? exit).lineLimit(1)
                        Spacer()
                        Text(Units.rate(Double(live.down[exit]?.last ?? 0))).font(.system(size: 12, design: .monospaced))
                    }
                }
            }
            Button("Test a Route's Speed") { navigate(.speed) }.contentButton().controlSize(.small).padding(.top, 8)
        }
    }
}
