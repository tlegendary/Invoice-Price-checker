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

    private var shown: [StoredPrice] {
        let query = TextTools.norm(search)
        if query.isEmpty { return prices }
        return prices.filter {
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
            if let stored = prices.first(where: { $0.uid == id }) { context.delete(stored) }
        }
    }

    var body: some View {
        NavigationStack {
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
                                    context.delete(price)
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
            .task {
                // the cloud check opens one item to look at its price history
                if let id = UserDefaults.standard.string(forKey: "demoPrice"), let stored = prices.first(where: { $0.uid == id }) {
                    draft = PriceDraft(item: stored.item, isNew: false)
                }
            }
            .searchable(text: $search, prompt: "Search \(prices.count) items")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
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
                        draft = PriceDraft(item: PriceItem(name: "", price: 0), isNew: true)
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
                    for item in items { AppData.save(item, in: context) }
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
                    for price in prices { context.delete(price) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your reports are kept. This can't be undone, so save a backup first in Settings.")
            }
        }
    }
}

struct PriceRow: View {
    let price: StoredPrice

    private var subtitle: String {
        var parts: [String] = []
        if !price.supplier.isEmpty { parts.append(price.supplier) }
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
            Text(Money.format(price.price))
                .font(.body.weight(.bold))
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }
}
