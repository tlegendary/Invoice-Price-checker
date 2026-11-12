import Foundation

/// One line of a supplier's statement: an invoice they say they sent, a payment they received, or a credit note.
public struct StatementLine: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case invoice, payment, credit }

    public var id: String { "\(kind.rawValue)|\(reference)|\(date)|\(amount)" }
    public var kind: Kind
    public var date: String
    /// The invoice or credit note number on the line ("" for most payments).
    public var reference: String
    public var amount: Double
    public var text: String

    public init(kind: Kind, date: String, reference: String, amount: Double, text: String) {
        self.kind = kind
        self.date = date
        self.reference = reference
        self.amount = amount
        self.text = text
    }
}

/// What a statement says, read from its text.
public struct ParsedStatement: Equatable, Sendable {
    public var lines: [StatementLine]
    /// The balance the supplier says you owe ("Balance due", "Amount due"…), if printed.
    public var balance: Double?
}

/// The statement compared with your own invoices and payments.
public struct StatementResult: Equatable, Sendable {
    public struct Mismatch: Identifiable, Equatable, Sendable {
        public var id: String { line.id }
        public var line: StatementLine
        /// Your invoice with the same number.
        public var invoiceID: String
        public var yours: Double
    }

    /// Invoices on the statement that match one in Reports.
    public var matched: [StatementLine]
    /// Same invoice number, different amount.
    public var amountDiffers: [Mismatch]
    /// On the statement but not in Reports: you haven't checked it, or never got it.
    public var notInReports: [StatementLine]
    /// Your invoices from the statement's dates that the statement doesn't list.
    public var notOnStatement: [HistoryEntry]
    /// Payments you recorded in those dates that the statement doesn't show.
    public var paymentsNotCounted: [SupplierPayment]
    /// Payments and credits on the statement that match yours.
    public var paymentsMatched: [StatementLine]
    /// Payments or credits on the statement you have no record of.
    public var paymentsUnknown: [StatementLine]
    /// What they say you owe, and what ChargeCheck says.
    public var theirBalance: Double?
    public var yourBalance: Double
    /// Overcharges and missing items you took off their invoices: part of any difference in balances.
    public var takenOff: Double

    public var allClear: Bool {
        amountDiffers.isEmpty && notInReports.isEmpty && paymentsNotCounted.isEmpty && paymentsUnknown.isEmpty
    }
}

public enum StatementCheck {
    static let paymentWords = ["payment", "paid", "receipt", "remittance", "bacs", "transfer", "cash", "cheque", "zahlung", "überweisung",
                               "paiement", "règlement", "virement", "دفعة", "سداد", "تحويل", "پارەدان", "دراو"]
    static let creditWords = ["credit", "cr note", "c/n", "cn ", "gutschrift", "avoir", "إشعار دائن", "اشعار دائن", "گەڕاندنەوە"]
    /// Lines carrying a balance over from another period: not an invoice or a payment.
    static let carriedWords = ["brought forward", "b/f", "b/fwd", "opening balance", "carried forward", "c/f", "übertrag", "report à nouveau",
                               "رصيد سابق", "رصيد افتتاحي"]
    static let balanceWords = ["balance due", "amount due", "total due", "balance outstanding", "total outstanding", "closing balance",
                               "balance", "saldo", "offener betrag", "solde", "montant dû", "الرصيد", "المبلغ المستحق", "باڵانس", "قەرز"]

    /// Money on a line: "1,234.56", "1.234,56", "234.56", "-12.00", "(12.00)". Whole numbers only for currencies without decimals.
    static func amounts(_ line: String) -> [Double] {
        let pattern = Money.currency.decimals == 0 ? "-?\\(?[0-9]{1,3}(?:[.,][0-9]{3})+\\)?|-?[0-9]{3,9}" : "-?\\(?[0-9]{1,3}(?:[.,]?[0-9]{3})*[.,][0-9]{2}\\)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let raw = ns.substring(with: match.range)
            let negative = raw.hasPrefix("-") || raw.hasPrefix("(")
            guard let value = Money.parse(raw.trimmingCharacters(in: CharacterSet(charactersIn: "-()"))) else { return nil }
            return negative ? -value : value
        }
    }

    static func date(_ line: String) -> String {
        Rx.group(line, "([0-9]{1,2}[/.\\-][0-9]{1,2}[/.\\-][0-9]{2,4})")
    }

    /// The invoice/credit number: the first run of 2 or more digits that isn't part of the date or a money amount.
    static func reference(_ line: String, date: String) -> String {
        var rest = date.isEmpty ? line : line.replacingOccurrences(of: date, with: " ")
        rest = Rx.replace(rest, "-?\\(?[0-9]{1,3}(?:[.,]?[0-9]{3})*[.,][0-9]{2}\\)?", " ")
        return Rx.group(rest, "([A-Za-z]{0,4}-?[0-9]{2,})")
    }

    /// Reads the statement's lines. Lines without a date and an amount (headings, addresses) are skipped.
    public static func parse(_ text: String) -> ParsedStatement {
        var lines: [StatementLine] = []
        var balance: Double?
        for raw in InvoiceParser.westernDigits(text).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            let day = date(line)
            // the date itself ("05.11.26") must not be read as an amount
            let money = amounts(day.isEmpty ? line : line.replacingOccurrences(of: day, with: " "))
            if carriedWords.contains(where: { lower.contains($0) }) { continue }
            if day.isEmpty {
                // "Balance due £1,234.56": the last such line wins (statements often print it once at the end)
                if let last = money.last, balanceWords.contains(where: { lower.contains($0) }) { balance = abs(last) }
                continue
            }
            guard let first = money.first else { continue }
            let kind: StatementLine.Kind
            if creditWords.contains(where: { lower.contains($0) }) {
                kind = .credit
            } else if paymentWords.contains(where: { lower.contains($0) }) || first < 0 {
                kind = .payment
            } else {
                kind = .invoice
            }
            // with several amounts the last is usually the running balance; the first is this line's amount
            lines.append(StatementLine(kind: kind, date: day, reference: kind == .payment ? "" : reference(line, date: day),
                                       amount: Money.round2(abs(first)), text: line))
        }
        return ParsedStatement(lines: lines, balance: balance)
    }

    static func digits(_ s: String) -> String {
        let only = s.filter { $0.isASCII && $0.isNumber }
        return String(only.drop { $0 == "0" })
    }

    /// "yyyy-MM-dd" from a statement date (day first, as on UK and European statements).
    static func isoDay(_ text: String) -> String? {
        let parts = text.split(whereSeparator: { "/.-".contains($0) }).compactMap { Int($0) }
        guard parts.count == 3, (1...31).contains(parts[0]), (1...12).contains(parts[1]) else { return nil }
        let year = parts[2] < 100 ? 2000 + parts[2] : parts[2]
        return String(format: "%04d-%02d-%02d", year, parts[1], parts[0])
    }

    /// Compares a statement with this supplier's invoices and payments in ChargeCheck.
    public static func compare(_ statement: ParsedStatement, account: SupplierAccount, payments: [SupplierPayment]) -> StatementResult {
        let theirs = account.entries
        var matched: [StatementLine] = []
        var differs: [StatementResult.Mismatch] = []
        var missing: [StatementLine] = []
        var used = Set<String>()
        for line in statement.lines where line.kind == .invoice {
            let ref = digits(line.reference)
            let byNumber = ref.isEmpty ? nil : theirs.first { !used.contains($0.id) && digits($0.invNo) == ref }
            let byAmount = byNumber == nil ? theirs.first { !used.contains($0.id) && $0.invNo.isEmpty && abs($0.total - line.amount) <= 0.05 } : nil
            if let entry = byNumber ?? byAmount {
                used.insert(entry.id)
                if abs(entry.total - line.amount) <= 0.05 {
                    matched.append(line)
                } else {
                    differs.append(.init(line: line, invoiceID: entry.id, yours: entry.total))
                }
            } else {
                missing.append(line)
            }
        }
        // the statement's dates: anything of yours in that window it doesn't list
        let days = statement.lines.compactMap { isoDay($0.date) }.sorted()
        var notOnStatement: [HistoryEntry] = []
        var notCounted: [SupplierPayment] = []
        var paymentsMatched: [StatementLine] = []
        var paymentsUnknown: [StatementLine] = []
        if let first = days.first, let last = days.last {
            notOnStatement = theirs.filter { entry in
                !used.contains(entry.id) && String(entry.savedAt.prefix(10)) >= first && String(entry.savedAt.prefix(10)) <= last
            }
            var mine = account.payments.filter { ($0.kind == .payment || $0.kind == .credit) && $0.date >= first && $0.date <= last }
            for line in statement.lines where line.kind != .invoice {
                if let index = mine.firstIndex(where: { abs($0.amount - line.amount) <= 0.05 }) {
                    mine.remove(at: index)
                    paymentsMatched.append(line)
                } else {
                    paymentsUnknown.append(line)
                }
            }
            notCounted = mine.filter { $0.kind == .payment }
        } else {
            paymentsUnknown = statement.lines.filter { $0.kind != .invoice }
        }
        let takenOff = Money.round2(theirs.filter { $0.paid == nil }.reduce(0) { $0 + $1.amountToPay.less })
        return StatementResult(matched: matched, amountDiffers: differs, notInReports: missing, notOnStatement: notOnStatement,
                               paymentsNotCounted: notCounted, paymentsMatched: paymentsMatched, paymentsUnknown: paymentsUnknown,
                               theirBalance: statement.balance, yourBalance: account.balance, takenOff: takenOff)
    }

    /// A message to the supplier listing what doesn't agree.
    public static func query(_ result: StatementResult, supplier: String, business: String) -> String {
        let t = CoreText.t
        var s = t("Hello{1},", supplier.isEmpty ? "" : " " + supplier) + "\n\n"
        s += t("I've checked your statement against our records and found these differences:") + "\n\n"
        for item in result.amountDiffers {
            s += "• " + t("Invoice {1}: your statement says {2}, our copy says {3}.", item.line.reference, Money.format(item.line.amount),
                          Money.format(item.yours)) + "\n"
        }
        for line in result.notInReports {
            s += "• " + t("Invoice {1} ({2}, {3}): we don't have this invoice. Please send a copy.", line.reference.isEmpty ? "?" : line.reference,
                          line.date, Money.format(line.amount)) + "\n"
        }
        for payment in result.paymentsNotCounted {
            s += "• " + t("Our payment of {1} on {2} isn't on your statement.", Money.format(payment.amount), payment.date) + "\n"
        }
        if let theirs = result.theirBalance, abs(theirs - result.yourBalance) > 0.05 {
            s += "\n" + t("Your statement shows {1} owed; by our records it's {2}.", Money.format(theirs), Money.format(result.yourBalance)) + "\n"
        }
        s += "\n" + t("Thank you,") + "\n" + business
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
