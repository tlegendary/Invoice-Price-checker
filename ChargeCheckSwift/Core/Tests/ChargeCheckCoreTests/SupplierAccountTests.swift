import XCTest
@testable import ChargeCheckCore

final class SupplierAccountTests: XCTestCase {
    private func entry(_ id: String, _ supplier: String, savedAt: String, total: Double, over: Double = 0, paid: String? = nil) -> HistoryEntry {
        HistoryEntry(id: id, savedAt: savedAt, supplier: supplier, invNo: id, date: "", net: total, total: total, over: over, paid: paid, lines: [])
    }

    private var invoices: [HistoryEntry] {
        [
            entry("a1", "APEX FOODS LTD", savedAt: "2026-11-01T10:00:00Z", total: 100),
            entry("a2", "Apex Foods", savedAt: "2026-11-05T10:00:00Z", total: 200, over: 20),   // pay 180
            entry("a3", "Apex Foods", savedAt: "2026-11-08T10:00:00Z", total: 50),
            entry("w1", "Waka", savedAt: "2026-10-01T10:00:00Z", total: 40, paid: "2026-10-02T10:00:00Z"),   // paid before accounts existed
            entry("w2", "Waka", savedAt: "2026-11-02T10:00:00Z", total: 60)
        ]
    }

    private let monday = SupplierAccounts.day("2026-11-11")!

    func testSameSupplierWhateverTheSpelling() {
        XCTAssertEqual(SupplierAccounts.key("APEX FOODS LTD"), SupplierAccounts.key("Apex  Foods"))
        XCTAssertEqual(SupplierAccounts.key("شركة النور"), "شركة النور")
        let accounts = SupplierAccounts.accounts(entries: invoices, payments: [], trusted: [], now: monday)
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts[0].name, "Apex Foods")       // the newest spelling
        XCTAssertEqual(accounts[0].entries.count, 3)
    }

    func testBalanceWithPaymentsTowardsTheBalance() {
        let payments = [
            SupplierPayment(supplier: "Apex Foods", amount: 150, date: "2026-11-10"),
            SupplierPayment(supplier: "apex foods", amount: 30, date: "2026-11-03", kind: .credit)
        ]
        let apex = SupplierAccounts.accounts(entries: invoices, payments: payments, trusted: [], now: monday)
            .first { $0.name == "Apex Foods" }!
        XCTAssertEqual(apex.invoiced, 330)
        XCTAssertEqual(apex.paid, 150)
        XCTAssertEqual(apex.credits, 30)
        XCTAssertEqual(apex.balance, 150)
        // 180 paid towards the balance: the oldest (100) is paid off, the 180 one is part paid so still open
        XCTAssertEqual(apex.open.map { $0.id }, ["a2", "a3"])
        XCTAssertEqual(apex.paidThisWeek, 150)
        XCTAssertEqual(apex.lastPayment?.amount, 150)
    }

    func testTickedInvoicesAndOldPaidMarks() {
        let waka = invoices.filter { $0.supplier == "Waka" }
        let ticked = SupplierAccounts.payment(for: [waka[1]], supplier: "Waka", date: "2026-11-09")
        XCTAssertEqual(ticked.amount, 60)
        XCTAssertEqual(ticked.invoiceIDs, ["w2"])
        var marked = invoices
        marked[4].paid = "2026-11-09T12:00:00Z"
        let account = SupplierAccounts.accounts(entries: marked, payments: [ticked], trusted: [], now: monday).first { $0.name == "Waka" }!
        // w1 was marked paid without a payment, w2 is paid by the ticked payment: nothing owed, counted once
        XCTAssertEqual(account.settledOutside, 40)
        XCTAssertEqual(account.paid, 60)
        XCTAssertEqual(account.balance, 0)
        XCTAssertTrue(account.open.isEmpty)
        XCTAssertEqual(account.paidThisWeek, 60)
    }

    func testStartingBalanceIsPaidFirst() {
        let payments = [
            SupplierPayment(supplier: "Waka", amount: 500, date: "2026-10-01", kind: .opening),
            SupplierPayment(supplier: "Waka", amount: 520, date: "2026-11-01")
        ]
        let account = SupplierAccounts.accounts(entries: invoices, payments: payments, trusted: [], now: monday).first { $0.name == "Waka" }!
        XCTAssertEqual(account.balance, 40)          // 500 + 60 - 520
        XCTAssertEqual(account.open.map { $0.id }, ["w2"])
        XCTAssertEqual(account.paidThisWeek, 0)      // last week's payment
    }

    func testTrustedSuppliers() {
        XCTAssertTrue(SupplierAccounts.isTrusted("APEX FOODS LTD", trusted: ["Apex Foods"]))
        XCTAssertTrue(SupplierAccounts.isTrusted("Apex Foods Wholesale", trusted: ["Apex Foods"]))
        XCTAssertFalse(SupplierAccounts.isTrusted("Apex", trusted: ["Waka"]))
        XCTAssertFalse(SupplierAccounts.isTrusted("", trusted: ["Waka"]))
        // a trusted supplier with no invoices yet still has an account
        let accounts = SupplierAccounts.accounts(entries: [], payments: [], trusted: ["Bravo Meats"], now: monday)
        XCTAssertEqual(accounts.map { $0.name }, ["Bravo Meats"])
        XCTAssertTrue(accounts[0].trusted)
    }

    func testTotalOnlyInvoice() {
        var draft = InvoiceDraft(supplier: "Bravo", invNo: "77", printedNet: 100, printedTotal: 120)
        draft.totalOnly = true
        let entry = InvoiceMaths.historyEntry(draft, book: PriceBook([]))
        XCTAssertTrue(entry.totalOnly)
        XCTAssertEqual(entry.total, 120)
        XCTAssertEqual(entry.net, 100)
        XCTAssertEqual(entry.amountToPay.pay, 120)
        let data = try! JSONEncoder().encode(entry)
        XCTAssertTrue(try! JSONDecoder().decode(HistoryEntry.self, from: data).totalOnly)
    }

    func testWidget() {
        let snapshot = WidgetSnapshot.make(SupplierAccounts.accounts(entries: invoices, payments: [], trusted: [], now: monday), currency: "GBP")
        XCTAssertEqual(snapshot.totalOwed, 390)      // Apex 330 + Waka 60
        XCTAssertEqual(snapshot.suppliers.first?.name, "Apex Foods")
        XCTAssertEqual(snapshot.suppliers.first?.openInvoices, 3)
    }

    func testBackupKeepsPayments() throws {
        let backup = BackupFile(baseline: [], payments: [SupplierPayment(supplier: "Waka", amount: 10, date: "2026-11-01")], trusted: ["Waka"])
        let back = try BackupFile.read(JSONEncoder().encode(backup))
        XCTAssertEqual(back.payments?.first?.amount, 10)
        XCTAssertEqual(back.trusted, ["Waka"])
    }
}
