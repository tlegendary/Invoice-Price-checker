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
    /// Special prices per supplier, as JSON – and the item's shops and shop prices in the same field, so the saved
    /// database didn't have to change for them (14 Nov 2026). Items without shops keep the old form (a plain list).
    var supplierPrices: Data?
    var unit: String?

    init(item: PriceItem) {
        uid = item.id
        cat = item.cat
        name = item.name
        price = item.price
        supplier = item.supplier
        aliasText = item.aliases.joined(separator: "\n")
        supplierPrices = StoredPrice.encode(item)
        unit = item.unit
    }

    /// Supplier prices plus shops, for items that have shops.
    private struct Extras: Codable {
        var sp: [SupplierPrice]
        var shops: [String]?
        var shopPrices: [ShopPrice]?
    }

    static func encode(_ item: PriceItem) -> Data? {
        if item.shops == nil && item.shopPrices == nil {
            return item.sp.isEmpty ? nil : try? JSONEncoder().encode(item.sp)
        }
        return try? JSONEncoder().encode(Extras(sp: item.sp, shops: item.shops, shopPrices: item.shopPrices))
    }

    private static func decode(_ data: Data?) -> Extras {
        guard let data else { return Extras(sp: []) }
        if let list = try? JSONDecoder().decode([SupplierPrice].self, from: data) { return Extras(sp: list) }
        return (try? JSONDecoder().decode(Extras.self, from: data)) ?? Extras(sp: [])
    }

    func update(from item: PriceItem) {
        cat = item.cat
        name = item.name
        price = item.price
        supplier = item.supplier
        aliasText = item.aliases.joined(separator: "\n")
        supplierPrices = StoredPrice.encode(item)
        unit = item.unit
    }

    var aliases: [String] {
        aliasText.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    var item: PriceItem {
        let extras = StoredPrice.decode(supplierPrices)
        let shops = extras.shops?.filter { !$0.isEmpty }
        let shopPrices = extras.shopPrices?.filter { !$0.shop.isEmpty && $0.p > 0 }
        return PriceItem(id: uid, cat: cat, name: name, price: price, supplier: supplier, aliases: aliases, sp: extras.sp, unit: unit,
                         shops: (shops?.isEmpty ?? true) ? nil : shops, shopPrices: (shopPrices?.isEmpty ?? true) ? nil : shopPrices)
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
