import Foundation

/// Stock sent from one shop to another: it leaves when sent, and arrives only when the other shop says it did.
public struct StockTransfer: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var itemID: String
    public var name: String
    public var units: Double
    public var from: String
    public var to: String
    public var sentAt: String
    public var sentBy: String?
    /// Set when it arrives: what actually came (it can differ from what was sent).
    public var received: Double?
    public var receivedAt: String?
    public var receivedBy: String?

    public init(id: String = UUID().uuidString, itemID: String, name: String, units: Double, from: String, to: String,
                sentAt: String, sentBy: String? = nil) {
        self.id = id
        self.itemID = itemID
        self.name = name
        self.units = units
        self.from = from
        self.to = to
        self.sentAt = sentAt
        self.sentBy = sentBy
    }

    public var inTransit: Bool { received == nil }
    /// Sent but didn't arrive (negative: more arrived than was sent).
    public var missing: Double { received.map { units - $0 } ?? 0 }
}

public enum Transfers {
    /// Marks a transfer as arrived (once: a second answer changes nothing).
    public static func receive(_ transfer: StockTransfer, units: Double, by: String?, at: String) -> StockTransfer {
        guard transfer.inTransit, units >= 0 else { return transfer }
        var t = transfer
        t.received = units
        t.receivedAt = at
        t.receivedBy = by
        return t
    }

    /// The same transfer from several tills: the one that says it arrived wins (arriving can't be undone).
    public static func merge(_ lists: [[StockTransfer]]) -> [StockTransfer] {
        var out: [String: StockTransfer] = [:]
        for t in lists.joined() {
            if let have = out[t.id], !have.inTransit { continue }
            out[t.id] = t
        }
        return out.values.sorted { $0.sentAt > $1.sentAt }
    }
}

/// A stocktake: many items counted in one go, compared with what the till expected, then saved together.
public struct Stocktake: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var shop: String
    public var startedAt: String
    /// What the till expected when the count began.
    public var expected: [String: Double]
    /// What was counted so far.
    public var counted: [String: Double]

    public init(id: String = UUID().uuidString, shop: String, startedAt: String, expected: [String: Double], counted: [String: Double] = [:]) {
        self.id = id
        self.shop = shop
        self.startedAt = startedAt
        self.expected = expected
        self.counted = counted
    }

    public struct Variance: Equatable, Sendable {
        public var itemID: String
        public var expected: Double
        public var counted: Double
        public var difference: Double { counted - expected }
        /// The difference at cost (negative: stock lost).
        public var value: Double
    }

    /// Every counted item whose count differs from what was expected, biggest money first.
    public func variances(cost: (String) -> Double) -> [Variance] {
        counted.compactMap { itemID, count -> Variance? in
            let expect = expected[itemID] ?? 0
            guard abs(count - expect) > 0.0001 else { return nil }
            return Variance(itemID: itemID, expected: expect, counted: count, value: Money.round2((count - expect) * cost(itemID)))
        }
        .sorted { abs($0.value) > abs($1.value) || (abs($0.value) == abs($1.value) && $0.itemID < $1.itemID) }
    }

    /// The total at cost: lost (negative) or found.
    public func netValue(cost: (String) -> Double) -> Double {
        variances(cost: cost).pennySum { $0.value }
    }
}
