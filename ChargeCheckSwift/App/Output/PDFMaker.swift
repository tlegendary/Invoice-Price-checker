import UIKit
import SwiftUI
import ChargeCheckCore

/// Draws simple A4 documents: a coloured title band, headings, text and tables that run over pages.
final class PDFPage {
    static let size = CGSize(width: 595, height: 842)   // A4 in points
    let margin: CGFloat = 36
    let theme: AppTheme
    let title: String
    let subtitle: String
    private let context: UIGraphicsPDFRendererContext
    private(set) var y: CGFloat = 0
    private var pageNumber = 0
    /// Arabic and Kurdish: the page reads right to left (text on the right, tables mirrored).
    let rtl: Bool = Locale.Language(identifier: Bundle.main.preferredLocalizations.first ?? "en").characterDirection == .rightToLeft

    var width: CGFloat { PDFPage.size.width - margin * 2 }

    init(context: UIGraphicsPDFRendererContext, title: String, subtitle: String, theme: AppTheme) {
        self.context = context
        self.title = title
        self.subtitle = subtitle
        self.theme = theme
        newPage()
    }

    private func newPage() {
        context.beginPage()
        pageNumber += 1
        if pageNumber == 1 {
            UIColor(theme.dark).setFill()
            context.fill(CGRect(x: 0, y: 0, width: PDFPage.size.width, height: 78))
            draw(title, at: CGPoint(x: margin, y: 20), font: .boldSystemFont(ofSize: 20), colour: .white, width: width)
            draw(subtitle, at: CGPoint(x: margin, y: 48), font: .systemFont(ofSize: 10), colour: UIColor.white.withAlphaComponent(0.85), width: width)
            y = 98
        } else {
            y = margin
        }
        let footer = "ChargeCheck · " + String(localized: "page \(pageNumber)")
        draw(footer, at: CGPoint(x: margin, y: PDFPage.size.height - 26), font: .systemFont(ofSize: 8), colour: .gray, width: width, alignment: .right)
    }

    private func room(_ height: CGFloat) {
        if y + height > PDFPage.size.height - 40 { newPage() }
    }

    private func draw(_ text: String, at point: CGPoint, font: UIFont, colour: UIColor, width: CGFloat, alignment: NSTextAlignment = .left, wraps: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = rtl ? (alignment == .left ? .right : alignment == .right ? .left : alignment) : alignment
        if rtl { style.baseWritingDirection = .rightToLeft }
        style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour, .paragraphStyle: style]
        let height = wraps ? 2000 : font.lineHeight + 2
        (text as NSString).draw(with: CGRect(x: point.x, y: point.y, width: width, height: height),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil)
    }

    func space(_ points: CGFloat = 10) {
        y += points
    }

    func heading(_ text: String) {
        let text = L(text)
        room(40)
        y += 6
        draw(text, at: CGPoint(x: margin, y: y), font: .boldSystemFont(ofSize: 12), colour: UIColor(theme.dark), width: width)
        y += 20
    }

    func paragraph(_ text: String, size: CGFloat = 10, bold: Bool = false, colour: UIColor = .black) {
        let text = L(text)
        let font: UIFont = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        let bounds = (text as NSString).boundingRect(with: CGSize(width: width, height: 4000), options: [.usesLineFragmentOrigin],
                                                    attributes: [.font: font], context: nil)
        let height = ceil(bounds.height) + 4
        room(height)
        draw(text, at: CGPoint(x: margin, y: y), font: font, colour: colour, width: width, wraps: true)
        y += height
    }

    /// Label on the left, value on the right.
    func pair(_ label: String, _ value: String, bold: Bool = false) {
        let label = L(label)
        room(18)
        let font: UIFont = bold ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 10)
        draw(label, at: CGPoint(x: rtl ? margin + width * 0.35 : margin, y: y), font: font, colour: .black, width: width * 0.65)
        draw(value, at: CGPoint(x: margin, y: y), font: font, colour: .black, width: width, alignment: .right)
        y += 17
    }

    /// A table. `widths` are shares of the page width; `right` are the columns to line up on the right (numbers).
    func table(headers: [String], widths: [CGFloat], right: Set<Int> = [], rows: [[String]], footer: [String]? = nil) {
        let headers = headers.map(L)
        let footer = footer?.map(L)
        let total = widths.reduce(0, +)
        let columns = widths.map { $0 / total * width }
        let rowHeight: CGFloat = 17

        func row(_ cells: [String], font: UIFont, colour: UIColor, fill: UIColor?) {
            if let fill {
                fill.setFill()
                context.fill(CGRect(x: margin, y: y, width: width, height: rowHeight))
            }
            var x = margin
            for (index, cell) in cells.enumerated() where index < columns.count {
                // right to left: the first column starts on the right
                let left = rtl ? margin + width - (x - margin) - columns[index] : x
                draw(cell, at: CGPoint(x: left + 4, y: y + 3), font: font, colour: colour, width: columns[index] - 8, alignment: right.contains(index) ? .right : .left)
                x += columns[index]
            }
            y += rowHeight
        }

        func header() {
            row(headers, font: .boldSystemFont(ofSize: 9), colour: .white, fill: UIColor(theme.main))
        }

        room(rowHeight * 3)
        header()
        for (index, cells) in rows.enumerated() {
            if y + rowHeight > PDFPage.size.height - 40 {
                newPage()
                header()
            }
            row(cells, font: .systemFont(ofSize: 9), colour: .black, fill: index % 2 == 1 ? UIColor(theme.main).withAlphaComponent(0.06) : nil)
        }
        if let footer {
            room(rowHeight)
            row(footer, font: .boldSystemFont(ofSize: 9), colour: UIColor(theme.dark), fill: UIColor(theme.main).withAlphaComponent(0.14))
        }
        y += 8
    }
}

enum PDFMaker {
    static func make(title: String, subtitle: String, theme: AppTheme, _ body: (PDFPage) -> Void) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: PDFPage.size))
        return renderer.pdfData { context in
            body(PDFPage(context: context, title: L(title), subtitle: subtitle, theme: theme))
        }
    }

    private static func stamp(_ business: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy HH:mm"
        return (business.isEmpty ? "" : business + " · ") + L("Created") + " " + formatter.string(from: Date())
    }

    /// The report for the accountant: totals, every invoice, and every overcharged line.
    static func report(_ entries: [HistoryEntry], period: String, business: String, theme: AppTheme) -> Data {
        make(title: "Invoice check report", subtitle: period + " · " + stamp(business), theme: theme) { page in
            let net = Money.round2(entries.reduce(0) { $0 + $1.net })
            let total = Money.round2(entries.reduce(0) { $0 + $1.total })
            let over = Money.round2(entries.reduce(0) { $0 + $1.over })
            let overVat = Money.round2(entries.reduce(0) { $0 + $1.overVat })
            page.heading("Summary")
            page.pair("Invoices checked", "\(entries.count)")
            page.pair("Spend checked (net)", Money.format(net))
            page.pair("Invoice totals (with VAT)", Money.format(total))
            page.pair("Overcharged (net)", Money.format(over), bold: true)
            if overVat > 0 { page.pair("VAT on overcharges", Money.format(overVat)) }

            var bySupplier: [String: (count: Int, net: Double, over: Double)] = [:]
            for entry in entries {
                let name = entry.supplier.isEmpty ? L("Unknown supplier") : entry.supplier
                var row = bySupplier[name] ?? (0, 0, 0)
                row.count += 1
                row.net += entry.net
                row.over += entry.over
                bySupplier[name] = row
            }
            page.heading("By supplier")
            page.table(headers: ["Supplier", "Invoices", "Spend (net)", "Overcharged"], widths: [5, 1.5, 2, 2], right: [1, 2, 3],
                       rows: bySupplier.sorted { $0.value.over != $1.value.over ? $0.value.over > $1.value.over : $0.key < $1.key }
                        .map { [$0.key, "\($0.value.count)", Money.format(Money.round2($0.value.net)), Money.format(Money.round2($0.value.over))] })

            page.heading("Invoices")
            page.table(headers: ["Date", "Supplier", "Invoice no.", "Net", "Total", "Overcharged", "Paid"], widths: [1.6, 4, 1.8, 1.7, 1.7, 1.9, 1], right: [3, 4, 5],
                       rows: entries.map { [$0.date, $0.supplier, $0.invNo, Money.format($0.net), Money.format($0.total), Money.format($0.over), $0.paid == nil ? "" : L("Yes")] },
                       footer: ["", "Total", "", Money.format(net), Money.format(total), Money.format(over), ""])

            var lines: [[String]] = []
            for entry in entries {
                for line in entry.lines where line.over > 0.005 && !line.excluded {
                    lines.append([entry.date, entry.supplier, line.item.isEmpty ? line.desc : line.item, quantity(line.qty), Money.format(line.unit),
                                  line.base.map { Money.format($0) } ?? "", Money.format(line.over)])
                }
            }
            if !lines.isEmpty {
                page.heading("Overcharged items")
                page.table(headers: ["Date", "Supplier", "Item", "Qty", "Charged", "Agreed", "Over"], widths: [1.6, 2.6, 4, 0.9, 1.5, 1.5, 1.5], right: [3, 4, 5, 6], rows: lines)
            }
        }
    }

    static func quantity(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    static func priceList(_ items: [PriceItem], business: String, theme: AppTheme) -> Data {
        make(title: "Agreed price list", subtitle: stamp(business), theme: theme) { page in
            let groups = Dictionary(grouping: items, by: { $0.cat }).sorted { $0.key < $1.key }
            for group in groups {
                page.heading(group.key)
                page.table(headers: ["Item", "Supplier", "Agreed price"], widths: [5.5, 3, 1.8], right: [2],
                           rows: group.value.sorted { $0.name < $1.name }.map { [$0.name, $0.supplier, Money.format($0.price)] })
            }
            if items.isEmpty { page.paragraph("No prices yet.") }
        }
    }

    /// A credit request to send to a supplier for one invoice.
    static func creditRequest(_ entry: HistoryEntry, business: String, theme: AppTheme) -> Data {
        make(title: "Credit request", subtitle: stamp(business), theme: theme) { page in
            page.pair("To", entry.supplier.isEmpty ? L("Supplier") : entry.supplier, bold: true)
            if !business.isEmpty { page.pair("From", business) }
            if !entry.invNo.isEmpty { page.pair("Invoice no.", entry.invNo) }
            if !entry.date.isEmpty { page.pair("Invoice date", entry.date) }
            page.space(8)
            page.paragraph("The items below were charged above our agreed prices, or were missing or returned. Please issue a credit note for the amount shown.")
            page.space(6)
            var rows: [[String]] = []
            for line in entry.lines where line.over > 0.005 && !line.excluded {
                rows.append([line.item.isEmpty ? line.desc : line.item, quantity(line.qty), Money.format(line.unit), line.base.map { Money.format($0) } ?? "", Money.format(line.over)])
            }
            if !rows.isEmpty {
                page.heading("Charged above the agreed price")
                page.table(headers: ["Item", "Qty", "Charged", "Agreed", "Overcharged"], widths: [5, 1, 1.6, 1.6, 1.8], right: [1, 2, 3, 4], rows: rows)
            }
            let missing = entry.lines.filter { $0.excluded }
            if !missing.isEmpty {
                page.heading("Missing or returned")
                page.table(headers: ["Item", "Qty", "Price", "Amount"], widths: [5, 1, 1.6, 1.8], right: [1, 2, 3],
                           rows: missing.map { [$0.item.isEmpty ? $0.desc : $0.item, quantity($0.qty), Money.format($0.unit), Money.format(Money.round2($0.qty * $0.unit))] })
            }
            let amounts = entry.amountToPay
            page.space(6)
            page.pair("Invoice total (with VAT)", Money.format(amounts.total))
            page.pair("Credit requested (with VAT)", Money.format(amounts.less), bold: true)
            page.pair("Amount we will pay", Money.format(amounts.pay), bold: true)
        }
    }

    /// One supplier: their account, score, open invoices, payments, price rises and overcharges.
    static func supplierReport(_ account: SupplierAccount, profile: SupplierProfile, due: [DueInvoice], business: String, theme: AppTheme) -> Data {
        make(title: "Supplier report", subtitle: account.name + " · " + stamp(business), theme: theme) { page in
            page.heading("Account")
            page.pair("You owe", Money.format(account.balance), bold: true)
            if account.opening != 0 { page.pair("Starting balance", Money.format(account.opening)) }
            page.pair("Invoices", Money.format(account.invoiced))
            if account.paid > 0.005 { page.pair("Payments", "−" + Money.format(account.paid)) }
            if account.credits > 0.005 { page.pair("Credit notes", "−" + Money.format(account.credits)) }
            if let last = account.lastPayment { page.pair("Last payment", Money.format(last.amount) + " · " + PayDates.show(last.date)) }

            page.heading("Purchases")
            page.pair("Invoices checked", "\(profile.invoices)")
            page.pair("This month", Money.format(profile.purchasesThisMonth))
            page.pair("Last month", Money.format(profile.purchasesLastMonth))
            page.pair("Average invoice", Money.format(profile.averageInvoice))
            page.pair("All invoices", Money.format(profile.totalBought))
            page.pair("Overcharged", Money.format(profile.overcharged))
            page.pair("Missing or short", Money.format(profile.missing))
            page.pair("Invoices with a problem", "\(profile.disputed)")
            if profile.creditsOwed > 0.005 { page.pair("Credits still owed", Money.format(profile.creditsOwed)) }

            page.heading("Score")
            page.pair("Supplier score", profile.score.map { "\($0) / 100" } ?? L("Not enough invoices yet"), bold: true)
            func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "–" }
            page.pair("Charged the agreed price", percent(profile.parts.invoiceAccuracy))
            page.pair("Delivered in full", percent(profile.parts.deliveryAccuracy))
            page.pair("Prices that stayed the same (90 days)", percent(profile.parts.priceStability))
            page.pair("Cheapest for items you also buy elsewhere", percent(profile.parts.priceCompetitiveness))

            if !account.open.isEmpty {
                let dueByID = Dictionary(due.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                page.heading("Still to pay")
                page.table(headers: ["Date", "Invoice no.", "Due", "To pay"], widths: [2, 2.5, 2.5, 2], right: [3],
                           rows: account.open.reversed().map { entry in
                               [entry.date, entry.invNo, dueByID[entry.id].map { PayDates.show($0.dueDate) } ?? "", Money.format(entry.amountToPay.pay)]
                           },
                           footer: ["", "Total", "", Money.format(Money.round2(account.open.reduce(0) { $0 + $1.amountToPay.pay }))])
            }
            let paid = account.payments.filter { $0.amount > 0.005 }
            if !paid.isEmpty {
                page.heading("Payments and credits")
                page.table(headers: ["Date", "Type", "Method", "Reference", "Amount"], widths: [1.8, 2, 1.6, 2.4, 1.8], right: [4],
                           rows: paid.map { payment in
                               let kind = payment.kind == .credit ? L("Credit note") : payment.kind == .opening ? L("Older amount owed") : L("Payment")
                               return [PayDates.show(payment.date), kind, PayMethod.name(payment.method), payment.reference,
                                       Money.format(payment.amount)]
                           })
            }
            let rises = Insights.priceRises(account.entries)
            if !rises.isEmpty {
                page.heading("Price rises")
                page.table(headers: ["Date", "Item", "Before", "Now", "Change"], widths: [1.8, 4, 1.6, 1.6, 1.4], right: [2, 3, 4],
                           rows: rises.prefix(40).map { [PayDates.show($0.when), $0.item, Money.format($0.from), Money.format($0.to),
                                                         String(format: "+%.1f%%", $0.percent)] })
            }
            var lines: [[String]] = []
            for entry in account.entries {
                for line in entry.lines where (line.over > 0.005 && !line.excluded) || line.excluded || line.short > 0 {
                    let problem = line.excluded ? L("missing or returned") : line.short > 0 ? L("short") : L("overcharged")
                    let amount = line.excluded ? Money.round2(line.qty * line.unit) : line.short > 0 ? Money.round2(line.short * line.unit) : line.over
                    lines.append([entry.date, entry.invNo, line.item.isEmpty ? line.desc : line.item, problem, Money.format(amount)])
                }
            }
            if !lines.isEmpty {
                page.heading("Problems found")
                page.table(headers: ["Date", "Invoice no.", "Item", "Problem", "Amount"], widths: [1.6, 1.8, 3.8, 2, 1.6], right: [4], rows: Array(lines.prefix(80)))
            }
        }
    }

    /// Several scanned pages as one PDF (to keep a copy of a multi-page invoice).
    static func pages(_ images: [UIImage]) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: PDFPage.size))
        return renderer.pdfData { context in
            for image in images {
                let bounds = CGRect(origin: .zero, size: image.size)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                image.draw(in: bounds)
            }
        }
    }
}
