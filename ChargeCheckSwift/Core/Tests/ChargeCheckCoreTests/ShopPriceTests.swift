import XCTest
@testable import ChargeCheckCore

/// Shops with their own items and prices (a food shop and a pharmacy), and finding an invoice's shop (Nov 2026).
final class ShopPriceTests: XCTestCase {
    override func setUp() { Money.currency = .gbp }

    private let food = "food"
    private let pharmacy = "pharmacy"

    private var items: [PriceItem] {
        [
            PriceItem(id: "wings", name: "Chicken Wings 10kg", price: 14.99, shops: [food]),
            PriceItem(id: "oil", name: "Vegetable Oil 20L", price: 24.99, shops: [food]),
            PriceItem(id: "para", name: "Paracetamol 500mg 32", price: 1.20, shops: [pharmacy]),
            PriceItem(id: "plasters", name: "Plasters Assorted 40", price: 2.10, shops: [pharmacy]),
            // bought for both, a different price in the pharmacy
            PriceItem(id: "water", name: "Water 500ml x24", price: 3.50, shopPrices: [ShopPrice(shop: pharmacy, p: 3.20)])
        ]
    }

    private func entry(_ id: String, supplier: String, shop: String) -> HistoryEntry {
        HistoryEntry(id: id, shopId: shop, supplier: supplier, net: 10, total: 10, over: 0, lines: [])
    }

    func testItemsBelongToTheirShops() {
        XCTAssertTrue(items[0].isIn(shop: food))
        XCTAssertFalse(items[0].isIn(shop: pharmacy))
        XCTAssertTrue(items[4].isIn(shop: pharmacy))        // no shops = every shop
        XCTAssertTrue(items[0].isIn(shop: ""))              // all shops
    }

    func testEachShopIsCheckedAgainstItsOwnPrice() {
        let water = items[4]
        XCTAssertEqual(water.price(inShop: pharmacy), 3.20)
        XCTAssertEqual(water.price(inShop: food), 3.50)
        let line = CheckLine(qty: 2, desc: "Water 500ml x24", unit: 3.50, matchId: "water", confident: true)
        // 3.50 is the food shop's price: fine there, 30p too much a case in the pharmacy
        XCTAssertEqual(InvoiceMaths.lineResult(line, supplier: "", book: PriceBook(items, shop: food)).over, 0)
        XCTAssertEqual(InvoiceMaths.lineResult(line, supplier: "", book: PriceBook(items, shop: pharmacy)).over, 0.6)
        // a supplier's own agreed price still comes first
        var special = water
        special.sp = [SupplierPrice(s: "Aqua Ltd", p: 3.00)]
        XCTAssertEqual(special.basePrice(for: "Aqua Ltd", shop: pharmacy), 3.00)
    }

    func testLoweringAPriceChangesTheShopsOwnPrice() {
        let lowered = PriceTools.setting(3.10, on: items[4], supplier: "", shop: pharmacy)
        XCTAssertEqual(lowered.price(inShop: pharmacy), 3.10)
        XCTAssertEqual(lowered.price, 3.50)                  // the standard price is left alone
        let standard = PriceTools.setting(3.40, on: items[4], supplier: "", shop: food)
        XCTAssertEqual(standard.price, 3.40)
    }

    func testTheItemsTellTheShop() {
        let guess = ShopDetect.guess(matched: ["para", "plasters", "water", nil], supplier: "MedSupply", items: items,
                                     history: [], shops: [food, pharmacy])
        XCTAssertEqual(guess, ShopGuess(shop: pharmacy, sure: true, reason: .items))
        // one item only: a hint, not sure
        let weak = ShopDetect.guess(matched: ["para", "water"], supplier: "New Supplier", items: items, history: [], shops: [food, pharmacy])
        XCTAssertEqual(weak?.shop, pharmacy)
        XCTAssertEqual(weak?.sure, false)
        // items for every shop say nothing
        XCTAssertNil(ShopDetect.guess(matched: ["water"], supplier: "", items: items, history: [], shops: [food, pharmacy]))
        // one shop only: nothing to work out
        XCTAssertNil(ShopDetect.guess(matched: ["para", "plasters"], supplier: "", items: items, history: [], shops: [pharmacy]))
    }

    func testTheSupplierTellsTheShop() {
        let history = (1...4).map { entry("h\($0)", supplier: "Fresh Meat Direct", shop: food) }
        let guess = ShopDetect.guess(matched: ["water"], supplier: "FRESH MEAT DIRECT LTD", items: items, history: history, shops: [food, pharmacy])
        XCTAssertEqual(guess, ShopGuess(shop: food, sure: true, reason: .supplier))
        // items and supplier agree: sure even with a single item
        let both = ShopDetect.guess(matched: ["wings"], supplier: "Fresh Meat Direct", items: items, history: history, shops: [food, pharmacy])
        XCTAssertEqual(both, ShopGuess(shop: food, sure: true, reason: .itemsAndSupplier))
        // they disagree: the items' shop is suggested, but the app asks
        let clash = ShopDetect.guess(matched: ["para", "plasters"], supplier: "Fresh Meat Direct", items: items, history: history,
                                     shops: [food, pharmacy])
        XCTAssertEqual(clash, ShopGuess(shop: pharmacy, sure: false, reason: .items))
        // a supplier who delivers to both shops says nothing
        let mixed = history + [entry("p1", supplier: "Fresh Meat Direct", shop: pharmacy)]
        XCTAssertNil(ShopDetect.guess(matched: [], supplier: "Fresh Meat Direct", items: items, history: mixed, shops: [food, pharmacy]))
    }

    func testOldItemsAndBackupsAreUnchanged() throws {
        let old = #"{"baseline":[{"id":"a","cat":"Meat","name":"Lamb","price":9.5,"supplier":"","aliases":[],"sp":[]}],"history":[]}"#
        let backup = try BackupFile.read(Data(old.utf8))
        XCTAssertNil(backup.baseline[0].shops)
        XCTAssertNil(backup.baseline[0].shopPrices)
        let written = String(decoding: try backup.encoded(), as: UTF8.self)
        XCTAssertFalse(written.contains("shops"))
        XCTAssertFalse(written.contains("shopPrices"))
        // tags and shop prices travel in backups
        let tagged = BackupFile(baseline: [items[4], items[0]])
        let again = try BackupFile.read(try tagged.encoded())
        XCTAssertEqual(again.baseline[0].shopPrices, [ShopPrice(shop: pharmacy, p: 3.20)])
        XCTAssertEqual(again.baseline[1].shops, [food])
    }
}
