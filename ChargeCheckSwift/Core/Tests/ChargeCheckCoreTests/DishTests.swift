import XCTest
@testable import ChargeCheckCore

final class DishTests: XCTestCase {
    let patties = PriceItem(id: "p", cat: "Meat", name: "Quarter Pounder 48x113g", price: 38.40, supplier: "")
    let buns = PriceItem(id: "b", cat: "Bakery", name: "Burger Buns 48", price: 9.60, supplier: "")
    let cheese = PriceItem(id: "c", cat: "Dairy", name: "Cheese Slices 112", price: 11.20, supplier: "")

    func testQuarterPounderCostAndMargin() {
        let dish = Dish(name: "Quarter pounder with cheese", price: 6.00, vatRate: 20, parts: [
            DishPart(itemID: "p", uses: 1, packOf: 48),    // 0.80
            DishPart(itemID: "b", uses: 1, packOf: 48),    // 0.20
            DishPart(itemID: "c", uses: 2, packOf: 112),   // 0.20
        ])
        let result = DishMaths.cost(of: dish, items: [patties, buns, cheese])
        XCTAssertEqual(result.cost, 1.20)
        XCTAssertEqual(result.netPrice, 5.00)
        XCTAssertEqual(result.margin, 3.80)
        XCTAssertEqual(result.foodCostPercent, 24.0)
        XCTAssertEqual(result.missing, 0)
    }

    func testPriceRiseShowsSinceSaved() {
        var dish = Dish(name: "QP", price: 6, parts: [DishPart(itemID: "p", uses: 1, packOf: 48)], costWhenSet: 0.80)
        var dearer = patties
        dearer.price = 43.20   // 0.90 each
        XCTAssertEqual(DishMaths.cost(of: dish, items: [dearer]).changeSinceSet, 0.10)
        dish.costWhenSet = nil
        XCTAssertEqual(DishMaths.cost(of: dish, items: [dearer]).changeSinceSet, 0)
    }

    func testShopPriceAndDeletedItemAndNoVat() {
        var item = patties
        item.shopPrices = [ShopPrice(shop: "s2", p: 48.00)]
        let dish = Dish(name: "QP", price: 5, vatRate: 0, shop: "s2",
                        parts: [DishPart(itemID: "p", uses: 1, packOf: 48), DishPart(itemID: "gone", uses: 1, packOf: 1)])
        let result = DishMaths.cost(of: dish, items: [item])
        XCTAssertEqual(result.cost, 1.00, "this shop's own price")
        XCTAssertEqual(result.missing, 1)
        XCTAssertEqual(result.netPrice, 5.00)
        XCTAssertEqual(result.foodCostPercent, 20.0)
    }

    func testBadNumbersNeverDivideByZero() {
        let dish = Dish(name: "x", price: 0, parts: [DishPart(itemID: "p", uses: 1, packOf: 0)])
        let result = DishMaths.cost(of: dish, items: [patties])
        XCTAssertEqual(result.cost, 0)
        XCTAssertNil(result.foodCostPercent)
    }

    func testSuggestedPriceForTargetFoodCost() {
        XCTAssertEqual(DishMaths.priceFor(foodCost: 25, cost: 1.20, vatRate: 20), 5.76)
        XCTAssertNil(DishMaths.priceFor(foodCost: 0, cost: 1, vatRate: 20))
    }

    func testDishesSurviveABackupAndOldBackupsStillOpen() throws {
        let backup = BackupFile(baseline: [patties], dishes: [Dish(name: "QP", price: 6, parts: [DishPart(itemID: "p", uses: 1, packOf: 48)])])
        let read = try BackupFile.read(try JSONEncoder().encode(backup))
        XCTAssertEqual(read.dishes?.first?.parts.first?.packOf, 48)
        let old = try BackupFile.read(Data(#"{"baseline":[],"history":[]}"#.utf8))
        XCTAssertNil(old.dishes)
    }
}

final class PackGuessTests: XCTestCase {
    func testGuesses() {
        XCTAssertEqual(PackGuess.count(in: "Quarter Pounder 48x113g"), 48)
        XCTAssertEqual(PackGuess.count(in: "Cups 4x50"), 200)
        XCTAssertEqual(PackGuess.count(in: "Napkins x500"), 500)
        XCTAssertEqual(PackGuess.count(in: "Chicken Wings 10kg"), 1)
        XCTAssertEqual(PackGuess.count(in: "Wooden forks 100pcs"), 100)
        XCTAssertEqual(PackGuess.count(in: "Box"), 1)
    }
}
