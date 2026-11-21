import Foundation

/// How a supplier is doing: what you buy, how accurate their invoices and deliveries are, and a score out of 100.
public struct SupplierProfile: Equatable, Sendable {
    /// Each part of the score, 0–100. nil when there isn't enough to judge it.
    public struct Part: Equatable, Sendable {
        public var invoiceAccuracy: Double?
        public var deliveryAccuracy: Double?
        public var priceStability: Double?
        public var priceCompetitiveness: Double?
    }

    public var invoices: Int
    public var purchasesThisMonth: Double
    public var purchasesLastMonth: Double
    public var averageInvoice: Double
    /// All their invoices together, with VAT.
    public var totalBought: Double
    public var overcharged: Double
    public var missing: Double
    /// Invoices with an overcharge or missing goods.
    public var disputed: Int
    /// Credits asked for and still owed.
    public var creditsOwed: Double
    public var risesLast90Days: Int
    public var parts: Part
    /// nil until there are at least `minimumInvoices` checked invoices.
    public var score: Int?

    public static let minimumInvoices = 3
}

public enum SupplierProfiles {
    /// `all` is every invoice (other suppliers too), for comparing prices.
    public static func make(_ account: SupplierAccount, all: [HistoryEntry], now: Date = Date()) -> SupplierProfile {
        let entries = account.entries
        let month = String(SupplierAccounts.dayText(now).prefix(7))
        let lastMonthDate = Calendar(identifier: .gregorian).date(byAdding: .month, value: -1, to: now) ?? now
        let lastMonth = String(SupplierAccounts.dayText(lastMonthDate).prefix(7))
        let total = entries.reduce(0) { $0 + $1.amountToPay.total }
        let caught = entries.map { OverviewMaths.caught($0) }

        // invoice accuracy: share of price-checked lines charged at (or below) the agreed price
        let checked = entries.filter { !$0.totalOnly }
        let priced = checked.flatMap { $0.lines }.filter { !$0.excluded && $0.base != nil }
        let invoiceAccuracy: Double? = priced.count >= 5
            ? Double(priced.filter { $0.over <= 0.005 }.count) / Double(priced.count) * 100 : nil

        // delivery accuracy: share of lines that arrived in full
        let lines = checked.flatMap { $0.lines }.filter { $0.qty > 0 }
        let deliveryAccuracy: Double? = lines.count >= 5
            ? Double(lines.filter { !$0.excluded && $0.short <= 0 }.count) / Double(lines.count) * 100 : nil

        // price stability: of the items bought in the last 90 days, the share that didn't go up
        let since = SupplierAccounts.dayText(now.addingTimeInterval(-90 * 86_400))
        let rises = Insights.priceRises(entries, since: since)
        var recentItems = Set<String>()
        for entry in checked where String(entry.savedAt.prefix(10)) >= since {
            for line in entry.lines where !line.excluded && line.unit > 0 {
                if let key = Insights.itemKey(matchId: line.matchId, name: line.item.isEmpty ? line.desc : line.item) { recentItems.insert(key) }
            }
        }
        let risenItems = Set(rises.map { SupplierAccounts.key($0.item) }).count
        let priceStability: Double? = recentItems.count >= 3
            ? max(0, Double(recentItems.count - min(risenItems, recentItems.count)) / Double(recentItems.count) * 100) : nil

        // price competitiveness: of the items you also buy elsewhere, the share where their latest price is the cheapest (within 1%)
        let compare = competition(all, supplier: account.id)
        let competitiveness: Double? = compare.shared >= 2 ? Double(compare.cheapest) / Double(compare.shared) * 100 : nil

        let parts = SupplierProfile.Part(invoiceAccuracy: invoiceAccuracy.map(round1), deliveryAccuracy: deliveryAccuracy.map(round1),
                                         priceStability: priceStability.map(round1), priceCompetitiveness: competitiveness.map(round1))
        let weighted: [(Double?, Double)] = [(invoiceAccuracy, 0.3), (deliveryAccuracy, 0.25), (priceStability, 0.2), (competitiveness, 0.25)]
        let known = weighted.compactMap { value, weight in value.map { ($0, weight) } }
        let weight = known.reduce(0) { $0 + $1.1 }
        let score: Int? = (checked.count >= SupplierProfile.minimumInvoices && weight > 0)
            ? Int((known.reduce(0) { $0 + $1.0 * $1.1 } / weight).rounded()) : nil

        return SupplierProfile(
            invoices: entries.count,
            purchasesThisMonth: Money.round2(entries.filter { $0.savedAt.hasPrefix(month) }.reduce(0) { $0 + $1.amountToPay.total }),
            purchasesLastMonth: Money.round2(entries.filter { $0.savedAt.hasPrefix(lastMonth) }.reduce(0) { $0 + $1.amountToPay.total }),
            averageInvoice: entries.isEmpty ? 0 : Money.round2(total / Double(entries.count)),
            totalBought: Money.round2(total),
            overcharged: Money.round2(caught.reduce(0) { $0 + $1.overcharges }),
            missing: Money.round2(caught.reduce(0) { $0 + $1.missing }),
            disputed: caught.filter { $0.overcharges + $0.missing > 0.005 }.count,
            creditsOwed: Money.round2(entries.compactMap { $0.credit }.filter { $0.isOwed }.reduce(0) { $0 + $1.amount }),
            risesLast90Days: rises.count,
            parts: parts,
            score: score)
    }

    /// Items this supplier sells you that you also buy from someone else, and how many of those they are cheapest for.
    static func competition(_ all: [HistoryEntry], supplier key: String) -> (shared: Int, cheapest: Int) {
        // item -> supplier -> latest price
        var latest: [String: [String: Double]] = [:]
        for entry in all.sorted(by: { $0.savedAt > $1.savedAt }) where !entry.totalOnly && !entry.supplier.isEmpty {
            let who = SupplierAccounts.key(entry.supplier)
            for line in entry.lines where !line.excluded && line.unit > 0 {
                guard let item = Insights.itemKey(matchId: line.matchId, name: line.item.isEmpty ? line.desc : line.item) else { continue }
                if latest[item]?[who] == nil { latest[item, default: [:]][who] = line.unit }
            }
        }
        var shared = 0
        var cheapest = 0
        for prices in latest.values where prices.count > 1 {
            guard let mine = prices[key], let others = prices.filter({ $0.key != key }).values.min() else { continue }
            shared += 1
            if mine <= others * 1.01 { cheapest += 1 }
        }
        return (shared, cheapest)
    }

    static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    /// Ranks every supplier with a score, best first.
    public static func ranked(_ accounts: [SupplierAccount], all: [HistoryEntry], now: Date = Date()) -> [(name: String, score: Int)] {
        accounts.compactMap { account in make(account, all: all, now: now).score.map { (account.name, $0) } }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
    }
}
