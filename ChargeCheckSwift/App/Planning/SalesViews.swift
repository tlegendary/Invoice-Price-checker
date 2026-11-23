import SwiftUI
import SwiftData
import ChargeCheckCore

/// Till › Sales and profit: a day's (or week's, month's) takings, profit and every sale, with refunds.
struct SalesView: View {
    @ObservedObject private var till = TillStore.shared
    @AppStorage(Shops.listKey) private var shopData = Data()
    @Query private var prices: [StoredPrice]
    @State private var period = 0
    @State private var opened: Sale?
    @State private var breakdown = 0
    @State private var exported: URL?
    @State private var exportedPDF: URL?
    @AppStorage(SettingKey.colour) private var colourID = "green"
    @State private var search = ""

    private var shop: String { LiveSettings.shared.shop }

    /// Items selling for too little over what they cost now (a supplier's price went up, or the till price is low).
    @ViewBuilder
    private var marginSection: some View {
        let alerts = MarginAlerts.find(prices.map { $0.item }, shop: LiveSettings.shared.shop)
        if !alerts.isEmpty {
            Section {
                ForEach(alerts.prefix(8), id: \.itemID) { alert in
                    LabeledContent(alert.name) {
                        Text(String(localized: "\(alert.margin.formatted())% margin"))
                            .foregroundStyle(alert.margin < 0 ? .red : .orange)
                    }
                }
            } header: {
                Text("Low margins")
            } footer: {
                Text("At today's cost prices, these earn less than 30% before VAT. Check the till price or the supplier's price.")
            }
        }
    }

    private func breakdownSection(_ shown: [Sale]) -> some View {
        Section {
            Picker("Show", selection: $breakdown) {
                Text("Items").tag(0)
                Text("Categories").tag(1)
                Text("Hours").tag(2)
                Text("Cashiers").tag(3)
            }
            .pickerStyle(.segmented)
            let rows: [SalesRow] = {
                switch breakdown {
                case 1: return SalesReports.byCategory(shown, items: prices.map { $0.item }, other: String(localized: "Other"))
                case 2: return SalesReports.byHour(shown)
                case 3: return SalesReports.byCashier(shown, nobody: String(localized: "No cashier"))
                default: return SalesReports.byItem(shown)
                }
            }()
            ForEach(rows.prefix(breakdown == 2 ? 24 : 15)) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(.subheadline)
                        Text(String(localized: "\(row.qty.formatted()) sold") + (row.profit.map { " · " + String(localized: "profit \(Money.format($0))") } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Money.format(row.takings)).fontWeight(.semibold).monospacedDigit()
                }
            }
            if let exportedPDF {
                ShareLink(item: exportedPDF) {
                    Label("Share the PDF", systemImage: "square.and.arrow.up")
                }
            } else {
                Button {
                    let data = TillPDF.sales(shown, period: SupplierAccounts.dayText(Date()), items: prices.map { $0.item }, theme: Themes.inUse(colourID))
                    exportedPDF = AppFiles.write(data, folder: "Exports", name: "Sales \(SupplierAccounts.dayText(Date())).pdf")
                } label: {
                    Label("Sales report (PDF)", systemImage: "doc.richtext")
                }
            }
            if let exported {
                ShareLink(item: exported) {
                    Label("Share the spreadsheet", systemImage: "square.and.arrow.up")
                }
            } else {
                Button {
                    exported = AppFiles.write(Data(("\u{FEFF}" + SalesReports.csv(shown)).utf8), folder: "Exports", name: "Sales \(SupplierAccounts.dayText(Date())).csv")
                } label: {
                    Label("Sales spreadsheet (CSV)", systemImage: "tablecells")
                }
            }
        } header: {
            Text("Best sellers and more")
        }
    }

    @ViewBuilder
    private func salesSection(_ shown: [Sale]) -> some View {
        Section("Sales") {
            if shown.isEmpty {
                Text("No sales yet.").foregroundStyle(.secondary)
            }
            ForEach(shown.prefix(200)) { sale in
                Button {
                    opened = sale
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(heading(sale))
                                .font(.subheadline.weight(.semibold))
                            Text(detail(sale))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Money.format(sale.total))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(sale.total < 0 ? .red : .primary)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private func heading(_ sale: Sale) -> String {
        let number = till.number(sale)
        return sale.refundOf == nil ? String(localized: "Sale \(number)") : String(localized: "Refund \(number)")
    }

    /// "2 Nov 10:15 · Cash · Sara · refunded"
    private func detail(_ sale: Sale) -> String {
        var parts = [SalesText.time(sale.at), SalesText.paid(sale)]
        if let cashier = sale.cashier, !cashier.isEmpty { parts.append(cashier) }
        if till.isRefunded(sale) { parts.append(String(localized: "refunded")) }
        return parts.joined(separator: " · ")
    }

    /// This shop's sales in the period, or every one that matches what's searched for.
    private func visible(since: String) -> [Sale] {
        var out: [Sale] = []
        for sale in till.sales {
            if !shop.isEmpty && sale.shop != shop { continue }
            if search.isEmpty {
                if sale.at >= since { out.append(sale) }
            } else if matches(sale) {
                out.append(sale)
            }
        }
        return out
    }

    /// A receipt number, a batch, a gift card, a customer or an item.
    private func matches(_ sale: Sale) -> Bool {
        let q = TextTools.norm(search)
        guard !q.isEmpty else { return true }
        if till.number(sale).lowercased() == search.lowercased().trimmingCharacters(in: .whitespaces) { return true }
        if let name = till.customer(sale.customer)?.name, TextTools.norm(name).contains(q) { return true }
        for line in sale.lines {
            if TextTools.norm(line.name).contains(q) { return true }
            if let batch = line.batch, TextTools.norm(batch) == q { return true }
        }
        let digits = search.filter(\.isNumber)
        if digits.isEmpty { return false }
        return sale.payments.contains { $0.ref == digits }
    }

    private var since: String {
        let calendar = Calendar.current
        let start: Date
        switch period {
        case 1: start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date())) ?? Date()
        case 2: start = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        default: start = calendar.startOfDay(for: Date())
        }
        return ISO8601DateFormatter().string(from: start)
    }

    var body: some View {
        let shown = visible(since: since)
        let summary = SaleMaths.summary(shown)
        List {
            Section {
                Picker("Period", selection: $period) {
                    Text("Today").tag(0)
                    Text("7 days").tag(1)
                    Text("This month").tag(2)
                }
                .pickerStyle(.segmented)
                LabeledContent("Takings") {
                    Text(Money.format(summary.takings)).font(.title3.weight(.bold))
                }
                LabeledContent("Profit") {
                    HStack(spacing: 6) {
                        Text(Money.format(summary.profit)).fontWeight(.semibold)
                            .foregroundStyle(summary.profit < 0 ? .red : .green)
                        if let margin = summary.margin {
                            Text("(\(margin.formatted(.number.precision(.fractionLength(0))))%)").foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Net sales (without VAT)", value: Money.format(summary.net))
                LabeledContent("Cost of goods sold", value: Money.format(summary.cogs))
                if let coverage = summary.coverage, coverage < 99.95 {
                    LabeledContent("Profit covers", value: String(localized: "\(coverage.formatted())% of sales"))
                        .foregroundStyle(.orange)
                }
                LabeledContent("VAT in takings", value: Money.format(summary.vat))
                LabeledContent("Sales", value: "\(summary.sales)")
                if summary.refunds > 0 { LabeledContent("Refunds", value: "\(summary.refunds)") }
                ForEach(PaymentKind.allCases, id: \.self) { kind in
                    if let amount = summary.byPayment[kind], abs(amount) > 0.005 {
                        LabeledContent(SalesText.payment(kind), value: Money.format(amount))
                            .font(.footnote)
                    }
                }
            } footer: {
                Text(summary.unknownCost > 0
                     ? String(localized: "Profit is the price without VAT, less what the goods cost you (from your agreed prices when sold). \(summary.unknownCost) lines had no cost, so they're left out of it.")
                     : String(localized: "Profit is the price without VAT, less what the goods cost you (from your agreed prices when sold)."))
            }
            if !shown.isEmpty { breakdownSection(shown) }
            marginSection
            salesSection(shown)
        }
        .navigationTitle("Sales and profit")
        .searchable(text: $search, prompt: Text("Receipt, item, batch or customer"))
        .themedScreen()
        .onChange(of: period) { exported = nil; exportedPDF = nil }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    TillSettingsView()
                } label: {
                    Label("Till settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(item: $opened) { sale in
            SaleDetailView(sale: sale)
        }
    }
}

enum SalesText {
    static func payment(_ kind: PaymentKind) -> String {
        switch kind {
        case .cash: return String(localized: "Cash")
        case .card: return String(localized: "Card")
        case .other: return String(localized: "Other")
        case .tab: return String(localized: "On account")
        case .gift: return String(localized: "Gift card")
        case .points: return String(localized: "Points")
        case .layaway: return String(localized: "Deposits paid")
        }
    }

    /// How a refund is paid back: the way the sale was paid, or cash when it was paid more than one way.
    static func refundWay(_ sale: Sale) -> String {
        sale.payments.count == 1 ? payment(sale.payments[0].kind) : payment(.cash)
    }

    /// "Cash", or "Gift card + Cash" for a sale paid more than one way.
    static func paid(_ sale: Sale) -> String {
        let kinds = sale.payments.map(\.kind)
        var seen: [PaymentKind] = []
        for kind in kinds where !seen.contains(kind) { seen.append(kind) }
        return seen.map(payment).joined(separator: " + ")
    }

    static func time(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

/// One sale: its receipt, and a refund.
struct SaleDetailView: View {
    let sale: Sale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @ObservedObject private var till = TillStore.shared
    @State private var confirmRefund = false
    @State private var refunded: Sale?
    @State private var choosing = false
    @State private var picked: [String: Double] = [:]
    @State private var approval: ApprovalRequest?
    @State private var refundBy: String?
    /// The money goes on the customer's account as store credit.
    @State private var toCredit = false

    private var text: String { TillReceipt.text(sale) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(text)
                        .font(.system(.footnote, design: .monospaced))
                }
                Section {
                    ReceiptButtons(sale: sale, text: text)
                    // card payments on a separate card machine: who confirmed them (the till couldn't check them)
                    ForEach(Array(sale.payments.enumerated()).filter { $0.element.isManualCard && $0.element.confirmedBy != nil },
                            id: \.offset) { _, card in
                        VStack(alignment: .leading, spacing: 2) {
                            LabeledContent(card.terminal ?? String(localized: "Card machine"), value: Money.format(card.amount))
                            Text(String(localized: "Confirmed by \(card.confirmedBy ?? "")") + (card.ref.map { " · " + $0 } ?? ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("Not checked by the till: confirm it against the card machine's end-of-day total.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    if let approved = sale.approvedBy {
                        LabeledContent("Allowed by", value: approved)
                    }
                    if sale.refundOf == nil && !CloudTeam.shared.isStaff {
                        if till.isRefunded(sale) {
                            Label("Refunded", systemImage: "checkmark")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Refund everything left", role: .destructive) {
                                Gate.check(.refund, String(localized: "Refund sale \(till.number(sale))"), request: $approval) { by in
                                    refundBy = by
                                    confirmRefund = true
                                }
                            }
                            if sale.lines.count > 1 || (sale.lines.first?.qty ?? 0) > 1 {
                                Button("Refund some items") {
                                    Gate.check(.refund, String(localized: "Refund sale \(till.number(sale))"), request: $approval) { by in
                                        refundBy = by
                                        picked = [:]
                                        choosing = true
                                    }
                                }
                            }
                        }
                    }
                }
                if choosing {
                    let left = till.refundable(sale)
                    Section {
                        ForEach(sale.lines.filter { (left[$0.id] ?? 0) > 0 }) { line in
                            Stepper(value: Binding(get: { picked[line.id] ?? 0 }, set: { picked[line.id] = $0 }),
                                    in: 0...(left[line.id] ?? 0)) {
                                LabeledContent(line.name, value: "\((picked[line.id] ?? 0).formatted()) / \((left[line.id] ?? 0).formatted())")
                            }
                        }
                        if let name = till.customer(sale.customer)?.name {
                            Toggle(String(localized: "As store credit for \(name)"), isOn: $toCredit)
                        }
                        Button("Refund these", role: .destructive) {
                            refunded = till.refund(sale, quantities: picked, approvedBy: refundBy, toCredit: toCredit, context: context)
                            choosing = false
                        }
                        .disabled(!picked.values.contains { $0 > 0 })
                    } header: {
                        Text("What's coming back?")
                    }
                }
            }
            .navigationTitle(sale.refundOf == nil ? String(localized: "Sale \(till.number(sale))") : String(localized: "Refund \(till.number(sale))"))
            .navigationBarTitleDisplayMode(.inline)
            .themedScreen()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Refund \(Money.format(sale.total))?", isPresented: $confirmRefund, titleVisibility: .visible) {
                Button("Refund", role: .destructive) { refunded = till.refund(sale, quantities: nil, approvedBy: refundBy, toCredit: false, context: context) }
                if let name = till.customer(sale.customer)?.name {
                    Button(String(localized: "Refund as store credit for \(name)")) {
                        refunded = till.refund(sale, quantities: nil, approvedBy: refundBy, toCredit: true, context: context)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Give the money back by \(SalesText.refundWay(sale).lowercased()). The items go back into stock.")
            }
            .managerApproval($approval)
            .sheet(item: $refunded) { refund in
                ReceiptSheet(sale: refund)
            }
        }
    }
}

/// Till › Stock: what's on the shelf, worked out from your last count, deliveries on checked invoices and sales.
struct StockView: View {
    @Query(sort: \StoredPrice.name) private var prices: [StoredPrice]
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @AppStorage(Shops.listKey) private var shopData = Data()
    @ObservedObject private var till = TillStore.shared
    @State private var chosen: String?
    @State private var counting: StockLevel?
    @State private var countText = ""
    @State private var notice: String?
    @State private var adding: StockLevel?
    @State private var addText = ""
    @State private var moving: String?
    /// The item whose movements are shown (touch and hold a row).
    @State private var history: StockLevel?
    @State private var arriving: StockTransfer?
    @State private var arrivedText = ""
    @State private var stocktaking = false

    /// Stock sent between shops that hasn't arrived yet: here, the ones coming in can be received.
    @ViewBuilder
    private func transitSection(shop: String, items: [PriceItem]) -> some View {
        let coming = till.transfers.filter { $0.inTransit && $0.to == shop }
        let going = till.transfers.filter { $0.inTransit && $0.from == shop }
        if !coming.isEmpty || !going.isEmpty {
            Section {
                ForEach(coming) { t in
                    Button {
                        arriving = t
                        arrivedText = t.units.formatted()
                    } label: {
                        LabeledContent(t.name, value: String(localized: "\(t.units.formatted()) from \(Shops.reportName(t.from))"))
                    }
                    .foregroundStyle(.primary)
                }
                ForEach(going) { t in
                    LabeledContent(t.name, value: String(localized: "\(t.units.formatted()) to \(Shops.reportName(t.to))"))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("On the way")
            } footer: {
                Text("Tap one when it arrives and enter what actually came.")
            }
            .alert("It arrived", isPresented: Binding(get: { arriving != nil }, set: { if !$0 { arriving = nil } }), presenting: arriving) { t in
                TextField("0", text: $arrivedText).keyboardType(.decimalPad)
                Button("Save") {
                    if let units = Double(arrivedText.replacingOccurrences(of: ",", with: ".")),
                       let item = items.first(where: { $0.id == t.itemID }) {
                        till.receive(t, units: units, item: item, invoices: reports.compactMap { $0.entry })
                    }
                    arriving = nil
                }
                Button("Cancel", role: .cancel) { arriving = nil }
            } message: { t in
                Text(String(localized: "\(t.units.formatted()) were sent. How many came?"))
            }
        }
    }

    var body: some View {
        let shops = Shops.decode(shopData)
        let shop = chosen ?? TillShop.resolve(view: LiveSettings.shared.shop, shops: shops)
        List {
            if shop == nil {
                Section("Which shop?") {
                    ForEach(shops, id: \.id) { s in
                        Button(s.name) { chosen = s.id }.foregroundStyle(.primary)
                    }
                }
            } else if let shop {
                let items = prices.map { $0.item }
                let levels = till.levels(items: items, shop: shop, invoices: reports.compactMap { $0.entry })
                let low = levels.filter(\.isLow)
                let weighed = Set(items.filter(\.isByWeight).map(\.id))
                if levels.isEmpty {
                    ContentUnavailableView("No stock to show yet", systemImage: "shippingbox",
                                           description: Text("Items show here once they have a selling price or a reorder level (open an item in your price list › Sell at the till)."))
                }
                Section {
                    if items.contains(where: { $0.till?.batches == true }) {
                        NavigationLink {
                            ExpiryView()
                        } label: {
                            Label("Expiry dates", systemImage: "calendar.badge.exclamationmark")
                        }
                    }
                    if shops.count > 1 {
                        Button {
                            moving = shop
                        } label: {
                            Label("Move stock to another shop", systemImage: "arrow.left.arrow.right")
                        }
                    }
                }
                transitSection(shop: shop, items: items)
                Section {
                    Button {
                        stocktaking = true
                    } label: {
                        Label("Stocktake", systemImage: "list.clipboard")
                    }
                } footer: {
                    Text("Count many items in one go, see what's missing or extra at cost, then save the whole count.")
                }
                .sheet(isPresented: $stocktaking) {
                    StocktakeView(shop: shop, levels: levels, items: items)
                }
                if !low.isEmpty {
                    Section {
                        Button {
                            let drafts = StockMaths.reorders(low, items: items, noSupplier: String(localized: "No supplier set"))
                            for draft in drafts { OrderStore.shared.addToDraft(supplier: draft.supplier, shop: shop, lines: draft.lines) }
                            notice = drafts.count == 1 ? String(localized: "An order for \(drafts[0].supplier) is ready in Suppliers › Orders.")
                                                       : String(localized: "Orders for \(drafts.count) suppliers are ready in Suppliers › Orders.")
                        } label: {
                            Label(low.count == 1 ? String(localized: "Order the 1 item running low") : String(localized: "Order the \(low.count) items running low"),
                                  systemImage: "cart.badge.plus")
                        }
                        if let notice { Text(notice).font(.footnote).foregroundStyle(.green) }
                    }
                }
                Section {
                    ForEach(levels) { level in
                        Button {
                            counting = level
                            countText = level.onHand.formatted()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(level.name).font(.subheadline.weight(.semibold))
                                    Text(level.counted ? String(localized: "\(level.delivered.formatted()) in · \(level.sold.formatted()) sold since the last count")
                                                       : String(localized: "Not counted yet: tap to count"))
                                        .font(.caption)
                                        .foregroundStyle(level.counted ? Color.secondary : Color.orange)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(level.onHand.formatted() + (weighed.contains(level.itemID) ? " kg" : ""))
                                        .font(.headline)
                                        .monospacedDigit()
                                        .foregroundStyle(level.onHand < 0 ? .red : (level.isLow ? .orange : .primary))
                                    if let at = level.low {
                                        Text("reorder at \(at.formatted())").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .contextMenu {
                            Button {
                                history = level
                            } label: {
                                Label("Movements", systemImage: "list.bullet.rectangle")
                            }
                        }
                        .sheet(isPresented: Binding(get: { history?.itemID == level.itemID },
                                                    set: { if !$0 { history = nil } })) {
                            if let item = items.first(where: { $0.id == level.itemID }) {
                                StockMovementsView(item: item, shop: shop, invoices: reports.compactMap { $0.entry })
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                adding = level
                                addText = ""
                            } label: {
                                Label("Stock in", systemImage: "plus")
                            }
                            .tint(.green)
                        }
                    }
                } footer: {
                    if !levels.isEmpty {
                        Text("In single units. Stock = your last count + deliveries ticked off on checked invoices − sales. Below zero means it needs counting. Tap to count; swipe right to add stock that came without an invoice.")
                    }
                }
            }
        }
        .navigationTitle("Stock")
        .themedScreen()
        .sheet(item: Binding(get: { moving.map { MovingFrom(shop: $0) } }, set: { if $0 == nil { moving = nil } })) { from in
            MoveStockSheet(items: prices.map { $0.item }.filter { $0.till?.sell != nil || $0.till?.low != nil }, from: from.shop)
        }
        .alert("Stock came in", isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } }), presenting: adding) { level in
            TextField("0", text: $addText).keyboardType(.decimalPad)
            Button("Add") {
                if let value = Double(addText.replacingOccurrences(of: ",", with: ".")), value > 0, let shop {
                    till.addStock(value, level: level, shop: shop)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { level in
            Text("How many \(level.name) came in without a checked invoice, in single units?")
        }
        .alert("Count on the shelf", isPresented: Binding(get: { counting != nil }, set: { if !$0 { counting = nil } }), presenting: counting) { level in
            TextField("0", text: $countText).keyboardType(.decimalPad)
            Button("Save") {
                if let value = Double(countText.replacingOccurrences(of: ",", with: ".")), value >= 0, let shop {
                    till.setCount(value, itemID: level.itemID, name: level.name, shop: shop)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { level in
            Text("How many \(level.name) are there now, in single units?")
        }
    }
}

struct MovingFrom: Identifiable {
    let shop: String
    var id: String { shop }
}


/// Every stock change of one item since its last count, from the invoices, sales and refunds themselves: the
/// figure on the stock screen, explained line by line.
struct StockMovementsView: View {
    let item: PriceItem
    let shop: String
    let invoices: [HistoryEntry]
    @ObservedObject private var till = TillStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let moves = InventoryLedger.movements(item: item, shop: shop, invoices: invoices, sales: till.sales, counts: till.counts)
        NavigationStack {
            List {
                Section {
                    ForEach(moves) { move in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(move)).font(.subheadline.weight(.semibold))
                                Text(String(move.at.prefix(16)).replacingOccurrences(of: "T", with: " ")
                                     + (move.source.isEmpty ? "" : " · " + move.source))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(move.kind == .counted ? move.qty.formatted() : (move.qty > 0 ? "+" : "") + move.qty.formatted())
                                .font(.headline)
                                .monospacedDigit()
                                .foregroundStyle(move.kind == .counted ? Color.primary : (move.qty < 0 ? Color.red : Color.green))
                        }
                    }
                } footer: {
                    Text(String(localized: "On hand: \(InventoryLedger.onHand(moves).formatted())"))
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func title(_ move: StockMovement) -> String {
        switch move.kind {
        case .counted: return String(localized: "Counted")
        case .delivered: return String(localized: "Delivered")
        case .sold: return String(localized: "Sold")
        case .refunded: return String(localized: "Refunded")
        }
    }
}


/// Counting many items in one go: what the till expects, what's counted, the difference at cost, saved together.
struct StocktakeView: View {
    let shop: String
    let levels: [StockLevel]
    let items: [PriceItem]
    @ObservedObject private var till = TillStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var take: Stocktake?
    @State private var texts: [String: String] = [:]

    var body: some View {
        let costs = Dictionary(items.map { ($0.id, $0.isTillOnly ? $0.price : $0.unitCost(shop: shop)) }, uniquingKeysWith: { a, _ in a })
        let current = currentTake
        NavigationStack {
            List {
                Section {
                    LabeledContent("Counted", value: "\(current.counted.count) / \(levels.count)")
                    let net = current.netValue(cost: { costs[$0] ?? 0 })
                    LabeledContent("Difference at cost", value: Money.format(net))
                        .foregroundStyle(net < -0.005 ? .red : (net > 0.005 ? .green : .primary))
                }
                Section {
                    ForEach(levels) { level in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(level.name).font(.subheadline.weight(.semibold))
                                Text(String(localized: "Expected \(level.onHand.formatted())")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            TextField("—", text: Binding(get: { texts[level.itemID] ?? "" }, set: { texts[level.itemID] = $0 }))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    Text("Leave an item empty to keep its current count.")
                }
            }
            .navigationTitle("Stocktake")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save count") {
                        till.commit(current, names: Dictionary(levels.map { ($0.itemID, $0.name) }, uniquingKeysWith: { a, _ in a }))
                        dismiss()
                    }
                    .disabled(current.counted.isEmpty)
                }
            }
            .onAppear {
                if take == nil {
                    take = Stocktake(shop: shop, startedAt: ISO8601DateFormatter().string(from: Date()),
                                     expected: Dictionary(levels.map { ($0.itemID, $0.onHand) }, uniquingKeysWith: { a, _ in a }))
                }
            }
        }
    }

    /// The stocktake with what's typed so far.
    private var currentTake: Stocktake {
        var t = take ?? Stocktake(shop: shop, startedAt: "", expected: [:])
        t.counted = texts.compactMapValues { Double($0.replacingOccurrences(of: ",", with: ".")) }.filter { $0.value >= 0 }
        return t
    }
}
