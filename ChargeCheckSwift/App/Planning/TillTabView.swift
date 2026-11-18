import SwiftUI
import SwiftData
import ChargeCheckCore

/// Whether the till has its own tab (in the Reports tab's place; Reports moves to the top of More).
enum TillTab {
    static let key = "tabs.till"

    /// The first time the till is opened or sells, it gets its tab (unless the owner turned the tab off).
    static func firstUse() {
        if UserDefaults.standard.object(forKey: key) == nil { UserDefaults.standard.set(true, forKey: key) }
    }
}

/// The Till tab: open the till, today's takings, and everything about selling in one place.
struct TillTabView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var till = TillStore.shared
    @AppStorage(Shops.listKey) private var shopData = Data()
    @AppStorage(TillTab.key) private var tillTab = false
    private var live: LiveSettings { LiveSettings.shared }
    @State private var showTill = false
    @State private var showDay = false
    @State private var beScreen = false

    private var shop: String? { TillShop.resolve(view: live.shop, shops: Shops.decode(shopData)) }

    var body: some View {
        NavigationStack {
            List {
                if store.allows(.till) {
                    todaySection
                    Section {
                        NavigationLink { SalesView() } label: { Label("Sales and profit", systemImage: "chart.line.uptrend.xyaxis") }
                        NavigationLink { StockView() } label: { Label("Stock", systemImage: "shippingbox") }
                        NavigationLink { ExpiryView() } label: { Label("Expiry dates", systemImage: "calendar.badge.exclamationmark") }
                    } header: {
                        Text("Selling")
                    }
                    Section {
                        NavigationLink { CustomersView() } label: { Label("Customers and accounts", systemImage: "person.2") }
                        NavigationLink { GiftCardsView() } label: { Label("Gift cards", systemImage: "giftcard") }
                    } header: {
                        Text("Customers")
                    }
                    Section {
                        NavigationLink { ShiftsView() } label: { Label("Staff hours", systemImage: "clock") }
                        NavigationLink { TillSettingsView() } label: { Label("Till settings and products", systemImage: "gearshape.2") }
                        Button {
                            beScreen = true
                        } label: {
                            Label("Be the customer screen", systemImage: "person.crop.rectangle")
                        }
                    } header: {
                        Text("Staff and setup")
                    }
                    Section {
                        Toggle(isOn: $tillTab) {
                            Label("Till as its own tab", systemImage: "rectangle.bottomthird.inset.filled")
                        }
                    } footer: {
                        Text("Turn off to put Reports back in this tab. The till is then in More and on Home.")
                    }
                } else {
                    Section {
                        LockedRow(feature: .till) {
                            Label("Till, stock and sales", systemImage: "cart")
                        }
                    }
                }
            }
            .navigationTitle("Till")
            .themedScreen()
            .shopSwitcher()
            .fullScreenCover(isPresented: $showTill) { TillView() }
            .fullScreenCover(isPresented: $beScreen) { CustomerScreenView(joins: true) }
            .sheet(isPresented: $showDay) { DayView(shop: shop ?? "") }
        }
    }

    private var todaySection: some View {
        let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
        let sales = till.sales.filter { $0.at >= today && (live.shop.isEmpty || $0.shop == live.shop) }
        let summary = SaleMaths.summary(sales)
        return Section {
            Button {
                showTill = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "cart.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open the till").font(.headline)
                        if let cashier = till.cashier {
                            Text(cashier.name).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
            LabeledContent("Takings today") {
                Text(Money.format(summary.takings)).fontWeight(.semibold).monospacedDigit()
            }
            LabeledContent("Sales today", value: "\(summary.sales)")
            if summary.unknownCost == 0 || summary.profit != 0 {
                LabeledContent("Profit today") {
                    Text(Money.format(summary.profit)).monospacedDigit()
                        .foregroundStyle(summary.profit < 0 ? Color.red : Color.primary)
                }
            }
            if shop != nil {
                Button {
                    showDay = true
                } label: {
                    Label(till.severalTills ? String(localized: "End of day (till \(till.code))") : String(localized: "End of day"),
                          systemImage: "lock.rectangle.stack")
                }
            }
        } footer: {
            if live.shop.isEmpty && Shops.decode(shopData).count > 1 {
                Text("Today's figures are for every shop. Choose a shop at the top to see one.")
            }
        }
    }
}
