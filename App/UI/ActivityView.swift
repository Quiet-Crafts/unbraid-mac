import Charts
import SwiftUI

/// Hours connected: this week, the last 13 weeks as a heat map, and one day at a time as a timeline (Android's Journal).
struct ActivityView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let model = AppModel.shared
    @State private var feed = StatsFeed()
    /// Index into the heat map's 91 days; nil = the last day that isn't in the future.
    @State private var day: Int?
    /// The spans of one day, tagged with it so a slow read never draws under another day's date.
    @State private var loaded: (day: Int64, spans: [Span])?

    var body: some View {
        StatsPage(feed: feed, title: "Activity", periodPicker: false, subtitle: { _ in "Last 13 weeks" }, content: content)
        .task(id: spanKey) { await loadSpans() }
        // The map moves a week on at Monday midnight: keep the same date selected (or the latest, once it scrolls off).
        .onChange(of: feed.view?.heatStart) { old, new in
            guard let old, let new, let d = day else { return }
            let moved = d - Int(new - old)
            day = moved >= 0 ? moved : nil
        }
    }

    private struct SpanKey: Hashable { var day: Int64?; var epoch: Int; var tick: Int?; var zone = TimeZone.current.identifier }

    /// A day's spans are read again when another day is picked, the statistics are deleted or the time zone moves the
    /// day's midnights, and today's with every refresh of the feed: its open span keeps growing, a pause's included (a
    /// pause adds no connected time). Past days don't change, so they aren't read every half-minute.
    private var spanKey: SpanKey {
        guard let v = feed.view else { return SpanKey(epoch: Stats.shared.epoch) }
        let sel = selected(v), today = v.heat.lastIndex { $0 >= 0 }
        return SpanKey(day: v.heatStart + Int64(sel), epoch: Stats.shared.epoch, tick: sel == today ? feed.revision : nil)
    }

    private func selected(_ v: StatsView) -> Int { min(day ?? v.heat.lastIndex { $0 >= 0 } ?? 0, max(0, v.heat.count - 1)) }

    private func loadSpans() async {
        guard let v = feed.view else { return }
        let d = v.heatStart + Int64(selected(v))
        // Local midnight to next midnight: 23 or 25 hours on a daylight saving change.
        let s = await Stats.shared.spans(from: StatsMath.dayStartMs(d), to: StatsMath.dayStartMs(d + 1))
        if !Task.isCancelled { loaded = (d, s) }
    }

    private func content(_ v: StatsView) -> some View {
        let sel = selected(v), dayNum = v.heatStart + Int64(sel)
        let spans = loaded?.day == dayNum ? loaded?.spans ?? [] : []
        let start = StatsMath.dayStartMs(dayNum), end = StatsMath.dayStartMs(dayNum + 1)
        return ScrollView {
            VStack(spacing: Layout.gap) {
                Card { Hero(v: v, selected: Binding(get: { sel }, set: { day = $0 })) }
                Card {
                    DayStepper(date: StatsMath.date(ofDay: dayNum), canBack: sel > 0, canForward: v.heat.indices.contains(sel + 1) && v.heat[sel + 1] >= 0,
                               back: { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { day = sel - 1 } }, forward: { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { day = sel + 1 } })
                    TimelineCard(spans: spans, start: start, end: end, loaded: loaded?.day == dayNum)
                    if loaded?.day == dayNum { Facts(spans: spans).padding(.top, 16) }
                }
            }
            .pageContent()
        }
    }
}

// MARK: - Hero and heat map

private struct Hero: View {
    let v: StatsView
    @Binding var selected: Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                summary.frame(minWidth: 230, maxWidth: .infinity, alignment: .leading)
                Heatmap(v: v, selected: $selected)
            }
            VStack(alignment: .leading, spacing: 24) { summary; Heatmap(v: v, selected: $selected) }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connected this week").overline()
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ForEach(Array(StatsMath.hmParts(v.weekMs).enumerated()), id: \.offset) { _, p in
                    Figure(value: p.0, unit: p.1, font: .heroNumeral)
                }
            }
            Text("Connected on \(v.week.filter { $0 > 0 }.count) of 7 days this week")
                .font(.system(size: 12))
                .foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Discrete duration tones for the calendar; timeline length already shows duration.
private func activityTone(_ hours: Float) -> Color {
    let level = hours <= 0 ? 0 : hours < 1 ? 1 : hours < 4 ? 2 : hours < 12 ? 3 : 4
    return heatTone(level)
}

/// How much of the deep green each level takes, from "none" to "12 h or more". The deep green (not the bright system
/// green) keeps the top levels at 3:1 or more against the card in light mode; the lowest levels stay lighter and are
/// also told by the legend, the tooltip and the line under the calendar.
private func heatTone(_ level: Int) -> Color {
    Ink.surface.mix(with: Ink.successText, by: [0, 0.4, 0.6, 0.8, 1.0][level])
}

private struct Hatching: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            for x in stride(from: -size.height, through: size.width, by: 6) {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            ctx.stroke(path, with: .color(Ink.dim), lineWidth: 1)
        }.clipped().accessibilityHidden(true)
    }
}

/// Fixed-size cells keep thirteen weeks legible; buttons support both keyboard and VoiceOver selection.
private struct Heatmap: View {
    let v: StatsView
    @Binding var selected: Int
    @Environment(\.displayScale) private var scale

    var body: some View {
        let names = Self.dayNames, months = monthLabels
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 4) {
                    Color.clear.frame(height: 14)
                    ForEach(0..<7) { row in
                        Text(row.isMultiple(of: 2) ? names[row] : "").lineLimit(1).minimumScaleFactor(0.8).frame(width: 28, height: 18, alignment: .leading)
                    }
                }
                ForEach(0..<13) { week in
                    VStack(spacing: 4) {
                        Text(months[week] ?? "").fixedSize().frame(width: 18, height: 14, alignment: .leading)
                        ForEach(0..<7) { row in
                            let i = week * 7 + row
                            if v.heat.indices.contains(i), v.heat[i] != -1 {
                                cell(i)
                            } else { Color.clear.frame(width: 18, height: 18) }
                        }
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(Array(["None", "Under 1 h", "1 to 4 h", "4 to 12 h", "12 h or more"].enumerated()), id: \.offset) { i, label in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: Corner.mark - 2).fill(heatTone(i))
                            .overlay(RoundedRectangle(cornerRadius: Corner.mark - 2).strokeBorder(Ink.separator, lineWidth: 1 / scale))
                            .frame(width: 12, height: 12)
                        Text(label).lineLimit(1)
                    }
                }
            }.font(.system(size: 12)).foregroundStyle(Ink.dim)
            Text(description(selected)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 320, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hours connected per day, last 13 weeks")
    }

    /// Monday first, as the rows run: "Mon", "Tue" … "Sun", so Saturday and Sunday are never both "S".
    private static var dayNames: [String] {
        let s = Calendar.current.shortStandaloneWeekdaySymbols
        return (0..<7).map { s[($0 + 1) % 7] }
    }

    private func cell(_ i: Int) -> some View {
        let hours = v.heat[i]
        return Button { selected = i } label: {
            RoundedRectangle(cornerRadius: Corner.mark - 2).fill(hours >= 0 ? activityTone(hours) : Ink.surface)
                .overlay { if !hours.isFinite || hours < 0 { Hatching().clipShape(.rect(cornerRadius: Corner.mark - 2)) } }
                .overlay(RoundedRectangle(cornerRadius: Corner.mark - 2).strokeBorder(i == selected ? Ink.text : Ink.separator, lineWidth: i == selected ? 2 : 1 / scale))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain).help(description(i))
        .accessibilityLabel(description(i)).accessibilityAddTraits(i == selected ? .isSelected : [])
    }

    private func description(_ i: Int) -> String {
        guard v.heat.indices.contains(i) else { return "Unavailable" }
        let hours = v.heat[i]
        let date = StatsMath.date(ofDay: v.heatStart + Int64(i)).formatted(.dateTime.day().month(.abbreviated).year())
        return "\(date) · " + (hours.isFinite && hours >= 0 ? StatsMath.hm(Int64(Double(hours) * 3_600_000)) : "Unavailable")
    }

    private var monthLabels: [Int: String] {
        let starts = (0..<13).filter { StatsMath.civil(v.heatStart + Int64($0 * 7)).d <= 7 }
        let weeks = (starts.contains { (1...2).contains($0) } ? [] : [0]) + starts
        return Dictionary(weeks.map { ($0, StatsMath.date(ofDay: v.heatStart + Int64($0 * 7 + 6)).formatted(.dateTime.month(.abbreviated))) }, uniquingKeysWith: { a, _ in a })
    }
}

// MARK: - Day

private struct DayStepper: View {
    let date: Date
    let canBack: Bool
    let canForward: Bool
    let back: () -> Void
    let forward: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(date, format: .dateTime.weekday(.wide).day().month(.wide)).font(.heading).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Button(action: back) { Label("Previous Day", systemImage: "chevron.left") }.disabled(!canBack).help("Previous day")
            Button(action: forward) { Label("Next Day", systemImage: "chevron.right") }.disabled(!canForward).help("Next day")
        }
        .labelStyle(.iconOnly).buttonStyle(.quiet).controlSize(.large).frame(height: 36)
    }
}

private func total(_ spans: [Span], paused: Bool) -> Int64 { spans.filter { $0.paused == paused }.reduce(0) { $0 + $1.end - $1.start } }

private struct TimelineCard: View {
    let spans: [Span]
    let start: Int64
    let end: Int64
    let loaded: Bool

    var body: some View {
        let length = Double(max(end - start, 1))
        VStack(alignment: .leading, spacing: 12) {
            Text("Daily timeline").overline()
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Ink.high
                    if !loaded { Hatching() }
                    if loaded && spans.isEmpty {
                        Text("Not connected this day").font(.system(size: 12)).foregroundStyle(Ink.dim)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    ForEach(Array(spans.enumerated()), id: \.offset) { _, s in
                        let a = max(s.start, start), b = min(s.end, end)
                        if b > a {
                            Rectangle().fill(s.paused ? Ink.surface : Ink.successText)
                                .overlay { if s.paused { Hatching() } }
                                .frame(width: max(1, g.size.width * Double(b - a) / length))
                                .offset(x: g.size.width * Double(a - start) / length)
                                .help("\(time(a)) to \(time(b)) · \(s.paused ? "Paused" : "Connected") · \(StatsMath.hm(b - a))")
                        }
                    }
                }.clipShape(.rect(cornerRadius: Corner.mark))
            }
            .frame(height: 32)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Connected and paused time")
            .accessibilityValue(loaded ? "\(StatsMath.hm(total(spans, paused: false))) connected, \(StatsMath.hm(total(spans, paused: true))) paused" : "Loading day")
            HStack {
                ForEach(0..<5) { i in
                    if i > 0 { Spacer() }
                    Text(time(start + Int64(Double(i) / 4 * length)))
                }
            }.font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim)
            HStack(spacing: 16) {
                Label { Text("Connected") } icon: { RoundedRectangle(cornerRadius: Corner.mark - 2).fill(Ink.successText).frame(width: 12, height: 12) }
                Label { Text("Paused") } icon: { Hatching().frame(width: 12, height: 12) }
                Label { Text("Off") } icon: { RoundedRectangle(cornerRadius: Corner.mark - 2).fill(Ink.high).frame(width: 12, height: 12) }
            }.font(.system(size: 12)).foregroundStyle(Ink.dim)
        }
    }

    private func time(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

private struct Facts: View {
    let spans: [Span]

    var body: some View {
        let on = spans.filter { !$0.paused }, pauses = spans.filter(\.paused)
        HStack(alignment: .top, spacing: 16) {
            Fact(value: StatsMath.hmParts(total(spans, paused: false)), label: "connected")
            Fact(value: StatsMath.hmParts(on.map { $0.end - $0.start }.max() ?? 0), label: "longest")
            Fact(value: [("\(pauses.count)", "")], label: pauses.isEmpty ? "pauses" : "pauses · \(StatsMath.hm(total(spans, paused: true)))")
        }
    }
}

private struct Fact: View {
    let value: [(String, String)]
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ForEach(Array(value.enumerated()), id: \.offset) { _, p in
                    Figure(value: p.0, unit: p.1)
                }
            }
            Text(label).font(.system(size: 12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}
