import SwiftUI
import ChargeCheckCore

/// Add, rename and remove shops, and choose the one new invoices are filed under.
struct ShopsView: View {
    @AppStorage(Shops.listKey) private var shopData = Data()
    @AppStorage(Shops.currentKey) private var current = ""
    @State private var newName = ""
    @State private var renaming: ShopInfo?
    @State private var renameText = ""

    private var shops: [ShopInfo] { Shops.decode(shopData) }

    private func store(_ list: [ShopInfo]) {
        shopData = Shops.encode(list)
        if !list.contains(where: { $0.id == current }) { current = list.first?.id ?? "" }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var list = shops
        list.append(ShopInfo(id: UUID().uuidString, name: String(name.prefix(60))))
        store(list)
        newName = ""
    }

    var body: some View {
        List {
            Section {
                ForEach(shops, id: \.id) { shop in
                    Button {
                        current = shop.id
                    } label: {
                        HStack {
                            Text(shop.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if Shops.current == shop.id || current == shop.id {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            store(shops.filter { $0.id != shop.id })
                        }
                        Button("Rename") {
                            renameText = shop.name
                            renaming = shop
                        }
                        .tint(.gray)
                    }
                }
                HStack {
                    TextField("Add a shop, e.g. High Street", text: $newName)
                        .onSubmit { add() }
                    Button("Add") { add() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text(shops.isEmpty
                     ? "Only needed if you have more than one shop. Each invoice is filed under a shop, and Reports can show each shop on its own. Your prices are shared by all shops."
                     : "New invoices are filed under the ticked shop. Swipe a shop to rename or remove it; its invoices stay in Reports.")
            }
        }
        .navigationTitle("Your shops")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename shop", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Shop name", text: $renameText)
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if let shop = renaming, !name.isEmpty {
                    store(shops.map { $0.id == shop.id ? ShopInfo(id: shop.id, name: String(name.prefix(60))) : $0 })
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}
