import Foundation

/// Money as a whole number of pence (cents, fils…): adding and subtracting can never drift by a fraction of a penny.
/// Amounts still travel as pounds (`Double`) between screens; totals are added up here.
public struct Pence: Hashable, Comparable, Codable, Sendable {
    public var value: Int

    public init(value: Int) { self.value = value }

    /// From pounds, to the nearest penny (halves away from zero, as `Money.round2`). nil when it isn't a number.
    public init?(_ pounds: Double) {
        guard pounds.isFinite, abs(pounds) < 1e13 else { return nil }
        value = Int((Money.round2(pounds) * 100).rounded())
    }

    public var pounds: Double { Double(value) / 100 }

    public static func < (a: Pence, b: Pence) -> Bool { a.value < b.value }
    public static func + (a: Pence, b: Pence) -> Pence { Pence(value: a.value + b.value) }
    public static func - (a: Pence, b: Pence) -> Pence { Pence(value: a.value - b.value) }
    public static let zero = Pence(value: 0)
}

public extension Sequence {
    /// Adds up money exactly: each amount to the penny, added in whole pence, the total back in pounds.
    /// A figure that isn't a number makes the total not a number too, so it's never silently left out.
    func pennySum(_ amount: (Element) -> Double) -> Double {
        var total = 0
        for element in self {
            guard let pence = Pence(amount(element)) else { return .nan }
            total += pence.value
        }
        return Pence(value: total).pounds
    }
}
