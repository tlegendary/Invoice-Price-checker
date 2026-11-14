import XCTest
@testable import ChargeCheckCore

final class PriceRiseTests: XCTestCase {
    private func entry(_ id: String, _ supplier: String, _ savedAt: String, _ lines: [HistoryLine]) -> HistoryEntry {
        HistoryEntry(id: id, savedAt: savedAt, supplier: supplier, invNo: id, date: "", net: 0, total: 0, over: 0, lines: lines)
    }

    private func line(_ name: String, _ unit: Double, id: String? = nil) -> HistoryLine {
        HistoryLine(qty: 1, desc: name, unit: unit, matchId: id, item: name)
    }

    private var history: [HistoryEntry] {
        [
            entry("1", "Apex Foods", "2026-10-01T09:00:00Z", [line("Wings", 14, id: "w"), line("Oil", 30)]),
            entry("2", "Bravo", "2026-10-03T09:00:00Z", [line("Wings", 20, id: "w")]),
            entry("3", "APEX FOODS LTD", "2026-10-20T09:00:00Z", [line("Wings", 15.12, id: "w"), line("Oil", 30.05)]),
            entry("4", "Apex Foods", "2026-11-05T09:00:00Z", [line("Wings", 15.12, id: "w"), line("Oil", 29)])
        ]
    }

    func testRisesAgainstTheSameSupplierOnly() {
        let rises = Insights.priceRises(history)
        // Bravo's 20 isn't a rise on Apex's 14; oil +0.17% is rounding; wings 14 → 15.12 is +8%
        XCTAssertEqual(rises.count, 1)
        XCTAssertEqual(rises[0].item, "Wings")
        XCTAssertEqual(rises[0].supplier, "APEX FOODS LTD")
        XCTAssertEqual(rises[0].from, 14)
        XCTAssertEqual(rises[0].to, 15.12)
        XCTAssertEqual(rises[0].percent, 8, accuracy: 0.001)
        XCTAssertEqual(rises[0].invoiceID, "3")
        XCTAssertTrue(Insights.priceRises(history, since: "2026-11-01").isEmpty)
    }

    func testRisesOnANewInvoice() {
        let lines = [CheckLine(qty: 2, desc: "Wings", unit: 16, matchId: "w"), CheckLine(qty: 1, desc: "Oil", unit: 29),
                     CheckLine(qty: 1, desc: "Ketchup", unit: 9)]
        let rises = Insights.priceRises(on: lines, supplier: "Apex Foods", history: history, excluding: "new")
        XCTAssertEqual(rises.map { $0.item }, ["Wings"])
        XCTAssertEqual(rises[0].from, 15.12)
        XCTAssertEqual(rises[0].before, "2026-11-05T09:00:00Z")
        XCTAssertTrue(Insights.priceRises(on: lines, supplier: "Waka", history: history, excluding: "new").isEmpty)
    }
}
