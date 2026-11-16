import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ChargeCheckCore

/// Till › End of day: what's been taken so far (X), then count the drawer and close the day (Z).
struct DayView: View {
    let shop: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var till = TillStore.shared
    @State private var counted = ""
    @State private var closed: DayReport?
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            let x = till.current(shop: shop)
            List {
                if let closed {
                    Section {
                        Text(CashDay.text(closed, shopName: Shops.reportName(shop), currency: Money.currency.code))
                            .font(.system(.footnote, design: .monospaced))
                        ShareLink(item: CashDay.text(closed, shopName: Shops.reportName(shop), currency: Money.currency.code)) {
                            Label("Send the report", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            Printing.printText(CashDay.text(closed, shopName: Shops.reportName(shop), currency: Money.currency.code), title: "Z\(closed.number)")
                        } label: {
                            Label("Print", systemImage: "printer")
                        }
                    } header: {
                        Text("Day closed: Z\(closed.number)")
                    }
                } else {
                    Section {
                        LabeledContent("Sales", value: "\(x.sales)")
                        LabeledContent("Takings", value: Money.format(x.takings))
                        LabeledContent("Profit", value: Money.format(x.profit))
                        LabeledContent("Cash", value: Money.format(x.cash))
                        LabeledContent("Card", value: Money.format(x.card))
                        if abs(x.other) > 0.005 { LabeledContent("Other", value: Money.format(x.other)) }
                        if x.refunds > 0 { LabeledContent("Refunds", value: "\(x.refunds)") }
                    } header: {
                        Text(x.from.isEmpty ? String(localized: "So far") : String(localized: "Since \(SalesText.time(x.from))"))
                    }
                    Section {
                        LabeledContent("Opening float", value: Money.format(x.float))
                        LabeledContent("Cash in", value: Money.format(x.paidIn))
                        LabeledContent("Cash out", value: Money.format(x.paidOut))
                        LabeledContent("Cash there should be") {
                            Text(Money.format(x.expected)).fontWeight(.bold)
                        }
                        LabeledContent("Cash counted") {
                            TextField(Money.format(0), text: $counted)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                        if let value = Money.parse(counted) {
                            let difference = Money.round2(value - x.expected)
                            LabeledContent("Difference") {
                                Text(Money.format(difference))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(abs(difference) < 0.005 ? .green : (difference < 0 ? .red : .orange))
                            }
                        }
                    } header: {
                        Text("The cash drawer")
                    } footer: {
                        Text("Count the notes and coins, then close the day. The next day starts from now; the report is kept below.")
                    }
                    Section {
                        Button("Close the day", role: .destructive) { confirm = true }
                    }
                }
                let past = till.days.filter { $0.shop == shop }.sorted { $0.number > $1.number }
                if !past.isEmpty {
                    Section("Earlier days") {
                        ForEach(past.prefix(60)) { day in
                            NavigationLink {
                                ScrollView {
                                    Text(CashDay.text(day, shopName: Shops.reportName(shop), currency: Money.currency.code))
                                        .font(.system(.footnote, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding()
                                }
                                .navigationTitle("Z\(day.number)")
                                .toolbar {
                                    ShareLink(item: CashDay.text(day, shopName: Shops.reportName(shop), currency: Money.currency.code))
                                }
                            } label: {
                                LabeledContent("Z\(day.number) · " + SalesText.time(day.to), value: Money.format(day.takings))
                            }
                        }
                    }
                }
            }
            .navigationTitle("End of day")
            .navigationBarTitleDisplayMode(.inline)
            .themedScreen()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Close the day?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Close the day", role: .destructive) {
                    closed = till.closeDay(shop: shop, counted: Money.parse(counted))
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sales from now on go on the next day's report.")
            }
        }
    }
}

/// More › Till › Till settings: receipts, cashiers, your own products.
struct TillSettingsView: View {
    /// Shown in a sheet (with a Done button).
    var done = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @ObservedObject private var till = TillStore.shared
    @AppStorage(Shops.listKey) private var shopData = Data()
    @State private var addingCashier = false
    @State private var newName = ""
    @State private var newPin = ""
    @State private var importing = false
    @State private var imported: [ImportedProduct]?
    @State private var columns: [String: String] = [:]
    @State private var addingProduct = false
    @State private var notice: String?

    var body: some View {
        List {
            Section {
                TextField("Address, phone…", text: $till.receipt.header, axis: .vertical)
                TextField("VAT number", text: $till.receipt.vatNumber)
                TextField("At the bottom, e.g. Thank you, see you soon", text: $till.receipt.footer, axis: .vertical)
                Toggle("Show the receipt after every sale", isOn: $till.receipt.askForReceipt)
            } header: {
                Text("Receipts")
            } footer: {
                Text("Off: the till goes straight to the next sale (it still shows when there's change to give). Every receipt is kept in Sales.")
            }

            Section {
                ForEach(till.cashiers) { cashier in
                    Label(cashier.name, systemImage: "person.crop.circle")
                }
                .onDelete { offsets in
                    for index in offsets { till.removeCashier(till.cashiers[index].id) }
                }
                Button {
                    addingCashier = true
                } label: {
                    Label("Add a cashier", systemImage: "person.badge.plus")
                }
            } header: {
                Text("Cashiers")
            } footer: {
                Text("With cashiers, the till asks for a 4-digit PIN and every sale shows who served. Swipe left to remove one.")
            }

            Section {
                Button {
                    importing = true
                } label: {
                    Label("Import products (CSV)", systemImage: "square.and.arrow.down")
                }
                Button {
                    addingProduct = true
                } label: {
                    Label("Add a product", systemImage: "plus.circle")
                }
                if let notice {
                    Text(notice).font(.footnote).foregroundStyle(.green)
                }
            } header: {
                Text("Your products")
            } footer: {
                Text("For things you sell that don't come on a supplier invoice, or your whole list from another till (save it as CSV). Products already in your price list (same barcode or name) get the till price instead of a copy.")
            }

            Section {
                Label("Card payments on this iPhone aren't set up. Use your own card machine and choose Card at the till.", systemImage: "creditcard")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Till settings")
        .themedScreen()
        .onChange(of: till.receipt) { till.saveSettings() }
        .toolbar {
            if done {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Add a cashier", isPresented: $addingCashier) {
            TextField("Name", text: $newName)
            SecureField("4-digit PIN", text: $newPin)
                .keyboardType(.numberPad)
            Button("Add") {
                let pin = newPin.filter(\.isNumber)
                let name = newName.trimmingCharacters(in: .whitespaces)
                if pin.count == 4, !name.isEmpty, !till.cashiers.contains(where: { $0.pinHash == TillStore.hash(pin) }) {
                    till.addCashier(name: name, pin: pin)
                } else {
                    notice = String(localized: "Use a name and a 4-digit PIN that no one else has.")
                }
                newName = ""
                newPin = ""
            }
            Button("Cancel", role: .cancel) {
                newName = ""
                newPin = ""
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .tabSeparatedText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            guard let data = try? Data(contentsOf: url) else { return }
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            let parsed = ProductImport.parse(text)
            columns = parsed.columns
            imported = parsed.products
        }
        .sheet(item: Binding(get: { imported.map { ImportBatch(products: $0) } }, set: { if $0 == nil { imported = nil } })) { batch in
            ImportPreview(products: batch.products, columns: columns) { count in
                notice = count == 1 ? String(localized: "1 product imported.") : String(localized: "\(count) products imported.")
            }
        }
        .sheet(isPresented: $addingProduct) {
            ProductAddSheet()
        }
    }

    struct ImportBatch: Identifiable {
        let id = UUID()
        let products: [ImportedProduct]
    }
}

/// Check what was read from the file, then import it.
struct ImportPreview: View {
    let products: [ImportedProduct]
    let columns: [String: String]
    let onDone: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            List {
                if products.isEmpty {
                    ContentUnavailableView("No products found", systemImage: "doc.text.magnifyingglass",
                                           description: Text("The first row must name the columns, with at least a name column (Name, Description or Product) and a price."))
                } else {
                    Section {
                        ForEach(["name", "price", "cost", "barcode", "category", "vat", "stock"], id: \.self) { key in
                            if let found = columns[key] {
                                LabeledContent(ImportText.title(key), value: found)
                            }
                        }
                    } header: {
                        Text("Columns found")
                    }
                    Section {
                        ForEach(Array(products.prefix(50).enumerated()), id: \.offset) { _, product in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(product.name).font(.subheadline.weight(.semibold))
                                Text([product.sell.map { Money.format($0) }, product.barcode, product.category,
                                      product.stock.map { String(localized: "stock \($0.formatted())") }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if products.count > 50 {
                            Text("and \(products.count - 50) more").foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(products.count == 1 ? String(localized: "1 product") : String(localized: "\(products.count) products"))
                    }
                }
            }
            .navigationTitle("Import products")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        onDone(ProductImporting.apply(products, context: context))
                        dismiss()
                    }
                    .disabled(products.isEmpty)
                }
            }
        }
    }
}

enum ImportText {
    static func title(_ key: String) -> String {
        switch key {
        case "name": return String(localized: "Name")
        case "price": return String(localized: "Selling price")
        case "cost": return String(localized: "Cost")
        case "barcode": return String(localized: "Barcode")
        case "category": return String(localized: "Category")
        case "vat": return String(localized: "VAT")
        default: return String(localized: "Stock")
        }
    }
}

@MainActor
enum ProductImporting {
    /// Updates products already in the price list (same barcode, else same name) with the till price; adds the rest
    /// as till-only products (in the shop being viewed). Stock, when given, becomes a stock count.
    static func apply(_ products: [ImportedProduct], context: ModelContext) -> Int {
        var items = AppData.items(context)
        let shop = LiveSettings.shared.shop
        var done = 0
        for product in products {
            let code = product.barcode ?? ""
            let index = items.firstIndex { !code.isEmpty && $0.hasBarcode(code) }
                ?? items.firstIndex { TextTools.norm($0.name) == TextTools.norm(product.name) }
            var item: PriceItem
            if let index {
                item = items[index]
            } else {
                item = PriceItem(cat: (product.category ?? "").isEmpty ? "Other" : product.category!, name: product.name,
                                 price: product.cost ?? 0, shops: shop.isEmpty ? nil : [shop],
                                 till: TillInfo(tillOnly: true))
            }
            var info = item.till ?? TillInfo()
            if let sell = product.sell, sell > 0 { info.sell = sell }
            if let vat = product.vat { info.vat = vat == 0 ? nil : vat }
            if !code.isEmpty, !(info.barcodes ?? []).contains(code) { info.barcodes = (info.barcodes ?? []) + [code] }
            if index == nil { info.perPack = 1 }
            item.till = info.isEmpty ? nil : info
            AppData.save(item, in: context, logged: false)
            if let index { items[index] = item } else { items.append(item) }
            if let stock = product.stock, stock >= 0 {
                TillStore.shared.setCount(stock, itemID: item.id, name: item.name, shop: shop)
            }
            done += 1
        }
        try? context.save()
        Accounts.shared.changed(context)
        return done
    }
}

/// A product of your own (not on supplier invoices): name, price, what it costs you, barcode.
struct ProductAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var category = ""
    @State private var sell = ""
    @State private var cost = ""
    @State private var vat = 0.0
    @State private var barcode = ""
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Category, e.g. Drinks", text: $category)
                LabeledContent("Selling price") {
                    TextField(Money.format(0), text: $sell).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                LabeledContent("What one costs you") {
                    TextField(String(localized: "Not known"), text: $cost).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                Picker("VAT in the price", selection: $vat) {
                    Text("None").tag(0.0)
                    Text("5%").tag(5.0)
                    Text("20%").tag(20.0)
                }
                HStack {
                    TextField("Barcode", text: $barcode).keyboardType(.numberPad)
                    if BarcodeScanner.canScan {
                        Button {
                            scanning = true
                        } label: {
                            Image(systemName: "barcode.viewfinder")
                        }
                        .accessibilityLabel(Text("Scan a barcode"))
                    }
                }
            }
            .navigationTitle("Add a product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let shop = LiveSettings.shared.shop
                        let code = barcode.trimmingCharacters(in: .whitespaces)
                        let item = PriceItem(cat: category.trimmingCharacters(in: .whitespaces).isEmpty ? "Other" : category.trimmingCharacters(in: .whitespaces),
                                             name: name.trimmingCharacters(in: .whitespaces), price: Money.round2(Money.parse(cost) ?? 0),
                                             shops: shop.isEmpty ? nil : [shop],
                                             till: TillInfo(sell: Money.parse(sell).map { Money.round2($0) }, perPack: 1,
                                                            barcodes: code.isEmpty ? nil : [code], vat: vat == 0 ? nil : vat, tillOnly: true))
                        AppData.save(item, in: context, logged: false)
                        try? context.save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (Money.parse(sell) ?? 0) <= 0)
                }
            }
            .sheet(isPresented: $scanning) {
                BarcodeScanner { code in
                    barcode = code
                    scanning = false
                }
                .ignoresSafeArea()
            }
        }
    }
}
