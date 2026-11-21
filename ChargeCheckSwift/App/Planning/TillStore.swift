import Foundation
import CryptoKit
import SwiftData
import UserNotifications
import ChargeCheckCore

/// The till's sales, cash, stock counts, batches, customers and staff hours.
///
/// Several tills: every device is a till with a letter (A, B…) and writes only its own files
/// ("Sales 2026-11 ~B.json", "Cash ~B.json"…) in Files › ChargeCheck › Till, copied to iCloud after every change.
/// The other tills read them every half minute while the till is open, so stock, customers and gift cards are the
/// same on every till, and one till can never overwrite another's sales. Files from before tills had letters are
/// read and kept as they are. Each till has its own cash drawer, float and end of day.
@MainActor
final class TillStore: ObservableObject {
    static let shared = TillStore()
    static let countsKey = "till.counts.v1"
    static let numberKey = "till.number"
    static let alertedKey = "till.lowAlerted"
    static let codeKey = "till.code"
    static let mainKey = "till.extra"
    static let productsKey = "till.productsApplied"
    static let folder = "Till/Sales"
    static let tillFolder = "Till"

    @Published private(set) var sales: [Sale] = []
    @Published private(set) var counts: [StockCount] = []
    @Published private(set) var cash: [CashEvent] = []
    @Published private(set) var days: [DayReport] = []
    @Published private(set) var cashiers: [Cashier] = []
    @Published private(set) var parked: [ParkedSale] = []
    @Published private(set) var batches: [StockBatch] = []
    @Published private(set) var customers: [Customer] = []
    @Published private(set) var clock: [ClockEvent] = []
    @Published private(set) var layaways: [Layaway] = []
    /// Training: sales, refunds and cash aren't saved, and stock doesn't change (new staff practise on the real till).
    @Published var training = UserDefaults.standard.bool(forKey: "till.training") {
        didSet { UserDefaults.standard.set(training, forKey: "till.training") }
    }
    @Published var receipt = ReceiptSettings()
    @Published var options = TillOptions()
    /// Who's serving now (nil: nobody signed in, or the till has no cashiers).
    @Published var cashier: Cashier?
    /// Every till seen in the files (this one included).
    @Published private(set) var tills: Set<String> = []
    @Published private(set) var lastSync: Date?

    /// This till's letter.
    private(set) var code: String
    private var ownCounts: [StockCount] = []
    private var ownBatches: [StockBatch] = []
    private var ownCustomers: [Customer] = []
    private var ownClock: [ClockEvent] = []
    private var ownLayaways: [Layaway] = []
    private var settingsUpdated = ""

    /// Another iPhone or iPad uses this till's letter too (found when the tills compare notes).
    @Published private(set) var clash = false

    private init() {
        code = UserDefaults.standard.string(forKey: Self.codeKey) ?? ""
        load()
        loadExtras()
        if !code.isEmpty { tills.insert(code) }
    }

    /// This device, for telling two tills with the same letter apart.
    private static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "till.device") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "till.device")
        return id
    }

    /// Gives this till its letter the first time it's needed: after looking at the other tills' files, so a new
    /// iPhone doesn't take a letter that's already used.
    func ensureCode() {
        guard code.isEmpty else { return }
        code = TillSync.nextCode(taken: tills)
        UserDefaults.standard.set(code, forKey: Self.codeKey)
        tills.insert(code)
        writeIdentity()
    }

    private func writeIdentity() {
        save(TillIdentity(device: Self.deviceID, at: Self.now()), name: own("Till"))
    }

    /// Nothing has been saved under this till's letter yet.
    var canRename: Bool {
        !sales.contains { $0.till == code } && !cash.contains { $0.till == code } && !days.contains { $0.till == code }
            && ownCounts.isEmpty && ownBatches.isEmpty && ownCustomers.isEmpty && ownClock.isEmpty && ownLayaways.isEmpty
    }

    /// More than one till sells: receipts show the till's letter, and each drawer has its own end of day.
    var severalTills: Bool { tills.count > 1 }

    /// An extra till gets its products from the main iPhone (it doesn't keep its own price list).
    var isExtraTill: Bool {
        get { UserDefaults.standard.bool(forKey: Self.mainKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.mainKey)
            objectWillChange.send()
        }
    }

    /// Renames this till (its letter): only before anything is saved under it, so nothing is left behind.
    func rename(_ new: String) -> Bool {
        let clean = new.uppercased().filter { ($0.isLetter && $0.isASCII) || $0.isNumber }
        guard !clean.isEmpty, clean.count <= 3, !tills.contains(clean) || clean == code, canRename else { return false }
        tills.remove(code)
        code = clean
        tills.insert(code)
        UserDefaults.standard.set(code, forKey: Self.codeKey)
        clash = false
        writeIdentity()
        return true
    }

    private func own(_ base: String) -> String { TillSync.fileName(base, till: code) }

    // MARK: files

    private static var salesDirectory: URL? { AppFiles.documents?.appendingPathComponent(folder, isDirectory: true) }
    private static var tillDirectory: URL? { AppFiles.documents?.appendingPathComponent(tillFolder, isDirectory: true) }

    private func load() {
        guard let directory = Self.salesDirectory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        var lists: [[Sale]] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
               let month = try? JSONDecoder().decode([Sale].self, from: data) {
                lists.append(month)
                if let till = TillSync.till(ofFile: name) { tills.insert(till) }
            }
        }
        sales = TillSync.merge(lists)
    }

    /// Every file of a kind in the Till folder: "Cash.json" (from before tills had letters) and "Cash ~A.json"…
    private func group<T: Decodable>(_ base: String, as: T.Type) -> [(till: String?, value: T)] {
        guard let directory = Self.tillDirectory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().compactMap { name -> (till: String?, value: T)? in
            guard name == base + ".json" || name.hasPrefix(base + " ~"), name.hasSuffix(".json"),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let value = try? JSONDecoder().decode(T.self, from: data) else { return nil }
            return (TillSync.till(ofFile: name), value)
        }
    }

    private func loadExtras() {
        let cashFiles = group("Cash", as: [CashEvent].self)
        cash = TillSync.mergeIDs(cashFiles.map { $0.value })
        days = TillSync.mergeIDs(group("Days", as: [DayReport].self).map { $0.value })
        let countFiles = group("Counts", as: [StockCount].self)
        ownCounts = countFiles.first { $0.till == code && !code.isEmpty }?.value ?? []
        var countLists = countFiles.map { $0.value }
        if let data = UserDefaults.standard.data(forKey: Self.countsKey), let saved = try? JSONDecoder().decode([StockCount].self, from: data) {
            countLists.append(saved)
        }
        counts = TillSync.mergeCounts(countLists)
        let batchFiles = group("Batches", as: [StockBatch].self)
        ownBatches = batchFiles.first { $0.till == code && !code.isEmpty }?.value ?? []
        batches = TillSync.mergeIDs(batchFiles.map { $0.value })
        let customerFiles = group("Customers", as: [Customer].self)
        ownCustomers = customerFiles.first { $0.till == code && !code.isEmpty }?.value ?? []
        customers = Self.latest(customerFiles.map { $0.value })
        let layawayFiles = group("Layaways", as: [Layaway].self)
        ownLayaways = layawayFiles.first { $0.till == code && !code.isEmpty }?.value ?? []
        layaways = Layaways.merge(layawayFiles.map { $0.value })
        let clockFiles = group("Clock", as: [ClockEvent].self)
        ownClock = clockFiles.first { $0.till == code && !code.isEmpty }?.value ?? []
        clock = TillSync.mergeIDs(clockFiles.map { $0.value })
        var seen: [String?] = cashFiles.map { $0.till } + countFiles.map { $0.till } + batchFiles.map { $0.till }
        seen += customerFiles.map { $0.till } + clockFiles.map { $0.till }
        seen += group("Till", as: TillIdentity.self).map { $0.till }
        for till in seen.compactMap({ $0 }) { tills.insert(till) }
        if let settings = group("Settings", as: TillSettingsFile.self).first(where: { $0.till == nil })?.value {
            cashiers = settings.cashiers
            receipt = settings.receipt
            options = settings.options ?? TillOptions()
            settingsUpdated = settings.updated ?? ""
        }
        if let data = UserDefaults.standard.data(forKey: "till.parked"), let list = try? JSONDecoder().decode([ParkedSale].self, from: data) {
            parked = list
        }
    }

    /// The same customer edited on two tills: the latest edit wins.
    private static func latest(_ lists: [[Customer]]) -> [Customer] {
        var best: [String: Customer] = [:]
        for list in lists {
            for customer in list where (best[customer.id]?.at ?? "") <= customer.at { best[customer.id] = customer }
        }
        return best.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func save<T: Encodable>(_ value: T, name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        AppFiles.write(data, folder: Self.tillFolder, name: name)
        if CloudFolder.isOn {
            DispatchQueue.global(qos: .utility).async { CloudFolder.write(data, folder: TillStore.tillFolder, name: name) }
        }
    }

    /// Writes this till's sales of that month, on the phone, then to iCloud in the background.
    private func store(month iso: String) {
        let prefix = String(iso.prefix(7))
        let list = sales.filter { $0.at.hasPrefix(prefix) && $0.till == code }.sorted { $0.at < $1.at }
        guard let data = try? JSONEncoder().encode(list) else { return }
        let name = own("Sales " + prefix)
        AppFiles.write(data, folder: Self.folder, name: name)
        if CloudFolder.isOn {
            DispatchQueue.global(qos: .utility).async { CloudFolder.write(data, folder: Self.folder, name: name) }
        }
    }

    // MARK: keeping the tills in step

    /// Reads the other tills' files from iCloud (this month's and last month's sales; `full`: every month), and on an
    /// extra till the products from the main iPhone. The main iPhone puts its products there for them.
    private var syncing = false

    func sync(context: ModelContext, full: Bool = false) async {
        guard CloudFolder.isOn, !syncing else { return }
        syncing = true
        defer { syncing = false }
        let me = code
        let months: [String]? = full ? nil : {
            let now = Date()
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM"
            return [f.string(from: now), f.string(from: now.addingTimeInterval(-32 * 86_400))]
        }()
        if !isExtraTill { publishProducts(context) }
        let before = Set(sales.map(\.id))
        let (salesFiles, tillFiles) = await Task.detached(priority: .utility) { () -> ([(name: String, data: Data)], [(name: String, data: Data)]) in
            let s = CloudFolder.readAll(folder: TillStore.folder) { name in
                TillSync.till(ofFile: name) != me && (months.map { list in list.contains { name.hasPrefix("Sales " + $0) } } ?? true)
            }
            let t = CloudFolder.readAll(folder: TillStore.tillFolder) { name in TillSync.till(ofFile: name) != me || name == "Till ~" + me + ".json" }
            return (s, t)
        }.value
        if !me.isEmpty, let mine = tillFiles.first(where: { $0.name == "Till ~" + me + ".json" }),
           let identity = try? JSONDecoder().decode(TillIdentity.self, from: mine.data) {
            clash = identity.device != Self.deviceID
        }
        // only what's new: reading every month again every half minute would freeze a till with a long history
        var changed = false
        for file in salesFiles where Self.differs(file.data, folder: Self.folder, name: file.name) {
            AppFiles.write(file.data, folder: Self.folder, name: file.name)
            changed = true
        }
        for file in tillFiles where !(file.name == "Till ~" + me + ".json") {
            if file.name != "Products.json" && !Self.differs(file.data, folder: Self.tillFolder, name: file.name) { continue }
            if file.name == "Settings.json" {
                // the newer settings win
                guard let theirs = try? JSONDecoder().decode(TillSettingsFile.self, from: file.data), (theirs.updated ?? "") > settingsUpdated else { continue }
            }
            if file.name == "Products.json" {
                if isExtraTill { applyProducts(file.data, context: context) }
                continue
            }
            AppFiles.write(file.data, folder: Self.tillFolder, name: file.name)
            changed = true
        }
        if changed {
            load()
            loadExtras()
        }
        ensureCode()
        lastSync = Date()
        // the main iPhone drafts the orders for what the other tills sold
        if !isExtraTill {
            let fresh = sales.filter { !before.contains($0.id) && $0.till != code }
            for shop in Set(fresh.map(\.shop)) {
                checkLowStock(shop: shop, items: fresh.filter { $0.shop == shop }.flatMap { $0.lines.compactMap(\.itemID) }, context: context)
            }
        }
    }

    /// The copy on this device isn't the same as this one from iCloud.
    private static func differs(_ data: Data, folder: String, name: String) -> Bool {
        guard let url = AppFiles.documents?.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name),
              let local = try? Data(contentsOf: url) else { return true }
        return local != data
    }

    /// The main iPhone's price list, for the extra tills (only when it changed).
    private func publishProducts(_ context: ModelContext) {
        let items = AppData.items(context)
        guard !items.isEmpty, let data = try? JSONEncoder().encode(items) else { return }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard UserDefaults.standard.string(forKey: "till.productsPublished") != hash else { return }
        UserDefaults.standard.set(hash, forKey: "till.productsPublished")
        if CloudFolder.isOn {
            DispatchQueue.global(qos: .utility).async { CloudFolder.write(data, folder: TillStore.tillFolder, name: "Products.json") }
        }
    }

    private func applyProducts(_ data: Data, context: ModelContext) {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard UserDefaults.standard.string(forKey: Self.productsKey) != hash,
              let items = try? JSONDecoder().decode([PriceItem].self, from: data), !items.isEmpty else { return }
        for item in items { AppData.save(item, in: context, logged: false) }
        try? context.save()
        UserDefaults.standard.set(hash, forKey: Self.productsKey)
    }

    // MARK: sales

    var nextNumber: Int { UserDefaults.standard.integer(forKey: Self.numberKey) + 1 }

    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    @discardableResult
    func record(lines: [SaleLine], shop: String, payment: PaymentKind, tendered: Double?, split: [SalePayment]? = nil,
                customer: String? = nil, approvedBy: String? = nil, voucher: String? = nil, context: ModelContext) -> Sale {
        if training {
            // practice: nothing is saved, nothing comes off stock, no receipt number is used
            var practice = Sale(number: 0, shop: shop, at: Self.now(), lines: lines, payment: payment, tendered: tendered,
                                cashier: cashier?.name, split: split, till: "T", customer: customer, approvedBy: approvedBy)
            practice.voucher = voucher
            return practice
        }
        ensureCode()
        let number = nextNumber
        UserDefaults.standard.set(number, forKey: Self.numberKey)
        let sale = Sale(number: number, shop: shop, at: Self.now(), lines: lines, payment: payment, tendered: tendered,
                        cashier: cashier?.name, split: split, till: code, customer: customer, approvedBy: approvedBy)
        var recorded = sale
        recorded.voucher = voucher
        return keep(recorded, shop: shop, lines: lines, approvedBy: approvedBy, context: context)
    }

    private func keep(_ sale: Sale, shop: String, lines: [SaleLine], approvedBy: String?, context: ModelContext) -> Sale {
        sales.insert(sale, at: 0)
        store(month: sale.at)
        TillTab.firstUse()
        if !isExtraTill { checkLowStock(shop: shop, items: lines.compactMap(\.itemID), context: context) }
        if let approvedBy { Records.shared.log(.tillApproved, String(localized: "Sale #\(sale.receiptNumber) · \(approvedBy)"), amount: sale.total) }
        return sale
    }

    /// Refunds what's given (line id → how many), or everything still refundable.
    /// `toCredit`: the money goes on the customer's account as store credit instead of back to them.
    func refund(_ sale: Sale, quantities: [String: Double]? = nil, approvedBy: String? = nil, toCredit: Bool = false,
                context: ModelContext) -> Sale? {
        guard sale.refundOf == nil, !training else { return nil }
        // the store decides, not the screen: the person signed in may, or a manager has just said yes
        guard let allowed = authorize(.refund) else { return nil }
        let approvedBy = allowed.by
        let left = SaleMaths.refundable(sale, refunds: sales.filter { $0.refundOf == sale.id })
        let wanted = (quantities ?? left).compactMapValues { qty -> Double? in qty > 0 ? qty : nil }
            .reduce(into: [String: Double]()) { out, pair in out[pair.key] = min(pair.value, left[pair.key] ?? 0) }
            .filter { $0.value > 0 }
        guard !wanted.isEmpty else { return nil }
        ensureCode()
        let number = nextNumber
        UserDefaults.standard.set(number, forKey: Self.numberKey)
        var refund = SaleMaths.refund(of: sale, quantities: wanted, number: number, at: Self.now(), cashier: cashier?.name)
        refund.till = code
        refund.approvedBy = approvedBy
        if toCredit, let customer = sale.customer {
            refund.payment = .tab
            refund.split = [SalePayment(kind: .tab, amount: refund.total, ref: customer)]
        }
        sales.insert(refund, at: 0)
        store(month: refund.at)
        Records.shared.log(.tillRefund, String(localized: "Refund #\(refund.receiptNumber) of sale #\(sale.receiptNumber)")
                           + (approvedBy.map { " · " + $0 } ?? ""), amount: refund.total)
        return refund
    }

    /// Everything on it has been refunded.
    func isRefunded(_ sale: Sale) -> Bool {
        sales.contains { $0.refundOf == sale.id } && SaleMaths.refundable(sale, refunds: sales.filter { $0.refundOf == sale.id }).isEmpty
    }

    func refundable(_ sale: Sale) -> [String: Double] {
        SaleMaths.refundable(sale, refunds: sales.filter { $0.refundOf == sale.id })
    }

    /// The receipt number as people see it: with the till's letter when there's more than one till.
    func number(_ sale: Sale) -> String { severalTills ? sale.receiptNumber : "\(sale.number)" }

    // MARK: cash, end of day (this till's drawer)

    func addCash(_ kind: CashEvent.Kind, amount: Double, note: String, shop: String, ref: String? = nil, card: Bool? = nil,
                 approvedBy: String? = nil) {
        guard !training else { return }
        var approvedBy = approvedBy
        if let needed = kind.permission {
            guard let allowed = authorize(needed) else { return }
            approvedBy = allowed.by
        }
        ensureCode()
        cash.append(CashEvent(shop: shop, at: Self.now(), kind: kind, amount: Money.round2(amount), note: note, cashier: cashier?.name,
                              till: code, ref: ref, card: card, approvedBy: approvedBy))
        save(cash.filter { $0.till == code }, name: own("Cash"))
        switch kind {
        case .noSale: Records.shared.log(.drawerOpened, note.isEmpty ? (cashier?.name ?? "") : note)
        case .tabPaid: Records.shared.log(.cashMoved, note, amount: amount)
        default: Records.shared.log(.cashMoved, note.isEmpty ? kind.rawValue : note, amount: kind == .paidOut ? -amount : amount)
        }
        if let approvedBy { Records.shared.log(.tillApproved, kind.rawValue + " · " + approvedBy, amount: amount) }
    }

    private func myDay(_ day: DayReport) -> Bool { day.till == code || (day.till == nil && code == "A") || (day.till == nil && !severalTills) }

    /// When this till's last Z report of the shop ended ("" = never).
    func lastClose(_ shop: String) -> String { days.filter { $0.shop == shop && myDay($0) }.map(\.to).max() ?? "" }

    var nextZ: Int { (days.filter(myDay).map(\.number).max() ?? 0) + 1 }

    /// The X report: so far since the last close.
    func current(shop: String) -> DayReport {
        var report = CashDay.report(shop: shop, since: lastClose(shop), to: Self.now(), sales: sales, events: cash, number: nextZ,
                                    till: severalTills ? code : nil)
        report.till = code
        return report
    }

    /// The Z report: closes the day. Starts a new day from now.
    @discardableResult
    /// nil: the person signed in may not close the day and no manager has said yes.
    func closeDay(shop: String, counted: Double?, approvedBy: String? = nil) -> DayReport? {
        guard !training else { return current(shop: shop) }
        guard let allowed = authorize(.closeDay) else { return nil }
        let approvedBy = allowed.by
        ensureCode()
        var report = current(shop: shop)
        report.counted = counted.map { Money.round2($0) }
        report.closedBy = [cashier?.name, approvedBy].compactMap { $0 }.joined(separator: " · ")
        days.append(report)
        save(days.filter { $0.till == code }, name: own("Days"))
        Records.shared.log(.tillClosed, "Z\(report.number)" + (report.difference.map { " · " + Money.format($0) } ?? ""), amount: report.takings)
        return report
    }

    // MARK: cashiers and what they may do

    func saveSettings() {
        settingsUpdated = Self.now()
        save(TillSettingsFile(cashiers: cashiers, receipt: receipt, options: options, updated: settingsUpdated), name: "Settings.json")
    }

    /// Adds a person. false if the PIN isn't 4–8 digits, is already someone's, or couldn't be stored safely.
    @discardableResult
    func addCashier(name: String, pin: String, role: TillRole) -> Bool {
        guard PinCredentials.isValid(pin), !pinInUse(pin), let credential = TillPins.make(pin) else { return false }
        cashiers.append(Cashier(id: UUID().uuidString, name: name, pinHash: "", role: role, pin: credential))
        saveSettings()
        return true
    }

    /// Gives someone a new PIN (the owner or a manager resets a forgotten one). The old one stops working at once.
    @discardableResult
    func resetPin(for id: String, to pin: String) -> Bool {
        guard let index = cashiers.firstIndex(where: { $0.id == id }), PinCredentials.isValid(pin),
              !pinInUse(pin, except: id), let credential = TillPins.make(pin) else { return false }
        cashiers[index].pin = credential
        cashiers[index].pinHash = ""
        if cashier?.id == id { cashier = cashiers[index] }
        saveSettings()
        return true
    }

    /// Whether this PIN already belongs to someone (each person's PIN must be their own).
    func pinInUse(_ pin: String, except id: String? = nil) -> Bool {
        cashiers.contains { $0.id != id && TillPins.check(pin, $0) != .no }
    }

    /// The person whose PIN this is. A PIN saved by an older version is upgraded to the salted kind on the spot.
    private func person(withPin pin: String, where allowed: (Cashier) -> Bool = { _ in true }) -> Cashier? {
        for index in cashiers.indices where allowed(cashiers[index]) {
            guard case let .yes(upgrade) = TillPins.check(pin, cashiers[index]) else { continue }
            if let upgrade {
                cashiers[index].pin = upgrade
                cashiers[index].pinHash = ""
                saveSettings()
            }
            return cashiers[index]
        }
        return nil
    }

    func setRole(_ role: TillRole, for id: String) {
        guard let index = cashiers.firstIndex(where: { $0.id == id }) else { return }
        cashiers[index].role = role
        if cashier?.id == id { cashier = cashiers[index] }
        saveSettings()
    }

    func removeCashier(_ id: String) {
        cashiers.removeAll { $0.id == id }
        if cashier?.id == id { cashier = nil }
        saveSettings()
    }

    var hasManagers: Bool { cashiers.contains { ($0.role ?? .cashier).isManager } }

    /// The person serving may do this without a manager.
    // MARK: who may do what – checked here, so no screen can skip it

    private var approvals = TillApprovals()
    /// Wrong manager PINs in a row; the PIN pad waits after too many.
    @Published private(set) var pinLockout = PinLockout()

    /// A manager's PIN for these actions. Gives a single-use yes for each (for two minutes), or nil: wrong PIN, or the
    /// pad is waiting after too many wrong ones.
    func approve(_ permissions: [TillPermission], pin: String) -> Cashier? {
        let now = Date()
        guard pinLockout.wait(at: now) == 0 else { return nil }
        guard let manager = manager(pin: pin) else {
            pinLockout.wrong(at: now)
            return nil
        }
        pinLockout.right()
        approvals.give(permissions, by: manager.name, at: now)
        return manager
    }

    /// The owner unlocked with this iPhone's Face ID or passcode (checked by iOS before this is called).
    func approveAsDeviceOwner(_ permissions: [TillPermission]) {
        approvals.give(permissions, by: String(localized: "Owner"), at: Date())
    }

    /// Whether this action may go ahead now: `by` is the manager who said yes (nil: the person signed in may do it).
    /// nil means no. A yes is used up.
    func authorize(_ permission: TillPermission) -> Allowed? {
        if may(permission) { return Allowed(by: nil) }
        guard let by = approvals.use(permission, at: Date()) else { return nil }
        return Allowed(by: by)
    }

    struct Allowed {
        /// The manager who said yes; nil when the person signed in may do it themselves.
        let by: String?
    }

    func may(_ permission: TillPermission) -> Bool {
        TillRoles.allows(cashier.map { $0.role ?? .cashier }, permission, cashierCan: options.cashierPermissions, hasManagers: hasManagers)
    }

    /// Signs in the cashier whose PIN this is.
    func signIn(pin: String) -> Bool {
        guard let found = person(withPin: pin) else { return false }
        cashier = found
        return true
    }

    /// A manager's (or the owner's) PIN, to allow one thing.
    func manager(pin: String) -> Cashier? {
        person(withPin: pin) { ($0.role ?? .cashier).isManager }
    }

    // MARK: clocking in and out

    func isClockedIn(_ person: String) -> Bool {
        clock.filter { $0.person == person }.max { $0.at < $1.at }?.start == true
    }

    func punch(_ person: String, shop: String, start: Bool) {
        ensureCode()
        let event = ClockEvent(person: person, shop: shop, at: Self.now(), start: start, till: code)
        ownClock.append(event)
        clock.append(event)
        save(ownClock, name: own("Clock"))
        Records.shared.log(start ? .clockedIn : .clockedOut, person)
    }

    // MARK: parked sales

    func park(_ lines: [SaleLine], shop: String, name: String, customer: String? = nil) {
        parked.append(ParkedSale(id: UUID().uuidString, name: name, at: Self.now(), shop: shop, lines: lines, customer: customer))
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

    // MARK: customers and gift cards

    func saveCustomer(_ customer: Customer) {
        ensureCode()
        var changed = customer
        changed.at = Self.now()
        ownCustomers.removeAll { $0.id == changed.id }
        ownCustomers.append(changed)
        customers.removeAll { $0.id == changed.id }
        customers.append(changed)
        customers.sort { $0.name.lowercased() < $1.name.lowercased() }
        save(ownCustomers, name: own("Customers"))
    }

    func customer(_ id: String?) -> Customer? { id.flatMap { id in customers.first { $0.id == id } } }

    func balance(_ customer: Customer) -> CustomerBalance {
        CustomerMaths.balance(customer.id, sales: sales, events: cash, loyalty: options.loyalty)
    }

    var giftCards: [GiftCard] { GiftCards.sold(in: sales) }

    func giftCard(_ code: String) -> GiftCard? {
        let clean = code.filter(\.isNumber)
        return giftCards.first { $0.code == clean }
    }

    func newGiftCode() -> String { GiftCards.newCode(taken: Set(giftCards.map(\.code))) }

    // MARK: layaways

    private func storeLayaway(_ layaway: Layaway) {
        var changed = layaway
        changed.updated = Self.now()
        ownLayaways.removeAll { $0.id == changed.id }
        ownLayaways.append(changed)
        layaways.removeAll { $0.id == changed.id }
        layaways.insert(changed, at: 0)
        save(ownLayaways, name: own("Layaways"))
    }

    /// Keeps the basket for a customer, with a first deposit (cash into this drawer, or card).
    @discardableResult
    func startLayaway(lines: [SaleLine], shop: String, customer: String, deposit: Double, card: Bool) -> Layaway? {
        guard !training, !lines.isEmpty else { return nil }
        ensureCode()
        let layaway = Layaway(shop: shop, customer: customer, lines: lines, at: Self.now(), updated: Self.now(), till: code)
        storeLayaway(layaway)
        if deposit > 0 { pay(layaway, amount: deposit, card: card) }
        return layaway
    }

    func pay(_ layaway: Layaway, amount: Double, card: Bool) {
        let name = customer(layaway.customer)?.name ?? ""
        addCash(.deposit, amount: amount, note: name, shop: layaway.shop, ref: layaway.id, card: card ? true : nil)
    }

    func paid(_ layaway: Layaway) -> Double { Layaways.paid(layaway.id, events: cash) }

    /// They take the goods: the sale happens now (stock, takings), paid by the deposits plus the rest.
    func collect(_ layaway: Layaway, rest: PaymentKind, context: ModelContext) -> Sale? {
        guard layaway.status == .open, !training else { return nil }
        let deposits = paid(layaway)
        let left = Money.round2(max(0, layaway.total - deposits))
        var parts = [SalePayment(kind: .layaway, amount: min(deposits, layaway.total), ref: layaway.id)]
        if left > 0 { parts.append(SalePayment(kind: rest, amount: left)) }
        let sale = record(lines: layaway.lines, shop: layaway.shop, payment: left > 0 ? rest : .layaway, tendered: nil,
                          split: parts, customer: layaway.customer, context: context)
        var done = layaway
        done.status = .collected
        done.sale = sale.id
        storeLayaway(done)
        return sale
    }

    /// Cancelled: the deposits go back (cash from this drawer, or card).
    func cancel(_ layaway: Layaway, card: Bool, approvedBy: String?) {
        guard layaway.status == .open, !training else { return }
        guard let allowed = authorize(.refund) else { return }
        let approvedBy = allowed.by
        let back = paid(layaway)
        if back > 0 {
            addCash(.deposit, amount: -back, note: customer(layaway.customer)?.name ?? "", shop: layaway.shop, ref: layaway.id,
                    card: card ? true : nil, approvedBy: approvedBy)
        }
        var done = layaway
        done.status = .cancelled
        storeLayaway(done)
    }

    // MARK: moving stock between shops

    /// Takes units off one shop's stock and adds them to another's (both counts are updated and it's logged).
    func move(_ units: Double, of item: PriceItem, from: String, to: String, invoices: [HistoryEntry]) {
        guard units > 0, from != to, !training else { return }
        let here = StockMaths.levels(items: [item], shop: from, invoices: invoices, sales: sales, counts: counts).first
        let there = StockMaths.levels(items: [item], shop: to, invoices: invoices, sales: sales, counts: counts).first
        setCount(max(0, (here?.onHand ?? 0) - units), itemID: item.id, name: item.name + " → " + Shops.reportName(to), shop: from)
        setCount((there?.onHand ?? 0) + units, itemID: item.id, name: item.name + " ← " + Shops.reportName(from), shop: to)
    }

    // MARK: batches and expiry dates

    func addBatch(itemID: String, name: String, shop: String, code batchCode: String, expiry: String, qty: Double) {
        ensureCode()
        let batch = StockBatch(itemID: itemID, shop: shop, code: batchCode, expiry: expiry, qty: qty, at: Self.now(), till: code)
        ownBatches.append(batch)
        batches.append(batch)
        save(ownBatches, name: own("Batches"))
        Records.shared.log(.stockCounted, name + " · " + String(localized: "batch \(batchCode), use by \(expiry)"))
    }

    /// Takes a batch away (entered by mistake): only one this till added.
    func removeBatch(_ id: String) -> Bool {
        guard ownBatches.contains(where: { $0.id == id }) else { return false }
        ownBatches.removeAll { $0.id == id }
        batches.removeAll { $0.id == id }
        save(ownBatches, name: own("Batches"))
        return true
    }

    static var today: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// What's left of each batch of an item on the shelf, shortest-dated first.
    func shelf(of item: PriceItem, shop: String, onHand: Double) -> [BatchOnShelf] {
        BatchMaths.onShelf(batches.filter { $0.itemID == item.id && $0.shop == shop }, onHand: onHand, today: Self.today)
    }

    // MARK: stock

    /// Stock that came in without a checked invoice (bought at a cash and carry, moved from another shop):
    /// the count becomes what's there now plus this.
    func addStock(_ units: Double, level: StockLevel, shop: String) {
        setCount(level.onHand + units, itemID: level.itemID, name: level.name + " (+\(units.formatted()))", shop: shop)
    }

    func setCount(_ count: Double, itemID: String, name: String, shop: String) {
        ensureCode()
        Records.shared.log(.stockCounted, name + " · \(count.formatted())")
        let entry = StockCount(itemID: itemID, shop: shop, count: count, at: Self.now())
        ownCounts.removeAll { $0.itemID == itemID && $0.shop == shop }
        ownCounts.append(entry)
        counts.removeAll { $0.itemID == itemID && $0.shop == shop }
        counts.append(entry)
        storeCounts()
        alerted.remove(shop + "|" + itemID)
    }

    private func storeCounts() {
        save(ownCounts, name: own("Counts"))
        // kept as before too, for the backup
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
        guard !ids.isEmpty else { return }
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
        counts = TillSync.mergeCounts([counts, list])
        if let data = try? JSONEncoder().encode(counts) { UserDefaults.standard.set(data, forKey: Self.countsKey) }
    }

    /// A new phone: every till's files from iCloud (after restoring the backup).
    func pullFromCloud() async {
        let files = await Task.detached(priority: .utility) { CloudFolder.readAll(folder: TillStore.folder) }.value
        let extras = await Task.detached(priority: .utility) { CloudFolder.readAll(folder: TillStore.tillFolder) }.value
        for file in files { AppFiles.write(file.data, folder: Self.folder, name: file.name) }
        for file in extras where file.name != "Products.json" { AppFiles.write(file.data, folder: Self.tillFolder, name: file.name) }
        load()
        loadExtras()
        ensureCode()
    }
}

/// "Till ~A.json": which device is till A.
struct TillIdentity: Codable {
    var device: String
    var at: String
}

struct Cashier: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// Before 21 Nov 2026: an unsalted fingerprint of the PIN. Emptied once `pin` is set (on the next sign-in).
    var pinHash: String
    /// nil: a cashier (people added before roles).
    var role: TillRole?
    /// The PIN as a slow, salted fingerprint (never the PIN itself). nil: only the old fingerprint exists.
    var pin: PinCredential?
}

struct ParkedSale: Codable, Identifiable {
    var id: String
    var name: String
    var at: String
    var shop: String
    var lines: [SaleLine]
    var customer: String?
}

/// What's printed on every receipt.
struct ReceiptSettings: Codable, Equatable {
    var header = ""
    var footer = ""
    var vatNumber = ""
    /// Ask "Receipt?" after a sale (off: straight to the next sale, the receipt is still in Sales).
    var askForReceipt = true
}

/// Shared by every till: what cashiers may do, meal deals, points, scale labels, expiry warnings.
struct TillOptions: Codable, Equatable {
    var cashierCan: [String] = TillPermission.cashierDefault.map(\.rawValue).sorted()
    var deals: [MealDeal] = []
    var loyalty = LoyaltySettings()
    var loyaltyOn = false
    var scaleCarries: ScaleLabelValue = .price
    /// Warn about batches this many days before they expire.
    var expiryDays = 30
    var vouchers: [Voucher] = []

    var cashierPermissions: Set<TillPermission> { Set(cashierCan.compactMap(TillPermission.init(rawValue:))) }

    init() {}

    enum CodingKeys: String, CodingKey { case cashierCan, deals, loyalty, loyaltyOn, scaleCarries, expiryDays, vouchers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cashierCan = (try? c.decode([String].self, forKey: .cashierCan)) ?? TillPermission.cashierDefault.map(\.rawValue).sorted()
        deals = (try? c.decode([MealDeal].self, forKey: .deals)) ?? []
        loyalty = (try? c.decode(LoyaltySettings.self, forKey: .loyalty)) ?? LoyaltySettings()
        loyaltyOn = (try? c.decode(Bool.self, forKey: .loyaltyOn)) ?? false
        scaleCarries = (try? c.decode(ScaleLabelValue.self, forKey: .scaleCarries)) ?? .price
        expiryDays = (try? c.decode(Int.self, forKey: .expiryDays)) ?? 30
        vouchers = (try? c.decode([Voucher].self, forKey: .vouchers)) ?? []
    }
}

struct TillSettingsFile: Codable {
    var cashiers: [Cashier]
    var receipt: ReceiptSettings
    var options: TillOptions?
    var updated: String?
}
