import Foundation

public struct MatchResult: Equatable, Sendable {
    /// The price-list item this invoice line is, or nil when nothing is close enough.
    public let itemID: String?
    /// False when two items are nearly as good – the app then asks the user to confirm.
    public let confident: Bool
}

/// Works out which price-list item an invoice line is.
public enum Matcher {
    /// 0 = nothing in common. 1 or more = one of the item's invoice spellings is in the line.
    public static func score(_ description: String, item: PriceItem) -> Double {
        let d = TextTools.norm(description)
        let dt = TextTools.tokens(description)
        var best = 0.0
        for alias in item.aliases {
            let words = TextTools.norm(alias).split(separator: " ").map(String.init)
            if words.isEmpty { continue }
            let all = words.allSatisfy { w in dt.contains(where: { TextTools.tokenEqual($0, w) }) || d.contains(w) }
            if all { best = max(best, 1 + Double(words.joined().count) / 100) }
        }
        if best > 0 { return best }
        let it = TextTools.tokens(item.name)
        if it.isEmpty || dt.isEmpty { return 0 }
        var hit = 0
        for t in dt where it.contains(where: { TextTools.tokenEqual($0, t) }) { hit += 1 }
        return Double(2 * hit) / Double(dt.count + it.count)
    }

    public static func match(_ description: String, in items: [PriceItem]) -> MatchResult {
        var best: PriceItem?
        var bestScore = 0.0, second = 0.0
        for item in items {
            let s = score(description, item: item)
            if s > bestScore {
                second = bestScore
                bestScore = s
                best = item
            } else if s > second {
                second = s
            }
        }
        guard let found = best, bestScore >= 0.55 else { return MatchResult(itemID: nil, confident: false) }
        let byAlias = bestScore >= 1
        let clear = byAlias ? (second < 1 || bestScore - second >= 0.02) : (bestScore >= 0.8 && bestScore - second >= 0.15)
        return MatchResult(itemID: found.id, confident: clear)
    }

    /// The closest few items, to offer when a line isn't recognised.
    public static func suggestions(_ description: String, in items: [PriceItem], limit: Int = 3) -> [PriceItem] {
        items.map { (item: $0, score: score(description, item: $0)) }
            .filter { $0.score >= 0.2 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0.item }
    }
}
