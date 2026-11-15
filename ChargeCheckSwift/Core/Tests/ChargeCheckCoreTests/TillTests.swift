import XCTest
@testable import ChargeCheckCore

final class TillTests: XCTestCase {
    let cola = PriceItem(id: "cola", cat: "Drinks", name: "Cola 24x330ml", price: 7.20, supplier: "Bookers",
                         till: TillInfo(sell: 0.90, vat: 20, low: 12))
    let paracetamol = PriceItem(id: "para", cat: "Medicine", name: "Paracetamol 16s", price: 3.00, supplier: "Phoenix",
                                till: TillInfo(sell: 0.75, perPack: 10, vat: 0, low: 5, orderPacks: 2))

    func testUnitCostAndProfit() {
        XCTAssertEqual(cola.unitsPerPack, 24)
        XCTAssertEqual(cola.unitCost(), 0.30)
        XCTAssertEqual(SaleMaths.unitProfit(cola), 0.45)          // 0.90 / 1.2 = 0.75 − 0.30
        XCTAssertEqual(paracetamol.unitsPerPack, 10, "set by hand wins over the name")
        XCTAssertEqual(SaleMaths.unitProfit(paracetamol), 0.45)
        XCTAssertNil(SaleMaths.unitProfit(PriceItem(name: "x", price: 1)))
    }

    func testSalesSummaryWithVATCostAndRefund() {
        let sale = Sale(number: 1, shop: "s1", at: "2026-11-16T10:00:00Z", lines: [
            SaleLine(itemID: "cola", name: "Cola", qty: 2, price: 0.90, vat: 20, cost: 0.30),
            SaleLine(itemID: "para", name: "Paracetamol", qty: 1, price: 0.75, vat: 0, cost: 0.30),
            SaleLine(name: "Something", qty: 1, price: 1.00),
        ], payment: .cash, tendered: 5)
        let refund = SaleMaths.refund(of: sale, number: 2, at: "2026-11-16T11:00:00Z")
        XCTAssertEqual(sale.total, 3.55)
        XCTAssertEqual(refund.total, -3.55)
        let one = SaleMaths.summary([sale])
        XCTAssertEqual(one.takings, 3.55)
        XCTAssertEqual(one.vat, 0.30)
        XCTAssertEqual(one.profit, 1.35)             // 1.50 − 0.60 + 0.75 − 0.30
        XCTAssertEqual(one.unknownCost, 1)
        XCTAssertEqual(one.margin, 60)               // 1.35 ÷ 2.25
        XCTAssertEqual(one.byPayment[.cash], 3.55)
        let both = SaleMaths.summary([sale, refund])
        XCTAssertEqual(both.takings, 0)
        XCTAssertEqual(both.profit, 0)
        XCTAssertEqual(both.sales, 1)
        XCTAssertEqual(both.refunds, 1)
        XCTAssertEqual(SaleMaths.change(tendered: 5, total: 3.55), 1.45)
        XCTAssertEqual(SaleMaths.change(tendered: 2, total: 3.55), 0)
    }

    func testStockFromCountDeliveriesAndSales() {
        let count = StockCount(itemID: "cola", shop: "s1", count: 10, at: "2026-11-10T09:00:00Z")
        var before = HistoryEntry(savedAt: "2026-11-09T09:00:00Z", supplier: "Bookers", net: 0, total: 0, over: 0,
                                  lines: [HistoryLine(qty: 5, desc: "Cola", unit: 7.2, matchId: "cola", item: "Cola")])
        before.shopId = "s1"
        var delivery = HistoryEntry(savedAt: "2026-11-12T09:00:00Z", supplier: "Bookers", net: 0, total: 0, over: 0,
                                    lines: [HistoryLine(qty: 2, desc: "Cola", unit: 7.2, matchId: "cola", item: "Cola", short: 1)])
        delivery.shopId = "s1"
        var otherShop = delivery
        otherShop.shopId = "s2"
        let sales = [
            Sale(number: 1, shop: "s1", at: "2026-11-13T10:00:00Z", lines: [SaleLine(itemID: "cola", name: "Cola", qty: 20, price: 0.9)], payment: .card),
            Sale(number: 2, shop: "s1", at: "2026-11-09T10:00:00Z", lines: [SaleLine(itemID: "cola", name: "Cola", qty: 99, price: 0.9)], payment: .card),
            Sale(number: 3, shop: "s2", at: "2026-11-13T10:00:00Z", lines: [SaleLine(itemID: "cola", name: "Cola", qty: 7, price: 0.9)], payment: .card),
        ]
        let levels = StockMaths.levels(items: [cola, paracetamol], shop: "s1", invoices: [before, delivery, otherShop], sales: sales, counts: [count])
        let colaLevel = levels.first { $0.itemID == "cola" }!
        // 10 counted + 1 case delivered (2 billed, 1 short) × 24 − 20 sold; earlier invoice and sale were before the count
        XCTAssertEqual(colaLevel.onHand, 14)
        XCTAssertFalse(colaLevel.isLow)
        XCTAssertTrue(colaLevel.counted)
        let para = levels.first { $0.itemID == "para" }!
        XCTAssertEqual(para.onHand, 0)
        XCTAssertTrue(para.isLow)
        XCTAssertEqual(levels.first?.itemID, "para", "low items first")
    }

    func testReordersPerSupplier() {
        let levels = [
            StockLevel(itemID: "cola", name: "Cola 24x330ml", supplier: "Bookers", onHand: 3, low: 12, counted: true, delivered: 0, sold: 0),
            StockLevel(itemID: "para", name: "Paracetamol 16s", supplier: "Phoenix", onHand: 1, low: 5, counted: true, delivered: 0, sold: 0),
        ]
        let orders = StockMaths.reorders(levels, items: [cola, paracetamol], noSupplier: "No supplier")
        XCTAssertEqual(orders.map(\.supplier), ["Bookers", "Phoenix"])
        XCTAssertEqual(orders[0].lines.first?.qty, 1, "(24 − 3) ÷ 24 → 1 case")
        XCTAssertEqual(orders[1].lines.first?.qty, 2, "the item's own order amount")
    }

    func testReceiptAndBarcodes() {
        var item = cola
        item.till?.barcodes = ["5000112637922"]
        XCTAssertTrue(item.hasBarcode("5000112637922"))
        XCTAssertFalse(item.hasBarcode(""))
        let sale = Sale(number: 7, shop: "s1", at: "2026-11-16T10:05:00Z", lines: [SaleLine(itemID: "cola", name: "Cola", qty: 2, price: 0.9, vat: 20)],
                        payment: .cash, tendered: 2)
        let text = SaleMaths.receipt(sale, shopName: "Market Road", currency: "GBP")
        XCTAssertTrue(text.contains("#7"))
        XCTAssertTrue(text.contains("2 × Cola"))
        XCTAssertTrue(text.contains("£1.80"))
        XCTAssertTrue(text.contains("£0.20"), "change")
    }

    func testTillInfoIsSavedWithTheItem() throws {
        let read = try JSONDecoder().decode(PriceItem.self, from: JSONEncoder().encode(paracetamol))
        XCTAssertEqual(read.till?.perPack, 10)
        let old = try JSONDecoder().decode(PriceItem.self, from: Data(#"{"id":"a","name":"Oil","price":3}"#.utf8))
        XCTAssertNil(old.till)
        XCTAssertNil(PriceItem(name: "x", price: 1, till: TillInfo()).till, "an empty till record isn't kept")
    }
}
