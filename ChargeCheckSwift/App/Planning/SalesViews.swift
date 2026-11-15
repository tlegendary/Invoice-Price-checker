import SwiftUI
import SwiftData
import ChargeCheckCore

/// Till › Sales and profit: a day's (or week's, month's) takings, profit and every sale, with refunds.
struct SalesView: View {
    @ObservedObject private var till = TillStore.shared
    @AppStorage(Shops.listKey) private var shopData = Data()
    @State private var period = 0
    @State private var opened: Sale?

    private var shop: String { LiveSettings.shared.shop }

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
        let shown = till.sales.filter { $0.at >= since && (shop.isEmpty || $0.shop == shop) }
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
                                Text(sale.refundOf == nil ? String(localized: "Sale \(sale.number)") : String(localized: "Refund \(sale.number)"))
                                    .font(.subheadline.weight(.semibold))
                                Text(SalesText.time(sale.at) + " · " + SalesText.payment(sale.payment) + (till.isRefunded(sale) ? " · " + String(localized: "refunded") : ""))
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
        .navigationTitle("Sales and profit")
        .themedScreen()
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
        }
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

    private var text: String { SaleMaths.receipt(sale, shopName: Shops.reportName(sale.shop), currency: Money.currency.code) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(text)
                        .font(.system(.footnote, design: .monospaced))
                }
                Section {
                    ShareLink(item: text) {
                        Label("Send receipt", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        Printing.printText(text, title: String(localized: "Receipt"))
                    } label: {
                        Label("Print", systemImage: "printer")
                    }
                    if sale.refundOf == nil && !CloudTeam.shared.isStaff {
                        if till.isRefunded(sale) {
                            Label("Refunded", systemImage: "checkmark")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Refund this sale", role: .destructive) { confirmRefund = true }
                        }
                    }
                }
            }
            .navigationTitle(sale.refundOf == nil ? String(localized: "Sale \(sale.number)") : String(localized: "Refund \(sale.number)"))
            .navigationBarTitleDisplayMode(.inline)
            .themedScreen()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Refund \(Money.format(sale.total))?", isPresented: $confirmRefund, titleVisibility: .visible) {
                Button("Refund", role: .destructive) { refunded = till.refund(sale, context: context) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Give the money back by \(SalesText.payment(sale.payment).lowercased()). The items go back into stock.")
            }
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
                if levels.isEmpty {
                    ContentUnavailableView("No stock to show yet", systemImage: "shippingbox",
                                           description: Text("Items show here once they have a selling price or a reorder level (open an item in your price list › Sell at the till)."))
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
                                    Text(level.onHand.formatted())
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
                    }
                } footer: {
                    if !levels.isEmpty {
                        Text("In single units. Stock = your last count + deliveries ticked off on checked invoices − sales. Below zero means it needs counting.")
                    }
                }
            }
        }
        .navigationTitle("Stock")
        .themedScreen()
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
