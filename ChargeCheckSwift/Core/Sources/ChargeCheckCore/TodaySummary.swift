import Foundation

/// The Home screen's "Today" card: the till's figures since the day was last closed (the same numbers as the
/// end-of-day report) and what's running low.
public struct TodaySummary: Equatable, Sendable {
    public var sales: Int
    public var refunds: Int
    public var takings: Double
    public var cash: Double
    public var card: Double
    /// Gift cards, tabs, vouchers and other ways of paying.
    public var other: Double
    /// Items at or below their low-stock level, the shortest first (at most `shown`).
    public var low: [StockLevel]
    public var lowCount: Int

    public static let shown = 3

    public init(report: DayReport, levels: [StockLevel]) {
        self.init(sales: report.sales, refunds: report.refunds, takings: report.takings, cash: report.cash,
                  card: report.card, other: report.other, levels: levels)
    }

    public init(sales: Int, refunds: Int, takings: Double, cash: Double, card: Double, other: Double,
                levels: [StockLevel]) {
        self.sales = sales
        self.refunds = refunds
        self.takings = takings
        self.cash = cash
        self.card = card
        self.other = other
        let short = levels.filter(\.isLow)
            .sorted { ($0.onHand - ($0.low ?? 0), $0.name.lowercased()) < ($1.onHand - ($1.low ?? 0), $1.name.lowercased()) }
        lowCount = short.count
        low = Array(short.prefix(Self.shown))
    }

    /// Nothing sold yet in this day.
    public var quiet: Bool { sales == 0 && refunds == 0 }
}
