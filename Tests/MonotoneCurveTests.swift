import XCTest
@testable import UnbraidTests

final class MonotoneCurveTests: XCTestCase {
    func testPassesThroughEveryReading() {
        let points: [(x: Double, y: Double)] = [(0, 10), (1, 30), (2, 25), (3, 80)]
        let curve = MonotoneCurve(points)
        for p in points { XCTAssertEqual(curve.value(at: p.x), p.y, accuracy: 1e-9) }
    }

    func testNeverLeavesTheReadingsOnEitherSide() {
        let values = [10.0, 200, 190, 5, 5, 300, 299, 301, 2]
        let curve = MonotoneCurve(values.enumerated().map { (x: Double($0.offset), y: $0.element) })
        for i in 0..<(values.count - 1) {
            let low = min(values[i], values[i + 1]) - 1e-9, high = max(values[i], values[i + 1]) + 1e-9
            for step in 0...100 {
                let y = curve.value(at: Double(i) + Double(step) / 100)
                XCTAssertTrue(y >= low && y <= high, "\(y) outside \(low)...\(high) after reading \(i)")
            }
        }
    }

    func testHoldsItsEndsAndCopesWithFewReadings() {
        XCTAssertEqual(MonotoneCurve([]).value(at: 3), 0)
        XCTAssertEqual(MonotoneCurve([(x: 2, y: 7)]).value(at: 9), 7)
        let two = MonotoneCurve([(x: 0, y: 0), (x: 2, y: 8)])
        XCTAssertEqual(two.value(at: -1), 0)
        XCTAssertEqual(two.value(at: 5), 8)
    }

    func testLeavesOutReadingsThatDontRise() {
        let curve = MonotoneCurve([(x: 0, y: 1), (x: 0, y: 5), (x: 1, y: 2)])
        XCTAssertEqual(curve.value(at: 0), 1)
    }

    func testCeilingsAreRoundAndAtLeastTen() {
        XCTAssertEqual(speedCeiling(0), 10)
        XCTAssertEqual(speedCeiling(3), 10)
        XCTAssertEqual(speedCeiling(11), 20)
        XCTAssertEqual(speedCeiling(21), 25)
        XCTAssertEqual(speedCeiling(26), 50)
        XCTAssertEqual(speedCeiling(251), 500)
    }
}
