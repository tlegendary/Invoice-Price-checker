import Foundation

/// Whether a till's sales file from iCloud is safe to take in place of the copy on this device. A till only ever
/// adds to its own sales files (refunds are new sales), so a good new copy still holds every sale the old one had.
public enum FileCheck {
    public enum Verdict: Equatable, Sendable {
        case ok
        /// Not readable as sales (half downloaded, damaged).
        case damaged
        /// Sales this device had are missing from it: keep ours.
        case shrank(missing: Int)
    }

    public static func sales(new data: Data, old: Data?) -> Verdict {
        guard let incoming = try? JSONDecoder().decode([Sale].self, from: data) else { return .damaged }
        guard let old, let existing = try? JSONDecoder().decode([Sale].self, from: old) else { return .ok }
        let have = Set(incoming.map(\.id))
        let missing = existing.filter { !have.contains($0.id) }.count
        return missing > 0 ? .shrank(missing: missing) : .ok
    }

    /// Any other till file (settings, cash, products): at least whole, readable JSON.
    public static func json(_ data: Data) -> Verdict {
        (try? JSONSerialization.jsonObject(with: data)) == nil ? .damaged : .ok
    }
}
