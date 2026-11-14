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
    @State private var confirmDeleteAll = false

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
            List {
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
                            Button {
                                draft = PriceDraft(item: price.item, isNew: false)
                            } label: {
                                PriceRow(price: price)
                            }
                            .buttonStyle(.plain)
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
            .navigationTitle("Prices")
            .shopSwitcher()
            .task {
                // the cloud check opens one item to look at its price history
                if let id = UserDefaults.standard.string(forKey: "demoPrice"), let stored = prices.first(where: { $0.uid == id }) {
                    draft = PriceDraft(item: stored.item, isNew: false)
                }
            }
            .searchable(text: $search, prompt: "Search \(prices.count) items")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
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
