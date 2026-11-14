import Foundation

/// Finds the invoice number and the invoice date when the usual "Invoice No" / "Invoice Date" labels didn't find them:
/// other label wordings ("Inv #", "Bill No", "Tax point"), letters in the number ("INV-2041"), dates with month names
/// ("10 Nov 2026"), and labels printed in a header box with the value on the row underneath.
public enum InvoiceDetails {

    // MARK: - invoice number

    /// Strongest first: wordings that can only mean the invoice number, then looser ones.
    static var numberLabels: [String] {
        [
            InvoiceParser.Words.invoiceNo,
            "invoice\\s*(?:no|number|num|nr|#)|inv\\.?\\s*(?:no|nr|num|#)|tax\\s*invoice\\s*(?:no|#)?|bill\\s*(?:no|number|#)|sales\\s*invoice",
            "document\\s*(?:no|number|#)|doc\\.?\\s*(?:no|#)|receipt\\s*(?:no|number|#)|voucher\\s*(?:no|#)|beleg\\s*(?:nr|nummer)|n°\\s*de\\s*facture|رقم الوصل|رقم السند|رقم|ژمارە",
            "(?:^|\\s)(?:no|nr|#|№)\\.?(?=\\s*[:#.]?\\s*[A-Za-z]{0,6}[-/]?[0-9])"
        ]
    }

    /// A value that can be an invoice number: has a digit, isn't a date, a money amount, a phone number or a percentage.
    public static func usableNumber(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .:-/#,"))
        guard value.count >= 2, value.count <= 24, value.hasAsciiDigit else { return nil }
        if isDate(value) { return nil }
        if Rx.test(value, "^[0-9]{1,3}([.,][0-9]{3})*[.,][0-9]{2}$") { return nil }        // 1,234.56
        if Rx.test(value, "^\\+?[0-9]{10,}$") && value.hasPrefix("0") { return nil }       // 07701234567
        if Rx.test(value, "%") { return nil }
        return value
    }

    static let numberValue = "([A-Za-z]{0,6}[-/]?[0-9][0-9A-Za-z\\-/]{0,22})"

    public static func invoiceNumber(in text: String) -> String {
        let text = InvoiceParser.westernDigits(text)
        let lines = text.components(separatedBy: "\n")
        for label in numberLabels {
            // the value beside its label: "Invoice #: INV-2041", "Bill No. 77"
            for line in lines {
                let found = Rx.group(line, "(?:" + label + ")\\.?[^0-9A-Za-z\\n]{0,8}" + numberValue, ci: true)
                if let value = usableNumber(found) { return value }
                // read left to right, an Arabic invoice puts the number before its label
                let before = Rx.group(line, "([0-9][0-9A-Za-z\\-/]{1,22})[^0-9A-Za-z\\n]{0,6}(?:" + label + ")", ci: true)
                if Rx.test(line, "[\\u0600-\\u06FF]"), let value = usableNumber(before) { return value }
            }
            // a header box: the label on one row, the number on the row underneath
            if let value = underLabel(label, in: lines, rows: 1, pick: { boxNumber($0) }) { return value }
        }
        // a tilted photo: "Invoice No" with its box just above or below, so the number lands on the next row
        if let value = besideLabel(InvoiceParser.Words.invoiceNo, in: lines) { return value }
        return numberWithYear(in: lines)
    }

    /// Iraqi wholesalers print the number with the year: "رقم الفاتورة: 57 - 2026" is invoice 2026-57.
    /// When the Arabic label wasn't read, "57 - 2026" (or "2026 - 57" read left to right) near the top is still the number.
    static func numberWithYear(in lines: [String]) -> String {
        for line in lines.prefix(15) {
            let after = Rx.group(line, "(?<![0-9\\-/.])(?:20[0-9]{2})\\s*[-/]\\s*([0-9]{1,8})(?![0-9]|\\s*[-/.]\\s*[0-9])")
            if !after.isEmpty, !Rx.test(after, "^20[0-9]{2}$"), (Int(after) ?? 0) > 0 { return withYear(after, in: line) }
            let before = Rx.group(line, "(?<![0-9\\-/.])([0-9]{1,8})\\s*[-/]\\s*20[0-9]{2}(?![0-9]|\\s*[-/.]\\s*[0-9])")
            if !before.isEmpty, !Rx.test(before, "^20[0-9]{2}$"), (Int(before) ?? 0) > 0 { return withYear(before, in: line) }
        }
        return ""
    }

    /// The invoice number with its year when the invoice prints them together: "57" beside "- 2026" becomes "2026-57",
    /// whichever way round the photo was read. A number that is part of a date is left alone.
    public static func withYear(_ number: String, in text: String) -> String {
        guard Rx.test(number, "^[0-9]{1,6}$") else { return number }
        let n = NSRegularExpression.escapedPattern(for: number)
        let lone = "(?![0-9]|[ \\t]*[-/.][ \\t]*[0-9])"
        let start = "(?<![0-9\\-/.])"
        var year = Rx.group(text, start + "(20[0-9]{2})[ \\t]*[-/][ \\t]*" + n + lone)
        if year.isEmpty { year = Rx.group(text, start + n + "[ \\t]*[-/][ \\t]*(20[0-9]{2})" + lone) }
        return year.isEmpty ? number : year + "-" + number
    }

    // MARK: - date

    static let months = "jan|feb|febr|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|januar|februar|märz|maerz|mai|juni|juli|okt|dez|janv|févr|fevr|mars|avr|juin|juil|août|aout|déc"
    static var numericDate: String { "[0-9]{1,2}[/.\\-][0-9]{1,2}[/.\\-](?:20)?[0-9]{2}|20[0-9]{2}[/.\\-][0-9]{1,2}[/.\\-][0-9]{1,2}" }
    static var wordDate: String {
        "[0-9]{1,2}(?:st|nd|rd|th|er)?[\\s\\-./]*(?:" + months + ")[a-zäéû]*\\.?[\\s\\-./,]*(?:20)?[0-9]{2}"
        + "|(?:" + months + ")[a-zäéû]*\\.?\\s*[0-9]{1,2}(?:st|nd|rd|th)?,?\\s*20[0-9]{2}"
    }
    static var anyDate: String { "(" + wordDate + "|" + numericDate + ")" }

    static func isDate(_ text: String) -> Bool {
        Rx.test(text, "^(?:" + wordDate + "|" + numericDate + ")$", ci: true)
    }

    /// Strongest first; a plain "Date" comes last because "Due date" and "Delivery date" also say date.
    static var dateLabels: [String] {
        [
            InvoiceParser.Words.date,
            "invoice\\s*date|inv\\.?\\s*date|date\\s*of\\s*invoice|tax\\s*point|issue\\s*date|date\\s*issued|billing\\s*date|rechnungsdatum|date\\s*de\\s*facturation|تاريخ الفاتورة|بەرواری پسوولە",
            "(?<!due\\s)(?<!delivery\\s)(?<!expiry\\s)(?<!order\\s)\\bdate\\b|datum|التاريخ|تاريخ|بەروار"
        ]
    }

    /// Dates that aren't the invoice date.
    static let otherDates = "due|delivery|deliver|expiry|expires|best\\s*before|order\\s*date|printed|fällig|liefer|échéance|livraison|الاستحقاق|التسليم|الانتهاء"

    public static func usableDate(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ",."))
        guard isDate(value), isRealDate(value) else { return nil }
        return value
    }

    /// Rejects numbers that only look like dates, such as "45.12.30".
    static func isRealDate(_ value: String) -> Bool {
        let parts = value.split(whereSeparator: { "/.-".contains($0) }).compactMap { Int($0) }
        guard parts.count == 3 else { return true }   // month-name dates were checked by the pattern
        if parts[0] >= 2000 { return (1...12).contains(parts[1]) && (1...31).contains(parts[2]) && !farAhead(year: parts[0], month: parts[1]) }
        let year = parts[2] < 100 ? parts[2] + 2000 : parts[2]
        guard (2000...2099).contains(year) else { return false }
        // an expiry or best-before date years ahead is never the invoice date
        if farAhead(year: year, month: (1...12).contains(parts[1]) ? parts[1] : parts[0]) { return false }
        // day/month or month/day: either way both must fit
        return ((1...31).contains(parts[0]) && (1...12).contains(parts[1])) || ((1...12).contains(parts[0]) && (1...31).contains(parts[1]))
    }

    /// More than about three months after today.
    static func farAhead(year: Int, month: Int, now: Date = Date()) -> Bool {
        let today = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: now)
        return (year * 12 + month) - ((today.year ?? 2026) * 12 + (today.month ?? 1)) > 3
    }

    public static func invoiceDate(in text: String) -> String {
        let text = InvoiceParser.westernDigits(text)
        let lines = text.components(separatedBy: "\n")
        for label in dateLabels {
            for line in lines {
                if let value = usableDate(Rx.group(line, "(?:" + label + ")[^0-9A-Za-z\\n]{0,10}" + anyDate, ci: true)) { return value }
                if let value = usableDate(Rx.group(line, anyDate + "[^0-9\\n]{0,6}(?:" + label + ")", ci: true)),
                   Rx.test(line, "[\\u0600-\\u06FF]") { return value }
            }
            if let value = underLabel(label, in: lines, pick: { usableDate($0) }) { return value }
        }
        // no label at all: the first date on the invoice that isn't a due, delivery or expiry date
        for line in lines where !Rx.test(line, otherDates, ci: true) {
            if let value = usableDate(Rx.group(line, anyDate, ci: true)) { return value }
        }
        return ""
    }

    // MARK: - header boxes

    /// The label ends its row with nothing after it; the number is the last cell of the row just above or below
    /// (a slightly tilted photo puts the value box on a neighbouring row). Only plain numbers of 3+ digits count,
    /// so a postcode or a page number is never taken.
    static func besideLabel(_ label: String, in lines: [String]) -> String? {
        for (index, line) in lines.enumerated() {
            let cells = line.components(separatedBy: "   ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let last = cells.last, Rx.test(last, "(?:" + label + ")\\W*$", ci: true) else { continue }
            for near in [index - 1, index + 1] where lines.indices.contains(near) {
                let other = lines[near].components(separatedBy: "   ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if let value = other.last, Rx.test(value, "^[A-Za-z]{0,4}[-/]?[0-9]{3,}$"), let usable = usableNumber(value) { return usable }
            }
        }
        return nil
    }

    /// A label on a row with nothing usable after it, and its value on the next row or two.
    /// With several labels in one header row, the value is taken from the same column (by word position).
    /// A number on its own in a box: at least 3 digits in a row, no spaces ("82044", "INV-2041"; never "B14 7JJ").
    static func boxNumber(_ text: String) -> String? {
        guard Rx.test(text, "^[A-Za-z]{0,6}[-/]?[0-9]{3,}[0-9A-Za-z\\-/]*$") else { return nil }
        return usableNumber(text)
    }

    static func underLabel(_ label: String, in lines: [String], rows: Int = 2, pick: (String) -> String?) -> String? {
        guard let rx = Rx.regex("(?:" + label + ")", ci: true) else { return nil }
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = rx.firstMatch(in: line, range: range), let found = Range(match.range, in: line) else { continue }
            let after = String(line[found.upperBound...])
            // the value is beside the label, or something else follows it: not a header box
            if after.hasAsciiDigit { continue }
            let headerColumns = line.components(separatedBy: "   ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let column = headerColumns.firstIndex { Rx.test($0, "(?:" + label + ")", ci: true) }
            for next in lines.dropFirst(index + 1).prefix(rows) {
                let cells = next.components(separatedBy: "   ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if let column, headerColumns.count > 1, cells.count == headerColumns.count, let value = pick(cells[column]) { return value }
                // otherwise the first usable word on the row
                for cell in cells {
                    if let value = pick(cell) { return value }
                    for word in cell.split(separator: " ").map(String.init) {
                        if let value = pick(word) { return value }
                    }
                }
            }
        }
        return nil
    }
}
