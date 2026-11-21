import XCTest
@testable import ChargeCheckCore

final class TillAuthorityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAYesIsForOneActionOnce() {
        var a = TillApprovals()
        a.give([.refund], by: "Dana", at: t0)
        XCTAssertNil(a.use(.cashOut, at: t0), "a yes for a refund isn't a yes for taking cash out")
        XCTAssertEqual(a.use(.refund, at: t0.addingTimeInterval(10)), "Dana")
        XCTAssertNil(a.use(.refund, at: t0.addingTimeInterval(11)), "used up")
    }

    func testAYesRunsOut() {
        var a = TillApprovals()
        a.give([.closeDay], by: "Dana", at: t0)
        XCTAssertNil(a.use(.closeDay, at: t0.addingTimeInterval(TillApprovals.lifetime + 1)))
        XCTAssertTrue(a.isEmpty)
    }

    func testOnePinCanSayYesToSeveralThingsTogether() {
        var a = TillApprovals()
        a.give([.discount, .priceChange], by: "Sam", at: t0)
        XCTAssertEqual(a.use(.priceChange, at: t0), "Sam")
        XCTAssertEqual(a.use(.discount, at: t0), "Sam")
    }

    func testAYesFromTheFutureIsRefused() {
        // the clock was moved back after the yes: don't trust it
        var a = TillApprovals()
        a.give([.refund], by: "Dana", at: t0)
        XCTAssertNil(a.use(.refund, at: t0.addingTimeInterval(-600)))
    }

    func testWrongPinsLockThePadForLongerEachTime() {
        var l = PinLockout()
        for _ in 1..<PinLockout.freeTries { l.wrong(at: t0) }
        XCTAssertEqual(l.wait(at: t0), 0, "four wrong PINs: still fine")
        l.wrong(at: t0)
        XCTAssertEqual(l.wait(at: t0), PinLockout.firstWait, accuracy: 0.001)
        XCTAssertEqual(l.wait(at: t0.addingTimeInterval(31)), 0)
        l.wrong(at: t0.addingTimeInterval(31))
        XCTAssertEqual(l.wait(at: t0.addingTimeInterval(31)), PinLockout.firstWait * 2, accuracy: 0.001)
        for _ in 0..<10 { l.wrong(at: t0) }
        XCTAssertEqual(l.wait(at: t0), PinLockout.longestWait, accuracy: 0.001, "never more than five minutes")
        l.right()
        XCTAssertEqual(l.wait(at: t0), 0)
        XCTAssertEqual(l.wrongInARow, 0)
    }

    func testWhichCashNeedsAManager() {
        XCTAssertEqual(CashEvent.Kind.paidOut.permission, .cashOut)
        XCTAssertEqual(CashEvent.Kind.paidIn.permission, .cashIn)
        XCTAssertEqual(CashEvent.Kind.float.permission, .float)
        XCTAssertEqual(CashEvent.Kind.noSale.permission, .noSale)
        XCTAssertNil(CashEvent.Kind.tabPaid.permission)
        XCTAssertNil(CashEvent.Kind.deposit.permission)
    }
}
