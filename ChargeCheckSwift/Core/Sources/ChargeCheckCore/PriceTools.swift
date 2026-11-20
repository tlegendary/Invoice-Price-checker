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

/// A new way a supplier writes an item already in the price list.
public struct LearnedName: Equatable, Sendable {
    public var itemID: String
    /// As TextTools.norm writes it – the form kept in the item's "on invoices as" list.
    public var spelling: String
}

public enum PriceTools {
    /// The names on a checked invoice that are new spellings of items in the price list, so the same
    /// item is recognised straight away next time whatever this supplier calls it.
    /// Only lines the app is sure of (a clear match, or one the user confirmed) are learned from.
    public static func newNames(in draft: InvoiceDraft, book: PriceBook) -> [LearnedName] {
        var out: [LearnedName] = []
        for line in draft.lines where !line.excluded && !line.noBase {
            guard let item = book.item(line.matchId), line.confident == true || line.ok else { continue }
            let spelling = TextTools.norm(line.desc)
            // a real name: two words or more, or one long word – never something as loose as "oil"
            guard TextTools.tokens(line.desc).count >= 2 || spelling.count >= 8, spelling.count <= 80,
                  !InvoiceParser.looksGarbled(line.desc) else { continue }
            // already known under this name
            guard spelling != TextTools.norm(item.name), !item.aliases.contains(spelling), item.aliases.count < 15,
                  Matcher.score(line.desc, item: item) < 1 else { continue }
            // a different pack size is not the same item
            guard PackSize.mismatch(invoice: line.desc, item: item.name) == nil else { continue }
            // a price far from the agreed one suggests the wrong item, unless the user confirmed the line
            let base = item.basePrice(for: draft.supplier)
            if !line.ok && base > 0 && abs(line.unit - base) / base > 0.35 { continue }
            // never give two items the same name
            let taken = book.items.contains { other in
                other.id != item.id && (TextTools.norm(other.name) == spelling || other.aliases.contains(spelling))
            }
            if taken || out.contains(where: { $0.spelling == spelling }) { continue }
            out.append(LearnedName(itemID: item.id, spelling: spelling))
        }
        return out
    }

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
