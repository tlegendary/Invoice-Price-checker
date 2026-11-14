import Foundation

/// Other names a supplier is likely to print for a price-list item ("Quarter Pounder" → "qtr pounder",
/// "HP10 Burger Box 1x150" → "hp10", "hp10 burger box"), offered in the item editor to add with a tap.
///
/// Safety first: a name is only offered when it can't also be read as another item in the price list
/// (checked with the same rule the matcher uses), so adding it never causes a "which one is it?" question
/// or a wrong match. The order of words doesn't matter to the matcher, so no reordered copies are made.
public enum NameIdeas {
    /// Common shorthand on wholesale invoices, both ways round.
    static let short: [String: [String]] = [
        "quarter": ["qtr"], "pounder": ["pdr"], "burger": ["bgr"],
        "chicken": ["chkn", "chk"], "breast": ["brst"], "fillet": ["fil"],
        "vegetable": ["veg"], "mayonnaise": ["mayo"], "large": ["lge", "lrg"], "medium": ["med"],
        "small": ["sml"], "frozen": ["frz"], "boneless": ["bnls"], "packet": ["pkt"], "pack": ["pk"],
        "carton": ["ctn"], "bottle": ["btl"], "container": ["cont"], "mozzarella": ["mozz"],
        "cheese": ["chs"], "sauce": ["sce"], "tomato": ["tom"], "regular": ["reg"], "original": ["orig"],
        "double": ["dbl"], "single": ["sgl"], "breaded": ["brd"], "sliced": ["slcd"], "doner": ["donner"],
        "kebab": ["kebap"], "napkins": ["napkin"], "assorted": ["asst"], "dozen": ["doz"],
    ]
    static let long: [String: String] = {
        var out: [String: String] = [:]
        for (full, shorts) in short { for s in shorts { out[s] = full } }
        return out
    }()

    /// Shorthand read as the full word, so "chkn wings" and "chicken wings" are seen as the same name.
    static func canon(_ words: [String]) -> [String] { words.map { long[$0] ?? $0 } }

    /// A pack size or count: "9kg", "10l", "4x12", "x50", "500", "1x150", "12pk".
    static func isSize(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        if word.hasPrefix("x"), word.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }), word.count > 1 { return true }
        guard first.isNumber else { return false }
        let units = ["kg", "g", "gr", "l", "ltr", "lt", "ml", "cl", "oz", "lb", "lbs", "pk", "pcs", "pc", "pack", "s", ""]
        if word.contains("x") {
            return word.split(separator: "x").allSatisfy { part in part.first?.isNumber ?? false }
        }
        let number = word.prefix { $0.isNumber || $0 == "." }
        return units.contains(String(word.dropFirst(number.count)))
    }

    /// A product code such as "hp10" or "c12": letters then digits.
    static func isCode(_ word: String) -> Bool {
        guard word.count >= 3, let first = word.first, first.isLetter, word.contains(where: { $0.isNumber }) else { return false }
        return word.allSatisfy { $0.isLetter || $0.isNumber }
    }

    public static func suggest(for item: PriceItem, among items: [PriceItem], limit: Int = 8) -> [String] {
        let words = TextTools.norm(item.name).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let plain = words.filter { !isSize($0) && !TextTools.stopWords.contains($0) }
        var ideas: [[String]] = []

        // the name without its pack size – how most suppliers shorten it
        if plain.count < words.count { ideas.append(plain) }
        // a product code on its own, and with the rest of the name
        for code in plain where isCode(code) {
            ideas.append([code])
        }
        // shorthand: each word on its own, then all of them together
        let base = plain.isEmpty ? words : plain
        var all = base
        for (index, word) in base.enumerated() {
            let swaps = (short[word] ?? []) + (long[word].map { [$0] } ?? [])
            for swap in swaps {
                var copy = base
                copy[index] = swap
                ideas.append(copy)
            }
            if let first = swaps.first { all[index] = first }
        }
        if all != base { ideas.append(all) }

        let own = Set([TextTools.norm(item.name)] + item.aliases.map { TextTools.norm($0) })
        let others = items.filter { $0.id != item.id }
            .map { other in
                ([other.name] + other.aliases).map { text -> (String, [String]) in
                    let full = canon(TextTools.norm(text).split(separator: " ").map(String.init)).joined(separator: " ")
                    return (full, TextTools.tokens(full))
                }
            }
        var out: [String] = []
        for idea in ideas {
            let text = idea.joined(separator: " ")
            guard !text.isEmpty, !own.contains(text), !out.contains(text) else { continue }
            // a real name: two words or more, a product code, or one long word – never something as loose as "oil"
            let meaningful = idea.filter { !TextTools.stopWords.contains($0) }
            guard meaningful.count >= 2 || (meaningful.count == 1 && (isCode(meaningful[0]) || meaningful[0].count >= 8)) else { continue }
            // it must not fit any other item (its name or one of its other names)
            let full = canon(idea)
            let clash = others.contains { texts in texts.contains { Matcher.aliasFits(full, d: $0.0, dt: $0.1) } }
            if clash { continue }
            out.append(text)
            if out.count == limit { break }
        }
        return out
    }
}
