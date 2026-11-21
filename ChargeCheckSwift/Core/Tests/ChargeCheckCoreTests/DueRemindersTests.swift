import XCTest
@testable import ChargeCheckCore

final class DueRemindersTests: XCTestCase {
    private func due(_ supplier: String, _ amount: Double, _ day: String, _ left: Int) -> DueInvoice {
        DueInvoice(supplier: supplier, entry: HistoryEntry(supplier: supplier, net: amount, total: amount, over: 0, lines: []),
                   amount: amount, dueDate: day, daysLeft: left)
    }

    func testOneReminderPerDayWithTheTotal() {
        let plan = DueReminders.plan([due("APEX", 100.10, "2026-11-20", 6), due("Brakes", 200.20, "2026-11-20", 6),
                                      due("APEX", 50, "2026-11-25", 11)], currencyOf: { _ in "GBP" })
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].day, "2026-11-20")
        XCTAssertEqual(plan[0].count, 2)
        XCTAssertEqual(plan[0].amount, 300.30)
        XCTAssertEqual(plan[0].suppliers, ["Brakes", "APEX"])
    }

    func testOverdueAndFarOffAreLeftOut() {
        let plan = DueReminders.plan([due("APEX", 10, "2026-11-01", -13), due("APEX", 10, "2026-12-30", 46), due("APEX", 0, "2026-11-15", 1)],
                                     currencyOf: { _ in "GBP" })
        XCTAssertTrue(plan.isEmpty)
    }

    func testCurrenciesAreNeverAddedTogether() {
        let plan = DueReminders.plan([due("APEX", 10, "2026-11-20", 6), due("Baghdad Foods", 25000, "2026-11-20", 6)],
                                     currencyOf: { $0.supplier == "APEX" ? "GBP" : "IQD" })
        XCTAssertEqual(plan.first?.count, 2)
        XCTAssertNil(plan.first?.amount)
    }
}

final class WrittenOffCreditTests: XCTestCase {
    func testWrittenOffIsNeitherOwedNorWonBack() {
        var a = HistoryEntry(supplier: "APEX", net: 10, total: 12, over: 3, lines: [])
        a.credit = CreditInfo(status: CreditInfo.writtenOff, amount: 3)
        var b = HistoryEntry(supplier: "APEX", net: 10, total: 12, over: 2, lines: [])
        b.credit = CreditInfo(status: CreditInfo.requested, amount: 2)
        XCTAssertFalse(a.credit!.isOwed)
        XCTAssertEqual(ReportMaths.creditsOwed([a, b]).amount, 2)
        XCTAssertEqual(ReportMaths.creditsReceived([a, b]).count, 0)
        XCTAssertEqual(ReportMaths.creditsWrittenOff([a, b]).amount, 3)
    }
}
