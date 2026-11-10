import SwiftUI
import UIKit
import ChargeCheckCore

/// Paste a price list from WhatsApp, an email or a spreadsheet: one item per line, price at the end.
struct PasteListView: View {
    @Environment(\.dismiss) private var dismiss

    let existing: [PriceItem]
    let onAdd: ([PriceItem]) -> Void

    @State private var text = ""
    @State private var supplier = ""

    private var rows: [PriceListText.Row] { PriceListText.parse(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                    Button("Paste from clipboard") {
                        if let copied = UIPasteboard.general.string { text = copied }
                    }
                } header: {
                    Text("Your list")
                } footer: {
                    Text("One item per line with its price at the end, for example: Chicken wings 10kg £15.00")
                }
                Section("Supplier (optional)") {
                    TextField("Who are these prices from?", text: $supplier)
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section(rows.isEmpty ? "Nothing found" : "Found \(rows.count) items") {
                        if rows.isEmpty {
                            Text("No lines with an item name and a price. Put one item per line with the price at the end.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack {
                                Text(row.name)
                                Spacer(minLength: 12)
                                Text(Money.format(row.price))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle("Paste a price list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(rows.isEmpty ? "Add" : "Add \(rows.count)") { add() }
                        .disabled(rows.isEmpty)
                }
            }
        }
    }

    private func add() {
        let from = supplier.trimmingCharacters(in: .whitespaces)
        var all = existing
        var changed: [PriceItem] = []
        for row in rows {
            let key = TextTools.norm(row.name)
            if let index = all.firstIndex(where: { TextTools.norm($0.name) == key }) {
                // already in the list: update its price
                all[index].price = row.price
                if all[index].supplier.isEmpty { all[index].supplier = from }
                changed.append(all[index])
            } else {
                var item = PriceItem(cat: "Other", name: row.name, price: row.price, supplier: from, aliases: [key])
                item.cat = Categoriser.suggest(for: item, in: all) ?? "Other"
                all.append(item)
                changed.append(item)
            }
        }
        onAdd(changed)
        dismiss()
    }
}
