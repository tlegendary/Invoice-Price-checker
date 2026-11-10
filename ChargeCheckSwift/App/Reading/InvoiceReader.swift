import UIKit
import Vision
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

    /// Reads one invoice (one or more pages). Runs away from the main thread.
    static func read(pages: [UIImage], book: PriceBook, knownSuppliers: [String], doubleCheck: Bool = true,
                     progress: @escaping @Sendable (String) -> Void) async -> ReadOutcome {
        var prepared = pages.map { $0.prepared() }
        let words = helpWords(book.items)
        progress(doubleCheck ? "Reading invoice (1 of 2)…" : "Reading invoice…")
        var first = onePass(prepared, book: book, words: words, second: false)
        if first.invoice.lines.count < 2 && prepared.count == 1 {
            // perhaps the photo is on its side or upside down
            for turns in [1, 3, 2] {
                progress("Trying the photo another way round…")
                let turned = [pages[0].prepared(quarterTurns: turns)]
                let attempt = onePass(turned, book: book, words: words, second: false)
                if attempt.invoice.lines.count > first.invoice.lines.count {
                    first = attempt
                    prepared = turned
                }
                if first.invoice.lines.count >= 2 { break }
            }
        }
        var merged = first.invoice
        var passes = 1
        if doubleCheck && !first.invoice.lines.isEmpty {
            progress("Double-checking (2 of 2)…")
            let second = onePass(prepared, book: book, words: words, second: true)
            merged = InvoiceParser.mergeReads(first.invoice, second.invoice, knownSuppliers: knownSuppliers)
            passes = 2
        } else {
            merged.supplier = InvoiceParser.bestSupplier([merged.supplier], known: knownSuppliers)
        }
        return ReadOutcome(invoice: merged, passes: passes, rawText: first.text)
    }
}
