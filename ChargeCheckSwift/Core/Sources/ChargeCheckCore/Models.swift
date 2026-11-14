import Foundation

// These match the backup file the first (web-based) version of the app writes,
// so prices and reports carry over when the Swift version replaces it.

extension KeyedDecodingContainer {
    func flexDouble(_ key: Key) -> Double? {
        if let d = try? decode(Double.self, forKey: key) { return d }
        if let s = try? decode(String.self, forKey: key) { return Money.parse(s) }
        return nil
    }

    func flexString(_ key: Key) -> String? {
        if let s = try? decode(String.self, forKey: key) { return s }
        if let d = try? decode(Double.self, forKey: key) {
            return d == d.rounded() ? String(Int(d)) : String(d)
        }
        return nil
    }

    func flexBool(_ key: Key) -> Bool? {
        if let b = try? decode(Bool.self, forKey: key) { return b }
        return nil
    }
}

/// A special price agreed with one supplier.
public struct SupplierPrice: Codable, Equatable, Hashable, Sendable {
    public var s: String
    public var p: Double

    public init(s: String, p: Double) {
        self.s = s
        self.p = p
    }

    enum CodingKeys: String, CodingKey { case s, p }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        s = c.flexString(.s) ?? ""
        p = c.flexDouble(.p) ?? 0
    }
}

/// One line of the agreed price list.
public struct PriceItem: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var cat: String
    public var name: String
    public var price: Double
    public var supplier: String
    /// How the item is written on invoices ("quater pounder", "prime wing").
    public var aliases: [String]
    public var sp: [SupplierPrice]
    public var unit: String?

    public init(id: String = UUID().uuidString, cat: String = "Other", name: String, price: Double,
                supplier: String = "", aliases: [String] = [], sp: [SupplierPrice] = [], unit: String? = nil) {
        self.id = id
        self.cat = cat
        self.name = name
        self.price = price
        self.supplier = supplier
        self.aliases = aliases
        self.sp = sp
        self.unit = unit
    }

    enum CodingKeys: String, CodingKey { case id, cat, name, price, supplier, aliases, sp, unit }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id) ?? UUID().uuidString
        let rawCat = (c.flexString(.cat) ?? "").trimmingCharacters(in: .whitespaces)
        cat = rawCat.isEmpty ? "Other" : rawCat
        name = c.flexString(.name) ?? ""
        price = Money.round2(c.flexDouble(.price) ?? 0)
        supplier = c.flexString(.supplier) ?? ""
        aliases = (try? c.decode([String].self, forKey: .aliases)) ?? []
        sp = (try? c.decode([SupplierPrice].self, forKey: .sp)) ?? []
        unit = c.flexString(.unit)
    }

    /// The price to compare with: this supplier's agreed price if there is one, otherwise the standard price.
    public func basePrice(for supplierName: String) -> Double {
        sp.first(where: { TextTools.sameSupplier($0.s, supplierName) })?.p ?? price
    }
}

public struct HistoryLine: Codable, Equatable, Sendable {
    public var qty: Double
    public var desc: String
    public var unit: Double
    public var vat: Double
    public var matchId: String?
    public var item: String
    public var base: Double?
    public var over: Double
    public var excluded: Bool
    public var noBase: Bool
    /// How many didn't arrive (delivery check).
    public var short: Double

    public init(qty: Double, desc: String, unit: Double, vat: Double = 0, matchId: String? = nil, item: String = "",
                base: Double? = nil, over: Double = 0, excluded: Bool = false, noBase: Bool = false, short: Double = 0) {
        self.qty = qty
        self.desc = desc
        self.unit = unit
        self.vat = vat
        self.matchId = matchId
        self.item = item
        self.base = base
        self.over = over
        self.excluded = excluded
        self.noBase = noBase
        self.short = short
    }

    enum CodingKeys: String, CodingKey { case qty, desc, unit, vat, matchId, item, base, over, excluded, noBase, short }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        qty = c.flexDouble(.qty) ?? 1
        desc = c.flexString(.desc) ?? ""
        unit = c.flexDouble(.unit) ?? 0
        vat = c.flexDouble(.vat) ?? 0
        matchId = c.flexString(.matchId)
        item = c.flexString(.item) ?? ""
        base = c.flexDouble(.base)
        over = c.flexDouble(.over) ?? 0
        excluded = c.flexBool(.excluded) ?? false
        noBase = c.flexBool(.noBase) ?? false
        short = c.flexDouble(.short) ?? 0
    }
}

public struct CreditInfo: Codable, Equatable, Sendable {
    public var status: String
    public var amount: Double
    public var at: String?
    public var paidAt: String?

    enum CodingKeys: String, CodingKey { case status, amount, at, paidAt }

    public static let requested = "requested"
    public static let received = "received"

    public init(status: String, amount: Double, at: String? = nil, paidAt: String? = nil) {
        self.status = status
        self.amount = amount
        self.at = at
        self.paidAt = paidAt
    }

    public var isOwed: Bool { status == CreditInfo.requested }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.flexString(.status) ?? "requested"
        amount = c.flexDouble(.amount) ?? 0
        at = c.flexString(.at)
        paidAt = c.flexString(.paidAt)
    }
}

/// One checked invoice, as kept in Reports.
public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var savedAt: String
    public var shopId: String
    public var supplier: String
    public var invNo: String
    public var date: String
    public var net: Double
    public var total: Double
    public var over: Double
    public var overVat: Double
    public var excluded: Double
    public var verified: Bool
    public var paid: String?
    public var file: String?
    public var credit: CreditInfo?
    public var lines: [HistoryLine]
    /// A trusted supplier's invoice: only the total was read, the prices weren't checked.
    public var totalOnly: Bool
    /// The currency of the amounts ("GBP", "IQD" …), saved with new invoices so they never change meaning.
    /// nil on invoices saved before this was kept.
    public var currency: String?
    /// The supplier billed this invoice twice: the id of the saved invoice it repeats. Shown under Needs attention.
    public var duplicateOf: String?

    public init(id: String = UUID().uuidString, savedAt: String = ISO8601DateFormatter().string(from: Date()), shopId: String = "",
                supplier: String, invNo: String = "", date: String = "", net: Double, total: Double, over: Double, overVat: Double = 0,
                excluded: Double = 0, verified: Bool = true, paid: String? = nil, file: String? = nil, credit: CreditInfo? = nil, lines: [HistoryLine],
                totalOnly: Bool = false, currency: String? = nil, duplicateOf: String? = nil) {
        self.id = id
        self.savedAt = savedAt
        self.shopId = shopId
        self.supplier = supplier
        self.invNo = invNo
        self.date = date
        self.net = net
        self.total = total
        self.over = over
        self.overVat = overVat
        self.excluded = excluded
        self.verified = verified
        self.paid = paid
        self.file = file
        self.credit = credit
        self.lines = lines
        self.totalOnly = totalOnly
        self.currency = currency
        self.duplicateOf = duplicateOf
    }

    enum CodingKeys: String, CodingKey {
        case id, savedAt, shopId, supplier, invNo, date, net, total, over, overVat, excluded, verified, paid, file, credit, lines, totalOnly,
             currency, duplicateOf
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.id) ?? UUID().uuidString
        savedAt = c.flexString(.savedAt) ?? ""
        shopId = c.flexString(.shopId) ?? ""
        supplier = c.flexString(.supplier) ?? ""
        invNo = c.flexString(.invNo) ?? ""
        date = c.flexString(.date) ?? ""
        net = c.flexDouble(.net) ?? 0
        total = c.flexDouble(.total) ?? (c.flexDouble(.net) ?? 0)
        over = c.flexDouble(.over) ?? 0
        overVat = c.flexDouble(.overVat) ?? 0
        excluded = c.flexDouble(.excluded) ?? 0
        verified = c.flexBool(.verified) ?? true
        paid = c.flexString(.paid)
        file = c.flexString(.file)
        credit = try? c.decode(CreditInfo.self, forKey: .credit)
        lines = (try? c.decode([HistoryLine].self, forKey: .lines)) ?? []
        totalOnly = c.flexBool(.totalOnly) ?? false
        currency = c.flexString(.currency)
        duplicateOf = c.flexString(.duplicateOf).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What to send the supplier: the invoice total less overcharges and missing items (VAT included).
    public var amountToPay: (total: Double, less: Double, pay: Double) {
        let missingVat = lines.reduce(0.0) { sum, line in
            let gone = line.excluded ? line.qty : line.short
            guard gone > 0 else { return sum }
            return sum + Money.round2(Money.round2(gone * line.unit) * line.vat / 100)
        }
        let less = min(total, Money.round2(over + overVat + excluded + missingVat))
        return (Money.round2(total), less, Money.round2(total - less))
    }

    /// The same, before VAT: the net invoice total, less overcharges and missing items (without their VAT).
    /// For shops that aren't VAT registered, or anyone who wants to see the figures without VAT.
    public var amountToPayBeforeVat: (total: Double, less: Double, pay: Double) {
        let total = Money.round2(net)
        let less = min(total, Money.round2(over + excluded))
        return (total, less, Money.round2(total - less))
    }

    /// What to pay for this invoice, with or without VAT.
    public func amountToPay(beforeVat: Bool) -> (total: Double, less: Double, pay: Double) {
        beforeVat ? amountToPayBeforeVat : amountToPay
    }
}

public struct ShopInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct BackupSettings: Codable, Equatable, Sendable {
    public var biz: String?
    public var tol: Double?
    public var shops: [ShopInfo]?
    public var shop: String?
    public var mode: String?
    public var color: String?
    public var keepCopy: String?

    public init() {}

    enum CodingKeys: String, CodingKey { case biz, tol, shops, shop, mode, color, keepCopy }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        biz = c.flexString(.biz)
        tol = c.flexDouble(.tol)
        shops = try? c.decode([ShopInfo].self, forKey: .shops)
        shop = c.flexString(.shop)
        mode = c.flexString(.mode)
        color = c.flexString(.color)
        keepCopy = c.flexString(.keepCopy)
    }
}

public struct ScanCredits: Codable, Equatable, Sendable {
    public var n: Int
    public var dev: String?
    /// A scan pack was bought on that phone.
    public var bought: Bool?

    public init(n: Int, dev: String?, bought: Bool? = nil) {
        self.n = n
        self.dev = dev
        self.bought = bought
    }
}

/// A whole backup: price list, reports, settings and unused scans.
public struct BackupFile: Codable, Equatable, Sendable {
    public var app: String?
    public var v: Int?
    public var savedAt: String?
    public var baseline: [PriceItem]
    public var history: [HistoryEntry]
    public var settings: BackupSettings?
    public var scans: ScanCredits?
    /// Payments, credits and starting balances (added with supplier accounts).
    public var payments: [SupplierPayment]?
    /// Suppliers whose invoices are only totalled, not price-checked.
    public var trusted: [String]?
    /// Each supplier's credit period in days, keyed by SupplierAccounts.key.
    public var creditDays: [String: Int]?
    /// Suppliers who invoice in another currency: SupplierAccounts.key → "USD".
    public var currencies: [String: String]?

    public init(baseline: [PriceItem], history: [HistoryEntry] = [], settings: BackupSettings? = nil, scans: ScanCredits? = nil,
                payments: [SupplierPayment]? = nil, trusted: [String]? = nil, creditDays: [String: Int]? = nil,
                currencies: [String: String]? = nil) {
        self.app = "ChargeCheck"
        self.v = 3
        self.savedAt = ISO8601DateFormatter().string(from: Date())
        self.baseline = baseline
        self.history = history
        self.settings = settings
        self.scans = scans
        self.payments = payments
        self.trusted = trusted
        self.creditDays = creditDays
        self.currencies = currencies
    }

    enum CodingKeys: String, CodingKey { case app, v, savedAt, baseline, history, settings, scans, payments, trusted, creditDays, currencies }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = c.flexString(.app)
        v = try? c.decode(Int.self, forKey: .v)
        savedAt = c.flexString(.savedAt)
        baseline = try c.decode([PriceItem].self, forKey: .baseline)
        history = (try? c.decode([HistoryEntry].self, forKey: .history)) ?? []
        settings = try? c.decode(BackupSettings.self, forKey: .settings)
        scans = try? c.decode(ScanCredits.self, forKey: .scans)
        payments = try? c.decode([SupplierPayment].self, forKey: .payments)
        trusted = try? c.decode([String].self, forKey: .trusted)
        creditDays = try? c.decode([String: Int].self, forKey: .creditDays)
        currencies = try? c.decode([String: String].self, forKey: .currencies)
    }

    public enum ReadError: Error { case notABackup }

    /// Reads a backup file. Also accepts a bare list of prices.
    public static func read(_ data: Data) throws -> BackupFile {
        let decoder = JSONDecoder()
        if let full = try? decoder.decode(BackupFile.self, from: data) {
            var clean = full
            clean.baseline = full.baseline.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            return clean
        }
        if let list = try? decoder.decode([PriceItem].self, from: data) {
            return BackupFile(baseline: list.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })
        }
        throw ReadError.notABackup
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
