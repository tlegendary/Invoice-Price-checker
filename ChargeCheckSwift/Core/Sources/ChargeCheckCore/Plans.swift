import Foundation

/// What someone has paid for. Each tier includes everything below it.
public enum Tier: Int, Comparable, Sendable {
    /// Nothing bought: one ad per scan, the last 30 days of invoices.
    case free
    /// Bought at least one scan pack.
    case packs
    /// Monthly or yearly subscription.
    case pro

    public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
}

/// Features that need a scan pack or Pro. Everything not listed here is free.
public enum Feature: String, CaseIterable, Identifiable, Sendable {
    // any scan pack bought
    case fullHistory, exports, creditPDF, deliveryCheck, statementCheck
    // Pro only
    case moneyLeaks, priceRises, cheaperElsewhere, supplierScores, supplierReport, dueDates, payRun,
         weeklyReminder, shops, staff, widget, smartCheck, monthlySummary, changeHistory

    public var id: String { rawValue }

    public var tier: Tier {
        switch self {
        case .fullHistory, .exports, .creditPDF, .deliveryCheck, .statementCheck: return .packs
        default: return .pro
        }
    }

    /// The free version keeps this many days of invoices in its lists.
    public static let freeHistoryDays = 30
}

public enum Plans {
    public static func allows(_ feature: Feature, tier: Tier) -> Bool {
        tier >= feature.tier
    }

    /// The invoices a tier may list: everything, or the free version's last 30 days.
    public static func visible(_ entries: [HistoryEntry], tier: Tier, now: Date = Date()) -> [HistoryEntry] {
        guard !allows(.fullHistory, tier: tier) else { return entries }
        let since = SupplierAccounts.dayText(now.addingTimeInterval(-Double(Feature.freeHistoryDays) * 86_400))
        return entries.filter { String($0.savedAt.prefix(10)) >= since }
    }

    /// How many invoices are older than the free version shows.
    public static func hidden(_ entries: [HistoryEntry], tier: Tier, now: Date = Date()) -> Int {
        entries.count - visible(entries, tier: tier, now: now).count
    }
}
