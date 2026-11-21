import Foundation
import MetricKit

/// Crash and freeze reports from this phone, collected by iOS (MetricKit) – no outside service, nothing sent anywhere.
/// iOS hands them over about once a day. They're kept in Files › ChargeCheck › Problem reports, and the user can send
/// them from Settings › Problem reports so a crash on a real phone can be found and fixed.
final class CrashReports: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReports()
    static let folderName = "Problem reports"

    func start() {
        MXMetricManager.shared.add(self)
    }

    static var folder: URL? {
        AppFiles.documents?.appendingPathComponent(folderName, isDirectory: true)
    }

    static var files: [URL] {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted(by: >).map { folder.appendingPathComponent($0) }
    }

    static func clear() {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let folder = Self.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        for (index, payload) in payloads.enumerated() {
            let crashes = payload.crashDiagnostics?.count ?? 0, hangs = payload.hangDiagnostics?.count ?? 0
            guard crashes + hangs > 0 else { continue }
            let kind = crashes > 0 ? "crash" : "freeze"
            let name = "\(kind)-\(formatter.string(from: payload.timeStampEnd))-\(index).json"
            try? payload.jsonRepresentation().write(to: folder.appendingPathComponent(name), options: .atomic)
        }
        // the newest 20 are plenty
        for old in Self.files.dropFirst(20) { try? FileManager.default.removeItem(at: old) }
    }
}
