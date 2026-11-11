import UIKit
import SwiftData
import UserNotifications
import ChargeCheckCore

/// The app's own folder (Files app › On My iPhone › ChargeCheck).
enum AppFiles {
    static var documents: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// Writes a file under the ChargeCheck folder, e.g. folder "Exports". Returns where it went.
    @discardableResult
    static func write(_ data: Data, folder: String, name: String) -> URL? {
        guard var url = documents else { return nil }
        for part in folder.split(separator: "/") { url.appendPathComponent(String(part), isDirectory: true) }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            url.appendPathComponent(name)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func url(forRelativePath path: String) -> URL? {
        guard let base = documents else { return nil }
        let url = base.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func safeName(_ text: String) -> String {
        String(text.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == " ") ? $0 : "-" })
    }
}

/// A folder the user picked once (for example iCloud Drive › ChargeCheck). Backups and
/// invoice copies are also saved there, so they survive a lost or new phone.
enum CloudFolder {
    private static let key = "cloud.folder.bookmark"
    static let nameKey = "cloud.folder.name"
    static let lastSavedKey = "cloud.folder.lastSaved"

    static var isChosen: Bool { UserDefaults.standard.data(forKey: key) != nil }

    static func describe(_ url: URL) -> String {
        let path = url.path
        if let range = path.range(of: "com~apple~CloudDocs") {
            return (["iCloud Drive"] + path[range.upperBound...].split(separator: "/").map(String.init)).joined(separator: " › ")
        }
        return url.lastPathComponent
    }

    /// Remembers the folder. Returns its name, or nil when access couldn't be kept.
    static func choose(_ url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        UserDefaults.standard.set(bookmark, forKey: key)
        let name = describe(url)
        UserDefaults.standard.set(name, forKey: nameKey)
        return name
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: nameKey)
        UserDefaults.standard.removeObject(forKey: lastSavedKey)
    }

    private static func folder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, url.startAccessingSecurityScopedResource() {
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: key)
            }
            url.stopAccessingSecurityScopedResource()
        }
        return url
    }

    @discardableResult
    static func write(_ data: Data, folder sub: String, name: String) -> Bool {
        guard let root = folder() else { return false }
        let scoped = root.startAccessingSecurityScopedResource()
        defer {
            if scoped { root.stopAccessingSecurityScopedResource() }
        }
        var directory = root
        for part in sub.split(separator: "/") { directory.appendPathComponent(String(part), isDirectory: true) }
        let target = directory.appendingPathComponent(name)
        var coordinationError: NSError?
        var ok = false
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                ok = true
            } catch {
                ok = false
            }
        }
        return ok && coordinationError == nil
    }

    /// The latest backup already in the folder (for a new phone).
    static func readBackup() -> BackupFile? {
        guard let root = folder() else { return nil }
        let scoped = root.startAccessingSecurityScopedResource()
        defer {
            if scoped { root.stopAccessingSecurityScopedResource() }
        }
        let target = root.appendingPathComponent(AppData.legacyBackupName)
        try? FileManager.default.startDownloadingUbiquitousItem(at: target)
        var found: BackupFile?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: target, options: [], error: &coordinationError) { url in
            if let data = try? Data(contentsOf: url) { found = try? BackupFile.read(data) }
        }
        return found
    }
}

/// Keeps an up-to-date backup in the app's folder (and the chosen iCloud folder) without the user doing anything.
@MainActor
enum AutoBackup {
    static let lastKey = "backup.last"

    static func run(_ context: ModelContext, scans: ScanCredits?) {
        let backup = AppData.backup(context, scans: scans)
        // nothing worth saving yet: never overwrite a good backup with an empty one
        if backup.baseline.isEmpty && backup.history.isEmpty && (scans?.n ?? 0) == 0 { return }
        guard let data = try? backup.encoded() else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let daily = "ChargeCheck-" + formatter.string(from: Date()) + ".json"
        AppFiles.write(data, folder: "", name: AppData.legacyBackupName)
        AppFiles.write(data, folder: "Backups", name: daily)
        trimDaily()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
        if CloudFolder.isChosen {
            DispatchQueue.global(qos: .utility).async {
                let ok = CloudFolder.write(data, folder: "", name: AppData.legacyBackupName)
                if ok {
                    CloudFolder.write(data, folder: "Backups", name: daily)
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: CloudFolder.lastSavedKey)
                }
            }
        }
    }

    /// Keeps the last 14 daily backups.
    private static func trimDaily() {
        guard let folder = AppFiles.documents?.appendingPathComponent("Backups", isDirectory: true),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let daily = names.filter { $0.hasPrefix("ChargeCheck-") && $0.hasSuffix(".json") }.sorted()
        for name in daily.dropLast(14) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }
}

/// Copies of the original invoices (photo or PDF), for suppliers, disputes and the accountant.
enum InvoiceCopies {
    /// "phone" (default), "ask" (phone + offer to save elsewhere) or "off".
    static var mode: String {
        let value = UserDefaults.standard.string(forKey: SettingKey.keepCopies) ?? "phone"
        return ["phone", "ask", "off"].contains(value) ? value : "phone"
    }

    /// Saves a copy and returns its path inside the ChargeCheck folder (e.g. "Invoices/2026-11/…jpg").
    static func keep(pages: [UIImage], sourcePDF: Data?, entry: HistoryEntry, replacing old: String?) -> String? {
        guard mode != "off" else { return old }
        var data: Data?
        var ending = "jpg"
        if let sourcePDF {
            data = sourcePDF
            ending = "pdf"
        } else if pages.count == 1 {
            data = pages[0].prepared(maxSide: 2200).jpegData(compressionQuality: 0.85)
        } else if pages.count > 1 {
            data = PDFMaker.pages(pages.map { $0.prepared(maxSide: 2200) })
            ending = "pdf"
        }
        guard let data else { return old }
        let name = ReportMaths.copyName(for: entry) + "." + ending
        let month = String(name.prefix(7))
        let folder = "Invoices/" + (month.contains("-") ? month : "undated")
        let path = folder + "/" + name
        if let old, old != path, let previous = AppFiles.url(forRelativePath: old) { try? FileManager.default.removeItem(at: previous) }
        guard AppFiles.write(data, folder: folder, name: name) != nil else { return old }
        if CloudFolder.isChosen && UserDefaults.standard.object(forKey: SettingKey.cloudCopies) as? Bool != false {
            DispatchQueue.global(qos: .utility).async { CloudFolder.write(data, folder: folder, name: name) }
        }
        return path
    }
}

/// A reminder two weeks after asking a supplier for a credit, if it hasn't been marked as received.
enum CreditReminder {
    static let days = 14

    private static func id(_ entryID: String) -> String { "chargecheck.credit." + entryID }

    static func set(for entry: HistoryEntry, amount: Double) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id(entry.id)])
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        let supplier = entry.supplier.isEmpty ? String(localized: "your supplier") : entry.supplier
        content.title = String(localized: "Has \(supplier) sent your credit?")
        content.body = String(localized: "You asked for \(Money.format(amount)) two weeks ago. Open ChargeCheck › Reports to mark it received or ask again.")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(days * 86_400), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id(entry.id), content: content, trigger: trigger))
    }

    static func cancel(for entryID: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id(entryID)])
    }
}

/// A reminder on the 1st of each month to send last month's report to the accountant.
enum MonthlyReminder {
    private static let id = "chargecheck.monthly.report"

    static func set(_ on: Bool) async -> Bool {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard on else { return true }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Last month's invoice report is ready")
        content.body = String(localized: "Open ChargeCheck › Reports › Export to send it to your accountant.")
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(day: 1, hour: 9, minute: 0), repeats: true)
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            return true
        } catch {
            return false
        }
    }
}
