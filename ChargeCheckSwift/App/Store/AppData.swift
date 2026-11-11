import Foundation
import SwiftData
import ChargeCheckCore

/// Reading and writing the saved price list and reports, and backups.
@MainActor
enum AppData {
    static let legacyBackupName = "ChargeCheck-backup.json"
    private static let legacyDoneKey = "legacyImportDone"

    static func items(_ context: ModelContext) -> [PriceItem] {
        let stored = (try? context.fetch(FetchDescriptor<StoredPrice>())) ?? []
        return stored.map { $0.item }
    }

    static func entries(_ context: ModelContext) -> [HistoryEntry] {
        let descriptor = FetchDescriptor<StoredReport>(sortBy: [SortDescriptor(\.savedAt, order: .reverse)])
        let stored = (try? context.fetch(descriptor)) ?? []
        return stored.compactMap { $0.entry }
    }

    /// Everything on this phone as one backup file.
    static func backup(_ context: ModelContext, scans: ScanCredits? = nil) -> BackupFile {
        let defaults = UserDefaults.standard
        var settings = BackupSettings()
        settings.biz = defaults.string(forKey: SettingKey.business)
        settings.mode = defaults.string(forKey: SettingKey.mode)
        settings.color = defaults.string(forKey: SettingKey.colour)
        settings.keepCopy = defaults.string(forKey: SettingKey.keepCopies)
        settings.tol = tolerance
        let shops = Shops.all
        if !shops.isEmpty {
            settings.shops = shops
            settings.shop = Shops.current
        }
        return BackupFile(baseline: items(context), history: entries(context), settings: settings, scans: scans,
                          payments: Accounts.shared.payments, trusted: Accounts.shared.trusted)
    }

    /// Replaces what is on this phone with the backup.
    static func restore(_ backup: BackupFile, into context: ModelContext) {
        for old in (try? context.fetch(FetchDescriptor<StoredPrice>())) ?? [] { context.delete(old) }
        for old in (try? context.fetch(FetchDescriptor<StoredReport>())) ?? [] { context.delete(old) }
        try? context.save()

        var seen = Set<String>()
        for item in backup.baseline where seen.insert(item.id).inserted {
            context.insert(StoredPrice(item: item))
        }
        seen.removeAll()
        for entry in backup.history where seen.insert(entry.id).inserted {
            context.insert(StoredReport(entry: entry))
        }
        try? context.save()
        Accounts.shared.restore(payments: backup.payments, trusted: backup.trusted, context: context)

        let defaults = UserDefaults.standard
        if let settings = backup.settings {
            if let biz = settings.biz { defaults.set(biz, forKey: SettingKey.business) }
            if let mode = settings.mode, ["auto", "light", "dark"].contains(mode) { defaults.set(mode, forKey: SettingKey.mode) }
            if let colour = settings.color, Themes.all.contains(where: { $0.id == colour }) { defaults.set(colour, forKey: SettingKey.colour) }
            if let copies = settings.keepCopy, ["phone", "ask", "off"].contains(copies) { defaults.set(copies, forKey: SettingKey.keepCopies) }
            if let tol = settings.tol, tol >= 0.01, tol <= 1 { defaults.set(tol, forKey: SettingKey.tolerance) }
            if let shops = settings.shops, !shops.isEmpty {
                Shops.all = shops
                if let shop = settings.shop { defaults.set(shop, forKey: Shops.currentKey) }
            }
        }
    }

    /// Supplier names the user already has (from reports and the price list).
    static func knownSuppliers(_ context: ModelContext) -> [String] {
        var seen = Set<String>()
        let names = entries(context).map { $0.supplier } + items(context).map { $0.supplier }
        return names.map { TextTools.cleanSupplier($0) }.filter { $0.count > 2 && seen.insert($0).inserted }
    }

    /// How much above the agreed price counts as an overcharge (at least 1p).
    static var tolerance: Double {
        max(0.01, UserDefaults.standard.double(forKey: SettingKey.tolerance))
    }

    /// Saves a checked invoice to Reports. If the same invoice is already there
    /// (same supplier, number and date) it is replaced, not saved twice.
    @discardableResult
    static func saveReport(_ draft: inout InvoiceDraft, book: PriceBook, context: ModelContext) -> HistoryEntry {
        let all = entries(context)
        var existing = all.first { $0.id == draft.id }
        if existing == nil {
            let net = draft.totalOnly ? (draft.printedNet ?? draft.printedTotal ?? 0) : InvoiceMaths.totals(draft, book: book, tolerance: tolerance).net
            if let same = InvoiceMaths.duplicate(of: draft, net: net, in: all) {
                existing = same
                draft.id = same.id
            }
        }
        let entry = InvoiceMaths.historyEntry(draft, book: book, tolerance: tolerance, existing: existing)
        let id = entry.id
        let descriptor = FetchDescriptor<StoredReport>(predicate: #Predicate<StoredReport> { $0.uid == id })
        if let stored = (try? context.fetch(descriptor))?.first {
            stored.update(from: entry)
        } else {
            context.insert(StoredReport(entry: entry))
        }
        try? context.save()
        return entry
    }

    /// Changes saved reports (for example marks them paid) and keeps everything else about them.
    static func updateReports(_ ids: Set<String>, context: ModelContext, _ change: (inout HistoryEntry) -> Void) {
        for stored in (try? context.fetch(FetchDescriptor<StoredReport>())) ?? [] where ids.contains(stored.uid) {
            guard var entry = stored.entry else { continue }
            let savedAt = entry.savedAt
            change(&entry)
            entry.savedAt = savedAt
            stored.update(from: entry)
        }
        try? context.save()
    }

    static func deleteReport(_ id: String, context: ModelContext) {
        for stored in (try? context.fetch(FetchDescriptor<StoredReport>())) ?? [] where stored.uid == id { context.delete(stored) }
        try? context.save()
    }

    /// Adds or updates one price.
    static func save(_ item: PriceItem, in context: ModelContext) {
        let id = item.id
        let descriptor = FetchDescriptor<StoredPrice>(predicate: #Predicate<StoredPrice> { $0.uid == id })
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.update(from: item)
        } else {
            context.insert(StoredPrice(item: item))
        }
    }

    /// The first (web-based) version of the app kept an automatic backup in the app's
    /// Documents folder. When the Swift version opens for the first time with nothing
    /// saved, it picks that up so prices and reports carry over.
    @discardableResult
    static func importLegacyBackupIfNeeded(_ context: ModelContext) -> BackupFile? {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: legacyDoneKey) { return nil }
        let priceCount = (try? context.fetchCount(FetchDescriptor<StoredPrice>())) ?? 0
        let reportCount = (try? context.fetchCount(FetchDescriptor<StoredReport>())) ?? 0
        guard priceCount == 0, reportCount == 0 else {
            defaults.set(true, forKey: legacyDoneKey)
            return nil
        }
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let file = folder.appendingPathComponent(legacyBackupName)
        guard let data = try? Data(contentsOf: file), let backup = try? BackupFile.read(data) else { return nil }
        restore(backup, into: context)
        defaults.set(true, forKey: legacyDoneKey)
        return backup
    }
}

enum SettingKey {
    static let mode = "look.mode"
    static let colour = "look.colour"
    static let business = "business.name"
    static let tolerance = "check.tolerance"
    /// The user has seen the plans and chose to carry on with the free version.
    static let choseFree = "access.choseFree"
    static let keepCopies = "copies.mode"
    static let cloudCopies = "copies.cloud"
    static let reminder = "reminder.monthly"
    static let paySkipped = "pay.skipped"
    /// How many times each photo is read: 1 (faster) or 2 (double-checked). 2 unless the user chose 1.
    static let photoReads = "check.photoReads"
    /// Show "To pay" before VAT (for shops that aren't VAT registered).
    static let payBeforeVat = "pay.beforeVat"
    /// Lower an agreed price when a fully checked invoice is cheaper (on unless turned off).
    static let autoLower = "prices.autoLower"
    static let lastRatingAsk = "rating.lastAsk"
}
