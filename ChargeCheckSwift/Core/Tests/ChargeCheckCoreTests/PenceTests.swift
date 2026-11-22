import XCTest
@testable import ChargeCheckCore

final class PenceTests: XCTestCase {
    func testPoundsToPence() {
        XCTAssertEqual(Pence(12.99)?.value, 1299)
        XCTAssertEqual(Pence(0.1 + 0.2)?.value, 30, "the classic 0.30000000000000004")
        XCTAssertEqual(Pence(2.675)?.value, 268, "a half penny rounds away from zero, as Money.round2")
        XCTAssertEqual(Pence(-2.675)?.value, -268)
        XCTAssertNil(Pence(.nan))
        XCTAssertNil(Pence(.infinity))
        XCTAssertEqual(Pence(value: 1299).pounds, 12.99)
    }

    func testTotalsAreExact() {
        // 10,000 lots of 10p: floating point drifts, pence don't
        let tenPences = [Double](repeating: 0.1, count: 10_000)
        XCTAssertNotEqual(tenPences.reduce(0, +), 1000, "plain adding drifts")
        XCTAssertEqual(tenPences.pennySum { $0 }, 1000)
        XCTAssertEqual([19.99, 0.01, -5.5].pennySum { $0 }, 14.5)
        XCTAssertEqual([Double]().pennySum { $0 }, 0)
    }

    func testABadFigureIsNeverLeftOutQuietly() {
        XCTAssertTrue([10, .nan, 5].pennySum { $0 }.isNaN)
    }

    func testOrderDoesntMatter() {
        var rng = SystemRandomNumberGenerator()
        let amounts = (0..<2_000).map { _ in Double(Int.random(in: -50_000...500_000, using: &rng)) / 100 }
        XCTAssertEqual(amounts.pennySum { $0 }, amounts.shuffled().pennySum { $0 })
        XCTAssertEqual(amounts.pennySum { $0 }, amounts.reversed().pennySum { $0 })
    }
}
