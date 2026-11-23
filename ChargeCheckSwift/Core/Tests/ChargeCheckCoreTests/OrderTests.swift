import XCTest
@testable import ChargeCheckCore

final class OrderTests: XCTestCase {
    private func line(_ id: String, _ name: String, qty: Double, unit: Double, short: Double = 0, excluded: Bool = false) -> HistoryLine {
        HistoryLine(qty: qty, desc: name, unit: unit, matchId: id, item: name, excluded: excluded, short: short)
    }

    func testOrderedDeliveredInvoiced() {
        let order = PurchaseOrder(supplier: "APEX", day: "2026-11-10", lines: [
            OrderLine(itemID: "chk", name: "Chicken Breast 9kg", qty: 2),
            OrderLine(itemID: "box", name: "HP10 Box", qty: 1),
            OrderLine(itemID: "oil", name: "Oil 20L", qty: 1),
            OrderLine(itemID: "buns", name: "Buns 48", qty: 4),
        ])
        let invoice = HistoryEntry(supplier: "APEX", net: 0, total: 0, over: 0, lines: [
            line("chk", "Chicken Breast 9kg", qty: 2, unit: 47.5, short: 1),   // billed 2, 1 came
            line("box", "HP10 Box", qty: 3, unit: 20),                          // 2 extra
            line("mayo", "Mayo 10L", qty: 1, unit: 15),                         // never ordered
            line("buns", "Buns 48", qty: 3, unit: 9.6),                         // 1 short, not billed
        ])
        let gaps = OrderMaths.compare(order, with: invoice)
        XCTAssertEqual(gaps.map(\.kind), [.billedNotDelivered, .extra, .notOrdered, .short, .notArrived])
        XCTAssertEqual(gaps[0].amount, 47.5)
        XCTAssertEqual(gaps[1].amount, 40)
        XCTAssertEqual(gaps[2].name, "Mayo 10L")
        XCTAssertEqual(gaps[3].invoiced, 3)
        XCTAssertEqual(gaps[4].name, "Oil 20L")
    }

    func testAllAsOrderedHasNoGaps() {
        let order = PurchaseOrder(supplier: "APEX", day: "2026-11-10", lines: [OrderLine(itemID: "chk", name: "Chicken", qty: 2)])
        let invoice = HistoryEntry(supplier: "APEX", net: 0, total: 0, over: 0, lines: [line("chk", "Chicken", qty: 2, unit: 10)])
        XCTAssertTrue(OrderMaths.compare(order, with: invoice).isEmpty)
    }

    func testMissingLineDeliveredNothing() {
        let order = PurchaseOrder(supplier: "APEX", day: "2026-11-10", lines: [OrderLine(itemID: "chk", name: "Chicken", qty: 1)])
        let invoice = HistoryEntry(supplier: "APEX", net: 0, total: 0, over: 0, lines: [line("chk", "Chicken", qty: 1, unit: 10, excluded: true)])
        let gaps = OrderMaths.compare(order, with: invoice)
        XCTAssertEqual(gaps.first?.kind, .billedNotDelivered)
        XCTAssertEqual(gaps.first?.amount, 10)
    }

    func testUsualQuantities() {
        let entries = (0..<5).map { n in
            HistoryEntry(savedAt: "2026-11-0\(n + 1)T10:00:00Z", supplier: "APEX", net: 0, total: 0, over: 0, lines: [
                line("chk", "Chicken Breast 9kg", qty: n == 4 ? 9 : 2, unit: 47.5),
                line("box", "HP10 Box", qty: 1, unit: 20),
            ] + (n == 0 ? [line("once", "Once only", qty: 1, unit: 5)] : []))
        }
        let usual = OrderMaths.usual(from: entries, supplier: "Apex", invoices: 8)
        XCTAssertEqual(usual.map(\.name), ["Chicken Breast 9kg", "HP10 Box"])
        XCTAssertEqual(usual[0].qty, 2, "the typical amount, not one big week")
        XCTAssertEqual(usual[0].itemID, "chk")
    }

    func testMessageAndLikelyInvoice() {
        let order = PurchaseOrder(supplier: "APEX", day: "2026-11-10", lines: [OrderLine(name: "Chicken", qty: 2), OrderLine(name: "Oil", qty: 0.5)])
        let text = OrderMaths.message(order, from: "Burger Bar", deliveryDay: "Thu 12 Nov")
        XCTAssertTrue(text.contains("Order – Burger Bar"))
        XCTAssertTrue(text.contains("2 × Chicken"))
        XCTAssertTrue(text.contains("0.5 × Oil"))
        let before = HistoryEntry(id: "a", savedAt: "2026-11-09T10:00:00Z", supplier: "APEX", net: 0, total: 0, over: 0, lines: [])
        let after = HistoryEntry(id: "b", savedAt: "2026-11-12T10:00:00Z", supplier: "APEX", net: 0, total: 0, over: 0, lines: [])
        let other = HistoryEntry(id: "c", savedAt: "2026-11-11T10:00:00Z", supplier: "Brakes", net: 0, total: 0, over: 0, lines: [])
        XCTAssertEqual(OrderMaths.likelyInvoice(for: order, in: [before, after, other], taken: [])?.id, "b")
        XCTAssertNil(OrderMaths.likelyInvoice(for: order, in: [before, after, other], taken: ["b"]))
    }

    func testOrdersSurviveABackup() throws {
        let backup = BackupFile(baseline: [], orders: [PurchaseOrder(supplier: "APEX", day: "2026-11-10", lines: [OrderLine(name: "Chicken", qty: 2)])])
        let read = try BackupFile.read(try JSONEncoder().encode(backup))
        XCTAssertEqual(read.orders?.first?.lines.first?.qty, 2)
    }
}
