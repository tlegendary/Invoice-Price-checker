import Foundation
import SwiftData
import ChargeCheckCore

/// One line of the agreed price list, as saved on the phone.
@Model
final class StoredPrice {
    @Attribute(.unique) var uid: String
    var cat: String
    var name: String
    var price: Double
    var supplier: String
    /// Invoice spellings, one per line.
    var aliasText: String
    /// Special prices per supplier, as JSON.
    var supplierPrices: Data?
    var unit: String?

    init(item: PriceItem) {
        uid = item.id
        cat = item.cat
        name = item.name
        price = item.price
        supplier = item.supplier
        aliasText = item.aliases.joined(separator: "\n")
        supplierPrices = StoredPrice.encode(item.sp)
        unit = item.unit
    }

    static func encode(_ special: [SupplierPrice]) -> Data? {
        if special.isEmpty { return nil }
        return try? JSONEncoder().encode(special)
    }

    func update(from item: PriceItem) {
        cat = item.cat
        name = item.name
        price = item.price
        supplier = item.supplier
        aliasText = item.aliases.joined(separator: "\n")
        supplierPrices = StoredPrice.encode(item.sp)
        unit = item.unit
    }

    var aliases: [String] {
        aliasText.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    var item: PriceItem {
        var special: [SupplierPrice] = []
        if let data = supplierPrices, let decoded = try? JSONDecoder().decode([SupplierPrice].self, from: data) {
            special = decoded
        }
        return PriceItem(id: uid, cat: cat, name: name, price: price, supplier: supplier, aliases: aliases, sp: special, unit: unit)
    }
}

/// One checked invoice, as kept in Reports.
@Model
final class StoredReport {
    @Attribute(.unique) var uid: String
    var savedAt: Date
    var supplier: String
    var invNo: String
    var dateText: String
    var total: Double
    var over: Double
    var paidAt: Date?
    /// The whole invoice (every line) as JSON, in the same shape as the backup file.
    var payload: Data

    init(entry: HistoryEntry) {
        uid = entry.id
        savedAt = StoredReport.parseDate(entry.savedAt) ?? Date()
        supplier = entry.supplier
        invNo = entry.invNo
        dateText = entry.date
        total = entry.total
        over = entry.over
        paidAt = entry.paid.flatMap { StoredReport.parseDate($0) }
        payload = (try? JSONEncoder().encode(entry)) ?? Data()
    }

    func update(from entry: HistoryEntry) {
        savedAt = StoredReport.parseDate(entry.savedAt) ?? Date()
        supplier = entry.supplier
        invNo = entry.invNo
        dateText = entry.date
        total = entry.total
        over = entry.over
        paidAt = entry.paid.flatMap { StoredReport.parseDate($0) }
        payload = (try? JSONEncoder().encode(entry)) ?? payload
    }

    var entry: HistoryEntry? {
        try? JSONDecoder().decode(HistoryEntry.self, from: payload)
    }

    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
