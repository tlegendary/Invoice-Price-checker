import Foundation

/// Words the core shows to people. The app plugs in its translations; on its own (and in tests) it's English.
/// Placeholders are {1}, {2}… so the same key works in every language whatever the word order.
public enum CoreText {
    public static var translate: (String) -> String = { $0 }

    static func t(_ key: String, _ args: String...) -> String {
        var text = translate(key)
        for (index, value) in args.enumerated() {
            text = text.replacingOccurrences(of: "{\(index + 1)}", with: value)
        }
        return text
    }

    /// Every key, so the app can check its translations are complete.
    public static let keys: [String] = [
        "The two reads of the photo didn't agree on this line.",
        "Only found on the second read – make sure it's really on the invoice.",
        "Not in your price list – choose the matching item or mark it as not in your list.",
        "Not 100% sure this is “{1}”.",
        "Price is very different from your price ({1}) – wrong item or misread?",
        "Quantity was hard to read – worked out {1} from the line total. Check.",
        "Price was hard to read – worked out from the line total. Check.",
        "Couldn't confirm this price against the line total – check the price and quantity.",
        "Quantity and price were hard to read – check this line.",
        "Last month", "This month", "This tax year", "Last tax year", "All time",
        "Unknown supplier",
        "Hello{1},",
        "I've checked the invoice below against our agreed prices and found the following differences:",
        "Invoice",
        "{1} x {2} – charged {3}{4}: {5}",
        ", agreed {1}",
        "{1} x {2} – not received / returned: {3}",
        "Total to credit: {1}",
        " (incl. VAT)",
        "Please could you issue a credit note for this amount.",
        "Thank you,",
        "Payment summary – {1}",
        "Invoice {1}",
        "less {1} overcharged/missing = {2}",
        "less {1} overcharged = {2}",
        "Pay {1}: {2}",
        "(invoices {1} less {2} taken off)",
        "Total to pay: {1}",
        "Amounts include VAT.",
        "Amounts are before VAT (no VAT added).",
        "Date", "Supplier", "Invoice no.", "Net", "Total inc VAT", "Overcharged", "Overcharged VAT", "Missing/returned",
        "To pay", "Paid", "Fully checked", "Overcharged lines", "Item", "Quantity", "Charged", "Agreed price", "Category",
        "On invoices as", "Yes", "No"
    ]
}
