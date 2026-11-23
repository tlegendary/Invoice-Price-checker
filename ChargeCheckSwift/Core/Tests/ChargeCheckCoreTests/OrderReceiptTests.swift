import XCTest
@testable import ChargeCheckCore

final class OrderReceiptTests: XCTestCase {
    private let order = PurchaseOrder(id: "po1", supplier: "Bookers", day: "2026-11-20",
                                      lines: [OrderLine(itemID: "cola", name: "Cola 24x330ml", qty: 10),
                                              OrderLine(itemID: "wings", name: "Wings 2kg", qty: 4),
                                              OrderLine(name: "Napkins", qty: 2)],
                                      sent: true)

    private func invoice(_ id: String, _ lines: [HistoryLine]) -> HistoryEntry {
        HistoryEntry(id: id, savedAt: "2026-11-21T09:00:00Z", supplier: "Bookers", invNo: id, date: "", net: 1, total: 1, over: 0, lines: lines)
    }

    func testAnOrderThatComesInTwoParts() {
        let first = invoice("i1", [HistoryLine(qty: 6, desc: "Cola", unit: 10, matchId: "cola"),
                                   HistoryLine(qty: 4, desc: "Wings", unit: 20, matchId: "wings", short: 1)])
        var po = order
        po.invoiceID = "i1"
        let part = OrderMaths.receipt(po, invoices: [first])
        XCTAssertEqual(part.status, .part)
        XCTAssertEqual(part.stillToCome.map(\.name), ["Cola 24x330ml", "Wings 2kg", "Napkins"])
        XCTAssertEqual(part.stillToCome.map(\.outstanding), [4, 1, 2], "a short line delivered qty − short")

        let second = invoice("i2", [HistoryLine(qty: 4, desc: "Cola", unit: 10, matchId: "cola"),
                                    HistoryLine(qty: 1, desc: "Wings", unit: 20, matchId: "wings"),
                                    HistoryLine(qty: 2, desc: "napkins ", unit: 1)])
        po.moreInvoices = ["i2"]
        let done = OrderMaths.receipt(po, invoices: [first, second])
        XCTAssertEqual(done.deliveries, 2)
        XCTAssertEqual(done.status, .received)
    }

    func testMissingLinesDeliverNothingAndExtrasAreShown() {
        var po = order
        po.invoiceID = "i1"
        var missing = HistoryLine(qty: 10, desc: "Cola", unit: 10, matchId: "cola")
        missing.excluded = true
        let inv = invoice("i1", [missing, HistoryLine(qty: 6, desc: "Wings", unit: 20, matchId: "wings"), HistoryLine(qty: 2, desc: "Napkins", unit: 1)])
        let r = OrderMaths.receipt(po, invoices: [inv])
        XCTAssertEqual(r.status, .part, "the cola was ticked missing")
        XCTAssertEqual(r.lines.first { $0.name == "Wings 2kg" }?.extra, 2)
    }

    func testNotYetAndOldOrdersStillLoad() throws {
        XCTAssertEqual(OrderMaths.receipt(order, invoices: []).status, .notYet)
        let old = try JSONDecoder().decode(PurchaseOrder.self, from: Data(#"{"id":"x","supplier":"A","day":"2026-01-01","lines":[],"sent":true,"invoiceID":"i9"}"#.utf8))
        XCTAssertEqual(old.invoiceIDs, ["i9"])
        XCTAssertEqual(old.moreInvoices, [])
    }
}
