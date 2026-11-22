import Foundation

/// What's wrong with a backup before it replaces anything. A restore deletes what's on the device, so the file is
/// checked first and refused when it can't be trusted.
public enum BackupProblem: Equatable, Sendable {
    /// Made by a newer ChargeCheck: fields this version doesn't know would be lost.
    case newerVersion(Int)
    /// No prices, invoices or payments: restoring it would only wipe the device.
    case empty
    /// Money figures that aren't numbers (NaN or infinite).
    case badMoney(Int)
    /// Items or invoices without an ID.
    case missingIDs(Int)

    /// Whether the restore must not go ahead.
    public var blocks: Bool { true }
}

public enum BackupValidation {
    /// The newest backup format this version reads.
    public static let newestVersion = 3

    public static func problems(_ backup: BackupFile) -> [BackupProblem] {
        var found: [BackupProblem] = []
        if let v = backup.v, v > newestVersion { found.append(.newerVersion(v)) }
        if backup.baseline.isEmpty && backup.history.isEmpty && (backup.payments ?? []).isEmpty { found.append(.empty) }
        var bad = 0
        for item in backup.baseline where !item.price.isFinite { bad += 1 }
        for entry in backup.history {
            let figures = [entry.net, entry.total, entry.over, entry.overVat, entry.excluded]
            if figures.contains(where: { !$0.isFinite }) { bad += 1 }
        }
        for payment in backup.payments ?? [] where !payment.amount.isFinite { bad += 1 }
        if bad > 0 { found.append(.badMoney(bad)) }
        let noID = backup.baseline.filter { $0.id.trimmingCharacters(in: .whitespaces).isEmpty }.count
            + backup.history.filter { $0.id.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if noID > 0 { found.append(.missingIDs(noID)) }
        return found
    }
}
