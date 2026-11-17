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

/// A line in the basket before it's paid.
struct BasketLine: Identifiable, Equatable {
    var id = UUID().uuidString
    var itemID: String?
    var name: String
    /// How many; for a weighed line, kg.
    var qty: Double
    /// Price of one of these (a single, a whole pack, or 1 kg).
    var price: Double
    var vat: Double
    /// Cost of one of these, before VAT.
    var cost: Double?
    /// Stock units in one of these (1, or the pack size).
    var units: Double = 1
    /// Money off typed at the till, for the whole line.
    var manualOff: Double = 0
    /// Multi-buy for single units: (qty, price).
    var offerQty: Double?
    var offerPrice: Double?
    var weighed = false
    var batch: String?
    var giftCard: String?
    /// The item's category, for meal deals.
    var category = ""
    /// Worked out from the whole basket: money off from meal deals, and how many of the line they used.
    var dealOff: Double = 0
    var dealUnits: Double = 0
    var dealName: String?

    var offerOff: Double {
        guard units == 1, !weighed, let q = offerQty, let p = offerPrice else { return 0 }
        return SaleMaths.offerDiscount(qty: max(0, qty - dealUnits), price: price, offer: (q, p))
    }
    var discount: Double { Money.round2(min(qty * price, manualOff + offerOff + dealOff)) }
    var total: Double { Money.round2(qty * price - discount) }
    /// Can be counted up and down with + and −.
    var countable: Bool { !weighed && giftCard == nil }

    var sale: SaleLine {
        SaleLine(itemID: itemID, name: name, qty: qty, price: price, vat: vat, cost: cost, units: units == 1 ? nil : units,
                 discount: discount > 0 ? discount : nil, weighed: weighed ? true : nil, batch: batch, giftCard: giftCard,
                 deal: dealOff > 0 ? dealName : nil)
    }
}

/// The till (full screen): tap or scan items into the basket, take payment, give a receipt.
/// Every sale takes the items off the shop's stock; anything that runs low gets an order drafted for its supplier.
struct TillView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @Query(sort: \StoredPrice.name) private var prices: [StoredPrice]
    @AppStorage(Shops.listKey) private var shopData = Data()
    @ObservedObject private var till = TillStore.shared
    @ObservedObject private var printer = ReceiptPrinter.shared
    @ObservedObject private var screen = CustomerScreenLink.shared

    @State private var shop: String?
    @State private var basket: [BasketLine] = []
    @State private var basketOff = 0.0
    @State private var customer: Customer?
    @State private var approvedBy: [String] = []
    @State private var category: String?
    @State private var search = ""
    @State private var scanning = false
    @State private var paying = false
    @State private var done: Sale?
    @State private var pricing: PriceItem?
    @State private var priceText = ""
    @State private var unknownCode: String?
    @State private var customAmount = false
    @State private var customText = ""
    @State private var editingLine: BasketLine?
    @State private var discounting = false
    @State private var parking = false
    @State private var parkName = ""
    @State private var recalling = false
    @State private var ageItem: AgeCheck?
    @State private var ageChecked: Set<String> = []
    @State private var expired: ExpiredPick?
    @State private var weighing: PriceItem?
    @State private var cashSheet: CashKind?
    @State private var showDay = false
    @State private var showSettings = false
    @State private var choosingCustomer = false
    @State private var sellingGift = false
    @State private var giftText = ""
    @State private var showCustomer = false
    @State private var approval: ApprovalRequest?
    /// Every half minute: the other tills' sales and stock.
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var shops: [ShopInfo] { Shops.decode(shopData) }
    private var items: [PriceItem] { prices.map { $0.item }.filter { $0.isIn(shop: shop ?? "") } }

    /// The basket with meal deals worked out.
    private var priced: [BasketLine] {
        let deals = till.options.deals.filter { $0.isOn(shop: shop ?? "") }
        guard !deals.isEmpty else { return basket }
        let input = basket.compactMap { line -> DealLine? in
            guard let id = line.itemID, line.countable, line.units == 1, line.qty >= 1 else { return nil }
            return DealLine(key: line.id, itemID: id, category: line.category, price: line.price, qty: Int(line.qty.rounded(.down)))
        }
        let result = DealMaths.apply(input, deals: deals)
        return basket.map { line in
            var out = line
            out.dealOff = result.off[line.id] ?? 0
            out.dealUnits = Double(result.used[line.id] ?? 0)
            out.dealName = result.dealName[line.id]
            return out
        }
    }
    private var subtotal: Double { Money.round2(priced.reduce(0) { $0 + $1.total }) }
    private var total: Double { Money.round2(max(0, subtotal - basketOff)) }

    /// Most sold in the last 30 days first, then by name: the items to tap.
    private var sellable: [PriceItem] {
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 86_400))
        var sold: [String: Double] = [:]
        for sale in till.sales where sale.at > since && sale.shop == (shop ?? "") {
            for line in sale.lines { if let id = line.itemID { sold[id, default: 0] += line.stockUnits } }
        }
        return items.filter { ($0.till?.sell ?? 0) > 0 || ($0.till?.packSell ?? 0) > 0 }
            .sorted { (sold[$0.id] ?? 0, $1.name.lowercased()) > (sold[$1.id] ?? 0, $0.name.lowercased()) }
    }

    private var categories: [String] {
        Array(Set(sellable.map { $0.cat.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
    }

    private var tiles: [PriceItem] {
        guard let category else { return sellable }
        return sellable.filter { $0.cat.trimmingCharacters(in: .whitespaces) == category }
    }

    private var found: [PriceItem] {
        let query = TextTools.norm(search)
        guard !query.isEmpty else { return [] }
        return items.filter { item in
            TextTools.norm(item.name + " " + item.aliases.joined(separator: " ")).contains(query) || item.hasBarcode(search)
        }.prefix(40).map { $0 }
    }

    private var locked: Bool { !till.cashiers.isEmpty && till.cashier == nil }

    struct AgeCheck: Identifiable {
        let item: PriceItem
        let pack: Bool
        var id: String { item.id }
    }

    struct ExpiredPick: Identifiable {
        let item: PriceItem
        let pack: Bool
        let kg: Double?
        let batch: BatchOnShelf
        var id: String { item.id }
    }

    struct CashKind: Identifiable {
        let kind: CashEvent.Kind
        var id: String { kind.rawValue }
    }

    private struct CodeLink: Identifiable {
        let code: String
        var id: String { code }
    }

    var body: some View {
        NavigationStack {
            attach(screenBody)
        }
    }

    private var screenBody: some View {
        Group {
            if locked {
                PinPad(title: String(localized: "Who's serving?")) { pin in till.signIn(pin: pin) }
            } else if shop == nil {
                shopChoice
            } else {
                VStack(spacing: 0) {
                    if till.clash {
                        Label("Another iPhone or iPad is also till \(till.code). Give this one its own letter in Till settings › This till.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(8)
                    }
                    catalogue
                    basketPanel
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .themedScreen()
        .toolbar { toolbar }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Find an item or type a barcode"))
        .onSubmit(of: .search) {
            if lookUp(search) { search = "" }
        }
        .onAppear { if shop == nil { shop = TillShop.resolve(view: LiveSettings.shared.shop, shops: shops) } }
        .task {
            await till.sync(context: context)
            if screen.tillOffers { screen.startTill() }
        }
        .onReceive(ticker) { _ in
            Task { await till.sync(context: context) }
        }
        .onChange(of: phase) { if phase == .active { Task { await till.sync(context: context) } } }
        .onChange(of: basket) { pushScreen() }
        .onChange(of: basketOff) { pushScreen() }
    }

    private var title: String {
        let name = shop.map { Shops.reportName($0) } ?? String(localized: "Till")
        return till.severalTills ? name + " · " + String(localized: "Till \(till.code)") : name
    }

    // MARK: sheets and alerts

    private func attach<Content: View>(_ content: Content) -> some View {
        moreAlerts(alerts(sheets(content)))
            .managerApproval($approval)
    }

    private func sheets<Content: View>(_ content: Content) -> some View {
        content
            .sheet(isPresented: $scanning) {
                BarcodeScanner { code in
                    scanning = false
                    scanned(code)
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $paying) {
                PaySheet(total: total, customer: customer) { payment, tendered, split in
                    paying = false
                    finish(payment: payment, tendered: tendered, split: split)
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $done) { sale in
                ReceiptSheet(sale: sale)
            }
            .sheet(item: $editingLine) { line in
                LineSheet(line: line) { changed in changeLine(line, to: changed) }
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $discounting) {
                BasketDiscountSheet(subtotal: subtotal, current: basketOff) { basketOff = $0 }
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $recalling) {
                ParkedList(shop: shop ?? "") { parked in restore(parked) }
            }
            .sheet(item: $cashSheet) { wrapper in
                CashSheet(kind: wrapper.kind) { amount, note in
                    till.addCash(wrapper.kind, amount: amount, note: note, shop: shop ?? "", approvedBy: approvedBy.last)
                    approvedBy = basket.isEmpty ? [] : approvedBy
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showDay) {
                DayView(shop: shop ?? "")
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { TillSettingsView(done: true, preApproved: true) }
            }
            .sheet(isPresented: $choosingCustomer) {
                CustomerPicker { customer = $0 }
            }
            .sheet(item: $weighing) { item in
                WeightSheet(item: item) { kg in add(item, pack: false, kg: kg) }
                    .presentationDetents([.medium])
            }
            .fullScreenCover(isPresented: $showCustomer) {
                CustomerScreenView(joins: false)
            }
            .sheet(item: Binding(get: { unknownCode.map { CodeLink(code: $0) } }, set: { if $0 == nil { unknownCode = nil } })) { link in
                ItemPicker(items: items, onPick: { item in
                    var changed = item
                    var info = changed.till ?? TillInfo()
                    info.barcodes = (info.barcodes ?? []) + [link.code]
                    changed.till = info
                    AppData.save(changed, in: context, logged: false)
                    try? context.save()
                    add(changed, pack: false)
                }, title: String(localized: "Which item is this barcode?"))
            }
    }

    private func alerts<Content: View>(_ content: Content) -> some View {
        content
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
                    add(changed, pack: false)
                    priceText = ""
                }
                Button("Cancel", role: .cancel) { priceText = "" }
            } message: { item in
                Text(item.isByWeight ? String(localized: "\(item.name) has no price a kg yet. It's kept for next time.")
                                     : String(localized: "\(item.name) has no selling price yet. It's kept for next time."))
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
            .alert("Park this sale", isPresented: $parking) {
                TextField("Name, e.g. Ali", text: $parkName)
                Button("Park") {
                    var lines = priced.map(\.sale)
                    if basketOff > 0 { lines = SaleMaths.shareDiscount(basketOff, over: lines) }
                    till.park(lines, shop: shop ?? "", name: parkName.trimmingCharacters(in: .whitespaces).isEmpty ? (customer?.name ?? "") : parkName,
                              customer: customer?.id)
                    clear()
                    parkName = ""
                }
                Button("Cancel", role: .cancel) { parkName = "" }
            } message: {
                Text("Keep it to finish later, and serve the next customer.")
            }
    }

    private func moreAlerts<Content: View>(_ content: Content) -> some View {
        content
            .alert("Check their ID", isPresented: Binding(get: { ageItem != nil }, set: { if !$0 { ageItem = nil } }), presenting: ageItem) { pending in
                Button("ID checked: 18 or over") {
                    ageChecked.insert(pending.item.id)
                    add(pending.item, pack: pending.pack)
                }
                Button("Don't sell", role: .cancel) {}
            } message: { pending in
                Text("\(pending.item.name) is age restricted. Challenge 25: ask for ID if they look under 25.")
            }
            .alert("Out of date", isPresented: Binding(get: { expired != nil }, set: { if !$0 { expired = nil } }), presenting: expired) { pick in
                Button("It's from a newer batch: sell it") { add(pick.item, pack: pick.pack, kg: pick.kg, batchOK: true) }
                Button("Don't sell", role: .cancel) {}
            } message: { pick in
                Text("Batch \(pick.batch.batch.code) of \(pick.item.name) expired on \(pick.batch.batch.expiry). Take it off the shelf. Check the date on the one in your hand.")
            }
            .alert("Sell a gift card", isPresented: $sellingGift) {
                TextField(Money.format(0), text: $giftText)
                    .keyboardType(.decimalPad)
                Button("Add") {
                    if let value = Money.parse(giftText), value > 0 {
                        let code = till.newGiftCode()
                        basket.append(BasketLine(itemID: nil, name: String(localized: "Gift card \(code)"), qty: 1, price: Money.round2(value),
                                                 vat: 0, cost: Money.round2(value), giftCard: code))
                    }
                    giftText = ""
                }
                Button("Cancel", role: .cancel) { giftText = "" }
            } message: {
                Text("How much is it for? The card number is on the receipt: they spend it with Gift card when they pay.")
            }
    }

    // MARK: pieces

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close") { dismiss() }
        }
        if !locked && shop != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Button { cash(.float) } label: { Label("Opening float", systemImage: "tray.and.arrow.down") }
                        Button { cash(.paidIn) } label: { Label("Cash in", systemImage: "plus.circle") }
                        Button { cash(.paidOut) } label: { Label("Cash out", systemImage: "minus.circle") }
                        if printer.settings.isSet {
                            Button {
                                Gate.check(.noSale, String(localized: "Open the drawer without a sale"), request: $approval) { by in
                                    printer.openDrawer()
                                    till.addCash(.noSale, amount: 0, note: "", shop: shop ?? "", approvedBy: by)
                                }
                            } label: { Label("Open the drawer", systemImage: "tray") }
                        }
                        Button { showDay = true } label: { Label("End of day", systemImage: "lock.rectangle.stack") }
                    }
                    if till.parked.contains(where: { $0.shop == (shop ?? "") }) {
                        Button { recalling = true } label: { Label("Parked sales", systemImage: "pause.circle") }
                    }
                    Section {
                        if let person = till.cashier?.name {
                            let isIn = till.isClockedIn(person)
                            Button {
                                till.punch(person, shop: shop ?? "", start: !isIn)
                            } label: {
                                Label(isIn ? String(localized: "Clock out \(person)") : String(localized: "Clock in \(person)"), systemImage: "clock")
                            }
                        }
                        Button { showCustomer = true } label: { Label("Show the customer", systemImage: "person.crop.rectangle") }
                    }
                    if shops.count > 1 && basket.isEmpty {
                        Menu {
                            ForEach(shops, id: \.id) { s in
                                Button(s.name) { shop = s.id }
                            }
                        } label: {
                            Label("Shop", systemImage: "storefront")
                        }
                    }
                    Button {
                        Gate.check(.settings, String(localized: "Change the till settings"), request: $approval) { _ in showSettings = true }
                    } label: { Label("Till settings", systemImage: "gearshape") }
                    if let cashier = till.cashier {
                        Button(role: .destructive) {
                            till.cashier = nil
                        } label: {
                            Label(String(localized: "Sign out \(cashier.name)"), systemImage: "person.crop.circle.badge.xmark")
                        }
                    }
                } label: {
                    Label("Till menu", systemImage: "ellipsis.circle")
                }
            }
        }
    }

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
                HStack {
                    Text(item.name)
                    Spacer()
                    if let sell = item.till?.sell, sell > 0 {
                        Button(item.isByWeight ? Money.format(sell) + "/kg" : Money.format(sell)) {
                            add(item, pack: false)
                            search = ""
                        }
                        .buttonStyle(.bordered)
                    } else if (item.till?.packSell ?? 0) <= 0 {
                        Button("Set a price") { pricing = item }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                    }
                    if let pack = item.till?.packSell, pack > 0 {
                        Button(String(localized: "Pack \(Money.format(pack))")) {
                            add(item, pack: true)
                            search = ""
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if found.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        } else if sellable.isEmpty {
            ContentUnavailableView {
                Label("Nothing to sell yet", systemImage: "cart")
            } description: {
                Text("Give items a selling price in your price list (open an item › Sell at the till), import your products (Till settings › Import products), or search above and set a price here.")
            }
        } else {
            VStack(spacing: 0) {
                if categories.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip(String(localized: "All"), selected: category == nil) { category = nil }
                            ForEach(categories, id: \.self) { name in
                                chip(name, selected: category == name) { category = name }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 10)], spacing: 10) {
                        ForEach(tiles) { item in tile(item) }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func tile(_ item: PriceItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                add(item, pack: (item.till?.sell ?? 0) <= 0)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(item.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if item.till?.ageCheck == true {
                            Text("25").font(.caption2.weight(.heavy)).foregroundStyle(.red)
                                .accessibilityLabel(Text("Ask for ID"))
                        }
                        if item.isByWeight {
                            Image(systemName: "scalemass").font(.caption2).foregroundStyle(.secondary)
                                .accessibilityLabel(Text("Sold by weight"))
                        }
                    }
                    Spacer(minLength: 0)
                    if let sell = item.till?.sell, sell > 0 {
                        Text(item.isByWeight ? Money.format(sell) + "/kg" : Money.format(sell))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.accentColor)
                    }
                    if let offer = item.till?.offer {
                        Text("\(offer.qty.formatted()) for \(Money.format(offer.price))")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
            }
            .buttonStyle(.plain)
            if let pack = item.till?.packSell, pack > 0 {
                Button {
                    add(item, pack: true)
                } label: {
                    Text(String(localized: "Pack of \(item.unitsPerPack.formatted()) · \(Money.format(pack))"))
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var basketPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if BarcodeScanner.canScan {
                    Button { scanning = true } label: { Label("Scan", systemImage: "barcode.viewfinder") }
                        .buttonStyle(.bordered)
                }
                Button {
                    Gate.check(.customAmount, String(localized: "Sell something not in the list"), request: $approval) { by in
                        note(by)
                        customAmount = true
                    }
                } label: { Label("Amount", systemImage: "plus") }
                    .buttonStyle(.bordered)
                customerButton
                Spacer()
                saleMenu
            }
            if !basket.isEmpty {
                basketLines
            }
            Button {
                paying = true
            } label: {
                HStack {
                    Text(basket.isEmpty ? String(localized: "Pay") : String(localized: "Pay \(Money.format(total))"))
                        .font(.headline)
                    Spacer()
                    if let cashier = till.cashier {
                        Text(cashier.name).font(.caption)
                    }
                    Text(basket.filter(\.countable).reduce(0) { $0 + $1.qty }.formatted() + " " + String(localized: "items"))
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

    @ViewBuilder
    private var customerButton: some View {
        if let customer {
            Menu {
                if till.options.loyaltyOn {
                    Text("\(till.balance(customer).points) points")
                }
                Button("Someone else") { choosingCustomer = true }
                Button("No customer", role: .destructive) { self.customer = nil }
            } label: {
                Label(customer.name, systemImage: "person.crop.circle.fill")
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
        } else {
            Button { choosingCustomer = true } label: { Label("Customer", systemImage: "person.crop.circle") }
                .buttonStyle(.bordered)
                .labelStyle(.iconOnly)
                .accessibilityLabel(Text("Customer"))
        }
    }

    @ViewBuilder
    private var saleMenu: some View {
        Menu {
            if !basket.isEmpty {
                Button {
                    Gate.check(.discount, String(localized: "Discount on the sale"), request: $approval) { by in
                        note(by)
                        discounting = true
                    }
                } label: { Label("Discount on the sale", systemImage: "percent") }
                Button { parking = true } label: { Label("Park the sale", systemImage: "pause.circle") }
            }
            Button {
                Gate.check(.giftCard, String(localized: "Sell a gift card"), request: $approval) { by in
                    note(by)
                    sellingGift = true
                }
            } label: { Label("Sell a gift card", systemImage: "giftcard") }
            if !basket.isEmpty {
                Button(role: .destructive) {
                    Gate.check(.removeLine, String(localized: "Clear the sale"), request: $approval) { by in
                        for line in priced { Records.shared.log(.lineVoided, line.name + (by.map { " · " + $0 } ?? ""), amount: line.total) }
                        clear()
                    }
                } label: { Label("Clear the sale", systemImage: "trash") }
            }
        } label: {
            Label("Sale", systemImage: "ellipsis.circle")
        }
        .buttonStyle(.bordered)
    }

    private var basketLines: some View {
        let shown = priced
        return ScrollView {
            VStack(spacing: 6) {
                ForEach(shown) { line in
                    HStack {
                        Button {
                            editingLine = basket.first { $0.id == line.id }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.name).font(.subheadline).lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(line.weighed ? Weight.text(line.qty) + " @ " + Money.format(line.price) + "/kg" : Money.format(line.price))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if line.discount > 0 {
                                        Text("−\(Money.format(line.discount))").font(.caption.weight(.semibold)).foregroundStyle(.green)
                                    }
                                    if line.dealOff > 0, let deal = line.dealName {
                                        Text(deal).font(.caption2.weight(.semibold)).foregroundStyle(.green)
                                    }
                                    if let batch = line.batch {
                                        Text(batch).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(.primary)
                        if line.countable {
                            Button {
                                lessOf(line)
                            } label: {
                                Image(systemName: line.qty <= 1 ? "trash.circle" : "minus.circle")
                            }
                            .accessibilityLabel(Text("One less"))
                            Text(line.qty.formatted())
                                .monospacedDigit()
                                .frame(minWidth: 24)
                            Button {
                                if let index = basket.firstIndex(where: { $0.id == line.id }) { basket[index].qty += 1 }
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .accessibilityLabel(Text("One more"))
                        } else {
                            Button {
                                remove(line)
                            } label: {
                                Image(systemName: "trash.circle")
                            }
                            .accessibilityLabel(Text("Take it off the sale"))
                        }
                        Text(Money.format(line.total))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .frame(minWidth: 70, alignment: .trailing)
                    }
                    .font(.title3)
                    .buttonStyle(.borderless)
                }
                if basketOff > 0 {
                    HStack {
                        Text("Discount on the sale").font(.subheadline)
                        Spacer()
                        Text("−\(Money.format(min(basketOff, subtotal)))").font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                    }
                }
            }
        }
        .frame(maxHeight: 200)
    }

    // MARK: actions

    /// A manager allowed something on this sale.
    private func note(_ by: String?) {
        if let by, !approvedBy.contains(by) { approvedBy.append(by) }
    }

    private func cash(_ kind: CashEvent.Kind) {
        let permission: TillPermission = kind == .paidOut ? .cashOut : (kind == .float ? .float : .cashIn)
        Gate.check(permission, PermissionText.title(permission), request: $approval) { by in
            note(by)
            cashSheet = CashKind(kind: kind)
        }
    }

    private func clear() {
        basket = []
        basketOff = 0
        ageChecked = []
        customer = nil
        approvedBy = []
    }

    private func lessOf(_ line: BasketLine) {
        if line.qty <= 1 {
            remove(line)
        } else if let index = basket.firstIndex(where: { $0.id == line.id }) {
            basket[index].qty -= 1
        }
    }

    /// Taking an item off is logged (and may need a manager): it's how money goes missing at tills.
    private func remove(_ line: BasketLine) {
        Gate.check(.removeLine, String(localized: "Take \(line.name) off the sale"), request: $approval) { by in
            Records.shared.log(.lineVoided, line.name + (by.map { " · " + $0 } ?? ""), amount: line.total)
            basket.removeAll { $0.id == line.id }
        }
    }

    private func changeLine(_ line: BasketLine, to changed: BasketLine?) {
        guard let changed else {
            remove(line)
            return
        }
        var needs: [TillPermission] = []
        if abs(changed.price - line.price) > 0.0001 { needs.append(.priceChange) }
        if changed.manualOff > line.manualOff + 0.0001 { needs.append(.discount) }
        if changed.qty < line.qty - 0.0001 { needs.append(.removeLine) }
        let apply: (String?) -> Void = { by in
            note(by)
            if changed.qty < line.qty { Records.shared.log(.lineVoided, line.name + " −\((line.qty - changed.qty).formatted())" + (by.map { " · " + $0 } ?? "")) }
            if let index = basket.firstIndex(where: { $0.id == line.id }) { basket[index] = changed }
        }
        if needs.allSatisfy({ till.may($0) }) {
            apply(nil)
        } else {
            approval = ApprovalRequest(title: needs.map(PermissionText.title).joined(separator: ", ")) { name in apply(name) }
        }
    }

    /// A barcode typed or scanned: the item, or a scale label (price or weight in the code).
    @discardableResult
    private func lookUp(_ code: String) -> Bool {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let item = items.first(where: { $0.hasBarcode(clean) }) {
            add(item, pack: (item.till?.sell ?? 0) <= 0)
            return true
        }
        if let label = ScaleBarcode.read(clean, carries: till.options.scaleCarries),
           let item = items.first(where: { $0.hasBarcode(label.lookup) }) {
            if till.options.scaleCarries == .weight {
                add(item, pack: false, kg: label.value)
            } else {
                addPriced(item, amount: label.value)
            }
            return true
        }
        return false
    }

    private func scanned(_ code: String) {
        if !lookUp(code) { unknownCode = code }
    }

    /// A scale label with the price in it: charged exactly that.
    private func addPriced(_ item: PriceItem, amount: Double) {
        let info = item.till ?? TillInfo()
        let perKg = info.sell ?? 0
        let kg = perKg > 0 ? (amount / perKg * 1000).rounded() / 1000 : 1
        let unitCost = item.price > 0 ? (item.isTillOnly ? item.price : item.unitCost(shop: shop ?? "")) : nil
        let name = perKg > 0 ? item.name + " (" + Weight.text(kg) + ")" : item.name
        basket.append(BasketLine(itemID: item.id, name: name, qty: 1, price: Money.round2(amount), vat: info.vat ?? 0,
                                 cost: unitCost.map { ($0 * kg * 10_000).rounded() / 10_000 }, units: kg, category: item.cat))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func nextBatch(_ item: PriceItem) -> BatchOnShelf? {
        let level = till.levels(items: [item], shop: shop ?? "", invoices: AppData.entries(context)).first
        return BatchMaths.next(till.shelf(of: item, shop: shop ?? "", onHand: level?.onHand ?? 0))
    }

    private func add(_ item: PriceItem, pack: Bool, kg: Double? = nil, batchOK: Bool = false) {
        let info = item.till ?? TillInfo()
        let price = pack ? (info.packSell ?? 0) : (info.sell ?? 0)
        guard price > 0 else {
            pricing = item
            return
        }
        if info.ageCheck == true && !ageChecked.contains(item.id) {
            ageItem = AgeCheck(item: item, pack: pack)
            return
        }
        if item.isByWeight && !pack && kg == nil {
            weighing = item
            return
        }
        var batch: String?
        if info.batches == true, let next = nextBatch(item) {
            if next.days < 0 && !batchOK {
                expired = ExpiredPick(item: item, pack: pack, kg: kg, batch: next)
                return
            }
            batch = next.batch.code
        }
        // till-only items: the price in the list is what one costs; others: the agreed pack price ÷ units
        let unitCost: Double? = item.price > 0 ? (item.isTillOnly ? item.price : item.unitCost(shop: shop ?? "")) : nil
        if let kg {
            basket.append(BasketLine(itemID: item.id, name: item.name, qty: kg, price: price, vat: info.vat ?? 0,
                                     cost: unitCost.map { ($0 * 10_000).rounded() / 10_000 }, weighed: true, batch: batch, category: item.cat))
        } else {
            let units = pack ? item.unitsPerPack : 1
            if let index = basket.firstIndex(where: { $0.itemID == item.id && $0.units == units && $0.price == price && $0.manualOff == 0
                && !$0.weighed && $0.batch == batch }) {
                basket[index].qty += 1
            } else {
                let name = pack ? String(localized: "\(item.name) (pack of \(units.formatted()))") : item.name
                basket.append(BasketLine(itemID: item.id, name: name, qty: 1, price: price, vat: info.vat ?? 0,
                                         cost: unitCost.map { ($0 * units * 10_000).rounded() / 10_000 }, units: units,
                                         offerQty: info.offer?.qty, offerPrice: info.offer?.price, batch: batch, category: item.cat))
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func restore(_ parked: ParkedSale) {
        guard let back = till.unpark(parked.id) else { return }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        basket = back.lines.map { line in
            let item = line.itemID.flatMap { byID[$0] }
            var restored = BasketLine(itemID: line.itemID, name: line.name, qty: line.qty, price: line.price, vat: line.vat, cost: line.cost,
                                      units: line.units ?? 1, offerQty: item?.till?.offer?.qty, offerPrice: item?.till?.offer?.price,
                                      weighed: line.weighed == true, batch: line.batch, giftCard: line.giftCard, category: item?.cat ?? "")
            // what was off, less what the offer gives again now (deals are worked out again from the basket)
            restored.manualOff = max(0, (line.discount ?? 0) - restored.offerOff - (line.deal == nil ? 0 : (line.discount ?? 0)))
            return restored
        }
        basketOff = 0
        customer = till.customer(back.customer)
    }

    private func finish(payment: PaymentKind, tendered: Double?, split: [SalePayment]?) {
        var lines = priced.map(\.sale)
        if basketOff > 0 { lines = SaleMaths.shareDiscount(basketOff, over: lines) }
        let sale = till.record(lines: lines, shop: shop ?? "", payment: payment, tendered: tendered, split: split,
                               customer: customer?.id, approvedBy: approvedBy.isEmpty ? nil : approvedBy.joined(separator: ", "), context: context)
        let hadCash = sale.payments.contains { $0.kind == .cash }
        if printer.settings.isSet {
            if printer.settings.autoPrint {
                printer.print(TillReceipt.text(sale), openDrawer: hadCash)
            } else if hadCash && printer.settings.drawer {
                printer.openDrawer()
            }
        }
        let change = tendered.map { SaleMaths.change(tendered: $0, total: sale.payments.filter { $0.kind == .cash }.reduce(0) { $0 + $1.amount }) } ?? 0
        screen.show(ScreenState(shop: Shops.reportName(shop ?? ""), lines: [], total: "",
                                message: change > 0.004 ? String(localized: "Change \(Money.format(change))") : String(localized: "Thank you")))
        clear()
        if till.receipt.askForReceipt || change > 0.004 { done = sale }
    }

    /// What the customer screen shows.
    private func pushScreen() {
        let lines = priced.map { line in
            ScreenLine(id: line.id, name: line.name,
                       detail: line.weighed ? Weight.text(line.qty) + " @ " + Money.format(line.price) + "/kg"
                           : (line.qty == 1 ? "" : "\(line.qty.formatted()) × \(Money.format(line.price))"),
                       amount: Money.format(line.total))
        }
        let saved = Money.round2(priced.reduce(0) { $0 + $1.discount } + min(basketOff, subtotal))
        screen.show(ScreenState(shop: Shops.reportName(shop ?? ""), lines: lines, total: basket.isEmpty ? "" : Money.format(total),
                                saving: saved > 0.004 ? String(localized: "You save \(Money.format(saved))") : nil, message: nil))
    }
}

/// Change one line: how many (or how heavy), its price, money off, or take it out.
struct LineSheet: View {
    let line: BasketLine
    let onDone: (BasketLine?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var edit: BasketLine
    @State private var priceText: String
    @State private var offText: String
    @State private var weightText: String
    @State private var percent = false

    init(line: BasketLine, onDone: @escaping (BasketLine?) -> Void) {
        self.line = line
        self.onDone = onDone
        _edit = State(initialValue: line)
        _priceText = State(initialValue: String(format: "%.2f", line.price))
        _offText = State(initialValue: line.manualOff > 0 ? String(format: "%.2f", line.manualOff) : "")
        _weightText = State(initialValue: line.weighed ? String(format: "%.3f", line.qty) : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if line.weighed {
                    LabeledContent("Weight (kg)") {
                        TextField("0.000", text: $weightText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                } else if line.giftCard == nil {
                    Stepper(value: $edit.qty, in: 1...9_999) {
                        LabeledContent("How many", value: edit.qty.formatted())
                    }
                }
                if line.giftCard == nil {
                    LabeledContent(line.weighed ? String(localized: "Price a kg") : String(localized: "Price")) {
                        TextField(Money.format(0), text: $priceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Section {
                        Picker("Money off", selection: $percent) {
                            Text("Amount").tag(false)
                            Text("%").tag(true)
                        }
                        .pickerStyle(.segmented)
                        TextField(percent ? "10" : Money.format(0), text: $offText)
                            .keyboardType(.decimalPad)
                    } footer: {
                        if edit.offerOff > 0 {
                            Text("The multi-buy takes off \(Money.format(edit.offerOff)) as well.")
                        }
                    }
                }
                Section {
                    Button("Take it off the sale", role: .destructive) {
                        onDone(nil)
                        dismiss()
                    }
                }
            }
            .navigationTitle(line.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        var out = edit
                        if line.weighed, let kg = Weight.parse(weightText, gramsWithoutPoint: false) { out.qty = kg }
                        if line.giftCard == nil, let price = Money.parse(priceText), price >= 0 { out.price = Money.round2(price) }
                        let typed = Money.parse(offText) ?? 0
                        out.manualOff = Money.round2(max(0, percent ? out.qty * out.price * min(typed, 100) / 100 : typed))
                        onDone(out)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Take the money: cash (with change), card on your own card machine, split between them, or other — and first,
/// if they have one, a gift card, their account or their points.
struct PaySheet: View {
    let total: Double
    var customer: Customer?
    let onPaid: (PaymentKind, Double?, [SalePayment]?) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var till = TillStore.shared
    @State private var kind = 0
    @State private var given = ""
    @State private var cashPart = ""
    @State private var extras: [SalePayment] = []
    @State private var askingGift = false
    @State private var giftCode = ""
    @State private var scanningGift = false
    @State private var problem: String?
    @State private var approval: ApprovalRequest?

    /// Still to pay after the gift card, account or points.
    private var due: Double { Money.round2(max(0, total - extras.reduce(0) { $0 + $1.amount })) }
    private var tendered: Double? { Money.parse(given) }
    private var cashShare: Double { min(due, max(0, Money.parse(cashPart) ?? 0)) }

    /// Exact, then the next notes up.
    private var quick: [Double] {
        let notes: [Double] = [5, 10, 20, 50]
        return [due] + notes.filter { $0 > due }.prefix(3)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(Money.format(due))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                    if !extras.isEmpty {
                        LabeledContent("Sale", value: Money.format(total))
                        ForEach(Array(extras.enumerated()), id: \.offset) { index, part in
                            HStack {
                                Text(SaleMaths.payName(part.kind) + (part.kind == .gift ? " " + (part.ref ?? "") : ""))
                                Spacer()
                                Text("−" + Money.format(part.amount)).foregroundStyle(.green)
                                Button {
                                    extras.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Text("Remove"))
                            }
                            .font(.subheadline)
                        }
                    }
                    if due > 0.004 {
                        Picker("Paid by", selection: $kind) {
                            Text("Cash").tag(0)
                            Text("Card").tag(1)
                            Text("Split").tag(3)
                            Text("Other").tag(2)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                if due > 0.004 {
                    mainPart
                    alsoPart
                }
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { pay() }
                        .fontWeight(.bold)
                        .disabled(due > 0.004 && kind == 0 && (tendered ?? due) < due - 0.001)
                }
            }
            .alert("Gift card", isPresented: $askingGift) {
                TextField("Card number", text: $giftCode).keyboardType(.numberPad)
                Button("Use it") { useGift(giftCode) }
                if BarcodeScanner.canScan {
                    Button("Scan it") { scanningGift = true }
                }
                Button("Cancel", role: .cancel) { giftCode = "" }
            } message: {
                Text("The 12-digit number on the gift card receipt.")
            }
            .sheet(isPresented: $scanningGift) {
                BarcodeScanner { code in
                    scanningGift = false
                    useGift(code)
                }
                .ignoresSafeArea()
            }
            .managerApproval($approval)
        }
    }

    @ViewBuilder
    private var mainPart: some View {
        if kind == 0 {
            Section("Cash given") {
                HStack {
                    ForEach(quick, id: \.self) { amount in
                        Button(amount == due ? String(localized: "Exact") : Money.format(amount)) {
                            given = String(format: "%.2f", amount)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                TextField(Money.format(0), text: $given)
                    .keyboardType(.decimalPad)
                if let tendered, tendered >= due {
                    LabeledContent("Change to give") {
                        Text(Money.format(SaleMaths.change(tendered: tendered, total: due)))
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.green)
                    }
                }
            }
        } else if kind == 3 {
            Section {
                LabeledContent("Cash") {
                    TextField(Money.format(0), text: $cashPart)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Card", value: Money.format(Money.round2(due - cashShare)))
            } footer: {
                Text("Take the cash part, then the rest on your card machine.")
            }
        } else if kind == 1 {
            Section {
                Text("Take the card on your card machine, then tap Done. Taking cards on this iPhone itself needs a card payment account, which isn't set up yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var alsoPart: some View {
        Section {
            Button {
                giftCode = ""
                askingGift = true
            } label: {
                Label("Gift card", systemImage: "giftcard")
            }
            if let customer {
                let balance = till.balance(customer)
                if customer.tabLimit != nil {
                    Button {
                        putOnAccount(customer, owed: balance.tab)
                    } label: {
                        Label(String(localized: "On \(customer.name)'s account (owes \(Money.format(balance.tab)))"), systemImage: "person.text.rectangle")
                    }
                }
                if till.options.loyaltyOn, balance.points > 0, !extras.contains(where: { $0.kind == .points }) {
                    let worth = CustomerMaths.worth(points: balance.points, loyalty: till.options.loyalty)
                    Button {
                        usePoints(customer, points: balance.points)
                    } label: {
                        Label(String(localized: "Use \(balance.points) points (\(Money.format(worth)))"), systemImage: "star.circle")
                    }
                }
            }
        } header: {
            Text("Or pay with")
        }
    }

    private func useGift(_ typed: String) {
        problem = nil
        giftCode = ""
        let code = typed.filter(\.isNumber)
        guard let card = till.giftCard(code) else {
            problem = String(localized: "No gift card with that number was sold on this till's shops.")
            return
        }
        let used = extras.filter { $0.kind == .gift && $0.ref == card.code }.reduce(0) { $0 + $1.amount }
        let left = Money.round2(GiftCards.balance(card, sales: till.sales) - used)
        guard left > 0.004 else {
            problem = String(localized: "That gift card has nothing left on it.")
            return
        }
        extras.append(SalePayment(kind: .gift, amount: min(left, due), ref: card.code))
    }

    private func putOnAccount(_ customer: Customer, owed: Double) {
        problem = nil
        guard CustomerMaths.tabAllows(customer, owed: owed, adding: due) else {
            problem = String(localized: "That would take \(customer.name) over the most they can owe (\(Money.format(customer.tabLimit ?? 0))).")
            return
        }
        Gate.check(.tab, PermissionText.title(.tab), request: $approval) { _ in
            extras.append(SalePayment(kind: .tab, amount: due, ref: customer.id))
        }
    }

    private func usePoints(_ customer: Customer, points: Int) {
        let worth = till.options.loyalty.worth
        guard worth > 0 else { return }
        let spend = min(points, Int((due / worth + 0.000_1).rounded(.down)))
        guard spend > 0 else { return }
        extras.append(SalePayment(kind: .points, amount: Money.round2(Double(spend) * worth), ref: customer.id))
    }

    private func pay() {
        if due <= 0.004 {
            guard let first = extras.first else { return }
            onPaid(first.kind, nil, extras)
            return
        }
        var parts = extras
        var main: PaymentKind
        var cash: Double?
        switch kind {
        case 0:
            main = .cash
            cash = tendered ?? due
            parts.append(SalePayment(kind: .cash, amount: due))
        case 1:
            main = .card
            parts.append(SalePayment(kind: .card, amount: due))
        case 3:
            let c = Money.round2(cashShare)
            main = c >= due ? .cash : .card
            parts += [SalePayment(kind: .cash, amount: c), SalePayment(kind: .card, amount: Money.round2(due - c))].filter { $0.amount > 0 }
        default:
            main = .other
            parts.append(SalePayment(kind: .other, amount: due))
        }
        onPaid(main, cash, parts.count > 1 || parts.contains { $0.ref != nil } ? parts : nil)
    }
}

/// After the sale: change to give, and a receipt to send, print or email.
struct ReceiptSheet: View {
    let sale: Sale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var till = TillStore.shared
    @ObservedObject private var printer = ReceiptPrinter.shared

    private var text: String { TillReceipt.text(sale) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: sale.refundOf == nil ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text(sale.refundOf == nil ? String(localized: "Sale \(till.number(sale)) done") : String(localized: "Refund \(till.number(sale)) done"))
                    .font(.title2.weight(.bold))
                if let tendered = sale.tendered {
                    let cash = sale.payments.filter { $0.kind == .cash }.reduce(0) { $0 + $1.amount }
                    if tendered > cash + 0.001 {
                        Text("Change: \(Money.format(SaleMaths.change(tendered: tendered, total: cash)))")
                            .font(.title.weight(.bold))
                            .foregroundStyle(.green)
                    }
                }
                ScrollView {
                    Text(text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                ReceiptButtons(sale: sale, text: text)
                if let problem = printer.problem {
                    Text(problem).font(.footnote).foregroundStyle(.red)
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

/// Send, print (receipt printer or AirPrint) and email a receipt.
struct ReceiptButtons: View {
    let sale: Sale
    let text: String
    @Environment(\.openURL) private var openURL
    @ObservedObject private var till = TillStore.shared
    @ObservedObject private var printer = ReceiptPrinter.shared

    var body: some View {
        HStack {
            ShareLink(item: text) {
                Label("Send", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            Button {
                if printer.settings.isSet {
                    printer.print(text, openDrawer: false)
                } else {
                    Printing.printText(text, title: String(localized: "Receipt"))
                }
            } label: {
                Label("Print", systemImage: "printer")
            }
            .buttonStyle(.bordered)
            .disabled(printer.busy)
            if let email = till.customer(sale.customer)?.email, email.contains("@"), let url = TillReceipt.mail(to: email, sale: sale, text: text) {
                Button {
                    openURL(url)
                } label: {
                    Label("Email", systemImage: "envelope")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

/// A receipt with the shop's own header, footer and VAT number, the customer and their points.
enum TillReceipt {
    @MainActor
    static func text(_ sale: Sale) -> String {
        let till = TillStore.shared
        let settings = till.receipt
        var shown = sale
        if !till.severalTills { shown.till = nil }
        var text = SaleMaths.receipt(shown, shopName: Shops.reportName(sale.shop), currency: Money.currency.code,
                                     header: settings.header, footer: settings.footer, vatNumber: settings.vatNumber)
        if let customer = till.customer(sale.customer) {
            text += "\n\n" + String(localized: "Customer: \(customer.name)")
            if till.options.loyaltyOn {
                let earned = CustomerMaths.pointsEarned(sale, perPound: till.options.loyalty.perPound)
                if earned != 0 { text += "\n" + String(localized: "Points earned: \(earned)") }
                text += "\n" + String(localized: "Points now: \(till.balance(customer).points)")
            }
            let owed = till.balance(customer).tab
            if sale.payments.contains(where: { $0.kind == .tab }) || abs(owed) > 0.004 {
                text += "\n" + String(localized: "Owed on account: \(Money.format(owed))")
            }
        }
        for part in sale.payments where part.kind == .gift {
            if let code = part.ref, let card = till.giftCard(code) {
                text += "\n" + String(localized: "Left on gift card \(code): \(Money.format(GiftCards.balance(card, sales: till.sales)))")
            }
        }
        return text
    }

    @MainActor
    static func mail(to email: String, sale: Sale, text: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = email
        parts.queryItems = [URLQueryItem(name: "subject", value: String(localized: "Your receipt from \(Shops.reportName(sale.shop))")),
                            URLQueryItem(name: "body", value: text)]
        return parts.url
    }
}
