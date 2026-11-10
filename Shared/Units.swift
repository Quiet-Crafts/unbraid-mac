import Foundation

/// Byte and speed formatting shared by screens and widgets (decimal units, like the Android app).
nonisolated enum Units {
    static func bytes(_ b: Int64) -> String {
        let v = Double(b)
        // A figure that would round to 1000 moves up a unit: 999 999 bytes read 1 MB, not 1000 kB.
        if v >= 999_500_000 { return String(format: "%.1f GB", v / 1e9) }
        if v >= 999_500 { return String(format: "%.0f MB", v / 1e6) }
        return String(format: "%.0f kB", v / 1e3)
    }

    /// Bits per second: Mbps from 1 Mbps, kbps below.
    static func rate(_ bps: Double) -> String {
        if bps >= 999_500 { return mbps(bps) + " Mbps" }
        if bps >= 100 { return String(format: "%.0f kbps", max(0.1, bps / 1e3)) }
        return "0 kbps"
    }

    static func mbps(_ bps: Double) -> String {
        let m = bps / 1e6
        return m >= 99.95 ? String(max(Int(m), 100)) : String(format: "%.1f", m)
    }
}
