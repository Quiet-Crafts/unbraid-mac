import Foundation

/// Byte and speed formatting shared by screens and widgets (decimal units, like the Android app). Screens use only
/// this, so one number reads the same everywhere. Halves round up, and a figure that would round to 1000 moves up a
/// unit.
nonisolated enum Units {
    private static func fixed(_ x: Double, _ decimals: Int) -> String {
        let k = pow(10.0, Double(decimals))
        return String(format: "%.\(decimals)f", (x * k).rounded(.toNearestOrAwayFromZero) / k)
    }

    /// A byte count as a number and its unit, for a big figure with a small unit beside it: ("1.2", "GB").
    static func byteParts(_ b: Int64) -> (String, String) {
        let v = Double(b)
        // 999 999 bytes read 1 MB, not 1000 kB.
        if v >= 999_500_000 { return (fixed(v / 1e9, 1), "GB") }
        if v >= 999_500 { return (fixed(v / 1e6, 0), "MB") }
        return (fixed(v / 1e3, 0), "kB")
    }

    static func bytes(_ b: Int64) -> String { let p = byteParts(b); return "\(p.0) \(p.1)" }

    /// One label of a byte axis whose ticks are `step` apart and whose top tick is `ceiling`: every label shares the
    /// unit of the top one and shows as many decimals as the step needs, so 0, 0.5, 1.0, 1.5 MB never repeat.
    static func axisBytes(_ value: Double, step: Double, ceiling: Double) -> String {
        if value == 0 { return "0" }
        let (size, unit): (Double, String) = ceiling >= 1e9 ? (1e9, "GB") : ceiling >= 1e6 ? (1e6, "MB") : ceiling >= 1e3 ? (1e3, "kB") : (1, "B")
        let ratio = step / size
        let decimals = (0...3).first { abs(ratio * pow(10, Double($0)) - (ratio * pow(10, Double($0))).rounded()) < 1e-6 } ?? 3
        return "\(fixed(value / size, decimals)) \(unit)"
    }

    /// Bits per second: Mbps from 1 Mbps, kbps below.
    static func rateParts(_ bps: Double) -> (String, String) {
        if bps >= 999_500 { return (mbps(bps), "Mbps") }
        if bps >= 100 { return (fixed(bps / 1e3, 0), "kbps") }
        return ("0", "kbps")
    }

    static func rate(_ bps: Double) -> String { let p = rateParts(bps); return "\(p.0) \(p.1)" }

    static func mbps(_ bps: Double) -> String {
        let m = bps / 1e6
        return m >= 99.95 ? String(max(Int(m), 100)) : String(format: "%.1f", m)
    }

    /// A measured speed (speed test): Mbps, and Gbps from 1000 Mbps for every reading alike.
    static func speed(_ bps: Double) -> (String, String) {
        bps >= 1e9 ? (fixed(bps / 1e9, 2), "Gbps") : (mbps(bps), "Mbps")
    }
}
