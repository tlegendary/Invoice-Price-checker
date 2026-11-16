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
    let id = UUID().uuidString
    var itemID: String?
    var name: String
    var qty: Double
    /// Price of one of these (a single, or a whole pack).
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

    var offerOff: Double {
        guard units == 1, let q = offerQty, let p = offerPrice else { return 0 }
        return SaleMaths.offerDiscount(qty: qty, price: price, offer: (q, p))
    }
    var discount: Double { Money.round2(min(qty * price, manualOff + offerOff)) }
    var total: Double { Money.round2(qty * price - discount) }

    var sale: SaleLine {
        SaleLine(itemID: itemID, name: name, qty: qty, price: price, vat: vat, cost: cost, units: units == 1 ? nil : units,
                 discount: discount > 0 ? discount : nil)
    }
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
    @State private var basketOff = 0.0
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
    @State private var cashSheet: CashKind?
    @State private var showDay = false
    @State private var showSettings = false

    private var shops: [ShopInfo] { Shops.decode(shopData) }
    private var items: [PriceItem] { prices.map { $0.item }.filter { $0.isIn(shop: shop ?? "") } }
    private var subtotal: Double { Money.round2(basket.reduce(0) { $0 + $1.total }) }
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
            attach(screen)
        }
    }

    private var screen: some View {
            Group {
                if locked {
                    PinPad(title: String(localized: "Who's serving?")) { pin in till.signIn(pin: pin) }
                } else if shop == nil {
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
            .toolbar { toolbar }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Find an item or type a barcode"))
            .onSubmit(of: .search) {
                if let item = items.first(where: { $0.hasBarcode(search) }) {
                    add(item, pack: (item.till?.sell ?? 0) <= 0)
                    search = ""
                }
            }
            .onAppear { if shop == nil { shop = TillShop.resolve(view: LiveSettings.shared.shop, shops: shops) } }
    }

    // MARK: sheets and alerts

    private func attach<Content: View>(_ content: Content) -> some View {
        alerts(sheets(content))
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
                PaySheet(total: total) { payment, tendered, split in
                    paying = false
                    var lines = basket.map(\.sale)
                    if basketOff > 0 { lines = SaleMaths.shareDiscount(basketOff, over: lines) }
                    let sale = till.record(lines: lines, shop: shop ?? "", payment: payment, tendered: tendered, split: split, context: context)
                    basket = []
                    basketOff = 0
                    ageChecked = []
                    if till.receipt.askForReceipt || (tendered ?? 0) > sale.total + 0.001 { done = sale }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $done) { sale in
                ReceiptSheet(sale: sale)
            }
            .sheet(item: $editingLine) { line in
                LineSheet(line: line) { changed in
                    if let index = basket.firstIndex(where: { $0.id == line.id }) {
                        if let changed { basket[index] = changed } else { basket.remove(at: index) }
                    }
                }
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
                    till.addCash(wrapper.kind, amount: amount, note: note, shop: shop ?? "")
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showDay) {
                DayView(shop: shop ?? "")
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { TillSettingsView(done: true) }
            }
            .sheet(item: Binding(get: { unknownCode.map { CodeLink(code: $0) } }, set: { if $0 == nil { unknownCode = nil } })) { link in
                ItemPicker(items: items) { item in
                    var changed = item
                    var info = changed.till ?? TillInfo()
                    info.barcodes = (info.barcodes ?? []) + [link.code]
                    changed.till = info
                    AppData.save(changed, in: context, logged: false)
                    try? context.save()
                    add(changed, pack: false)
                }
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
            .alert("Park this sale", isPresented: $parking) {
                TextField("Name, e.g. Ali", text: $parkName)
                Button("Park") {
                    var lines = basket.map(\.sale)
                    if basketOff > 0 { lines = SaleMaths.shareDiscount(basketOff, over: lines) }
                    till.park(lines, shop: shop ?? "", name: parkName.trimmingCharacters(in: .whitespaces))
                    basket = []
                    basketOff = 0
                    parkName = ""
                }
                Button("Cancel", role: .cancel) { parkName = "" }
            } message: {
                Text("Keep it to finish later, and serve the next customer.")
            }
            .alert("Check their ID", isPresented: Binding(get: { ageItem != nil }, set: { if !$0 { ageItem = nil } }), presenting: ageItem) { pending in
                Button("ID checked: 18 or over") {
                    ageChecked.insert(pending.item.id)
                    add(pending.item, pack: pending.pack)
                }
                Button("Don't sell", role: .cancel) {}
            } message: { pending in
                Text("\(pending.item.name) is age restricted. Challenge 25: ask for ID if they look under 25.")
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
                        Button { cashSheet = CashKind(kind: .float) } label: { Label("Opening float", systemImage: "tray.and.arrow.down") }
                        Button { cashSheet = CashKind(kind: .paidIn) } label: { Label("Cash in", systemImage: "plus.circle") }
                        Button { cashSheet = CashKind(kind: .paidOut) } label: { Label("Cash out", systemImage: "minus.circle") }
                        Button { showDay = true } label: { Label("End of day", systemImage: "lock.rectangle.stack") }
                    }
                    if till.parked.contains(where: { $0.shop == (shop ?? "") }) {
                        Button { recalling = true } label: { Label("Parked sales", systemImage: "pause.circle") }
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
                    Button { showSettings = true } label: { Label("Till settings", systemImage: "gearshape") }
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
                        Button(Money.format(sell)) {
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
                    }
                    Spacer(minLength: 0)
                    if let sell = item.till?.sell, sell > 0 {
                        Text(Money.format(sell))
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
                Button { customAmount = true } label: { Label("Amount", systemImage: "plus") }
                    .buttonStyle(.bordered)
                Spacer()
                if !basket.isEmpty {
                    Menu {
                        Button { discounting = true } label: { Label("Discount on the sale", systemImage: "percent") }
                        Button { parking = true } label: { Label("Park the sale", systemImage: "pause.circle") }
                        Button(role: .destructive) {
                            basket = []
                            basketOff = 0
                            ageChecked = []
                        } label: { Label("Clear the sale", systemImage: "trash") }
                    } label: {
                        Label("Sale", systemImage: "ellipsis.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
            if !basket.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($basket) { $line in
                            HStack {
                                Button {
                                    editingLine = line
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(line.name).font(.subheadline).lineLimit(1)
                                        HStack(spacing: 6) {
                                            Text(Money.format(line.price)).font(.caption).foregroundStyle(.secondary)
                                            if line.discount > 0 {
                                                Text("−\(Money.format(line.discount))").font(.caption.weight(.semibold)).foregroundStyle(.green)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .foregroundStyle(.primary)
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

    private func add(_ item: PriceItem, pack: Bool) {
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
        let units = pack ? item.unitsPerPack : 1
        if let index = basket.firstIndex(where: { $0.itemID == item.id && $0.units == units && $0.price == price && $0.manualOff == 0 }) {
            basket[index].qty += 1
        } else {
            // till-only items: the price in the list is what one costs; others: the agreed pack price ÷ units
            let cost: Double? = item.price > 0 ? (item.isTillOnly ? item.price * units : item.unitCost(shop: shop ?? "") * units) : nil
            let name = pack ? String(localized: "\(item.name) (pack of \(units.formatted()))") : item.name
            basket.append(BasketLine(itemID: item.id, name: name, qty: 1, price: price, vat: info.vat ?? 0,
                                     cost: cost.map { ($0 * 10_000).rounded() / 10_000 }, units: units,
                                     offerQty: info.offer?.qty, offerPrice: info.offer?.price))
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func scanned(_ code: String) {
        if let item = items.first(where: { $0.hasBarcode(code) }) {
            add(item, pack: (item.till?.sell ?? 0) <= 0)
        } else {
            unknownCode = code
        }
    }

    private func restore(_ parked: ParkedSale) {
        guard let back = till.unpark(parked.id) else { return }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        basket = back.lines.map { line in
            let item = line.itemID.flatMap { byID[$0] }
            var restored = BasketLine(itemID: line.itemID, name: line.name, qty: line.qty, price: line.price, vat: line.vat, cost: line.cost,
                                      units: line.units ?? 1, offerQty: item?.till?.offer?.qty, offerPrice: item?.till?.offer?.price)
            // what was off, less what the offer gives again now
            restored.manualOff = max(0, (line.discount ?? 0) - restored.offerOff)
            return restored
        }
        basketOff = 0
    }
}

/// Change one line: how many, its price, money off, or take it out.
struct LineSheet: View {
    let line: BasketLine
    let onDone: (BasketLine?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var edit: BasketLine
    @State private var priceText: String
    @State private var offText: String
    @State private var percent = false

    init(line: BasketLine, onDone: @escaping (BasketLine?) -> Void) {
        self.line = line
        self.onDone = onDone
        _edit = State(initialValue: line)
        _priceText = State(initialValue: String(format: "%.2f", line.price))
        _offText = State(initialValue: line.manualOff > 0 ? String(format: "%.2f", line.manualOff) : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Stepper(value: $edit.qty, in: 1...9_999) {
                    LabeledContent("How many", value: edit.qty.formatted())
                }
                LabeledContent("Price") {
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
                        if let price = Money.parse(priceText), price >= 0 { out.price = Money.round2(price) }
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

/// Money off the whole sale (amount or %).
struct BasketDiscountSheet: View {
    let subtotal: Double
    let current: Double
    let onDone: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var percent = true
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Sale", value: Money.format(subtotal))
                Picker("Money off", selection: $percent) {
                    Text("%").tag(true)
                    Text("Amount").tag(false)
                }
                .pickerStyle(.segmented)
                TextField(percent ? "10" : Money.format(0), text: $text)
                    .keyboardType(.decimalPad)
                HStack {
                    ForEach([5, 10, 15, 20], id: \.self) { p in
                        Button("\(p)%") {
                            percent = true
                            text = "\(p)"
                        }
                        .buttonStyle(.bordered)
                    }
                }
                if current > 0 {
                    Button("Remove the discount", role: .destructive) {
                        onDone(0)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Discount on the sale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let typed = Money.parse(text) ?? 0
                        onDone(Money.round2(min(subtotal, max(0, percent ? subtotal * min(typed, 100) / 100 : typed))))
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Parked sales to pick up again.
struct ParkedList: View {
    let shop: String
    let onPick: (ParkedSale) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var till = TillStore.shared

    var body: some View {
        NavigationStack {
            List {
                ForEach(till.parked.filter { $0.shop == shop }) { parked in
                    Button {
                        onPick(parked)
                        dismiss()
                    } label: {
                        LabeledContent(parked.name.isEmpty ? SalesText.time(parked.at) : parked.name,
                                       value: Money.format(Money.round2(parked.lines.reduce(0) { $0 + $1.gross })))
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button("Delete", role: .destructive) { _ = till.unpark(parked.id) }
                    }
                }
            }
            .navigationTitle("Parked sales")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

/// Cash put in or taken out of the drawer.
struct CashSheet: View {
    let kind: CashEvent.Kind
    let onSave: (Double, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var note = ""

    private var title: String {
        switch kind {
        case .float: return String(localized: "Opening float")
        case .paidIn: return String(localized: "Cash in")
        case .paidOut: return String(localized: "Cash out")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(Money.format(0), text: $amount)
                    .keyboardType(.decimalPad)
                    .font(.title2)
                TextField(kind == .paidOut ? String(localized: "What for, e.g. paid the window cleaner") : String(localized: "Note (optional)"), text: $note)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let value = Money.parse(amount), value > 0 { onSave(value, note.trimmingCharacters(in: .whitespaces)) }
                        dismiss()
                    }
                    .disabled((Money.parse(amount) ?? 0) <= 0)
                }
            }
        }
    }
}

/// Take the money: cash (with change), card on your own card machine, split between them, or other.
struct PaySheet: View {
    let total: Double
    let onPaid: (PaymentKind, Double?, [SalePayment]?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = 0
    @State private var given = ""
    @State private var cashPart = ""

    private var tendered: Double? { Money.parse(given) }
    private var cashShare: Double { min(total, max(0, Money.parse(cashPart) ?? 0)) }

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
                        Text("Cash").tag(0)
                        Text("Card").tag(1)
                        Text("Split").tag(3)
                        Text("Other").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                if kind == 0 {
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
                } else if kind == 3 {
                    Section {
                        LabeledContent("Cash") {
                            TextField(Money.format(0), text: $cashPart)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Card", value: Money.format(Money.round2(total - cashShare)))
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
            .navigationTitle("Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        switch kind {
                        case 0: onPaid(.cash, tendered ?? total, nil)
                        case 1: onPaid(.card, nil, nil)
                        case 3:
                            let cash = Money.round2(cashShare)
                            let parts = [SalePayment(kind: .cash, amount: cash), SalePayment(kind: .card, amount: Money.round2(total - cash))]
                                .filter { $0.amount > 0 }
                            onPaid(cash >= total ? .cash : .card, nil, parts.count > 1 ? parts : nil)
                        default: onPaid(.other, nil, nil)
                        }
                    }
                    .fontWeight(.bold)
                    .disabled(kind == 0 && (tendered ?? total) < total - 0.001)
                }
            }
        }
    }
}

/// After the sale: change to give, and a receipt to send or print.
struct ReceiptSheet: View {
    let sale: Sale
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var till = TillStore.shared

    private var text: String { TillReceipt.text(sale) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: sale.refundOf == nil ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text(sale.refundOf == nil ? String(localized: "Sale \(sale.number) done") : String(localized: "Refund \(sale.number) done"))
                    .font(.title2.weight(.bold))
                if let tendered = sale.tendered, tendered > sale.total + 0.001 {
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

/// A receipt with the shop's own header, footer and VAT number.
enum TillReceipt {
    @MainActor
    static func text(_ sale: Sale) -> String {
        let settings = TillStore.shared.receipt
        return SaleMaths.receipt(sale, shopName: Shops.reportName(sale.shop), currency: Money.currency.code,
                                 header: settings.header, footer: settings.footer, vatNumber: settings.vatNumber)
    }
}

/// A PIN pad: four digits sign a cashier in.
struct PinPad: View {
    let title: String
    let check: (String) -> Bool
    @State private var pin = ""
    @State private var wrong = false

    var body: some View {
        VStack(spacing: 20) {
            Text(title).font(.title2.weight(.bold))
            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < pin.count ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 16, height: 16)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(pin.count) of 4 digits"))
            if wrong {
                Text("That PIN isn't right.").foregroundStyle(.red).font(.footnote)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(84)), count: 3), spacing: 14) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"], id: \.self) { key in
                    if key.isEmpty {
                        Color.clear.frame(height: 64)
                    } else {
                        Button {
                            press(key)
                        } label: {
                            Text(key)
                                .font(.title.weight(.semibold))
                                .frame(width: 84, height: 64)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(key == "⌫" ? String(localized: "Delete") : key))
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func press(_ key: String) {
        wrong = false
        if key == "⌫" {
            if !pin.isEmpty { pin.removeLast() }
            return
        }
        guard pin.count < 4 else { return }
        pin += key
        if pin.count == 4 {
            if !check(pin) {
                wrong = true
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            pin = ""
        }
    }
}

/// AirPrint for a plain text receipt or report.
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
