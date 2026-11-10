import Foundation

/// A smooth line through readings that never overshoots them (monotone cubic, Fritsch and Carlson): between two readings
/// it stays between their values, so a graph can't show a speed that was never measured.
nonisolated struct MonotoneCurve: Sendable {
    private var xs: [Double] = []
    private var ys: [Double] = []
    private var slopes: [Double] = []

    /// `points` in rising x; ones that don't rise are left out.
    init(_ points: [(x: Double, y: Double)]) {
        for p in points where p.x > (xs.last ?? -.infinity) { xs.append(p.x); ys.append(p.y) }
        let n = xs.count
        guard n > 1 else { slopes = Array(repeating: 0, count: n); return }
        var steps: [Double] = []
        for i in 0..<(n - 1) {
            let rise: Double = ys[i + 1] - ys[i], run: Double = xs[i + 1] - xs[i]
            steps.append(rise / run)
        }
        slopes = Array(repeating: 0, count: n)
        slopes[0] = steps[0]
        slopes[n - 1] = steps[n - 2]
        for i in stride(from: 1, to: n - 1, by: 1) {
            let before: Double = steps[i - 1], after: Double = steps[i]
            slopes[i] = before * after <= 0 ? 0 : (before + after) / 2
        }
        for i in 0..<(n - 1) {
            if steps[i] == 0 { slopes[i] = 0; slopes[i + 1] = 0; continue }
            let a: Double = slopes[i] / steps[i], b: Double = slopes[i + 1] / steps[i]
            let reach: Double = a * a + b * b
            if reach > 9 {
                let k: Double = 3 / reach.squareRoot()
                slopes[i] = k * a * steps[i]
                slopes[i + 1] = k * b * steps[i]
            }
        }
    }

    var first: Double? { xs.first }
    var last: Double? { xs.last }

    /// The curve at `x`, held at the ends.
    func value(at x: Double) -> Double {
        guard let start = xs.first, let end = xs.last else { return 0 }
        if x <= start { return ys[0] }
        if x >= end { return ys[ys.count - 1] }
        var low = 0, high = xs.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if xs[middle] <= x { low = middle } else { high = middle }
        }
        let h: Double = xs[high] - xs[low], t: Double = (x - xs[low]) / h, t2: Double = t * t, t3: Double = t2 * t
        let fromLow: Double = (2 * t3 - 3 * t2 + 1) * ys[low] + (t3 - 2 * t2 + t) * h * slopes[low]
        let fromHigh: Double = (-2 * t3 + 3 * t2) * ys[high] + (t3 - t2) * h * slopes[high]
        return fromLow + fromHigh
    }
}

/// The top of a speed graph: the smallest of 1, 2, 2.5, 5 and 10 times a power of ten that holds `x`, at least 10.
nonisolated func speedCeiling(_ x: Double) -> Double {
    guard x > 0 else { return 10 }
    let p = pow(10, floor(log10(x)))
    return max(10, [1, 2, 2.5, 5, 10].map { $0 * p }.first { $0 >= 0.999 * x } ?? 10 * p)
}
