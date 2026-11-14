import SwiftUI
import ChargeCheckCore

/// Check or correct one line of an invoice, and choose which price-list item it is.
struct LineEditView: View {
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    let supplier: String
    let items: [PriceItem]
    /// The invoice's shop: its own prices are shown.
    var shop: String = ""
    let isSample: Bool
    let onSave: (CheckLine) -> Void
    let onDelete: (() -> Void)?

    @State private var line: CheckLine
    @State private var qtyText: String
    @State private var unitText: String
    @State private var search = ""
    @State private var showAll = false

    init(draft: LineDraft, supplier: String, items: [PriceItem], isSample: Bool, onSave: @escaping (CheckLine) -> Void, onDelete: (() -> Void)?) {
        self.isNew = draft.isNew
        self.supplier = supplier
        self.items = items
        self.isSample = isSample
        self.onSave = onSave
        self.onDelete = onDelete
        let line = draft.line
        _line = State(initialValue: line)
        _qtyText = State(initialValue: line.qty == line.qty.rounded() ? String(Int(line.qty)) : String(format: "%.2f", line.qty))
        _unitText = State(initialValue: line.unit > 0 ? String(format: "%.2f", line.unit) : "")
    }

    private var matched: PriceItem? {
        guard let id = line.matchId else { return nil }
        return items.first { $0.id == id }
    }

    private var choices: [PriceItem] {
        let query = TextTools.norm(search)
        if !query.isEmpty {
            return items.filter { TextTools.norm($0.name + " " + $0.aliases.joined(separator: " ")).contains(query) }
        }
        if showAll { return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
        return Matcher.suggestions(line.desc, in: items, limit: 4)
    }

    private var canSave: Bool {
        !line.desc.trimmingCharacters(in: .whitespaces).isEmpty && (Money.parse(qtyText) ?? 0) > 0 && Money.parse(unitText) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if !line.warn.isEmpty || line.disagree || line.onlySecondRead {
                    Section {
                        if !line.warn.isEmpty { Text(line.warn) }
                        if line.disagree, let q = line.altQty, let u = line.altUnit {
                            Text("The second read gave \(q == q.rounded() ? String(Int(q)) : String(format: "%.2f", q)) × \(Money.format(u)).")
                        }
                        if line.onlySecondRead { Text("Only found on the second read – make sure it's really on the invoice.") }
                    }
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
                Section("On the invoice") {
                    TextField("Item name", text: $line.desc, axis: .vertical)
                        .autocorrectionDisabled()
                    LabeledContent("Quantity") {
                        TextField("1", text: $qtyText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Unit price \(Money.currency.symbol)") {
                        TextField("0.00", text: $unitText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("VAT", selection: $line.vat) {
                        Text("0%").tag(0.0)
                        Text("5%").tag(5.0)
                        Text("20%").tag(20.0)
                    }
                }
                Section {
                    if let matched {
                        LabeledContent {
                            Text(Money.format(matched.basePrice(for: supplier, shop: shop)))
                        } label: {
                            Label(matched.name, systemImage: "checkmark.circle.fill")
                        }
                        Button("This is a different item") {
                            line.matchId = nil
                            line.confident = nil
                        }
                    } else {
                        TextField("Search your price list", text: $search)
                            .autocorrectionDisabled()
                        ForEach(choices) { item in
                            Button {
                                line.matchId = item.id
                                line.confident = true
                                line.noBase = false
                                search = ""
                            } label: {
                                HStack {
                                    Text(item.name)
                                    Spacer(minLength: 8)
                                    Text(Money.format(item.basePrice(for: supplier, shop: shop)))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if search.isEmpty && !showAll && !items.isEmpty {
                            Button("Show my whole price list") { showAll = true }
                        }
                        Toggle("Not in my price list", isOn: $line.noBase)
                    }
                } header: {
                    Text("In your price list")
                } footer: {
                    if matched == nil {
                        Text(isSample ? "Pick the matching item." : "Pick the matching item. The app remembers how this supplier writes it.")
                    }
                }
                Section {
                    Toggle("Missing or returned", isOn: $line.excluded)
                    Toggle("I've checked this line", isOn: $line.ok)
                } footer: {
                    Text("Missing or returned items are taken off what you pay.")
                }
                if let onDelete {
                    Section {
                        Button("Delete this line", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add a line" : "Check this line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        var result = line
        result.desc = line.desc.trimmingCharacters(in: .whitespaces)
        result.qty = Money.parse(qtyText) ?? 1
        result.unit = Money.round2(Money.parse(unitText) ?? 0)
        if result.confident == false && result.matchId != nil { result.confident = true }
        // the user has looked at it: the reader's doubts no longer apply
        if result.qty != line.qty || result.unit != line.unit || isNew {
            result.warn = ""
            result.disagree = false
        }
        if isNew && result.matchId == nil && !result.noBase {
            let match = Matcher.match(result.desc, in: items)
            result.matchId = match.itemID
            result.confident = match.itemID == nil ? nil : match.confident
        }
        onSave(result)
        dismiss()
    }
}
