import SwiftUI
import SwiftData
import ChargeCheckCore

/// Which shop the till sells for: the shop chosen at the top of the app, the only shop, or nil when one must be picked.
enum TillShop {
    static func resolve(view: String, shops: [ShopInfo]) -> String? {
        if !view.isEmpty { return view }
        if shops.isEmpty { return "" }
        return shops.count == 1 ? shops[0].id : nil
    }
}

struct BasketLine: Identifiable, Equatable {
    let id = UUID().uuidString
    var itemID: String?
    var name: String
    var qty: Double
    var price: Double
    var vat: Double
    var cost: Double?

    var sale: SaleLine { SaleLine(itemID: itemID, name: name, qty: qty, price: price, vat: vat, cost: cost) }
    var total: Double { Money.round2(qty * price) }
}

/// The till (full screen): tap or scan items into the basket, take payment, give a receipt.
/// Every sale takes the items off the shop's stock; anything that runs low gets an order drafted for its supplier.
struct TillView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredPrice.name) private var prices: [StoredPrice]
    @AppStorage(Shops.listKey) private var shopData = Data()
    @ObservedObject private var till = TillStore.shared

    @State private var shop: String?
    @State private var basket: [BasketLine] = []
    @State private var search = ""
    @State private var scanning = false
    @State private var paying = false
    @State private var done: Sale?
    @State private var pricing: PriceItem?
    @State private var priceText = ""
    @State private var unknownCode: String?
    @State private var customAmount = false
    @State private var customText = ""
    @State private var notice: String?

    private var shops: [ShopInfo] { Shops.decode(shopData) }
    private var items: [PriceItem] { prices.map { $0.item }.filter { $0.isIn(shop: shop ?? "") } }
    private var total: Double { Money.round2(basket.reduce(0) { $0 + $1.total }) }

    /// Most sold in the last 30 days first, then by name: the items to tap.
    private var quick: [PriceItem] {
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 86_400))
        var sold: [String: Double] = [:]
        for sale in till.sales where sale.at > since && sale.shop == (shop ?? "") {
            for line in sale.lines { if let id = line.itemID { sold[id, default: 0] += line.qty } }
        }
        return items.filter { ($0.till?.sell ?? 0) > 0 }
            .sorted { (sold[$0.id] ?? 0, $1.name.lowercased()) > (sold[$1.id] ?? 0, $0.name.lowercased()) }
    }

    private var found: [PriceItem] {
        let query = TextTools.norm(search)
        guard !query.isEmpty else { return [] }
        return items.filter { item in
            TextTools.norm(item.name + " " + item.aliases.joined(separator: " ")).contains(query) || item.hasBarcode(search)
        }.prefix(40).map { $0 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if shop == nil {
                    shopChoice
                } else {
                    VStack(spacing: 0) {
                        catalogue
                        basketPanel
                    }
                }
            }
            .navigationTitle(shop.map { Shops.reportName($0) } ?? String(localized: "Till"))
            .navigationBarTitleDisplayMode(.inline)
            .themedScreen()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if shop != nil && shops.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ForEach(shops, id: \.id) { s in
                                Button(s.name) {
                                    shop = s.id
                                    basket = []
                                }
                            }
                        } label: {
                            Label("Shop", systemImage: "storefront")
                        }
                        .disabled(!basket.isEmpty)
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Find an item or type a barcode"))
            .onSubmit(of: .search) {
                if let item = items.first(where: { $0.hasBarcode(search) }) {
                    add(item)
                    search = ""
                }
            }
            .onAppear { if shop == nil { shop = TillShop.resolve(view: LiveSettings.shared.shop, shops: shops) } }
            .sheet(isPresented: $scanning) {
                BarcodeScanner { code in
                    scanning = false
                    scanned(code)
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $paying) {
                PaySheet(total: total) { payment, tendered in
                    paying = false
                    let sale = till.record(lines: basket.map(\.sale), shop: shop ?? "", payment: payment, tendered: tendered, context: context)
                    basket = []
                    done = sale
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $done) { sale in
                ReceiptSheet(sale: sale)
            }
            .sheet(item: Binding(get: { unknownCode.map { CodeLink(code: $0) } }, set: { if $0 == nil { unknownCode = nil } })) { link in
                ItemPicker(items: items) { item in
                    var changed = item
                    var info = changed.till ?? TillInfo()
                    info.barcodes = (info.barcodes ?? []) + [link.code]
                    changed.till = info
                    AppData.save(changed, in: context, logged: false)
                    try? context.save()
                    add(changed)
                }
            }
            .alert("Selling price", isPresented: Binding(get: { pricing != nil }, set: { if !$0 { pricing = nil } }), presenting: pricing) { item in
                TextField(Money.format(0), text: $priceText)
                    .keyboardType(.decimalPad)
                Button("Add") {
                    guard let value = Money.parse(priceText), value > 0 else { return }
                    var changed = item
                    var info = changed.till ?? TillInfo()
                    info.sell = Money.round2(value)
                    changed.till = info
                    AppData.save(changed, in: context, logged: false)
                    try? context.save()
                    add(changed)
                    priceText = ""
                }
                Button("Cancel", role: .cancel) { priceText = "" }
            } message: { item in
                Text("\(item.name) has no selling price yet. It's kept for next time.")
            }
            .alert("Another amount", isPresented: $customAmount) {
                TextField(Money.format(0), text: $customText)
                    .keyboardType(.decimalPad)
                Button("Add") {
                    if let value = Money.parse(customText), value > 0 {
                        basket.append(BasketLine(itemID: nil, name: String(localized: "Other"), qty: 1, price: Money.round2(value), vat: 0, cost: nil))
                    }
                    customText = ""
                }
                Button("Cancel", role: .cancel) { customText = "" }
            } message: {
                Text("For something not in your price list. It isn't counted in stock or profit.")
            }
        }
    }

    private struct CodeLink: Identifiable { let code: String; var id: String { code } }

    // MARK: pieces

    private var shopChoice: some View {
        List {
            Section {
                ForEach(shops, id: \.id) { s in
                    Button(s.name) { shop = s.id }
                        .foregroundStyle(.primary)
                }
            } header: {
                Text("Which shop is this till in?")
            }
        }
    }

    @ViewBuilder
    private var catalogue: some View {
        if !search.isEmpty {
            List(found) { item in
                Button {
                    add(item)
                    search = ""
                } label: {
                    LabeledContent(item.name) {
                        if let sell = item.till?.sell, sell > 0 {
                            Text(Money.format(sell)).monospacedDigit()
                        } else {
                            Text("Set a price").foregroundStyle(.orange)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .listStyle(.plain)
            .overlay {
                if found.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        } else if quick.isEmpty {
            ContentUnavailableView {
                Label("Nothing to sell yet", systemImage: "cart")
            } description: {
                Text("Give items a selling price in your price list (open an item › Sell at the till), or search for one above and set its price here.")
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                    ForEach(quick) { item in
                        Button {
                            add(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Text(Money.format(item.till?.sell ?? 0))
                                    .font(.subheadline.weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.accentColor)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("\(item.name), \(Money.format(item.till?.sell ?? 0))"))
                    }
                }
                .padding(12)
            }
        }
    }

    private var basketPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if BarcodeScanner.canScan {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan", systemImage: "barcode.viewfinder")
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    customAmount = true
                } label: {
                    Label("Amount", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                Spacer()
                if !basket.isEmpty {
                    Button("Clear", role: .destructive) { basket = [] }
                }
            }
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(.orange)
            }
            if !basket.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($basket) { $line in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.name).font(.subheadline).lineLimit(1)
                                    Text(Money.format(line.price)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    if line.qty <= 1 { basket.removeAll { $0.id == line.id } } else { line.qty -= 1 }
                                } label: {
                                    Image(systemName: line.qty <= 1 ? "trash.circle" : "minus.circle")
                                }
                                .accessibilityLabel(Text("One less"))
                                Text(line.qty.formatted())
                                    .monospacedDigit()
                                    .frame(minWidth: 24)
                                Button {
                                    line.qty += 1
                                } label: {
                                    Image(systemName: "plus.circle")
                                }
                                .accessibilityLabel(Text("One more"))
                                Text(Money.format(line.total))
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .frame(minWidth: 70, alignment: .trailing)
                            }
                            .font(.title3)
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
            Button {
                paying = true
            } label: {
                HStack {
                    Text(basket.isEmpty ? String(localized: "Pay") : String(localized: "Pay \(Money.format(total))"))
                        .font(.headline)
                    Spacer()
                    Text(basket.reduce(0) { $0 + $1.qty }.formatted() + " " + String(localized: "items"))
                        .font(.subheadline)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(basket.isEmpty || total <= 0)
        }
        .padding(12)
        .background(.bar)
    }

    // MARK: actions

    private func add(_ item: PriceItem) {
        notice = nil
        guard let sell = item.till?.sell, sell > 0 else {
            pricing = item
            return
        }
        if let index = basket.firstIndex(where: { $0.itemID == item.id }) {
            basket[index].qty += 1
        } else {
            let cost = item.price > 0 ? item.unitCost(shop: shop ?? "") : nil
            basket.append(BasketLine(itemID: item.id, name: item.name, qty: 1, price: sell, vat: item.till?.vat ?? 0,
                                     cost: cost.map { (($0 * 10_000).rounded()) / 10_000 }))
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func scanned(_ code: String) {
        if let item = items.first(where: { $0.hasBarcode(code) }) {
            add(item)
        } else {
            unknownCode = code
        }
    }
}

/// Take the money: cash (with change), card on your own card machine, or other.
struct PaySheet: View {
    let total: Double
    let onPaid: (PaymentKind, Double?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: PaymentKind = .cash
    @State private var given = ""

    private var tendered: Double? { Money.parse(given) }

    /// Exact, then the next notes up.
    private var quick: [Double] {
        let notes: [Double] = [5, 10, 20, 50]
        return [total] + notes.filter { $0 > total }.prefix(3)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(Money.format(total))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                    Picker("Paid by", selection: $kind) {
                        Text("Cash").tag(PaymentKind.cash)
                        Text("Card").tag(PaymentKind.card)
                        Text("Other").tag(PaymentKind.other)
                    }
                    .pickerStyle(.segmented)
                }
                if kind == .cash {
                    Section("Cash given") {
                        HStack {
                            ForEach(quick, id: \.self) { amount in
                                Button(amount == total ? String(localized: "Exact") : Money.format(amount)) {
                                    given = String(format: "%.2f", amount)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        TextField(Money.format(0), text: $given)
                            .keyboardType(.decimalPad)
                        if let tendered, tendered >= total {
                            LabeledContent("Change to give") {
                                Text(Money.format(SaleMaths.change(tendered: tendered, total: total)))
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                } else if kind == .card {
                    Section {
                        Text("Take the card on your card machine, then tap Done. Taking cards on this iPhone itself needs a card payment account, which isn't set up yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onPaid(kind, kind == .cash ? (tendered ?? total) : nil) }
                        .fontWeight(.bold)
                        .disabled(kind == .cash && (tendered ?? total) < total - 0.001)
                }
            }
        }
    }
}

/// After the sale: change to give, and a receipt to send or print.
struct ReceiptSheet: View {
    let sale: Sale
    @Environment(\.dismiss) private var dismiss

    private var text: String { SaleMaths.receipt(sale, shopName: Shops.reportName(sale.shop), currency: Money.currency.code) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: sale.refundOf == nil ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text(sale.refundOf == nil ? String(localized: "Sale \(sale.number) done") : String(localized: "Refund \(sale.number) done"))
                    .font(.title2.weight(.bold))
                if sale.payment == .cash, let tendered = sale.tendered, tendered > sale.total + 0.001 {
                    Text("Change: \(Money.format(SaleMaths.change(tendered: tendered, total: sale.total)))")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.green)
                }
                ScrollView {
                    Text(text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                HStack {
                    ShareLink(item: text) {
                        Label("Send receipt", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        Printing.printText(text, title: String(localized: "Receipt"))
                    } label: {
                        Label("Print", systemImage: "printer")
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    dismiss()
                } label: {
                    Text("Next sale").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// AirPrint for a plain text receipt.
enum Printing {
    @MainActor
    static func printText(_ text: String, title: String) {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .grayscale
        info.jobName = title
        controller.printInfo = info
        let formatter = UISimpleTextPrintFormatter(text: text)
        formatter.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        formatter.perPageContentInsets = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        controller.printFormatter = formatter
        controller.present(animated: true)
    }
}
