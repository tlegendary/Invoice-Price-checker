import SwiftUI
import ChargeCheckCore

/// Prices › More › "Suggest other names": likely supplier spellings for the whole price list in one go.
/// Everything is ticked to start with; untick any you don't want. A name is never suggested if it could
/// also be read as another item, so adding them doesn't cause "which item is it?" questions.
struct NameSuggestionsView: View {
    let items: [PriceItem]
    let onSave: ([PriceItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row]?
    @State private var chosen: Set<String> = []

    struct Row: Identifiable, Sendable {
        var id: String { item.id }
        let item: PriceItem
        let ideas: [String]
    }

    private static func key(_ row: Row, _ idea: String) -> String { row.item.id + "\u{1F}" + idea }

    var body: some View {
        NavigationStack {
            Group {
                if let rows {
                    if rows.isEmpty {
                        ContentUnavailableView("No new names to suggest", systemImage: "checkmark.seal",
                                               description: Text("Your items already have the usual names, or another name would be too easy to mix up with another item."))
                    } else {
                        List {
                            Section {
                                Text("Ways suppliers often write these items. Untick any you don't want, then add them. Matching ignores word order.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(rows) { row in
                                Section {
                                    ForEach(row.ideas, id: \.self) { idea in
                                        Toggle(isOn: Binding(
                                            get: { chosen.contains(Self.key(row, idea)) },
                                            set: { on in
                                                if on { chosen.insert(Self.key(row, idea)) } else { chosen.remove(Self.key(row, idea)) }
                                            }
                                        )) {
                                            Text(verbatim: idea)
                                        }
                                    }
                                } header: {
                                    Text(verbatim: row.item.name)
                                        .textCase(nil)
                                }
                            }
                        }
                    }
                } else {
                    ProgressView("Finding other names…")
                }
            }
            .navigationTitle("Other names")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chosen.count == 1 ? String(localized: "Add 1 name") : String(localized: "Add \(chosen.count) names")) {
                        save()
                    }
                    .disabled(chosen.isEmpty)
                }
            }
            .task {
                let all = items
                let found = await Task.detached(priority: .userInitiated) {
                    all.compactMap { item -> Row? in
                        let ideas = NameIdeas.suggest(for: item, among: all, limit: 4)
                        return ideas.isEmpty ? nil : Row(item: item, ideas: ideas)
                    }
                }.value
                chosen = Set(found.flatMap { row in row.ideas.map { Self.key(row, $0) } })
                rows = found
            }
        }
    }

    private func save() {
        var changed: [PriceItem] = []
        for row in rows ?? [] {
            let names = row.ideas.filter { chosen.contains(Self.key(row, $0)) }
            guard !names.isEmpty else { continue }
            var item = row.item
            for name in names where !item.aliases.contains(name) { item.aliases.append(name) }
            changed.append(item)
        }
        onSave(changed)
        dismiss()
    }
}
