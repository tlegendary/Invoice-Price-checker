import SwiftUI
import SwiftData
import ChargeCheckCore

/// Prices › More › "Cost per dish": what each thing you sell costs to make at today's agreed prices,
/// what you keep after VAT, and which dishes got dearer since you last looked.
struct DishesView: View {
    @Query(sort: \StoredPrice.name) private var prices: [StoredPrice]
    @ObservedObject private var store = DishStore.shared
    @State private var editing: Dish?
    @State private var confirmDelete: Dish?

    private var items: [PriceItem] { prices.map { $0.item } }

    var body: some View {
        let all = items
        List {
            if store.dishes.isEmpty {
                ContentUnavailableView {
                    Label("No dishes yet", systemImage: "fork.knife")
                } description: {
                    Text("Add what you sell, made from items in your price list. You'll see what each one costs to make, what you keep, and when a price rise eats into it.")
                } actions: {
                    Button("Add a dish") { editing = newDish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(all.isEmpty)
                }
            } else {
                Section {
                    ForEach(store.dishes) { dish in
                        let cost = DishMaths.cost(of: dish, items: all)
                        Button {
                            editing = dish
                        } label: {
                            DishRow(dish: dish, cost: cost)
                        }
                        .foregroundStyle(.primary)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                confirmDelete = dish
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text("Costs use your agreed prices (each shop's own price where it has one). Food cost is the ingredients as a share of the price without VAT.")
                }
            }
        }
        .navigationTitle("Cost per dish")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = newDish()
                } label: {
                    Label("Add a dish", systemImage: "plus")
                }
                .disabled(all.isEmpty)
            }
        }
        .sheet(item: $editing) { dish in
            DishEditView(dish: dish, items: all) { store.save($0) }
        }
        .confirmationDialog("Delete this dish?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmDelete) { dish in
            Button("Delete", role: .destructive) { store.delete([dish.id]) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func newDish() -> Dish {
        Dish(name: "", price: 0, vatRate: 20, shop: LiveSettings.shared.shop)
    }
}

struct DishRow: View {
    let dish: Dish
    let cost: DishCost

    private var percentColour: Color {
        guard let percent = cost.foodCostPercent else { return .secondary }
        return percent > 40 ? .red : (percent > 30 ? .orange : .green)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(dish.name.isEmpty ? String(localized: "Dish") : dish.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let percent = cost.foodCostPercent {
                    Text("\(percent, specifier: "%.0f")% food cost")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(percentColour)
                }
            }
            Text(String(localized: "Costs \(Money.format(cost.cost)) · sells \(Money.format(dish.price)) · you keep \(Money.format(cost.margin))"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if cost.changeSinceSet > 0.005 {
                Label(String(localized: "Costs \(Money.format(cost.changeSinceSet)) more than when you set it"), systemImage: "arrow.up.right")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if cost.missing > 0 {
                Label(cost.missing == 1 ? String(localized: "1 ingredient is no longer in your price list")
                                        : String(localized: "\(cost.missing) ingredients are no longer in your price list"),
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A dish: its selling price and what goes into it.
struct DishEditView: View {
    let items: [PriceItem]
    let onSave: (Dish) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dish: Dish
    @State private var priceText: String
    @State private var picking = false

    init(dish: Dish, items: [PriceItem], onSave: @escaping (Dish) -> Void) {
        self.items = items
        self.onSave = onSave
        _dish = State(initialValue: dish)
        _priceText = State(initialValue: dish.price > 0 ? String(format: "%.2f", dish.price) : "")
    }

    private var cost: DishCost { DishMaths.cost(of: dish, items: items) }
    private var book: PriceBook { PriceBook(items, shop: dish.shop) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Quarter pounder meal", text: $dish.name)
                    LabeledContent("Selling price") {
                        TextField(Money.format(0), text: $priceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: priceText) { dish.price = max(0, Money.parse(priceText) ?? 0) }
                    }
                    Picker("VAT in the price", selection: $dish.vatRate) {
                        Text("20%").tag(20.0)
                        Text("5%").tag(5.0)
                        Text("None").tag(0.0)
                    }
                }
                Section {
                    ForEach($dish.parts) { $part in
                        PartRow(part: $part, item: book.item(part.itemID), cost: DishMaths.partCost(part, book: book))
                    }
                    .onDelete { dish.parts.remove(atOffsets: $0) }
                    Button {
                        picking = true
                    } label: {
                        Label("Add an ingredient", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Made from")
                } footer: {
                    Text("For each item: how many the pack holds, and how many this dish uses. A case of 48 patties, 1 per burger: pack 48, uses 1. Swipe left to remove one.")
                }
                Section {
                    LabeledContent("Ingredients cost", value: Money.format(cost.cost))
                    LabeledContent("Price without VAT", value: Money.format(cost.netPrice))
                    LabeledContent("You keep") {
                        Text(Money.format(cost.margin))
                            .fontWeight(.semibold)
                            .foregroundStyle(cost.margin < 0 ? .red : .primary)
                    }
                    if let percent = cost.foodCostPercent {
                        LabeledContent("Food cost", value: String(format: "%.0f%%", percent))
                    }
                    if let target = DishMaths.priceFor(foodCost: 30, cost: cost.cost, vatRate: dish.vatRate) {
                        LabeledContent("Price for 30% food cost", value: Money.format(target))
                    }
                }
            }
            .navigationTitle(dish.name.isEmpty ? String(localized: "New dish") : dish.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = dish
                        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                        saved.parts.removeAll { $0.packOf <= 0 }
                        // the cost now, so later price rises show against it
                        saved.costWhenSet = DishMaths.cost(of: saved, items: items).cost
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(dish.name.trimmingCharacters(in: .whitespaces).isEmpty || dish.parts.isEmpty)
                }
            }
            .sheet(isPresented: $picking) {
                ItemPicker(items: items) { item in
                    dish.parts.append(DishPart(itemID: item.id, uses: 1, packOf: PackGuess.count(in: item.name)))
                }
            }
        }
    }
}

private struct PartRow: View {
    @Binding var part: DishPart
    let item: PriceItem?
    let cost: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item?.name ?? String(localized: "No longer in your price list"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(item == nil ? .orange : .primary)
                Spacer()
                if let cost { Text(Money.format(Money.round2(cost))).font(.subheadline) }
            }
            HStack(spacing: 16) {
                Stepper(value: $part.packOf, in: 1...10_000, step: 1) {
                    Text("Pack \(part.packOf, specifier: "%g")")
                        .font(.footnote)
                }
            }
            HStack {
                Text("Uses")
                    .font(.footnote)
                TextField("1", value: $part.uses, format: .number)
                    .keyboardType(.decimalPad)
                    .font(.footnote)
                    .frame(maxWidth: 80)
                    .textFieldStyle(.roundedBorder)
                Spacer()
            }
        }
        .padding(.vertical, 2)
    }
}

/// Choose an item from the price list.
private struct ItemPicker: View {
    let items: [PriceItem]
    let onPick: (PriceItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var shown: [PriceItem] {
        let query = TextTools.norm(search)
        let list = query.isEmpty ? items : items.filter { TextTools.norm($0.name + " " + $0.aliases.joined(separator: " ")).contains(query) }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List(shown) { item in
                Button {
                    onPick(item)
                    dismiss()
                } label: {
                    LabeledContent(item.name, value: Money.format(item.price))
                }
                .foregroundStyle(.primary)
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Add an ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
