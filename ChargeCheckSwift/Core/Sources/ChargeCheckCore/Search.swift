import Foundation

/// One search box for everything: invoices, suppliers, items, payments and credit notes.
public struct SearchResults: Equatable, Sendable {
    public var suppliers: [String] = []
    public var invoices: [HistoryEntry] = []
    public var items: [PriceItem] = []
    public var payments: [SupplierPayment] = []
    /// For each invoice found by one of its lines, the line that matched ("Chicken wings 10kg").
    public var matchedLine: [String: String] = [:]

    public init() {}

    public var isEmpty: Bool { suppliers.isEmpty && invoices.isEmpty && items.isEmpty && payments.isEmpty }
    public var count: Int { suppliers.count + invoices.count + items.count + payments.count }
}

public enum Search {
    /// The words of the query; every one has to be found.
    static func words(_ query: String) -> [String] {
        TextTools.norm(query).split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    static func matches(_ words: [String], _ text: String) -> Bool {
        let hay = TextTools.norm(text)
        return words.allSatisfy { hay.contains($0) }
    }

    /// A number typed in the box ("170.86", "1,500") to find an invoice or payment by its amount.
    static func amount(_ query: String) -> Double? {
        let cleaned = query.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard cleaned.contains(where: { $0.isNumber }), cleaned.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return Double(cleaned)
    }

    static func sameAmount(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }

    public static func find(_ query: String, entries: [HistoryEntry], payments: [SupplierPayment], items: [PriceItem],
                            limit: Int = 50) -> SearchResults {
        var out = SearchResults()
        let words = words(query)
        guard !words.isEmpty else { return out }
        let number = amount(query)

        // suppliers: from invoices and payments, one name each (the newest spelling)
        var seen = Set<String>()
        for name in entries.sorted(by: { $0.savedAt > $1.savedAt }).map({ $0.supplier }) + payments.map({ $0.supplier }) {
            let k = SupplierAccounts.key(name)
            guard !k.isEmpty, seen.insert(k).inserted, matches(words, name) else { continue }
            out.suppliers.append(name)
        }

        // invoices: supplier, number, date, amounts, or an item on them
        for entry in entries.sorted(by: { $0.savedAt > $1.savedAt }) {
            if out.invoices.count >= limit { break }
            let head = [entry.supplier, entry.invNo, entry.date, String(entry.savedAt.prefix(10))].joined(separator: " ")
            if matches(words, head) {
                out.invoices.append(entry)
            } else if let number, sameAmount(number, entry.total) || sameAmount(number, entry.amountToPay.pay) {
                out.invoices.append(entry)
            } else if let line = entry.lines.first(where: { matches(words, $0.desc + " " + $0.item) }) {
                out.invoices.append(entry)
                out.matchedLine[entry.id] = line.item.isEmpty ? line.desc : line.item
            }
        }

        // items in the price list, under any of their names
        out.items = Array(items.filter { matches(words, ([$0.name, $0.cat, $0.supplier] + $0.aliases).joined(separator: " ")) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(limit))

        // payments, credits and starting balances: supplier, reference, note, method, date or amount
        out.payments = Array(payments.filter { payment in
            if let number, sameAmount(number, payment.amount) { return true }
            return matches(words, [payment.supplier, payment.reference, payment.note, payment.method, payment.date,
                                   payment.kind == .credit ? "credit note" : ""].joined(separator: " "))
        }
        .sorted { $0.date > $1.date }
        .prefix(limit))
        return out
    }
}
