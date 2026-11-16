import XCTest
@testable import ChargeCheckCore

final class TillProTests: XCTestCase {
    func testSellingAWholePackTakesTheWholePackOffStock() {
        let cola = PriceItem(id: "cola", name: "Cola 24x330ml", price: 7.20, till: TillInfo(sell: 0.90, packSell: 18))
        let count = StockCount(itemID: "cola", shop: "", count: 48, at: "2026-11-01T00:00:00Z")
        let sale = Sale(number: 1, shop: "", at: "2026-11-02T10:00:00Z", lines: [
            SaleLine(itemID: "cola", name: "Cola (case of 24)", qty: 1, price: 18, cost: 7.20, units: 24),
            SaleLine(itemID: "cola", name: "Cola", qty: 3, price: 0.90, cost: 0.30),
        ], payment: .cash)
        let level = StockMaths.levels(items: [cola], shop: "", invoices: [], sales: [sale], counts: [count]).first!
        XCTAssertEqual(level.onHand, 21)
        XCTAssertEqual(SaleMaths.summary([sale]).profit, 12.60)    // (18 − 7.20) + 3 × (0.90 − 0.30)
    }

    func testMultiBuyAndBasketDiscount() {
        XCTAssertEqual(SaleMaths.offerDiscount(qty: 7, price: 0.90, offer: (3, 2)), 1.40)
        XCTAssertEqual(SaleMaths.offerDiscount(qty: 2, price: 0.90, offer: (3, 2)), 0)
        XCTAssertNil(TillInfo(multiQty: 1, multiPrice: 2).offer, "1 for £2 isn't a multi-buy")
        let lines = [SaleLine(name: "A", qty: 1, price: 6, vat: 20), SaleLine(name: "B", qty: 2, price: 2, vat: 0)]
        let shared = SaleMaths.shareDiscount(1, over: lines)
        XCTAssertEqual(shared.map { $0.discount ?? 0 }, [0.6, 0.4])
        let sale = Sale(number: 1, shop: "", at: "2026-11-02T10:00:00Z", lines: shared, payment: .card)
        XCTAssertEqual(sale.total, 9)
        XCTAssertEqual(SaleMaths.summary([sale]).vat, 0.9, "VAT on the discounted price: 5.40 × 20/120")
        XCTAssertEqual(SaleMaths.shareDiscount(50, over: lines).reduce(0) { $0 + $1.gross }, 0, "never below nothing")
    }

    func testSplitPaymentAndPartRefund() {
        let sale = Sale(number: 5, shop: "s", at: "2026-11-02T10:00:00Z", lines: [
            SaleLine(id: "a", itemID: "x", name: "X", qty: 3, price: 2, discount: 0.6),
            SaleLine(id: "b", itemID: "y", name: "Y", qty: 1, price: 4),
        ], payment: .card, split: [SalePayment(kind: .cash, amount: 5), SalePayment(kind: .card, amount: 4.4)])
        XCTAssertEqual(sale.total, 9.4)
        let summary = SaleMaths.summary([sale])
        XCTAssertEqual(summary.byPayment[.cash], 5)
        XCTAssertEqual(summary.byPayment[.card], 4.4)
        let back = SaleMaths.refund(of: sale, quantities: ["a": 1], number: 6, at: "2026-11-02T11:00:00Z")
        XCTAssertEqual(back.total, -1.8, "one of three, with a third of the discount")
        let left = SaleMaths.refundable(sale, refunds: [back])
        XCTAssertEqual(left["a"], 2)
        XCTAssertEqual(left["b"], 1)
        let rest = SaleMaths.refund(of: sale, quantities: left, number: 7, at: "2026-11-02T12:00:00Z")
        XCTAssertTrue(SaleMaths.refundable(sale, refunds: [back, rest]).isEmpty)
    }

    func testEndOfDayCash() {
        let sales = [
            Sale(number: 1, shop: "s", at: "2026-11-02T10:00:00Z", lines: [SaleLine(name: "A", qty: 1, price: 10)], payment: .cash),
            Sale(number: 2, shop: "s", at: "2026-11-02T11:00:00Z", lines: [SaleLine(name: "B", qty: 1, price: 6)], payment: .card),
            Sale(number: 3, shop: "s", at: "2026-11-01T11:00:00Z", lines: [SaleLine(name: "old", qty: 1, price: 99)], payment: .cash),
        ]
        let events = [CashEvent(shop: "s", at: "2026-11-02T08:00:00Z", kind: .float, amount: 50),
                      CashEvent(shop: "s", at: "2026-11-02T12:00:00Z", kind: .paidOut, amount: 4.5, note: "milk")]
        var z = CashDay.report(shop: "s", since: "2026-11-01T23:59:59Z", to: "2026-11-02T23:00:00Z", sales: sales, events: events, number: 3)
        XCTAssertEqual(z.takings, 16)
        XCTAssertEqual(z.cash, 10)
        XCTAssertEqual(z.card, 6)
        XCTAssertEqual(z.expected, 55.5)
        z.counted = 55
        XCTAssertEqual(z.difference, -0.5)
        XCTAssertTrue(CashDay.text(z, shopName: "Market Road", currency: "GBP").contains("Z3"))
    }

    func testReports() {
        let items = [PriceItem(id: "x", cat: "Drinks", name: "X", price: 1), PriceItem(id: "y", cat: "", name: "Y", price: 1)]
        let sales = [Sale(number: 1, shop: "", at: "2026-11-02T10:00:00Z", lines: [
            SaleLine(itemID: "x", name: "X", qty: 2, price: 3, cost: 1), SaleLine(itemID: "y", name: "Y", qty: 1, price: 1)], payment: .cash, cashier: "Sara")]
        XCTAssertEqual(SalesReports.byItem(sales).first?.name, "X")
        XCTAssertEqual(SalesReports.byItem(sales).first?.profit, 4)
        XCTAssertNil(SalesReports.byItem(sales).last?.profit, "no cost known")
        XCTAssertEqual(SalesReports.byCategory(sales, items: items, other: "Other").map(\.name), ["Drinks", "Other"])
        XCTAssertEqual(SalesReports.byCashier(sales, nobody: "-").first?.name, "Sara")
        XCTAssertEqual(SalesReports.byHour(sales).count, 1)
        XCTAssertTrue(SalesReports.csv(sales).contains("Sara"))
    }

    func testImportFromAnotherTill() {
        let csv = "\u{FEFF}Product Name;Retail Price;Cost Price;EAN;Department;VAT;Stock\n"
            + "\"Cola, 330ml\";0,90;0,30;5000112637922;Drinks;20%;48\n"
            + "Paracetamol 16;0.75;;5012345678900;Medicine;0;\n"
            + ";1;;;;;\n"
        let (products, columns) = ProductImport.parse(csv)
        XCTAssertEqual(columns["name"], "Product Name")
        XCTAssertEqual(columns["price"], "Retail Price")
        XCTAssertEqual(columns["cost"], "Cost Price")
        XCTAssertEqual(products.count, 2)
        XCTAssertEqual(products[0], ImportedProduct(name: "Cola, 330ml", sell: 0.9, cost: 0.3, barcode: "5000112637922", category: "Drinks", vat: 20, stock: 48))
        XCTAssertNil(products[1].cost)
        XCTAssertEqual(products[1].vat, 0)
    }

    func testTillOnlyItemsAreNeverMatchedToInvoices() {
        let own = PriceItem(id: "own", name: "Chicken Wrap", price: 1.20, till: TillInfo(sell: 3, tillOnly: true))
        let bought = PriceItem(id: "b", name: "Chicken Breast 9kg", price: 45)
        let book = PriceBook([own, bought])
        XCTAssertNil(book.item("own"))
        XCTAssertNotNil(book.item("b"))
        XCTAssertTrue(own.isTillOnly)
    }

    func testReceiptDetails() {
        let sale = Sale(number: 2, shop: "", at: "2026-11-02T10:00:00Z", lines: [SaleLine(name: "A", qty: 1, price: 5, discount: 1)],
                        payment: .cash, tendered: 10, cashier: "Sara")
        let text = SaleMaths.receipt(sale, shopName: "Shop", currency: "GBP", header: "1 Market Road", footer: "See you soon", vatNumber: "GB123")
        XCTAssertTrue(text.contains("1 Market Road"))
        XCTAssertTrue(text.contains("GB123"))
        XCTAssertTrue(text.contains("See you soon"))
        XCTAssertTrue(text.contains("Sara"))
        XCTAssertTrue(text.contains("£6.00"), "change from £10 on £4")
    }
}
