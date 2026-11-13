import Foundation

/// One unpaid invoice with its payment due date (from the supplier's credit period).
public struct DueInvoice: Identifiable, Equatable, Sendable {
    public var id: String { entry.id }
    public var supplier: String
    public var entry: HistoryEntry
    /// What is still to pay on it.
    public var amount: Double
    /// "yyyy-MM-dd"
    public var dueDate: String
    /// Days until it's due: 0 = today, below 0 = overdue by that many days.
    public var daysLeft: Int

    public init(supplier: String, entry: HistoryEntry, amount: Double, dueDate: String, daysLeft: Int) {
        self.supplier = supplier
        self.entry = entry
        self.amount = amount
        self.dueDate = dueDate
        self.daysLeft = daysLeft
    }
}

/// Payment due dates. Each supplier can have a credit period ("pay within 30 days");
/// an invoice is due that many days after its date. 0 days = pay on delivery.
public enum DueDates {
    /// The day the invoice counts from: its printed date, or the day it was checked when that can't be read
    /// (or looks wrong: in the future, or more than a year before it was checked).
    public static func start(of entry: HistoryEntry) -> Date {
        let saved = SupplierAccounts.day(entry.savedAt) ?? Date()
        guard let printed = ReportMaths.date(of: entry) else { return saved }
        let gap = saved.timeIntervalSince(printed)
        if gap < -86_400 || gap > 366 * 86_400 { return saved }
        return printed
    }

    public static func dueDate(of entry: HistoryEntry, days: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: max(0, days), to: calendar.startOfDay(for: start(of: entry))) ?? start(of: entry)
    }

    /// Every unpaid invoice of the suppliers that have a credit period, soonest due first.
    /// `creditDays` is keyed by `SupplierAccounts.key`.
    public static func open(accounts: [SupplierAccount], creditDays: [String: Int], now: Date = Date(),
                            calendar: Calendar = .current) -> [DueInvoice] {
        let today = calendar.startOfDay(for: now)
        var out: [DueInvoice] = []
        for account in accounts where account.balance > 0.005 {
            guard let days = creditDays[account.id] else { continue }
            // the balance may be smaller than the open invoices add up to (a part payment): the oldest are paid first,
            // so the newest invoices keep their full amount and the oldest one carries the rest
            var left = account.balance
            var rows: [DueInvoice] = []
            for entry in account.open.reversed() {
                guard left > 0.005 else { break }
                let amount = Money.round2(min(entry.amountToPay.pay, left))
                left -= amount
                let due = dueDate(of: entry, days: days, calendar: calendar)
                let daysLeft = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: due)).day ?? 0
                rows.append(DueInvoice(supplier: account.name, entry: entry, amount: amount,
                                       dueDate: SupplierAccounts.dayText(due), daysLeft: daysLeft))
            }
            out += rows
        }
        return out.sorted { $0.daysLeft != $1.daysLeft ? $0.daysLeft < $1.daysLeft : $0.supplier < $1.supplier }
    }

    /// Cash needed in the next `days` days, overdue included.
    public static func cashNeeded(_ due: [DueInvoice], withinDays days: Int = 7) -> Double {
        Money.round2(due.filter { $0.daysLeft <= days }.reduce(0) { $0 + $1.amount })
    }
}
