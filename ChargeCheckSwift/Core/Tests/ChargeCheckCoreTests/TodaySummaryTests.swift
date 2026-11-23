import XCTest
@testable import ChargeCheckCore

final class TodaySummaryTests: XCTestCase {
    private func level(_ name: String, onHand: Double, low: Double?) -> StockLevel {
        StockLevel(itemID: name, name: name, supplier: "Bookers", onHand: onHand, low: low, counted: true, delivered: 0, sold: 0)
    }

    func testLowStockShowsTheShortestFirstAndCountsTheRest() {
        let levels = [level("Cola", onHand: 3, low: 12), level("Crisps", onHand: 10, low: 10), level("Water", onHand: 40, low: 12),
                      level("Bread", onHand: 0, low: 5), level("Milk", onHand: 1, low: 4), level("Tea", onHand: 2, low: nil)]
        let today = TodaySummary(sales: 4, refunds: 0, takings: 52.4, cash: 20, card: 32.4, other: 0, levels: levels)
        XCTAssertEqual(today.lowCount, 4, "at or below the level counts; no level set doesn't")
        XCTAssertEqual(today.low.map(\.name), ["Cola", "Bread", "Milk"], "9 short, 5 short, 3 short")
        XCTAssertFalse(today.quiet)
    }

    func testANewDay() {
        let today = TodaySummary(sales: 0, refunds: 0, takings: 0, cash: 0, card: 0, other: 0, levels: [])
        XCTAssertTrue(today.quiet)
        XCTAssertEqual(today.lowCount, 0)
    }
}
