import Foundation
import SwiftData
import UserNotifications
import WidgetKit
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

    private init() {
        trusted = UserDefaults.standard.stringArray(forKey: Self.trustedKey) ?? []
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

    func accounts(_ context: ModelContext) -> [SupplierAccount] {
        SupplierAccounts.accounts(entries: AppData.entries(context), payments: payments, trusted: trusted)
    }

    func isTrusted(_ supplier: String) -> Bool {
        SupplierAccounts.isTrusted(supplier, trusted: trusted)
    }

    // MARK: - changing

    func add(_ payment: SupplierPayment, context: ModelContext) {
        payments.append(payment)
        save()
        changed(context)
    }

    func remove(_ id: String, context: ModelContext) {
        guard let payment = payments.first(where: { $0.id == id }) else { return }
        payments.removeAll { $0.id == id }
        // a payment for ticked invoices: those invoices are unpaid again
        if !payment.invoiceIDs.isEmpty {
            AppData.updateReports(Set(payment.invoiceIDs), context: context) { $0.paid = nil }
        }
        save()
        changed(context)
    }

    func setTrusted(_ supplier: String, _ on: Bool, context: ModelContext) {
        let key = SupplierAccounts.key(supplier)
        trusted.removeAll { SupplierAccounts.key($0) == key }
        if on { trusted.append(supplier.trimmingCharacters(in: .whitespaces)) }
        save()
        changed(context)
    }

    /// Ticked invoices are paid: they're marked paid and one payment per supplier is recorded for them.
    func markPaid(_ entries: [HistoryEntry], date: Date = Date(), context: ModelContext) {
        let stamp = ISO8601DateFormatter().string(from: date)
        let day = SupplierAccounts.dayText(date)
        var groups: [String: [HistoryEntry]] = [:]
        var names: [String: String] = [:]
        for entry in entries where entry.paid == nil {
            let key = SupplierAccounts.key(entry.supplier)
            groups[key, default: []].append(entry)
            names[key] = names[key] ?? entry.supplier
        }
        for (key, group) in groups {
            payments.append(SupplierAccounts.payment(for: group, supplier: names[key] ?? key, date: day))
        }
        AppData.updateReports(Set(groups.values.flatMap { $0.map { $0.id } }), context: context) { $0.paid = stamp }
        save()
        changed(context)
    }

    /// Undoes "mark as paid": the invoices are unpaid again and the payments recorded for them are taken back.
    func markUnpaid(_ ids: Set<String>, context: ModelContext) {
        let entries = AppData.entries(context).filter { ids.contains($0.id) }
        let amounts = Dictionary(entries.map { ($0.id, $0.amountToPay.pay) }, uniquingKeysWith: { first, _ in first })
        for index in payments.indices.reversed() where !payments[index].invoiceIDs.isEmpty {
            let gone = payments[index].invoiceIDs.filter { ids.contains($0) }
            if gone.isEmpty { continue }
            payments[index].invoiceIDs.removeAll { ids.contains($0) }
            payments[index].amount = Money.round2(payments[index].amount - gone.reduce(0) { $0 + (amounts[$1] ?? 0) })
            if payments[index].invoiceIDs.isEmpty || payments[index].amount <= 0.005 { payments.remove(at: index) }
        }
        AppData.updateReports(ids, context: context) { $0.paid = nil }
        save()
        changed(context)
    }

    /// From a backup.
    func restore(payments: [SupplierPayment]?, trusted: [String]?, context: ModelContext) {
        self.payments = payments ?? []
        self.trusted = trusted ?? []
        save()
        changed(context)
    }

    /// Anything changed: refresh the home screen widget.
    func changed(_ context: ModelContext) {
        WidgetData.write(WidgetSnapshot.make(accounts(context), currency: Money.currency.code))
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
