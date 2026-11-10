import Foundation
import ChargeCheckCore

/// The user's shops. Each checked invoice is filed under one, and Reports can show a shop on its own.
/// Prices are shared by every shop.
enum Shops {
    static let listKey = "shops.list"
    static let currentKey = "shops.current"

    static func decode(_ data: Data) -> [ShopInfo] {
        (try? JSONDecoder().decode([ShopInfo].self, from: data)) ?? []
    }

    static func encode(_ shops: [ShopInfo]) -> Data {
        (try? JSONEncoder().encode(shops)) ?? Data()
    }

    static var all: [ShopInfo] {
        get { decode(UserDefaults.standard.data(forKey: listKey) ?? Data()) }
        set { UserDefaults.standard.set(encode(newValue), forKey: listKey) }
    }

    /// The shop new invoices are filed under ("" when there are no shops).
    static var current: String {
        let shops = all
        let id = UserDefaults.standard.string(forKey: currentKey) ?? ""
        if shops.contains(where: { $0.id == id }) { return id }
        return shops.first?.id ?? ""
    }
}
