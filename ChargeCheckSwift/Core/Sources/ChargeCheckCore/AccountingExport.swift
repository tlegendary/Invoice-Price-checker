import Foundation

/// Bills for the accountant's software. Each invoice is exported exactly as the supplier issued it
/// (its net and VAT), because that is the bill in the books; what ChargeCheck caught goes in the description,
/// and the credit, when it arrives, is booked as the supplier's credit note.
public enum AccountingExport {
    public struct Options: Sendable {
        /// Expense account, e.g. Xero UK's "310" (Cost of Goods Sold).
        public var accountCode: String
        /// Tax rate names as set up in the accounting software.
        public var vatTaxType: String
        public var noVatTaxType: String
        public var mainCurrency: String

        public init(accountCode: String = "310", vatTaxType: String = "20% (VAT on Expenses)", noVatTaxType: String = "No VAT",
                    mainCurrency: String = "GBP") {
            self.accountCode = accountCode
            self.vatTaxType = vatTaxType
            self.noVatTaxType = noVatTaxType
            self.mainCurrency = mainCurrency
        }
    }

    static func day(_ date: Date) -> String {
        let parts = ReportMaths.ukCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d/%02d/%04d", parts.day ?? 0, parts.month ?? 0, parts.year ?? 0)
    }

    /// One bill's figures, shared by both formats.
    struct Bill {
        var supplier, number, date, due, description, currency: String
        var net, vat: Double
    }

    static func bills(_ entries: [HistoryEntry], creditDays: (HistoryEntry) -> Int, options: Options) -> [Bill] {
        entries.filter { $0.duplicateOf == nil }.map { entry in
            let start = DueDates.start(of: entry)
            let due = DueDates.dueDate(of: entry, days: creditDays(entry), calendar: ReportMaths.ukCalendar)
            let net = Money.round2(entry.net)
            let vat = Money.round2(max(0, entry.total - entry.net))
            var text = entry.invNo.isEmpty ? CoreText.t("Invoice") : CoreText.t("Invoice") + " " + entry.invNo
            if entry.over > 0.005 { text += " · " + CoreText.t("Overcharged") + " " + ReportMaths.amount(entry.over) }
            if entry.excluded > 0.005 { text += " · " + CoreText.t("Missing/returned") + " " + ReportMaths.amount(entry.excluded) }
            let supplier = entry.supplier.trimmingCharacters(in: .whitespaces)
            return Bill(supplier: supplier.isEmpty ? CoreText.t("Supplier") : supplier,
                        number: entry.invNo.isEmpty ? "CC-" + String(entry.id.prefix(8)) : entry.invNo,
                        date: day(start), due: day(due), description: text,
                        currency: entry.currency ?? options.mainCurrency, net: net, vat: vat)
        }
    }

    private static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(ReportMaths.cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Xero › Purchases › Bills › Import (column names exactly as Xero's template). Choose "Tax exclusive" when importing.
    public static func xeroBills(_ entries: [HistoryEntry], creditDays: (HistoryEntry) -> Int, options: Options = Options()) -> String {
        var rows = [["*ContactName", "*InvoiceNumber", "*InvoiceDate", "*DueDate", "Description", "*Quantity", "*UnitAmount",
                     "*AccountCode", "*TaxType", "TaxAmount", "Currency"]]
        for bill in bills(entries, creditDays: creditDays, options: options) {
            rows.append([bill.supplier, bill.number, bill.date, bill.due, bill.description, "1", ReportMaths.amount(bill.net),
                         options.accountCode, bill.vat > 0.005 ? options.vatTaxType : options.noVatTaxType,
                         ReportMaths.amount(bill.vat), bill.currency])
        }
        return csv(rows)
    }

    /// QuickBooks Online › Settings › Import data › Bills (QuickBooks lets you match the columns when importing).
    public static func quickBooksBills(_ entries: [HistoryEntry], creditDays: (HistoryEntry) -> Int, options: Options = Options()) -> String {
        var rows = [["Bill No", "Supplier", "Bill Date", "Due Date", "Account", "Line Description", "Line Amount", "Line VAT Code", "Line VAT Amount", "Currency"]]
        for bill in bills(entries, creditDays: creditDays, options: options) {
            rows.append([bill.number, bill.supplier, bill.date, bill.due, options.accountCode, bill.description, ReportMaths.amount(bill.net),
                         bill.vat > 0.005 ? "20.0% S" : "No VAT", ReportMaths.amount(bill.vat), bill.currency])
        }
        return csv(rows)
    }
}
