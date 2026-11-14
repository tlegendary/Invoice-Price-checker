import SwiftUI
import SwiftData
import ChargeCheckCore

/// The More tab: price list, shops, staff, records and settings.
struct MoreView: View {
    @Binding var showPaywall: Bool

    enum Page: String, Hashable {
        case prices, shops, staff, settings, deleted, history
    }

    @ObservedObject private var team = CloudTeam.shared
    @ObservedObject private var records = Records.shared
    @EnvironmentObject private var store: Store
    @Query private var prices: [StoredPrice]
    @AppStorage(Shops.listKey) private var shopData = Data()
    @State private var path: [Page]

    init(showPaywall: Binding<Bool>, open: Page? = nil) {
        _showPaywall = showPaywall
        _path = State(initialValue: open.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // staff phones: prices, shops and records are the owner's
                if !team.isStaff {
                    Section {
                        NavigationLink(value: Page.prices) {
                            LabeledContent {
                                Text("\(prices.count)")
                            } label: {
                                Label("Price list", systemImage: "tag")
                            }
                        }
                        NavigationLink(value: Page.shops) {
                            LabeledContent {
                                let shops = Shops.decode(shopData)
                                Text(shops.isEmpty ? String(localized: "One shop") : "\(shops.count)")
                            } label: {
                                Label("Shops", systemImage: "storefront")
                            }
                        }
                    } header: {
                        Text("Your business")
                    }
                }
                Section {
                    NavigationLink(value: Page.staff) {
                        LabeledContent {
                            Text(team.role == .owner ? String(localized: "Sharing on") : team.role == .staff ? String(localized: "Team member") : "")
                        } label: {
                            Label("Staff", systemImage: "person.2")
                        }
                    }
                } footer: {
                    if team.role == .none {
                        Text("Let staff check invoices on their own iPhones.")
                    }
                }
                if !team.isStaff {
                    Section {
                        NavigationLink(value: Page.deleted) {
                            LabeledContent {
                                if !records.bin.isEmpty { Text("\(records.bin.count)") }
                            } label: {
                                Label("Recently deleted", systemImage: "trash")
                            }
                        }
                        NavigationLink(value: Page.history) {
                            Label("History of changes", systemImage: "clock.arrow.circlepath")
                        }
                    } header: {
                        Text("Records")
                    } footer: {
                        Text("Deleted invoices, payments and prices can be brought back for 30 days.")
                    }
                }
                Section {
                    NavigationLink(value: Page.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                    if !store.isSubscribed && store.checkedEntitlements {
                        Button {
                            showPaywall = true
                        } label: {
                            Label("Go unlimited", systemImage: "star.circle")
                        }
                    }
                }
            }
            .navigationTitle("More")
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .prices: PricesView(embedded: true)
                case .shops: ShopsView()
                case .staff: TeamView()
                case .settings: SettingsView(showPaywall: $showPaywall, embedded: true)
                case .deleted: RecentlyDeletedView()
                case .history: ChangeHistoryView()
                }
            }
        }
    }
}
