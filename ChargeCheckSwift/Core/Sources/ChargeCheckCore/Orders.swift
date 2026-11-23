import Foundation

/// One line of an order to a supplier.
public struct OrderLine: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// The price-list item, when it is one.
    public var itemID: String?
    public var name: String
    public var qty: Double

    public init(id: String = UUID().uuidString, itemID: String? = nil, name: String, qty: Double) {
        self.id = id
        self.itemID = itemID
        self.name = name
        self.qty = qty
    }
}

/// An order sent to a supplier, then compared with what arrived and what was invoiced.
public struct PurchaseOrder: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var supplier: String
    public var shop: String
    /// "yyyy-MM-dd"
    public var day: String
    public var lines: [OrderLine]
    public var sent: Bool
    /// The invoice it was matched to (the first delivery).
    public var invoiceID: String?
    /// Later deliveries for the same order, when it came in parts. (Since 23 Nov 2026.)
    public var moreInvoices: [String] = []
    public var note: String

    /// Every invoice matched to it, first delivery first.
    public var invoiceIDs: [String] { (invoiceID.map { [$0] } ?? []) + moreInvoices.filter { $0 != invoiceID } }

    public init(id: String = UUID().uuidString, supplier: String, shop: String = "", day: String, lines: [OrderLine] = [],
                sent: Bool = false, invoiceID: String? = nil, note: String = "") {
        self.id = id
        self.supplier = supplier
        self.shop = shop
        self.day = day
        self.lines = lines
        self.sent = sent
        self.invoiceID = invoiceID
        self.note = note
    }

    enum CodingKeys: String, CodingKey { case id, supplier, shop, day, lines, sent, invoiceID, moreInvoices, note }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        supplier = (try? c.decode(String.self, forKey: .supplier)) ?? ""
        shop = (try? c.decode(String.self, forKey: .shop)) ?? ""
        day = (try? c.decode(String.self, forKey: .day)) ?? ""
        lines = (try? c.decode([OrderLine].self, forKey: .lines)) ?? []
        sent = (try? c.decode(Bool.self, forKey: .sent)) ?? false
        invoiceID = try? c.decode(String.self, forKey: .invoiceID)
        moreInvoices = (try? c.decode([String].self, forKey: .moreInvoices)) ?? []
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
    }
}

/// What differs between the order, the delivery and the invoice, for one item.
public struct OrderGap: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        /// Billed for more than was delivered (ticked off as short or missing on the invoice).
        case billedNotDelivered
        /// Delivered and billed less than ordered.
        case short
        /// More than ordered.
        case extra
        /// On the invoice but never ordered.
        case notOrdered
        /// Ordered but not on the invoice at all.
        case notArrived
    }
    public var id: String { kind.rawValue + name }
    public var kind: Kind
    public var name: String
    public var ordered: Double
    public var delivered: Double
    public var invoiced: Double
    /// Money at stake when it is clear: billed but not delivered (at the invoice price), or extra billed.
    public var amount: Double
}

public enum OrderMaths {
    /// What is usually ordered from this supplier: the typical quantity of each item over their last `invoices` invoices,
    /// for items bought on at least two of them, biggest spend first.
    public static func usual(from entries: [HistoryEntry], supplier: String, invoices: Int = 8) -> [OrderLine] {
        let theirs = entries.filter { TextTools.sameSupplier($0.supplier, supplier) && $0.duplicateOf == nil }
            .sorted { $0.savedAt > $1.savedAt }.prefix(invoices)
        var quantities: [String: [Double]] = [:], names: [String: String] = [:], spend: [String: Double] = [:]
        for entry in theirs {
            for line in entry.lines where line.qty > 0 {
                let key = line.matchId ?? TextTools.norm(line.desc)
                guard !key.isEmpty else { continue }
                quantities[key, default: []].append(line.qty)
                if names[key] == nil { names[key] = line.item.isEmpty ? line.desc : line.item }
                spend[key, default: 0] += line.qty * line.unit
            }
        }
        return quantities.filter { $0.value.count >= 2 }
            .sorted { (spend[$0.key] ?? 0) != (spend[$1.key] ?? 0) ? (spend[$0.key] ?? 0) > (spend[$1.key] ?? 0) : $0.key < $1.key }
            .map { key, values in
                let sorted = values.sorted()
                let middle = sorted[sorted.count / 2]
                let isItem = entries.contains { $0.lines.contains { $0.matchId == key } }
                return OrderLine(itemID: isItem ? key : nil, name: names[key] ?? key, qty: middle.rounded())
            }
    }

    /// The message to send the supplier (WhatsApp, text or email).
    public static func message(_ order: PurchaseOrder, from business: String, deliveryDay: String) -> String {
        var text = CoreText.t("Order") + (business.isEmpty ? "" : " – " + business)
        if !deliveryDay.isEmpty { text += "\n" + CoreText.t("For delivery") + ": " + deliveryDay }
        text += "\n"
        for line in order.lines where line.qty > 0 {
            let qty = line.qty == line.qty.rounded() ? String(Int(line.qty)) : String(line.qty)
            text += "\n" + qty + " × " + line.name
        }
        if !order.note.trimmingCharacters(in: .whitespaces).isEmpty { text += "\n\n" + order.note }
        text += "\n\n" + CoreText.t("Thank you")
        return text
    }

    /// Ordered vs delivered vs invoiced. Delivered comes from the delivery tick-off on the invoice
    /// (a line marked missing or returned delivered nothing; a short line delivered qty − short).
    public static func compare(_ order: PurchaseOrder, with invoice: HistoryEntry) -> [OrderGap] {
        func key(itemID: String?, name: String) -> String { itemID ?? TextTools.norm(name) }
        var ordered: [String: (name: String, qty: Double)] = [:]
        for line in order.lines where line.qty > 0 {
            let k = key(itemID: line.itemID, name: line.name)
            ordered[k] = (ordered[k]?.name ?? line.name, (ordered[k]?.qty ?? 0) + line.qty)
        }
        var billed: [String: (name: String, qty: Double, delivered: Double, price: Double)] = [:]
        for line in invoice.lines where line.qty > 0 {
            let k = key(itemID: line.matchId, name: line.item.isEmpty ? line.desc : line.item)
            let delivered = line.excluded ? 0 : max(0, line.qty - line.short)
            let old = billed[k]
            billed[k] = (old?.name ?? (line.item.isEmpty ? line.desc : line.item), (old?.qty ?? 0) + line.qty,
                         (old?.delivered ?? 0) + delivered, line.unit)
        }
        var gaps: [OrderGap] = []
        for (k, bill) in billed {
            let want = ordered[k]?.qty ?? 0
            let name = ordered[k]?.name ?? bill.name
            if bill.delivered + 0.0001 < bill.qty {
                gaps.append(OrderGap(kind: .billedNotDelivered, name: name, ordered: want, delivered: bill.delivered, invoiced: bill.qty,
                                     amount: Money.round2((bill.qty - bill.delivered) * bill.price)))
            }
            if want == 0 {
                gaps.append(OrderGap(kind: .notOrdered, name: name, ordered: 0, delivered: bill.delivered, invoiced: bill.qty,
                                     amount: Money.round2(bill.qty * bill.price)))
            } else if bill.qty > want + 0.0001 {
                gaps.append(OrderGap(kind: .extra, name: name, ordered: want, delivered: bill.delivered, invoiced: bill.qty,
                                     amount: Money.round2((bill.qty - want) * bill.price)))
            } else if bill.qty + 0.0001 < want {
                gaps.append(OrderGap(kind: .short, name: name, ordered: want, delivered: bill.delivered, invoiced: bill.qty, amount: 0))
            }
        }
        for (k, want) in ordered where billed[k] == nil {
            gaps.append(OrderGap(kind: .notArrived, name: want.name, ordered: want.qty, delivered: 0, invoiced: 0, amount: 0))
        }
        let order: [OrderGap.Kind] = [.billedNotDelivered, .extra, .notOrdered, .short, .notArrived]
        return gaps.sorted { (order.firstIndex(of: $0.kind) ?? 9, $0.name) < (order.firstIndex(of: $1.kind) ?? 9, $1.name) }
    }

    /// The invoice that most likely answers this order: the supplier's first one saved on or after the order day
    /// (within 14 days) that isn't already matched to another order.
    public static func likelyInvoice(for order: PurchaseOrder, in entries: [HistoryEntry], taken: Set<String>) -> HistoryEntry? {
        let start = String(order.day.prefix(10))
        guard let startDate = SupplierAccounts.day(start) else { return nil }
        let end = startDate.addingTimeInterval(15 * 86_400)
        return entries.filter { entry in
            guard TextTools.sameSupplier(entry.supplier, order.supplier), entry.duplicateOf == nil, !taken.contains(entry.id) else { return false }
            if !order.shop.isEmpty && !entry.shopId.isEmpty && entry.shopId != order.shop { return false }
            let saved = ISO8601DateFormatter().date(from: entry.savedAt) ?? .distantPast
            return saved >= startDate && saved < end
        }.sorted { $0.savedAt < $1.savedAt }.first
    }
}

/// How much of an order has arrived, across every delivery matched to it.
public struct OrderReceipt: Equatable, Sendable {
    public enum Status: String, Sendable { case notYet, part, received, more }

    public struct Line: Equatable, Sendable {
        public var name: String
        public var ordered: Double
        public var received: Double
        /// Still to come.
        public var outstanding: Double { max(0, ordered - received) }
        /// Came on top of what was ordered.
        public var extra: Double { max(0, received - ordered) }
    }

    public var lines: [Line]
    public var deliveries: Int

    public var status: Status {
        if deliveries == 0 { return .notYet }
        if lines.contains(where: { $0.outstanding > 0.0001 }) { return .part }
        if lines.contains(where: { $0.extra > 0.0001 }) { return .more }
        return .received
    }

    public var stillToCome: [Line] { lines.filter { $0.outstanding > 0.0001 } }
}

public extension OrderMaths {
    /// What arrived for each ordered line over all the order's deliveries: a line ticked missing or returned on the
    /// invoice delivered nothing, a short line delivered qty − short (as `compare`). Lines are matched by item, or by
    /// name when the order line isn't a price-list item.
    static func receipt(_ order: PurchaseOrder, invoices: [HistoryEntry]) -> OrderReceipt {
        let matched = order.invoiceIDs.compactMap { id in invoices.first { $0.id == id } }
        func key(item: String?, name: String) -> String {
            item.map { "id:" + $0 } ?? "name:" + name.lowercased().trimmingCharacters(in: .whitespaces)
        }
        var received: [String: Double] = [:]
        for invoice in matched {
            for line in invoice.lines {
                let delivered = line.excluded ? 0 : max(0, line.qty - line.short)
                received[key(item: line.matchId, name: line.desc), default: 0] += delivered
                if line.matchId != nil { received[key(item: nil, name: line.desc), default: 0] += delivered }
            }
        }
        let lines = order.lines.map { line in
            OrderReceipt.Line(name: line.name, ordered: line.qty, received: received[key(item: line.itemID, name: line.name)] ?? 0)
        }
        return OrderReceipt(lines: lines, deliveries: matched.count)
    }
}
