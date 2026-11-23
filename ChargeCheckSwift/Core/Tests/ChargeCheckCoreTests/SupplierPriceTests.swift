import XCTest
@testable import ChargeCheckCore

final class SupplierPriceTests: XCTestCase {
    private let items = [
        PriceItem(id: "w", name: "Wings 10kg", price: 15, sp: [SupplierPrice(s: "Apex Foods Ltd", p: 14.5)]),
        PriceItem(id: "o", name: "Oil 20L", price: 30),
        PriceItem(id: "b", name: "Boxes", price: 20, sp: [SupplierPrice(s: "Bravo", p: 19), SupplierPrice(s: "APEX FOODS", p: 21)])
    ]

    func testRowsForASupplier() {
        let rows = SupplierPrices.rows(for: "Apex Foods", items: items)
        XCTAssertEqual(rows.map { $0.item.id }, ["b", "w"])
        XCTAssertEqual(rows.first?.special, 21)
        XCTAssertEqual(rows.first?.difference, 1)
        XCTAssertEqual(rows.last?.difference, -0.5)
        XCTAssertEqual(SupplierPrices.count(for: "Bravo", items: items), 1)
        XCTAssertEqual(SupplierPrices.count(for: "Waka", items: items), 0)
    }

    func testSettingAndRemoving() {
        let oil = SupplierPrices.set(28.499, for: "Bravo", on: items[1])
        XCTAssertEqual(oil.sp, [SupplierPrice(s: "Bravo", p: 28.5)])
        XCTAssertEqual(oil.basePrice(for: "Bravo"), 28.5)
        XCTAssertEqual(oil.basePrice(for: "Apex"), 30)
        // replacing keeps one price per supplier
        let again = SupplierPrices.set(27, for: "bravo", on: oil)
        XCTAssertEqual(again.sp, [SupplierPrice(s: "bravo", p: 27)])
        let gone = SupplierPrices.set(nil, for: "Apex Foods", on: items[2])
        XCTAssertEqual(gone.sp, [SupplierPrice(s: "Bravo", p: 19)])
    }
}
