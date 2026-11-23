import ChargeCheckCore
import SwiftData
import SwiftUI

/// Till › Recipes: what each dish or drink is made of and what one portion costs (rules in `Recipes`). Saving a
/// change makes a new version from now on, so sales already made keep the cost they had.
struct RecipesView: View {
    @Query private var prices: [StoredPrice]
    @ObservedObject private var till = TillStore.shared
    @State private var editing: Recipe?
    @State private var choosing = false
    @State private var notice: String?

    private var items: [PriceItem] { prices.map { $0.item } }

    var body: some View {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        List {
            if till.currentRecipes.isEmpty {
                ContentUnavailableView("No recipes yet", systemImage: "fork.knife",
                                       description: Text("Add what a dish or drink is made of to see what each portion costs and how stock is used."))
            }
            ForEach(till.currentRecipes.sorted { (byID[$0.itemID]?.name ?? "") < (byID[$1.itemID]?.name ?? "") }) { recipe in
                let cost = Recipes.cost(recipe, packPrice: { byID[$0]?.price })
                Button {
                    editing = recipe
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(byID[recipe.itemID]?.name ?? recipe.itemID).font(.headline)
                            Text(String(localized: "Version \(recipe.version) · \(recipe.ingredients.count) ingredients"))
                                .font(.caption).foregroundStyle(.secondary)
                            if !cost.unpriced.isEmpty {
                                Text("Some ingredients can't be priced: check their units.").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Money.format(cost.perPortion)).font(.headline).monospacedDigit()
                            if let sell = byID[recipe.itemID]?.till?.sell, sell > 0 {
                                let margin = (sell - cost.perPortion) / sell * 100
                                Text(String(localized: "\(margin.formatted(.number.precision(.fractionLength(0))))% margin"))
                                    .font(.caption2).foregroundStyle(margin < 50 ? .orange : .secondary)
                            }
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("Recipes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(items.filter { $0.till?.sell != nil && !till.currentRecipes.map(\.itemID).contains($0.id) }
                        .sorted { $0.name < $1.name }) { item in
                        Button(item.name) {
                            editing = Recipe(itemID: item.id, version: 0, from: "", ingredients: [])
                        }
                    }
                } label: {
                    Label("Add a recipe", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { recipe in
            RecipeEditor(recipe: recipe, items: items) { ingredients, portions in
                let now = ISO8601DateFormatter().string(from: Date())
                if !till.saveRecipe(Recipes.revise(recipe, ingredients: ingredients, portions: portions, at: now)) {
                    notice = String(localized: "Only the owner or a manager can change recipes.")
                }
            }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

private struct RecipeEditor: View {
    let recipe: Recipe
    let items: [PriceItem]
    let onSave: ([Ingredient], Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ingredients: [Ingredient] = []
    @State private var portions = 1.0
    @State private var loaded = false

    var body: some View {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let draft = Recipe(itemID: recipe.itemID, from: "", portions: portions, ingredients: ingredients)
        let cost = Recipes.cost(draft, packPrice: { byID[$0]?.price })
        NavigationStack {
            Form {
                Section {
                    Stepper(String(localized: "Makes \(portions.formatted()) portions"), value: $portions, in: 1...500)
                    LabeledContent("Cost per portion", value: Money.format(cost.perPortion))
                }
                ForEach($ingredients) { $ingredient in
                    Section(byID[ingredient.itemID]?.name ?? ingredient.itemID) {
                        HStack {
                            TextField("Amount", value: $ingredient.qty, format: .number).keyboardType(.decimalPad)
                            Picker("Unit", selection: $ingredient.unit) {
                                ForEach(RecipeUnit.allCases, id: \.self) { Text($0.rawValue) }
                            }
                            .labelsHidden()
                        }
                        HStack {
                            Text("One pack holds")
                            TextField("Pack", value: $ingredient.packSize, format: .number).keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Picker("Pack unit", selection: $ingredient.packUnit) {
                                ForEach(RecipeUnit.allCases, id: \.self) { Text($0.rawValue) }
                            }
                            .labelsHidden()
                        }
                        Stepper(String(localized: "Waste \(ingredient.waste.formatted())%"), value: $ingredient.waste, in: 0...90, step: 5)
                        if ingredient.packsUsed == nil {
                            Text("This amount and the pack don't measure the same thing (weight, volume or count).")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .onDelete { ingredients.remove(atOffsets: $0) }
                Section {
                    Menu {
                        ForEach(items.filter { $0.id != recipe.itemID }.sorted { $0.name < $1.name }) { item in
                            Button(item.name) {
                                ingredients.append(Ingredient(itemID: item.id, qty: 1, unit: .each, packSize: item.unitsPerPack, packUnit: .each))
                            }
                        }
                    } label: {
                        Label("Add an ingredient", systemImage: "plus.circle")
                    }
                } footer: {
                    Text("Pick ingredients from your price list. Saving makes a new version from now on; sales already made keep the cost they had.")
                }
            }
            .navigationTitle(items.first { $0.id == recipe.itemID }?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(ingredients, portions)
                        dismiss()
                    }
                    .disabled(ingredients.isEmpty)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                ingredients = recipe.ingredients
                portions = max(1, recipe.portions)
            }
        }
    }
}
