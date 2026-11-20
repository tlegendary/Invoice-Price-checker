import XCTest
@testable import ChargeCheckCore

/// What to pay, checked three ways: worked examples, the rules every invoice must follow, and the same rules
/// for the totals on every screen (Reports, suppliers, Home), over thousands of made-up invoices.
final class PayBreakdownTests: XCTestCase {
    private func entry(net: Double, total: Double, over: Double = 0, overVat: Double = 0, excluded: Double = 0,
                       lines: [HistoryLine] = [], supplier: String = "Apex", id: String = UUID().uuidString) -> HistoryEntry {
        HistoryEntry(id: id, savedAt: "2026-11-01T10:00:00Z", supplier: supplier, invNo: id, date: "", net: net, total: total,
                     over: over, overVat: overVat, excluded: excluded, paid: nil, lines: lines)
    }

    // MARK: 1. worked examples

    func testAnOverchargeComesOffTheNetAndItsVatOffTheVat() {
        // Ramyar's case: £100 + £20 VAT = £120, £10 overcharged, the lines read without VAT rates.
        // Wrong (before): £120 − £10 = £110. Right: (£100 − £10) + (£20 − £2) = £108.
        let p = entry(net: 100, total: 120, over: 10, lines: [HistoryLine(qty: 1, desc: "x", unit: 100, over: 10)]).payment
        XCTAssertEqual(p.payNet, 90)
        XCTAssertEqual(p.payVat, 18)
        XCTAssertEqual(p.pay, 108)
        XCTAssertEqual(p.less, 12)
        XCTAssertEqual(p.allItemsRate, 20)
        XCTAssertFalse(p.vatUnknown)
    }

    func testVatComesOffOnlyForItemsThatHadVat() {
        // £50 of zero-rated chicken overcharged by £5, £50 of cola at 20% overcharged by £2: VAT comes off the £2 only
        let lines = [HistoryLine(qty: 1, desc: "Chicken", unit: 50, vat: 0, over: 5),
                     HistoryLine(qty: 1, desc: "Cola", unit: 50, vat: 20, over: 2)]
        let p = entry(net: 100, total: 110, over: 7, overVat: 0.4, lines: lines).payment
        XCTAssertEqual(p.lessVat, 0.4)
        XCTAssertEqual(p.less, 7.4)
        XCTAssertEqual(p.pay, 102.6)
        XCTAssertEqual(p.payNet, 93)
        XCTAssertEqual(p.payVat, 9.6)
    }

    func testUnknownVatIsNeverGuessed() {
        // VAT is £10 on £100 – not one rate on everything, and no line says which items had it: none is taken off
        let lines = [HistoryLine(qty: 1, desc: "Chicken", unit: 50, over: 5), HistoryLine(qty: 1, desc: "Cola", unit: 50)]
        let p = entry(net: 100, total: 110, over: 5, lines: lines).payment
        XCTAssertTrue(p.vatUnknown)
        XCTAssertNil(p.allItemsRate)
        XCTAssertEqual(p.lessVat, 0)
        XCTAssertEqual(p.pay, 105)
        XCTAssertEqual(p.payNet, 95)
        XCTAssertEqual(p.payVat, 10)
    }

    func testEachLinesOwnVatRateIsUsedWhenItsKnown() {
        // a zero-rated food line overcharged by £3 on an invoice with some VAT elsewhere: only £3 comes off
        let lines = [HistoryLine(qty: 3, desc: "Wings", unit: 15.99, vat: 0, over: 3),
                     HistoryLine(qty: 1, desc: "Pepsi", unit: 16.60, vat: 20)]
        let p = entry(net: 64.57, total: 67.89, over: 3, overVat: 0, lines: lines).payment
        XCTAssertNil(p.allItemsRate)
        XCTAssertFalse(p.vatUnknown)
        XCTAssertEqual(p.lessVat, 0)
        XCTAssertEqual(p.pay, 64.89)
        // a standard-rated line overcharged by £5: £5 + £1 VAT comes off
        let vatLine = [HistoryLine(qty: 1, desc: "Cleaner", unit: 30, vat: 20, over: 5)]
        let q = entry(net: 30, total: 36, over: 5, overVat: 1, lines: vatLine).payment
        XCTAssertEqual(q.pay, 30)
        XCTAssertEqual(q.payNet, 25)
        XCTAssertEqual(q.payVat, 5)
    }

    func testMissingItemsComeOffWithTheirVat() {
        let lines = [HistoryLine(qty: 10, desc: "Wings", unit: 15, vat: 20, short: 3), HistoryLine(qty: 1, desc: "Oil", unit: 30)]
        let p = entry(net: 180, total: 210, excluded: 45, lines: lines).payment
        XCTAssertEqual(p.missing, 45)
        XCTAssertEqual(p.missingVat, 9)
        XCTAssertEqual(p.pay, 156)
        XCTAssertEqual(p.payNet, 135)
        XCTAssertEqual(p.payVat, 21)
    }

    func testNothingGoesBelowZero() {
        let p = entry(net: 10, total: 12, over: 50).payment
        XCTAssertEqual(p.pay, 0)
        XCTAssertEqual(p.payNet, 0)
        XCTAssertEqual(p.payVat, 0)
        XCTAssertEqual(p.less, 12)
    }

    func testMisreadOrMissingNet() {
        // a total below its net is a misread: no VAT split, the total is what's owed
        let low = entry(net: 150, total: 120).payment
        XCTAssertEqual(low.net, 120)
        XCTAssertEqual(low.vat, 0)
        XCTAssertEqual(low.pay, 120)
        // a trusted supplier's invoice with only the total read
        let onlyTotal = entry(net: 0, total: 95.5).payment
        XCTAssertEqual(onlyTotal.payNet, 95.5)
        XCTAssertEqual(onlyTotal.payVat, 0)
        XCTAssertEqual(onlyTotal.pay, 95.5)
    }

    func testOldNamesGiveTheSameFigures() {
        let e = entry(net: 100, total: 120, over: 10)
        XCTAssertEqual(e.amountToPay.pay, e.payment.pay)
        XCTAssertEqual(e.amountToPay.less, e.payment.less)
        XCTAssertEqual(e.amountToPayBeforeVat.pay, e.payment.payNet)
        XCTAssertEqual(e.amountToPayBeforeVat.less, e.payment.lessNet)
        XCTAssertEqual(OverviewMaths.caught(e).overcharges, 12, "the overcharge with its VAT")
    }

    // MARK: 2. the rules, on thousands of made-up invoices

    /// The same "random" invoices every run.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func pennies(_ max: Int, _ rng: inout Seeded) -> Double { Double(Int.random(in: 0...max, using: &rng)) / 100 }

    private func randomInvoices(_ count: Int) -> [HistoryEntry] {
        var rng = Seeded(state: 20261120)
        let rates: [Double] = [0, 0, 5, 20]
        var out: [HistoryEntry] = []
        for n in 0..<count {
            var lines: [HistoryLine] = []
            var net = 0.0, vat = 0.0, over = 0.0, overVat = 0.0, excluded = 0.0
            let ratesKnown = Bool.random(using: &rng)
            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                let qty = Double(Int.random(in: 1...20, using: &rng))
                let unit = pennies(5_000, &rng)
                let rate = rates.randomElement(using: &rng) ?? 0
                let lineNet = Money.round2(qty * unit)
                net += lineNet
                vat += Money.round2(lineNet * rate / 100)
                var line = HistoryLine(qty: qty, desc: "item", unit: unit, vat: ratesKnown ? rate : 0)
                switch Int.random(in: 0...5, using: &rng) {
                case 0:
                    let o = Money.round2(qty * pennies(300, &rng))
                    line.over = o
                    over += o
                    overVat += ratesKnown ? Money.round2(o * rate / 100) : 0
                case 1:
                    line.short = Double(Int.random(in: 1...Int(qty), using: &rng))
                    excluded += Money.round2(line.short * unit)
                case 2:
                    line.excluded = true
                    excluded += lineNet
                default:
                    break
                }
                lines.append(line)
            }
            // now and then: a misread total, a trusted supplier's total only, a huge overcharge
            var printedNet = Money.round2(net), printedTotal = Money.round2(net + vat)
            switch n % 50 {
            case 7: printedTotal = Money.round2(printedNet * 0.9)
            case 13: printedNet = 0; lines = []
            case 29: over += 100_000
            default: break
            }
            out.append(entry(net: printedNet, total: printedTotal, over: Money.round2(over), overVat: Money.round2(overVat),
                             excluded: Money.round2(excluded), lines: lines, supplier: "Supplier \(n % 7)", id: "inv\(n)"))
        }
        return out
    }

    func testEveryInvoiceAddsUp() {
        for e in randomInvoices(5_000) {
            let p = e.payment
            XCTAssertEqual(p.net + p.vat, p.total, accuracy: 0.001, e.id)
            XCTAssertEqual(p.payNet + p.payVat, p.pay, accuracy: 0.001, e.id)
            XCTAssertEqual(p.lessNet + p.lessVat, p.less, accuracy: 0.001, e.id)
            XCTAssertEqual(p.less + p.pay, p.total, accuracy: 0.001, e.id)
            XCTAssertEqual(p.over + p.missing, p.lessNet, accuracy: 0.001, e.id)
            XCTAssertEqual(p.overVat + p.missingVat, p.lessVat, accuracy: 0.001, e.id)
            XCTAssertGreaterThanOrEqual(p.payNet, 0, e.id)
            XCTAssertGreaterThanOrEqual(p.payVat, 0, e.id)
            XCTAssertLessThanOrEqual(p.payNet, p.net + 0.001, e.id)
            XCTAssertLessThanOrEqual(p.payVat, p.vat + 0.001, e.id)
            // whole pennies only
            for value in [p.pay, p.payNet, p.payVat, p.less, p.lessNet, p.lessVat] {
                XCTAssertEqual((value * 100).rounded(), value * 100, accuracy: 0.0001, e.id)
            }
            // VAT only comes off for items that had VAT: never guessed
            if let rate = p.allItemsRate {
                XCTAssertFalse(e.lines.contains { $0.vat > 0 }, e.id)
                XCTAssertEqual(p.lessVat, Money.round2(p.lessNet * rate / 100), accuracy: 0.011, e.id)
            }
            if p.vatUnknown {
                XCTAssertEqual(p.lessVat, 0, e.id)
                XCTAssertFalse(e.lines.contains { $0.vat > 0 }, e.id)
            }
            if e.lines.contains(where: { $0.vat > 0 }) {
                XCTAssertNil(p.allItemsRate, e.id)
                XCTAssertFalse(p.vatUnknown, e.id)
            }
            let caught = OverviewMaths.caught(e)
            XCTAssertEqual(caught.overcharges + caught.missing, p.less > 0.005 ? p.less : 0, accuracy: 0.001, e.id)
        }
    }

    // MARK: 3. the totals on every screen

    func testEveryScreensTotalsAddUp() {
        let invoices = randomInvoices(2_000)
        func sum(_ values: [Double]) -> Double { Money.round2(values.reduce(0, +)) }

        // Reports › To pay
        let summary = ReportMaths.paySummary(invoices, skipped: [])
        XCTAssertEqual(summary.pay, sum(invoices.map { $0.payment.pay }), accuracy: 0.001)
        XCTAssertEqual(summary.total - summary.less, summary.pay, accuracy: 0.001)
        XCTAssertEqual(summary.payBeforeVat + summary.vat, summary.payWithVat, accuracy: 0.001)
        XCTAssertEqual(summary.payBeforeVat, sum(invoices.map { $0.payment.payNet }), accuracy: 0.001)
        for supplier in summary.suppliers {
            XCTAssertEqual(supplier.total - supplier.less, supplier.pay, accuracy: 0.001, supplier.name)
        }
        let net = ReportMaths.paySummary(invoices, skipped: [], beforeVat: true)
        XCTAssertEqual(net.pay, summary.payBeforeVat, accuracy: 0.001)

        // Suppliers: balances, and before VAT + VAT = what's owed
        let payment = SupplierPayment(supplier: "Supplier 3", amount: 250, date: "2026-11-05", kind: .payment)
        let accounts = SupplierAccounts.accounts(entries: invoices, payments: [payment], trusted: [])
        for account in accounts {
            let invoiced = sum(account.entries.map { $0.payment.pay })
            XCTAssertEqual(account.invoiced, invoiced, accuracy: 0.001, account.name)
            if let split = SupplierAccounts.owedSplit(account) {
                XCTAssertEqual(split.beforeVat + split.vat, account.balance, accuracy: 0.001, account.name)
                XCTAssertGreaterThanOrEqual(split.vat, -0.001, account.name)
            }
        }
        if let all = SupplierAccounts.totalSplit(accounts) {
            XCTAssertEqual(all.beforeVat + all.vat, sum(accounts.filter { $0.balance > 0.005 }.map(\.balance)), accuracy: 0.01)
        }

        // Home: what's owed is the suppliers' balances
        let home = OverviewMaths.make(entries: invoices, payments: [payment], trusted: [])
        XCTAssertEqual(home.owed, sum(accounts.filter { $0.balance > 0.005 }.map(\.balance)), accuracy: 0.001)
        if let split = home.owedSplit {
            XCTAssertEqual(split.beforeVat + split.vat, home.owed, accuracy: 0.01)
        }
    }
}
