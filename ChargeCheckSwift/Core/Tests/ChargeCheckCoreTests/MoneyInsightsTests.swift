import XCTest
@testable import ChargeCheckCore

final class MoneyInsightsTests: XCTestCase {
    private func entry(_ supplier: String, _ date: String, net: Double, total: Double, lines: [HistoryLine] = [], currency: String = "GBP") -> HistoryEntry {
        HistoryEntry(supplier: supplier, invNo: "1", date: date, net: net, total: total, over: 0, lines: lines, currency: currency)
    }
    private func line(_ id: String?, _ name: String, qty: Double, unit: Double, short: Double = 0, excluded: Bool = false) -> HistoryLine {
        HistoryLine(qty: qty, desc: name, unit: unit, matchId: id, item: name, excluded: excluded, short: short)
    }
    private func day(_ text: String) -> Date { SupplierAccounts.day(text)!.addingTimeInterval(12 * 3600) }

    func testVATByQuarterAndSupplier() {
        var twice = entry("APEX", "15/08/2026", net: 100, total: 120)
        twice.duplicateOf = "x"
        let quarters = VATSummary.quarters([
            entry("APEX", "05/07/2026", net: 100, total: 120),
            entry("Brakes", "30/09/2026", net: 50, total: 60),
            entry("APEX", "01/10/2026", net: 10, total: 12),
            entry("Baghdad", "05/07/2026", net: 1000, total: 1200, currency: "IQD"),
            twice,
        ], currency: "GBP", currencyOf: { $0.currency ?? "GBP" })
        XCTAssertEqual(quarters.map(\.id), ["2026-Q4", "2026-Q3"])
        XCTAssertEqual(quarters[1].vat, 30)
        XCTAssertEqual(quarters[1].invoices, 2)
        XCTAssertEqual(quarters[1].bySupplier.map(\.name), ["APEX", "Brakes"])
        let csv = VATSummary.csv([entry("APEX", "05/07/2026", net: 100, total: 120)], quarter: quarters[1], currency: "GBP", currencyOf: { _ in "GBP" })
        XCTAssertTrue(csv.contains("05/07/2026,APEX,1,100.00,20.00,120.00"), csv)
    }

    func testSpendingByCategoryThisMonthAndLast() {
        let items = [PriceItem(id: "m", cat: "Meat", name: "Chicken", price: 10, supplier: ""), PriceItem(id: "p", cat: "Packaging", name: "Box", price: 5, supplier: "")]
        let result = Spending.byCategory([
            entry("APEX", "10/11/2026", net: 0, total: 0, lines: [line("m", "Chicken", qty: 3, unit: 10), line("p", "Box", qty: 2, unit: 5, excluded: true),
                                                                  line(nil, "Mystery", qty: 1, unit: 4)]),
            entry("APEX", "10/10/2026", net: 0, total: 0, lines: [line("m", "Chicken", qty: 2, unit: 10, short: 1)]),
        ], items: items, other: "Other", now: day("2026-11-15"))
        XCTAssertEqual(result.first?.category, "Meat")
        XCTAssertEqual(result.first?.thisMonth, 30)
        XCTAssertEqual(result.first?.lastMonth, 10)
        XCTAssertEqual(result.first?.change, 200)
        XCTAssertEqual(result.first { $0.category == "Other" }?.thisMonth, 4)
        XCTAssertNil(result.first { $0.category == "Packaging" }, "missing lines aren't spend")
    }

    func testBudgets() {
        let items = [PriceItem(id: "m", cat: "Meat", name: "Chicken", price: 10, supplier: "")]
        let status = BudgetMaths.status([Budget(kind: .category, name: "meat", monthly: 100), Budget(kind: .supplier, name: "Apex", monthly: 500)],
                                        entries: [entry("APEX", "10/11/2026", net: 85, total: 102, lines: [line("m", "Chicken", qty: 8.5, unit: 10)])],
                                        items: items, other: "Other", now: day("2026-11-15"))
        XCTAssertEqual(status.first?.budget.kind, .category)
        XCTAssertEqual(status.first?.percent, 85)
        XCTAssertTrue(status.first!.warning)
        XCTAssertFalse(status.first!.over)
        XCTAssertEqual(status.last?.spent, 102)
    }

    func testYearlyCostOfARise() {
        let entries = (0..<6).map { n in entry("APEX", String(format: "%02d/11/2026", n + 1), net: 0, total: 0, lines: [line("c", "Chicken 9kg", qty: 2, unit: 49.5)]) }
        let rise = PriceRise(item: "Chicken 9kg", supplier: "APEX", from: 47.5, to: 49.5, when: "2026-11-06", before: "2026-10-01", invoiceID: "x")
        // 12 cases in 90 days → 48.7 a year × £2
        XCTAssertEqual(RiseCost.yearly(rise, entries: entries, now: day("2026-11-15")), 97.33)
        XCTAssertNil(RiseCost.yearly(rise, entries: [], now: day("2026-11-15")))
    }

    func testUnitPrices() {
        XCTAssertEqual(UnitPrices.of(name: "Chicken Breast 9kg", price: 45), UnitPrice(value: 5, unit: .kg))
        XCTAssertEqual(UnitPrices.of(name: "Quarter Pounder 48x113g", price: 38.40)?.unit, .kg)
        XCTAssertEqual(UnitPrices.of(name: "Quarter Pounder 48x113g", price: 38.40)?.value, 7.08)
        XCTAssertEqual(UnitPrices.of(name: "Oil 20L", price: 30), UnitPrice(value: 1.5, unit: .litre))
        XCTAssertEqual(UnitPrices.of(name: "Cola 24x330ml", price: 7.92), UnitPrice(value: 1, unit: .litre))
        XCTAssertEqual(UnitPrices.of(name: "Cups 4x50", price: 10), UnitPrice(value: 0.05, unit: .each))
        XCTAssertNil(UnitPrices.of(name: "Mayo", price: 10))
    }

    func testCreditSpeed() {
        var a = entry("APEX", "01/11/2026", net: 0, total: 0)
        a.credit = CreditInfo(status: CreditInfo.received, amount: 5, at: "2026-11-01T10:00:00Z", paidAt: "2026-11-05T10:00:00Z")
        var b = entry("APEX", "01/10/2026", net: 0, total: 0)
        b.credit = CreditInfo(status: CreditInfo.requested, amount: 5, at: "2026-10-01T10:00:00Z")
        let speed = CreditSpeeds.of([a, b], now: day("2026-11-15"))
        XCTAssertEqual(speed.averageDays, 4)
        XCTAssertEqual(speed.late, 1)
    }

    func testDealsEnding() {
        let ending = DealDates.ending(["APEX": "2026-11-20", "Brakes": "2027-03-01", "Bookers": "2026-11-10", "Old": "2026-01-01"], now: day("2026-11-15"))
        XCTAssertEqual(ending.map(\.supplier), ["Bookers", "APEX"])
        XCTAssertEqual(ending.map(\.daysLeft), [-5, 5])
    }

    func testBigItemsWithCheaperElsewhere() {
        let now = day("2026-11-15")
        let entries = [
            entry("APEX", "05/11/2026", net: 0, total: 0, lines: [line("c", "Chicken 9kg", qty: 3, unit: 50), line("b", "Box", qty: 1, unit: 5)]),
            entry("Brakes", "06/11/2026", net: 0, total: 0, lines: [line("c", "Chicken 9kg", qty: 1, unit: 46)]),
        ]
        let big = BigItems.of(supplier: "APEX", entries: entries, now: now)
        XCTAssertEqual(big.first?.name, "Chicken 9kg")
        XCTAssertEqual(big.first?.yearlyQuantity, 12)
        XCTAssertEqual(big.first?.cheapestElsewhere, 46)
        XCTAssertEqual(big.first?.elsewhereSupplier, "Brakes")
        XCTAssertNil(big.last?.cheapestElsewhere)
    }
}
