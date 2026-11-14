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
    @EnvironmentObject private var store: Store
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @State private var filter = Filter.all
    @State private var search = ""
    /// Select mode: tick invoices (or all of them) to delete them or move them to another shop.
    @State private var editMode: EditMode
    @State private var selected: Set<String> = []
    @State private var confirmDeleteSelected = false
    @AppStorage(Shops.listKey) private var shopData = Data()

    private var selecting: Bool { editMode.isEditing }

    /// `selecting`: open straight in select mode (the Invoices tab's Select button).
    init(selecting: Bool = false) {
        _editMode = State(initialValue: selecting ? .active : .inactive)
    }

    private var shown: [HistoryEntry] {
        // the shop being viewed (every shop under "All shops")
        var list = Plans.visible(Accounts.shared.inShop(reports.compactMap { $0.entry }), tier: store.tier)
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
        List(selection: $selected) {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if list.isEmpty {
                ContentUnavailableView("No invoices", systemImage: "tray")
            }
            let older = Plans.hidden(reports.compactMap { $0.entry }, tier: store.tier)
            if older > 0 {
                Section {
                    LockedRow(feature: .fullHistory) {
                        Label(older == 1 ? String(localized: "1 older invoice") : String(localized: "\(older) older invoices"), systemImage: "clock")
                    }
                } footer: {
                    Text("The free version lists the last 30 days. Your balances still count every invoice.")
                }
            }
            Section {
                ForEach(list) { entry in
                    NavigationLink(value: ReportLink(id: entry.id)) {
                        ReportRow(entry: entry)
                    }
                    .tag(entry.id)
                    .invoiceSwipes(entry)
                }
            } footer: {
                if !list.isEmpty {
                    Text(list.count == 1 ? String(localized: "1 invoice") : String(localized: "\(list.count) invoices"))
                }
            }
        }
        .navigationTitle(selecting ? (selected.count == 1 ? String(localized: "1 selected") : String(localized: "\(selected.count) selected")) : String(localized: "Checked invoices"))
        .searchable(text: $search, prompt: "Supplier, number, item or amount")
        .environment(\.editMode, $editMode)
        .toolbar {
            if selecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selected.count == list.count && !list.isEmpty ? String(localized: "Deselect all") : String(localized: "Select all")) {
                        selected = selected.count == list.count ? [] : Set(list.map { $0.id })
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        editMode = .inactive
                        selected = []
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") { editMode = .active }
                        .disabled(list.isEmpty)
                }
            }
        }
        .toolbar {
            if !selecting {
                ToolbarItem(placement: .topBarLeading) { ShopSwitcher() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                SelectionBar(count: selected.count, shops: Shops.decode(shopData), deleteTitle: String(localized: "Delete"),
                             onMove: { shop in
                                 Accounts.shared.moveInvoices(selected, to: shop, context: context)
                                 selected = []
                                 editMode = .inactive
                             },
                             onDelete: { confirmDeleteSelected = true })
            }
        }
        .confirmationDialog(selected.count == 1 ? String(localized: "Delete 1 invoice?") : String(localized: "Delete \(selected.count) invoices?"),
                            isPresented: $confirmDeleteSelected, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                AppData.deleteReports(selected, context: context)
                Accounts.shared.changed(context)
                selected = []
                editMode = .inactive
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can bring them back from More › Recently deleted for 30 days.")
        }
    }
}

/// Every invoice list: swipe right to pay (or, on a paid one, to mark it unpaid again), swipe left to delete.
/// Paying asks once with the amount, so a swipe on the wrong row can't record a payment by itself.
struct InvoiceSwipes: ViewModifier {
    let entry: HistoryEntry
    @Environment(\.modelContext) private var context
    @State private var confirmPay = false
    @State private var confirmDelete = false

    func body(content: Content) -> some View {
        // staff phones: only the owner pays or removes invoices
        let owner = !CloudTeam.shared.isStaff
        let pay = entry.amountToPay.pay
        content
            .swipeActions(edge: .leading, allowsFullSwipe: entry.paid == nil) {
                if owner {
                    if entry.paid == nil {
                        Button {
                            confirmPay = true
                        } label: {
                            Label("Pay", systemImage: "banknote")
                        }
                        .tint(.green)
                    } else {
                        Button {
                            Accounts.shared.markUnpaid([entry.id], context: context)
                        } label: {
                            Label("Unpaid", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.orange)
                    }
                }
            }
            .swipeActions(edge: .trailing) {
                if owner {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .confirmationDialog(String(localized: "Mark as paid (\(Money.format(pay, supplier: entry.supplier)))?"),
                                isPresented: $confirmPay, titleVisibility: .visible) {
                Button("Mark as paid") {
                    Accounts.shared.markPaid([entry], context: context)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(entry.supplier.isEmpty ? String(localized: "A payment for this invoice is recorded today.")
                                            : String(localized: "A payment to \(entry.supplier) for this invoice is recorded today."))
            }
            .confirmationDialog("Delete this invoice?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    AppData.deleteReport(entry.id, context: context)
                    Accounts.shared.changed(context)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can bring it back from More › Recently deleted for 30 days.")
            }
    }
}

extension View {
    func invoiceSwipes(_ entry: HistoryEntry) -> some View { modifier(InvoiceSwipes(entry: entry)) }
}

/// The bar under a list in select mode: move the ticked rows to a shop, or delete them.
struct SelectionBar: View {
    let count: Int
    let shops: [ShopInfo]
    let deleteTitle: String
    /// "" = all shops / no shop, otherwise a shop's id.
    let onMove: (String) -> Void
    let onDelete: () -> Void
    /// For the price list: "Add to" a shop as well as "Move to" (items can be in several shops).
    var onAdd: ((String) -> Void)?
    var allShopsTitle: String?

    /// No shops yet (or only one): "Move to shop" offers to add them, in Your shops.
    @State private var showShops = false

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                if !shops.isEmpty {
                    if let allShopsTitle, shops.count > 1 {
                        Button(allShopsTitle) { onMove("") }
                    }
                    Section(String(localized: "Move to")) {
                        ForEach(shops, id: \.id) { shop in
                            Button(shop.name) { onMove(shop.id) }
                        }
                    }
                    if let onAdd, shops.count > 1 {
                        Section(String(localized: "Also add to")) {
                            ForEach(shops, id: \.id) { shop in
                                Button(shop.name) { onAdd(shop.id) }
                            }
                        }
                    }
                }
                Section(shops.count < 2 ? String(localized: "Add your shops first, then move these to the right one.") : "") {
                    Button {
                        showShops = true
                    } label: {
                        Label(shops.isEmpty ? String(localized: "Add your shops") : String(localized: "Add a shop"), systemImage: "plus")
                    }
                }
            } label: {
                Label("Move to shop", systemImage: "storefront")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(count == 0)
            Button(role: .destructive, action: onDelete) {
                Label(deleteTitle, systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(count == 0)
        }
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .sheet(isPresented: $showShops) {
            NavigationStack {
                ShopsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showShops = false }
                        }
                    }
            }
        }
    }
}
