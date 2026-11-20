import XCTest
@testable import ChargeCheckCore

final class SavingsSplitTests: XCTestCase {
    /// £10 overcharged on a £100 invoice with no VAT.
    private func caught(paid: Bool = false, credit: CreditInfo? = nil) -> HistoryEntry {
        HistoryEntry(supplier: "Apex", net: 100, total: 100, over: 10, paid: paid ? "2026-11-10T10:00:00Z" : nil, credit: credit, lines: [])
    }

    func testOnlyMoneyActuallyKeptCountsAsSecured() {
        let s = OverviewMaths.savings([
            caught(paid: true),                                                        // paid £90: £10 kept
            caught(),                                                                  // not paid yet
            caught(credit: CreditInfo(status: CreditInfo.received, amount: 6)),        // asked back, only £6 came
            caught(credit: CreditInfo(status: CreditInfo.requested, amount: 10)),      // still waiting
            caught(credit: CreditInfo(status: CreditInfo.writtenOff, amount: 10)),     // supplier refused
            HistoryEntry(supplier: "Apex", net: 50, total: 50, over: 0, paid: "2026-11-10T10:00:00Z", lines: [])
        ])
        XCTAssertEqual(s.total, 50)
        XCTAssertEqual(s.secured, 16)
        XCTAssertEqual(s.pending, 24)
        XCTAssertEqual(s.writtenOff, 10)
        XCTAssertEqual(s.secured + s.pending + s.writtenOff, s.total, accuracy: 0.001)
        XCTAssertEqual(s.invoices, 5)
    }

    func testABiggerCreditNeverClaimsMoreThanWasCaught() {
        let s = OverviewMaths.savings([caught(credit: CreditInfo(status: CreditInfo.received, amount: 40))])
        XCTAssertEqual(s.secured, 10)
        XCTAssertEqual(s.pending, 0)
    }
}
