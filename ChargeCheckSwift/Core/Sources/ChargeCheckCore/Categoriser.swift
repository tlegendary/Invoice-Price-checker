import Foundation

/// Sorts price-list items into categories: first by common shop words (using the
/// user's own category names where they have them), otherwise by learning from
/// items that are already sorted.
public enum Categoriser {
    static let rules: [(name: String, pattern: String)] = [
        ("Bakery", "\\bbuns?\\b|\\bbreads?\\b|panini|tortilla|pitta|pita|naan|baguette|dough|bagel|brioche|roll(?:s)?\\b(?=.*\\b(?:bread|sub|bap|brioche)\\b)|\\bwraps?\\b(?! film)"),
        ("Meat & Poultry", "chicken|fillet|wing|breast|thigh|drumstick|lamb|beef|mince|doner|kebab|burger|steak|turkey|sausage|nugget|strip|popcorn|gyro|meat|quarter pounder|quater pounder|pounder|fish|cod|haddock|scampi|prawn|tuna|salmon|bacon|ham\\b|pepperoni|salami|halal|9 cut"),
        ("Oils & Sauces", "\\bfat\\b|lard|ghee|margarine|oil|mayo|mayonnaise|ketchup|sauce|dressing|vinegar|garlic|peri|bbq|chilli|chili|relish"),
        ("Dry Goods", "breading|coating|batter|flour|\\bsalt\\b|sugar|spice|seasoning|pepper\\b|rice\\b|pasta|noodle|crumb|semolina|yeast|herb|oregano|paprika|cumin"),
        ("Dairy & Cheese", "cheese|mozzarella|cheddar|milk|cream|butter|yogurt|yoghurt"),
        ("Frozen & Sides", "chip|fries|frozen|onion ring|wedge|hash|veg|pea|corn|potato"),
        ("Drinks", "cola|coke|pepsi|fanta|sprite|\\bwater\\b|juice|\\bcans?\\b(?=.*\\d)|drink|7up|tango|red bull|lucozade|rubicon|vimto|monster|\\bsoda\\b"),
        ("Packaging", "\\bbox(es)?\\b|\\bbags?\\b|container|\\blids?\\b|\\bcups?\\b|\\bpots?\\b|napkin|foil|wrap film|cling|tray|straw|cutlery|fork|spoon|label|greaseproof|\\bpaper\\b|carrier|sachet"),
        ("Cleaning", "tissue|tissu\\b|wipe|bleach|clean|soap|glove|sanitis|degreas|roll|bin liner|refuse|blue roll|detergent")
    ]

    /// Words in a user's own category name that mean the same as one of ours.
    static let sameAs: [String: String] = [
        "Meat & Poultry": "meat|poultry|protein|chicken",
        "Oils & Sauces": "oil|sauce|fat",
        "Dairy & Cheese": "dairy|cheese",
        "Bakery": "bak|bread|bun",
        "Frozen & Sides": "frozen|chip|potato|side",
        "Drinks": "drink|beverage",
        "Packaging": "pack|sundr|dispos",
        "Cleaning": "clean|hygien",
        "Dry Goods": "dry|breading|coating|spice|flour|grocer|store"
    ]

    static let fillerWords: Set<String> = ["fresh", "halal", "large", "medium", "small", "mini", "general", "pack", "packs", "with", "inch",
                                           "standard", "extra", "original", "premium", "best", "quality", "case", "each", "brown", "white", "colour", "color"]

    public static let standardNames: [String] = rules.map { $0.name } + ["Other"]

    public static func isUnsorted(_ category: String) -> Bool {
        let c = category.trimmingCharacters(in: .whitespaces).lowercased()
        return c.isEmpty || ["other", "imported", "uncategorised", "uncategorized", "misc"].contains(c)
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The category an item most likely belongs in, or nil when it can't tell.
    public static func suggest(for item: PriceItem, in all: [PriceItem]) -> String? {
        let mine = uniqueInOrder(all.map { $0.cat }.filter { !isUnsorted($0) })
        let text = TextTools.norm(item.name + " " + item.aliases.joined(separator: " "))
        let keyword = rules.first(where: { matches($0.pattern, text) })?.name
        if let keyword {
            if let exact = mine.first(where: { $0 == keyword }) { return exact }
            if let pattern = sameAs[keyword], let own = mine.first(where: { matches(pattern, $0) }) { return own }
        }
        // learn from items already sorted that share a word with this one
        let words = text.split(separator: " ").map(String.init).filter { w in
            w.count >= 4 && !w.contains(where: { $0.isNumber }) && !fillerWords.contains(w)
        }
        var votes: [String: Int] = [:]
        for other in all where other.id != item.id && !isUnsorted(other.cat) {
            let otherWords = Set(TextTools.norm(other.name + " " + other.aliases.joined(separator: " ")).split(separator: " ").map(String.init))
            let shared = words.filter { otherWords.contains($0) }.count
            if shared > 0 { votes[other.cat, default: 0] += shared }
        }
        let ranked = votes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        if let top = ranked.first, ranked.count == 1 || top.value > ranked[1].value { return top.key }
        return keyword
    }

    private static func uniqueInOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
