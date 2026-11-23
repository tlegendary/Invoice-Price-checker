import XCTest
@testable import ChargeCheckCore

final class OverspendTests: XCTestCase {
    private let card = GiftCard(code: "1234567890", amount: 20, shop: "s", at: "2026-11-01T09:00:00Z", sale: "sold")

    private func spend(_ id: String, _ amount: Double, till: String, at: String) -> Sale {
        var s = Sale(id: id, number: 1, shop: "s", at: at, lines: [SaleLine(name: "x", qty: 1, price: amount)], payment: .gift)
        s.split = [SalePayment(kind: .gift, amount: amount, ref: card.code)]
        s.till = till
        return s
    }

    func testTwoOfflineTillsSpendingTheSameCardAreFoundAndNothingIsLost() {
        // till A and till B each took £15 off a £20 card while offline; both sales are kept
        let a = spend("a", 15, till: "A", at: "2026-11-23T10:00:00Z")
        let b = spend("b", 15, till: "B", at: "2026-11-23T10:05:00Z")
        let merged = TillSync.merge([[a], [b]])
        XCTAssertEqual(merged.count, 2, "no sale lost in the merge")
        let found = Overspends.find(cards: [card], sales: merged)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.sale, "b")
        XCTAssertEqual(found.first?.till, "B")
        XCTAssertEqual(found.first?.over, 10)
        XCTAssertEqual(GiftCards.balance(card, sales: merged), -10)
    }

    func testSpendingWithinTheBalanceIsFine() {
        let sales = [spend("a", 12.5, till: "A", at: "2026-11-23T10:00:00Z"), spend("b", 7.5, till: "B", at: "2026-11-23T11:00:00Z")]
        XCTAssertEqual(Overspends.find(cards: [card], sales: sales), [])
    }

    func testTheSameSaleInTwoFilesCountsOnce() {
        let a = spend("a", 15, till: "A", at: "2026-11-23T10:00:00Z")
        let merged = TillSync.merge([[a], [a]])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(Overspends.find(cards: [card], sales: merged), [])
    }
}
