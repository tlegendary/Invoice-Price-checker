import Foundation
import ChargeCheckCore

/// One file for the accountant: the report PDF, the spreadsheet, bills for Xero, and every invoice's original photo
/// or PDF (and any photos added to a credit request) – zipped with iOS's own zipping, no extra code needed.
enum MonthPack {
    static func make(_ entries: [HistoryEntry], title: String, pdf: Data, csv: Data, xero: Data) -> URL? {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("pack-" + UUID().uuidString, isDirectory: true)
        let root = work.appendingPathComponent(title, isDirectory: true)
        let invoices = root.appendingPathComponent(String(localized: "Invoices"), isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: invoices, withIntermediateDirectories: true)
            try pdf.write(to: root.appendingPathComponent("Report.pdf"))
            try csv.write(to: root.appendingPathComponent("Report.csv"))
            try xero.write(to: root.appendingPathComponent("Xero bills.csv"))
        } catch {
            return nil
        }
        var used = Set<String>()
        for entry in entries {
            let base = [entry.supplier, entry.invNo.isEmpty ? entry.date : entry.invNo]
                .filter { !$0.isEmpty }.joined(separator: " ")
                .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
            var stem = base.isEmpty ? String(entry.id.prefix(8)) : base
            while used.contains(stem) { stem += " (2)" }
            used.insert(stem)
            if let path = entry.file, let url = AppFiles.url(forRelativePath: path) {
                try? fm.copyItem(at: url, to: invoices.appendingPathComponent(stem + "." + url.pathExtension))
            }
            for (index, photo) in CreditPhotos.list(entry.id).enumerated() {
                try? fm.copyItem(at: photo, to: invoices.appendingPathComponent(stem + " – " + String(localized: "photo") + " \(index + 1).jpg"))
            }
        }
        // iOS zips a folder when it's read "for uploading"
        var zipped: URL?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &error) { zip in
            guard let data = try? Data(contentsOf: zip) else { return }
            zipped = AppFiles.write(data, folder: "Exports", name: title + ".zip")
        }
        return zipped
    }
}
