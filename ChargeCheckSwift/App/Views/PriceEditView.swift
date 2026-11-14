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
    @Query private var storedPrices: [StoredPrice]
    /// "Suggest other names": likely supplier spellings to add with a tap (nil until asked).
    @State private var ideas: [String]?
    @AppStorage(Shops.listKey) private var shopData = Data()
    /// The shops that buy this item (empty = every shop).
    @State private var shopTags: Set<String>
    /// Each shop's own price as typed ("" = the agreed price above).
    @State private var shopPriceText: [String: String]

    private var allShops: [ShopInfo] { Shops.decode(shopData) }

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
        _shopTags = State(initialValue: Set(draft.item.shops ?? []))
        var texts: [String: String] = [:]
        for own in draft.item.shopPrices ?? [] { texts[own.shop] = String(format: "%.\(Money.currency.decimals)f", own.p) }
        _shopPriceText = State(initialValue: texts)
    }

    private func inShop(_ id: String) -> Bool { shopTags.isEmpty || shopTags.contains(id) }

    /// Ticking or unticking a shop. Every shop ticked is the same as "all shops"; at least one stays ticked.
    private func setShop(_ id: String, _ on: Bool) {
        var tags = shopTags.isEmpty ? Set(allShops.map { $0.id }) : shopTags
        if on { tags.insert(id) } else { tags.remove(id) }
        guard !tags.isEmpty else { return }
        shopTags = tags.count >= allShops.count ? [] : tags
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
                if allShops.count > 1 {
                    Section {
                        Toggle("All shops", isOn: Binding(get: { shopTags.isEmpty }, set: { if $0 { shopTags = [] } }))
                        ForEach(allShops, id: \.id) { shop in
                            Toggle(shop.name, isOn: Binding(get: { inShop(shop.id) }, set: { setShop(shop.id, $0) }))
                            if inShop(shop.id) {
                                HStack {
                                    Text("Price in \(shop.name)")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(Money.currency.symbol)
                                        .foregroundStyle(.secondary)
                                    TextField(price.map { Money.format($0) } ?? String(localized: "Same price"),
                                              text: Binding(get: { shopPriceText[shop.id] ?? "" }, set: { shopPriceText[shop.id] = $0 }))
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .frame(maxWidth: 110)
                                }
                                .font(.subheadline)
                            }
                        }
                    } header: {
                        Text("Shops")
                    } footer: {
                        Text("Which of your shops buy this item, and a shop's own price if it pays a different one (leave it empty for the agreed price above). Each shop's invoices are checked against its own price, and the items on an invoice tell the app which shop it's for.")
                    }
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
                    if let ideas {
                        if ideas.isEmpty {
                            Text("No more safe suggestions: other likely names could also be read as another item in your list.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(ideas, id: \.self) { idea in
                                Button {
                                    addIdeas([idea])
                                } label: {
                                    Label(idea, systemImage: "plus.circle.fill")
                                }
                                .accessibilityHint(Text("Adds this name"))
                            }
                            if ideas.count > 1 {
                                Button("Add all \(ideas.count)") { addIdeas(ideas) }
                                    .fontWeight(.semibold)
                            }
                        }
                    } else {
                        Button {
                            suggestNames()
                        } label: {
                            Label("Suggest other names", systemImage: "sparkles")
                        }
                        .disabled(TextTools.norm(item.name).isEmpty)
                    }
                } header: {
                    Text("Other names on invoices")
                } footer: {
                    Text("Every way suppliers write this item, one per line. The app recognises the item by any of them. When you pick the right item for a line it didn't recognise, that name is added here for you. Swipe left to remove one.")
                }
                .onChange(of: item.name) { _, _ in ideas = nil }
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
        // shops: only ones that still exist; every shop = all shops (nil), so new shops get the item too
        let known = allShops.map { $0.id }
        let tags = known.filter { shopTags.contains($0) }
        result.shops = (tags.isEmpty || tags.count == known.count) ? nil : tags
        let own = known.compactMap { id -> ShopPrice? in
            guard inShop(id), let typed = shopPriceText[id], let value = Money.parse(typed), value > 0 else { return nil }
            let rounded = Money.round2(value)
            return abs(rounded - price) < 0.005 ? nil : ShopPrice(shop: id, p: rounded)
        }
        result.shopPrices = known.isEmpty ? item.shopPrices : (own.isEmpty ? nil : own)
        onSave(result)
        dismiss()
    }

    /// Adds the typed name (commas split several at once).
    /// Likely ways a supplier writes this item, never one that could also be another item in the list.
    private func suggestNames() {
        var current = item
        current.aliases = aliasList
        let others = storedPrices.map { $0.item }.filter { $0.id != item.id }
        ideas = NameIdeas.suggest(for: current, among: others + [current])
    }

    private func addIdeas(_ names: [String]) {
        for name in names where !aliasList.contains(name) { aliasList.append(name) }
        ideas?.removeAll { names.contains($0) }
    }

    private func addAlias() {
        for part in newAlias.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let name = TextTools.norm(String(part))
            if !name.isEmpty, !aliasList.contains(name) { aliasList.append(name) }
        }
        newAlias = ""
    }
}