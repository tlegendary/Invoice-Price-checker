import Foundation

/// Money that went to (or came back from) a supplier outside an invoice.
public struct SupplierPayment: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Money you paid them.
        case payment
        /// A credit note they gave you (lowers what you owe, like a payment).
        case credit
        /// What you already owed them before you started using the app (raises what you owe).
        case opening
    }

    public var id: String
    public var supplier: String
    public var amount: Double
    /// "yyyy-MM-dd"
    public var date: String
    public var kind: Kind
    public var note: String
    /// The invoices this payment paid off, when they were ticked one by one (empty = paid towards the balance).
    public var invoiceIDs: [String]
    /// How it was paid: "cash", "transfer", "card", "cheque" or "" (not said).
    public var method: String
    /// The bank transfer or cheque number, if any.
    public var reference: String
    /// File name of a photo or screenshot of the receipt, kept by the app.
    public var receipt: String?

    public static let methods = ["transfer", "cash", "card", "cheque"]

    public init(id: String = UUID().uuidString, supplier: String, amount: Double, date: String, kind: Kind = .payment,
                note: String = "", invoiceIDs: [String] = [], method: String = "", reference: String = "", receipt: String? = nil) {
        self.id = id
        self.supplier = supplier
        self.amount = amount
        self.date = date
        self.kind = kind
        self.note = note
        self.invoiceIDs = invoiceIDs
        self.method = method
        self.reference = reference
        self.receipt = receipt
    }

    enum CodingKeys: String, CodingKey { case id, supplier, amount, date, kind, note, invoiceIDs, method, reference, receipt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id) ?? UUID().uuidString
        supplier = c.flexString(.supplier) ?? ""
        amount = c.flexDouble(.amount) ?? 0
        date = c.flexString(.date) ?? ""
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .payment
        note = c.flexString(.note) ?? ""
        invoiceIDs = (try? c.decode([String].self, forKey: .invoiceIDs)) ?? []
        method = c.flexString(.method) ?? ""
        reference = c.flexString(.reference) ?? ""
        receipt = c.flexString(.receipt)
    }
}

/// Everything about one supplier: what they invoiced, what you paid, and what you still owe.
public struct SupplierAccount: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Trusted suppliers' invoices aren't price-checked: scanning one just reads the total.
    public var trusted: Bool
    /// Their invoices, newest first.
    public var entries: [HistoryEntry]
    /// Payments, credits and the starting balance, newest first.
    public var payments: [SupplierPayment]
    public var opening: Double
    /// What their invoices come to (less overcharges and missing items).
    public var invoiced: Double
    public var paid: Double
    public var credits: Double
    /// Invoices marked as paid before payments were recorded in the app.
    public var settledOutside: Double
    /// What you owe them now. Below zero means you paid more than they invoiced.
    public var balance: Double
    /// The invoices not paid off yet, oldest first. Payments towards the balance pay the oldest invoices first.
    public var open: [HistoryEntry]
    public var paidThisWeek: Double
    public var lastPayment: SupplierPayment?
}

public enum SupplierAccounts {
    /// One key per supplier, whatever the spelling, case or alphabet ("APEX FOODS LTD" = "Apex Foods Ltd").
    public static func key(_ name: String) -> String {
        var out = ""
        var space = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                if space && !out.isEmpty { out.append(" ") }
                out.append(ch)
                space = false
            } else {
                space = true
            }
        }
        for ending in [" ltd", " limited", " plc", " gmbh", " sarl", " sas"] where out.hasSuffix(ending) {
            out.removeLast(ending.count)
        }
        return out
    }

    public static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }

    /// Every supplier with an invoice, a payment, or a place on the trusted list. Most owed first.
    public static func accounts(entries: [HistoryEntry], payments: [SupplierPayment], trusted: [String],
                                now: Date = Date(), calendar: Calendar = .current) -> [SupplierAccount] {
        var names: [String: String] = [:]
        var order: [String] = []
        func note(_ name: String) -> String? {
            let k = key(name)
            if k.isEmpty { return nil }
            if names[k] == nil {
                names[k] = name.trimmingCharacters(in: .whitespaces)
                order.append(k)
            }
            return k
        }
        // newest invoices first, so the name shown is the latest spelling
        let byNewest = entries.sorted { $0.savedAt > $1.savedAt }
        var invoices: [String: [HistoryEntry]] = [:]
        for entry in byNewest {
            guard let k = note(entry.supplier) else { continue }
            invoices[k, default: []].append(entry)
        }
        var money: [String: [SupplierPayment]] = [:]
        for payment in payments.sorted(by: { $0.date > $1.date }) {
            guard let k = note(payment.supplier) else { continue }
            money[k, default: []].append(payment)
        }
        let trustedKeys = Set(trusted.compactMap { note($0) })

        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        return order.map { k in
            let theirs = invoices[k] ?? []
            let paidList = money[k] ?? []
            let linked = Set(paidList.flatMap { $0.invoiceIDs })
            let opening = paidList.filter { $0.kind == .opening }.reduce(0) { $0 + $1.amount }
            let paid = paidList.filter { $0.kind == .payment }.reduce(0) { $0 + $1.amount }
            let credits = paidList.filter { $0.kind == .credit }.reduce(0) { $0 + $1.amount }
            let invoiced = theirs.reduce(0) { $0 + $1.amountToPay.pay }
            let outside = theirs.filter { $0.paid != nil && !linked.contains($0.id) }.reduce(0) { $0 + $1.amountToPay.pay }
            let balance = Money.round2(opening + invoiced - outside - paid - credits)

            // payments towards the balance (not tied to invoices) pay the starting balance, then the oldest invoices
            var pool = paidList.filter { $0.kind != .opening && $0.invoiceIDs.isEmpty }.reduce(0) { $0 + $1.amount } - opening
            var open: [HistoryEntry] = []
            for entry in theirs.reversed() where entry.paid == nil && !linked.contains(entry.id) {
                let due = entry.amountToPay.pay
                if open.isEmpty && pool >= due - 0.005 {
                    pool -= due
                } else {
                    open.append(entry)
                }
            }
            let thisWeek = paidList.filter { payment in
                guard payment.kind == .payment, let week, let date = day(payment.date) else { return false }
                return week.contains(date)
            }.reduce(0) { $0 + $1.amount }
            return SupplierAccount(id: k, name: names[k] ?? k, trusted: trustedKeys.contains(k), entries: theirs, payments: paidList,
                                   opening: Money.round2(opening), invoiced: Money.round2(invoiced), paid: Money.round2(paid),
                                   credits: Money.round2(credits), settledOutside: Money.round2(outside), balance: balance,
                                   open: open, paidThisWeek: Money.round2(thisWeek),
                                   lastPayment: paidList.first { $0.kind == .payment })
        }
        .sorted { $0.balance != $1.balance ? $0.balance > $1.balance : $0.name < $1.name }
    }

    /// Whether this supplier is on the trusted list.
    public static func isTrusted(_ supplier: String, trusted: [String]) -> Bool {
        let k = key(supplier)
        guard !k.isEmpty else { return false }
        return trusted.contains { other in
            let o = key(other)
            // the reader sometimes adds or drops a word ("Apex Foods" / "Apex Foods Wholesale")
            return o == k || (o.count >= 4 && (k.hasPrefix(o + " ") || o.hasPrefix(k + " ")))
        }
    }

    /// Paying ticked invoices: one payment for the lot, tied to them.
    public static func payment(for invoices: [HistoryEntry], supplier: String, date: String) -> SupplierPayment {
        SupplierPayment(supplier: supplier, amount: Money.round2(invoices.reduce(0) { $0 + $1.amountToPay.pay }), date: date,
                        invoiceIDs: invoices.map { $0.id })
    }
}

/// What the home screen widget shows. Written by the app, read by the widget.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Line: Codable, Equatable, Sendable {
        public var name: String
        public var owed: Double
        public var openInvoices: Int

        public init(name: String, owed: Double, openInvoices: Int) {
            self.name = name
            self.owed = owed
            self.openInvoices = openInvoices
        }
    }

    public var totalOwed: Double
    public var paidThisWeek: Double
    public var suppliers: [Line]
    public var currency: String
    public var updated: Date
    /// The widget is a Pro feature: true when the app isn't on Pro (it shows how to unlock it instead of figures).
    public var locked: Bool?

    public static func locked(currency: String, now: Date = Date()) -> WidgetSnapshot {
        var snapshot = WidgetSnapshot(totalOwed: 0, paidThisWeek: 0, suppliers: [], currency: currency, updated: now)
        snapshot.locked = true
        return snapshot
    }

    public init(totalOwed: Double, paidThisWeek: Double, suppliers: [Line], currency: String, updated: Date) {
        self.totalOwed = totalOwed
        self.paidThisWeek = paidThisWeek
        self.suppliers = suppliers
        self.currency = currency
        self.updated = updated
    }

    public static func make(_ accounts: [SupplierAccount], currency: String, now: Date = Date()) -> WidgetSnapshot {
        let owing = accounts.filter { $0.balance > 0.005 }
        return WidgetSnapshot(totalOwed: Money.round2(owing.reduce(0) { $0 + $1.balance }),
                              paidThisWeek: Money.round2(accounts.reduce(0) { $0 + $1.paidThisWeek }),
                              suppliers: owing.prefix(6).map { Line(name: $0.name, owed: $0.balance, openInvoices: $0.open.count) },
                              currency: currency, updated: now)
    }
}

/// Prices agreed with one supplier that differ from an item's standard price ("Apex sells us wings at £14.50").
public enum SupplierPrices {
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: String { item.id }
        public var item: PriceItem
        /// This supplier's agreed price.
        public var special: Double
        /// The item's standard price.
        public var standard: Double
        public var difference: Double { Money.round2(special - standard) }
    }

    /// The items with a special price for this supplier, by name.
    public static func rows(for supplier: String, items: [PriceItem]) -> [Row] {
        items.compactMap { item in
            guard let price = item.sp.first(where: { TextTools.sameSupplier($0.s, supplier) })?.p else { return nil }
            return Row(item: item, special: price, standard: item.price)
        }
        .sorted { $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending }
    }

    /// Sets (or with nil, removes) this supplier's special price on an item.
    public static func set(_ price: Double?, for supplier: String, on item: PriceItem) -> PriceItem {
        var changed = item
        changed.sp.removeAll { TextTools.sameSupplier($0.s, supplier) }
        if let price, price > 0 {
            changed.sp.append(SupplierPrice(s: supplier.trimmingCharacters(in: .whitespaces), p: Money.round2(price)))
        }
        return changed
    }

    /// How many special prices each supplier has (for the supplier list).
    public static func count(for supplier: String, items: [PriceItem]) -> Int {
        items.filter { item in item.sp.contains { TextTools.sameSupplier($0.s, supplier) } }.count
    }
}
