import Foundation
import ChargeCheckCore
import UserNotifications

/// Monthly budgets and the dates suppliers' agreed prices end. Kept on the phone and in every backup.
@MainActor
final class BudgetStore: ObservableObject {
    static let shared = BudgetStore()
    static let budgetsKey = "budgets.v1"
    static let dealsKey = "deals.v1"

    @Published private(set) var budgets: [Budget] = []
    /// Supplier name → "yyyy-MM-dd" (one per supplier, however its name is spelled)
    @Published private(set) var deals: [String: String] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.budgetsKey), let saved = try? JSONDecoder().decode([Budget].self, from: data) {
            budgets = saved
        }
        deals = (UserDefaults.standard.dictionary(forKey: Self.dealsKey) as? [String: String]) ?? [:]
    }

    func save(_ budget: Budget) {
        if let index = budgets.firstIndex(where: { $0.id == budget.id }) { budgets[index] = budget } else { budgets.append(budget) }
        storeBudgets()
    }

    func delete(_ id: String) {
        budgets.removeAll { $0.id == id }
        storeBudgets()
    }

    private func storeBudgets() {
        if let data = try? JSONEncoder().encode(budgets) { UserDefaults.standard.set(data, forKey: Self.budgetsKey) }
    }

    /// The supplier's agreed prices end on `day` ("yyyy-MM-dd"), or nil to remove it.
    func setDeal(_ supplier: String, until day: String?) {
        let key = SupplierAccounts.key(supplier)
        for name in deals.keys where SupplierAccounts.key(name) == key { deals[name] = nil }
        deals[supplier] = day
        UserDefaults.standard.set(deals, forKey: Self.dealsKey)
        DealReminder.plan(supplier: supplier, key: key, day: day)
    }

    func deal(for supplier: String) -> String? {
        let key = SupplierAccounts.key(supplier)
        return deals.first { SupplierAccounts.key($0.key) == key }?.value
    }

    func restore(budgets: [Budget]?, deals: [String: String]?) {
        if let budgets {
            self.budgets = budgets
            storeBudgets()
        }
        if let deals {
            self.deals = deals
            UserDefaults.standard.set(deals, forKey: Self.dealsKey)
        }
    }

    /// Home's extra "Needs attention" rows: budgets nearly used up, and price deals ending.
    func attention(entries: [HistoryEntry], items: [PriceItem]) -> [Attention] {
        var out: [Attention] = []
        let status = BudgetMaths.status(budgets, entries: entries, items: items, other: String(localized: "Other"))
        let warned = status.filter(\.warning)
        if !warned.isEmpty { out.append(Attention(kind: .overBudget, count: warned.count, amount: 0)) }
        let ending = DealDates.ending(deals)
        if !ending.isEmpty { out.append(Attention(kind: .dealsEnding, count: ending.count, amount: 0)) }
        return out
    }
}

/// A reminder 14 days before a supplier's agreed prices end, so there's time to renegotiate.
enum DealReminder {
    static func plan(supplier: String, key: String, day: String?) {
        let center = UNUserNotificationCenter.current()
        let id = "chargecheck.deal." + key
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard let day, let end = SupplierAccounts.day(day),
              let fire = Calendar.current.date(byAdding: .day, value: -14, to: end), fire > Date() else { return }
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Prices from \(supplier) end in 2 weeks")
            content.body = String(localized: "A good time to agree the next prices. Their supplier report shows your biggest items and cheaper prices elsewhere.")
            var when = Calendar.current.dateComponents([.year, .month, .day], from: fire)
            when.hour = 10
            try? await center.add(UNNotificationRequest(identifier: id, content: content,
                                                       trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
        }
    }
}
