import SwiftUI
import ChargeCheckCore

/// How "To pay" is worked out for one invoice: before VAT, VAT and total, side by side, so every figure can be
/// checked by hand. Deductions come off before VAT first; the VAT on them comes off the VAT.
struct PayWorkings: View {
    let entry: HistoryEntry
    @State private var open = false

    var body: some View {
        let p = entry.payment
        DisclosureGroup(isExpanded: $open) {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Before VAT").font(.caption.weight(.semibold))
                    Text("VAT").font(.caption.weight(.semibold))
                    Text("Total").font(.caption.weight(.semibold))
                }
                row(String(localized: "Invoice"), p.net, p.vat, p.total, bold: false)
                if p.over > 0.004 || p.overVat > 0.004 {
                    row(String(localized: "Overcharged"), -p.over, -p.overVat, -p.overWithVat, bold: false, red: true)
                }
                if p.missing > 0.004 || p.missingVat > 0.004 {
                    row(String(localized: "Missing / returned"), -p.missing, -p.missingVat, -Money.round2(p.missing + p.missingVat), bold: false, red: true)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                row(String(localized: "To pay"), p.payNet, p.payVat, p.pay, bold: true)
            }
            .font(.subheadline.monospacedDigit())
            .padding(.vertical, 4)
            if p.vatFromShare {
                Text("This invoice's lines were read without VAT rates, so the VAT taken off is the invoice's own VAT share (\(VatShare.text(p))).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } label: {
            HStack {
                Text("How it's worked out")
                Spacer()
                if p.vat > 0.004 {
                    Text(String(localized: "\(money(p.payNet)) + VAT \(money(p.payVat))"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func money(_ value: Double) -> String { Money.format(value, supplier: entry.supplier) }

    @ViewBuilder
    private func row(_ name: String, _ net: Double, _ vat: Double, _ total: Double, bold: Bool, red: Bool = false) -> some View {
        GridRow {
            Text(name).gridColumnAlignment(.leading).lineLimit(2).minimumScaleFactor(0.8)
            Text(money(net))
            Text(money(vat))
            Text(money(total)).fontWeight(bold ? .bold : .regular)
        }
        .foregroundStyle(red ? Color.red : Color.primary)
        .fontWeight(bold ? .semibold : .regular)
    }
}

enum VatShare {
    /// "20%": the invoice's VAT as a share of its net.
    static func text(_ p: PayBreakdown) -> String {
        guard p.net > 0.004 else { return "0%" }
        return (p.vat / p.net * 100).formatted(.number.precision(.fractionLength(0...1))) + "%"
    }
}
