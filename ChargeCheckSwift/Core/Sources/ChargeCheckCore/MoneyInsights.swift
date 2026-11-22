import Foundation

// MARK: - VAT paid to suppliers, per quarter (for the VAT return)

public struct VATQuarter: Equatable, Identifiable, Sendable {
    public var id: String { "\(year)-Q\(quarter)" }
    public var year: Int
    /// 1–4 (calendar quarters: Jan–Mar …)
    public var quarter: Int
    public var invoices: Int
    public var net: Double
    public var vat: Double
    public var gross: Double
    /// VAT per supplier, most first.
    public var bySupplier: [(name: String, vat: Double)]

    public static func == (a: VATQuarter, b: VATQuarter) -> Bool {
        a.id == b.id && a.invoices == b.invoices && a.net == b.net && a.vat == b.vat && a.gross == b.gross
            && a.bySupplier.map(\.name) == b.bySupplier.map(\.name) && a.bySupplier.map(\.vat) == b.bySupplier.map(\.vat)
    }
}

public enum VATSummary {
    /// VAT on supplier invoices (total − net), by the invoice's own date, newest quarter first.
    /// Invoices billed twice are left out, and only `currency` is counted (amounts are never mixed).
    public static func quarters(_ entries: [HistoryEntry], currency: String, currencyOf: (HistoryEntry) -> String) -> [VATQuarter] {
        var buckets: [String: VATQuarter] = [:]
        var perSupplier: [String: [String: Double]] = [:]
        let calendar = ReportMaths.ukCalendar
        for entry in entries where entry.duplicateOf == nil && currencyOf(entry) == currency {
            guard let date = ReportMaths.date(of: entry) else { continue }
            let year = calendar.component(.year, from: date), quarter = (calendar.component(.month, from: date) - 1) / 3 + 1
            let key = "\(year)-Q\(quarter)"
            var q = buckets[key] ?? VATQuarter(year: year, quarter: quarter, invoices: 0, net: 0, vat: 0, gross: 0, bySupplier: [])
            let vat = max(0, entry.total - entry.net)
            q.invoices += 1
            q.net += entry.net
            q.vat += vat
            q.gross += entry.total
            buckets[key] = q
            perSupplier[key, default: [:]][entry.supplier, default: 0] += vat
        }
        return buckets.values.map { q in
            var out = q
            out.net = Money.round2(q.net)
            out.vat = Money.round2(q.vat)
            out.gross = Money.round2(q.gross)
            out.bySupplier = (perSupplier[q.id] ?? [:]).map { (name: $0.key, vat: Money.round2($0.value)) }
                .filter { $0.vat > 0.005 }
                .sorted { $0.vat != $1.vat ? $0.vat > $1.vat : $0.name < $1.name }
            return out
        }.sorted { ($0.year, $0.quarter) > ($1.year, $1.quarter) }
    }

    /// A spreadsheet of one quarter, invoice by invoice.
    public static func csv(_ entries: [HistoryEntry], quarter: VATQuarter, currency: String, currencyOf: (HistoryEntry) -> String) -> String {
        let calendar = ReportMaths.ukCalendar
        var rows = [[CoreText.t("Date"), CoreText.t("Supplier"), CoreText.t("Invoice no."), CoreText.t("Net"), CoreText.t("VAT"), CoreText.t("Total")]]
        let inQuarter = entries.filter { entry in
            guard entry.duplicateOf == nil, currencyOf(entry) == currency, let date = ReportMaths.date(of: entry) else { return false }
            return calendar.component(.year, from: date) == quarter.year && (calendar.component(.month, from: date) - 1) / 3 + 1 == quarter.quarter
        }.sorted { (ReportMaths.date(of: $0) ?? .distantPast) < (ReportMaths.date(of: $1) ?? .distantPast) }
        for entry in inQuarter {
            rows.append([entry.date, entry.supplier, entry.invNo, ReportMaths.amount(entry.net),
                         ReportMaths.amount(max(0, entry.total - entry.net)), ReportMaths.amount(entry.total)])
        }
        rows.append(["", CoreText.t("Total"), "", ReportMaths.amount(quarter.net), ReportMaths.amount(quarter.vat), ReportMaths.amount(quarter.gross)])
        return rows.map { $0.map(ReportMaths.cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - Spending by category

public struct CategorySpend: Equatable, Identifiable, Sendable {
    public var id: String { category }
    public var category: String
    public var thisMonth: Double
    public var lastMonth: Double
    /// % change from last month (nil when there was nothing last month).
    public var change: Double?
}

public enum Spending {
    /// "yyyy-MM" of an invoice, by its own date.
    static func month(of entry: HistoryEntry) -> String? {
        guard let date = ReportMaths.date(of: entry) else { return nil }
        let parts = ReportMaths.ukCalendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    static func monthKey(_ date: Date, offset: Int) -> String {
        let calendar = ReportMaths.ukCalendar
        let shifted = calendar.date(byAdding: .month, value: offset, to: date) ?? date
        let parts = calendar.dateComponents([.year, .month], from: shifted)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// What each line cost (before VAT), by the category of the item it matched; lines that matched nothing go
    /// under `other`. Missing or returned lines aren't counted.
    public static func byCategory(_ entries: [HistoryEntry], items: [PriceItem], other: String, now: Date = Date()) -> [CategorySpend] {
        let categories = Dictionary(items.map { ($0.id, $0.cat) }, uniquingKeysWith: { a, _ in a })
        let this = monthKey(now, offset: 0), last = monthKey(now, offset: -1)
        var sums: [String: (this: Double, last: Double)] = [:]
        for entry in entries where entry.duplicateOf == nil {
            guard let month = month(of: entry), month == this || month == last else { continue }
            for line in entry.lines where !line.excluded {
                let raw = line.matchId.flatMap { categories[$0] } ?? ""
                let category = raw.trimmingCharacters(in: .whitespaces).isEmpty ? other : raw
                let value = max(0, line.qty - line.short) * line.unit
                var sum = sums[category] ?? (0, 0)
                if month == this { sum.this += value } else { sum.last += value }
                sums[category] = sum
            }
        }
        return sums.map { category, sum in
            let change: Double? = sum.last > 0.005 ? ((sum.this - sum.last) / sum.last * 1000).rounded() / 10 : nil
            return CategorySpend(category: category, thisMonth: Money.round2(sum.this), lastMonth: Money.round2(sum.last), change: change)
        }.sorted { $0.thisMonth != $1.thisMonth ? $0.thisMonth > $1.thisMonth : $0.category < $1.category }
    }
}

// MARK: - Budgets

public struct Budget: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case supplier, category }
    public var id: String
    public var kind: Kind
    /// The supplier's or category's name.
    public var name: String
    /// A month's limit, before VAT for categories and with VAT for suppliers (what you pay them).
    public var monthly: Double

    public init(id: String = UUID().uuidString, kind: Kind, name: String, monthly: Double) {
        self.id = id
        self.kind = kind
        self.name = name
        self.monthly = monthly
    }
}

public struct BudgetStatus: Equatable, Identifiable, Sendable {
    public var id: String { budget.id }
    public var budget: Budget
    public var spent: Double
    /// spent ÷ limit × 100
    public var percent: Double
    public var warning: Bool { percent >= 80 }
    public var over: Bool { percent >= 100 }
}

public enum BudgetMaths {
    public static func status(_ budgets: [Budget], entries: [HistoryEntry], items: [PriceItem], other: String, now: Date = Date()) -> [BudgetStatus] {
        let this = Spending.monthKey(now, offset: 0)
        let month = entries.filter { $0.duplicateOf == nil && Spending.month(of: $0) == this }
        let spend = Dictionary(Spending.byCategory(month, items: items, other: other, now: now).map { ($0.category.lowercased(), $0.thisMonth) },
                               uniquingKeysWith: +)
        return budgets.filter { $0.monthly > 0 }.map { budget in
            let spent: Double
            switch budget.kind {
            case .supplier:
                spent = Money.round2(month.filter { TextTools.sameSupplier($0.supplier, budget.name) }.pennySum { $0.total })
            case .category:
                spent = spend[budget.name.lowercased()] ?? 0
            }
            return BudgetStatus(budget: budget, spent: spent, percent: (spent / budget.monthly * 1000).rounded() / 10)
        }.sorted { $0.percent > $1.percent }
    }
}

// MARK: - What a price rise costs a year

public enum RiseCost {
    /// The rise × how many you buy from that supplier in a typical year (from the last 90 days of invoices,
    /// scaled up). nil when it hasn't been bought in the last 90 days.
    public static func yearly(_ rise: PriceRise, entries: [HistoryEntry], now: Date = Date()) -> Double? {
        let since = now.addingTimeInterval(-90 * 86_400)
        let key = TextTools.norm(rise.item)
        var quantity = 0.0
        for entry in entries where entry.duplicateOf == nil && TextTools.sameSupplier(entry.supplier, rise.supplier) {
            guard let date = ReportMaths.date(of: entry), date >= since, date <= now.addingTimeInterval(86_400) else { continue }
            for line in entry.lines where !line.excluded && TextTools.norm(line.item.isEmpty ? line.desc : line.item) == key {
                quantity += max(0, line.qty - line.short)
            }
        }
        guard quantity > 0, rise.to > rise.from else { return nil }
        return Money.round2((rise.to - rise.from) * quantity * 365 / 90)
    }
}

// MARK: - Price per kg, litre or each

public struct UnitPrice: Equatable, Sendable {
    public enum Unit: String, Sendable { case kg, litre, each }
    public var value: Double
    public var unit: Unit
}

public enum UnitPrices {
    /// From the pack size in the name: "Chicken 9kg" → per kg; "Patties 48x113g" → per kg; "Oil 20L" → per litre;
    /// "Cups 4x50" or "Napkins x500" → each. nil when the name has no size.
    public static func of(name: String, price: Double) -> UnitPrice? {
        guard price > 0 else { return nil }
        let words = TextTools.norm(name).split(separator: " ").map(String.init)
        for word in words.reversed() {
            if let (amount, unit) = measure(word), amount > 0 { return UnitPrice(value: Money.round2(price / amount), unit: unit) }
        }
        let count = PackGuess.count(in: name)
        return count > 1 ? UnitPrice(value: (price / count * 1000).rounded() / 1000, unit: .each) : nil
    }

    /// "9kg" → (9, kg); "113g" → (0.113, kg); "48x113g" → (5.424, kg); "20l" / "500ml" → litres.
    static func measure(_ word: String) -> (Double, UnitPrice.Unit)? {
        var count = 1.0, rest = Substring(word)
        let sides = word.split(separator: "x", omittingEmptySubsequences: false)
        if sides.count == 2, let n = Double(sides[0]), n >= 1, sides[1].first?.isNumber == true {
            count = n
            rest = sides[1]
        }
        let number = rest.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number), value > 0 else { return nil }
        switch String(rest.dropFirst(number.count)) {
        case "kg", "kgs", "kilo": return (count * value, .kg)
        case "g", "gr", "grm": return (count * value / 1000, .kg)
        case "l", "lt", "ltr", "litre", "liter": return (count * value, .litre)
        case "ml": return (count * value / 1000, .litre)
        case "cl": return (count * value / 100, .litre)
        default: return nil
        }
    }
}

// MARK: - How fast a supplier sends credits

public struct CreditSpeed: Equatable, Sendable {
    /// Average days from asking to receiving, over the credits received.
    public var averageDays: Double?
    public var received: Int
    /// Asked more than 14 days ago and still not received.
    public var late: Int
}

public enum CreditSpeeds {
    public static func of(_ entries: [HistoryEntry], now: Date = Date()) -> CreditSpeed {
        let iso = ISO8601DateFormatter()
        func date(_ text: String?) -> Date? {
            guard let text else { return nil }
            return iso.date(from: text) ?? SupplierAccounts.day(String(text.prefix(10)))
        }
        var days: [Double] = [], late = 0
        for entry in entries {
            guard let credit = entry.credit, let asked = date(credit.at) else { continue }
            if credit.status == CreditInfo.received, let got = date(credit.paidAt), got >= asked {
                days.append(got.timeIntervalSince(asked) / 86_400)
            } else if credit.isOwed, now.timeIntervalSince(asked) > 14 * 86_400 {
                late += 1
            }
        }
        let average = days.isEmpty ? nil : (days.reduce(0, +) / Double(days.count) * 10).rounded() / 10
        return CreditSpeed(averageDays: average, received: days.count, late: late)
    }
}

// MARK: - Agreed prices with an end date

public struct DealEnding: Equatable, Identifiable, Sendable {
    public var id: String { supplier }
    public var supplier: String
    /// "yyyy-MM-dd"
    public var until: String
    /// Negative once it has passed.
    public var daysLeft: Int
}

public enum DealDates {
    /// Deals ending within `within` days, or already ended (up to 30 days ago), soonest first.
    public static func ending(_ deals: [String: String], within: Int = 14, now: Date = Date()) -> [DealEnding] {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: now)
        return deals.compactMap { supplier, until in
            guard let date = SupplierAccounts.day(until) else { return nil }
            let left = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
            guard left <= within, left >= -30 else { return nil }
            return DealEnding(supplier: supplier, until: until, daysLeft: left)
        }.sorted { $0.daysLeft != $1.daysLeft ? $0.daysLeft < $1.daysLeft : $0.supplier < $1.supplier }
    }
}

// MARK: - Your biggest items from a supplier (for renegotiating)

public struct BigItem: Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    /// A year's quantity at the rate of the last 90 days.
    public var yearlyQuantity: Double
    public var yearlySpend: Double
    public var lastPrice: Double
    /// The cheapest price paid to another supplier for the same item, when there is one.
    public var cheapestElsewhere: Double?
    public var elsewhereSupplier: String?
}

public enum BigItems {
    public static func of(supplier: String, entries: [HistoryEntry], limit: Int = 12, now: Date = Date()) -> [BigItem] {
        let since = now.addingTimeInterval(-90 * 86_400)
        var quantity: [String: Double] = [:], last: [String: (price: Double, when: String)] = [:], names: [String: String] = [:]
        for entry in entries where entry.duplicateOf == nil && TextTools.sameSupplier(entry.supplier, supplier) {
            guard let date = ReportMaths.date(of: entry), date >= since else { continue }
            for line in entry.lines where !line.excluded && line.qty > 0 {
                let name = line.item.isEmpty ? line.desc : line.item
                let key = TextTools.norm(name)
                quantity[key, default: 0] += max(0, line.qty - line.short)
                if names[key] == nil { names[key] = name }
                if (last[key]?.when ?? "") <= entry.savedAt { last[key] = (line.unit, entry.savedAt) }
            }
        }
        // the latest price each other supplier charged for the same item in the last year
        let yearAgo = now.addingTimeInterval(-365 * 86_400)
        var elsewhere: [String: [String: (price: Double, when: String, name: String)]] = [:]
        for entry in entries where entry.duplicateOf == nil && !entry.supplier.isEmpty && !TextTools.sameSupplier(entry.supplier, supplier) {
            guard let date = ReportMaths.date(of: entry), date >= yearAgo else { continue }
            let who = SupplierAccounts.key(entry.supplier)
            for line in entry.lines where !line.excluded && line.unit > 0 {
                let key = TextTools.norm(line.item.isEmpty ? line.desc : line.item)
                guard quantity[key] != nil else { continue }
                if (elsewhere[key]?[who]?.when ?? "") <= entry.savedAt {
                    elsewhere[key, default: [:]][who] = (line.unit, entry.savedAt, entry.supplier)
                }
            }
        }
        return quantity.compactMap { key, qty -> BigItem? in
            guard let price = last[key]?.price, price > 0 else { return nil }
            let yearly = qty * 365 / 90
            let other = elsewhere[key]?.values.filter { $0.price < price - 0.005 }.min { $0.price < $1.price }
            return BigItem(name: names[key] ?? key, yearlyQuantity: yearly.rounded(), yearlySpend: Money.round2(yearly * price),
                           lastPrice: price, cheapestElsewhere: other?.price, elsewhereSupplier: other?.name)
        }.sorted { $0.yearlySpend > $1.yearlySpend }.prefix(limit).map { $0 }
    }
}

// MARK: - Pack sizes

/// How many are in a pack, guessed from the item's name
/// ("Quarter Pounder 48x113g" → 48, "Cups 4x50" → 200, "Napkins x500" → 500, "Wings 10kg" → 1). Always editable.
public enum PackGuess {
    public static func count(in name: String) -> Double {
        let words = TextTools.norm(name).split(separator: " ").map(String.init)
        for word in words.reversed() {
            // "48x113g": 48 of 113 g; "4x50": 4 sleeves of 50
            let sides = word.split(separator: "x", omittingEmptySubsequences: false).map(String.init)
            if sides.count == 2, let left = Double(sides[0]), left >= 1 {
                if let right = Double(sides[1]), right >= 1 { return min(left * right, 10_000) }
                if !sides[1].isEmpty, sides[1].first?.isNumber == true { return min(left, 10_000) }
            }
            if sides.count == 2, sides[0].isEmpty, let right = Double(sides[1]), right >= 1 { return min(right, 10_000) }
            // "100pcs", "12pk"
            for unit in ["pcs", "pc", "pk", "pack"] where word.hasSuffix(unit) {
                if let n = Double(word.dropLast(unit.count)), n >= 1 { return min(n, 10_000) }
            }
        }
        return 1
    }
}
