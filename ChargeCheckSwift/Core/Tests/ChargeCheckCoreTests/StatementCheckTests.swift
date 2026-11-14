import XCTest
@testable import ChargeCheckCore

final class StatementCheckTests: XCTestCase {
    private let text = """
    APEX FOODS LTD
    STATEMENT OF ACCOUNT  November 2026
    Date        Ref          Details          Debit     Credit    Balance
    01/10/2026               Balance brought forward              500.00
    03/11/2026  INV-4471     Invoice          120.00              620.00
    05.11.2026  INV-4480     Invoice          1,234.56            1,854.56
    07/11/2026  4495         Invoice          60.00               1,914.56
    08/11/2026               Payment received           -500.00   1,414.56
    10/11/2026  CN-77        Credit note                -12.00    1,402.56
    Balance due £1,402.56
    """

    func testReadsTheStatement() {
        let s = StatementCheck.parse(text)
        XCTAssertEqual(s.lines.map { $0.kind }, [.invoice, .invoice, .invoice, .payment, .credit])
        XCTAssertEqual(s.lines.map { $0.amount }, [120, 1234.56, 60, 500, 12])
        XCTAssertEqual(s.lines.map { $0.reference }, ["INV-4471", "INV-4480", "4495", "", "CN-77"])
        XCTAssertEqual(s.balance, 1402.56)
        XCTAssertEqual(StatementCheck.isoDay("05.11.2026"), "2026-11-05")
        XCTAssertEqual(StatementCheck.isoDay("7/11/26"), "2026-11-07")
    }

    func testComparesWithYourRecords() {
        func entry(_ id: String, _ no: String, _ savedAt: String, _ total: Double) -> HistoryEntry {
            HistoryEntry(id: id, savedAt: savedAt, supplier: "Apex Foods", invNo: no, date: "", net: total, total: total, over: 0, lines: [])
        }
        let entries = [
            entry("a", "4471", "2026-11-03T09:00:00Z", 120),
            entry("b", "INV 4480", "2026-11-05T09:00:00Z", 1230.56),     // they say 1,234.56
            entry("c", "4501", "2026-11-09T09:00:00Z", 75)               // not on their statement
        ]
        let payments = [
            SupplierPayment(supplier: "Apex Foods", amount: 500, date: "2026-11-08"),
            SupplierPayment(supplier: "Apex Foods", amount: 200, date: "2026-11-09")   // they haven't counted this
        ]
        let account = SupplierAccounts.accounts(entries: entries, payments: payments, trusted: [])[0]
        let r = StatementCheck.compare(StatementCheck.parse(text), account: account, payments: payments)
        XCTAssertEqual(r.matched.map { $0.reference }, ["INV-4471"])
        XCTAssertEqual(r.amountDiffers.map { $0.invoiceID }, ["b"])
        XCTAssertEqual(r.amountDiffers.first?.yours, 1230.56)
        XCTAssertEqual(r.notInReports.map { $0.reference }, ["4495"])
        XCTAssertEqual(r.notOnStatement.map { $0.id }, ["c"])
        XCTAssertEqual(r.paymentsMatched.map { $0.amount }, [500])
        XCTAssertEqual(r.paymentsUnknown.map { $0.amount }, [12])
        XCTAssertEqual(r.paymentsNotCounted.map { $0.amount }, [200])
        XCTAssertEqual(r.theirBalance, 1402.56)
        XCTAssertFalse(r.allClear)
        let query = StatementCheck.query(r, supplier: "Apex Foods", business: "RJ")
        XCTAssertTrue(query.contains("Invoice INV-4480: your statement says £1234.56, our copy says £1230.56."))
        XCTAssertTrue(query.contains("Invoice 4495 (07/11/2026, £60.00): we don't have this invoice. Please send a copy."))
        XCTAssertTrue(query.contains("Our payment of £200.00 on 2026-11-09 isn't on your statement."))
    }
}
