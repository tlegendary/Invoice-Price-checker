import XCTest
@testable import ChargeCheckCore

final class RecipeTests: XCTestCase {
    // a burger: 150 g mince (2 kg bag £12, 5% trimmed), 1 bun (pack of 6 £1.80), 25 ml sauce (1 l bottle £3)
    private let burger = Recipe(itemID: "burger", from: "2026-11-01T00:00:00Z", ingredients: [
        Ingredient(itemID: "mince", qty: 150, unit: .g, packSize: 2, packUnit: .kg, waste: 5),
        Ingredient(itemID: "buns", qty: 1, unit: .each, packSize: 6, packUnit: .each),
        Ingredient(itemID: "sauce", qty: 25, unit: .ml, packSize: 1, packUnit: .l)
    ])
    private let prices: [String: Double] = ["mince": 12, "buns": 1.8, "sauce": 3]

    func testUnitsConvertOnlyWithinTheirKind() {
        XCTAssertEqual(RecipeUnit.g.convert(1500, to: .kg), 1.5)
        XCTAssertEqual(RecipeUnit.l.convert(0.25, to: .ml), 250)
        XCTAssertEqual(RecipeUnit.each.convert(3, to: .each), 3)
        XCTAssertNil(RecipeUnit.g.convert(100, to: .ml), "grams aren't millilitres")
        XCTAssertNil(RecipeUnit.each.convert(1, to: .kg))
    }

    func testCostPerPortion() {
        // mince 0.15/2 × 1.05 × 12 = 0.945; bun 1.8/6 = 0.30; sauce 0.025 × 3 = 0.075 → £1.32
        let cost = Recipes.cost(burger, packPrice: { self.prices[$0] })
        XCTAssertEqual(cost.perPortion, 1.32)
        XCTAssertEqual(cost.unpriced, [])
        var batch = burger
        batch.portions = 2
        XCTAssertEqual(Recipes.cost(batch, packPrice: { self.prices[$0] }).perPortion, 0.66)
    }

    func testAnIngredientThatCantBePricedIsShownNotGuessed() {
        var r = burger
        r.ingredients.append(Ingredient(itemID: "cheese", qty: 30, unit: .g, packSize: 1, packUnit: .l))
        let cost = Recipes.cost(r, packPrice: { self.prices[$0] ?? 4 })
        XCTAssertEqual(cost.unpriced, ["cheese"], "grams against a pack in litres")
        XCTAssertEqual(cost.perPortion, 1.32)
    }

    func testOldSalesKeepTheRecipeTheyWereMadeWith() {
        let v2 = Recipes.revise(burger, ingredients: [Ingredient(itemID: "mince", qty: 200, unit: .g, packSize: 2, packUnit: .kg)],
                                portions: 1, at: "2026-11-15T00:00:00Z")
        let all = [burger, v2]
        XCTAssertEqual(Recipes.version(of: "burger", at: "2026-11-10T12:00:00Z", in: all)?.version, 1)
        XCTAssertEqual(Recipes.version(of: "burger", at: "2026-11-20T12:00:00Z", in: all)?.version, 2)
        XCTAssertNil(Recipes.version(of: "burger", at: "2026-10-01T00:00:00Z", in: all))
        // ingredient use: 2 burgers on the 10th (v1), 1 on the 20th (v2), 1 refunded on the 20th
        func sale(_ at: String, _ qty: Double) -> Sale {
            Sale(number: 1, shop: "", at: at, lines: [SaleLine(itemID: "burger", name: "Burger", qty: qty, price: 6)], payment: .cash)
        }
        let used = Recipes.consumption([sale("2026-11-10T12:00:00Z", 2), sale("2026-11-20T12:00:00Z", 1), sale("2026-11-20T13:00:00Z", -1)],
                                       recipes: all)
        XCTAssertEqual(used["mince"]!, 2 * 0.075 * 1.05, accuracy: 0.0001, "v1: 150 g + 5% waste each; v2's sale was refunded")
        XCTAssertEqual(used["buns"]!, 2.0 / 6, accuracy: 0.0001)
    }
}
