import Foundation

// MARK: - An item at the till

/// How an item is sold at the till. Bought by the pack (a case of 24 cans), sold by the unit (1 can).
public struct TillInfo: Codable, Equatable, Hashable, Sendable {
    /// Selling price of one unit, as charged (VAT included when there is VAT).
    public var sell: Double?
    /// Units in one pack bought from the supplier. nil = worked out from the name ("24x330ml" → 24).
    public var perPack: Double?
    public var barcodes: [String]?
    /// VAT % included in the selling price (0, 5 or 20).
    public var vat: Double?
    /// Order more when the stock (in units) is at or below this.
    public var low: Double?
    /// How many packs to order when it runs low. nil = enough for twice the low level.
    public var orderPacks: Double?

    public init(sell: Double? = nil, perPack: Double? = nil, barcodes: [String]? = nil, vat: Double? = nil,
                low: Double? = nil, orderPacks: Double? = nil) {
        self.sell = sell
        self.perPack = perPack
        self.barcodes = barcodes
        self.vat = vat
        self.low = low
        self.orderPacks = orderPacks
    }

    public var isEmpty: Bool {
        sell == nil && perPack == nil && (barcodes ?? []).isEmpty && vat == nil && low == nil && orderPacks == nil
    }
}

extension PriceItem {
    /// Units in one pack (at least 1).
    public var unitsPerPack: Double { max(1, till?.perPack ?? PackGuess.count(in: name)) }

    /// What one unit costs, before VAT: the agreed pack price (this shop's, else the standard) ÷ units per pack.
    public func unitCost(shop: String = "") -> Double {
        price(inShop: shop) / unitsPerPack
    }

    public func hasBarcode(_ code: String) -> Bool {
        let wanted = code.trimmingCharacters(in: .whitespaces)
        return !wanted.isEmpty && (till?.barcodes ?? []).contains(wanted)
    }
}

// MARK: - Sales

public enum PaymentKind: String, Codable, CaseIterable, Sendable {
    case cash, card, other
}

public struct SaleLine: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var itemID: String?
    public var name: String
    /// Units sold (negative on a refund).
    public var qty: Double
    /// Price of one unit, as charged.
    public var price: Double
    /// VAT % in the price.
    public var vat: Double
    /// What one unit cost, before VAT, when it was sold (nil when not known).
    public var cost: Double?

    public init(id: String = UUID().uuidString, itemID: String? = nil, name: String, qty: Double, price: Double, vat: Double = 0, cost: Double? = nil) {
        self.id = id
        self.itemID = itemID
        self.name = name
        self.qty = qty
        self.price = price
        self.vat = vat
        self.cost = cost
    }
}

public struct Sale: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// Receipt number, counting up per phone.
    public var number: Int
    public var shop: String
    /// ISO 8601
    public var at: String
    public var lines: [SaleLine]
    public var payment: PaymentKind
    /// Cash handed over (for the change).
    public var tendered: Double?
    /// The sale this refunds.
    public var refundOf: String?

    public init(id: String = UUID().uuidString, number: Int, shop: String, at: String, lines: [SaleLine], payment: PaymentKind,
                tendered: Double? = nil, refundOf: String? = nil) {
        self.id = id
        self.number = number
        self.shop = shop
        self.at = at
        self.lines = lines
        self.payment = payment
        self.tendered = tendered
        self.refundOf = refundOf
    }

    public var total: Double { Money.round2(lines.reduce(0) { $0 + $1.qty * $1.price }) }
    public var day: String { String(at.prefix(10)) }
}

public struct SalesSummary: Equatable, Sendable {
    public var sales: Int
    public var refunds: Int
    /// Money taken, VAT included (refunds taken off).
    public var takings: Double
    public var vat: Double
    /// Takings without VAT.
    public var net: Double
    /// Net − what the goods cost, over lines whose cost is known.
    public var profit: Double
    /// profit ÷ net of those lines, in %.
    public var margin: Double?
    /// Lines sold without a known cost (left out of the profit).
    public var unknownCost: Int
    public var byPayment: [PaymentKind: Double]
}

public enum SaleMaths {
    public static func vat(of line: SaleLine) -> Double { line.qty * line.price * line.vat / (100 + line.vat) }

    /// Cash given − total, never negative.
    public static func change(tendered: Double, total: Double) -> Double { Money.round2(max(0, tendered - total)) }

    public static func summary(_ sales: [Sale]) -> SalesSummary {
        var takings = 0.0, vat = 0.0, profit = 0.0, costedNet = 0.0, unknown = 0
        var byPayment: [PaymentKind: Double] = [:]
        for sale in sales {
            byPayment[sale.payment, default: 0] += sale.total
            for line in sale.lines {
                let gross = line.qty * line.price
                let lineVat = vat(of: line)
                takings += gross
                vat += lineVat
                if let cost = line.cost {
                    costedNet += gross - lineVat
                    profit += gross - lineVat - cost * line.qty
                } else {
                    unknown += 1
                }
            }
        }
        let margin: Double? = abs(costedNet) > 0.005 ? (profit / costedNet * 1000).rounded() / 10 : nil
        return SalesSummary(sales: sales.filter { $0.refundOf == nil }.count, refunds: sales.filter { $0.refundOf != nil }.count,
                            takings: Money.round2(takings), vat: Money.round2(vat), net: Money.round2(takings - vat),
                            profit: Money.round2(profit), margin: margin, unknownCost: unknown,
                            byPayment: byPayment.mapValues { Money.round2($0) })
    }

    /// The refund of a whole sale: the same lines with the quantities taken back, same payment.
    public static func refund(of sale: Sale, number: Int, at: String) -> Sale {
        Sale(number: number, shop: sale.shop, at: at,
             lines: sale.lines.map { SaleLine(itemID: $0.itemID, name: $0.name, qty: -$0.qty, price: $0.price, vat: $0.vat, cost: $0.cost) },
             payment: sale.payment, refundOf: sale.id)
    }

    /// Profit on one unit at the till: price without VAT − cost. nil without a selling price.
    public static func unitProfit(_ item: PriceItem, shop: String = "") -> Double? {
        guard let sell = item.till?.sell, sell > 0 else { return nil }
        let vat = item.till?.vat ?? 0
        return Money.round2(sell / (1 + vat / 100) - item.unitCost(shop: shop))
    }

    /// A short text receipt (to send or print).
    public static func receipt(_ sale: Sale, shopName: String, currency: String) -> String {
        var text = shopName.isEmpty ? "" : shopName + "\n"
        text += (sale.refundOf == nil ? CoreText.t("Receipt") : CoreText.t("Refund")) + " #\(sale.number) · " + String(sale.at.prefix(16)).replacingOccurrences(of: "T", with: " ") + "\n\n"
        for line in sale.lines {
            let qty = line.qty == line.qty.rounded() ? String(Int(line.qty)) : String(line.qty)
            text += "\(qty) × \(line.name)  " + Money.format(Money.round2(line.qty * line.price), code: currency) + "\n"
        }
        text += "\n" + CoreText.t("Total") + "  " + Money.format(sale.total, code: currency)
        let vat = Money.round2(sale.lines.reduce(0) { $0 + vat(of: $1) })
        if abs(vat) > 0.005 { text += "\n" + CoreText.t("VAT included") + "  " + Money.format(vat, code: currency) }
        if let tendered = sale.tendered, sale.payment == .cash {
            text += "\n" + CoreText.t("Cash") + "  " + Money.format(tendered, code: currency)
            text += "\n" + CoreText.t("Change given") + "  " + Money.format(change(tendered: tendered, total: sale.total), code: currency)
        }
        text += "\n\n" + CoreText.t("Thank you")
        return text
    }
}

// MARK: - Stock

/// A count of what is on the shelf, at a moment. Stock afterwards = this count + deliveries − sales since.
public struct StockCount: Codable, Equatable, Sendable {
    public var itemID: String
    public var shop: String
    public var count: Double
    /// ISO 8601
    public var at: String

    public init(itemID: String, shop: String, count: Double, at: String) {
        self.itemID = itemID
        self.shop = shop
        self.count = count
        self.at = at
    }
}

public struct StockLevel: Equatable, Identifiable, Sendable {
    public var id: String { itemID }
    public var itemID: String
    public var name: String
    public var supplier: String
    /// Units on the shelf now.
    public var onHand: Double
    public var low: Double?
    public var counted: Bool
    public var delivered: Double
    public var sold: Double
    public var isLow: Bool { low.map { onHand <= $0 } ?? false }
}

public enum StockMaths {
    /// Stock is never typed in after the first count: it's worked out from the last count, the deliveries ticked off
    /// on checked invoices (in units: packs × units per pack, short and missing items left out) and the till's sales.
    /// So editing or deleting an invoice or a sale puts the stock right by itself.
    /// Items shown: those sold at the till, counted, or with a reorder level.
    public static func levels(items: [PriceItem], shop: String, invoices: [HistoryEntry], sales: [Sale], counts: [StockCount]) -> [StockLevel] {
        let lastCount = Dictionary(counts.filter { $0.shop == shop }.map { ($0.itemID, $0) }, uniquingKeysWith: { a, b in a.at >= b.at ? a : b })
        let shopInvoices = invoices.filter { $0.duplicateOf == nil && (shop.isEmpty || $0.shopId == shop || $0.shopId.isEmpty) }
        let shopSales = sales.filter { $0.shop == shop }
        return items.filter { $0.isIn(shop: shop) && ($0.till?.sell != nil || $0.till?.low != nil || lastCount[$0.id] != nil) }
            .map { item in
                let count = lastCount[item.id]
                let since = count?.at ?? ""
                var delivered = 0.0, sold = 0.0
                for entry in shopInvoices where entry.savedAt > since {
                    for line in entry.lines where line.matchId == item.id && !line.excluded {
                        delivered += max(0, line.qty - line.short) * item.unitsPerPack
                    }
                }
                for sale in shopSales where sale.at > since {
                    for line in sale.lines where line.itemID == item.id { sold += line.qty }
                }
                let onHand = (count?.count ?? 0) + delivered - sold
                return StockLevel(itemID: item.id, name: item.name, supplier: item.supplier, onHand: (onHand * 1000).rounded() / 1000,
                                  low: item.till?.low, counted: count != nil, delivered: delivered, sold: sold)
            }
            .sorted { ($0.isLow ? 0 : 1, $0.name.lowercased()) < ($1.isLow ? 0 : 1, $1.name.lowercased()) }
    }

    /// Orders for everything running low, one per supplier: the item's pack count to order, or enough packs to get
    /// back to twice the low level. Items without a supplier are grouped under `noSupplier`.
    public static func reorders(_ levels: [StockLevel], items: [PriceItem], noSupplier: String) -> [(supplier: String, lines: [OrderLine])] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: (name: String, lines: [OrderLine])] = [:]
        for level in levels where level.isLow {
            guard let item = byID[level.itemID], let low = level.low else { continue }
            let packs = item.till?.orderPacks ?? max(1, ((low * 2 - level.onHand) / item.unitsPerPack).rounded(.up))
            let supplier = item.supplier.trimmingCharacters(in: .whitespaces).isEmpty ? noSupplier : item.supplier
            let key = SupplierAccounts.key(supplier)
            var group = out[key] ?? (supplier, [])
            group.lines.append(OrderLine(itemID: item.id, name: item.name, qty: packs))
            out[key] = group
        }
        return out.values.map { ($0.name, $0.lines.sorted { $0.name < $1.name }) }.sorted { $0.supplier < $1.supplier }
    }
}
