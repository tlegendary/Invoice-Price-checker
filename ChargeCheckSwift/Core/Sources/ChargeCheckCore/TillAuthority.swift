import Foundation

/// A manager's (or the owner's) yes for one action, given by typing their PIN. Single use, and only for a short time,
/// so a yes can't be saved up and used later by someone else.
public struct TillApproval: Codable, Equatable, Sendable {
    public var permission: TillPermission
    /// Who said yes.
    public var by: String
    public var at: Date

    public init(permission: TillPermission, by: String, at: Date) {
        self.permission = permission
        self.by = by
        self.at = at
    }
}

/// The yeses waiting to be used. The till store checks here before every action that needs a manager.
public struct TillApprovals: Sendable {
    /// How long a yes waits to be used.
    public static let lifetime: TimeInterval = 120
    private var waiting: [TillApproval] = []

    public init() {}

    public mutating func give(_ permissions: [TillPermission], by: String, at now: Date) {
        waiting.removeAll { permissions.contains($0.permission) || now.timeIntervalSince($0.at) > Self.lifetime }
        waiting += permissions.map { TillApproval(permission: $0, by: by, at: now) }
    }

    /// Uses up the yes for this action: who gave it, or nil if there isn't a fresh one.
    public mutating func use(_ permission: TillPermission, at now: Date) -> String? {
        waiting.removeAll { now.timeIntervalSince($0.at) > Self.lifetime || $0.at > now.addingTimeInterval(5) }
        guard let index = waiting.firstIndex(where: { $0.permission == permission }) else { return nil }
        return waiting.remove(at: index).by
    }

    public var isEmpty: Bool { waiting.isEmpty }
}

/// After too many wrong PINs the pad waits before it takes another, a little longer each time.
public struct PinLockout: Codable, Equatable, Sendable {
    /// Wrong PINs allowed in a row before the first wait.
    public static let freeTries = 5
    public static let firstWait: TimeInterval = 30
    public static let longestWait: TimeInterval = 300

    public var wrongInARow = 0
    public var lockedUntil: Date?

    public init() {}

    /// Seconds left before another PIN may be tried (0: try now).
    public func wait(at now: Date) -> TimeInterval {
        guard let until = lockedUntil else { return 0 }
        return max(0, until.timeIntervalSince(now))
    }

    public mutating func wrong(at now: Date) {
        wrongInARow += 1
        guard wrongInARow >= Self.freeTries else { return }
        let extra = Double(wrongInARow - Self.freeTries)
        lockedUntil = now.addingTimeInterval(min(Self.longestWait, Self.firstWait * pow(2, extra)))
    }

    public mutating func right() {
        wrongInARow = 0
        lockedUntil = nil
    }
}

public extension CashEvent.Kind {
    /// The permission this kind of cash event needs (nil: money from a customer, no manager needed).
    var permission: TillPermission? {
        switch self {
        case .float: return .float
        case .paidIn: return .cashIn
        case .paidOut: return .cashOut
        case .noSale: return .noSale
        case .tabPaid, .deposit: return nil
        }
    }
}
