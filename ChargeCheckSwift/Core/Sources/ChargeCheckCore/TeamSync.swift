import Foundation

/// What a business shares with its staff through iCloud: one record per report, price and payment, plus the settings.
public enum SyncKind: String, CaseIterable, Sendable {
    case report = "Report"
    case price = "Price"
    case payment = "Payment"
    case settings = "TeamSettings"

    /// Owner-only data: staff phones receive it but never send it.
    public var ownerOnly: Bool { self != .report }
}

/// The settings staff phones take from the owner.
public struct TeamSettings: Codable, Equatable, Sendable {
    public var business: String
    public var shops: [ShopInfo]
    public var trusted: [String]

    public init(business: String, shops: [ShopInfo], trusted: [String]) {
        self.business = business
        self.shops = shops
        self.trusted = trusted
    }
}

/// One thing to keep in step between phones.
public struct SyncItem: Equatable, Sendable {
    public var kind: SyncKind
    public var id: String
    /// The thing itself as JSON (same shapes as the backup file).
    public var data: Data

    /// The iCloud record name: kind and id, so ids from different kinds never clash.
    public var recordName: String { TeamSync.recordName(kind, id) }
    public var hash: String { TeamSync.hash(data) }

    public init(kind: SyncKind, id: String, data: Data) {
        self.kind = kind
        self.id = id
        self.data = data
    }
}

public enum TeamSync {
    static let settingsID = "business"

    public static func recordName(_ kind: SyncKind, _ id: String) -> String { kind.rawValue + "_" + id }

    /// The kind and id back from a record name ("Report_ABC" → report, "ABC").
    public static func parse(_ recordName: String) -> (kind: SyncKind, id: String)? {
        guard let cut = recordName.firstIndex(of: "_"), let kind = SyncKind(rawValue: String(recordName[..<cut])) else { return nil }
        return (kind, String(recordName[recordName.index(after: cut)...]))
    }

    static func json<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    /// A short fingerprint of the data, to tell what changed since the last sync (FNV-1a, 64 bits).
    public static func hash(_ data: Data) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16)
    }

    /// Everything this phone shares. Staff phones share only the reports they make.
    public static func items(entries: [HistoryEntry], prices: [PriceItem], payments: [SupplierPayment], settings: TeamSettings,
                             staff: Bool) -> [SyncItem] {
        var out = entries.map { SyncItem(kind: .report, id: $0.id, data: json($0)) }
        if !staff {
            out += prices.map { SyncItem(kind: .price, id: $0.id, data: json($0)) }
            out += payments.map { SyncItem(kind: .payment, id: $0.id, data: json($0)) }
            out.append(SyncItem(kind: .settings, id: settingsID, data: json(settings)))
        }
        return out
    }

    /// What to send: new or changed items, and records that were synced before but are gone now.
    /// `synced` is record name → hash of what iCloud has. Staff never delete owner-only records.
    public static func changes(_ items: [SyncItem], synced: [String: String], staff: Bool) -> (save: [SyncItem], delete: [String]) {
        var seen = Set<String>()
        var save: [SyncItem] = []
        for item in items where seen.insert(item.recordName).inserted {
            if synced[item.recordName] != item.hash { save.append(item) }
        }
        let delete = synced.keys.filter { name in
            guard !seen.contains(name), let parsed = parse(name) else { return false }
            return !(staff && parsed.kind.ownerOnly)
        }.sorted()
        return (save, delete)
    }

    /// Reading a record that arrived from iCloud.
    public static func decodeReport(_ data: Data) -> HistoryEntry? { try? JSONDecoder().decode(HistoryEntry.self, from: data) }
    public static func decodePrice(_ data: Data) -> PriceItem? { try? JSONDecoder().decode(PriceItem.self, from: data) }
    public static func decodePayment(_ data: Data) -> SupplierPayment? { try? JSONDecoder().decode(SupplierPayment.self, from: data) }
    public static func decodeSettings(_ data: Data) -> TeamSettings? { try? JSONDecoder().decode(TeamSettings.self, from: data) }
}
