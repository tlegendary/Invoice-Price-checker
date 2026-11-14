import XCTest
@testable import ChargeCheckCore

/// Shops kept apart, duplicate invoices, undoing "paid", totals in dinars and old backups still reading (Nov 2026).
final class ShopMoneySafetyTests: XCTestCase {
    override func setUp() {
        Money.currency = .gbp
    }

    override func tearDown() {
        Money.currency = .gbp
    }

    private func entry(_ id: String, shop: String, supplier: String = "Apex Foods", total: Double, invNo: String = "",
                       date: String = "06/11/2026", paid: String? = nil) -> HistoryEntry {
        HistoryEntry(id: id, savedAt: "2026-11-0\(id.count)T10:00:00Z", shopId: shop, supplier: supplier, invNo: invNo, date: date,
                     net: total, total: total, over: 0, paid: paid, lines: [])
    }

    // MARK: - shops

    func testEachShopSeesOnlyItsInvoicesAndPayments() {
        let entries = [entry("a", shop: "s1", total: 100), entry("b", shop: "s2", total: 60), entry("c", shop: "", total: 10)]
        let payments = [
            SupplierPayment(supplier: "Apex Foods", amount: 40, date: "2026-11-07", shopId: "s1"),
            SupplierPayment(supplier: "Apex Foods", amount: 60, date: "2026-11-07", invoiceIDs: ["b"]),       // old payment of a s2 invoice
            SupplierPayment(supplier: "Apex Foods", amount: 5, date: "2026-11-07")                           // old, no shop
        ]
        XCTAssertEqual(ShopFilter.entries(entries, shop: "s1").map { $0.id }, ["a"])
        XCTAssertEqual(ShopFilter.entries(entries, shop: "").count, 3)
        XCTAssertEqual(ShopFilter.payments(payments, allEntries: entries, shop: "s1").map { $0.amount }, [40])
        XCTAssertEqual(ShopFilter.payments(payments, allEntries: entries, shop: "s2").map { $0.amount }, [60])
        XCTAssertEqual(ShopFilter.payments(payments, allEntries: entries, shop: "").count, 3)
        XCTAssertEqual(ShopFilter.unassigned(payments, allEntries: entries).map { $0.amount }, [5])

        // what shop 1 owes Apex: its 100 less its own 40
        let s1 = SupplierAccounts.accounts(entries: ShopFilter.entries(entries, shop: "s1"),
                                           payments: ShopFilter.payments(payments, allEntries: entries, shop: "s1"), trusted: [])
        XCTAssertEqual(s1.first?.balance, 60)
        // all shops: 170 invoiced, 40 + 5 paid, the 60 invoice paid by its own payment
        let all = SupplierAccounts.accounts(entries: entries, payments: payments, trusted: [])
        XCTAssertEqual(all.first?.balance, 65)
    }

    func testPayingTickedInvoicesRemembersShopAndAmounts() {
        let a = entry("a", shop: "s1", total: 100)
        let b = entry("bb", shop: "s1", total: 50)
        let payment = SupplierAccounts.payment(for: [a, b], supplier: "Apex Foods", date: "2026-11-10", currency: "GBP")
        XCTAssertEqual(payment.amount, 150)
        XCTAssertEqual(payment.shopId, "s1")
        XCTAssertEqual(payment.currency, "GBP")
        XCTAssertEqual(payment.invoiceAmounts?["a"], 100)
        let mixed = SupplierAccounts.payment(for: [a, entry("c", shop: "s2", total: 5)], supplier: "Apex Foods", date: "2026-11-10")
        XCTAssertNil(mixed.shopId)
    }

    // MARK: - undo paid

    func testUndoPaidTakesBackWhatWasPaidThen() {
        let a = entry("a", shop: "", total: 100)
        let b = entry("bb", shop: "", total: 50)
        let payment = SupplierAccounts.payment(for: [a, b], supplier: "Apex Foods", date: "2026-11-10")
        // the invoice was corrected after it was paid: 100 → 90
        var corrected = a
        corrected.total = 90
        corrected.net = 90
        let result = SupplierAccounts.undoPaid(["a"], payments: [payment], entries: [corrected, b])
        XCTAssertEqual(result.payments.count, 1)
        XCTAssertEqual(result.payments[0].amount, 50)               // 150 − the 100 paid for it then (not 90)
        XCTAssertEqual(result.payments[0].invoiceIDs, ["bb"])
        XCTAssertEqual(result.before.first?.amount, 150)            // the payment as it was, kept for the history
    }

    func testUndoPaidOnEveryInvoiceRemovesThePayment() {
        let a = entry("a", shop: "", total: 100)
        let payment = SupplierAccounts.payment(for: [a], supplier: "Apex Foods", date: "2026-11-10")
        let other = SupplierPayment(supplier: "Apex Foods", amount: 20, date: "2026-11-09")
        let result = SupplierAccounts.undoPaid(["a"], payments: [payment, other], entries: [a])
        XCTAssertEqual(result.payments.map { $0.id }, [other.id])
        XCTAssertEqual(result.before.map { $0.id }, [payment.id])
    }

    // MARK: - duplicates

    func testDuplicatesAreNeverAcrossShops() {
        let saved = entry("a", shop: "s1", total: 120)
        var draft = InvoiceDraft(supplier: "Apex Foods", date: "06/11/2026", shopId: "s2")
        XCTAssertNil(InvoiceMaths.duplicate(of: draft, net: 120, in: [saved]))
        draft.shopId = "s1"
        XCTAssertEqual(InvoiceMaths.duplicate(of: draft, net: 120, in: [saved])?.id, "a")
        // an invoice from before shops (no shop) can still be the same invoice
        draft.shopId = ""
        XCTAssertEqual(InvoiceMaths.duplicate(of: draft, net: 120, in: [saved])?.id, "a")
    }

    func testFlaggedDuplicateIsNotMatchedAgainAndNeedsAttention() {
        let first = entry("a", shop: "", total: 120, invNo: "77")
        var twice = entry("bb", shop: "", total: 120, invNo: "77")
        twice.duplicateOf = "a"
        let draft = InvoiceDraft(supplier: "Apex Foods", invNo: "77", date: "06/11/2026")
        XCTAssertEqual(InvoiceMaths.duplicate(of: draft, net: 120, in: [twice, first])?.id, "a")
        let overview = OverviewMaths.make(entries: [first, twice], payments: [], trusted: [])
        let flag = overview.attention.first { $0.kind == .duplicates }
        XCTAssertEqual(flag?.count, 1)
        XCTAssertEqual(flag?.amount, 120)
    }

    func testUpdatingAnInvoiceKeepsItsCurrencyAndFlag() {
        var saved = entry("a", shop: "", total: 10)
        saved.currency = "GBP"
        saved.duplicateOf = "x"
        let draft = InvoiceDraft(id: "a", supplier: "Apex Foods", lines: [CheckLine(qty: 1, desc: "Thing", unit: 10, ok: true, noBase: true)])
        let updated = InvoiceMaths.historyEntry(draft, book: PriceBook([]), existing: saved)
        XCTAssertEqual(updated.currency, "GBP")
        XCTAssertEqual(updated.duplicateOf, "x")
    }

    // MARK: - totals and dinars

    func testTotalCheckAllowsVatRoundingOnLongInvoices() {
        XCTAssertEqual(InvoiceMaths.totalAllowance(lines: 3, withVat: true), 0.05)
        XCTAssertEqual(InvoiceMaths.totalAllowance(lines: 40, withVat: true), 0.2, accuracy: 0.0001)
        XCTAssertEqual(InvoiceMaths.totalAllowance(lines: 40, withVat: false), 0.05)
        Money.currency = .iqd
        XCTAssertEqual(InvoiceMaths.totalAllowance(lines: 3, withVat: false), 1)
        XCTAssertEqual(InvoiceMaths.totalAllowance(lines: 10, withVat: true), 5)
    }

    func testNoMinusZero() {
        XCTAssertEqual(Money.format(-0.2, in: .iqd), "0 IQD")
        XCTAssertEqual(Money.format(-0.001, in: .gbp), "£0.00")
        XCTAssertEqual(Money.format(-3, in: .gbp), "-£3.00")
        XCTAssertEqual(Money.format(-25_000, in: .iqd), "-25,000 IQD")
    }

    // MARK: - old backups

    func testOldBackupsStillReadAndNewFieldsStayOutUntilSet() throws {
        let old = #"{"baseline":[],"history":[{"id":"h1","supplier":"Apex","net":10,"total":10,"over":0,"lines":[]}],"#
            + #""payments":[{"id":"p1","supplier":"Apex","amount":5,"date":"2026-11-01","kind":"payment","invoiceIDs":[]}]}"#
        let backup = try BackupFile.read(Data(old.utf8))
        XCTAssertNil(backup.history[0].currency)
        XCTAssertNil(backup.history[0].duplicateOf)
        XCTAssertNil(backup.payments?[0].shopId)
        XCTAssertNil(backup.payments?[0].invoiceAmounts)
        let written = String(decoding: try backup.encoded(), as: UTF8.self)
        // a backup written from old data looks exactly as before (the old app and TeamSync hashes stay the same)
        XCTAssertFalse(written.contains("invoiceAmounts"))
        XCTAssertFalse(written.contains("\"currency\""))
        XCTAssertFalse(written.contains("duplicateOf"))
        XCTAssertTrue(written.contains("\"shopId\":\"\""))          // the invoice's own shop field, as before
        XCTAssertFalse(written.contains("\"shopId\":null"))
        let again = try BackupFile.read(try backup.encoded())
        XCTAssertEqual(again.payments?[0].amount, 5)
    }
}
