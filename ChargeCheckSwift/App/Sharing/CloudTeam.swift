import Foundation
import CloudKit
import SwiftData
import ChargeCheckCore

/// Shares one business between the owner's phone and staff phones through the owner's iCloud.
///
/// The owner keeps everything in a zone of their private iCloud database and shares the whole zone with staff
/// (CKShare). Staff phones read and write that zone through their shared database. Each report, price and payment is
/// one record holding the same JSON as the backup file. `CKSyncEngine` does the sending and fetching.
@MainActor
final class CloudTeam: NSObject, ObservableObject {
    static let shared = CloudTeam()

    enum Role: String {
        case none, owner, staff
    }

    static let roleKey = "team.role"
    /// Off in betas 16–17 while a launch crash was found (it was SwiftData + the iCloud entitlement, fixed in 17).
    /// iCloud's sync engine starting without the Push Notifications capability. While this is false, iCloud is never touched.
    /// Turn back on only together with the push entitlement (see MIGRATION.md, "Staff phones").
    static let enabled = true
    /// Set while the sync engine is starting. If the app dies before it's cleared, sharing stays paused on the next launch
    /// instead of crashing again and again.
    private static let startingKey = "team.starting"
    /// The user deliberately deleted many things at once: the next scan may send that many deletions.
    private var bulkDeleteAllowed = false

    func allowBulkDelete() { bulkDeleteAllowed = true }
    @Published private(set) var pausedAfterCrash = false
    private static let zoneName = "Business"
    private static let zoneOwnerKey = "team.zoneOwner"
    private static let recordType = "Item"

    @Published private(set) var role: Role
    @Published private(set) var status = ""
    @Published private(set) var lastSync: Date?
    @Published private(set) var busy = false

    var isStaff: Bool { Self.enabled && role == .staff }

    private var context: ModelContext?
    private var engine: CKSyncEngine?
    /// What iCloud has: record name → hash of the data.
    private var synced: [String: String] = [:]
    /// iCloud's own bookkeeping for each record, so a change updates the record instead of clashing with it.
    private var systemFields: [String: Data] = [:]
    /// Data waiting to be sent.
    private var outgoing: [String: SyncItem] = [:]
    private var scanTask: Task<Void, Never>?
    /// This phone's items by record name, built once when iCloud asks for records that aren't waiting in `outgoing`.
    private var itemsCache: [String: SyncItem]?
    private static let wipeKey = "team.wipeOnStart"
    /// While remote changes are being applied, local saves mustn't be sent back.
    private var applying = false

    static var containerID: String {
        Bundle.main.object(forInfoDictionaryKey: "CCCloudContainer") as? String ?? "iCloud.com.rjapps.invoicepricechecker"
    }

    private lazy var container = CKContainer(identifier: Self.containerID)

    private override init() {
        role = Role(rawValue: UserDefaults.standard.string(forKey: Self.roleKey) ?? "") ?? .none
        super.init()
        load()
    }

    private var zoneID: CKRecordZone.ID {
        let owner = UserDefaults.standard.string(forKey: Self.zoneOwnerKey) ?? CKCurrentUserDefaultName
        return CKRecordZone.ID(zoneName: Self.zoneName, ownerName: owner)
    }

    // MARK: - saved state

    private static var folder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Team", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private struct Saved: Codable {
        var synced: [String: String] = [:]
        var systemFields: [String: Data] = [:]
        var engine: Data?
        var lastSync: Date?
    }

    private var engineState: CKSyncEngine.State.Serialization?

    private func load() {
        guard let url = Self.folder?.appendingPathComponent("state.json"), let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        synced = saved.synced
        systemFields = saved.systemFields
        lastSync = saved.lastSync
        if let engine = saved.engine { engineState = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: engine) }
    }

    private func save() {
        let engineData = engineState.flatMap { try? JSONEncoder().encode($0) }
        let saved = Saved(synced: synced, systemFields: systemFields, engine: engineData, lastSync: lastSync)
        guard let url = Self.folder?.appendingPathComponent("state.json"), let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func forgetState() {
        synced = [:]
        systemFields = [:]
        outgoing = [:]
        engineState = nil
        lastSync = nil
        save()
    }

    private func setRole(_ new: Role) {
        role = new
        UserDefaults.standard.set(new.rawValue, forKey: Self.roleKey)
    }

    // MARK: - starting

    /// Called once at launch with the app's data.
    func start(_ context: ModelContext) {
        self.context = context
        if UserDefaults.standard.bool(forKey: Self.wipeKey) {
            // an invite link opened the app before its data was ready: clear this phone's own data now
            UserDefaults.standard.removeObject(forKey: Self.wipeKey)
            wipeLocal()
        }
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleScan() }
        }
        startEngine()
    }

    private func startEngine() {
        guard Self.enabled, role != .none, engine == nil else { return }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.startingKey) {
            pausedAfterCrash = true
            status = String(localized: "Staff sharing is paused because the app closed unexpectedly while starting it.")
            return
        }
        defaults.set(true, forKey: Self.startingKey)
        defaults.synchronize()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            UserDefaults.standard.removeObject(forKey: Self.startingKey)
        }
        let database = role == .owner ? container.privateCloudDatabase : container.sharedCloudDatabase
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: engineState, delegate: self)
        configuration.automaticallySync = true
        engine = CKSyncEngine(configuration)
        if role == .owner, engineState == nil {
            engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        }
        scheduleScan(after: 0.5)
        Task { await refresh() }
    }

    /// After a paused start: try once more.
    func retryAfterCrash() {
        UserDefaults.standard.removeObject(forKey: Self.startingKey)
        pausedAfterCrash = false
        status = ""
        startEngine()
    }

    /// Fetches what other phones changed and sends this phone's changes. Safe to call any time.
    func refresh() async {
        guard let engine else { return }
        busy = true
        defer { busy = false }
        scan()
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            lastSync = Date()
            status = ""
            save()
        } catch {
            status = Self.describe(error)
        }
    }

    // MARK: - owner: sharing the business

    /// Turns sharing on: everything on this phone goes up to the owner's iCloud.
    func becomeOwner() async throws {
        guard Self.enabled else { throw TeamError.noICloud }
        let account = try await container.accountStatus()
        guard account == .available else { throw TeamError.noICloud }
        engine = nil
        forgetState()
        UserDefaults.standard.removeObject(forKey: Self.zoneOwnerKey)
        setRole(.owner)
        _ = try await container.privateCloudDatabase.save(CKRecordZone(zoneID: zoneID))
        startEngine()
    }

    /// The zone-wide share staff join through. Made the first time it's needed.
    func share() async throws -> CKShare {
        let database = container.privateCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        if let existing = try? await database.record(for: shareID) as? CKShare { return existing }
        let share = CKShare(recordZoneID: zoneID)
        let business = UserDefaults.standard.string(forKey: SettingKey.business) ?? ""
        share[CKShare.SystemFieldKey.title] = business.isEmpty ? String(localized: "ChargeCheck team") : business
        share.publicPermission = .none
        _ = try await database.modifyRecords(saving: [share], deleting: [])
        return share
    }

    var cloudContainer: CKContainer { container }

    /// Stops sharing: staff lose access. The owner's data stays on this phone and in iCloud.
    func stopSharing() async {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        _ = try? await container.privateCloudDatabase.modifyRecords(saving: [], deleting: [shareID])
        engine = nil
        setRole(.none)
        forgetState()
    }

    // MARK: - staff: joining

    /// A staff member opened the owner's invite link.
    func accept(_ metadata: CKShare.Metadata) async {
        guard Self.enabled else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await container.accept(metadata)
            engine = nil
            forgetState()
            UserDefaults.standard.set(metadata.share.recordID.zoneID.ownerName, forKey: Self.zoneOwnerKey)
            setRole(.staff)
            // the owner's data replaces this phone's
            if context != nil {
                wipeLocal()
            } else {
                UserDefaults.standard.set(true, forKey: Self.wipeKey)
            }
            startEngine()
        } catch {
            status = Self.describe(error)
        }
    }

    /// A staff member leaves: the owner's data is removed from this phone.
    func leave() async {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        _ = try? await container.sharedCloudDatabase.modifyRecords(saving: [], deleting: [shareID])
        engine = nil
        setRole(.none)
        forgetState()
        UserDefaults.standard.removeObject(forKey: Self.zoneOwnerKey)
        wipeLocal()
    }

    /// Removes prices, reports and payments from this phone (joining or leaving a team). Never touches iCloud.
    private func wipeLocal() {
        guard let context else { return }
        applying = true
        defer { applying = false }
        for stored in (try? context.fetch(FetchDescriptor<StoredPrice>())) ?? [] { context.delete(stored) }
        for stored in (try? context.fetch(FetchDescriptor<StoredReport>())) ?? [] { context.delete(stored) }
        try? context.save()
        Accounts.shared.restore(payments: [], trusted: [], context: context)
    }

    // MARK: - finding what changed on this phone

    func scheduleScan(after delay: Double = 2) {
        guard role != .none, !applying else { return }
        scanTask?.cancel()
        scanTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            scan()
        }
    }

    private func currentItems() -> [SyncItem] {
        guard let context else { return [] }
        let defaults = UserDefaults.standard
        let settings = TeamSettings(business: defaults.string(forKey: SettingKey.business) ?? "", shops: Shops.all,
                                    trusted: Accounts.shared.trusted)
        return TeamSync.items(entries: AppData.entries(context), prices: AppData.items(context), payments: Accounts.shared.payments,
                              settings: settings, staff: role == .staff)
    }

    private func scan() {
        guard let engine, context != nil, role != .none, !applying else { return }
        let items = currentItems()
        itemsCache = nil
        var changes = TeamSync.changes(items, synced: synced, staff: role == .staff)
        // Safety: if this phone suddenly has (almost) nothing, its data didn't load or was reset – never pass that on as
        // deleting everyone's records. Real deletions are one or a few at a time.
        let deletable = synced.keys.filter { name in TeamSync.parse(name).map { !(role == .staff && $0.kind.ownerOnly) } ?? false }.count
        let allowed = bulkDeleteAllowed
        bulkDeleteAllowed = false
        if !allowed && changes.delete.count > 10 && changes.delete.count * 2 > deletable {
            status = String(localized: "This phone's data looks empty, so nothing was deleted from iCloud.")
            changes.delete = []
        }
        guard !changes.save.isEmpty || !changes.delete.isEmpty else { return }
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        for item in changes.save {
            outgoing[item.recordName] = item
            pending.append(.saveRecord(CKRecord.ID(recordName: item.recordName, zoneID: zoneID)))
        }
        for name in changes.delete {
            pending.append(.deleteRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
        }
        engine.state.add(pendingRecordZoneChanges: pending)
    }

    private func record(for id: CKRecord.ID) -> CKRecord? {
        let name = id.recordName
        if outgoing[name] == nil {
            if itemsCache == nil { itemsCache = Dictionary(currentItems().map { ($0.recordName, $0) }, uniquingKeysWith: { a, _ in a }) }
            if let item = itemsCache?[name] { outgoing[name] = item }
        }
        guard let item = outgoing[name] else { return nil }
        let record: CKRecord
        if let fields = systemFields[name], let coder = try? NSKeyedUnarchiver(forReadingFrom: fields) {
            coder.requiresSecureCoding = true
            record = CKRecord(coder: coder) ?? CKRecord(recordType: Self.recordType, recordID: id)
            coder.finishDecoding()
        } else {
            record = CKRecord(recordType: Self.recordType, recordID: id)
        }
        record["kind"] = item.kind.rawValue as CKRecordValue
        record["data"] = item.data as CKRecordValue
        return record
    }

    private func remember(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        systemFields[record.recordID.recordName] = coder.encodedData
    }

    // MARK: - applying what other phones changed

    private func apply(saved records: [CKRecord], deleted names: [String]) {
        guard let context else { return }
        applying = true
        defer { applying = false }
        var payments = Accounts.shared.payments
        var trusted: [String]?
        var paymentsChanged = false
        for record in records {
            remember(record)
            let name = record.recordID.recordName
            guard let parsed = TeamSync.parse(name), let data = record["data"] as? Data else { continue }
            synced[name] = TeamSync.hash(data)
            switch parsed.kind {
            case .report:
                guard let entry = TeamSync.decodeReport(data) else { continue }
                let id = entry.id
                let descriptor = FetchDescriptor<StoredReport>(predicate: #Predicate<StoredReport> { $0.uid == id })
                if let stored = (try? context.fetch(descriptor))?.first { stored.update(from: entry) } else { context.insert(StoredReport(entry: entry)) }
            case .price:
                guard let item = TeamSync.decodePrice(data) else { continue }
                AppData.save(item, in: context)
            case .payment:
                guard let payment = TeamSync.decodePayment(data) else { continue }
                payments.removeAll { $0.id == payment.id }
                payments.append(payment)
                paymentsChanged = true
            case .settings:
                guard let settings = TeamSync.decodeSettings(data) else { continue }
                UserDefaults.standard.set(settings.business, forKey: SettingKey.business)
                if !settings.shops.isEmpty { Shops.all = settings.shops }
                trusted = settings.trusted
            }
        }
        for name in names {
            synced[name] = nil
            systemFields[name] = nil
            guard let parsed = TeamSync.parse(name) else { continue }
            let id = parsed.id
            switch parsed.kind {
            case .report:
                for stored in (try? context.fetch(FetchDescriptor<StoredReport>(predicate: #Predicate<StoredReport> { $0.uid == id }))) ?? [] {
                    context.delete(stored)
                }
            case .price:
                for stored in (try? context.fetch(FetchDescriptor<StoredPrice>(predicate: #Predicate<StoredPrice> { $0.uid == id }))) ?? [] {
                    context.delete(stored)
                }
            case .payment:
                payments.removeAll { $0.id == id }
                paymentsChanged = true
            case .settings:
                break
            }
        }
        try? context.save()
        if paymentsChanged || trusted != nil {
            Accounts.shared.restore(payments: payments, trusted: trusted ?? Accounts.shared.trusted, context: context)
        }
        // remember what this phone now holds for those records (as it reads back), so they aren't sent straight back
        let applied = Set(records.map { $0.recordID.recordName })
        for item in currentItems() where applied.contains(item.recordName) { synced[item.recordName] = item.hash }
        save()
    }

    // MARK: - errors

    enum TeamError: LocalizedError {
        case noICloud
        var errorDescription: String? {
            String(localized: "Sign in to iCloud in the Settings app first (Settings › your name › iCloud).")
        }
    }

    static func describe(_ error: Error) -> String {
        if let team = error as? TeamError { return team.errorDescription ?? "" }
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated: return String(localized: "Sign in to iCloud in the Settings app first (Settings › your name › iCloud).")
            case .networkUnavailable, .networkFailure: return String(localized: "No internet connection. Changes are sent when you're back online.")
            case .quotaExceeded: return String(localized: "The owner's iCloud storage is full.")
            case .participantMayNeedVerification: return String(localized: "Open the invite link again and follow Apple's steps to verify.")
            default: break
            }
        }
        return String(localized: "iCloud problem: \(error.localizedDescription)")
    }
}

extension CloudTeam: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await MainActor.run { self.handle(event) }
    }

    private func handle(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let update):
            engineState = update.stateSerialization
            save()
        case .accountChange(let change):
            if case .signOut = change.changeType {
                status = String(localized: "Signed out of iCloud. Sharing is paused.")
            }
        case .fetchedDatabaseChanges(let changes):
            // the owner stopped sharing, or removed this phone
            if changes.deletions.contains(where: { $0.zoneID.zoneName == Self.zoneName }), role == .staff {
                status = String(localized: "The owner stopped sharing with this phone.")
            }
        case .fetchedRecordZoneChanges(let changes):
            apply(saved: changes.modifications.map { $0.record }, deleted: changes.deletions.map { $0.recordID.recordName })
        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                remember(record)
                let name = record.recordID.recordName
                if let item = outgoing.removeValue(forKey: name) { synced[name] = item.hash }
            }
            for id in sent.deletedRecordIDs {
                synced[id.recordName] = nil
                systemFields[id.recordName] = nil
            }
            var retry: [CKSyncEngine.PendingRecordZoneChange] = []
            for failure in sent.failedRecordSaves {
                let id = failure.record.recordID
                switch failure.error.code {
                case .serverRecordChanged:
                    // someone else changed it first: take their bookkeeping and send ours again (last change wins)
                    if let server = failure.error.serverRecord { remember(server) }
                    retry.append(.saveRecord(id))
                case .zoneNotFound:
                    if role == .owner { engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
                    retry.append(.saveRecord(id))
                case .unknownItem:
                    systemFields[id.recordName] = nil
                    retry.append(.saveRecord(id))
                case .permissionFailure:
                    // staff can't change owner-only records; forget them so they aren't tried again
                    outgoing[id.recordName] = nil
                default:
                    status = CloudTeam.describe(failure.error)
                }
            }
            if !retry.isEmpty { engine?.state.add(pendingRecordZoneChanges: retry) }
            lastSync = Date()
            save()
        default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                               syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            await MainActor.run { self.record(for: id) }
        }
    }
}
