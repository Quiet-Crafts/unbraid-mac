import SwiftUI

/// The last minute of readings, sliding left without a jump. A reading arrives each second; between two of them the graph
/// keeps moving on the clock, so each new reading enters from the right edge over the following second. Drawn off the
/// main thread, thirty times a second is plenty at this pace, and only while the window is in use. With Reduce Motion it
/// holds still between readings.
struct LiveGraph: View {
    struct Line {
        var values: [Float]
        var color: Color
    }

    let lines: [Line]
    /// The top of the scale; it moves to a new value over a second rather than at once.
    let top: Double
    var fill = 0.16
    var lineWidth: CGFloat = 1.5
    private let stats = Stats.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var oldTop: Double?
    @State private var newTopAt = 0.0

    /// Sixty readings make fifty-nine steps across the width.
    private static let steps = 59.0

    var body: some View {
        // Worked out once a reading, not once a frame.
        let drawn = lines.map { line in
            (curve: MonotoneCurve(line.values.enumerated().map { (x: Double($0.offset - line.values.count + 60), y: Double($0.element)) }),
             first: Double(60 - line.values.count), color: line.color)
        }
        let moving = scenePhase == .active && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { time in
            let now = time.date.timeIntervalSinceReferenceDate
            // How far through the second since the last reading: 1 holds the newest reading at the right edge.
            let through = moving ? min(1, max(0, (now - stats.liveAt) / 1)) : 1
            let settled = min(1, max(0, (now - newTopAt) / 1))
            let scale = max(0.001, (oldTop ?? top) + (top - (oldTop ?? top)) * settled * settled * (3 - 2 * settled))
            let fill = fill, lineWidth = lineWidth
            Canvas(rendersAsynchronously: true) { context, size in
                let unit = size.width / Self.steps
                func x(_ slot: Double) -> CGFloat { CGFloat(slot + 1 - through) * unit }
                func y(_ value: Double) -> CGFloat { size.height - 1 - CGFloat(min(value / scale, 1)) * (size.height - 2) }
                for line in drawn {
                    guard let last = line.curve.last, last > line.first else { continue }
                    var trace = Path()
                    let slotsPerStep = Double(3 / max(unit, 0.1))
                    var slot = line.first
                    trace.move(to: CGPoint(x: x(slot), y: y(line.curve.value(at: slot))))
                    while slot < last {
                        slot = min(last, slot + slotsPerStep)
                        trace.addLine(to: CGPoint(x: x(slot), y: y(line.curve.value(at: slot))))
                    }
                    if fill > 0 {
                        var area = trace
                        area.addLine(to: CGPoint(x: x(last), y: size.height)); area.addLine(to: CGPoint(x: x(line.first), y: size.height)); area.closeSubpath()
                        context.fill(area, with: .color(line.color.opacity(fill)))
                    }
                    context.stroke(trace, with: .color(line.color), style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
                }
            }
        }
        .clipped()
        .onChange(of: top) { old, _ in oldTop = old; newTopAt = Date.now.timeIntervalSinceReferenceDate }
        .accessibilityHidden(true)
    }
}

/// A minute of samples as a line with a soft fill, scaled to its own peak.
struct Sparkline: View {
    let values: [Float]
    let color: Color

    var body: some View {
        LiveGraph(lines: [.init(values: values, color: color)], top: Double(max(values.max() ?? 1, 1)))
    }
}
