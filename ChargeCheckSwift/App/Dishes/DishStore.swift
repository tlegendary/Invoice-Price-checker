import Foundation
import ChargeCheckCore

/// The shop's dishes (cost per dish). Kept on the phone and in every backup.
@MainActor
final class DishStore: ObservableObject {
    static let shared = DishStore()
    static let key = "dishes.v1"

    @Published private(set) var dishes: [Dish] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Dish].self, from: data) {
            dishes = saved
        }
    }

    private func store() {
        if let data = try? JSONEncoder().encode(dishes) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func save(_ dish: Dish) {
        if let index = dishes.firstIndex(where: { $0.id == dish.id }) { dishes[index] = dish } else { dishes.append(dish) }
        dishes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        store()
    }

    func delete(_ ids: Set<String>) {
        dishes.removeAll { ids.contains($0.id) }
        store()
    }

    /// From a backup. A backup made before dishes existed leaves them as they are.
    func restore(_ list: [Dish]?) {
        guard let list else { return }
        dishes = list
        store()
    }
}
