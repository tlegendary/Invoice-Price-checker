import SwiftUI
import SwiftData
import ChargeCheckCore

struct PriceDraft: Identifiable {
    let id = UUID()
    var item: PriceItem
    var isNew: Bool
}

struct PriceGroup: Identifiable {
    let cat: String
    let items: [StoredPrice]
    var id: String { cat }
}

struct PricesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredPrice.name) private var prices: [StoredPrice]
    @State private var search = ""
    @State private var draft: PriceDraft?
    @State private var showPaste = false
    @State private var showSort = false
    @State private var showNames = false
    @State private var showDishes = false
    @State private var confirmDeleteAll = false
    /// Select mode: tick items (or all of them) to delete them or change their shops.
    @State private var editMode: EditMode = .inactive
    @State private var selected: Set<String> = []
    @State private var confirmDeleteSelected = false
    @AppStorage(Shops.listKey) private var shopData = Data()

    private var selecting: Bool { editMode.isEditing }

    /// Changes the shops of the ticked items (moving to one shop drops other shops' own prices).
    private func changeShops(_ change: (inout PriceItem) -> Void) {
        let chosen = prices.filter { selected.contains($0.uid) }
        for stored in chosen {
            var item = stored.item
            change(&item)
            stored.update(from: item)
        }
        try? context.save()
        Records.shared.log(.priceChanged, chosen.count == 1 ? String(localized: "Shops changed for 1 item")
                                                            : String(localized: "Shops changed for \(chosen.count) items"))
        selected = []
        editMode = .inactive
    }

    /// The items of the shop being viewed (every item under "All shops").
    private var inShop: [StoredPrice] {
        let shop = LiveSettings.shared.shop
        if shop.isEmpty { return Array(prices) }
        return prices.filter { $0.item.isIn(shop: shop) }
    }

    private var shown: [StoredPrice] {
        let query = TextTools.norm(search)
        if query.isEmpty { return inShop }
        return inShop.filter {
            TextTools.norm($0.name + " " + $0.supplier + " " + $0.aliasText + " " + $0.cat).contains(query)
        }
    }

    private var groups: [PriceGroup] {
        Dictionary(grouping: shown, by: { $0.cat })
            .map { PriceGroup(cat: $0.key, items: $0.value) }
            .sorted { $0.cat.localizedCaseInsensitiveCompare($1.cat) == .orderedAscending }
    }

    private var categories: [String] {
        var seen = Set<String>()
        return (prices.map { $0.cat } + Categoriser.standardNames).filter { seen.insert($0).inserted }.sorted()
    }

    private func deleteAction(for current: PriceDraft) -> (() -> Void)? {
        if current.isNew { return nil }
        let id = current.item.id
        return {
            if let stored = prices.first(where: { $0.uid == id }) { AppData.deletePrices([stored], context: context) }
        }
    }

    /// Opened from the More tab, inside its navigation, rather than as a tab of its own.
    var embedded = false

    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }

    private var content: some View {
            List(selection: $selected) {
                if prices.isEmpty {
                    ContentUnavailableView {
                        Label("No prices yet", systemImage: "tag")
                    } description: {
                        Text("Add the prices you agreed with your suppliers. Tap + to add one, or use the ••• menu to paste a whole list.")
                    }
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                ForEach(groups) { group in
                    Section(L(group.cat)) {
                        ForEach(group.items) { price in
                            if selecting {
                                PriceRow(price: price)
                                    .tag(price.uid)
                            } else {
                            Button {
                                draft = PriceDraft(item: price.item, isNew: false)
                            } label: {
                                PriceRow(price: price)
                            }
                            .buttonStyle(.plain)
                            .tag(price.uid)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    AppData.deletePrices([price], context: context)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    draft = PriceDraft(item: price.item, isNew: false)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            }
                        }
                    }
                }
            }
            .navigationTitle(selecting ? (selected.count == 1 ? String(localized: "1 selected") : String(localized: "\(selected.count) selected")) : String(localized: "Prices"))
            .environment(\.editMode, $editMode)
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    SelectionBar(count: selected.count, shops: Shops.decode(shopData), deleteTitle: String(localized: "Delete"),
                                 onMove: { shop in
                                     changeShops { item in
                                         item.shops = shop.isEmpty ? nil : [shop]
                                         if !shop.isEmpty {
                                             let kept = item.shopPrices?.filter { $0.shop == shop }
                                             item.shopPrices = (kept?.isEmpty ?? true) ? nil : kept
                                         }
                                     }
                                 },
                                 onDelete: { confirmDeleteSelected = true },
                                 onAdd: { shop in
                                     let all = Shops.all.map { $0.id }
                                     changeShops { item in
                                         guard var tags = item.shops else { return }   // already in every shop
                                         if !tags.contains(shop) { tags.append(shop) }
                                         item.shops = all.allSatisfy({ tags.contains($0) }) ? nil : tags
                                     }
                                 },
                                 allShopsTitle: String(localized: "Use in all shops"))
                }
            }
            .confirmationDialog(selected.count == 1 ? String(localized: "Delete 1 item?") : String(localized: "Delete \(selected.count) items?"),
                                isPresented: $confirmDeleteSelected, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    AppData.deletePrices(prices.filter { selected.contains($0.uid) }, context: context)
                    try? context.save()
                    selected = []
                    editMode = .inactive
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your reports are kept. Deleted prices can be brought back from More › Recently deleted for 30 days.")
            }
            .task {
                // the cloud check opens one item to look at its price history
                if let id = UserDefaults.standard.string(forKey: "demoPrice"), let stored = prices.first(where: { $0.uid == id }) {
                    draft = PriceDraft(item: stored.item, isNew: false)
                }
            }
            .searchable(text: $search, prompt: "Search \(prices.count) items")
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(selected.count == shown.count && !shown.isEmpty ? String(localized: "Deselect all") : String(localized: "Select all")) {
                            selected = selected.count == shown.count ? [] : Set(shown.map { $0.uid })
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            editMode = .inactive
                            selected = []
                        }
                        .fontWeight(.semibold)
                    }
                } else {
                ToolbarItem(placement: .topBarLeading) { ShopSwitcher() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            editMode = .active
                        } label: {
                            Label("Select items", systemImage: "checkmark.circle")
                        }
                        .disabled(prices.isEmpty)
                        Button {
                            showPaste = true
                        } label: {
                            Label("Paste a price list", systemImage: "doc.on.clipboard")
                        }
                        Button {
                            showSort = true
                        } label: {
                            Label("Sort into categories", systemImage: "folder")
                        }
                        .disabled(prices.isEmpty)
                        Button {
                            showNames = true
                        } label: {
                            Label("Suggest other names", systemImage: "sparkles")
                        }
                        .disabled(prices.isEmpty)
                        Button {
                            showDishes = true
                        } label: {
                            Label("Cost per dish", systemImage: "fork.knife")
                        }
                        Divider()
                        Button(role: .destructive) {
                            confirmDeleteAll = true
                        } label: {
                            Label("Delete all prices", systemImage: "trash")
                        }
                        .disabled(prices.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // a new item belongs to the shop being viewed (all shops under "All shops")
                        let shop = LiveSettings.shared.shop
                        draft = PriceDraft(item: PriceItem(name: "", price: 0, shops: shop.isEmpty ? nil : [shop]), isNew: true)
                    } label: {
                        Label("Add a price", systemImage: "plus")
                    }
                }
                }
            }
            .sheet(item: $draft) { current in
                PriceEditView(
                    draft: current,
                    categories: categories,
                    onSave: { AppData.save($0, in: context) },
                    onDelete: deleteAction(for: current)
                )
            }
            .sheet(isPresented: $showPaste) {
                PasteListView(existing: prices.map { $0.item }) { items in
                    // new items belong to the shop being viewed; items already in the list keep their shops
                    let shop = LiveSettings.shared.shop
                    let known = Set(prices.map { $0.uid })
                    for var item in items {
                        if !shop.isEmpty, !known.contains(item.id), item.shops == nil { item.shops = [shop] }
                        AppData.save(item, in: context)
                    }
                }
            }
            .sheet(isPresented: $showDishes) {
                NavigationStack {
                    DishesView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showDishes = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showNames) {
                NameSuggestionsView(items: prices.map { $0.item }) { changed in
                    for item in changed { AppData.save(item, in: context) }
                    try? context.save()
                }
            }
            .sheet(isPresented: $showSort) {
                SortCategoriesView(items: prices.map { $0.item }) { moves in
                    for price in prices {
                        if let category = moves[price.uid] { price.cat = category }
                    }
                }
            }
            .confirmationDialog("Delete all \(prices.count) prices?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete all prices", role: .destructive) {
                    AppData.deletePrices(Array(prices), context: context)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your reports are kept. Deleted prices can be brought back from More › Recently deleted for 30 days.")
            }
    }
}

struct PriceRow: View {
    let price: StoredPrice

    private var subtitle: String {
        var parts: [String] = []
        if !price.supplier.isEmpty { parts.append(price.supplier) }
        // with several shops: which shops buy it, when not all of them
        if let tags = price.item.shops, Shops.all.count > 1 {
            let names = tags.compactMap { Shops.name($0) }
            if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        }
        let spellings = price.aliases.filter { $0 != TextTools.norm(price.name) }
        if !spellings.isEmpty { parts.append(String(localized: "on invoices as: \(spellings.joined(separator: ", "))")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(price.name)
                    .font(.body.weight(.semibold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            // the shop being viewed: its own price if it has one
            Text(Money.format(price.item.price(inShop: LiveSettings.shared.shop)))
                .font(.body.weight(.bold))
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }
}
