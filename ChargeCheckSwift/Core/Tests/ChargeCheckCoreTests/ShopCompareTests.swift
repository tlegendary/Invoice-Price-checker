import XCTest
@testable import ChargeCheckCore

final class ShopCompareTests: XCTestCase {
    private func entry(_ id: String, shop: String, supplier: String, savedAt: String, total: Double, over: Double = 0,
                       credit: CreditInfo? = nil) -> HistoryEntry {
        HistoryEntry(id: id, savedAt: savedAt, shopId: shop, supplier: supplier, invNo: id, date: "", net: total, total: total,
                     over: over, credit: credit, lines: [])
    }

    func testShopsSideBySide() {
        let shops = [ShopInfo(id: "a", name: "High St"), ShopInfo(id: "b", name: "Market"), ShopInfo(id: "c", name: "New shop")]
        let entries = [
            entry("1", shop: "a", supplier: "Apex", savedAt: "2026-11-02T10:00:00Z", total: 100, over: 10,
                  credit: CreditInfo(status: CreditInfo.requested, amount: 10)),
            entry("2", shop: "a", supplier: "Bravo", savedAt: "2026-11-03T10:00:00Z", total: 300),
            entry("3", shop: "b", supplier: "Apex", savedAt: "2026-11-04T10:00:00Z", total: 50, over: 5,
                  credit: CreditInfo(status: CreditInfo.received, amount: 5)),
            entry("4", shop: "gone", supplier: "Apex", savedAt: "2026-11-05T10:00:00Z", total: 20),
            entry("5", shop: "b", supplier: "Apex", savedAt: "2026-10-01T10:00:00Z", total: 999)
        ]
        let rows = Insights.compareShops(entries, shops: shops, since: "2026-11-01")
        XCTAssertEqual(rows.map { $0.name }, ["High St", "Market", "No shop", "New shop"])
        XCTAssertEqual(rows[0].invoices, 2)
        XCTAssertEqual(rows[0].spent, 400)
        XCTAssertEqual(rows[0].overcharged, 10)
        XCTAssertEqual(rows[0].overchargedPercent, 2.5, accuracy: 0.0001)
        XCTAssertEqual(rows[0].creditsOwed, 10)
        XCTAssertEqual(rows[0].topSupplier, "Bravo")
        XCTAssertEqual(rows[1].creditsReceived, 5)
        XCTAssertEqual(rows[1].spent, 50)
        XCTAssertEqual(rows[2].spent, 20)
        XCTAssertEqual(rows[3].invoices, 0)
        // a closed range
        XCTAssertEqual(Insights.compareShops(entries, shops: shops, since: "2026-10-01", until: "2026-11-01")
            .first { $0.id == "b" }?.spent, 999)
    }
}
