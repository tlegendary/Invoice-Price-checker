import XCTest
@testable import ChargeCheckCore

final class CoreTests: XCTestCase {
    let list: [PriceItem] = [
        PriceItem(id: "qp", cat: "Meat & Poultry", name: "Quarter Pounder 48x4oz", price: 24.99, aliases: ["quater pounder", "quarter pounder"]),
        PriceItem(id: "wing", cat: "Meat & Poultry", name: "Fresh Prime Wing", price: 14.99, aliases: ["fresh prime wing", "prime wing"]),
        PriceItem(id: "mayo", cat: "Oils & Sauces", name: "Cheff Real Mayo 10L", price: 10.99, aliases: ["cheff real mayo", "chef real mayo"]),
        PriceItem(id: "oil", cat: "Oils & Sauces", name: "KTC Vegetable Oil Tin 20L", price: 27.99, aliases: ["ktc vegetable oil", "vegetable oil tin"]),
        PriceItem(id: "bun", cat: "Bakery", name: "Americana 4.5\" Seed Burger Bun 4x12", price: 6.99, aliases: ["americana", "seed burger bun"])
    ]

    func testNorm() {
        XCTAssertEqual(TextTools.norm("  QUATER  POUNDER 48X4oz (Va) "), "quater pounder 48x4oz va")
        XCTAssertEqual(TextTools.norm("Ketch-Up 2x4.5LT"), "ketch up 2x4.5lt")
        XCTAssertEqual(TextTools.tokens("Fresh Halal Fillet 110-130 9KG"), ["fillet", "110", "130", "9kg"])
    }

    func testMatchingSupplierSpellings() {
        XCTAssertEqual(Matcher.match("QUATER POUNDER 48X40Z va VIS L Q", in: list).itemID, "qp")
        XCTAssertEqual(Matcher.match("FRESH PRIME WING", in: list).itemID, "wing")
        XCTAssertEqual(Matcher.match("3 CHEFF REAL MAYO 10L", in: list).itemID, "mayo")
        XCTAssertEqual(Matcher.match("KTC VEGETABLE OIL TIN 20 Itrs", in: list).itemID, "oil")
        XCTAssertEqual(Matcher.match("AMERICANA A4.5 SEED BURGER BUN 4X12", in: list).itemID, "bun")
        XCTAssertNil(Matcher.match("PEPSI CAN 24X330 ML", in: list).itemID)
        XCTAssertTrue(Matcher.match("FRESH PRIME WING", in: list).confident)
    }

    func testSupplier() {
        XCTAssertTrue(TextTools.sameSupplier("FOOD DISTRIB TION", "Food Distribution"))
        XCTAssertEqual(TextTools.cleanSupplier("x FOOD DIS   T  (Tm 12"), "FOOD DIS (Tm")
        var item = list[0]
        item.sp = [SupplierPrice(s: "Apex Foods", p: 23.5)]
        XCTAssertEqual(item.basePrice(for: "APEX FOODS LTD"), 23.5)
        XCTAssertEqual(item.basePrice(for: "Waka"), 24.99)
    }

    func testMoney() {
        XCTAssertEqual(Money.round2(1.005), 1.01)
        XCTAssertEqual(Money.format(27.4), "£27.40")
        XCTAssertEqual(Money.format(-3), "-£3.00")
        XCTAssertEqual(Money.parse("£12,50"), 12.5)
        XCTAssertNil(Money.parse("abc"))
    }

    func testBackupFromTheFirstApp() throws {
        let json = """
        {"app":"ChargeCheck","v":3,"savedAt":"2026-11-10T02:49:39.977Z",
         "baseline":[{"id":"c01","cat":"Bakery","name":"Discovery Tortilla Wrap 10\\"","price":14,"supplier":"FOOD DISTRIBUTION","aliases":["discovery tortilla wrap 10"],"sp":[],"unit":"each"},
                     {"id":"x2","name":"Steak Breaded","price":"24.00"},{"id":"bad","name":"  ","price":1}],
         "history":[{"id":"h1","savedAt":"2026-11-10T02:47:32.034Z","shopId":"","credit":null,"supplier":"FOOD DISTRIBUTION","invNo":"82044","date":"06/11/2026",
                     "net":100,"total":110,"over":10,"overVat":1,"excluded":20,"verified":true,
                     "lines":[{"qty":2,"desc":"STEAK BREADED","unit":26.99,"vat":0,"matchId":"x2","item":"Steak Breaded","base":24,"over":5.98,"excluded":false,"noBase":false},
                              {"qty":1,"desc":"PEPSI","unit":20,"vat":20,"matchId":null,"item":"","base":null,"over":0,"excluded":true,"noBase":false}]}],
         "settings":{"biz":"","tol":0.01,"double":true,"shops":[{"id":"s1","name":"Kings heath"}],"shop":"s1","mode":"dark","color":"blue"},
         "scans":{"n":27,"dev":"abc"}}
        """
        let backup = try BackupFile.read(Data(json.utf8))
        XCTAssertEqual(backup.baseline.count, 2)
        XCTAssertEqual(backup.baseline[0].unit, "each")
        XCTAssertEqual(backup.baseline[1].price, 24)
        XCTAssertEqual(backup.baseline[1].cat, "Other")
        XCTAssertEqual(backup.history.count, 1)
        XCTAssertEqual(backup.history[0].lines.count, 2)
        XCTAssertNil(backup.history[0].credit)
        XCTAssertEqual(backup.settings?.shops?.first?.name, "Kings heath")
        XCTAssertEqual(backup.settings?.color, "blue")
        XCTAssertEqual(backup.scans?.n, 27)
        // 110 total − (10 + 1 overcharge + 20 missing + 4 VAT on the missing item) = 75
        let pay = backup.history[0].amountToPay
        XCTAssertEqual(pay.less, 35)
        XCTAssertEqual(pay.pay, 75)
        // and it writes a file the same reader accepts
        let again = try BackupFile.read(try backup.encoded())
        XCTAssertEqual(again.baseline, backup.baseline)
        XCTAssertEqual(again.history.first?.id, "h1")
    }

    func testBarePriceListAndRubbish() throws {
        let list = try BackupFile.read(Data("[{\"name\":\"Salt\",\"price\":5.99}]".utf8))
        XCTAssertEqual(list.baseline.first?.name, "Salt")
        XCTAssertThrowsError(try BackupFile.read(Data("hello".utf8)))
        XCTAssertThrowsError(try BackupFile.read(Data("{\"x\":1}".utf8)))
    }

    func testPastedPriceList() {
        let rows = PriceListText.parse("""
        Americana 4.5" Seeded Burger Buns (4x12) £6.99
        Chicken wings 10kg, 15.00
        Pizza Box 12 inch - 9,99 each
        just some words
        FC1 £14.50
        """)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0], PriceListText.Row(name: "Americana 4.5\" Seeded Burger Buns (4x12)", price: 6.99))
        XCTAssertEqual(rows[1], PriceListText.Row(name: "Chicken wings 10kg", price: 15))
        XCTAssertEqual(rows[2], PriceListText.Row(name: "Pizza Box 12 inch", price: 9.99))
        XCTAssertEqual(rows[3].name, "FC1")
    }

    func testCategories() {
        func other(_ name: String) -> PriceItem { PriceItem(cat: "Other", name: name, price: 1) }
        let all = [other("Chicken Popcorn 3kg"), other("Pepsi Can 24x330ml"), other("16 Inch Colour Pizza Boxes"), other("Palmax Fat 12.5kg"),
                   other("Original Breading"), other("Suprano Cheese R74"), other("Mystery Thing")]
        XCTAssertEqual(Categoriser.suggest(for: all[0], in: all), "Meat & Poultry")
        XCTAssertEqual(Categoriser.suggest(for: all[1], in: all), "Drinks")
        XCTAssertEqual(Categoriser.suggest(for: all[2], in: all), "Packaging")
        XCTAssertEqual(Categoriser.suggest(for: all[3], in: all), "Oils & Sauces")
        XCTAssertEqual(Categoriser.suggest(for: all[4], in: all), "Dry Goods")
        XCTAssertEqual(Categoriser.suggest(for: all[5], in: all), "Dairy & Cheese")
        XCTAssertNil(Categoriser.suggest(for: all[6], in: all))
        // uses the user's own category names
        let mine = [PriceItem(cat: "Proteins & Poultry", name: "Hash Browns", price: 20), other("Fresh Halal Medium Wings 10kg")]
        XCTAssertEqual(Categoriser.suggest(for: mine[1], in: mine), "Proteins & Poultry")
        XCTAssertTrue(Categoriser.isUnsorted(" imported "))
        XCTAssertFalse(Categoriser.isUnsorted("Bakery"))
    }
}
