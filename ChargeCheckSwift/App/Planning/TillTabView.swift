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
                        NavigationLink { ManagerOnly { DealsView() } } label: { Label("Meal deals and multi-buys", systemImage: "takeoutbag.and.cup.and.straw") }
                        NavigationLink { ManagerOnly { VouchersView() } } label: { Label("Vouchers", systemImage: "ticket") }
                    } header: {
                        Text("Pricing and discounts")
                    } footer: {
                        Text("Item options (size, add-ons), variants, VAT and multi-buys are set on each item: price list › the item › Sell at the till.")
                    }
                    Section {
                        NavigationLink { CustomersView() } label: { Label("Customers, accounts and store credit", systemImage: "person.2") }
                        NavigationLink { GiftCardsView() } label: { Label("Gift cards", systemImage: "giftcard") }
                        NavigationLink { RecipesView() } label: { Label("Recipes and costing", systemImage: "fork.knife") }
                        NavigationLink { KitchenView() } label: { Label("Kitchen screen", systemImage: "frying.pan") }
                        NavigationLink { LayawaysView() } label: {
                            LabeledContent {
                                let open = till.layaways.filter { $0.status == .open }.count
                                if open > 0 { Text("\(open)") }
                            } label: {
                                Label("Layaways", systemImage: "shippingbox.and.arrow.backward")
                            }
                        }
                    } header: {
                        Text("Payments and customers")
                    }
                    Section {
                        NavigationLink { StockView() } label: { Label("Stock and moving stock", systemImage: "shippingbox") }
                        NavigationLink { ExpiryView() } label: { Label("Expiry dates", systemImage: "calendar.badge.exclamationmark") }
                        NavigationLink { OrdersView() } label: { Label("Supplier orders", systemImage: "cart.badge.plus") }
                    } header: {
                        Text("Stock")
                    }
                    Section {
                        NavigationLink { SalesView() } label: { Label("Sales, best sellers, peak hours", systemImage: "chart.line.uptrend.xyaxis") }
                        if shop != nil {
                            Button {
                                showDay = true
                            } label: {
                                Label(till.severalTills ? String(localized: "End of day (till \(till.code))") : String(localized: "End of day"),
                                      systemImage: "lock.rectangle.stack")
                            }
                        }
                    } header: {
                        Text("Reports")
                    } footer: {
                        Text("Sales by item, category, hour and cashier, with VAT, as a spreadsheet or PDF.")
                    }
                    Section {
                        NavigationLink { ShiftsView() } label: { Label("Staff hours", systemImage: "clock") }
                        NavigationLink { ManagerOnly { TillPermissionsView() } } label: { Label("What cashiers can do", systemImage: "lock.shield") }
                        NavigationLink { ChangeHistoryView() } label: { Label("Activity: voids, refunds, no sales", systemImage: "list.bullet.rectangle") }
                        Toggle(isOn: $till.training) {
                            Label("Training mode", systemImage: "graduationcap")
                        }
                    } header: {
                        Text("Staff and security")
                    } footer: {
                        Text("Training mode: new staff use the real till, but sales, refunds and cash aren't saved and stock doesn't change.")
                    }
                    Section {
                        NavigationLink { TillSettingsView() } label: { Label("Till settings, people and products", systemImage: "gearshape.2") }
                        NavigationLink { ManagerOnly { PrinterSettingsView() } } label: { Label("Receipt printer and cash drawer", systemImage: "printer") }
                        Button {
                            beScreen = true
                        } label: {
                            Label("Be the customer screen", systemImage: "person.crop.rectangle")
                        }
                        Toggle(isOn: $tillTab) {
                            Label("Till as its own tab", systemImage: "rectangle.bottomthird.inset.filled")
                        }
                    } header: {
                        Text("Setup")
                    } footer: {
                        Text("Turn off “Till as its own tab” to put Reports back in this tab. The till is then in More and on Home.")
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
                            Text(till.training ? String(localized: "Training mode is on") : cashier.name).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
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
        } footer: {
            if live.shop.isEmpty && Shops.decode(shopData).count > 1 {
                Text("Today's figures are for every shop. Choose a shop at the top to see one.")
            }
        }
    }
}
