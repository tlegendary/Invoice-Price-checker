import Foundation

/// Files that didn't reach iCloud yet. The file itself is always saved on the device first; this remembers to send
/// it again, waiting longer after each failure (30 s, 1 min, 2 min… up to an hour), so going offline never loses a
/// sale and never drains the battery retrying.
public struct SyncOutbox: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var folder: String
        public var name: String
        public var attempts: Int
        public var firstFailed: Date
        public var nextTry: Date
        public var key: String { folder + "/" + name }
    }

    public static let firstWait: TimeInterval = 30
    public static let longestWait: TimeInterval = 3600

    public private(set) var items: [String: Item] = [:]

    public init() {}

    public var isEmpty: Bool { items.isEmpty }

    public mutating func failed(folder: String, name: String, at now: Date) {
        let key = folder + "/" + name
        var item = items[key] ?? Item(folder: folder, name: name, attempts: 0, firstFailed: now, nextTry: now)
        item.attempts += 1
        let wait = min(Self.longestWait, Self.firstWait * pow(2, Double(item.attempts - 1)))
        item.nextTry = now.addingTimeInterval(wait)
        items[key] = item
    }

    /// It reached iCloud (a later save of the same file counts: it carries everything).
    public mutating func sent(folder: String, name: String) {
        items[folder + "/" + name] = nil
    }

    /// The files to try now, the longest waiting first.
    public func due(at now: Date) -> [Item] {
        items.values.filter { $0.nextTry <= now }.sorted { $0.firstFailed < $1.firstFailed }
    }

    /// How long the oldest one has waited (for "not in iCloud since…").
    public func oldest() -> Date? { items.values.map(\.firstFailed).min() }
}
