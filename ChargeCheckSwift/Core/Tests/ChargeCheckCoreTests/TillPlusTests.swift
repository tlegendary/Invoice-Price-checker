import XCTest
@testable import ChargeCheckCore

final class TillPlusTests: XCTestCase {
    // MARK: roles

    func testCashiersNeedAManagerForRefundsOnceThereIsOne() {
        let can = TillPermission.cashierDefault
        XCTAssertTrue(TillRoles.allows(nil, .refund, cashierCan: can, hasManagers: false), "no managers yet: nothing locked")
        XCTAssertFalse(TillRoles.allows(.cashier, .refund, cashierCan: can, hasManagers: true))
        XCTAssertFalse(TillRoles.allows(.cashier, .cashOut, cashierCan: can, hasManagers: true))
        XCTAssertFalse(TillRoles.allows(.cashier, .closeDay, cashierCan: can, hasManagers: true))
        XCTAssertTrue(TillRoles.allows(.cashier, .customAmount, cashierCan: can, hasManagers: true))
        XCTAssertTrue(TillRoles.allows(.manager, .refund, cashierCan: can, hasManagers: true))
        XCTAssertFalse(TillRoles.allows(.cashier, .settings, cashierCan: Set(TillPermission.allCases), hasManagers: true),
                       "settings are never a cashier's")
        XCTAssertFalse(TillRoles.allows(nil, .discount, cashierCan: can, hasManagers: true), "nobody signed in")
    }

    // MARK: several tills

    func testEachTillHasItsOwnFileAndSalesMergeOnce() {
        XCTAssertEqual(TillSync.fileName("Sales 2026-11", till: "B"), "Sales 2026-11 ~B.json")
        XCTAssertEqual(TillSync.till(ofFile: "Sales 2026-11 ~B.json"), "B")
        XCTAssertNil(TillSync.till(ofFile: "Sales 2026-11.json"), "a file from before tills had names")
        let a = Sale(id: "1", number: 1, shop: "", at: "2026-11-02T10:00:00Z", lines: [], payment: .cash, till: "A")
        let b = Sale(id: "2", number: 1, shop: "", at: "2026-11-02T10:00:01Z", lines: [], payment: .cash, till: "B")
        let merged = TillSync.merge([[a], [b, a]])
        XCTAssertEqual(merged.map(\.id), ["2", "1"])
        XCTAssertEqual(b.receiptNumber, "B-1")
        XCTAssertEqual(Sale(number: 7, shop: "", at: "", lines: [], payment: .cash).receiptNumber, "7")
        XCTAssertEqual(TillSync.nextCode(taken: ["A", "B"]), "C")
    }

    func testTheLatestStockCountWinsAcrossTills() {
        let older = StockCount(itemID: "x", shop: "s", count: 10, at: "2026-11-01T00:00:00Z")
        let newer = StockCount(itemID: "x", shop: "s", count: 4, at: "2026-11-03T00:00:00Z")
        XCTAssertEqual(TillSync.mergeCounts([[newer], [older]]).map(\.count), [4])
    }

    func testEachTillHasItsOwnDrawerAtTheEndOfTheDay() {
        let a = Sale(number: 1, shop: "s", at: "2026-11-02T10:00:00Z", lines: [SaleLine(name: "x", qty: 1, price: 5)], payment: .cash, till: "A")
        let b = Sale(number: 1, shop: "s", at: "2026-11-02T10:05:00Z", lines: [SaleLine(name: "y", qty: 1, price: 3)], payment: .cash, till: "B")
        let float = CashEvent(shop: "s", at: "2026-11-02T08:00:00Z", kind: .float, amount: 50, till: "B")
        let reportB = CashDay.report(shop: "s", since: "", to: "2026-11-02T23:00:00Z", sales: [a, b], events: [float], number: 1, till: "B")
        XCTAssertEqual(reportB.cash, 3)
        XCTAssertEqual(reportB.expected, 53)
        let shop = CashDay.report(shop: "s", since: "", to: "2026-11-02T23:00:00Z", sales: [a, b], events: [float], number: 1)
        XCTAssertEqual(shop.takings, 8)
    }

    // MARK: weight

    func testWeighedItemsAndScaleLabels() {
        XCTAssertEqual(Weight.parse("452"), 0.452, "grams without a point")
        XCTAssertEqual(Weight.parse("1,2"), 1.2)
        XCTAssertEqual(Weight.parse("0.5 kg"), 0.5)
        XCTAssertNil(Weight.parse("0"))
        XCTAssertEqual(Weight.text(0.452), "0.452 kg")
        XCTAssertEqual(Weight.text(1.2), "1.2 kg")
        XCTAssertEqual(Weight.price(kg: 0.452, perKg: 3.99), 1.80)

        XCTAssertEqual(ScaleBarcode.read("2012345004528", carries: .weight), ScaleBarcode.Read(lookup: "2012345", value: 0.452))
        XCTAssertEqual(ScaleBarcode.read("2012345012998", carries: .price), ScaleBarcode.Read(lookup: "2012345", value: 12.99))
        XCTAssertNil(ScaleBarcode.read("2012345004527", carries: .weight), "wrong check digit")
        XCTAssertNil(ScaleBarcode.read("5012345004528", carries: .weight), "not a shop label")

        // stock in kg: 10 kg counted, 0.452 kg sold
        let rice = PriceItem(id: "rice", name: "Rice loose", price: 15, till: TillInfo(sell: 3.99, perPack: 10, byWeight: true))
        let sale = Sale(number: 1, shop: "", at: "2026-11-02T10:00:00Z",
                        lines: [SaleLine(itemID: "rice", name: "Rice loose", qty: 0.452, price: 3.99, cost: 1.5, weighed: true)], payment: .cash)
        let count = StockCount(itemID: "rice", shop: "", count: 10, at: "2026-11-01T00:00:00Z")
        XCTAssertEqual(StockMaths.levels(items: [rice], shop: "", invoices: [], sales: [sale], counts: [count]).first?.onHand, 9.548)
        XCTAssertEqual(rice.unitCost(), 1.5, "a 10 kg sack at £15 is £1.50 a kg")
        XCTAssertTrue(SaleMaths.receipt(sale, shopName: "", currency: "GBP").contains("0.452 kg"))
    }

    // MARK: batches

    func testShortestDatedBatchesAreSoldFirst() {
        let early = StockBatch(id: "e", itemID: "p", shop: "", code: "L1", expiry: "2026-12-01", qty: 10, at: "2026-10-01T00:00:00Z")
        let late = StockBatch(id: "l", itemID: "p", shop: "", code: "L2", expiry: "2027-06-01", qty: 10, at: "2026-11-01T00:00:00Z")
        let shelf = BatchMaths.onShelf([early, late], onHand: 14, today: "2026-11-20")
        XCTAssertEqual(shelf.map(\.batch.code), ["L1", "L2"])
        XCTAssertEqual(shelf.map(\.left), [4, 10])
        XCTAssertEqual(shelf.first?.days, 11)
        XCTAssertEqual(BatchMaths.onShelf([early, late], onHand: 6, today: "2026-11-20").map(\.batch.code), ["L2"], "the early batch is gone")
        let soon = BatchMaths.expiring([("Paracetamol", shelf)], within: 30)
        XCTAssertEqual(soon.map(\.batch.batch.code), ["L1"])
        XCTAssertEqual(BatchMaths.onShelf([early], onHand: 5, today: "2026-12-05").first?.days, -4, "expired")
    }

    func testExpiryDatesAsTheyArePrintedOnBoxes() {
        XCTAssertEqual(BatchMaths.parseExpiry("2027-03-31"), "2027-03-31")
        XCTAssertEqual(BatchMaths.parseExpiry("31/03/2027"), "2027-03-31")
        XCTAssertEqual(BatchMaths.parseExpiry("03/27"), "2027-03-31", "month/year means the end of that month")
        XCTAssertEqual(BatchMaths.parseExpiry("2/2028"), "2028-02-29")
        XCTAssertNil(BatchMaths.parseExpiry("13/2027"))
        XCTAssertNil(BatchMaths.parseExpiry("soon"))
    }

    // MARK: meal deals

    func testMealDealTakesTheDearestItemsThatFit() {
        let deal = MealDeal(name: "Meal deal", price: 4, slots: [
            DealSlot(name: "Sandwich", categories: ["Sandwiches"]),
            DealSlot(name: "Drink", categories: ["Drinks"]),
            DealSlot(name: "Snack", items: ["crisps"]),
        ])
        let lines = [
            DealLine(key: "s", itemID: "blt", category: "Sandwiches", price: 3.00, qty: 2),
            DealLine(key: "d", itemID: "cola", category: "Drinks", price: 1.50, qty: 1),
            DealLine(key: "c", itemID: "crisps", category: "Snacks", price: 1.00, qty: 3),
        ]
        let result = DealMaths.apply(lines, deals: [deal])
        XCTAssertEqual(result.applied["Meal deal"], 1, "only one drink, so one deal")
        XCTAssertEqual(result.total, 1.50)
        XCTAssertEqual((result.off["s"] ?? 0) + (result.off["d"] ?? 0) + (result.off["c"] ?? 0), 1.50, accuracy: 0.0001)
        XCTAssertEqual(result.used, ["s": 1, "d": 1, "c": 1])
        // a deal that would cost more than buying the items isn't applied
        let cheap = [DealLine(key: "s", itemID: "x", category: "Sandwiches", price: 1, qty: 1),
                     DealLine(key: "d", itemID: "y", category: "Drinks", price: 1, qty: 1),
                     DealLine(key: "c", itemID: "crisps", category: "Snacks", price: 1, qty: 1)]
        XCTAssertEqual(DealMaths.apply(cheap, deals: [deal]).total, 0)
        XCTAssertTrue(deal.isOn(shop: "any"))
        XCTAssertFalse(MealDeal(name: "x", price: 4, slots: deal.slots, shops: ["a"]).isOn(shop: "b"))
    }

    // MARK: customers

    func testPointsTabAndGiftCards() {
        let loyalty = LoyaltySettings(perPound: 1, worth: 0.01)
        let buy = Sale(id: "1", number: 1, shop: "", at: "2026-11-02T10:00:00Z", lines: [SaleLine(name: "x", qty: 1, price: 12.80)],
                       payment: .card, customer: "ali")
        let onTab = Sale(id: "2", number: 2, shop: "", at: "2026-11-03T10:00:00Z", lines: [SaleLine(name: "y", qty: 1, price: 20)],
                         payment: .tab, split: [SalePayment(kind: .tab, amount: 20, ref: "ali")], customer: "ali")
        let spend = Sale(id: "3", number: 3, shop: "", at: "2026-11-04T10:00:00Z", lines: [SaleLine(name: "z", qty: 1, price: 1)],
                         payment: .points, split: [SalePayment(kind: .points, amount: 0.30, ref: "ali"), SalePayment(kind: .cash, amount: 0.70)],
                         customer: "ali")
        let paid = CashEvent(shop: "", at: "2026-11-05T10:00:00Z", kind: .tabPaid, amount: 15, ref: "ali")
        let balance = CustomerMaths.balance("ali", sales: [buy, onTab, spend], events: [paid], loyalty: loyalty)
        XCTAssertEqual(balance.points, 12 + 20 + 0 - 30, "points earned on money and tab, 30 spent")
        XCTAssertEqual(balance.tab, 5)
        XCTAssertEqual(balance.visits, 3)
        let ali = Customer(id: "ali", name: "Ali", tabLimit: 50, at: "")
        XCTAssertTrue(CustomerMaths.tabAllows(ali, owed: 5, adding: 45))
        XCTAssertFalse(CustomerMaths.tabAllows(ali, owed: 5, adding: 45.01))
        XCTAssertFalse(CustomerMaths.tabAllows(Customer(name: "No tab", at: ""), owed: 0, adding: 1))

        // tab paid off in cash goes into the drawer
        let day = CashDay.report(shop: "", since: "", to: "2026-11-06T00:00:00Z", sales: [buy, onTab, spend], events: [paid], number: 1)
        XCTAssertEqual(day.expected, 0.70 + 15)
        XCTAssertEqual(day.tab, 20)
        XCTAssertEqual(day.takings, 33.80, "goods sold, however they were paid")
    }

    func testGiftCardsAreNotTakingsUntilTheyAreSpent() {
        let code = GiftCards.newCode(taken: [])
        XCTAssertTrue(GiftCards.looksValid(code))
        XCTAssertFalse(GiftCards.looksValid(String(code.dropLast()) + (code.last == "1" ? "2" : "1")))
        let sold = Sale(id: "g", number: 1, shop: "", at: "2026-11-02T10:00:00Z",
                        lines: [SaleLine(name: "Gift card", qty: 1, price: 25, cost: 25, giftCard: code)], payment: .cash, tendered: 25)
        let summary = SaleMaths.summary([sold])
        XCTAssertEqual(summary.takings, 0)
        XCTAssertEqual(summary.giftSold, 25)
        XCTAssertEqual(summary.byPayment[.cash], 25, "but the cash is in the drawer")
        let card = GiftCards.sold(in: [sold]).first!
        XCTAssertEqual(card.amount, 25)
        let spent = Sale(id: "s", number: 2, shop: "", at: "2026-11-03T10:00:00Z", lines: [SaleLine(name: "x", qty: 1, price: 10)],
                         payment: .gift, split: [SalePayment(kind: .gift, amount: 10, ref: code)])
        XCTAssertEqual(GiftCards.balance(card, sales: [sold, spent]), 15)
        let refund = SaleMaths.refund(of: spent, number: 3, at: "2026-11-04T10:00:00Z")
        XCTAssertEqual(refund.payments.first?.kind, .gift, "refunded onto the card")
        XCTAssertEqual(GiftCards.balance(card, sales: [sold, spent, refund]), 25)
        XCTAssertTrue(SaleMaths.refundable(sold, refunds: []).isEmpty, "a gift card sold can't be refunded as goods")
    }

    func testAMixedRefundGoesBackWhereItCameFrom() {
        let code = "712345678904"
        let sale = Sale(id: "m", number: 1, shop: "", at: "2026-11-02T10:00:00Z",
                        lines: [SaleLine(id: "l", name: "x", qty: 2, price: 5)], payment: .cash,
                        split: [SalePayment(kind: .gift, amount: 6, ref: code), SalePayment(kind: .cash, amount: 4)])
        let all = SaleMaths.refund(of: sale, number: 2, at: "2026-11-03T10:00:00Z")
        XCTAssertEqual(all.payments, [SalePayment(kind: .gift, amount: -6, ref: code), SalePayment(kind: .cash, amount: -4)],
                       "the gift card part goes back on the card, not out of the drawer")
        let half = SaleMaths.refund(of: sale, quantities: ["l": 1], number: 3, at: "2026-11-03T10:00:00Z")
        XCTAssertEqual(half.payments.map(\.amount), [-3, -2])
        let day = CashDay.report(shop: "", since: "", to: "2026-11-04T00:00:00Z", sales: [sale, all], events: [], number: 1)
        XCTAssertEqual(day.cash, 0, "4 in, 4 back out")
    }

    // MARK: clocking in

    func testHoursWorked() {
        let events = [
            ClockEvent(person: "Sara", shop: "", at: "2026-11-02T08:00:00Z", start: true),
            ClockEvent(person: "Sara", shop: "", at: "2026-11-02T12:30:00Z", start: false),
            ClockEvent(person: "Omar", shop: "", at: "2026-11-02T10:00:00Z", start: true),
            ClockEvent(person: "Omar", shop: "", at: "2026-11-02T11:00:00Z", start: true),
        ]
        let rows = Shifts.hours(events, from: "2026-11-02T00:00:00Z", to: "2026-11-02T14:00:00Z")
        XCTAssertEqual(rows.first { $0.person == "Sara" }?.hours, 4.5)
        let omar = rows.first { $0.person == "Omar" }
        XCTAssertEqual(omar?.hours, 4, "still in since 10:00, the second clock-in doesn't restart it")
        XCTAssertEqual(omar?.inSince, "2026-11-02T10:00:00Z")
    }

    // MARK: printer

    func testReceiptPictureBytes() {
        // 10 × 2: first pixel of each row black
        var pixels = [Bool](repeating: false, count: 20)
        pixels[0] = true
        pixels[10] = true
        pixels[9] = true
        let bytes = EscPos.raster(width: 10, height: 2, pixels: pixels)
        XCTAssertEqual(Array(bytes.prefix(8)), [0x1D, 0x76, 0x30, 0x00, 2, 0, 2, 0])
        XCTAssertEqual(Array(bytes.dropFirst(8)), [0x80, 0x40, 0x80, 0x00])
        XCTAssertEqual(EscPos.raster(width: 8, height: 300, pixels: [Bool](repeating: true, count: 2400)).count, 8 + 255 + 8 + 45, "split into bands")
        let receipt = EscPos.receipt(width: 8, height: 1, pixels: [Bool](repeating: false, count: 8), openDrawer: true)
        XCTAssertEqual(Array(receipt.suffix(EscPos.openDrawer.count)), EscPos.openDrawer)
        XCTAssertEqual(EscPos.chunks(Array(repeating: 1, count: 250), size: 100).map(\.count), [100, 100, 50])
    }
}
