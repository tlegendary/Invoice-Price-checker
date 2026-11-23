import Foundation

/// Units an ingredient is measured in. Converts only within its kind (weight, volume, count).
public enum RecipeUnit: String, Codable, CaseIterable, Sendable {
    case g, kg, ml, l, each

    /// How many of the kind's base unit (g, ml, each) one of these is.
    var base: Double {
        switch self {
        case .g, .ml, .each: return 1
        case .kg, .l: return 1000
        }
    }

    var kind: Int {
        switch self {
        case .g, .kg: return 0
        case .ml, .l: return 1
        case .each: return 2
        }
    }

    /// `amount` of this unit in `other`; nil when they don't measure the same thing (grams into litres).
    public func convert(_ amount: Double, to other: RecipeUnit) -> Double? {
        guard kind == other.kind else { return nil }
        return amount * base / other.base
    }
}

/// One ingredient: a price-list item, how much goes in, and what one pack of that item holds.
public struct Ingredient: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var itemID: String
    public var qty: Double
    public var unit: RecipeUnit
    /// One pack of the item holds this much (a 2 kg bag: 2, .kg).
    public var packSize: Double
    public var packUnit: RecipeUnit
    /// Lost in preparation (trimming, peeling), as a percent of what's used: 10 means 10% more is bought.
    public var waste: Double

    public init(id: String = UUID().uuidString, itemID: String, qty: Double, unit: RecipeUnit,
                packSize: Double, packUnit: RecipeUnit, waste: Double = 0) {
        self.id = id
        self.itemID = itemID
        self.qty = qty
        self.unit = unit
        self.packSize = packSize
        self.packUnit = packUnit
        self.waste = waste
    }

    /// Packs used for the whole recipe, waste included. nil when the units don't match.
    public var packsUsed: Double? {
        guard packSize > 0, let inPackUnits = unit.convert(qty, to: packUnit) else { return nil }
        return inPackUnits / packSize * (1 + max(0, waste) / 100)
    }
}

/// What a dish or drink is made of. A change makes a new version: sales keep the version they were made with.
public struct Recipe: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// The item sold at the till.
    public var itemID: String
    public var version: Int
    /// From when this version applies ("yyyy-MM-ddTHH:mm:ssZ").
    public var from: String
    /// Portions the ingredients make.
    public var portions: Double
    public var ingredients: [Ingredient]

    public init(id: String = UUID().uuidString, itemID: String, version: Int = 1, from: String, portions: Double = 1,
                ingredients: [Ingredient]) {
        self.id = id
        self.itemID = itemID
        self.version = version
        self.from = from
        self.portions = portions
        self.ingredients = ingredients
    }
}

public enum Recipes {
    public struct Cost: Equatable, Sendable {
        /// Per portion, to the penny.
        public var perPortion: Double
        /// Ingredients whose units don't match their pack, or whose item has no price: left out, and shown.
        public var unpriced: [String]
    }

    /// The cost of one portion: each ingredient's share of its pack price, waste included, over the portions.
    /// `packPrice` gives an item's current pack price (nil when unknown).
    public static func cost(_ recipe: Recipe, packPrice: (String) -> Double?) -> Cost {
        var pence = 0.0
        var unpriced: [String] = []
        for ingredient in recipe.ingredients {
            guard let packs = ingredient.packsUsed, let price = packPrice(ingredient.itemID) else {
                unpriced.append(ingredient.itemID)
                continue
            }
            pence += packs * price * 100
        }
        let portions = max(recipe.portions, 0.0001)
        return Cost(perPortion: Pence(value: Int((pence / portions).rounded())).pounds, unpriced: unpriced)
    }

    /// The version that applied at a moment: the latest one starting at or before it.
    public static func version(of itemID: String, at moment: String, in recipes: [Recipe]) -> Recipe? {
        recipes.filter { $0.itemID == itemID && $0.from <= moment }.max { ($0.from, $0.version) < ($1.from, $1.version) }
    }

    /// Ingredients used by these sales, in each ingredient item's pack units (refunds give back), with the recipe
    /// version that applied when each sale was made.
    public static func consumption(_ sales: [Sale], recipes: [Recipe]) -> [String: Double] {
        var used: [String: Double] = [:]
        for sale in sales {
            for line in sale.lines {
                guard let itemID = line.itemID, let recipe = version(of: itemID, at: sale.at, in: recipes) else { continue }
                let share = line.stockUnits / max(recipe.portions, 0.0001)
                for ingredient in recipe.ingredients {
                    guard let packs = ingredient.packsUsed else { continue }
                    used[ingredient.itemID, default: 0] += packs * share
                }
            }
        }
        return used.mapValues { ($0 * 10_000).rounded() / 10_000 }
    }

    /// The next version of a recipe, starting now; the old one stays for sales made before.
    public static func revise(_ recipe: Recipe, ingredients: [Ingredient], portions: Double, at moment: String) -> Recipe {
        Recipe(itemID: recipe.itemID, version: recipe.version + 1, from: moment, portions: portions, ingredients: ingredients)
    }
}
