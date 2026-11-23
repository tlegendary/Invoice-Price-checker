import Foundation

/// One change to an item's stock, from where it came from. Movements are never edited: they're read from the
/// invoices, sales, refunds and counts themselves, so the list can always be rebuilt and checked.
public struct StockMovement: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case counted, delivered, sold, refunded }

    /// Unique per source line, so the same sale or invoice seen twice counts once.
    public var id: String
    public var kind: Kind
    public var at: String
    /// + in, − out; for `counted`, what was counted (it replaces what came before).
    public var qty: Double
    /// Invoice or receipt number, for the person reading it.
    public var source: String
}

public enum InventoryLedger {
    /// Every movement of one item in one shop, oldest first, from the last count on.
    public static func movements(item: PriceItem, shop: String, invoices: [HistoryEntry], sales: [Sale],
                                 counts: [StockCount]) -> [StockMovement] {
        var out: [String: StockMovement] = [:]
        let last = counts.filter { $0.shop == shop && $0.itemID == item.id }.max { $0.at < $1.at }
        let since = last?.at ?? ""
        if let last {
            out["count|" + last.at] = StockMovement(id: "count|" + last.at, kind: .counted, at: last.at, qty: last.count, source: "")
        }
        for entry in invoices where entry.duplicateOf == nil && (shop.isEmpty || entry.shopId == shop || entry.shopId.isEmpty)
            && entry.savedAt > since {
            for (index, line) in entry.lines.enumerated() where line.matchId == item.id && !line.excluded {
                let qty = max(0, line.qty - line.short) * item.unitsPerPack
                guard qty != 0 else { continue }
                let id = "inv|\(entry.id)|\(index)"
                out[id] = StockMovement(id: id, kind: .delivered, at: entry.savedAt, qty: qty, source: entry.invNo)
            }
        }
        for sale in sales where sale.shop == shop && sale.at > since {
            for line in sale.lines where line.itemID == item.id {
                let id = "sale|\(sale.id)|\(line.id)"
                out[id] = StockMovement(id: id, kind: line.stockUnits < 0 ? .refunded : .sold, at: sale.at,
                                        qty: -line.stockUnits, source: sale.receiptNumber)
            }
        }
        return out.values.sorted { ($0.kind == .counted ? 0 : 1, $0.at, $0.id) < ($1.kind == .counted ? 0 : 1, $1.at, $1.id) }
    }

    /// Stock on hand from the movements: the count, then everything after it.
    public static func onHand(_ movements: [StockMovement]) -> Double {
        let total = movements.reduce(0.0) { $0 + $1.qty }
        return (total * 1000).rounded() / 1000
    }
}
