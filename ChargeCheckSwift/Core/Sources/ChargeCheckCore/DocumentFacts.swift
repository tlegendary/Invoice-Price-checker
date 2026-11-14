import Foundation

/// What kind of paper was scanned and which currency it is in, worked out from its words and symbols.
public enum DocumentFacts {

    public enum Kind: String, Sendable {
        case invoice, creditNote, statement, deliveryNote, quote, order, receipt
    }

    /// Words that only appear on papers that aren't bills to pay. An invoice wins whenever it says "invoice"
    /// in its heading, because "delivery address" or "order no" are printed on ordinary invoices too.
    static let kinds: [(Kind, [String])] = [
        (.statement, ["statement of account", "account statement", "kontoauszug", "relevé de compte", "كشف حساب", "کەشفی حیساب"]),
        (.deliveryNote, ["delivery note", "despatch note", "dispatch note", "packing slip", "packing list", "goods received note",
                         "lieferschein", "bon de livraison", "مذكرة تسليم", "اذن تسليم", "إذن تسليم", "وصل استلام"]),
        (.quote, ["quotation", "pro forma", "proforma", "pro-forma", "estimate", "angebot", "devis", "عرض سعر", "عرض أسعار", "فاتورة مبدئية"]),
        (.order, ["purchase order", "order confirmation", "bestellung", "auftragsbestätigung", "bon de commande", "أمر شراء", "طلبية"]),
        (.receipt, ["till receipt", "cash receipt", "sales receipt", "kassenbon", "ticket de caisse", "إيصال"])
    ]

    public static func kind(_ text: String) -> Kind {
        let s = text.lowercased()
        if Insights.isCreditNote(text) { return .creditNote }
        // the top of the page decides: "Invoice" in the heading means an invoice, whatever else is printed
        let top = s.components(separatedBy: "\n").prefix(12).joined(separator: "\n")
        let saysInvoice = Rx.test(top, "\\b(tax\\s+)?invoice\\b|rechnung|facture|فاتورة|پسوولە|فاتورە", ci: true)
        for (kind, words) in kinds where words.contains(where: { top.contains($0) }) {
            if saysInvoice && kind != .statement { continue }
            return kind
        }
        return .invoice
    }

    /// The currency printed on the invoice ("GBP", "EUR", "USD", "IQD"), or nil when it doesn't say or says several equally.
    public static func currency(_ text: String) -> String? {
        func count(_ pattern: String) -> Int {
            guard let rx = Rx.regex(pattern, ci: true) else { return 0 }
            return rx.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        // whole words only: "European Foods" is not euros
        let scores: [(String, Int)] = [
            ("GBP", count("£|\\bgbp\\b|\\bsterling\\b")),
            ("EUR", count("€|\\beur\\b|\\beuros?\\b")),
            ("USD", count("\\$|\\busd\\b|\\bus\\s*dollars?\\b|دولار|دۆلار")),
            ("IQD", count("\\biqd\\b|دينار|دینار|د\\.ع|\\bi\\.q\\.d"))
        ]
        let best = scores.max { $0.1 < $1.1 }!
        guard best.1 > 0, scores.filter({ $0.1 == best.1 }).count == 1 else { return nil }
        return best.0
    }
}
