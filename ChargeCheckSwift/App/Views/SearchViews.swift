import SwiftUI
import SwiftData
import ChargeCheckCore

/// What the Home search box found: suppliers, invoices, items and payments.
/// Suppliers open with a `String` key and invoices with a `ReportLink`, so the stack it sits in needs both destinations.
struct SearchResultsSections: View {
    let results: SearchResults

    @Environment(\.modelContext) private var context
    @Query(sort: \StoredPrice.name) private var prices: [StoredPrice]
    @State private var draft: PriceDraft?

    var body: some View {
        if results.isEmpty {
            ContentUnavailableView.search
        }
        if !results.suppliers.isEmpty {
            Section("Suppliers") {
                ForEach(results.suppliers, id: \.self) { name in
                    NavigationLink(value: SupplierAccounts.key(name)) {
                        Label(name, systemImage: "shippingbox")
                    }
                }
            }
        }
        if !results.invoices.isEmpty {
            Section("Invoices") {
                ForEach(results.invoices) { entry in
                    NavigationLink(value: ReportLink(id: entry.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            ReportRow(entry: entry)
                            if let line = results.matchedLine[entry.id] {
                                Label(line, systemImage: "text.magnifyingglass")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        }
        if !results.items.isEmpty {
            Section("Items") {
                ForEach(results.items) { item in
                    Button {
                        draft = PriceDraft(item: item, isNew: false)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.subheadline.weight(.semibold))
                                Text(L(item.cat))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Money.format(item.price))
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .sheet(item: $draft) { current in
                PriceEditView(
                    draft: current,
                    categories: Array(Set(prices.map { $0.cat } + Categoriser.standardNames)).sorted(),
                    onSave: { AppData.save($0, in: context) },
                    onDelete: nil
                )
            }
        }
        if !results.payments.isEmpty {
            Section("Payments and credits") {
                ForEach(results.payments) { payment in
                    NavigationLink(value: SupplierAccounts.key(payment.supplier)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(payment.supplier)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            PaymentRow(payment: payment)
                        }
                    }
                }
            }
        }
    }
}
