import Foundation

/// Which shop a scanned invoice is for, worked out from what's on it.
public struct ShopGuess: Equatable, Sendable {
    public enum Reason: String, Sendable {
        /// The items on it are only bought for that shop.
        case items
        /// This supplier's invoices have always been for that shop.
        case supplier
        /// Both say the same shop.
        case itemsAndSupplier
    }

    public var shop: String
    /// Sure enough to file it there without asking (when the user lets the app do that).
    public var sure: Bool
    public var reason: Reason

    public init(shop: String, sure: Bool, reason: Reason) {
        self.shop = shop
        self.sure = sure
        self.reason = reason
    }
}

/// Works out the shop of an invoice when the shops buy different things (a food shop and a pharmacy).
///
/// Two signs are used: items in the price list that are only bought for some shops, and where this supplier's
/// earlier invoices were filed. Items for every shop say nothing. When the signs are weak or disagree the guess is
/// not "sure", so the app asks instead of filing it on its own.
public enum ShopDetect {
    /// - Parameters:
    ///   - matched: the price-list item each line was matched to (nil for unmatched lines)
    ///   - shops: the ids of the user's shops
    ///   - history: saved invoices (for where this supplier's invoices went before)
    public static func guess(matched: [String?], supplier: String, items: [PriceItem], history: [HistoryEntry],
                             shops: [String]) -> ShopGuess? {
        guard shops.count > 1 else { return nil }
        let known = Set(shops)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // items only bought for some shops: one vote for each of those shops
        var votes: [String: Int] = [:]
        for id in matched.compactMap({ $0 }) {
            guard let tags = byID[id]?.shops?.filter({ known.contains($0) }), !tags.isEmpty, tags.count < known.count else { continue }
            for shop in tags { votes[shop, default: 0] += 1 }
        }
        let ranked = votes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let itemShop = ranked.first.map { $0.key }
        let top = ranked.first?.value ?? 0
        let second = ranked.dropFirst().first?.value ?? 0
        // clearly one shop's items: at least two lines, and three times more than any other shop
        let itemsClear = top >= 2 && top >= 3 * second
        let itemsHint = top >= 1 && top > second

        // where this supplier's invoices went before
        let key = SupplierAccounts.key(supplier)
        var past: [String: Int] = [:]
        if !key.isEmpty {
            for entry in history where !entry.shopId.isEmpty && known.contains(entry.shopId) && SupplierAccounts.key(entry.supplier) == key {
                past[entry.shopId, default: 0] += 1
            }
        }
        let pastTotal = past.values.reduce(0, +)
        let usual = past.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
        // a regular supplier of one shop: at least three invoices, nine in ten of them for that shop
        let supplierShop: String? = usual.flatMap { pastTotal >= 3 && Double($0.value) >= 0.9 * Double(pastTotal) ? $0.key : nil }

        switch (itemsHint ? itemShop : nil, supplierShop) {
        case let (items?, supplier?) where items == supplier:
            return ShopGuess(shop: items, sure: true, reason: .itemsAndSupplier)
        case let (items?, _?):
            // the items and the supplier disagree: suggest the items' shop, but ask
            return ShopGuess(shop: items, sure: false, reason: .items)
        case let (items?, nil):
            return ShopGuess(shop: items, sure: itemsClear, reason: .items)
        case let (nil, supplier?):
            return ShopGuess(shop: supplier, sure: true, reason: .supplier)
        case (nil, nil):
            return nil
        }
    }
}
