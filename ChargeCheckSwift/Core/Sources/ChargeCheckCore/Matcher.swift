import Foundation

public struct MatchResult: Equatable, Sendable {
    /// The price-list item this invoice line is, or nil when nothing is close enough.
    public let itemID: String?
    /// False when two items are nearly as good – the app then asks the user to confirm.
    public let confident: Bool
}

/// Works out which price-list item an invoice line is.
public enum Matcher {
    /// A price-list item with its words already split, so a whole invoice is matched without redoing that for every line.
    public struct Prepared: Sendable {
        public let item: PriceItem
        let aliasWords: [[String]]
        let nameTokens: [String]
    }

    public static func prepare(_ item: PriceItem) -> Prepared {
        Prepared(item: item,
                 aliasWords: item.aliases.map { TextTools.norm($0).split(separator: " ").map(String.init) }.filter { !$0.isEmpty },
                 nameTokens: TextTools.tokens(item.name))
    }

    /// 0 = nothing in common. 1 or more = one of the item's invoice spellings is in the line.
    public static func score(_ description: String, item: PriceItem) -> Double {
        score(d: TextTools.norm(description), dt: TextTools.tokens(description), prepare(item))
    }

    static func score(d: String, dt: [String], _ p: Prepared) -> Double {
        var best = 0.0
        for words in p.aliasWords where aliasFits(words, d: d, dt: dt) {
            best = max(best, 1 + Double(words.joined().count) / 100)
        }
        if best > 0 { return best }
        let it = p.nameTokens
        if it.isEmpty || dt.isEmpty { return 0 }
        var hit = 0
        for t in dt where it.contains(where: { TextTools.tokenEqual($0, t) }) { hit += 1 }
        return Double(2 * hit) / Double(dt.count + it.count)
    }

    /// An "other name" fits a line when every one of its words is in it.
    static func aliasFits(_ words: [String], d: String, dt: [String]) -> Bool {
        !words.isEmpty && words.allSatisfy { w in dt.contains(where: { TextTools.tokenEqual($0, w) }) || d.contains(w) }
    }

    public static func match(_ description: String, in items: [PriceItem]) -> MatchResult {
        match(description, prepared: items.map(prepare))
    }

    public static func match(_ description: String, prepared: [Prepared]) -> MatchResult {
        let d = TextTools.norm(description)
        let dt = TextTools.tokens(description)
        var best: PriceItem?
        var bestScore = 0.0, second = 0.0
        for p in prepared {
            let s = score(d: d, dt: dt, p)
            if s > bestScore {
                second = bestScore
                bestScore = s
                best = p.item
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
