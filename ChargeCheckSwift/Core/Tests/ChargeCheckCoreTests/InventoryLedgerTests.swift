import XCTest
@testable import ChargeCheckCore

final class InventoryLedgerTests: XCTestCase {
    private let cola = PriceItem(id: "cola", name: "Cola 24x330ml", price: 10, till: TillInfo(sell: 1, perPack: 24, low: 12))

    private func delivery(_ id: String, packs: Double, at: String, short: Double = 0, duplicateOf: String? = nil) -> HistoryEntry {
        var e = HistoryEntry(id: id, savedAt: at, supplier: "Bookers", invNo: "INV-" + id, date: "", net: 10, total: 12, over: 0,
                             lines: [HistoryLine(qty: packs, desc: "Cola", unit: 10, matchId: "cola", short: short)])
        e.duplicateOf = duplicateOf
        return e
    }

    private func sale(_ id: String, qty: Double, at: String) -> Sale {
        Sale(id: id, number: 1, shop: "", at: at, lines: [SaleLine(id: "l", itemID: "cola", name: "Cola", qty: qty, price: 1)], payment: .cash)
    }

    func testTheLedgerExplainsTheStockFigureExactly() {
        let counts = [StockCount(itemID: "cola", shop: "", count: 30, at: "2026-11-01T08:00:00Z")]
        let invoices = [delivery("a", packs: 2, at: "2026-11-02T09:00:00Z", short: 0.5),          // 1.5 packs = 36
                        delivery("b", packs: 1, at: "2026-11-03T09:00:00Z", duplicateOf: "a"),     // a copy: not stock
                        delivery("old", packs: 5, at: "2026-10-30T09:00:00Z")]                     // before the count
        let sales = [sale("s1", qty: 10, at: "2026-11-02T12:00:00Z"), sale("s2", qty: -2, at: "2026-11-02T13:00:00Z"),
                     sale("s0", qty: 4, at: "2026-10-31T12:00:00Z")]
        let moves = InventoryLedger.movements(item: cola, shop: "", invoices: invoices, sales: sales, counts: counts)
        XCTAssertEqual(moves.map(\.kind), [.counted, .delivered, .sold, .refunded])
        XCTAssertEqual(moves.map(\.qty), [30, 36, -10, 2])
        let level = StockMaths.levels(items: [cola], shop: "", invoices: invoices, sales: sales, counts: counts).first
        XCTAssertEqual(InventoryLedger.onHand(moves), level?.onHand)
        XCTAssertEqual(InventoryLedger.onHand(moves), 58)
    }

    func testTheSameSaleOrInvoiceSeenTwiceCountsOnce() {
        let s = sale("s1", qty: 3, at: "2026-11-02T12:00:00Z")
        let d = delivery("a", packs: 1, at: "2026-11-02T09:00:00Z")
        let moves = InventoryLedger.movements(item: cola, shop: "", invoices: [d, d], sales: [s, s], counts: [])
        XCTAssertEqual(moves.count, 2)
        XCTAssertEqual(InventoryLedger.onHand(moves), 21)
    }

    func testAgreesWithTheStockFigureOnManyRandomDays() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let invoices = (0..<Int.random(in: 0...6, using: &rng)).map { i in
                delivery("i\(i)", packs: Double(Int.random(in: 1...5, using: &rng)), at: "2026-11-0\(Int.random(in: 1...9, using: &rng))T09:00:00Z")
            }
            let sales = (0..<Int.random(in: 0...12, using: &rng)).map { i in
                sale("s\(i)", qty: Double(Int.random(in: -3...20, using: &rng)), at: "2026-11-0\(Int.random(in: 1...9, using: &rng))T12:00:00Z")
            }
            let counts = Bool.random(using: &rng) ? [StockCount(itemID: "cola", shop: "", count: 50, at: "2026-11-04T08:00:00Z")] : []
            let moves = InventoryLedger.movements(item: cola, shop: "", invoices: invoices, sales: sales, counts: counts)
            let level = StockMaths.levels(items: [cola], shop: "", invoices: invoices, sales: sales, counts: counts).first
            XCTAssertEqual(InventoryLedger.onHand(moves), level?.onHand ?? 0, accuracy: 0.0001)
        }
    }
}
