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
        "Not 100% sure this is “{1}”. If it is, you were overcharged {2}. Confirm the match to count it.",
        "Price is very different from your price ({1}) – wrong item or misread?",
        "Handwritten on this line: “{1}”. If it was missing or sent back, mark the line as missing or returned.",
        "The invoice says {1} but your item is {2} – check it's the same pack size.",
        "Quantity was hard to read – worked out {1} from the line total. Check.",
        "Price was hard to read – worked out from the line total. Check.",
        "Couldn't confirm this price against the line total – check the price and quantity.",
        "Quantity and price were hard to read – check this line.",
        "Discount of {1} taken off – the price shown is after the discount.",
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
        "On invoices as", "Yes", "No",
        "No shop",
        "No invoices were checked in {1}.",
        "In {1} you checked {2} invoices worth {3}.",
        "You were overcharged {1} in total, {2} of it by {3}.",
        "Nobody charged more than your agreed prices.",
        "You spent most with {1}: {2}.",
        "{1} spent the most: {2}.",
        "{1} went up at {2}, from {3} to {4}.",
        "Suppliers still owe you {1} in credits.",
        "You paid suppliers {1} this month.",
        "You owe {1} in total now.",
        "I've checked your statement against our records and found these differences:",
        "Invoice {1}: your statement says {2}, our copy says {3}.",
        "Invoice {1} ({2}, {3}): we don't have this invoice. Please send a copy.",
        "Our payment of {1} on {2} isn't on your statement.",
        "Your statement shows {1} owed; by our records it's {2}."
    ]
}
