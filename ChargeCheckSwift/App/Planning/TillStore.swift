import Foundation
import SwiftData
import UserNotifications
import ChargeCheckCore

/// The till's sales and stock counts.
/// Sales are kept one file per month (Files › ChargeCheck › Till › Sales) and copied to iCloud after every sale;
/// on a new phone they come back from iCloud with the backup. Stock counts travel inside the backup.
@MainActor
final class TillStore: ObservableObject {
    static let shared = TillStore()
    static let countsKey = "till.counts.v1"
    static let numberKey = "till.number"
    static let alertedKey = "till.lowAlerted"
    static let folder = "Till/Sales"

    @Published private(set) var sales: [Sale] = []
    @Published private(set) var counts: [StockCount] = []

    private init() {
        load()
        if let data = UserDefaults.standard.data(forKey: Self.countsKey), let saved = try? JSONDecoder().decode([StockCount].self, from: data) {
            counts = saved
        }
    }

    // MARK: files

    private static func monthName(_ iso: String) -> String { "Sales " + String(iso.prefix(7)) + ".json" }

    private static var directory: URL? {
        AppFiles.documents?.appendingPathComponent(folder, isDirectory: true)
    }

    private func load() {
        guard let directory = Self.directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        var all: [Sale] = []
        for name in names where name.hasSuffix(".json") {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
               let month = try? JSONDecoder().decode([Sale].self, from: data) {
                all += month
            }
        }
        sales = all.sorted { $0.at > $1.at }
    }

    /// Writes the month's file on the phone, then to iCloud in the background.
    private func store(month iso: String) {
        let prefix = String(iso.prefix(7))
        let list = sales.filter { $0.at.hasPrefix(prefix) }.sorted { $0.at < $1.at }
        guard let data = try? JSONEncoder().encode(list) else { return }
        let name = Self.monthName(iso)
        AppFiles.write(data, folder: Self.folder, name: name)
        if CloudFolder.isOn {
            DispatchQueue.global(qos: .utility).async { CloudFolder.write(data, folder: Self.folder, name: name) }
        }
    }

    // MARK: sales

    var nextNumber: Int { UserDefaults.standard.integer(forKey: Self.numberKey) + 1 }

    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    @discardableResult
    func record(lines: [SaleLine], shop: String, payment: PaymentKind, tendered: Double?, context: ModelContext) -> Sale {
        let number = nextNumber
        UserDefaults.standard.set(number, forKey: Self.numberKey)
        let sale = Sale(number: number, shop: shop, at: Self.now(), lines: lines, payment: payment, tendered: tendered)
        sales.insert(sale, at: 0)
        store(month: sale.at)
        checkLowStock(shop: shop, items: lines.compactMap(\.itemID), context: context)
        return sale
    }

    func refund(_ sale: Sale, context: ModelContext) -> Sale? {
        guard sale.refundOf == nil, !isRefunded(sale) else { return nil }
        let number = nextNumber
        UserDefaults.standard.set(number, forKey: Self.numberKey)
        let refund = SaleMaths.refund(of: sale, number: number, at: Self.now())
        sales.insert(refund, at: 0)
        store(month: refund.at)
        Records.shared.log(.tillRefund, String(localized: "Refund #\(number) of sale #\(sale.number)"), amount: refund.total)
        return refund
    }

    func isRefunded(_ sale: Sale) -> Bool { sales.contains { $0.refundOf == sale.id } }

    // MARK: stock

    func setCount(_ count: Double, itemID: String, name: String, shop: String) {
        Records.shared.log(.stockCounted, name + " · \(count.formatted())")
        counts.removeAll { $0.itemID == itemID && $0.shop == shop }
        counts.append(StockCount(itemID: itemID, shop: shop, count: count, at: Self.now()))
        storeCounts()
        alerted.remove(shop + "|" + itemID)
    }

    private func storeCounts() {
        if let data = try? JSONEncoder().encode(counts) { UserDefaults.standard.set(data, forKey: Self.countsKey) }
    }

    func levels(items: [PriceItem], shop: String, invoices: [HistoryEntry]) -> [StockLevel] {
        StockMaths.levels(items: items, shop: shop, invoices: invoices, sales: sales, counts: counts)
    }

    /// Items already warned about (until they're restocked or counted again), so one low item doesn't nag every sale.
    private var alerted: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.alertedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.alertedKey) }
    }

    /// After a sale: anything that just went low gets an order drafted for its supplier (in Suppliers › Orders,
    /// ready to check and send – never sent by itself) and one notification.
    func checkLowStock(shop: String, items ids: [String], context: ModelContext) {
        let items = AppData.items(context)
        let levels = levels(items: items.filter { ids.contains($0.id) }, shop: shop, invoices: AppData.entries(context))
        var warned = alerted
        // restocked items can warn again later
        for level in levels where !level.isLow { warned.remove(shop + "|" + level.itemID) }
        let fresh = levels.filter { $0.isLow && !warned.contains(shop + "|" + $0.itemID) }
        guard !fresh.isEmpty else {
            alerted = warned
            return
        }
        for level in fresh { warned.insert(shop + "|" + level.itemID) }
        alerted = warned
        let drafts = StockMaths.reorders(fresh, items: items, noSupplier: String(localized: "No supplier set"))
        for draft in drafts { OrderStore.shared.addToDraft(supplier: draft.supplier, shop: shop, lines: draft.lines) }
        let content = UNMutableNotificationContent()
        content.title = fresh.count == 1 ? String(localized: "\(fresh[0].name) is running low")
                                         : String(localized: "\(fresh.count) items are running low")
        content.body = drafts.count == 1 ? String(localized: "An order for \(drafts[0].supplier) is ready to check and send in Suppliers › Orders.")
                                         : String(localized: "Orders for \(drafts.count) suppliers are ready to check and send in Suppliers › Orders.")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "chargecheck.low." + UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: backup

    func restore(counts list: [StockCount]?) {
        guard let list else { return }
        counts = list
        storeCounts()
    }

    /// A new phone: the sales files from iCloud (after restoring the backup).
    func pullFromCloud() async {
        let files = await Task.detached(priority: .utility) { CloudFolder.readAll(folder: TillStore.folder) }.value
        guard !files.isEmpty else { return }
        for file in files { AppFiles.write(file.data, folder: Self.folder, name: file.name) }
        load()
    }
}
