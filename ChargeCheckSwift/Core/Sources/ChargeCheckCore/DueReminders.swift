import Foundation

/// One morning reminder: the invoices that fall due that day.
public struct DueNotice: Equatable, Sendable {
    /// "yyyy-MM-dd"
    public var day: String
    public var count: Int
    /// Suppliers, most owed first.
    public var suppliers: [String]
    /// The total, when every invoice that day is in the same currency (otherwise nil: amounts are never mixed).
    public var amount: Double?
    public var currency: String?
}

/// Reminders for payments falling due, one per day with something due, for the next couple of weeks
/// (iOS keeps only a limited number waiting, so they're planned again whenever invoices or payments change).
public enum DueReminders {
    public static func plan(_ dues: [DueInvoice], currencyOf: (DueInvoice) -> String, horizon: Int = 14) -> [DueNotice] {
        let upcoming = dues.filter { $0.daysLeft >= 0 && $0.daysLeft < horizon && $0.amount > 0.005 }
        let byDay = Dictionary(grouping: upcoming, by: { $0.dueDate })
        return byDay.keys.sorted().map { day in
            let list = byDay[day] ?? []
            var perSupplier: [String: Double] = [:]
            for due in list { perSupplier[due.supplier, default: 0] += due.amount }
            let suppliers = perSupplier.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { $0.key }
            let currencies = Set(list.map(currencyOf))
            let single = currencies.count == 1 ? currencies.first : nil
            return DueNotice(day: day, count: list.count, suppliers: suppliers,
                             amount: single == nil ? nil : Money.round2(list.reduce(0) { $0 + $1.amount }), currency: single)
        }
    }
}
