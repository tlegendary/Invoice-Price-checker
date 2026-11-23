import XCTest
@testable import ChargeCheckCore

final class RetailTests: XCTestCase {
    func testATransferIsInTransitUntilItArrivesAndShortagesShow() {
        let sent = StockTransfer(itemID: "cola", name: "Cola", units: 24, from: "A", to: "B", sentAt: "2026-11-23T09:00:00Z", sentBy: "Sara")
        XCTAssertTrue(sent.inTransit)
        let arrived = Transfers.receive(sent, units: 22, by: "Ali", at: "2026-11-23T15:00:00Z")
        XCTAssertFalse(arrived.inTransit)
        XCTAssertEqual(arrived.missing, 2)
        XCTAssertEqual(Transfers.receive(arrived, units: 24, by: "X", at: "z"), arrived, "received once")
    }

    func testTheTillThatSaysItArrivedWins() {
        let sent = StockTransfer(id: "t", itemID: "cola", name: "Cola", units: 24, from: "A", to: "B", sentAt: "2026-11-23T09:00:00Z")
        let arrived = Transfers.receive(sent, units: 24, by: "Ali", at: "2026-11-23T15:00:00Z")
        XCTAssertEqual(Transfers.merge([[arrived], [sent]]).first?.inTransit, false)
        XCTAssertEqual(Transfers.merge([[sent], [arrived]]).first?.inTransit, false)
        XCTAssertEqual(Transfers.merge([[sent], [sent]]).count, 1)
    }

    func testStocktakeVariancesAtCost() {
        let take = Stocktake(shop: "A", startedAt: "2026-11-23T20:00:00Z",
                             expected: ["cola": 40, "crisps": 12, "water": 30],
                             counted: ["cola": 36, "crisps": 12, "water": 31])
        let cost = ["cola": 0.45, "crisps": 0.3, "water": 0.2]
        let v = take.variances(cost: { cost[$0] ?? 0 })
        XCTAssertEqual(v.map(\.itemID), ["cola", "water"], "unchanged items aren't listed; biggest money first")
        XCTAssertEqual(v.map(\.difference), [-4, 1])
        XCTAssertEqual(v.map(\.value), [-1.8, 0.2])
        XCTAssertEqual(take.netValue(cost: { cost[$0] ?? 0 }), -1.6)
    }
}
