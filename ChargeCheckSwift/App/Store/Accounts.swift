import Foundation
import SwiftData
import UserNotifications
import WidgetKit
import UIKit
import ChargeCheckCore

/// Payments, credits and starting balances for each supplier, and the trusted-supplier list.
/// Kept in one small file on the phone (and in every backup).
@MainActor
final class Accounts: ObservableObject {
    static let shared = Accounts()
    static let trustedKey = "suppliers.trusted"
    nonisolated static let appGroup = Bundle.main.object(forInfoDictionaryKey: "CCAppGroup") as? String ?? "group.com.rjapps.invoicepricechecker"

    @Published private(set) var payments: [SupplierPayment] = []
    @Published private(set) var trusted: [String] = []
    /// Each supplier's credit period in days ("pay within 30 days"), keyed by SupplierAccounts.key. 0 = pay on delivery.
    @Published private(set) var creditDays: [String: Int] = [:]
    static let creditDaysKey = "suppliers.creditDays"
    /// Suppliers who invoice in another currency than the app's: SupplierAccounts.key → "USD".
    @Published private(set) var currencies: [String: String] = [:]
    static let currenciesKey = SupplierCurrency.key

    private init() {
        trusted = UserDefaults.standard.stringArray(forKey: Self.trustedKey) ?? []
        creditDays = (UserDefaults.standard.dictionary(forKey: Self.creditDaysKey) as? [String: Int]) ?? [:]
        currencies = (UserDefaults.standard.dictionary(forKey: Self.currenciesKey) as? [String: String]) ?? [:]
        if let url = Self.fileURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([SupplierPayment].self, from: data) {
            payments = saved
        }
    }

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("payments.json")
    }

    private func save() {
        if let url = Self.fileURL, let data = try? JSONEncoder().encode(payments) {
            try? data.write(to: url, options: .atomic)
        }
        UserDefaults.standard.set(trusted, forKey: Self.trustedKey)
    }

    // MARK: - reading

    /// The suppliers of the shop being viewed (every shop when "All shops" is chosen).
    func accounts(_ context: ModelContext) -> [SupplierAccount] {
        let all = AppData.entries(context)
        return SupplierAccounts.accounts(entries: inShop(all), payments: shopPayments(all), trusted: trusted)
    }

    // MARK: - the shop being viewed

    /// The shop every screen shows ("" = All shops). Reading it makes a screen redraw when it changes.
    var viewingShop: String { LiveSettings.shared.shop }

    /// The invoices of the shop being viewed.
    func inShop(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        ShopFilter.entries(entries, shop: viewingShop)
    }

    /// The payments, credits and starting balances of the shop being viewed. `allEntries` = every invoice.
    func shopPayments(_ allEntries: [HistoryEntry]) -> [SupplierPayment] {
        ShopFilter.payments(payments, allEntries: allEntries, shop: viewingShop)
    }

    /// Payments recorded before shops were kept apart: they only count under "All shops".
    func unassignedPayments(_ allEntries: [HistoryEntry]) -> Int {
        viewingShop.isEmpty ? 0 : ShopFilter.unassigned(payments, allEntries: allEntries).count
    }

    /// The supplier's credit period in days, or nil when none is set.
    func creditPeriod(_ supplier: String) -> Int? {
        creditDays[SupplierAccounts.key(supplier)]
    }

    func setCreditPeriod(_ supplier: String, _ days: Int?, context: ModelContext) {
        let key = SupplierAccounts.key(supplier)
        guard !key.isEmpty else { return }
        creditDays[key] = days
        UserDefaults.standard.set(creditDays, forKey: Self.creditDaysKey)
        changed(context)
        Records.shared.log(.supplierChanged, supplier + " · " + (days.map { String(localized: "pay within \($0) days") } ?? String(localized: "no due date")))
    }

    /// The currency this supplier invoices in (the app's own unless set).
    func currency(for supplier: String) -> Currency {
        guard let code = currencies[SupplierAccounts.key(supplier)], let found = Currency.all.first(where: { $0.code == code }) else {
            return Money.currency
        }
        return found
    }

    /// The supplier's currency code when it differs from the app's, otherwise nil.
    func otherCurrency(_ supplier: String) -> String? {
        let code = currency(for: supplier).code
        return code == Money.currency.code ? nil : code
    }

    func setCurrency(_ supplier: String, _ code: String?, context: ModelContext) {
        let key = SupplierAccounts.key(supplier)
        guard !key.isEmpty else { return }
        currencies[key] = (code == nil || code == Money.currency.code) ? nil : code
        UserDefaults.standard.set(currencies, forKey: Self.currenciesKey)
        changed(context)
        // every amount of this supplier is shown in the new currency straight away
        LiveSettings.shared.moneyChanged()
        Records.shared.log(.supplierChanged, supplier + " · " + currency(for: supplier).code)
    }

    /// Accounts of the suppliers who use the app's own currency (what the totals and the widget add up).
    func homeCurrencyAccounts(_ list: [SupplierAccount]) -> [SupplierAccount] {
        list.filter { otherCurrency($0.name) == nil }
    }

    /// Unpaid invoices of suppliers with a credit period, soonest due first.
    func due(_ context: ModelContext) -> [DueInvoice] {
        DueDates.open(accounts: accounts(context), creditDays: creditDays)
    }

    func isTrusted(_ supplier: String) -> Bool {
        SupplierAccounts.isTrusted(supplier, trusted: trusted)
    }

    // MARK: - changing

    func add(_ payment: SupplierPayment, context: ModelContext) {
        var payment = payment
        // a payment belongs to the shop being viewed (unless it pays ticked invoices: then it is theirs)
        if payment.shopId == nil, payment.invoiceIDs.isEmpty, !viewingShop.isEmpty { payment.shopId = viewingShop }
        if payment.currency == nil { payment.currency = currency(for: payment.supplier).code }
        payments.append(payment)
        save()
        changed(context)
        if payment.amount > 0.005 {
            Records.shared.log(payment.kind == .credit ? .creditReceived : .paymentRecorded, payment.supplier, amount: payment.amount)
        }
    }

    /// Puts back a payment from Recently deleted. A payment for ticked invoices marks them paid again.
    func restorePayment(_ payment: SupplierPayment, context: ModelContext) {
        guard !payments.contains(where: { $0.id == payment.id }) else { return }
        payments.append(payment)
        if !payment.invoiceIDs.isEmpty {
            let stamp = ISO8601DateFormatter().string(from: Date())
            AppData.updateReports(Set(payment.invoiceIDs), context: context) { if $0.paid == nil { $0.paid = stamp } }
        }
        save()
        changed(context)
    }

    /// A receipt photo goes when its payment leaves Recently deleted.
    func deleteReceiptFile(_ name: String) {
        guard !payments.contains(where: { $0.receipt == name }), let url = receiptURL(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - receipts

    private static var receiptsFolder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Receipts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Keeps a photo or screenshot of a payment receipt. Returns its file name.
    func saveReceipt(_ image: UIImage) -> String? {
        let name = UUID().uuidString + ".jpg"
        guard let folder = Self.receiptsFolder, let data = image.resizedForReceipt().jpegData(compressionQuality: 0.75),
              (try? data.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
        return name
    }

    func receiptURL(_ name: String) -> URL? {
        guard let url = Self.receiptsFolder?.appendingPathComponent(name), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func remove(_ id: String, context: ModelContext) {
        guard let payment = payments.first(where: { $0.id == id }) else { return }
        payments.removeAll { $0.id == id }
        // kept in Recently deleted for 30 days (with its receipt photo)
        Records.shared.binPayment(payment)
        // a payment for ticked invoices: those invoices are unpaid again
        if !payment.invoiceIDs.isEmpty {
            AppData.updateReports(Set(payment.invoiceIDs), context: context) { $0.paid = nil }
        }
        save()
        changed(context)
    }

    /// Removes payments for one supplier: all of them, or only those tied to the given invoices.
    func removePayments(supplier: String, onlyFor invoiceIDs: Set<String>? = nil, context: ModelContext) {
        let key = SupplierAccounts.key(supplier)
        let gone = payments.filter { payment in
            guard SupplierAccounts.key(payment.supplier) == key else { return false }
            guard let ids = invoiceIDs else { return true }
            return !payment.invoiceIDs.isEmpty && payment.invoiceIDs.allSatisfy { ids.contains($0) }
        }
        for payment in gone where payment.amount > 0.005 || payment.kind == .opening {
            Records.shared.binPayment(payment)
        }
        let goneIDs = Set(gone.map { $0.id })
        payments.removeAll { goneIDs.contains($0.id) }
        save()
        changed(context)
    }

    func setTrusted(_ supplier: String, _ on: Bool, context: ModelContext) {
        let key = SupplierAccounts.key(supplier)
        trusted.removeAll { SupplierAccounts.key($0) == key }
        if on { trusted.append(supplier.trimmingCharacters(in: .whitespaces)) }
        save()
        changed(context)
        Records.shared.log(.supplierChanged, supplier + " · " + (on ? String(localized: "trusted") : String(localized: "not trusted")))
    }

    /// Ticked invoices are paid: they're marked paid and one payment per supplier is recorded for them.
    func markPaid(_ entries: [HistoryEntry], date: Date = Date(), context: ModelContext) {
        let stamp = ISO8601DateFormatter().string(from: date)
        let day = SupplierAccounts.dayText(date)
        // one payment per supplier and shop, so each shop's payments stay its own
        var groups: [String: [HistoryEntry]] = [:]
        var names: [String: String] = [:]
        for entry in entries where entry.paid == nil {
            let key = SupplierAccounts.key(entry.supplier) + "\u{1F}" + entry.shopId
            groups[key, default: []].append(entry)
            names[key] = names[key] ?? entry.supplier
        }
        for (key, group) in groups {
            let name = names[key] ?? key
            payments.append(SupplierAccounts.payment(for: group, supplier: name, date: day, currency: currency(for: name).code))
        }
        AppData.updateReports(Set(groups.values.flatMap { $0.map { $0.id } }), context: context) { $0.paid = stamp }
        save()
        changed(context)
        for group in groups.values {
            for entry in group { Records.shared.log(.markedPaid, RecordKeeping.subject(entry), amount: entry.amountToPay.pay) }
        }
    }

    /// Files invoices under another shop ("" = no shop). Payments made for exactly those invoices go with them.
    func moveInvoices(_ ids: Set<String>, to shop: String, context: ModelContext) {
        guard !ids.isEmpty else { return }
        AppData.updateReports(ids, context: context) { $0.shopId = shop }
        for index in payments.indices where !payments[index].invoiceIDs.isEmpty && payments[index].invoiceIDs.allSatisfy({ ids.contains($0) }) {
            payments[index].shopId = shop.isEmpty ? nil : shop
        }
        save()
        changed(context)
        let name = Shops.name(shop) ?? String(localized: "no shop")
        Records.shared.log(.invoiceUpdated, ids.count == 1 ? String(localized: "1 invoice moved to \(name)")
                                                           : String(localized: "\(ids.count) invoices moved to \(name)"))
    }

    /// Undoes "mark as paid": the invoices are unpaid again and the payments recorded for them are taken back –
    /// exactly what was paid for them at the time. Each payment as it was goes to Recently deleted, so nothing is lost.
    func markUnpaid(_ ids: Set<String>, context: ModelContext) {
        let all = AppData.entries(context)
        let entries = all.filter { ids.contains($0.id) }
        let result = SupplierAccounts.undoPaid(ids, payments: payments, entries: all)
        for old in result.before { Records.shared.binPayment(old) }
        payments = result.payments
        AppData.updateReports(ids, context: context) { $0.paid = nil }
        save()
        changed(context)
        for entry in entries { Records.shared.log(.markedUnpaid, RecordKeeping.subject(entry), amount: entry.amountToPay.pay) }
    }

    /// From a backup.
    func restore(payments: [SupplierPayment]?, trusted: [String]?, creditDays: [String: Int]? = nil, currencies: [String: String]? = nil,
                 context: ModelContext) {
        if let currencies {
            self.currencies = currencies
            UserDefaults.standard.set(currencies, forKey: Self.currenciesKey)
        }
        self.payments = payments ?? []
        self.trusted = trusted ?? []
        if let creditDays {
            self.creditDays = creditDays
            UserDefaults.standard.set(creditDays, forKey: Self.creditDaysKey)
        }
        save()
        changed(context)
    }

    /// Anything changed: send it to staff phones and refresh the home screen widget.
    func changed(_ context: ModelContext) {
        widgetContext = context
        CloudTeam.shared.scheduleScan()
        refreshWidget()
    }

    private weak var widgetContext: ModelContext?

    /// The widget shows the shop being viewed (or all shops), in the app's currency. It is part of Pro.
    func refreshWidget() {
        guard PlanMirror.allows(.widget) else {
            WidgetData.write(WidgetSnapshot.locked(currency: Money.currency.code))
            return
        }
        guard let context = widgetContext else { return }
        WidgetData.write(WidgetSnapshot.make(homeCurrencyAccounts(accounts(context)), currency: Money.currency.code))
    }
}

/// Hands the widget what it shows, through the app group both can read.
enum WidgetData {
    static let fileName = "widget.json"

    static func write(_ snapshot: WidgetSnapshot) {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Accounts.appGroup),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// A reminder once a week, on the day you pay your suppliers.
enum WeeklyPayReminder {
    static let dayKey = "pay.weeklyDay"   // 0 = off, 1 = Sunday … 7 = Saturday
    private static let id = "chargecheck.weekly.pay"

    static func set(_ weekday: Int) async -> Bool {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard weekday > 0 else { return true }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Supplier payment day")
        content.body = String(localized: "Open ChargeCheck › Suppliers to see what you owe each supplier and record this week's payments.")
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 9, minute: 0, weekday: weekday), repeats: true)
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            return true
        } catch {
            return false
        }
    }
}

private extension UIImage {
    /// Receipts don't need full camera size: at most 1600 pixels on the long side.
    func resizedForReceipt() -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > 1600 else { return self }
        let scale = 1600 / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

enum SupplierCurrency {
    static let key = "suppliers.currencies"

    /// The supplier's currency code, if it was set (read straight from the settings, so it works anywhere).
    static func code(_ supplier: String) -> String? {
        guard !supplier.isEmpty, let map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return nil }
        return map[SupplierAccounts.key(supplier)]
    }
}

extension Money {
    /// An amount in the currency this supplier invoices in (the app's own unless set).
    static func format(_ value: Double, supplier: String) -> String {
        format(value, code: SupplierCurrency.code(supplier))
    }
}
