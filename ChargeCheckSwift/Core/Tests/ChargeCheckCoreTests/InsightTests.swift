import XCTest
@testable import ChargeCheckCore

final class InsightTests: XCTestCase {
    private func line(_ name: String, qty: Double, unit: Double, id: String? = nil, short: Double = 0) -> HistoryLine {
        HistoryLine(qty: qty, desc: name, unit: unit, matchId: id, item: name, short: short)
    }

    private func entry(_ id: String, _ supplier: String, _ savedAt: String, _ lines: [HistoryLine], shop: String = "") -> HistoryEntry {
        let net = lines.reduce(0) { $0 + $1.qty * $1.unit }
        return HistoryEntry(id: id, savedAt: savedAt, shopId: shop, supplier: supplier, invNo: id, date: "", net: net, total: net, lines: lines)
    }

    private let now = SupplierAccounts.day("2026-11-12")!

    func testCheaperSupplier() {
        let entries = [
            entry("1", "Apex Foods", "2026-11-10T09:00:00Z", [line("Chicken wings 10kg", qty: 4, unit: 15.40, id: "w")]),
            entry("2", "Bravo", "2026-10-20T09:00:00Z", [line("Chicken wings 10kg", qty: 1, unit: 14.20, id: "w")]),
            entry("3", "Apex Foods", "2026-11-01T09:00:00Z", [line("Chicken wings 10kg", qty: 2, unit: 15.00, id: "w"),
                                                              line("Oil 20L", qty: 1, unit: 30, id: "o")]),
            entry("4", "Bravo", "2026-11-02T09:00:00Z", [line("Oil 20L", qty: 1, unit: 32, id: "o")])
        ]
        let tips = Insights.supplierTips(entries, now: now)
        // oil: Bravo was last and dearer than Apex's 30, so it's a tip; wings: Apex last at 15.40, Bravo 14.20
        XCTAssertEqual(tips.count, 2)
        XCTAssertEqual(tips[0].item, "Chicken wings 10kg")
        XCTAssertEqual(tips[0].cheapest.supplier, "Bravo")
        XCTAssertEqual(tips[0].lastSupplier, "Apex Foods")
        XCTAssertEqual(tips[0].savingEach, 1.20)
        XCTAssertEqual(tips[0].boughtLately, 7)
        XCTAssertEqual(tips[0].savingMonth, 8.40)
        XCTAssertEqual(tips[1].item, "Oil 20L")
        XCTAssertEqual(tips[1].cheapest.supplier, "Apex Foods")
    }

    func testNoTipWhenYouAlreadyUseTheCheapest() {
        let entries = [
            entry("1", "Bravo", "2026-11-10T09:00:00Z", [line("Oil 20L", qty: 1, unit: 30)]),
            entry("2", "Apex", "2026-11-01T09:00:00Z", [line("Oil 20L", qty: 1, unit: 31)])
        ]
        XCTAssertTrue(Insights.supplierTips(entries, now: now).isEmpty)
    }

    func testMonthSummary() {
        let entries = [
            entry("1", "Apex Foods", "2026-09-28T09:00:00Z", [line("Wings", qty: 2, unit: 14, id: "w")]),
            entry("2", "Apex Foods", "2026-10-05T09:00:00Z", [line("Wings", qty: 2, unit: 15, id: "w")], shop: "s1"),
            entry("3", "Bravo", "2026-10-09T09:00:00Z", [line("Oil", qty: 1, unit: 35, id: "o")], shop: "s2")
        ]
        var withOver = entries
        withOver[1].over = 2
        let payments = [SupplierPayment(supplier: "Apex Foods", amount: 20, date: "2026-10-12")]
        let s = Insights.month("2026-10", entries: withOver, payments: payments,
                               shops: [ShopInfo(id: "s1", name: "High St"), ShopInfo(id: "s2", name: "Market")])
        XCTAssertEqual(s.invoices, 2)
        XCTAssertEqual(s.spent, 65)
        XCTAssertEqual(s.overcharged, 2)
        XCTAssertEqual(s.bySupplier.first?.name, "Bravo")
        XCTAssertEqual(s.byShop.first?.name, "Market")
        XCTAssertEqual(s.rises, [MonthSummary.Rise(item: "Wings", supplier: "Apex Foods", from: 14, to: 15)])
        XCTAssertEqual(s.paid, 20)
        XCTAssertEqual(s.owedNow, 71)       // 28 + 28 + 35 − 20
        let text = Insights.sentences(s, monthName: "October")
        XCTAssertEqual(text.first, "In October you checked 2 invoices worth £65.00.")
        XCTAssertTrue(text.contains("You were overcharged £2.00 in total, £2.00 of it by Apex Foods."))
        XCTAssertTrue(text.contains("Wings went up at Apex Foods, from £14.00 to £15.00."))
        XCTAssertEqual(Insights.sentences(Insights.month("2026-01", entries: entries, payments: []), monthName: "January"),
                       ["No invoices were checked in January."])
    }

    func testShortDelivery() {
        var draft = InvoiceDraft(supplier: "Apex", invNo: "1")
        draft.lines = [CheckLine(qty: 10, desc: "Wings", unit: 15, vat: 20, short: 3), CheckLine(qty: 1, desc: "Oil", unit: 30)]
        let totals = InvoiceMaths.totals(draft, book: PriceBook([]))
        XCTAssertEqual(totals.excluded, 45)
        let entry = InvoiceMaths.historyEntry(draft, book: PriceBook([]))
        XCTAssertEqual(entry.lines[0].short, 3)
        XCTAssertEqual(entry.lines[0].qty, 10)
        // 150 + 30 VAT + 30 = 210; less 45 + 9 VAT
        XCTAssertEqual(entry.amountToPay.total, 210)
        XCTAssertEqual(entry.amountToPay.less, 54)
        XCTAssertTrue(ReportMaths.creditText(entry, business: "").contains("3 x Wings – not received / returned: £45.00"))
        let back = try! JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(back.lines[0].short, 3)
    }

    func testCreditNotes() {
        XCTAssertTrue(Insights.isCreditNote("APEX FOODS LTD\nCREDIT NOTE 4471\nTotal 12.00"))
        XCTAssertTrue(Insights.isCreditNote("Gutschrift Nr. 88"))
        XCTAssertFalse(Insights.isCreditNote("INVOICE 4471 Total 12.00"))
        var asked = entry("1", "Apex Foods", "2026-11-01T09:00:00Z", [line("Wings", qty: 1, unit: 10)])
        asked.credit = CreditInfo(status: CreditInfo.requested, amount: 12)
        let other = entry("2", "Apex Foods", "2026-11-02T09:00:00Z", [line("Oil", qty: 1, unit: 10)])
        XCTAssertEqual(Insights.creditMatch(supplier: "APEX FOODS LTD", amount: 12, in: [asked, other])?.id, "1")
        XCTAssertNil(Insights.creditMatch(supplier: "Apex Foods", amount: 50, in: [asked, other]))
        XCTAssertNil(Insights.creditMatch(supplier: "Bravo", amount: 12, in: [asked, other]))
    }

    func testPaymentDetails() throws {
        let payment = SupplierPayment(supplier: "Apex", amount: 100, date: "2026-11-12", method: "transfer", reference: "TX-991", receipt: "r1.jpg")
        let back = try JSONDecoder().decode(SupplierPayment.self, from: JSONEncoder().encode(payment))
        XCTAssertEqual(back.method, "transfer")
        XCTAssertEqual(back.reference, "TX-991")
        XCTAssertEqual(back.receipt, "r1.jpg")
        let old = try JSONDecoder().decode(SupplierPayment.self, from: Data(#"{"supplier":"Apex","amount":5,"date":"2026-11-01"}"#.utf8))
        XCTAssertEqual(old.method, "")
        XCTAssertNil(old.receipt)
    }
}
