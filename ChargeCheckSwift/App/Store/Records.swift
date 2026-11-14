import Foundation
import SwiftData
import UIKit
import ChargeCheckCore

/// Recently deleted invoices, payments and prices (kept 30 days), and the history of changes.
/// Both live in small files on this iPhone.
@MainActor
final class Records: ObservableObject {
    static let shared = Records()

    @Published private(set) var bin: [BinItem] = []
    @Published private(set) var history: [ActivityEntry] = []

    private init() {
        bin = Self.read([BinItem].self, "bin.json") ?? []
        history = Self.read([ActivityEntry].self, "activity.json") ?? []
        prune()
    }

    // MARK: - files

    private static func url(_ name: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(name)
    }

    private static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let url = url(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let url = url(name), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func saveBin() { Self.write(bin, "bin.json") }
    private func saveHistory() { Self.write(history, "activity.json") }

    /// Things deleted more than 30 days ago go for good (with their receipt photos).
    func prune() {
        let result = RecordKeeping.prune(bin)
        guard !result.gone.isEmpty else { return }
        bin = result.kept
        for item in result.gone {
            if let receipt = item.payment?.receipt { Accounts.shared.deleteReceiptFile(receipt) }
        }
        saveBin()
    }

    // MARK: - history

    /// Who made the change: the owner or a member of staff, on which kind of iPhone.
    private var by: String {
        let role: String
        switch CloudTeam.shared.role {
        case .staff: role = String(localized: "Staff")
        case .owner: role = String(localized: "Owner")
        case .none: role = ""
        }
        let device = UIDevice.current.model
        return role.isEmpty ? device : role + " · " + device
    }

    func log(_ action: ActivityEntry.Action, _ subject: String, amount: Double? = nil, newAmount: Double? = nil) {
        history.insert(ActivityEntry(action: action, subject: subject, amount: amount, newAmount: newAmount, by: by), at: 0)
        if history.count > RecordKeeping.historyLimit { history = RecordKeeping.trimmed(history) }
        saveHistory()
    }

    // MARK: - the bin

    func binInvoice(_ entry: HistoryEntry) {
        bin.insert(BinItem(invoice: entry), at: 0)
        saveBin()
        log(.invoiceDeleted, RecordKeeping.subject(entry), amount: entry.total)
    }

    func binPayment(_ payment: SupplierPayment) {
        bin.insert(BinItem(payment: payment), at: 0)
        saveBin()
        log(.paymentRemoved, payment.supplier, amount: payment.amount)
    }

    func binPrice(_ item: PriceItem) {
        bin.insert(BinItem(price: item), at: 0)
        saveBin()
        log(.priceDeleted, item.name, amount: item.price)
    }

    /// Puts something back where it was.
    func restore(_ item: BinItem, context: ModelContext) {
        if let entry = item.invoice {
            let id = entry.id
            let existing = (try? context.fetch(FetchDescriptor<StoredReport>(predicate: #Predicate<StoredReport> { $0.uid == id }))) ?? []
            if existing.isEmpty { context.insert(StoredReport(entry: entry)) }
            try? context.save()
            log(.invoiceRestored, RecordKeeping.subject(entry), amount: entry.total)
        }
        if let payment = item.payment {
            Accounts.shared.restorePayment(payment, context: context)
            log(.paymentRestored, payment.supplier, amount: payment.amount)
        }
        if let price = item.price {
            AppData.save(price, in: context, logged: false)
            try? context.save()
            log(.priceRestored, price.name, amount: price.price)
        }
        bin.removeAll { $0.id == item.id }
        saveBin()
        Accounts.shared.changed(context)
    }

    func forget(_ item: BinItem) {
        bin.removeAll { $0.id == item.id }
        if let receipt = item.payment?.receipt { Accounts.shared.deleteReceiptFile(receipt) }
        saveBin()
    }

    func emptyBin() {
        for item in bin { if let receipt = item.payment?.receipt { Accounts.shared.deleteReceiptFile(receipt) } }
        let count = bin.count
        bin = []
        saveBin()
        log(.binEmptied, String(count))
    }
}
