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

/// A price agreed for one shop that differs from the item's standard price ("the pharmacy pays £3.20").
public struct ShopPrice: Codable, Equatable, Hashable, Sendable {
    public var shop: String
    public var p: Double

    public init(shop: String, p: Double) {
        self.shop = shop
        self.p = p
    }

    enum CodingKeys: String, CodingKey { case shop, p }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shop = c.flexString(.shop) ?? ""
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
    /// The shops this item is bought for. nil or empty = every shop (all items saved before shops had their own
    /// lists). Shops can be different trades (food, medicine), so each keeps to its own items.
    public var shops: [String]?
    /// Prices agreed for one shop that differ from the standard price.
    public var shopPrices: [ShopPrice]?
    /// Selling at the till: price, units per pack, barcodes, reorder level (nil = not sold at the till).
    public var till: TillInfo?

    public init(id: String = UUID().uuidString, cat: String = "Other", name: String, price: Double,
                supplier: String = "", aliases: [String] = [], sp: [SupplierPrice] = [], unit: String? = nil,
                shops: [String]? = nil, shopPrices: [ShopPrice]? = nil, till: TillInfo? = nil) {
        self.id = id
        self.cat = cat
        self.name = name
        self.price = price
        self.supplier = supplier
        self.aliases = aliases
        self.sp = sp
        self.unit = unit
        self.shops = shops
        self.shopPrices = shopPrices
        self.till = (till?.isEmpty ?? true) ? nil : till
    }

    enum CodingKeys: String, CodingKey { case id, cat, name, price, supplier, aliases, sp, unit, shops, shopPrices, till }

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
        let tags = (try? c.decode([String].self, forKey: .shops))?.filter { !$0.isEmpty }
        shops = (tags?.isEmpty ?? true) ? nil : tags
        let own = (try? c.decode([ShopPrice].self, forKey: .shopPrices))?.filter { !$0.shop.isEmpty && $0.p > 0 }
        shopPrices = (own?.isEmpty ?? true) ? nil : own
        let sold = try? c.decode(TillInfo.self, forKey: .till)
        till = (sold?.isEmpty ?? true) ? nil : sold
    }

    /// Whether this item is bought for that shop ("" = all shops: every item counts).
    public func isIn(shop: String) -> Bool {
        guard !shop.isEmpty, let shops, !shops.isEmpty else { return true }
        return shops.contains(shop)
    }

    /// The item's price in one shop: that shop's own price if it has one, otherwise the standard price.
    public func price(inShop shop: String) -> Double {
        guard !shop.isEmpty else { return price }
        return shopPrices?.first(where: { $0.shop == shop })?.p ?? price
    }

    /// The price to compare with: this supplier's agreed price if there is one, otherwise the shop's own price,
    /// otherwise the standard price.
    public func basePrice(for supplierName: String, shop: String = "") -> Double {
        sp.first(where: { TextTools.sameSupplier($0.s, supplierName) })?.p ?? price(inShop: shop)
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
    /// The supplier won't credit it: no longer owed, and never counted as money won back.
    public static let writtenOff = "writtenOff"

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

    /// Everything about what to pay for this invoice, worked out once so every screen shows the same figures
    /// and they always add up: deductions come off the amount before VAT first, then the VAT on them comes off the VAT.
    public var payment: PayBreakdown { PayBreakdown(self) }

    /// What to send the supplier: the invoice total less overcharges and missing items (VAT included).
    public var amountToPay: (total: Double, less: Double, pay: Double) {
        let p = payment
        return (p.total, p.less, p.pay)
    }

    /// The same, before VAT: the net invoice total, less overcharges and missing items (without their VAT).
    /// For shops that aren't VAT registered, or anyone who wants to see the figures without VAT.
    public var amountToPayBeforeVat: (total: Double, less: Double, pay: Double) {
        let p = payment
        return (p.net, p.lessNet, p.payNet)
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
    /// Orders sent to suppliers. Older versions of the app ignore this.
    public var orders: [PurchaseOrder]?
    /// Monthly budgets, and when each supplier's agreed prices end (supplier name → "yyyy-MM-dd").
    public var budgets: [Budget]?
    public var deals: [String: String]?
    /// The till's stock counts (the sales themselves are files of their own, in iCloud next to the backup).
    public var stockCounts: [StockCount]?

    public init(baseline: [PriceItem], history: [HistoryEntry] = [], settings: BackupSettings? = nil, scans: ScanCredits? = nil,
                payments: [SupplierPayment]? = nil, trusted: [String]? = nil, creditDays: [String: Int]? = nil,
                currencies: [String: String]? = nil, orders: [PurchaseOrder]? = nil,
                budgets: [Budget]? = nil, deals: [String: String]? = nil, stockCounts: [StockCount]? = nil) {
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
        self.orders = orders
        self.budgets = budgets
        self.deals = deals
        self.stockCounts = stockCounts
    }

    enum CodingKeys: String, CodingKey { case app, v, savedAt, baseline, history, settings, scans, payments, trusted, creditDays, currencies, orders, budgets, deals, stockCounts }

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
        orders = try? c.decode([PurchaseOrder].self, forKey: .orders)
        budgets = try? c.decode([Budget].self, forKey: .budgets)
        deals = try? c.decode([String: String].self, forKey: .deals)
        stockCounts = try? c.decode([StockCount].self, forKey: .stockCounts)
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

/// What to pay for one invoice, before VAT and with it.
///
/// - The invoice: `net` + `vat` = `total` (the VAT is the printed total less the printed net).
/// - Taken off: overcharges and missing or returned items, before VAT (`lessNet`), and the VAT on them (`lessVat`).
///   The VAT on them comes from each line's own VAT rate. When the invoice's lines were read without VAT rates but
///   the invoice has VAT, it's the invoice's own VAT share instead (`vatFromShare`), so an overcharge never comes
///   off the total with VAT while its VAT stays in.
/// - To pay: `payNet` + `payVat` = `pay`, to the penny, and `less` + `pay` = `total`.
public struct PayBreakdown: Equatable, Sendable {
    public var net: Double
    public var vat: Double
    public var total: Double
    /// Overcharges before VAT, and their VAT.
    public var over: Double
    public var overVat: Double
    /// Missing or returned items before VAT, and their VAT.
    public var missing: Double
    public var missingVat: Double
    public var lessNet: Double
    public var lessVat: Double
    public var less: Double
    public var payNet: Double
    public var payVat: Double
    public var pay: Double
    /// The VAT taken off was worked out from the invoice's VAT share (its lines had no VAT rates).
    public var vatFromShare: Bool

    public init(_ entry: HistoryEntry) {
        // the invoice itself: a total can't be below its net (a misread); then there's no VAT to split
        let printedTotal = Money.round2(max(0, entry.total))
        var net = Money.round2(max(0, entry.net))
        if net <= 0.004 || net > printedTotal + 0.004 { net = printedTotal }
        let vat = Money.round2(printedTotal - net)
        total = printedTotal
        self.net = net
        self.vat = vat

        // what comes off, before VAT
        let overNet = Money.round2(max(0, entry.over))
        let missingNet = Money.round2(max(0, entry.excluded))
        var lineMissingVat = 0.0
        var linesWithVat = false
        for line in entry.lines {
            if line.vat > 0 { linesWithVat = true }
            let gone = line.excluded ? line.qty : line.short
            guard gone > 0 else { continue }
            lineMissingVat += Money.round2(Money.round2(gone * line.unit) * line.vat / 100)
        }
        let lessNet = min(net, Money.round2(overNet + missingNet))
        // keep the split between overcharges and missing items when the net cap bites
        over = min(overNet, lessNet)
        missing = Money.round2(lessNet - over)

        // and the VAT on it
        vatFromShare = vat > 0.004 && !linesWithVat && lessNet > 0.004
        if vatFromShare {
            let share = vat / net
            overVat = Money.round2(over * share)
            missingVat = Money.round2(missing * share)
        } else {
            overVat = Money.round2(max(0, entry.overVat))
            missingVat = Money.round2(lineMissingVat)
        }
        var lessVat = Money.round2(overVat + missingVat)
        if lessVat > vat {
            // never more VAT off than the invoice has
            lessVat = vat
            overVat = min(overVat, vat)
            missingVat = Money.round2(vat - overVat)
        }
        self.lessNet = lessNet
        self.lessVat = lessVat
        less = Money.round2(lessNet + lessVat)
        payNet = Money.round2(net - lessNet)
        payVat = Money.round2(vat - lessVat)
        pay = Money.round2(payNet + payVat)
    }

    /// Overcharges with their VAT.
    public var overWithVat: Double { Money.round2(over + overVat) }
}
