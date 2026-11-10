import UIKit
import Vision
import PDFKit
import ChargeCheckCore

struct ReadOutcome {
    var invoice: ParsedInvoice
    var passes: Int
    var rawText: String
}

/// Reads invoice photos on the phone with Apple's text reader (Vision). Works offline.
/// Every invoice is read twice – once normally and once from a high-contrast copy with
/// spelling help switched off – and the two reads are compared.
enum InvoiceReader {

    /// Words to help the reader spell: column headings plus the words in the price list.
    static func helpWords(_ items: [PriceItem]) -> [String] {
        var seen = Set<String>()
        var words = ["Quantity", "Description", "Unit", "Price", "Net", "Amount", "VAT", "Invoice", "Total", "Discount",
                     "Fillet", "Chicken", "Mayonnaise", "Tortilla", "Burger", "Halal", "Frozen", "Breading"]
        for word in words { seen.insert(word) }
        for item in items {
            for word in item.name.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                let lettersOnly = word.count >= 4 && word.allSatisfy { $0.isASCII && $0.isLetter }
                if lettersOnly && seen.insert(word).inserted { words.append(word) }
            }
        }
        return Array(words.prefix(400))
    }

    /// Every piece of text on one picture, with where it sits (pixels, origin top-left).
    static func pieces(in image: CGImage, words: [String], correct: Bool) -> [TextPiece] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = correct
        let wanted = Regional.language.vision
        let supported = (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
        let usable = wanted.filter { supported.contains($0) }
        request.recognitionLanguages = usable.isEmpty ? ["en-US"] : usable
        if Regional.language.id != "en" { request.automaticallyDetectsLanguage = usable.isEmpty }
        request.minimumTextHeight = 0.006
        if correct && !words.isEmpty { request.customWords = words }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let width = Double(image.width), height = Double(image.height)
        var out: [TextPiece] = []
        for observation in request.results ?? [] {
            guard let best = observation.topCandidates(1).first else { continue }
            let tlx = Double(observation.topLeft.x) * width, tly = (1 - Double(observation.topLeft.y)) * height
            let trx = Double(observation.topRight.x) * width, try_ = (1 - Double(observation.topRight.y)) * height
            let blx = Double(observation.bottomLeft.x) * width, bly = (1 - Double(observation.bottomLeft.y)) * height
            let brx = Double(observation.bottomRight.x) * width, bry = (1 - Double(observation.bottomRight.y)) * height
            let w = ((trx - tlx) * (trx - tlx) + (try_ - tly) * (try_ - tly)).squareRoot()
            let h = ((blx - tlx) * (blx - tlx) + (bly - tly) * (bly - tly)).squareRoot()
            out.append(TextPiece(text: best.string, confidence: Double(best.confidence),
                                 x: (tlx + trx + blx + brx) / 4, y: (tly + try_ + bly + bry) / 4,
                                 width: w, height: h, angle: atan2(bry - bly, brx - blx)))
        }
        return out
    }

    private static func onePass(_ pages: [UIImage], book: PriceBook, words: [String], second: Bool) -> (invoice: ParsedInvoice, text: String) {
        var text = ""
        for page in pages {
            let picture = second ? page.highContrast() : page.cgImage
            guard let picture else { continue }
            let rows = InvoiceParser.rows(from: pieces(in: picture, words: words, correct: !second))
            if !rows.isEmpty { text += rows + "\n" }
        }
        return (InvoiceParser.parseInvoice(text, known: book.knownWords), text)
    }

    // MARK: - PDFs with real text

    /// The words on one PDF page, straight from its text (no reading mistakes possible). Scanned PDFs have none.
    static func pdfPieces(_ page: PDFPage) -> [TextPiece] {
        guard let text = page.string, !text.isEmpty else { return [] }
        let box = page.bounds(for: .mediaBox)
        let longest = max(box.width, box.height)
        guard longest > 0 else { return [] }
        let scale = 2400 / longest
        var pieces: [TextPiece] = []
        var word = ""
        var frame = CGRect.null
        func finish() {
            if !word.isEmpty, !frame.isNull {
                // PDF pages count up from the bottom; the reader counts down from the top
                pieces.append(TextPiece(text: word, confidence: 1,
                                        x: Double((frame.midX - box.minX) * scale), y: Double((box.maxY - frame.midY) * scale),
                                        width: Double(frame.width * scale), height: Double(frame.height * scale), angle: 0))
            }
            word = ""
            frame = .null
        }
        let ns = text as NSString
        for index in 0..<ns.length {
            let unit = ns.substring(with: NSRange(location: index, length: 1))
            if unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finish()
                continue
            }
            let bounds = page.characterBounds(at: index)
            if bounds.isEmpty || bounds.width.isNaN { word += unit; continue }
            if !frame.isNull {
                // a big gap or a new line also ends a word (PDFs often leave the spaces out between columns)
                let gap = bounds.minX - frame.maxX
                let otherLine = abs(bounds.midY - frame.midY) > max(bounds.height, frame.height) * 0.6
                if otherLine || gap > max(bounds.height, 2) * 0.9 || gap < -bounds.height * 2 { finish() }
            }
            word += unit
            frame = frame.isNull ? bounds : frame.union(bounds)
        }
        finish()
        return pieces
    }

    /// The invoice's text from a PDF made by the supplier's computer, or nil when it's a scan (just pictures).
    static func pdfText(_ data: Data) -> String? {
        guard let document = PDFDocument(data: data) else { return nil }
        var text = ""
        for index in 0..<min(document.pageCount, 10) {
            guard let page = document.page(at: index) else { continue }
            let rows = InvoiceParser.rows(from: pdfPieces(page))
            if !rows.isEmpty { text += rows + "\n" }
        }
        let digits = text.filter { $0.isASCII && $0.isNumber }.count
        return text.count > 60 && digits > 6 ? text : nil
    }

    // MARK: - Apple's table reader (iOS 26)

    /// Each table row Apple's document reader found, as one line of text. Empty before iOS 26 or when it finds no table.
    static func tableRows(_ pages: [UIImage]) async -> String {
        guard #available(iOS 26.0, *) else { return "" }
        var lines: [String] = []
        for page in pages {
            guard let picture = page.cgImage else { continue }
            let request = RecognizeDocumentsRequest()
            guard let observations = try? await request.perform(on: picture) else { continue }
            for observation in observations {
                for table in observation.document.tables {
                    for row in table.rows {
                        let cells = row.map { $0.content.text.transcript.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        if !cells.isEmpty { lines.append(cells.joined(separator: "  ")) }
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// How far the lines are from the printed net total (smaller is better). Without a printed total, more lines is better.
    private static func distance(_ lines: [ParsedLine], printedNet: Double?) -> Double {
        guard let printedNet, printedNet > 0 else { return -Double(lines.count) }
        let net = lines.reduce(0.0) { $0 + Money.round2($1.qty * $1.unit) }
        return abs(Money.round2(net) - printedNet)
    }

    /// Uses the table reader's lines when they fit the invoice better than the normal read.
    private static func betterLines(_ invoice: ParsedInvoice, tableText: String, book: PriceBook) -> ParsedInvoice {
        guard !tableText.isEmpty else { return invoice }
        let table = InvoiceParser.parseInvoice(tableText, known: book.knownWords).lines
        guard !table.isEmpty else { return invoice }
        let now = distance(invoice.lines, printedNet: invoice.printedNet)
        let then = distance(table, printedNet: invoice.printedNet)
        if then < now - 0.005 || (abs(then - now) <= 0.005 && table.count > invoice.lines.count) {
            var better = invoice
            better.lines = table
            return better
        }
        return invoice
    }

    /// Reads one invoice (one or more pages). Runs away from the main thread.
    static func read(pages: [UIImage], pdf: Data? = nil, book: PriceBook, knownSuppliers: [String], doubleCheck: Bool = true,
                     progress: @escaping @Sendable (String) -> Void) async -> ReadOutcome {
        // a PDF the supplier's computer made already holds the exact text: nothing to misread
        if let pdf, let text = pdfText(pdf) {
            progress(String(localized: "Reading the PDF's text…"))
            var invoice = InvoiceParser.parseInvoice(text, known: book.knownWords)
            if !invoice.lines.isEmpty {
                invoice.supplier = InvoiceParser.bestSupplier([invoice.supplier], known: knownSuppliers)
                for index in invoice.lines.indices { invoice.lines[index].reads = 2 }
                return ReadOutcome(invoice: invoice, passes: 2, rawText: text)
            }
        }
        var prepared = pages.map { $0.prepared() }
        let words = helpWords(book.items)
        progress(doubleCheck ? String(localized: "Reading invoice (1 of 2)…") : String(localized: "Reading invoice…"))
        var first = onePass(prepared, book: book, words: words, second: false)
        if first.invoice.lines.count < 2 && prepared.count == 1 {
            // perhaps the photo is on its side or upside down
            for turns in [1, 3, 2] {
                progress(String(localized: "Trying the photo another way round…"))
                let turned = [pages[0].prepared(quarterTurns: turns)]
                let attempt = onePass(turned, book: book, words: words, second: false)
                if attempt.invoice.lines.count > first.invoice.lines.count {
                    first = attempt
                    prepared = turned
                }
                if first.invoice.lines.count >= 2 { break }
            }
        }
        if #available(iOS 26.0, *), !first.invoice.lines.isEmpty || prepared.count == 1 {
            progress(String(localized: "Reading the table of items…"))
            first.invoice = betterLines(first.invoice, tableText: await tableRows(prepared), book: book)
        }
        var merged = first.invoice
        var passes = 1
        if doubleCheck && !first.invoice.lines.isEmpty {
            progress(String(localized: "Double-checking (2 of 2)…"))
            let second = onePass(prepared, book: book, words: words, second: true)
            merged = InvoiceParser.mergeReads(first.invoice, second.invoice, knownSuppliers: knownSuppliers)
            passes = 2
        } else {
            merged.supplier = InvoiceParser.bestSupplier([merged.supplier], known: knownSuppliers)
        }
        return ReadOutcome(invoice: merged, passes: passes, rawText: first.text)
    }
}
