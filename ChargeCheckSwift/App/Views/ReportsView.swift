import SwiftUI
import SwiftData
import ChargeCheckCore

struct SupplierDue: Identifiable {
    let name: String
    let count: Int
    let pay: Double
    var id: String { name }
}

/// Checked invoices brought over from the previous version. New scans, the export
/// for the accountant and choosing which invoices to pay arrive in later stages.
struct ReportsView: View {
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]

    private var entries: [HistoryEntry] { reports.compactMap { $0.entry } }

    private func due(_ list: [HistoryEntry]) -> [SupplierDue] {
        let unpaid = list.filter { $0.paid == nil }
        return Dictionary(grouping: unpaid, by: { $0.supplier.isEmpty ? "Unknown supplier" : $0.supplier })
            .map { SupplierDue(name: $0.key, count: $0.value.count, pay: Money.round2($0.value.reduce(0) { $0 + $1.amountToPay.pay })) }
            .sorted { $0.pay > $1.pay }
    }

    var body: some View {
        NavigationStack {
            let list = entries
            let owed = due(list)
            List {
                if list.isEmpty {
                    ContentUnavailableView {
                        Label("No reports yet", systemImage: "chart.bar")
                    } description: {
                        Text("Every invoice you check is kept here, with what each supplier overcharged.")
                    }
                } else {
                    Section {
                        LabeledContent("Overcharged, all time") {
                            Text(Money.format(Money.round2(list.reduce(0) { $0 + $1.over })))
                                .foregroundStyle(.red)
                                .fontWeight(.bold)
                        }
                        LabeledContent("Invoices checked", value: "\(list.count)")
                        LabeledContent("Spend checked", value: Money.format(Money.round2(list.reduce(0) { $0 + $1.net })))
                    }
                    if !owed.isEmpty {
                        Section {
                            ForEach(owed) { supplier in
                                LabeledContent {
                                    Text(Money.format(supplier.pay))
                                        .fontWeight(.semibold)
                                } label: {
                                    Text(supplier.name)
                                    Text(supplier.count == 1 ? "1 invoice" : "\(supplier.count) invoices")
                                }
                            }
                            LabeledContent("Amount to pay") {
                                Text(Money.format(Money.round2(owed.reduce(0) { $0 + $1.pay })))
                                    .font(.title3.weight(.bold))
                            }
                        } header: {
                            Text("To pay")
                        } footer: {
                            Text("Invoice totals with VAT, less overcharges and missing items.")
                        }
                    }
                    Section("Checked invoices") {
                        ForEach(list) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.supplier.isEmpty ? "Invoice" : entry.supplier)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer(minLength: 12)
                                    Text(entry.over > 0.005 ? Money.format(entry.over) : "OK")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(entry.over > 0.005 ? Color.red : Color.green)
                                }
                                Text(detail(entry))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Reports")
        }
    }

    private func detail(_ entry: HistoryEntry) -> String {
        var parts: [String] = []
        if !entry.invNo.isEmpty { parts.append("#" + entry.invNo) }
        if !entry.date.isEmpty { parts.append(entry.date) }
        parts.append("total " + Money.format(entry.total))
        if entry.paid != nil { parts.append("paid") }
        return parts.joined(separator: " · ")
    }
}
