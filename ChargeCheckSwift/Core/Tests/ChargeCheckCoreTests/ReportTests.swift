import XCTest
@testable import ChargeCheckCore

final class ReportTests: XCTestCase {
    private func entry(_ id: String, _ supplier: String, _ date: String, net: Double, total: Double, over: Double = 0, overVat: Double = 0,
                       excluded: Double = 0, paid: String? = nil, lines: [HistoryLine] = []) -> HistoryEntry {
        HistoryEntry(id: id, savedAt: "2026-11-09T10:00:00Z", supplier: supplier, invNo: id, date: date, net: net, total: total, over: over,
                     overVat: overVat, excluded: excluded, paid: paid, lines: lines)
    }

    private var sample: [HistoryEntry] {
        [
            entry("1", "Apex Foods", "06/11/2026", net: 100, total: 110, over: 10, overVat: 1,
                  lines: [HistoryLine(qty: 2, desc: "WINGS", unit: 20, item: "Chicken Wings", base: 15, over: 10)]),
            entry("2", "Apex Foods", "05/11/2026", net: 200, total: 200, excluded: 20,
                  lines: [HistoryLine(qty: 1, desc: "X", unit: 180), HistoryLine(qty: 1, desc: "Y", unit: 20, excluded: true)]),
            entry("3", "Waka", "04/10/2026", net: 50, total: 60, over: 5, overVat: 1),
            entry("4", "Waka", "01/05/2026", net: 10, total: 10, paid: "2026-05-02T10:00:00Z")
        ]
    }

    func testWhatToPay() {
        let all = ReportMaths.paySummary(sample, skipped: [])
        XCTAssertEqual(all.unpaid.count, 3)                 // the paid one is left out
        XCTAssertEqual(all.total, 370)
        XCTAssertEqual(all.less, 37)
        XCTAssertEqual(all.pay, 333)
        XCTAssertEqual(all.suppliers.map { $0.name }, ["Apex Foods", "Waka"])
        XCTAssertEqual(all.suppliers[0].pay, 279)
        XCTAssertTrue(all.suppliers[0].hasMissing)
        XCTAssertEqual(all.suppliers[1].pay, 54)
        let onlyWaka = ReportMaths.paySummary(sample, skipped: ["1", "2"])
        XCTAssertEqual(onlyWaka.selected.count, 1)
        XCTAssertEqual(onlyWaka.pay, 54)
        let text = ReportMaths.paymentText(onlyWaka, today: "10 Nov 2026")
        XCTAssertTrue(text.contains("Total to pay: £54.00 (invoices £60.00 less £6.00 taken off)"), text)
        XCTAssertTrue(text.contains("Invoice 3 · 04/10/2026 · £60.00 less £6.00 overcharged = £54.00"), text)
        XCTAssertEqual(ReportMaths.paySummary([], skipped: []).pay, 0)
    }

    func testCredits() throws {
        var list = sample
        list[0].credit = CreditInfo(status: CreditInfo.requested, amount: 11, at: "2026-11-06T10:00:00Z")
        list[2].credit = CreditInfo(status: CreditInfo.received, amount: 6, at: "2026-10-05T10:00:00Z", paidAt: "2026-10-20T10:00:00Z")
        XCTAssertEqual(ReportMaths.creditsOwed(list).count, 1)
        XCTAssertEqual(ReportMaths.creditsOwed(list).amount, 11)
        XCTAssertEqual(ReportMaths.creditsReceived(list).amount, 6)
        XCTAssertEqual(ReportMaths.creditsOwed(sample).count, 0)
        // the old app's backup format: a credit survives a save and a load
        let data = try JSONEncoder().encode(list[0])
        let back = try JSONDecoder().decode(HistoryEntry.self, from: data)
        XCTAssertEqual(back.credit?.status, "requested")
        XCTAssertEqual(back.credit?.amount, 11)
    }

    func testWhatToPayBeforeVat() {
        let withVat = ReportMaths.paySummary(sample, skipped: [])
        XCTAssertEqual(withVat.payBeforeVat, 315)
        XCTAssertEqual(withVat.payWithVat, 333)
        XCTAssertEqual(withVat.vat, 18)
        let net = ReportMaths.paySummary(sample, skipped: [], beforeVat: true)
        XCTAssertTrue(net.beforeVat)
        XCTAssertEqual(net.total, 350)
        XCTAssertEqual(net.less, 35)
        XCTAssertEqual(net.pay, 315)
        XCTAssertEqual(net.suppliers.map { $0.pay }, [270, 45])
        XCTAssertEqual(net.payWithVat, 333)
        let text = ReportMaths.paymentText(ReportMaths.paySummary(sample, skipped: ["1", "2"], beforeVat: true), today: "10 Nov 2026")
        XCTAssertTrue(text.contains("Invoice 3 · 04/10/2026 · £50.00 less £5.00 overcharged = £45.00"), text)
        XCTAssertTrue(text.contains("Amounts are before VAT (no VAT added)."), text)
    }

    func testPeriods() {
        let calendar = ReportMaths.ukCalendar
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9))!
        XCTAssertEqual(ReportMaths.entries(sample, in: .thisMonth, now: now).map { $0.id }, ["1", "2"])
        XCTAssertEqual(ReportMaths.entries(sample, in: .lastMonth, now: now).map { $0.id }, ["3"])
        XCTAssertEqual(ReportMaths.entries(sample, in: .thisTaxYear, now: now).count, 4)      // 6 Apr 2026 – 5 Apr 2027
        XCTAssertEqual(ReportMaths.entries(sample, in: .lastTaxYear, now: now).count, 0)
        XCTAssertEqual(ReportMaths.entries(sample, in: .all, now: now).count, 4)
        // 5 April belongs to the tax year before, 6 April starts the new one
        let fifth = calendar.date(from: DateComponents(year: 2027, month: 4, day: 5, hour: 9))!
        let sixth = calendar.date(from: DateComponents(year: 2027, month: 4, day: 6, hour: 9))!
        XCTAssertEqual(ReportMaths.entries(sample, in: .thisTaxYear, now: fifth).count, 4)
        XCTAssertEqual(ReportMaths.entries(sample, in: .thisTaxYear, now: sixth).count, 0)
        XCTAssertEqual(ReportMaths.entries(sample, in: .lastTaxYear, now: sixth).count, 4)
        // January: "last month" is December of the year before
        let january = calendar.date(from: DateComponents(year: 2027, month: 1, day: 3))!
        let range = ReportMaths.range(.lastMonth, now: january)
        XCTAssertEqual(range.map { calendar.component(.month, from: $0.start) }, 12)
        XCTAssertEqual(range.map { calendar.component(.year, from: $0.start) }, 2026)
        // an invoice with no readable date uses the day it was saved
        let undated = entry("9", "X", "", net: 1, total: 1)
        XCTAssertEqual(ReportMaths.entries([undated], in: .thisMonth, now: now).count, 1)
    }

    func testSpreadsheets() {
        let csv = ReportMaths.reportCSV(sample)
        let rows = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(rows[0], "Date,Supplier,Invoice no.,Net,Total inc VAT,Overcharged,Overcharged VAT,Missing/returned,To pay,Paid,Fully checked")
        XCTAssertEqual(rows[1], "06/11/2026,Apex Foods,1,100.00,110.00,10.00,1.00,0.00,99.00,No,Yes")
        XCTAssertEqual(rows[4], "01/05/2026,Waka,4,10.00,10.00,0.00,0.00,0.00,10.00,Yes,Yes")
        XCTAssertTrue(csv.contains("06/11/2026,Apex Foods,1,Chicken Wings,2.00,20.00,15.00,10.00"))
        // commas, quotes and formula-looking text are made safe
        XCTAssertEqual(ReportMaths.cell("Smith, Sons"), "\"Smith, Sons\"")
        XCTAssertEqual(ReportMaths.cell("10\" wrap"), "\"10\"\" wrap\"")
        XCTAssertEqual(ReportMaths.cell("=SUM(A1)"), "'=SUM(A1)")
        XCTAssertEqual(ReportMaths.cell("-5.00"), "-5.00")
        let prices = ReportMaths.pricesCSV([PriceItem(cat: "Bakery", name: "Buns", price: 6.99, supplier: "A, B", aliases: ["bun", "buns"])])
        XCTAssertTrue(prices.contains("Bakery,Buns,6.99,\"A, B\",bun; buns"))
    }

    func testCopyNames() {
        XCTAssertEqual(ReportMaths.copyName(for: sample[0]), "2026-11-06 Apex Foods 1")
        XCTAssertEqual(ReportMaths.copyName(for: entry("A/7:9", "Food*Dist/ Ltd", "6.11.26", net: 1, total: 1)), "2026-11-06 Food Dist Ltd A 7 9")
        XCTAssertEqual(ReportMaths.copyName(for: entry("", "", "", net: 1, total: 1)), "2026-11-09 Invoice")
    }

    func testCreditMessage() {
        let entry = HistoryEntry(id: "c", supplier: "Sample Foods Ltd", invNo: "81", date: "06/11/2026", net: 47.97, total: 47.97, over: 1.00,
                                 lines: [HistoryLine(qty: 2, desc: "CHICKEN WINGS", unit: 15.49, matchId: "w", base: 14.99, over: 1.00),
                                         HistoryLine(qty: 1, desc: "OIL TIN", unit: 16.99, matchId: "o", excluded: true)])
        let text = ReportMaths.creditText(entry, business: "My Shop")
        XCTAssertTrue(text.hasPrefix("Hello Sample Foods Ltd,"))
        XCTAssertTrue(text.contains("• 2 x CHICKEN WINGS – charged £15.49, agreed £14.99: £1.00"))
        XCTAssertTrue(text.contains("• 1 x OIL TIN – not received / returned: £16.99"))
        XCTAssertTrue(text.hasSuffix("Thank you,\nMy Shop"))
    }
}
