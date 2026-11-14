import Foundation

/// Showing one shop at a time. "" means every shop.
///
/// An invoice belongs to the shop it was filed under. A payment belongs to the shop it was recorded for; a payment
/// recorded before shops were kept apart belongs to its invoices' shop when it paid ticked invoices of one shop,
/// and otherwise is only counted under "All shops" (it is never guessed into a shop).
public enum ShopFilter {
    public static func entries(_ entries: [HistoryEntry], shop: String) -> [HistoryEntry] {
        shop.isEmpty ? entries : entries.filter { $0.shopId == shop }
    }

    /// The shop a payment belongs to, "" when it can't be told.
    /// `shopOf` is invoice id → shop id, for every invoice (not only the shown shop's).
    public static func shop(of payment: SupplierPayment, shopOf: [String: String]) -> String {
        if !payment.shop.isEmpty { return payment.shop }
        guard !payment.invoiceIDs.isEmpty else { return "" }
        let shops = Set(payment.invoiceIDs.map { shopOf[$0] ?? "" })
        return shops.count == 1 ? shops.first ?? "" : ""
    }

    /// The payments of one shop. `allEntries` must be every invoice (to know the shop of payments tied to invoices).
    public static func payments(_ payments: [SupplierPayment], allEntries: [HistoryEntry], shop: String) -> [SupplierPayment] {
        guard !shop.isEmpty else { return payments }
        let shopOf = Dictionary(allEntries.map { ($0.id, $0.shopId) }, uniquingKeysWith: { first, _ in first })
        return payments.filter { self.shop(of: $0, shopOf: shopOf) == shop }
    }

    /// Payments (with an amount) that don't belong to any shop: they only count under "All shops".
    public static func unassigned(_ payments: [SupplierPayment], allEntries: [HistoryEntry]) -> [SupplierPayment] {
        let shopOf = Dictionary(allEntries.map { ($0.id, $0.shopId) }, uniquingKeysWith: { first, _ in first })
        return payments.filter { $0.amount > 0.005 && shop(of: $0, shopOf: shopOf).isEmpty }
    }
}
