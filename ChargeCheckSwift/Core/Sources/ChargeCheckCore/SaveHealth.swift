import Foundation

/// Where something is saved, so a failure can say plainly what didn't save.
public enum SaveArea: String, Codable, CaseIterable, Sendable {
    /// Invoices, prices, suppliers (the app's database on this device).
    case database
    /// Files on this device: till sales, settings, orders, exports.
    case phone
    /// The copy in iCloud Drive that other devices and staff read.
    case icloud
}

/// One thing that didn't save.
public struct SaveFailure: Codable, Equatable, Sendable {
    public var area: SaveArea
    /// What was being saved, in plain words ("Till sales", "Invoice 1043").
    public var what: String
    /// The system's reason, kept for support.
    public var reason: String
    public var at: Date
    /// Times in a row it failed.
    public var count: Int

    public init(area: SaveArea, what: String, reason: String, at: Date, count: Int = 1) {
        self.area = area
        self.what = what
        self.reason = reason
        self.at = at
        self.count = count
    }
}

/// What hasn't saved right now. A failure stays until the same thing saves again, so the warning never
/// disappears while the data is still at risk.
public struct SaveHealth: Codable, Equatable, Sendable {
    public private(set) var failures: [SaveFailure] = []
    /// How many failures are kept (the oldest go first).
    public static let limit = 20

    public init() {}

    public var isHealthy: Bool { failures.isEmpty }

    public mutating func failed(_ area: SaveArea, _ what: String, reason: String, at now: Date) {
        if let index = failures.firstIndex(where: { $0.area == area && $0.what == what }) {
            failures[index].count += 1
            failures[index].reason = reason
            failures[index].at = now
        } else {
            failures.append(SaveFailure(area: area, what: what, reason: reason, at: now))
            if failures.count > Self.limit { failures.removeFirst(failures.count - Self.limit) }
        }
    }

    /// It saved: that warning can go.
    public mutating func saved(_ area: SaveArea, _ what: String) {
        failures.removeAll { $0.area == area && $0.what == what }
    }

    /// The worst problem first: the database (invoices, money owed), then the phone, then iCloud.
    public var worst: SaveFailure? {
        failures.min { rank($0.area) < rank($1.area) || (rank($0.area) == rank($1.area) && $0.at > $1.at) }
    }

    private func rank(_ area: SaveArea) -> Int {
        switch area {
        case .database: return 0
        case .phone: return 1
        case .icloud: return 2
        }
    }
}
