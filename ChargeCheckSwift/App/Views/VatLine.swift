import SwiftUI
import ChargeCheckCore

/// "£1,052.68 before VAT + £210.53 VAT" under an amount to pay, wherever the app says how much to pay.
/// Nothing when there's no VAT in it. "About" when it's worked out in proportion (part-payments, a starting balance).
struct VatLine: View {
    let split: SupplierAccounts.OwedSplit?
    /// Money in the supplier's currency (nil: the main currency).
    var supplier: String?

    var body: some View {
        if let split, split.vat > 0.005 {
            Text(VatLine.text(split, supplier: supplier))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    static func text(_ split: SupplierAccounts.OwedSplit, supplier: String? = nil) -> String {
        let before = supplier.map { Money.format(split.beforeVat, supplier: $0) } ?? Money.format(split.beforeVat)
        let vat = supplier.map { Money.format(split.vat, supplier: $0) } ?? Money.format(split.vat)
        let line = String(localized: "\(before) before VAT + \(vat) VAT")
        return split.exact ? line : String(localized: "About \(line)")
    }
}
