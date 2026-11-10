import Foundation
import PDFKit
import ChargeCheckCore

/// Many suppliers email invoices as PDFs that contain real text. That text can be taken exactly,
/// instead of reading a picture of the page, so prices and names come out right first time.
enum PDFText {

    /// The text on each page, as pieces with their positions (the same shape the photo reader gives).
    /// A page that is only a picture (a scanned invoice) gives no pieces.
    static func pieces(ofPDF data: Data, maxPages: Int = 10) -> [[TextPiece]] {
        guard let document = PDFDocument(data: data) else { return [] }
        var pages: [[TextPiece]] = []
        for index in 0..<min(document.pageCount, maxPages) {
            guard let page = document.page(at: index) else { continue }
            pages.append(pieces(on: page))
        }
        return pages
    }

    /// Joins the letters on a page into runs of text. A run ends at a new line or a wide gap (the next column).
    private static func pieces(on page: PDFKit.PDFPage) -> [TextPiece] {
        guard let text = page.string, !text.isEmpty else { return [] }
        let box = page.bounds(for: .mediaBox)
        let letters = text as NSString
        var out: [TextPiece] = []
        var run = ""
        var area = CGRect.null

        func finish() {
            let words = run.trimmingCharacters(in: .whitespaces)
            if !words.isEmpty && !area.isNull {
                out.append(TextPiece(text: words, confidence: 1,
                                     x: Double(area.midX - box.minX), y: Double(box.maxY - area.midY),
                                     width: Double(area.width), height: Double(area.height), angle: 0))
            }
            run = ""
            area = .null
        }

        for index in 0..<letters.length {
            let letter = letters.substring(with: NSRange(location: index, length: 1))
            if letter == "\n" || letter == "\r" {
                finish()
                continue
            }
            if letter.trimmingCharacters(in: .whitespaces).isEmpty {
                if !run.isEmpty && !run.hasSuffix(" ") { run += " " }
                continue
            }
            let bounds = page.characterBounds(at: index)
            guard !bounds.isNull, !bounds.isEmpty, bounds.width.isFinite, bounds.height.isFinite else {
                run += letter
                continue
            }
            if !area.isNull {
                let height = max(area.height, bounds.height, 1)
                let sameLine = abs(bounds.midY - area.midY) < height * 0.5
                let gap = bounds.minX - area.maxX
                if !sameLine || gap > height * 1.2 || gap < -height { finish() }
            }
            run += letter
            area = area.isNull ? bounds : area.union(bounds)
        }
        finish()
        return out
    }
}
