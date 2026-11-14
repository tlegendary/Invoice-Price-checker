import Foundation

/// What to pay one supplier for the chosen invoices.
public struct SupplierPay: Identifiable, Equatable, Sendable {
    public var name: String
    public var entries: [HistoryEntry]
    public var total: Double
    public var less: Double
    public var pay: Double
    public var hasMissing: Bool
    public var id: String { name }
}

public struct PaySummary: Equatable, Sendable {
    /// Invoices not yet marked as paid.
    public var unpaid: [HistoryEntry]
    /// The unpaid invoices the user has ticked (all of them unless some were unticked).
    public var selected: [HistoryEntry]
    public var suppliers: [SupplierPay]
    public var total: Double
    public var less: Double
    public var pay: Double
    /// True when the amounts above are before VAT.
    public var beforeVat = false
    /// The amount to pay before VAT and with VAT, whichever way the amounts above are shown.
    public var payBeforeVat: Double = 0
    public var payWithVat: Double = 0
    public var vat: Double { Money.round2(max(0, payWithVat - payBeforeVat)) }
    public var hasMissing: Bool { suppliers.contains { $0.hasMissing } }
}

public enum ReportPeriod: String, CaseIterable, Identifiable, Sendable {
    case lastMonth, thisMonth, thisTaxYear, lastTaxYear, all
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lastMonth: return CoreText.t("Last month")
        case .thisMonth: return CoreText.t("This month")
        case .thisTaxYear: return CoreText.t("This tax year")
        case .lastTaxYear: return CoreText.t("Last tax year")
        case .all: return CoreText.t("All time")
        }
    }
}

public enum ReportMaths {
    public static var ukCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    // MARK: - what to pay

    public static func paySummary(_ entries: [HistoryEntry], skipped: Set<String>, beforeVat: Bool = false) -> PaySummary {
        let unpaid = entries.filter { $0.paid == nil }
        let selected = unpaid.filter { !skipped.contains($0.id) }
        var order: [String] = []
        var groups: [String: SupplierPay] = [:]
        for entry in selected {
            let name = entry.supplier.isEmpty ? CoreText.t("Unknown supplier") : entry.supplier
            let amounts = entry.amountToPay(beforeVat: beforeVat)
            var group = groups[name] ?? SupplierPay(name: name, entries: [], total: 0, less: 0, pay: 0, hasMissing: false)
            if groups[name] == nil { order.append(name) }
            group.entries.append(entry)
            group.total += amounts.total
            group.less += amounts.less
            group.pay += amounts.pay
            group.hasMissing = group.hasMissing || entry.excluded > 0
            groups[name] = group
        }
        var suppliers = order.compactMap { groups[$0] }.map { group -> SupplierPay in
            var g = group
            g.total = Money.round2(g.total)
            g.less = Money.round2(g.less)
            g.pay = Money.round2(g.pay)
            return g
        }
        suppliers.sort { $0.pay != $1.pay ? $0.pay > $1.pay : $0.name < $1.name }
        return PaySummary(unpaid: unpaid, selected: selected, suppliers: suppliers,
                          total: Money.round2(suppliers.reduce(0) { $0 + $1.total }),
                          less: Money.round2(suppliers.reduce(0) { $0 + $1.less }),
                          pay: Money.round2(suppliers.reduce(0) { $0 + $1.pay }),
                          beforeVat: beforeVat,
                          payBeforeVat: Money.round2(selected.reduce(0) { $0 + $1.amountToPayBeforeVat.pay }),
                          payWithVat: Money.round2(selected.reduce(0) { $0 + $1.amountToPay.pay }))
    }

    // MARK: - credits

    /// Credits asked for but not received yet: how many, and how much in all.
    public static func creditsOwed(_ entries: [HistoryEntry]) -> (count: Int, amount: Double) {
        let owed = entries.filter { $0.credit?.isOwed == true }
        return (owed.count, Money.round2(owed.reduce(0) { $0 + ($1.credit?.amount ?? 0) }))
    }

    /// Credits received, how many and how much in all – money won back.
    public static func creditsReceived(_ entries: [HistoryEntry]) -> (count: Int, amount: Double) {
        let got = entries.filter { $0.credit?.status == CreditInfo.received }
        return (got.count, Money.round2(got.reduce(0) { $0 + ($1.credit?.amount ?? 0) }))
    }

    /// Credits the supplier refused, written off: how many and how much.
    public static func creditsWrittenOff(_ entries: [HistoryEntry]) -> (count: Int, amount: Double) {
        let lost = entries.filter { $0.credit?.status == CreditInfo.writtenOff }
        return (lost.count, Money.round2(lost.reduce(0) { $0 + ($1.credit?.amount ?? 0) }))
    }

    /// A ready-to-send message asking the supplier for a credit note (same wording as the old app).
    public static func creditText(_ entry: HistoryEntry, business: String, code: String? = nil) -> String {
        let t = CoreText.t
        var s = t("Hello{1},", entry.supplier.isEmpty ? "" : " " + entry.supplier) + "\n\n"
        s += t("I've checked the invoice below against our agreed prices and found the following differences:") + "\n\n"
        s += t("Invoice") + (entry.invNo.isEmpty ? "" : " #" + entry.invNo) + (entry.date.isEmpty ? "" : " (" + entry.date + ")") + "\n"
        func qty(_ q: Double) -> String { q == q.rounded() ? String(Int(q)) : String(q) }
        for line in entry.lines where !line.excluded && line.over > 0.005 {
            let name = line.desc.isEmpty ? line.item : line.desc
            let base = line.base.map { t(", agreed {1}", Money.format($0, code: code)) } ?? ""
            s += "• " + t("{1} x {2} – charged {3}{4}: {5}", qty(line.qty), name, Money.format(line.unit, code: code), base, Money.format(line.over, code: code)) + "\n"
        }
        for line in entry.lines where line.excluded {
            let name = line.desc.isEmpty ? line.item : line.desc
            s += "• " + t("{1} x {2} – not received / returned: {3}", qty(line.qty), name, Money.format(Money.round2(line.qty * line.unit), code: code)) + "\n"
        }
        for line in entry.lines where !line.excluded && line.short > 0 {
            let name = line.desc.isEmpty ? line.item : line.desc
            s += "• " + t("{1} x {2} – not received / returned: {3}", qty(line.short), name, Money.format(Money.round2(line.short * line.unit), code: code)) + "\n"
        }
        let less = entry.amountToPay.less
        s += "\n" + t("Total to credit: {1}", Money.format(less, code: code)) + (entry.overVat > 0.005 ? t(" (incl. VAT)") : "") + "\n\n"
        s += t("Please could you issue a credit note for this amount.") + "\n\n" + t("Thank you,") + "\n" + (business.isEmpty ? "" : business)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A text breakdown to send to a supplier with the payment.
    public static func paymentText(_ summary: PaySummary, today: String) -> String {
        let t = CoreText.t
        var lines = [t("Payment summary – {1}", today), ""]
        for supplier in summary.suppliers {
            lines.append(supplier.name)
            for entry in supplier.entries {
                let amounts = entry.amountToPay(beforeVat: summary.beforeVat)
                var line = "  " + (entry.invNo.isEmpty ? t("Invoice") : t("Invoice {1}", entry.invNo))
                if !entry.date.isEmpty { line += " · " + entry.date }
                line += " · " + Money.format(amounts.total)
                if amounts.less > 0 {
                    line += " " + t(entry.excluded > 0 ? "less {1} overcharged/missing = {2}" : "less {1} overcharged = {2}",
                                    Money.format(amounts.less), Money.format(amounts.pay))
                }
                lines.append(line)
            }
            lines.append("  " + t("Pay {1}: {2}", supplier.name, Money.format(supplier.pay)))
            lines.append("")
        }
        var last = t("Total to pay: {1}", Money.format(summary.pay))
        if summary.less > 0 { last += " " + t("(invoices {1} less {2} taken off)", Money.format(summary.total), Money.format(summary.less)) }
        lines.append(last)
        lines.append(summary.beforeVat ? t("Amounts are before VAT (no VAT added).") : t("Amounts include VAT."))
        return lines.joined(separator: "\n")
    }

    // MARK: - dates and periods

    /// The invoice date (dd/mm/yyyy on the invoice), or when it was saved if the date is missing.
    public static func date(of entry: HistoryEntry) -> Date? {
        let parts = entry.date.split(whereSeparator: { $0 == "/" || $0 == "." || $0 == "-" }).compactMap { Int($0) }
        if parts.count == 3, (1...31).contains(parts[0]), (1...12).contains(parts[1]) {
            let year = parts[2] < 100 ? 2000 + parts[2] : parts[2]
            if let date = ukCalendar.date(from: DateComponents(year: year, month: parts[1], day: parts[0], hour: 12)) { return date }
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: entry.savedAt) ?? ISO8601DateFormatter().date(from: entry.savedAt)
    }

    /// Start (inclusive) and end (exclusive) of a period. The UK tax year starts on 6 April.
    public static func range(_ period: ReportPeriod, now: Date) -> (start: Date, end: Date)? {
        let calendar = ukCalendar
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        func make(_ y: Int, _ m: Int, _ d: Int) -> Date? { calendar.date(from: DateComponents(year: y, month: m, day: d)) }
        switch period {
        case .all:
            return nil
        case .thisMonth:
            guard let start = make(year, month, 1), let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
            return (start, end)
        case .lastMonth:
            guard let end = make(year, month, 1), let start = calendar.date(byAdding: .month, value: -1, to: end) else { return nil }
            return (start, end)
        case .thisTaxYear, .lastTaxYear:
            var startYear = (month > 4 || (month == 4 && day >= 6)) ? year : year - 1
            if period == .lastTaxYear { startYear -= 1 }
            guard let start = make(startYear, 4, 6), let end = make(startYear + 1, 4, 6) else { return nil }
            return (start, end)
        }
    }

    public static func entries(_ all: [HistoryEntry], in period: ReportPeriod, now: Date) -> [HistoryEntry] {
        guard let range = range(period, now: now) else { return all }
        return all.filter { entry in
            guard let date = date(of: entry) else { return false }
            return date >= range.start && date < range.end
        }
    }

    // MARK: - spreadsheets (CSV opens in Excel, Numbers and Google Sheets)

    static func cell(_ text: String) -> String {
        // quote when needed, and stop a cell being run as a formula by a spreadsheet
        var value = text
        if let first = value.first, "=+-@".contains(first), Double(value) == nil { value = "'" + value }
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            value = "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    static func amount(_ value: Double) -> String { String(format: "%.2f", value) }

    public static func reportCSV(_ entries: [HistoryEntry]) -> String {
        let t = CoreText.t
        var rows = [["Date", "Supplier", "Invoice no.", "Net", "Total inc VAT", "Overcharged", "Overcharged VAT", "Missing/returned", "To pay", "Paid", "Fully checked"].map { t($0) }]
        for entry in entries {
            rows.append([entry.date, entry.supplier, entry.invNo, amount(entry.net), amount(entry.total), amount(entry.over), amount(entry.overVat),
                         amount(entry.excluded), amount(entry.amountToPay.pay), entry.paid == nil ? t("No") : t("Yes"), entry.verified ? t("Yes") : t("No")])
        }
        rows.append([])
        rows.append([t("Overcharged lines")])
        rows.append(["Date", "Supplier", "Invoice no.", "Item", "Quantity", "Charged", "Agreed price", "Overcharged"].map { t($0) })
        for entry in entries {
            for line in entry.lines where line.over > 0.005 && !line.excluded {
                rows.append([entry.date, entry.supplier, entry.invNo, line.item.isEmpty ? line.desc : line.item, amount(line.qty), amount(line.unit),
                             line.base.map(amount) ?? "", amount(line.over)])
            }
        }
        return rows.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    public static func pricesCSV(_ items: [PriceItem]) -> String {
        var rows = [["Category", "Item", "Agreed price", "Supplier", "On invoices as"].map { CoreText.t($0) }]
        for item in items.sorted(by: { $0.cat != $1.cat ? $0.cat < $1.cat : $0.name < $1.name }) {
            rows.append([item.cat, item.name, amount(item.price), item.supplier, item.aliases.joined(separator: "; ")])
        }
        return rows.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// A tidy file name for a copy of an invoice: "2026-11-06 Supplier 82044".
    public static func copyName(for entry: HistoryEntry) -> String {
        var day = "undated"
        if let date = date(of: entry) {
            let parts = ukCalendar.dateComponents([.year, .month, .day], from: date)
            day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        func clean(_ text: String) -> String {
            let allowed = text.map { ch -> Character in (ch.isLetter || ch.isNumber || ch == " " || ch == "-" || ch == "." || ch == "(" || ch == ")") ? ch : " " }
            return String(String(allowed).split(separator: " ").joined(separator: " ").prefix(40))
        }
        let supplier = clean(entry.supplier)
        return [day, supplier.isEmpty ? "Invoice" : supplier, clean(entry.invNo)].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
