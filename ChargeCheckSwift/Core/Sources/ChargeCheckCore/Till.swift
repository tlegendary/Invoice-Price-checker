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
    /// Price for the whole pack, as it was bought (a case of 24), when it's also sold that way.
    public var packSell: Double?
    /// Sold at the till only, never bought on a supplier invoice: never matched to invoice lines.
    public var tillOnly: Bool?
    /// Ask for ID before selling (alcohol, tobacco, knives…): Challenge 25.
    public var ageCheck: Bool?
    /// Multi-buy offer: `multiQty` for `multiPrice` (3 for £2).
    public var multiQty: Double?
    public var multiPrice: Double?

    public init(sell: Double? = nil, perPack: Double? = nil, barcodes: [String]? = nil, vat: Double? = nil,
                low: Double? = nil, orderPacks: Double? = nil, packSell: Double? = nil, tillOnly: Bool? = nil,
                ageCheck: Bool? = nil, multiQty: Double? = nil, multiPrice: Double? = nil) {
        self.sell = sell
        self.perPack = perPack
        self.barcodes = barcodes
        self.vat = vat
        self.low = low
        self.orderPacks = orderPacks
        self.packSell = packSell
        self.tillOnly = tillOnly
        self.ageCheck = ageCheck
        self.multiQty = multiQty
        self.multiPrice = multiPrice
    }

    public var isEmpty: Bool {
        sell == nil && perPack == nil && (barcodes ?? []).isEmpty && vat == nil && low == nil && orderPacks == nil
            && packSell == nil && tillOnly != true && ageCheck != true && multiQty == nil && multiPrice == nil
    }

    /// A multi-buy that actually saves something.
    public var offer: (qty: Double, price: Double)? {
        guard let q = multiQty, let p = multiPrice, q >= 2, p > 0 else { return nil }
        return (q, p)
    }
}

extension PriceItem {
    /// Units in one pack (at least 1).
    public var unitsPerPack: Double { max(1, till?.perPack ?? PackGuess.count(in: name)) }

    /// What one unit costs, before VAT: the agreed pack price (this shop's, else the standard) ÷ units per pack.
    public func unitCost(shop: String = "") -> Double {
        price(inShop: shop) / unitsPerPack
    }

    /// Only sold at the till (not on supplier invoices).
    public var isTillOnly: Bool { till?.tillOnly == true }

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
    /// What one of these cost, before VAT, when it was sold (nil when not known). For a pack: the pack's cost.
    public var cost: Double?
    /// Stock units in one of these: 1 for a single, 24 for a case of 24.
    public var units: Double?
    /// Money taken off this line (a discount, a multi-buy, a share of a basket discount). Negative on a refund.
    public var discount: Double?

    public init(id: String = UUID().uuidString, itemID: String? = nil, name: String, qty: Double, price: Double, vat: Double = 0,
                cost: Double? = nil, units: Double? = nil, discount: Double? = nil) {
        self.id = id
        self.itemID = itemID
        self.name = name
        self.qty = qty
        self.price = price
        self.vat = vat
        self.cost = cost
        self.units = units
        self.discount = discount
    }

    /// What was charged for the line.
    public var gross: Double { qty * price - (discount ?? 0) }
    /// Stock units this line takes off (or puts back, on a refund).
    public var stockUnits: Double { qty * (units ?? 1) }
}

public struct SalePayment: Codable, Equatable, Sendable {
    public var kind: PaymentKind
    public var amount: Double
    public init(kind: PaymentKind, amount: Double) {
        self.kind = kind
        self.amount = amount
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
    /// Who served (when the till has cashiers).
    public var cashier: String?
    /// Paid partly one way, partly another (cash + card). nil = all by `payment`.
    public var split: [SalePayment]?

    public init(id: String = UUID().uuidString, number: Int, shop: String, at: String, lines: [SaleLine], payment: PaymentKind,
                tendered: Double? = nil, refundOf: String? = nil, cashier: String? = nil, split: [SalePayment]? = nil) {
        self.id = id
        self.number = number
        self.shop = shop
        self.at = at
        self.lines = lines
        self.payment = payment
        self.tendered = tendered
        self.refundOf = refundOf
        self.cashier = cashier
        self.split = split
    }

    public var total: Double { Money.round2(lines.reduce(0) { $0 + $1.gross }) }

    /// How it was paid, amount by amount.
    public var payments: [SalePayment] {
        if let split, !split.isEmpty { return split }
        return [SalePayment(kind: payment, amount: total)]
    }
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
    public static func vat(of line: SaleLine) -> Double { line.gross * line.vat / (100 + line.vat) }

    /// Cash given − total, never negative.
    public static func change(tendered: Double, total: Double) -> Double { Money.round2(max(0, tendered - total)) }

    public static func summary(_ sales: [Sale]) -> SalesSummary {
        var takings = 0.0, vatTotal = 0.0, profit = 0.0, costedNet = 0.0, unknown = 0
        var byPayment: [PaymentKind: Double] = [:]
        for sale in sales {
            for part in sale.payments { byPayment[part.kind, default: 0] += part.amount }
            for line in sale.lines {
                let gross = line.gross
                let lineVat = vat(of: line)
                takings += gross
                vatTotal += lineVat
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
                            takings: Money.round2(takings), vat: Money.round2(vatTotal), net: Money.round2(takings - vatTotal),
                            profit: Money.round2(profit), margin: margin, unknownCost: unknown,
                            byPayment: byPayment.mapValues { Money.round2($0) })
    }

    /// The refund of a whole sale: the same lines with the quantities taken back, same payment.
    public static func refund(of sale: Sale, number: Int, at: String, cashier: String? = nil) -> Sale {
        refund(of: sale, quantities: Dictionary(sale.lines.map { ($0.id, $0.qty) }, uniquingKeysWith: { a, _ in a }),
               number: number, at: at, cashier: cashier)
    }

    /// The refund of some of a sale: line id → how many to take back (at most what was sold, less earlier refunds
    /// are the caller's to check). Discounts come back in proportion. Paid back the way the sale was paid.
    public static func refund(of sale: Sale, quantities: [String: Double], number: Int, at: String, cashier: String? = nil) -> Sale {
        let lines = sale.lines.compactMap { line -> SaleLine? in
            guard let back = quantities[line.id], back > 0, line.qty > 0 else { return nil }
            let qty = min(back, line.qty)
            let share = (line.discount ?? 0) * qty / line.qty
            return SaleLine(itemID: line.itemID, name: line.name, qty: -qty, price: line.price, vat: line.vat, cost: line.cost,
                            units: line.units, discount: share == 0 ? nil : -Money.round2(share))
        }
        return Sale(number: number, shop: sale.shop, at: at, lines: lines, payment: sale.split == nil ? sale.payment : .cash,
                    refundOf: sale.id, cashier: cashier)
    }

    /// How many of each line are still refundable, after earlier refunds of this sale.
    public static func refundable(_ sale: Sale, refunds: [Sale]) -> [String: Double] {
        var left = Dictionary(sale.lines.map { ($0.id, $0.qty) }, uniquingKeysWith: { a, _ in a })
        for refund in refunds where refund.refundOf == sale.id {
            for line in refund.lines {
                // refund lines are new ids: match back by item and price, the first that still has some left
                if let original = sale.lines.first(where: { $0.itemID == line.itemID && $0.name == line.name && $0.price == line.price
                    && (left[$0.id] ?? 0) > 0 }) {
                    left[original.id] = max(0, (left[original.id] ?? 0) + line.qty)
                }
            }
        }
        return left.filter { $0.value > 0.0001 }
    }

    /// Multi-buy: money off a line for every full set of `qty` (3 for £2 on 7 at 90p → 2 sets × (£2.70 − £2) = £1.40).
    public static func offerDiscount(qty: Double, price: Double, offer: (qty: Double, price: Double)?) -> Double {
        guard let offer, qty >= offer.qty else { return 0 }
        let sets = (qty / offer.qty).rounded(.down)
        return Money.round2(max(0, sets * (offer.qty * price - offer.price)))
    }

    /// A basket discount (money off the whole sale) shared across the lines in proportion to their value,
    /// so VAT and profit stay right line by line. The last line takes the rounding.
    public static func shareDiscount(_ amount: Double, over lines: [SaleLine]) -> [SaleLine] {
        let totals = lines.map { max(0, $0.gross) }
        let sum = totals.reduce(0, +)
        guard amount > 0, sum > 0 else { return lines }
        let off = min(amount, sum)
        var given = 0.0
        return lines.enumerated().map { index, line in
            var out = line
            let share = index == lines.count - 1 ? Money.round2(off - given) : Money.round2(off * totals[index] / sum)
            given += share
            out.discount = Money.round2((line.discount ?? 0) + share)
            return out
        }
    }

    /// Profit on one unit at the till: price without VAT − cost. nil without a selling price.
    public static func unitProfit(_ item: PriceItem, shop: String = "") -> Double? {
        guard let sell = item.till?.sell, sell > 0 else { return nil }
        let vat = item.till?.vat ?? 0
        return Money.round2(sell / (1 + vat / 100) - item.unitCost(shop: shop))
    }

    /// A short text receipt (to send or print).
    public static func receipt(_ sale: Sale, shopName: String, currency: String, header: String = "", footer: String = "",
                               vatNumber: String = "") -> String {
        var text = shopName.isEmpty ? "" : shopName + "\n"
        let top = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if !top.isEmpty { text += top + "\n" }
        let vatNo = vatNumber.trimmingCharacters(in: .whitespaces)
        if !vatNo.isEmpty { text += CoreText.t("VAT no.") + " " + vatNo + "\n" }
        text += (sale.refundOf == nil ? CoreText.t("Receipt") : CoreText.t("Refund")) + " #\(sale.number) · " + String(sale.at.prefix(16)).replacingOccurrences(of: "T", with: " ") + "\n\n"
        for line in sale.lines {
            let qty = line.qty == line.qty.rounded() ? String(Int(line.qty)) : String(line.qty)
            text += "\(qty) × \(line.name)  " + Money.format(Money.round2(line.qty * line.price), code: currency) + "\n"
            if let off = line.discount, abs(off) > 0.005 {
                text += "   " + CoreText.t("Discount") + "  −" + Money.format(abs(off), code: currency) + "\n"
            }
        }
        text += "\n" + CoreText.t("Total") + "  " + Money.format(sale.total, code: currency)
        let included = Money.round2(sale.lines.reduce(0) { $0 + vat(of: $1) })
        if abs(included) > 0.005 { text += "\n" + CoreText.t("VAT included") + "  " + Money.format(included, code: currency) }
        if let split = sale.split, split.count > 1 {
            for part in split { text += "\n" + CoreText.t(part.kind == .cash ? "Cash" : (part.kind == .card ? "Card" : "Other")) + "  " + Money.format(part.amount, code: currency) }
        }
        if let tendered = sale.tendered, sale.payments.contains(where: { $0.kind == .cash }) {
            text += "\n" + CoreText.t("Cash") + "  " + Money.format(tendered, code: currency)
            let cash = sale.payments.filter { $0.kind == .cash }.reduce(0) { $0 + $1.amount }
            text += "\n" + CoreText.t("Change given") + "  " + Money.format(change(tendered: tendered, total: cash), code: currency)
        }
        if let cashier = sale.cashier, !cashier.isEmpty { text += "\n" + CoreText.t("Served by") + " " + cashier }
        let bottom = footer.trimmingCharacters(in: .whitespacesAndNewlines)
        text += "\n\n" + (bottom.isEmpty ? CoreText.t("Thank you") : bottom)
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
                    for line in sale.lines where line.itemID == item.id { sold += line.stockUnits }
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

// MARK: - Sales reports

public struct SalesRow: Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var qty: Double
    public var takings: Double
    public var profit: Double?
}

public enum SalesReports {
    /// Best sellers: by item, most taken first.
    public static func byItem(_ sales: [Sale]) -> [SalesRow] {
        group(sales) { line, _ in line.name }
    }

    /// By the item's category in the price list (`other` for lines without one).
    public static func byCategory(_ sales: [Sale], items: [PriceItem], other: String) -> [SalesRow] {
        let cats = Dictionary(items.map { ($0.id, $0.cat) }, uniquingKeysWith: { a, _ in a })
        return group(sales) { line, _ in
            let cat = line.itemID.flatMap { cats[$0] }?.trimmingCharacters(in: .whitespaces) ?? ""
            return cat.isEmpty ? other : cat
        }
    }

    public static func byCashier(_ sales: [Sale], nobody: String) -> [SalesRow] {
        group(sales) { _, sale in (sale.cashier ?? "").isEmpty ? nobody : sale.cashier! }
    }

    /// Takings per hour of the day (local time), "09:00" … in hour order.
    public static func byHour(_ sales: [Sale], calendar: Calendar = .current) -> [SalesRow] {
        let iso = ISO8601DateFormatter()
        let rows = group(sales) { _, sale in
            guard let date = iso.date(from: sale.at) else { return "–" }
            return String(format: "%02d:00", calendar.component(.hour, from: date))
        }
        return rows.sorted { $0.name < $1.name }
    }

    private static func group(_ sales: [Sale], key: (SaleLine, Sale) -> String) -> [SalesRow] {
        var rows: [String: (qty: Double, takings: Double, profit: Double, known: Bool)] = [:]
        for sale in sales {
            for line in sale.lines {
                let k = key(line, sale)
                var row = rows[k] ?? (0, 0, 0, true)
                row.qty += line.qty
                row.takings += line.gross
                if let cost = line.cost {
                    row.profit += line.gross - SaleMaths.vat(of: line) - cost * line.qty
                } else {
                    row.known = false
                }
                rows[k] = row
            }
        }
        return rows.map { SalesRow(name: $0.key, qty: $0.value.qty, takings: Money.round2($0.value.takings),
                                   profit: $0.value.known ? Money.round2($0.value.profit) : nil) }
            .sorted { $0.takings != $1.takings ? $0.takings > $1.takings : $0.name < $1.name }
    }

    /// Every line of every sale, for a spreadsheet.
    public static func csv(_ sales: [Sale]) -> String {
        var rows = [[CoreText.t("Date"), CoreText.t("Receipt"), CoreText.t("Item"), CoreText.t("Qty"), CoreText.t("Price"),
                     CoreText.t("Discount"), CoreText.t("Total"), CoreText.t("VAT"), CoreText.t("Cost"), CoreText.t("Paid by"), CoreText.t("Served by")]]
        for sale in sales.sorted(by: { $0.at < $1.at }) {
            let paid = sale.payments.map { $0.kind.rawValue }.joined(separator: "+")
            for line in sale.lines {
                rows.append([String(sale.at.prefix(16)).replacingOccurrences(of: "T", with: " "), "\(sale.number)", line.name,
                             line.qty.formatted(), ReportMaths.amount(line.price), ReportMaths.amount(line.discount ?? 0),
                             ReportMaths.amount(line.gross), ReportMaths.amount(SaleMaths.vat(of: line)),
                             line.cost.map { ReportMaths.amount($0 * line.qty) } ?? "", paid, sale.cashier ?? ""])
            }
        }
        return rows.map { $0.map(ReportMaths.cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - Cash in the till, and the end of the day

/// Money in or out of the drawer that isn't a sale.
public struct CashEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Cash put in the drawer at the start.
        case float
        /// Cash added (change from the bank).
        case paidIn
        /// Cash taken out (paid a delivery driver, bought milk).
        case paidOut
    }
    public var id: String
    public var shop: String
    public var at: String
    public var kind: Kind
    public var amount: Double
    public var note: String
    public var cashier: String?

    public init(id: String = UUID().uuidString, shop: String, at: String, kind: Kind, amount: Double, note: String = "", cashier: String? = nil) {
        self.id = id
        self.shop = shop
        self.at = at
        self.kind = kind
        self.amount = amount
        self.note = note
        self.cashier = cashier
    }
}

/// An end-of-day (Z) report: everything since the last one, the cash there should be, and what was counted.
public struct DayReport: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var number: Int
    public var shop: String
    public var from: String
    public var to: String
    public var sales: Int
    public var refunds: Int
    public var takings: Double
    public var vat: Double
    public var profit: Double
    public var cash: Double
    public var card: Double
    public var other: Double
    public var float: Double
    public var paidIn: Double
    public var paidOut: Double
    /// Float + cash sales + paid in − paid out.
    public var expected: Double
    /// Counted in the drawer at the end (nil when not counted).
    public var counted: Double?
    public var closedBy: String?

    /// counted − expected: positive = more cash than there should be.
    public var difference: Double? { counted.map { Money.round2($0 - expected) } }
}

public enum CashDay {
    /// What's happened since the last Z report (or ever): the X report. `number` is the next Z number.
    public static func report(shop: String, since: String, to: String, sales: [Sale], events: [CashEvent], number: Int) -> DayReport {
        let theseSales = sales.filter { $0.shop == shop && $0.at > since && $0.at <= to }
        let theseEvents = events.filter { $0.shop == shop && $0.at > since && $0.at <= to }
        let summary = SaleMaths.summary(theseSales)
        func sum(_ kind: CashEvent.Kind) -> Double { Money.round2(theseEvents.filter { $0.kind == kind }.reduce(0) { $0 + $1.amount }) }
        let cash = summary.byPayment[.cash] ?? 0
        let float = sum(.float), paidIn = sum(.paidIn), paidOut = sum(.paidOut)
        return DayReport(id: UUID().uuidString, number: number, shop: shop, from: since, to: to, sales: summary.sales, refunds: summary.refunds,
                         takings: summary.takings, vat: summary.vat, profit: summary.profit, cash: cash,
                         card: summary.byPayment[.card] ?? 0, other: summary.byPayment[.other] ?? 0,
                         float: float, paidIn: paidIn, paidOut: paidOut,
                         expected: Money.round2(float + cash + paidIn - paidOut), counted: nil, closedBy: nil)
    }

    public static func text(_ report: DayReport, shopName: String, currency: String) -> String {
        func m(_ v: Double) -> String { Money.format(v, code: currency) }
        var lines = [shopName, CoreText.t("End of day") + " Z\(report.number)",
                     String(report.from.prefix(16)).replacingOccurrences(of: "T", with: " ") + " – " + String(report.to.prefix(16)).replacingOccurrences(of: "T", with: " "), "",
                     CoreText.t("Sales") + ": \(report.sales)   " + CoreText.t("Refunds") + ": \(report.refunds)",
                     CoreText.t("Takings") + ": " + m(report.takings), CoreText.t("VAT") + ": " + m(report.vat),
                     CoreText.t("Profit") + ": " + m(report.profit), "",
                     CoreText.t("Cash") + ": " + m(report.cash), CoreText.t("Card") + ": " + m(report.card), CoreText.t("Other") + ": " + m(report.other), "",
                     CoreText.t("Float") + ": " + m(report.float), CoreText.t("Paid in") + ": " + m(report.paidIn), CoreText.t("Paid out") + ": " + m(report.paidOut),
                     CoreText.t("Cash expected") + ": " + m(report.expected)]
        if let counted = report.counted {
            lines.append(CoreText.t("Cash counted") + ": " + m(counted))
            lines.append(CoreText.t("Difference") + ": " + m(report.difference ?? 0))
        }
        if let by = report.closedBy, !by.isEmpty { lines.append(CoreText.t("Served by") + " " + by) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Importing products from another till or a spreadsheet

public struct ImportedProduct: Equatable, Sendable {
    public var name: String
    public var sell: Double?
    public var cost: Double?
    public var barcode: String?
    public var category: String?
    public var vat: Double?
    public var stock: Double?
}

public enum ProductImport {
    /// Reads a CSV (commas, semicolons or tabs; quotes allowed) with a header row. Columns are found by name in
    /// English, German, French or Arabic-free common till exports: name/description/product, price/sell/retail/RRP,
    /// cost/buy, barcode/EAN/UPC/PLU, category/department/group, VAT/tax, stock/qty/on hand.
    public static func parse(_ text: String) -> (products: [ImportedProduct], columns: [String: String]) {
        let clean = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let firstLine = clean.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let delimiter: Character = [";", "\t", ","].max { a, b in firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count } ?? ","
        let rows = table(clean, delimiter: delimiter)
        guard let header = rows.first else { return ([], [:]) }
        let names = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func column(_ words: [String], avoid: [String] = []) -> Int? {
            names.firstIndex { name in words.contains { name == $0 || name.contains($0) } && !avoid.contains { name.contains($0) } }
        }
        let nameCol = column(["name", "description", "product", "item", "bezeichnung", "artikel", "désignation", "libellé", "produit"],
                             avoid: ["category", "group", "department"])
        let sellCol = column(["sell", "selling", "retail", "rrp", "sale price", "price", "preis", "prix"], avoid: ["cost", "buy", "purchase", "einkauf", "achat"])
        let costCol = column(["cost", "buy", "purchase", "einkauf", "achat", "coût"])
        let codeCol = column(["barcode", "ean", "upc", "gtin", "plu", "code barre", "strichcode"])
        let catCol = column(["category", "department", "group", "kategorie", "warengruppe", "catégorie", "rayon"])
        let vatCol = column(["vat", "tax", "mwst", "tva"])
        let stockCol = column(["stock", "on hand", "onhand", "quantity", "qty", "bestand", "quantité"])
        var columns: [String: String] = [:]
        for (key, index) in [("name", nameCol), ("price", sellCol), ("cost", costCol), ("barcode", codeCol), ("category", catCol), ("vat", vatCol), ("stock", stockCol)] {
            if let index { columns[key] = header[index] }
        }
        guard let nameCol else { return ([], columns) }
        func cell(_ row: [String], _ index: Int?) -> String? {
            guard let index, index < row.count else { return nil }
            let value = row[index].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        func number(_ text: String?) -> Double? {
            guard var t = text else { return nil }
            t = t.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
            if t.contains(","), !t.contains(".") { t = t.replacingOccurrences(of: ",", with: ".") } else { t = t.replacingOccurrences(of: ",", with: "") }
            return Double(t)
        }
        let products = rows.dropFirst().compactMap { row -> ImportedProduct? in
            guard let name = cell(row, nameCol) else { return nil }
            var vat = number(cell(row, vatCol))
            if let v = vat, v > 0, v < 1 { vat = v * 100 }   // 0.2 → 20
            return ImportedProduct(name: name, sell: number(cell(row, sellCol)).map { Money.round2($0) },
                                   cost: number(cell(row, costCol)).map { Money.round2($0) },
                                   barcode: cell(row, codeCol)?.filter { !$0.isWhitespace },
                                   category: cell(row, catCol), vat: vat, stock: number(cell(row, stockCol)))
        }
        return (products, columns)
    }

    /// Splits CSV text into rows of cells, keeping commas and line breaks inside quotes.
    static func table(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { cell.append("\""); chars = chars.dropFirst() } else { quoted = false }
                } else { cell.append(c) }
            } else if c == "\"" {
                quoted = true
            } else if c == delimiter {
                row.append(cell); cell = ""
            } else if c == "\n" {
                row.append(cell); cell = ""
                if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.append(row) }
                row = []
            } else {
                cell.append(c)
            }
        }
        row.append(cell)
        if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.append(row) }
        return rows
    }
}

