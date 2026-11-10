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
    static func backup(_ context: ModelContext) -> BackupFile {
        let defaults = UserDefaults.standard
        var settings = BackupSettings()
        settings.biz = defaults.string(forKey: SettingKey.business)
        settings.mode = defaults.string(forKey: SettingKey.mode)
        settings.color = defaults.string(forKey: SettingKey.colour)
        return BackupFile(baseline: items(context), history: entries(context), settings: settings)
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

        let defaults = UserDefaults.standard
        if let settings = backup.settings {
            if let biz = settings.biz { defaults.set(biz, forKey: SettingKey.business) }
            if let mode = settings.mode, ["auto", "light", "dark"].contains(mode) { defaults.set(mode, forKey: SettingKey.mode) }
            if let colour = settings.color, Themes.all.contains(where: { $0.id == colour }) { defaults.set(colour, forKey: SettingKey.colour) }
        }
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
    static func importLegacyBackupIfNeeded(_ context: ModelContext) -> Int {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: legacyDoneKey) { return 0 }
        let priceCount = (try? context.fetchCount(FetchDescriptor<StoredPrice>())) ?? 0
        let reportCount = (try? context.fetchCount(FetchDescriptor<StoredReport>())) ?? 0
        guard priceCount == 0, reportCount == 0 else {
            defaults.set(true, forKey: legacyDoneKey)
            return 0
        }
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return 0 }
        let file = folder.appendingPathComponent(legacyBackupName)
        guard let data = try? Data(contentsOf: file), let backup = try? BackupFile.read(data) else { return 0 }
        restore(backup, into: context)
        defaults.set(true, forKey: legacyDoneKey)
        return backup.baseline.count
    }
}

enum SettingKey {
    static let mode = "look.mode"
    static let colour = "look.colour"
    static let business = "business.name"
}
