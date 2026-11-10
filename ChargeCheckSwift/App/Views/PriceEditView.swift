import SwiftUI
import SwiftData
import ChargeCheckCore

struct PriceEditView: View {
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    let categories: [String]
    let onSave: (PriceItem) -> Void
    let onDelete: (() -> Void)?

    @State private var item: PriceItem
    @State private var priceText: String
    @State private var aliasText: String
    @State private var newCategory = ""
    @Query private var reports: [StoredReport]

    private var history: [PricePoint] {
        isNew ? [] : PriceTools.history(of: item.id, in: reports.compactMap { $0.entry })
    }

    init(draft: PriceDraft, categories: [String], onSave: @escaping (PriceItem) -> Void, onDelete: (() -> Void)?) {
        self.isNew = draft.isNew
        var options = categories
        if !options.contains(draft.item.cat) { options.append(draft.item.cat) }
        self.categories = options
        self.onSave = onSave
        self.onDelete = onDelete
        _item = State(initialValue: draft.item)
        _priceText = State(initialValue: draft.item.price > 0 ? String(format: "%.2f", draft.item.price) : "")
        _aliasText = State(initialValue: draft.item.aliases.joined(separator: ", "))
    }

    private var price: Double? {
        guard let value = Money.parse(priceText), value > 0, value < (Money.currency.decimals == 0 ? 1_000_000_000 : 100_000) else { return nil }
        return Money.round2(value)
    }

    private var canSave: Bool {
        !item.name.trimmingCharacters(in: .whitespaces).isEmpty && price != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    TextField("Name, e.g. Chicken Wings 10kg", text: $item.name)
                    HStack {
                        Text(Money.currency.symbol)
                            .foregroundStyle(.secondary)
                        TextField("Your agreed price", text: $priceText)
                            .keyboardType(.decimalPad)
                    }
                    TextField("Usual supplier (optional)", text: $item.supplier)
                }
                Section("Category") {
                    Picker("Category", selection: $item.cat) {
                        ForEach(categories, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    TextField("Or type a new category", text: $newCategory)
                }
                Section {
                    TextField("e.g. quater pounder, qtr pounder", text: $aliasText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("On invoices as")
                } footer: {
                    Text("How suppliers write this item on their invoices, separated by commas. The app uses these to recognise it.")
                }
                if !history.isEmpty {
                    Section("Price history") {
                        PriceHistoryChart(points: history, agreed: price ?? item.price)
                    }
                }
                if let onDelete {
                    Section {
                        Button("Delete this item", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add a price" : "Edit price")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        guard let price else { return }
        var result = item
        result.name = item.name.trimmingCharacters(in: .whitespaces)
        result.price = price
        result.supplier = item.supplier.trimmingCharacters(in: .whitespaces)
        let typed = newCategory.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { result.cat = typed }
        var seen = Set<String>()
        var aliases = aliasText
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { TextTools.norm(String($0)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        if aliases.isEmpty { aliases = [TextTools.norm(result.name)] }
        result.aliases = aliases
        onSave(result)
        dismiss()
    }
}
