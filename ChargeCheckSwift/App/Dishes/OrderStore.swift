import Foundation
import ChargeCheckCore

/// Orders sent to suppliers. Kept on the phone and in every backup.
@MainActor
final class OrderStore: ObservableObject {
    static let shared = OrderStore()
    static let key = "orders.v1"

    @Published private(set) var orders: [PurchaseOrder] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([PurchaseOrder].self, from: data) {
            orders = saved
        }
    }

    private func store() {
        if let data = try? JSONEncoder().encode(orders) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func save(_ order: PurchaseOrder) {
        if let index = orders.firstIndex(where: { $0.id == order.id }) { orders[index] = order } else { orders.append(order) }
        orders.sort { $0.day > $1.day }
        store()
    }

    func delete(_ id: String) {
        orders.removeAll { $0.id == id }
        store()
    }

    func restore(_ list: [PurchaseOrder]?) {
        guard let list else { return }
        orders = list
        store()
    }

    /// Invoices already matched to an order.
    var takenInvoices: Set<String> { Set(orders.compactMap { $0.invoiceID }) }
}
