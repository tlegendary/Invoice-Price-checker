import Foundation
import Observation
import ChargeCheckCore

/// The user's shops. Each checked invoice is filed under one. Prices are shared by every shop.
///
/// The shop being viewed ("" = All shops) decides what every screen shows: Home, invoices, suppliers and what you
/// owe them, payments, due dates, Reports and the widget. Choosing a shop also files new invoices under it.
enum Shops {
    static let listKey = "shops.list"
    /// The shop new invoices are filed under.
    static let currentKey = "shops.current"
    /// The shop every screen shows ("" = all shops).
    static let viewKey = "shops.view"

    static func decode(_ data: Data) -> [ShopInfo] {
        (try? JSONDecoder().decode([ShopInfo].self, from: data)) ?? []
    }

    static func encode(_ shops: [ShopInfo]) -> Data {
        (try? JSONEncoder().encode(shops)) ?? Data()
    }

    static var all: [ShopInfo] {
        get { decode(UserDefaults.standard.data(forKey: listKey) ?? Data()) }
        set {
            UserDefaults.standard.set(encode(newValue), forKey: listKey)
            // a removed shop can't stay chosen
            Task { @MainActor in LiveSettings.shared.checkShop() }
        }
    }

    /// The shop new invoices are filed under ("" when there are no shops).
    static var current: String {
        let shops = all
        let id = UserDefaults.standard.string(forKey: currentKey) ?? ""
        if shops.contains(where: { $0.id == id }) { return id }
        return shops.first?.id ?? ""
    }

    static func name(_ id: String) -> String? {
        all.first { $0.id == id }?.name
    }

    /// The name at the top of reports, credit requests and PDFs, taken from the shops (there is no separate
    /// business name any more): the invoice's own shop, else the shop being viewed, else the shop new invoices go to,
    /// else the business name saved by an earlier version. "" when there is none.
    @MainActor
    static func reportName(_ shopId: String = "") -> String {
        for id in [shopId, LiveSettings.shared.shop, current] where !id.isEmpty {
            if let name = name(id), !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        }
        return UserDefaults.standard.string(forKey: SettingKey.business) ?? ""
    }
}

/// Settings every screen follows as soon as they change (no need to close and open the app):
/// the shop being viewed, and how money is shown (the app's currency, a supplier's currency).
///
/// Screens don't have to do anything: every amount is written out through `Money.format`, which reads `moneyStamp`
/// here, and the shop lists read `shop` – so SwiftUI redraws exactly the screens that show them.
@Observable
@MainActor
final class LiveSettings {
    static let shared = LiveSettings()

    /// The shop every screen shows. "" = All shops.
    private(set) var shop: String
    /// Changes whenever the way amounts are shown changes.
    private(set) var moneyStamp = 0

    private init() {
        let saved = UserDefaults.standard.string(forKey: Shops.viewKey) ?? ""
        shop = Shops.all.contains(where: { $0.id == saved }) ? saved : ""
    }

    /// Show one shop (its id) or all shops (""). Choosing a shop also files new invoices under it.
    func view(shop id: String) {
        let valid = id.isEmpty || Shops.all.contains { $0.id == id }
        let chosen = valid ? id : ""
        UserDefaults.standard.set(chosen, forKey: Shops.viewKey)
        if !chosen.isEmpty { UserDefaults.standard.set(chosen, forKey: Shops.currentKey) }
        guard chosen != shop else { return }
        shop = chosen
        Accounts.shared.refreshWidget()
    }

    /// After shops are added, renamed or removed: a removed shop falls back to All shops.
    func checkShop() {
        if !shop.isEmpty && !Shops.all.contains(where: { $0.id == shop }) { view(shop: "") }
    }

    /// The currency, or a supplier's currency, changed: redraw every amount.
    func moneyChanged() {
        moneyStamp &+= 1
        Accounts.shared.refreshWidget()
    }

    /// Lets every amount on screen follow the currency (called once at start-up).
    static func connect() {
        Money.willFormat = {
            // only screens (main thread) need to know; reading invoices in the background is left alone
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { _ = LiveSettings.shared.moneyStamp }
        }
    }
}
