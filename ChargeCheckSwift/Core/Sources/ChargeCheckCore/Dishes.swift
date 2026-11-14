import Foundation

/// One price-list item in a dish: the dish uses `uses` out of a pack that holds `packOf`
/// (a quarter pounder uses 1 of the 48 patties in a case; a portion of chips uses 0.15 of a 2.5 kg bag → uses 0.15, packOf 1).
public struct DishPart: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var itemID: String
    public var uses: Double
    public var packOf: Double

    public init(id: String = UUID().uuidString, itemID: String, uses: Double = 1, packOf: Double = 1) {
        self.id = id
        self.itemID = itemID
        self.uses = uses
        self.packOf = packOf
    }

    enum CodingKeys: String, CodingKey { case id, itemID, uses, packOf }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        itemID = try c.decode(String.self, forKey: .itemID)
        uses = (try? c.decode(Double.self, forKey: .uses)) ?? 1
        packOf = (try? c.decode(Double.self, forKey: .packOf)) ?? 1
    }
}

/// Something the shop sells, made from items in the price list, so its cost follows the agreed prices.
public struct Dish: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The selling price, as on the menu.
    public var price: Double
    /// VAT included in the selling price, in % (20 for hot takeaway food in the UK; 0 when not VAT registered).
    public var vatRate: Double
    /// The shop whose prices are used ("" = the standard agreed prices).
    public var shop: String
    public var parts: [DishPart]
    /// What it cost when the dish was last saved, to show how much prices have moved since.
    public var costWhenSet: Double?

    public init(id: String = UUID().uuidString, name: String, price: Double, vatRate: Double = 20, shop: String = "",
                parts: [DishPart] = [], costWhenSet: Double? = nil) {
        self.id = id
        self.name = name
        self.price = price
        self.vatRate = vatRate
        self.shop = shop
        self.parts = parts
        self.costWhenSet = costWhenSet
    }

    enum CodingKeys: String, CodingKey { case id, name, price, vatRate, shop, parts, costWhenSet }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        price = (try? c.decode(Double.self, forKey: .price)) ?? 0
        vatRate = (try? c.decode(Double.self, forKey: .vatRate)) ?? 20
        shop = (try? c.decode(String.self, forKey: .shop)) ?? ""
        parts = (try? c.decode([DishPart].self, forKey: .parts)) ?? []
        costWhenSet = try? c.decode(Double.self, forKey: .costWhenSet)
    }
}

public struct DishCost: Equatable, Sendable {
    /// What the ingredients cost at today's agreed prices.
    public var cost: Double
    /// The selling price without VAT: what the shop keeps.
    public var netPrice: Double
    /// netPrice − cost.
    public var margin: Double
    /// cost ÷ netPrice, 0–100+ (nil when there is no selling price).
    public var foodCostPercent: Double?
    /// Ingredients whose item has been deleted from the price list (left out of the cost, and shown).
    public var missing: Int
    /// How much the cost has changed since the dish was saved (+ = gone up).
    public var changeSinceSet: Double
}

public enum DishMaths {
    /// The cost of one of each part.
    public static func partCost(_ part: DishPart, book: PriceBook) -> Double? {
        guard let item = book.item(part.itemID) else { return nil }
        guard part.packOf > 0, part.uses >= 0 else { return 0 }
        return book.base(item, supplier: item.supplier) / part.packOf * part.uses
    }

    public static func cost(of dish: Dish, items: [PriceItem]) -> DishCost {
        let book = PriceBook(items, shop: dish.shop)
        var total = 0.0
        var missing = 0
        for part in dish.parts {
            if let value = partCost(part, book: book) { total += value } else { missing += 1 }
        }
        let cost = Money.round2(total)
        let net = dish.vatRate > 0 ? Money.round2(dish.price / (1 + dish.vatRate / 100)) : Money.round2(dish.price)
        let percent: Double? = net > 0.005 ? (cost / net * 1000).rounded() / 10 : nil
        return DishCost(cost: cost, netPrice: net, margin: Money.round2(net - cost), foodCostPercent: percent, missing: missing,
                        changeSinceSet: Money.round2(cost - (dish.costWhenSet ?? cost)))
    }

    /// What the selling price would need to be (with VAT) for the ingredients to be `target`% of it.
    public static func priceFor(foodCost target: Double, cost: Double, vatRate: Double) -> Double? {
        guard target > 0, target < 100, cost > 0 else { return nil }
        return Money.round2(cost / (target / 100) * (1 + vatRate / 100))
    }
}

/// How many are in a pack, guessed from the item's name to start a dish ingredient off
/// ("Quarter Pounder 48x113g" → 48, "Cups 4x50" → 200, "Napkins x500" → 500, "Wings 10kg" → 1). Always editable.
public enum PackGuess {
    public static func count(in name: String) -> Double {
        let words = TextTools.norm(name).split(separator: " ").map(String.init)
        for word in words.reversed() {
            // "48x113g": 48 of 113 g; "4x50": 4 sleeves of 50
            let sides = word.split(separator: "x", omittingEmptySubsequences: false).map(String.init)
            if sides.count == 2, let left = Double(sides[0]), left >= 1 {
                if let right = Double(sides[1]), right >= 1 { return min(left * right, 10_000) }
                if !sides[1].isEmpty, sides[1].first?.isNumber == true { return min(left, 10_000) }
            }
            if sides.count == 2, sides[0].isEmpty, let right = Double(sides[1]), right >= 1 { return min(right, 10_000) }
            // "100pcs", "12pk"
            for unit in ["pcs", "pc", "pk", "pack"] where word.hasSuffix(unit) {
                if let n = Double(word.dropLast(unit.count)), n >= 1 { return min(n, 10_000) }
            }
        }
        return 1
    }
}
