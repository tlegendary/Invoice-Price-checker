import Foundation

/// The App Store products. These must match App Store Connect exactly.
public enum Products {
    public static let yearly = "ipc_yearly"
    public static let monthly = "ipc_monthlyy"
    public static let plans = [yearly, monthly]
    /// Scan packs (bought once, used up): product ID → number of scans.
    public static let packs: [String: Int] = ["ipc_scans_3": 3, "ipc_scans_10": 10, "ipc_scans_30": 30]
    public static let packOrder = ["ipc_scans_3", "ipc_scans_10", "ipc_scans_30"]

    /// "Save 17%": how much cheaper a year is than twelve months.
    public static func yearlySaving(yearly: Double, monthly: Double) -> Int {
        guard yearly > 0, monthly > 0 else { return 0 }
        return max(0, Int(((1 - yearly / (monthly * 12)) * 100).rounded()))
    }
}

/// The scans a non-subscriber has: bought in packs or earned by watching an ad.
public struct ScanLedger: Codable, Equatable, Sendable {
    public private(set) var credits: Int
    /// Purchases already counted, so a pack is never added twice.
    public private(set) var seenTransactions: [String]
    /// A random name for this phone, kept in backups so restoring a backup on the
    /// same phone can't be used to get used scans back.
    public let device: String

    public init(device: String = ScanLedger.newDeviceID(), credits: Int = 0) {
        self.device = device
        self.credits = max(0, credits)
        self.seenTransactions = []
    }

    public static func newDeviceID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Adds the scans for a pack purchase exactly once. Returns how many were added.
    @discardableResult
    public mutating func creditPack(productID: String, transactionID: String) -> Int {
        guard let scans = Products.packs[productID] else { return 0 }
        if !transactionID.isEmpty {
            if seenTransactions.contains(transactionID) { return 0 }
            seenTransactions.append(transactionID)
            if seenTransactions.count > 300 { seenTransactions.removeFirst(seenTransactions.count - 300) }
        }
        credits += scans
        return scans
    }

    /// One scan for one rewarded ad. Only call this when the ad network confirms the reward.
    public mutating func addAdReward() {
        credits += 1
    }

    /// Uses up to `wanted` scans. Returns how many were actually available.
    @discardableResult
    public mutating func use(_ wanted: Int = 1) -> Int {
        let taken = max(0, min(wanted, credits))
        credits -= taken
        return taken
    }

    /// Gives a scan back (the invoice couldn't be read).
    public mutating func refund(_ count: Int = 1) {
        credits += max(0, count)
    }

    /// Unused scans from a backup made on a different phone. Returns how many were added.
    @discardableResult
    public mutating func restore(from scans: ScanCredits?) -> Int {
        guard let scans, scans.n > 0, scans.dev != device, scans.n > credits else { return 0 }
        let added = scans.n - credits
        credits = scans.n
        return added
    }

    /// Unused scans carried over from the first version of the app on this phone (done once).
    public mutating func adopt(legacyCredits: Int) {
        credits = max(credits, legacyCredits)
    }

    public var forBackup: ScanCredits {
        ScanCredits(n: credits, dev: device)
    }
}
