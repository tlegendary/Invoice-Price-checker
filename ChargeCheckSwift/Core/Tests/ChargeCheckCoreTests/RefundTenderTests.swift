import XCTest
@testable import ChargeCheckCore

final class RefundTenderTests: XCTestCase {
    /// £30: £20 on the card machine (approval code A1), £10 cash. Three lines of £10.
    private func sale() -> Sale {
        var s = Sale(number: 1, shop: "s", at: "2026-11-23T10:00:00Z",
                     lines: (1...3).map { SaleLine(id: "l\($0)", name: "Item \($0)", qty: 1, price: 10) }, payment: .card)
        s.split = [SalePayment(kind: .card, amount: 20, ref: "A1", confirmedBy: "Sara", terminal: "Card machine", verified: false),
                   SalePayment(kind: .cash, amount: 10)]
        return s
    }

    func testACardAndCashSaleIsRefundedToTheCardFirstNotAllInCash() {
        let original = sale()
        let refund = SaleMaths.refund(of: original, quantities: ["l1": 1], number: 2, at: "2026-11-23T11:00:00Z")
        XCTAssertEqual(refund.payments.map(\.kind), [.card])
        XCTAssertEqual(refund.payments.map(\.amount), [-10])
        XCTAssertEqual(refund.payments.first?.ref, "A1", "linked to the original card payment")
        XCTAssertEqual(refund.payments.first?.verified, false, "given back on the card machine by a person")
    }

    func testPartialRefundsNeverGiveAnyWayBackMoreThanItPaid() {
        let original = sale()
        let first = SaleMaths.refund(of: original, quantities: ["l1": 1, "l2": 1], number: 2, at: "2026-11-23T11:00:00Z")
        XCTAssertEqual(first.payments.map(\.kind), [.card])
        XCTAssertEqual(first.payments.map(\.amount), [-20])
        // the last £10: the card has nothing left, so cash
        let second = SaleMaths.refund(of: original, quantities: ["l3": 1], number: 3, at: "2026-11-23T12:00:00Z", earlier: [first])
        XCTAssertEqual(second.payments.map(\.kind), [.cash])
        XCTAssertEqual(second.payments.map(\.amount), [-10])
        let back = [first, second].flatMap(\.payments)
        XCTAssertEqual(back.filter { $0.kind == .card }.pennySum { -$0.amount }, 20)
        XCTAssertEqual(back.filter { $0.kind == .cash }.pennySum { -$0.amount }, 10)
    }

    func testTwoRefundsMadeFromTheSameStartingPointCantBothUseTheCard() {
        // two tills build a refund at once, each without the other's: the second, made with the first in view,
        // gets only what the card has left
        let original = sale()
        let a = SaleMaths.refundTenders(original, amount: -15, earlier: [])
        XCTAssertEqual(a.map(\.amount), [-15])
        var aSale = SaleMaths.refund(of: original, quantities: ["l1": 1], number: 2, at: "x")
        aSale.split = a
        let b = SaleMaths.refundTenders(original, amount: -15, earlier: [aSale])
        XCTAssertEqual(b.map(\.kind), [.card, .cash])
        XCTAssertEqual(b.map(\.amount), [-5, -10])
    }

    func testOnePaymentSalesGoBackTheSameWay() {
        let cashSale = Sale(number: 1, shop: "s", at: "x", lines: [SaleLine(id: "l", name: "A", qty: 2, price: 4.5)], payment: .cash)
        let refund = SaleMaths.refund(of: cashSale, quantities: ["l": 1], number: 2, at: "y")
        XCTAssertEqual(refund.payments.map(\.kind), [.cash])
        XCTAssertEqual(refund.payments.map(\.amount), [-4.5])
        XCTAssertEqual(refund.payment, .cash)
    }
}
