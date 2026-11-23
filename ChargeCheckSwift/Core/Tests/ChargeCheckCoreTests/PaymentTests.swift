import XCTest
@testable import ChargeCheckCore

final class PaymentTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func p(_ pence: Int) -> Pence { Pence(value: pence) }
    private func card(_ amount: Int = 1250) -> PaymentAttempt {
        PaymentAttempt(saleID: "s1", amount: p(amount), currency: "GBP", channel: .provider("fake"), at: t0)
    }

    func testAProviderPaymentIsVerifiedOnlyByTheProvider() {
        var a = card()
        XCTAssertEqual(a.apply(.submitted, at: t0), .changed)
        XCTAssertEqual(a.status, .pending)
        XCTAssertEqual(a.apply(.confirmedByCashier(by: "Sara", reference: nil), at: t0), .refused("a connected card company's payment can't be approved by hand"))
        XCTAssertEqual(a.apply(.approved(reference: "ch_1"), at: t0), .changed)
        XCTAssertEqual(a.status, .approved)
        XCTAssertTrue(a.verified)
        XCTAssertEqual(a.reference, "ch_1")
    }

    func testRepeatedCallbacksChangeNothing() {
        var a = card()
        a.apply(.submitted, at: t0)
        a.apply(.approved(reference: "ch_1"), at: t0)
        XCTAssertEqual(a.apply(.approved(reference: "ch_1"), at: t0), .ignored)
        XCTAssertEqual(a.apply(.submitted, at: t0), .refused("already approved"))
        XCTAssertNil(a.needsReview)
    }

    func testContradictingAnswersAreNeverAppliedSilently() {
        var a = card()
        a.apply(.submitted, at: t0)
        a.apply(.approved(reference: "ch_1"), at: t0)
        XCTAssertEqual(a.apply(.declined(reason: "late"), at: t0), .refused("contradicts the earlier answer"))
        XCTAssertEqual(a.status, .approved, "the first final answer stands")
        XCTAssertNotNil(a.needsReview)
        XCTAssertTrue(PaymentSummary(due: p(1250), attempts: [a]).needsChecking)
    }

    func testATimeoutMeansUnknownNotFailed() {
        var a = card()
        a.apply(.submitted, at: t0)
        XCTAssertEqual(a.apply(.timedOut, at: t0), .changed)
        XCTAssertEqual(a.status, .unknown)
        let waiting = PaymentSummary(due: p(1250), attempts: [a])
        XCTAssertFalse(waiting.canAskForMore, "never start a second card payment while the first might still go through")
        XCTAssertEqual(waiting.waiting, p(1250))
        // asking the card company later settles it, with the same key
        XCTAssertEqual(a.apply(.approved(reference: "ch_9"), at: t0), .changed)
        XCTAssertEqual(a.idempotencyKey, a.id)
        XCTAssertTrue(PaymentSummary(due: p(1250), attempts: [a]).isPaid)
    }

    func testADeclinedCardCanBeFollowedByAnother() {
        var first = card()
        first.apply(.submitted, at: t0)
        first.apply(.declined(reason: "insufficient funds"), at: t0)
        let summary = PaymentSummary(due: p(1250), attempts: [first])
        XCTAssertTrue(summary.canAskForMore, "declined: safe to try another card")
        XCTAssertEqual(summary.paid, .zero)
    }

    func testCashAndASeparateCardMachineAreConfirmedByAPersonNotVerified() {
        var machine = PaymentAttempt(saleID: "s1", amount: p(800), currency: "GBP", channel: .externalTerminal(label: "Till 2 reader"), at: t0)
        XCTAssertEqual(machine.apply(.approved(reference: "x"), at: t0), .refused("only a connected card company can approve by itself"))
        XCTAssertEqual(machine.apply(.confirmedByCashier(by: " ", reference: nil), at: t0), .refused("who confirmed it is needed"))
        XCTAssertEqual(machine.apply(.confirmedByCashier(by: "Sara", reference: "AUTH 0042"), at: t0), .changed)
        XCTAssertEqual(machine.status, .approved)
        XCTAssertFalse(machine.verified, "a cashier's word is recorded, never called verified")
        XCTAssertEqual(machine.confirmedBy, "Sara")
        XCTAssertEqual(machine.log.count, 3, "every step is in the log, refused ones too")
    }

    func testRefundsNeverExceedWhatWasPaidAndRepeatsCountOnce() {
        var a = card(1000)
        a.apply(.submitted, at: t0)
        a.apply(.approved(reference: "ch_1"), at: t0)
        XCTAssertEqual(a.apply(.refunded(id: "r1", amount: p(400), reference: nil), at: t0), .changed)
        XCTAssertEqual(a.apply(.refunded(id: "r1", amount: p(400), reference: nil), at: t0), .ignored)
        XCTAssertEqual(a.apply(.refunded(id: "r2", amount: p(700), reference: nil), at: t0), .refused("more than can be refunded"))
        XCTAssertEqual(a.refundable, p(600))
        XCTAssertEqual(a.kept, p(600))
        var declined = card()
        declined.apply(.submitted, at: t0)
        declined.apply(.declined(reason: nil), at: t0)
        XCTAssertEqual(declined.apply(.refunded(id: "r", amount: p(1), reference: nil), at: t0), .refused("only an approved payment can be refunded"))
    }

    func testSplitPaymentsAddUpExactly() {
        var cashPart = PaymentAttempt(saleID: "s1", amount: p(2000), currency: "GBP", channel: .cash, at: t0)
        cashPart.apply(.confirmedByCashier(by: "Sara", reference: nil), at: t0)
        var cardPart = card(1999)
        cardPart.apply(.submitted, at: t0)
        let half = PaymentSummary(due: p(3999), attempts: [cashPart, cardPart])
        XCTAssertEqual(half.paid, p(2000))
        XCTAssertEqual(half.remaining, p(1999))
        XCTAssertFalse(half.isPaid)
        cardPart.apply(.approved(reference: "ch_2"), at: t0)
        let done = PaymentSummary(due: p(3999), attempts: [cashPart, cardPart])
        XCTAssertTrue(done.isPaid)
        XCTAssertEqual(done.over, .zero)
    }

    func testItSurvivesBeingSavedAndLoaded() throws {
        var a = card()
        a.apply(.submitted, at: t0)
        a.apply(.timedOut, at: t0)
        let back = try JSONDecoder().decode(PaymentAttempt.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
        XCTAssertEqual(back.status, .unknown, "after a crash the app still knows it must check, not charge again")
    }

    func testCardMachinePaymentsAreRecordedAsConfirmedNotVerified() throws {
        let card = SalePayment(kind: .card, amount: 12.5, ref: "AUTH 0042", confirmedBy: "Sara", terminal: "Card machine · T2", verified: false)
        XCTAssertTrue(card.isManualCard)
        let back = try JSONDecoder().decode(SalePayment.self, from: JSONEncoder().encode(card))
        XCTAssertEqual(back, card)
        // a sale saved before this existed still loads, and its card payment isn't called verified
        let old = try JSONDecoder().decode(SalePayment.self, from: Data(#"{"kind":"card","amount":9.99}"#.utf8))
        XCTAssertNil(old.confirmedBy)
        XCTAssertTrue(old.isManualCard)
        XCTAssertFalse(SalePayment(kind: .card, amount: 1, verified: true).isManualCard)
        XCTAssertFalse(SalePayment(kind: .cash, amount: 1).isManualCard)
    }
}
