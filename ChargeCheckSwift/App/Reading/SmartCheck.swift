import Foundation
import ChargeCheckCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A second opinion from Apple Intelligence (the on-device model in iOS 26, offline, no cost).
/// It only fixes names, picks the matching price-list item and spots lines that are not real.
/// Quantities and prices always come from the photo – the model never changes a number.
enum SmartCheck {
    static let settingKey = "smartCheck.on"

    static var isOn: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    /// Why it can't run on this phone ("" when it can).
    static var status: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return ""
            case .unavailable(.deviceNotEligible):
                return String(localized: "This iPhone doesn't support Apple Intelligence (it needs an iPhone 15 Pro or newer).")
            case .unavailable(.appleIntelligenceNotEnabled):
                return String(localized: "Turn on Apple Intelligence in the Settings app to use this.")
            case .unavailable(.modelNotReady):
                return String(localized: "Apple Intelligence is still downloading. It will be used once it's ready.")
            case .unavailable:
                return String(localized: "Apple Intelligence isn't available right now.")
            }
        }
        return String(localized: "Needs iOS 26 or newer.")
        #else
        return String(localized: "Needs iOS 26 or newer.")
        #endif
    }

    static var canRun: Bool { isOn && status.isEmpty }

    /// Checks the lines of one invoice. Returns them unchanged if Apple Intelligence can't run.
    static func check(_ lines: [CheckLine], supplier: String, book: PriceBook, progress: @Sendable (String) -> Void) async -> [CheckLine] {
        guard canRun, !lines.isEmpty else { return lines }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            progress(String(localized: "Checking with Apple Intelligence…"))
            return await Checker.run(lines, supplier: supplier, book: book)
        }
        #endif
        return lines
    }

    /// Asks Apple Intelligence to find the invoice number and date when the reader couldn't.
    /// An answer is only used when it is really printed on the invoice, so nothing is made up.
    static func findDetails(in text: String, progress: @Sendable (String) -> Void) async -> (number: String, date: String) {
        guard canRun, !text.isEmpty else { return ("", "") }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            progress(String(localized: "Finding the invoice number and date with Apple Intelligence…"))
            return await DetailsFinder.run(text)
        }
        #endif
        return ("", "")
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct SmartDetails {
    @Guide(description: "The invoice number exactly as printed (for example 57, 82044 or INV-2041). Not a phone number, account number, batch number or amount. Empty if there is none.")
    var invoiceNumber: String
    @Guide(description: "The date the invoice was issued, copied exactly as printed (for example 2026-11-10 or 06/11/2026). Not a due, delivery or expiry date. Empty if there is none.")
    var invoiceDate: String
}

@available(iOS 26.0, *)
private enum DetailsFinder {
    static let instructions = """
    You read text taken from a photo of a supplier's invoice. It can be in English, Arabic, Kurdish, German or French, \
    and Arabic or Kurdish text may appear in reverse order. Labels such as "رقم الفاتورة" mean invoice number and \
    "التاريخ" or "تاريخ الفاتورة" mean date. Iraqi invoices often write the number with the year, like "57 - 2026": \
    the invoice number is then 57. Copy values exactly as they appear; never invent them.
    """

    static func run(_ text: String) async -> (number: String, date: String) {
        // the details are at the top (sometimes the bottom): keep the request small and quick
        let lines = text.components(separatedBy: "\n").map { String($0.prefix(120)) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let picked = lines.count > 40 ? Array(lines.prefix(30)) + Array(lines.suffix(8)) : lines
        do {
            let session = LanguageModelSession(instructions: instructions)
            let reply = try await session.respond(to: "Invoice text:\n" + picked.joined(separator: "\n"), generating: SmartDetails.self,
                                                  options: GenerationOptions(sampling: .greedy))
            let plain = InvoiceParser.westernDigits(text)
            let number = InvoiceParser.westernDigits(reply.content.invoiceNumber).trimmingCharacters(in: .whitespacesAndNewlines)
            let date = InvoiceParser.westernDigits(reply.content.invoiceDate).trimmingCharacters(in: .whitespacesAndNewlines)
            return (printed(number, in: plain) && InvoiceDetails.usableNumber(number) != nil ? number : "",
                    printed(date, in: plain) && InvoiceDetails.usableDate(date) != nil ? date : "")
        } catch {
            return ("", "")
        }
    }

    /// True when the value is on the invoice (spaces and letter case ignored).
    private static func printed(_ value: String, in text: String) -> Bool {
        guard !value.isEmpty else { return false }
        let squeeze = { (s: String) in s.lowercased().filter { !$0.isWhitespace } }
        let wanted = squeeze(value), whole = squeeze(text)
        guard whole.contains(wanted) else { return false }
        // a whole number on its own, not part of a longer one ("57", not the 57 inside 2057)
        if wanted.allSatisfy({ $0.isASCII && $0.isNumber }) {
            let pattern = "(?<![0-9])" + wanted + "(?![0-9])"
            return text.range(of: pattern, options: .regularExpression) != nil
        }
        return true
    }
}

@available(iOS 26.0, *)
@Generable
struct SmartLine {
    @Guide(description: "The line number, exactly as given")
    var line: Int
    @Guide(description: "The product name as it is really printed on the invoice, in the invoice's language, with the reader's spelling mistakes and invented letters fixed. Do not add words that are not there. Empty if you can't tell.")
    var name: String
    @Guide(description: "The number of the matching choice, or 0 if none of the choices is the same product")
    var choice: Int
    @Guide(description: "true only if this is not a product line at all (a heading, address, note or total), or the same product line as another line read twice")
    var notAProduct: Bool
}

@available(iOS 26.0, *)
@Generable
struct SmartReply {
    var lines: [SmartLine]
}

@available(iOS 26.0, *)
private enum Checker {
    static var instructions: String {
        """
    You check lines that a text reader read from a photo of a food supplier's invoice (takeaway and restaurant supplies), written in \(Regional.language.name), with prices in \(Money.currency.code).
    The reader sometimes invents letters (for example "16Ạ!¡COLOUR" for 16" COLOUR, "Vznfiour16Ko" for FLOUR 16Kg), joins words, or reads the same line twice.
    For each line: write the real product name, choose which of its choices from the shop's price list is the same product (0 if none is), and say if it is not a product line.
    Sizes, weights and pack counts must agree for a choice to be the same product. Quantities and prices are already correct; never change them.
    Write names in the invoice's own language and alphabet.
    """
    }

    static func run(_ lines: [CheckLine], supplier: String, book: PriceBook) async -> [CheckLine] {
        var result = lines
        var notProducts = Set<Int>()
        // small batches keep each request well inside the on-device model's limit
        let indices = Array(lines.indices)
        for start in stride(from: 0, to: indices.count, by: 8) {
            let batch = Array(indices[start..<min(start + 8, indices.count)])
            var choices: [Int: [PriceItem]] = [:]
            var prompt = "Supplier: \(supplier.isEmpty ? "unknown" : supplier)\n\n"
            for index in batch {
                let line = lines[index]
                var options = Matcher.suggestions(line.read.isEmpty ? line.desc : line.read, in: book.items, limit: 4)
                for item in book.items where abs(item.basePrice(for: supplier) - line.unit) < 0.005 && !options.contains(where: { $0.id == item.id }) {
                    options.append(item)
                    if options.count >= 6 { break }
                }
                if let current = book.item(line.matchId), !options.contains(where: { $0.id == current.id }) { options.insert(current, at: 0) }
                choices[index] = options
                prompt += "Line \(index + 1): read as \"\(line.read.isEmpty ? line.desc : line.read)\" – quantity \(PDFMaker.quantity(line.qty)), \(Money.format(line.unit)) each\n"
                if options.isEmpty {
                    prompt += "  Choices: none\n"
                } else {
                    for (n, item) in options.enumerated() {
                        prompt += "  \(n + 1)) \(item.name) (agreed \(Money.format(item.basePrice(for: supplier))))\n"
                    }
                }
            }
            do {
                let session = LanguageModelSession(instructions: instructions)
                let reply = try await session.respond(to: prompt, generating: SmartReply.self,
                                                      options: GenerationOptions(sampling: .greedy))
                for answer in reply.content.lines {
                    let index = answer.line - 1
                    guard batch.contains(index) else { continue }
                    if apply(answer, to: &result[index], options: choices[index] ?? [], supplier: supplier) { notProducts.insert(index) }
                }
            } catch {
                // too long, refused or not ready: keep what the reader found for this batch
                continue
            }
        }
        // a line Apple Intelligence calls a repeat is only removed if the photo reader wasn't sure of it either
        return result.enumerated().filter { index, line in
            !(notProducts.contains(index) && (lines[index].onlySecondRead || lines[index].matchId == nil))
        }.map { $0.element }
    }

    /// Returns true when Apple Intelligence says this is not a product line.
    private static func apply(_ answer: SmartLine, to line: inout CheckLine, options: [PriceItem], supplier: String) -> Bool {
        let name = answer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, !InvoiceParser.looksGarbled(name), name.count <= 80,
           InvoiceParser.looksGarbled(line.desc) || TextTools.similarity(name, line.desc) >= 0.3 {
            line.desc = name
        }
        if answer.choice >= 1, answer.choice <= options.count {
            let item = options[answer.choice - 1]
            if line.matchId == item.id {
                // the reader and Apple Intelligence agree
                if line.confident == false { line.confident = true }
            } else if line.matchId == nil || line.confident != true {
                line.matchId = item.id
                // sure only when the agreed price backs it up; otherwise the user is asked to confirm
                line.confident = abs(item.basePrice(for: supplier) - line.unit) < 0.005
            }
        }
        return answer.notAProduct
    }
}
#endif
