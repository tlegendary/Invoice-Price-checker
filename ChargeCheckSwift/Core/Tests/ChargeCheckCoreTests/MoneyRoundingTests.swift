import XCTest
@testable import ChargeCheckCore

/// `Money.round2` is used for every line total, VAT amount, balance and overcharge, so it must give the penny a
/// person with a calculator would. The expected answers here are worked out with whole numbers only (no Doubles).
final class MoneyRoundingTests: XCTestCase {
    func testHalfPenniesRoundUp() {
        XCTAssertEqual(Money.round2(1.005), 1.01)
        XCTAssertEqual(Money.round2(2.675), 2.68)
        XCTAssertEqual(Money.round2(10.005), 10.01)
        XCTAssertEqual(Money.round2(1234.565), 1234.57)
        XCTAssertEqual(Money.round2(0.125), 0.13)
    }

    func testWorkedOutHalfPenniesRoundUp() {
        // these were a penny short before: the sum is stored just below the half penny
        XCTAssertEqual(Money.round2(0.25 * 16.74), 4.19)      // 4.185, a quarter kilo
        XCTAssertEqual(Money.round2(0.125 * 19.4), 2.43)      // 2.425
        XCTAssertEqual(Money.round2(0.125 * 40.12), 5.02)     // 5.015
        XCTAssertEqual(Money.round2(0.25 * 32.98), 8.25)      // 8.245
        XCTAssertEqual(Money.round2(3 * 3.335), 10.01)        // 10.005
    }

    func testOrdinaryAmountsAreUnchanged() {
        XCTAssertEqual(Money.round2(0), 0)
        XCTAssertEqual(Money.round2(1.234), 1.23)
        XCTAssertEqual(Money.round2(1.236), 1.24)
        XCTAssertEqual(Money.round2(12.5), 12.5)
        XCTAssertEqual(Money.round2(0.1 + 0.2), 0.3)
        XCTAssertEqual(Money.round2(100.0049), 100.0)
        XCTAssertEqual(Money.round2(100.0051), 100.01)
        XCTAssertEqual(Money.round2(25_000), 25_000)            // whole dinars
        XCTAssertEqual(Money.round2(1_500_000_000), 1_500_000_000)
        XCTAssertEqual(Money.round2(123_456_789.125), 123_456_789.13)
    }

    func testMinusAmountsRoundLikePlusAmounts() {
        // a credit or an overpayment of £1.005 is the same penny as a charge of £1.005
        XCTAssertEqual(Money.round2(-1.005), -1.01)
        XCTAssertEqual(Money.round2(-2.675), -2.68)
        XCTAssertEqual(Money.round2(-1.234), -1.23)
        XCTAssertEqual(Money.round2(-0.25 * 16.74), -4.19)
        for pennies in stride(from: 5, to: 200_000, by: 10) {
            let value = Double(pennies) / 1000
            XCTAssertEqual(Money.round2(-value), -Money.round2(value), "\(value)")
        }
    }

    func testOddValuesAreSafe() {
        XCTAssertEqual(Money.round2(.infinity), .infinity)
        XCTAssertTrue(Money.round2(.nan).isNaN)
        XCTAssertEqual(Money.round2(1e300), 1e300)
    }

    func testRoundingTwiceChangesNothing() {
        for value in [4.185, 2.675, -1.005, 9.975, 123_456_789.125, 0.005, 1808.675] {
            let once = Money.round2(value)
            XCTAssertEqual(Money.round2(once), once, "\(value)")
        }
    }

    /// Every amount with a half penny from 0.005 to 1,999.995, against whole-number arithmetic.
    func testEveryHalfPennyUpTo2000() {
        var wrong: [String] = []
        for thousandths in stride(from: 5, to: 2_000_000, by: 10) {
            let want = Double((thousandths + 5) / 10) / 100
            let got = Money.round2(Double(thousandths) / 1000)
            if got != want { wrong.append("\(Double(thousandths) / 1000) → \(got), want \(want)") }
        }
        XCTAssertEqual(wrong.count, 0, wrong.prefix(5).joined(separator: "; "))
    }

    /// Weighed lines: quantity in steps of an eighth of a kilo (and tenths) × a price in pence.
    func testWeighedLineTotals() {
        // quantity as thousandths of a unit
        let quantities = Array(stride(from: 125, through: 50_000, by: 125)) + Array(stride(from: 100, to: 50_000, by: 100))
        var wrong: [String] = []
        for q in quantities {
            for pence in stride(from: 1, through: 6000, by: 7) {
                // exact total in hundred-thousandths of a pound, rounded half up to pennies with whole numbers
                let want = Double((q * pence + 500) / 1000) / 100
                let got = Money.round2(Double(q) / 1000 * (Double(pence) / 100))
                if got != want, wrong.count < 5 { wrong.append("\(Double(q) / 1000) × \(Double(pence) / 100) → \(got), want \(want)") }
            }
        }
        XCTAssertTrue(wrong.isEmpty, wrong.joined(separator: "; "))
    }
}

/// The rounding as the invoice check uses it: line totals, VAT, and an invoice saved before the rounding fix.
final class MoneyRoundingInUseTests: XCTestCase {
    override func setUp() { Money.currency = .gbp }

    func testNoMinusZero() {
        XCTAssertEqual(Money.round2(-0.004).sign, .plus)
        XCTAssertEqual(Money.round2(-0.0).sign, .plus)
        let json = String(decoding: try! JSONEncoder().encode([Money.round2(-0.001)]), as: UTF8.self)
        XCTAssertEqual(json, "[0]")
    }

    func testWeighedLineAndItsVat() {
        let book = PriceBook([PriceItem(id: "mince", name: "Lamb mince", price: 16.74)])
        let line = CheckLine(qty: 0.25, desc: "Lamb mince", unit: 16.74, vat: 20, matchId: "mince", confident: true)
        let result = InvoiceMaths.lineResult(line, supplier: "", book: book)
        XCTAssertEqual(result.net, 4.19)                       // 4.185, a quarter kilo
        XCTAssertEqual(result.vat, 0.84)                       // 20% of 4.19 = 0.838
        XCTAssertEqual(Money.round2(0.9 * 5 / 100), 0.05)      // 5% VAT on 90p = 4.5p
    }

    func testInvoiceSavedBeforeTheFixIsStillFoundAsTheSameInvoice() {
        // saved by an earlier version a penny lower (4.18), the same invoice now adds up to 4.19
        let saved = HistoryEntry(id: "old", supplier: "Butcher", date: "14/11/2026", net: 4.18, total: 4.18, over: 0, lines: [])
        let again = InvoiceDraft(supplier: "Butcher", date: "14/11/2026")
        XCTAssertEqual(InvoiceMaths.duplicate(of: again, net: 4.19, in: [saved])?.id, "old")
        XCTAssertNil(InvoiceMaths.duplicate(of: again, net: 4.21, in: [saved]))
    }
}
