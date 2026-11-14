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

/// The app's own folder in iCloud Drive (iCloud Drive › ChargeCheck). Used automatically – nothing to set up –
/// whenever this iPhone is signed in to iCloud and the user hasn't chosen a folder of their own.
/// Finding it can take a moment the first time, so `prepare()` runs off the main thread at launch.
final class AutoCloud: @unchecked Sendable {
    static let shared = AutoCloud()
    private let lock = NSLock()
    private var found: URL?

    /// Settings › iCloud backup › "Save to iCloud automatically" (on unless turned off).
    static let settingKey = "cloud.auto"

    var root: URL? {
        guard UserDefaults.standard.object(forKey: Self.settingKey) as? Bool != false else { return nil }
        lock.lock(); defer { lock.unlock() }
        return found
    }

    /// Signed in to iCloud and the folder was found (whether or not automatic saving is turned on).
    var available: Bool {
        lock.lock(); defer { lock.unlock() }
        return found != nil
    }

    /// Looks for the folder again (at launch, and when coming back to the app).
    func prepare() async {
        let url: URL? = await Task.detached(priority: .utility) {
            guard FileManager.default.ubiquityIdentityToken != nil,
                  let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            return documents
        }.value
        lock.lock(); found = url; lock.unlock()
    }
}

/// Where backups and invoice copies are also saved, so they survive a lost or new phone: a folder the user picked,
/// or otherwise the app's own iCloud Drive folder (automatic).
enum CloudFolder {
    private static let key = "cloud.folder.bookmark"
    static let nameKey = "cloud.folder.name"
    static let lastSavedKey = "cloud.folder.lastSaved"

    /// The user picked a folder of their own.
    static var isChosen: Bool { UserDefaults.standard.data(forKey: key) != nil }
    /// Saving to iCloud automatically (no folder picked, signed in to iCloud).
    static var isAutomatic: Bool { !isChosen && AutoCloud.shared.root != nil }
    /// Backups and copies go to the cloud, one way or the other.
    static var isOn: Bool { isChosen || AutoCloud.shared.root != nil }

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
        CloudCopies.forgetUploaded()
    }

    /// The folder's identity, so the list of copies already uploaded starts again when the place changes.
    static var placeID: String { folder()?.path ?? "" }

    static func folder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return AutoCloud.shared.root }
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

    /// Keeps the newest `keep` files of a kind in a folder there (the daily backups), so iCloud doesn't fill up.
    static func trim(folder sub: String, prefix: String, keep: Int) {
        guard let root = folder() else { return }
        let scoped = root.startAccessingSecurityScopedResource()
        defer {
            if scoped { root.stopAccessingSecurityScopedResource() }
        }
        let directory = root.appendingPathComponent(sub, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        // a file not downloaded to this phone is listed as ".name.icloud"
        let plain = names.map { $0.hasPrefix(".") && $0.hasSuffix(".icloud") ? String($0.dropFirst().dropLast(7)) : $0 }
        let daily = Set(plain.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }).sorted()
        for name in daily.dropLast(keep) {
            let target = directory.appendingPathComponent(name)
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: .forDeleting, error: &error) { url in
                try? FileManager.default.removeItem(at: url)
            }
        }
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
        // the saved data didn't open: what's on screen is temporary – never let it replace a real backup
        guard !AppStorageSetup.failed else { return }
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
        if CloudFolder.isOn {
            DispatchQueue.global(qos: .utility).async {
                let ok = CloudFolder.write(data, folder: "", name: AppData.legacyBackupName)
                if ok {
                    CloudFolder.write(data, folder: "Backups", name: daily)
                    CloudFolder.trim(folder: "Backups", prefix: "ChargeCheck-", keep: 30)
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: CloudFolder.lastSavedKey)
                }
                // invoice copies the cloud doesn't have yet (older ones, or ones saved while offline)
                CloudCopies.catchUp()
            }
        }
    }

    /// Before a backup replaces what's on the phone: a copy of what was there, in Files › ChargeCheck › Backups
    /// ("Before-restore-…"), so a restore of the wrong file can be undone. The last 5 are kept.
    static func safetyCopy(_ context: ModelContext, scans: ScanCredits?) {
        guard !AppStorageSetup.failed else { return }
        let backup = AppData.backup(context, scans: scans)
        if backup.baseline.isEmpty && backup.history.isEmpty && (backup.payments ?? []).isEmpty { return }
        guard let data = try? backup.encoded() else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "Before-restore-" + formatter.string(from: Date()) + ".json"
        AppFiles.write(data, folder: "Backups", name: name)
        guard let folder = AppFiles.documents?.appendingPathComponent("Backups", isDirectory: true),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let copies = names.filter { $0.hasPrefix("Before-restore-") && $0.hasSuffix(".json") }.sorted()
        for old in copies.dropLast(5) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
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
            data = CloudCopies.compressed(pages[0])
        } else if pages.count > 1 {
            // each page kept as a compressed photo inside the PDF
            data = PDFMaker.pages(pages.compactMap { CloudCopies.compressed($0).flatMap { UIImage(data: $0) } })
            ending = "pdf"
        }
        guard let data else { return old }
        let name = ReportMaths.copyName(for: entry) + "." + ending
        let month = String(name.prefix(7))
        let folder = "Invoices/" + (month.contains("-") ? month : "undated")
        let path = folder + "/" + name
        if let old, old != path, let previous = AppFiles.url(forRelativePath: old) { try? FileManager.default.removeItem(at: previous) }
        guard AppFiles.write(data, folder: folder, name: name) != nil else { return old }
        if CloudCopies.wanted {
            DispatchQueue.global(qos: .utility).async {
                if CloudFolder.write(data, folder: folder, name: name) { CloudCopies.markUploaded(path) }
            }
        }
        return path
    }
}

/// Invoice copies in iCloud: compressed first, uploaded in the background, and any the cloud is missing
/// (saved before iCloud was on, or while offline) sent later.
enum CloudCopies {
    private static let uploadedKey = "cloud.copies.uploaded"
    private static let placeKey = "cloud.copies.place"
    private static let lock = NSLock()

    static var wanted: Bool {
        CloudFolder.isOn && UserDefaults.standard.object(forKey: SettingKey.cloudCopies) as? Bool != false
    }

    /// An invoice photo as kept: long side 1800 px, JPEG quality 0.6 – sharp enough to read every figure,
    /// about a quarter of the size of the camera's photo.
    static func compressed(_ image: UIImage) -> Data? {
        image.prepared(maxSide: 1800).jpegData(compressionQuality: 0.6)
    }

    private static func uploaded() -> Set<String> {
        let defaults = UserDefaults.standard
        let place = CloudFolder.placeID
        if defaults.string(forKey: placeKey) != place {
            defaults.set(place, forKey: placeKey)
            defaults.removeObject(forKey: uploadedKey)
        }
        return Set(defaults.stringArray(forKey: uploadedKey) ?? [])
    }

    static func markUploaded(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        var done = uploaded()
        done.insert(path)
        UserDefaults.standard.set(Array(done), forKey: uploadedKey)
    }

    static func forgetUploaded() {
        UserDefaults.standard.removeObject(forKey: uploadedKey)
        UserDefaults.standard.removeObject(forKey: placeKey)
    }

    /// Sends copies on this phone that the cloud doesn't have yet, a few at a time so it never runs long.
    /// Large older photos are compressed for the cloud copy; the copy on the phone is left exactly as it is.
    static func catchUp(limit: Int = 40) {
        guard wanted, let base = AppFiles.documents else { return }
        let invoices = base.appendingPathComponent("Invoices", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: invoices, includingPropertiesForKeys: nil) else { return }
        let done = uploaded()
        var sent = 0
        for case let url as URL in walker {
            guard sent < limit else { break }
            let ending = url.pathExtension.lowercased()
            guard ["jpg", "jpeg", "png", "pdf", "heic"].contains(ending) else { continue }
            let relative = url.standardizedFileURL.path.replacingOccurrences(of: invoices.standardizedFileURL.path + "/", with: "")
            let path = "Invoices/" + relative
            guard !done.contains(path), var data = try? Data(contentsOf: url) else { continue }
            if ending != "pdf", data.count > 700_000, let image = UIImage(data: data), let small = compressed(image) {
                data = small
            }
            let folder = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            guard CloudFolder.write(data, folder: folder, name: name) else { return }   // offline or iCloud full: next time
            markUploaded(path)
            sent += 1
        }
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

/// "Payments due" reminders: at 9 am on each day something falls due, e.g. "2 invoices due today: Brakes, APEX · £300.30".
/// Planned again for the next two weeks whenever invoices or payments change.
enum DueReminder {
    static let settingKey = "reminder.due"
    private static let prefix = "chargecheck.due."

    static var isOn: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    /// Turning it on asks for notifications. Returns false when they're not allowed.
    static func set(_ on: Bool) async -> Bool {
        UserDefaults.standard.set(false, forKey: settingKey)
        await clear()
        guard on else { return true }
        guard (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true else { return false }
        UserDefaults.standard.set(true, forKey: settingKey)
        return true
    }

    private static func clear() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map { $0.identifier }.filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    static func refresh(_ dues: [DueInvoice], currencyOf: (DueInvoice) -> String) {
        guard isOn else { return }
        let plan = DueReminders.plan(dues, currencyOf: currencyOf)
        Task {
            await clear()
            let center = UNUserNotificationCenter.current()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_GB_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let now = Date()
            for notice in plan {
                guard let day = formatter.date(from: notice.day) else { continue }
                var when = Calendar.current.dateComponents([.year, .month, .day], from: day)
                when.hour = 9
                // due today but 9 am has passed: no reminder (it's on Home already)
                if let fire = Calendar.current.date(from: when), fire < now { continue }
                let content = UNMutableNotificationContent()
                content.title = notice.count == 1 ? String(localized: "1 invoice due today") : String(localized: "\(notice.count) invoices due today")
                var body = notice.suppliers.prefix(3).joined(separator: ", ")
                if notice.suppliers.count > 3 { body += " " + String(localized: "and others") }
                if let amount = notice.amount, let code = notice.currency { body += " · " + Money.format(amount, code: code) }
                content.body = body
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: prefix + notice.day, content: content, trigger: trigger))
            }
        }
    }
}

