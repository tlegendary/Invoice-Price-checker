import XCTest
@testable import ChargeCheckCore

final class PriceToolsTests: XCTestCase {
    func testHistoryIsOldestFirstAndSkipsMissingItems() {
        let entries = [
            HistoryEntry(id: "b", supplier: "Apex", invNo: "2", date: "06/11/2026", net: 0, total: 0, over: 0,
                         lines: [HistoryLine(qty: 2, desc: "WINGS", unit: 16, matchId: "w"), HistoryLine(qty: 1, desc: "OIL", unit: 20, matchId: "o")]),
            HistoryEntry(id: "a", supplier: "Waka", invNo: "1", date: "01/10/2026", net: 0, total: 0, over: 0,
                         lines: [HistoryLine(qty: 1, desc: "WINGS", unit: 15, matchId: "w"), HistoryLine(qty: 1, desc: "WINGS", unit: 15, matchId: "w", excluded: true)])
        ]
        let points = PriceTools.history(of: "w", in: entries)
        XCTAssertEqual(points.map { $0.unit }, [15, 16])
        XCTAssertEqual(points.map { $0.supplier }, ["Waka", "Apex"])
        XCTAssertTrue(PriceTools.history(of: "none", in: entries).isEmpty)
    }

    func testCheaperPricesNeverRiseAndNeedASureLine() {
        var wings = PriceItem(id: "w", name: "Chicken Wings", price: 15)
        wings.sp = [SupplierPrice(s: "Apex Foods", p: 14)]
        let oil = PriceItem(id: "o", name: "Oil", price: 20)
        let book = PriceBook([wings, oil])
        let invoice = InvoiceDraft(supplier: "Apex Foods", lines: [
            CheckLine(qty: 1, desc: "WINGS", unit: 13.5, matchId: "w", confident: true),
            CheckLine(qty: 1, desc: "WINGS", unit: 13, matchId: "w", confident: true),
            CheckLine(qty: 1, desc: "OIL", unit: 25, matchId: "o", confident: true),
            CheckLine(qty: 1, desc: "OIL", unit: 18, matchId: "o", confident: false),
            CheckLine(qty: 1, desc: "NEW", unit: 1, confident: nil)
        ])
        let changes = PriceTools.cheaper(in: invoice, book: book)
        XCTAssertEqual(changes, [PriceChange(itemID: "w", name: "Chicken Wings", from: 14, to: 13)])

        let lowered = PriceTools.setting(13, on: wings, supplier: "Apex Foods")
        XCTAssertEqual(lowered.price, 15)
        XCTAssertEqual(lowered.sp.first?.p, 13)
        XCTAssertEqual(PriceTools.setting(18, on: oil, supplier: "Apex Foods").price, 18)
    }

    func testSpreadsheetLists() {
        let rows = PriceListText.parse("Item,Price\nChicken Wings 10kg,15.00\n\"Oil, vegetable 20L\",£22.50\nFries 2.5kg;9,99\n")
        XCTAssertEqual(rows.map { $0.price }, [15, 22.5, 9.99])
        XCTAssertEqual(rows.first?.name, "Chicken Wings 10kg")
    }
}
