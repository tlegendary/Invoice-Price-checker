import SwiftUI
import ChargeCheckCore

struct CategoryMove: Identifiable {
    let id: String
    let name: String
    let from: String
    let to: String
}

/// Shows where each item would be moved, lets the user untick any, then applies.
struct SortCategoriesView: View {
    @Environment(\.dismiss) private var dismiss

    let items: [PriceItem]
    /// Item id → new category.
    let onApply: ([String: String]) -> Void

    @State private var recheckAll = false
    @State private var moves: [CategoryMove] = []
    @State private var skipped: Set<String> = []

    private var chosen: [CategoryMove] { moves.filter { !skipped.contains($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Re-check items that already have a category", isOn: $recheckAll)
                } footer: {
                    Text(recheckAll ? "Looks at every item." : "Sorts items that are in “Other” or have no category. It learns from the items you've already sorted.")
                }
                if moves.isEmpty {
                    Section {
                        Text(recheckAll ? "Everything is already in the right place." : "Nothing to sort. Every item already has a category.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Untick anything you don't want moved") {
                        ForEach(moves) { move in
                            Toggle(isOn: Binding(
                                get: { !skipped.contains(move.id) },
                                set: { isOn in
                                    if isOn { skipped.remove(move.id) } else { skipped.insert(move.id) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(move.name)
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(move.from) → \(move.to)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sort into categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chosen.isEmpty ? "Move" : "Move \(chosen.count)") {
                        var result: [String: String] = [:]
                        for move in chosen { result[move.id] = move.to }
                        onApply(result)
                        dismiss()
                    }
                    .disabled(chosen.isEmpty)
                }
            }
            .onAppear { work() }
            .onChange(of: recheckAll) { work() }
        }
    }

    private func work() {
        skipped = []
        moves = items.compactMap { item in
            if !recheckAll && !Categoriser.isUnsorted(item.cat) { return nil }
            guard let target = Categoriser.suggest(for: item, in: items), target != item.cat else { return nil }
            return CategoryMove(id: item.id, name: item.name, from: item.cat.isEmpty ? "No category" : item.cat, to: target)
        }
    }
}
