import Foundation
import CryptoKit
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
    @Published private(set) var cash: [CashEvent] = []
    @Published private(set) var days: [DayReport] = []
    @Published private(set) var cashiers: [Cashier] = []
    @Published private(set) var parked: [ParkedSale] = []
    @Published var receipt = ReceiptSettings()
    /// Who's serving now (nil: nobody signed in, or the till has no cashiers).
    @Published var cashier: Cashier?

    private init() {
        load()
        loadExtras()
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
    func record(lines: [SaleLine], shop: String, payment: PaymentKind, tendered: Double?, split: [SalePayment]? = nil,
                context: ModelContext) -> Sale {
        let number = nextNumber
        UserDefaults.standard.set(number, forKey: Self.numberKey)
        let sale = Sale(number: number, shop: shop, at: Self.now(), lines: lines, payment: payment, tendered: tendered,
                        cashier: cashier?.name, split: split)
        sales.insert(sale, at: 0)
        store(month: sale.at)
        checkLowStock(shop: shop, items: lines.compactMap(\.itemID), context: context)
        return sale
    }

    /// Refunds what's given (line id → how many), or everything still refundable.
    func refund(_ sale: Sale, quantities: [String: Double]? = nil, context: ModelContext) -> Sale? {
        guard sale.refundOf == nil else { return nil }
        let left = SaleMaths.refundable(sale, refunds: sales.filter { $0.refundOf == sale.id })
        let wanted = (quantities ?? left).compactMapValues { qty -> Double? in qty > 0 ? qty : nil }
            .reduce(into: [String: Double]()) { out, pair in out[pair.key] = min(pair.value, left[pair.key] ?? 0) }
            .filter { $0.value > 0 }
        guard !wanted.isEmpty else { return nil }
        let number = nextNumber
        UserDefaults.standard.set(number, forKey: Self.numberKey)
        let refund = SaleMaths.refund(of: sale, quantities: wanted, number: number, at: Self.now(), cashier: cashier?.name)
        sales.insert(refund, at: 0)
        store(month: refund.at)
        Records.shared.log(.tillRefund, String(localized: "Refund #\(number) of sale #\(sale.number)"), amount: refund.total)
        return refund
    }

    /// Everything on it has been refunded.
    func isRefunded(_ sale: Sale) -> Bool {
        sales.contains { $0.refundOf == sale.id } && SaleMaths.refundable(sale, refunds: sales.filter { $0.refundOf == sale.id }).isEmpty
    }

    func refundable(_ sale: Sale) -> [String: Double] {
        SaleMaths.refundable(sale, refunds: sales.filter { $0.refundOf == sale.id })
    }

    // MARK: cash, end of day

    static let tillFolder = "Till"

    private func loadExtras() {
        func read<T: Decodable>(_ name: String, as: T.Type) -> T? {
            guard let url = AppFiles.documents?.appendingPathComponent(Self.tillFolder + "/" + name),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        cash = read("Cash.json", as: [CashEvent].self) ?? []
        days = read("Days.json", as: [DayReport].self) ?? []
        if let settings = read("Settings.json", as: TillSettingsFile.self) {
            cashiers = settings.cashiers
            receipt = settings.receipt
        }
        if let data = UserDefaults.standard.data(forKey: "till.parked"), let list = try? JSONDecoder().decode([ParkedSale].self, from: data) {
            parked = list
        }
    }

    private func save<T: Encodable>(_ value: T, name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        AppFiles.write(data, folder: Self.tillFolder, name: name)
        if CloudFolder.isOn {
            DispatchQueue.global(qos: .utility).async { CloudFolder.write(data, folder: TillStore.tillFolder, name: name) }
        }
    }

    func addCash(_ kind: CashEvent.Kind, amount: Double, note: String, shop: String) {
        cash.append(CashEvent(shop: shop, at: Self.now(), kind: kind, amount: Money.round2(amount), note: note, cashier: cashier?.name))
        save(cash, name: "Cash.json")
        Records.shared.log(.cashMoved, note.isEmpty ? kind.rawValue : note, amount: kind == .paidOut ? -amount : amount)
    }

    /// When the last Z report of this shop ended ("" = never).
    func lastClose(_ shop: String) -> String { days.filter { $0.shop == shop }.map(\.to).max() ?? "" }

    var nextZ: Int { (days.map(\.number).max() ?? 0) + 1 }

    /// The X report: so far since the last close.
    func current(shop: String) -> DayReport {
        CashDay.report(shop: shop, since: lastClose(shop), to: Self.now(), sales: sales, events: cash, number: nextZ)
    }

    /// The Z report: closes the day. Starts a new day from now.
    @discardableResult
    func closeDay(shop: String, counted: Double?) -> DayReport {
        var report = current(shop: shop)
        report.counted = counted.map { Money.round2($0) }
        report.closedBy = cashier?.name
        days.append(report)
        save(days, name: "Days.json")
        Records.shared.log(.tillClosed, "Z\(report.number)" + (report.difference.map { " · " + Money.format($0) } ?? ""), amount: report.takings)
        return report
    }

    // MARK: cashiers, receipt

    static func hash(_ pin: String) -> String {
        SHA256.hash(data: Data(("chargecheck|" + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func saveSettings() {
        save(TillSettingsFile(cashiers: cashiers, receipt: receipt), name: "Settings.json")
    }

    func addCashier(name: String, pin: String) {
        cashiers.append(Cashier(id: UUID().uuidString, name: name, pinHash: Self.hash(pin)))
        saveSettings()
    }

    func removeCashier(_ id: String) {
        cashiers.removeAll { $0.id == id }
        if cashier?.id == id { cashier = nil }
        saveSettings()
    }

    /// Signs in the cashier whose PIN this is.
    func signIn(pin: String) -> Bool {
        let wanted = Self.hash(pin)
        guard let found = cashiers.first(where: { $0.pinHash == wanted }) else { return false }
        cashier = found
        return true
    }

    // MARK: parked sales

    func park(_ lines: [SaleLine], shop: String, name: String) {
        parked.append(ParkedSale(id: UUID().uuidString, name: name, at: Self.now(), shop: shop, lines: lines))
        storeParked()
    }

    func unpark(_ id: String) -> ParkedSale? {
        guard let index = parked.firstIndex(where: { $0.id == id }) else { return nil }
        let sale = parked.remove(at: index)
        storeParked()
        return sale
    }

    private func storeParked() {
        if let data = try? JSONEncoder().encode(parked) { UserDefaults.standard.set(data, forKey: "till.parked") }
    }

    // MARK: stock

    /// Stock that came in without a checked invoice (bought at a cash and carry, moved from another shop):
    /// the count becomes what's there now plus this.
    func addStock(_ units: Double, level: StockLevel, shop: String) {
        setCount(level.onHand + units, itemID: level.itemID, name: level.name + " (+\(units.formatted()))", shop: shop)
    }

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
        let extras = await Task.detached(priority: .utility) { CloudFolder.readAll(folder: TillStore.tillFolder) }.value
        for file in files { AppFiles.write(file.data, folder: Self.folder, name: file.name) }
        for file in extras { AppFiles.write(file.data, folder: Self.tillFolder, name: file.name) }
        load()
        loadExtras()
    }
}

struct Cashier: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// The PIN is never kept, only a fingerprint of it.
    var pinHash: String
}

struct ParkedSale: Codable, Identifiable {
    var id: String
    var name: String
    var at: String
    var shop: String
    var lines: [SaleLine]
}

/// What's printed on every receipt.
struct ReceiptSettings: Codable, Equatable {
    var header = ""
    var footer = ""
    var vatNumber = ""
    /// Ask "Receipt?" after a sale (off: straight to the next sale, the receipt is still in Sales).
    var askForReceipt = true
}

struct TillSettingsFile: Codable {
    var cashiers: [Cashier]
    var receipt: ReceiptSettings
}

