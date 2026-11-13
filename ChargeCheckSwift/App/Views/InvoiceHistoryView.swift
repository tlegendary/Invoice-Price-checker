import SwiftUI
import SwiftData
import ChargeCheckCore

/// Every checked invoice, newest first, with a filter. Rows open with a `ReportLink`.
struct InvoiceHistoryView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, toPay, problems, credits
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: return "All"
            case .toPay: return "To pay"
            case .problems: return "Problems"
            case .credits: return "Credits"
            }
        }
    }

    @Environment(\.modelContext) private var context
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @AppStorage(Shops.listKey) private var shopData = Data()
    @State private var filter = Filter.all
    @State private var shopFilter = ""
    @State private var search = ""
    @State private var confirmDelete: HistoryEntry?

    private var shops: [ShopInfo] { Shops.decode(shopData) }

    private var shown: [HistoryEntry] {
        var list = reports.compactMap { $0.entry }
        if !shopFilter.isEmpty { list = list.filter { $0.shopId == shopFilter } }
        switch filter {
        case .all: break
        case .toPay: list = list.filter { $0.paid == nil }
        case .problems: list = list.filter { $0.amountToPay.less > 0.005 || !$0.verified }
        case .credits: list = list.filter { $0.credit != nil }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            let found = Set(Search.find(query, entries: list, payments: [], items: [], limit: 10_000).invoices.map { $0.id })
            list = list.filter { found.contains($0.id) }
        }
        return list
    }

    var body: some View {
        let list = shown
        List {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if list.isEmpty {
                ContentUnavailableView("No invoices", systemImage: "tray")
            }
            Section {
                ForEach(list) { entry in
                    NavigationLink(value: ReportLink(id: entry.id)) {
                        ReportRow(entry: entry)
                    }
                    .swipeActions(edge: .trailing) {
                        // staff phones: only the owner removes invoices
                        if !CloudTeam.shared.isStaff {
                            Button(role: .destructive) {
                                confirmDelete = entry
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } footer: {
                if !list.isEmpty {
                    Text(list.count == 1 ? String(localized: "1 invoice") : String(localized: "\(list.count) invoices"))
                }
            }
        }
        .navigationTitle("Checked invoices")
        .searchable(text: $search, prompt: "Supplier, number, item or amount")
        .toolbar {
            if !shops.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Shop", selection: $shopFilter) {
                        Text("All shops").tag("")
                        ForEach(shops, id: \.id) { shop in
                            Text(shop.name).tag(shop.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .confirmationDialog("Delete this invoice?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmDelete) { entry in
            Button("Delete", role: .destructive) {
                AppData.deleteReport(entry.id, context: context)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You can bring it back from More › Recently deleted for 30 days.")
        }
    }
}
