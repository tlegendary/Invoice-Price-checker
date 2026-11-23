import XCTest
@testable import ChargeCheckCore

final class PaymentRunnerTests: XCTestCase {
    private func attempt(_ pence: Int = 1250) -> PaymentAttempt {
        PaymentAttempt(saleID: "s1", amount: Pence(value: pence), currency: "GBP", channel: .provider("fake"), at: Date())
    }

    func testApproveDeclineCancel() async {
        let store = MemoryAttemptStore()
        let fake = FakePaymentProvider([.approve, .decline, .cancel])
        let runner = PaymentRunner(provider: fake, store: store)
        let approved = await runner.take(attempt())
        XCTAssertEqual(approved.status, .approved)
        XCTAssertTrue(approved.verified)
        let declined = await runner.take(attempt())
        XCTAssertEqual(declined.status, .declined)
        let cancelled = await runner.take(attempt())
        XCTAssertEqual(cancelled.status, .cancelled)
        let charges = await fake.charges
        XCTAssertEqual(charges, 1)
    }

    func testATimeoutIsCheckedNotChargedAgain() async {
        let store = MemoryAttemptStore()
        let fake = FakePaymentProvider([.timeoutButCharged])
        let runner = PaymentRunner(provider: fake, store: store)
        let first = await runner.take(attempt())
        XCTAssertEqual(first.status, .unknown, "no answer: maybe charged, maybe not")
        let recovered = await runner.recover(first)
        XCTAssertEqual(recovered.status, .approved, "the card company says it went through")
        let charges = await fake.charges
        XCTAssertEqual(charges, 1, "asked about, never charged twice")
    }

    func testATimeoutTheCardCompanyNeverGotIsNothingTaken() async {
        let fake = FakePaymentProvider([.timeout])
        let runner = PaymentRunner(provider: fake, store: MemoryAttemptStore())
        let first = await runner.take(attempt())
        XCTAssertEqual(first.status, .unknown)
        let recovered = await runner.recover(first)
        XCTAssertEqual(recovered.status, .failed)
        XCTAssertEqual(recovered.kept, .zero)
    }

    func testSendingTheSameAttemptAgainNeverChargesTwice() async {
        let fake = FakePaymentProvider([.approve, .approve])
        let runner = PaymentRunner(provider: fake, store: MemoryAttemptStore())
        let a = attempt()
        _ = await runner.take(a)
        _ = await runner.take(a)   // e.g. the button tapped twice, or a retry after a crash
        let charges = await fake.charges
        XCTAssertEqual(charges, 1)
    }

    func testAfterACrashOpenAttemptsAreCheckedOnLaunch() async throws {
        let store = MemoryAttemptStore()
        let fake = FakePaymentProvider([.timeoutButCharged])
        let runner = PaymentRunner(provider: fake, store: store)
        _ = await runner.take(attempt())
        // the app restarts: a fresh runner finds the open attempt and settles it
        let again = PaymentRunner(provider: fake, store: store)
        let settled = await again.recoverAll()
        XCTAssertEqual(settled.map(\.status), [.approved])
        let charges = await fake.charges
        XCTAssertEqual(charges, 1)
    }

    func testIfItCantBeSavedFirstTheCardIsNeverAsked() async {
        let store = MemoryAttemptStore()
        await store.setFailSaving(true)
        let fake = FakePaymentProvider([.approve])
        let result = await PaymentRunner(provider: fake, store: store).take(attempt())
        XCTAssertEqual(result.status, .failed)
        let charges = await fake.charges
        XCTAssertEqual(charges, 0)
    }

    func testOfflineIsUnknownUntilChecked() async {
        let result = await PaymentRunner(provider: FakePaymentProvider([.offline]), store: MemoryAttemptStore()).take(attempt())
        XCTAssertEqual(result.status, .unknown)
    }

    func testRefundsGoThroughTheCardCompanyAndAreCapped() async {
        let runner = PaymentRunner(provider: FakePaymentProvider([.approve]), store: MemoryAttemptStore())
        var paid = await runner.take(attempt(1000))
        paid = await runner.refund(paid, amount: Pence(value: 300), refundID: "r1")
        XCTAssertEqual(paid.refunded, Pence(value: 300))
        paid = await runner.refund(paid, amount: Pence(value: 800), refundID: "r2")
        XCTAssertEqual(paid.refunded, Pence(value: 300), "never more than is left")
    }
}
