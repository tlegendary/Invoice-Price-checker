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
    @State private var aliasList: [String]
    @State private var newAlias = ""
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
        _aliasList = State(initialValue: draft.item.aliases)
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
                            Text(L(name)).tag(name)
                        }
                    }
                    TextField("Or type a new category", text: $newCategory)
                }
                Section {
                    ForEach(item.sp.indices, id: \.self) { index in
                        HStack {
                            // guarded, so removing a row can't read past the end of the list
                            TextField("Supplier", text: Binding(
                                get: { index < item.sp.count ? item.sp[index].s : "" },
                                set: { if index < item.sp.count { item.sp[index].s = $0 } }))
                                .textInputAutocapitalization(.words)
                            Text(Money.currency.symbol)
                                .foregroundStyle(.secondary)
                            TextField("Price", value: Binding(
                                get: { index < item.sp.count ? item.sp[index].p : 0 },
                                set: { if index < item.sp.count { item.sp[index].p = $0 } }),
                                      format: .number.precision(.fractionLength(Money.currency.decimals)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 90)
                        }
                    }
                    .onDelete { item.sp.remove(atOffsets: $0) }
                    Button {
                        item.sp.append(SupplierPrice(s: "", p: price ?? item.price))
                    } label: {
                        Label("Add a supplier's own price", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Special prices")
                } footer: {
                    Text("A different price agreed with one supplier. Invoices from that supplier are checked against it. Swipe left to remove one.")
                }
                Section {
                    ForEach(aliasList.indices, id: \.self) { index in
                        Text(aliasList[index])
                    }
                    .onDelete { aliasList.remove(atOffsets: $0) }
                    HStack {
                        TextField("Another name, e.g. hp10 box", text: $newAlias)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addAlias)
                        Button("Add", action: addAlias)
                            .buttonStyle(.borderless)
                            .disabled(TextTools.norm(newAlias).isEmpty)
                    }
                } header: {
                    Text("Other names on invoices")
                } footer: {
                    Text("Every way suppliers write this item, one per line. The app recognises the item by any of them. When you pick the right item for a line it didn't recognise, that name is added here for you. Swipe left to remove one.")
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
        var aliases = (aliasList + [newAlias])
            .flatMap { $0.split(whereSeparator: { $0 == "," || $0 == "\n" }) }
            .map { TextTools.norm(String($0)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        if aliases.isEmpty { aliases = [TextTools.norm(result.name)] }
        result.aliases = aliases
        result.sp = item.sp
            .map { SupplierPrice(s: $0.s.trimmingCharacters(in: .whitespaces), p: Money.round2($0.p)) }
            .filter { !$0.s.isEmpty && $0.p > 0 }
        onSave(result)
        dismiss()
    }

    /// Adds the typed name (commas split several at once).
    private func addAlias() {
        for part in newAlias.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let name = TextTools.norm(String(part))
            if !name.isEmpty, !aliasList.contains(name) { aliasList.append(name) }
        }
        newAlias = ""
    }
}