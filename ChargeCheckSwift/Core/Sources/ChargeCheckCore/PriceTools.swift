import Foundation

/// One time an item was bought: what the supplier charged per unit.
public struct PricePoint: Identifiable, Equatable, Sendable {
    public var id: String
    public var date: Date
    public var label: String
    public var unit: Double
    public var supplier: String
}

public struct PriceChange: Identifiable, Equatable, Sendable {
    public var itemID: String
    public var name: String
    public var from: Double
    public var to: Double
    public var id: String { itemID }
}

public enum PriceTools {
    /// Every time this item appears on a saved invoice, oldest first (for the price history chart).
    public static func history(of itemID: String, in entries: [HistoryEntry]) -> [PricePoint] {
        var points: [PricePoint] = []
        for entry in entries {
            guard let date = ReportMaths.date(of: entry) else { continue }
            for (index, line) in entry.lines.enumerated() where line.matchId == itemID && !line.excluded && line.unit > 0 {
                points.append(PricePoint(id: entry.id + "-\(index)", date: date, label: entry.date, unit: line.unit, supplier: entry.supplier))
            }
        }
        return points.sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }
    }

    /// Prices on this invoice that are cheaper than the agreed ones. Only items already in the
    /// price list, only lines the app is sure about, never a rise, one change per item (the lowest).
    public static func cheaper(in invoice: InvoiceDraft, book: PriceBook) -> [PriceChange] {
        var best: [String: PriceChange] = [:]
        var order: [String] = []
        for line in invoice.lines {
            guard !line.excluded, line.unit > 0, line.confident == true || line.ok, let item = book.item(line.matchId) else { continue }
            let base = item.basePrice(for: invoice.supplier)
            let unit = Money.round2(line.unit)
            guard unit < base - 0.005 else { continue }
            if let known = best[item.id] {
                if unit < known.to { best[item.id]?.to = unit }
            } else {
                best[item.id] = PriceChange(itemID: item.id, name: item.name, from: base, to: unit)
                order.append(item.id)
            }
        }
        return order.compactMap { best[$0] }
    }

    /// The item with its agreed price changed: this supplier's own price if it has one, otherwise the standard price.
    public static func setting(_ price: Double, on item: PriceItem, supplier: String) -> PriceItem {
        var result = item
        if let index = result.sp.firstIndex(where: { TextTools.sameSupplier($0.s, supplier) }) {
            result.sp[index].p = Money.round2(price)
        } else {
            result.price = Money.round2(price)
        }
        return result
    }
}
