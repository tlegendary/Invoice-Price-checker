import Foundation

/// Something deleted, kept for 30 days so it can be brought back.
public struct BinItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    /// ISO 8601
    public var deletedAt: String
    public var invoice: HistoryEntry?
    public var payment: SupplierPayment?
    public var price: PriceItem?

    public init(id: String = UUID().uuidString, deletedAt: String = ISO8601DateFormatter().string(from: Date()),
                invoice: HistoryEntry? = nil, payment: SupplierPayment? = nil, price: PriceItem? = nil) {
        self.id = id
        self.deletedAt = deletedAt
        self.invoice = invoice
        self.payment = payment
        self.price = price
    }
}

/// One line in the history of changes: who did what, and when.
public struct ActivityEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case invoiceSaved, invoiceUpdated, invoiceDeleted, invoiceRestored
        case paymentRecorded, paymentRemoved, paymentRestored, markedPaid, markedUnpaid
        case priceAdded, priceChanged, priceDeleted, priceRestored
        case creditAsked, creditReceived, creditCleared
        case supplierChanged, backupRestored, binEmptied
    }

    public var id: String
    public var at: String
    public var action: Action
    /// What it was about: "Apex Foods · #2041", "Oil 20L".
    public var subject: String
    /// The amount involved, or for a price change the old price.
    public var amount: Double?
    public var newAmount: Double?
    /// Owner or staff, and which iPhone.
    public var by: String

    public init(id: String = UUID().uuidString, at: String = ISO8601DateFormatter().string(from: Date()), action: Action,
                subject: String, amount: Double? = nil, newAmount: Double? = nil, by: String = "") {
        self.id = id
        self.at = at
        self.action = action
        self.subject = subject
        self.amount = amount
        self.newAmount = newAmount
        self.by = by
    }

    enum CodingKeys: String, CodingKey { case id, at, action, subject, amount, newAmount, by }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id) ?? UUID().uuidString
        at = c.flexString(.at) ?? ""
        action = (try? c.decode(Action.self, forKey: .action)) ?? .supplierChanged
        subject = c.flexString(.subject) ?? ""
        amount = c.flexDouble(.amount)
        newAmount = c.flexDouble(.newAmount)
        by = c.flexString(.by) ?? ""
    }
}

public enum RecordKeeping {
    public static let binDays = 30
    public static let historyLimit = 2_000

    /// Drops what has been in the bin longer than 30 days. Returns what is kept and what went.
    public static func prune(_ bin: [BinItem], now: Date = Date()) -> (kept: [BinItem], gone: [BinItem]) {
        let cutoff = now.addingTimeInterval(-Double(binDays) * 86_400)
        let reader = ISO8601DateFormatter()
        var kept: [BinItem] = []
        var gone: [BinItem] = []
        for item in bin {
            if let date = reader.date(from: item.deletedAt), date < cutoff { gone.append(item) } else { kept.append(item) }
        }
        return (kept, gone)
    }

    /// Days left before something in the bin is gone for good.
    public static func daysLeft(_ item: BinItem, now: Date = Date()) -> Int {
        guard let date = ISO8601DateFormatter().date(from: item.deletedAt) else { return binDays }
        return max(0, binDays - Int(now.timeIntervalSince(date) / 86_400))
    }

    /// Newest first, at most `historyLimit`.
    public static func trimmed(_ history: [ActivityEntry]) -> [ActivityEntry] {
        Array(history.sorted { $0.at > $1.at }.prefix(historyLimit))
    }

    /// A short name for an invoice in the history: "Apex Foods · #2041".
    public static func subject(_ entry: HistoryEntry) -> String {
        let name = entry.supplier.isEmpty ? CoreText.t("Invoice") : entry.supplier
        return entry.invNo.isEmpty ? name : name + " · #" + entry.invNo
    }
}
