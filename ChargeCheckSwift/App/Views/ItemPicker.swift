import SwiftUI
import ChargeCheckCore

/// Choose an item from the price list.
struct ItemPicker: View {
    let items: [PriceItem]
    let onPick: (PriceItem) -> Void
    var title = String(localized: "Choose an item")
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
            .navigationTitle(title)
            .themedScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
