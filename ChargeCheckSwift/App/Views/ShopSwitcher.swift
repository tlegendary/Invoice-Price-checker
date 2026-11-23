import SwiftUI
import ChargeCheckCore

/// "Which shop am I looking at?" – in the top bar of Home, Invoices, Suppliers and Reports when there are shops.
/// Choosing a shop changes every screen at once (and files new invoices under it); "All shops" shows everything.
struct ShopSwitcher: View {
    @AppStorage(Shops.listKey) private var shopData = Data()

    var body: some View {
        let shops = Shops.decode(shopData)
        let live = LiveSettings.shared
        if !shops.isEmpty {
            Menu {
                Picker("Show", selection: Binding(get: { live.shop }, set: { live.view(shop: $0) })) {
                    Label("All shops", systemImage: "square.grid.2x2").tag("")
                    ForEach(shops, id: \.id) { shop in
                        Label(shop.name, systemImage: "storefront").tag(shop.id)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: live.shop.isEmpty ? "square.grid.2x2" : "storefront")
                    Text(shops.first { $0.id == live.shop }?.name ?? String(localized: "All shops"))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .font(.subheadline.weight(.semibold))
            }
            .accessibilityLabel(Text("Shop"))
            .accessibilityValue(Text(shops.first { $0.id == live.shop }?.name ?? String(localized: "All shops")))
        }
    }
}

extension View {
    /// Adds the shop switcher to this screen's top bar.
    func shopSwitcher() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ShopSwitcher()
            }
        }
    }
}
