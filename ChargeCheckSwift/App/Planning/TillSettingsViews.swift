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
    @State private var zPDF: URL?
    @AppStorage(SettingKey.colour) private var colourID = "green"
    @State private var approval: ApprovalRequest?
    @State private var closeBy: String?

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
                        if let zPDF {
                            ShareLink(item: zPDF) { Label("Share the PDF", systemImage: "doc.richtext") }
                        } else {
                            Button {
                                zPDF = AppFiles.write(TillPDF.day(closed, theme: Themes.inUse(colourID)), folder: "Exports", name: "Z\(closed.number).pdf")
                            } label: {
                                Label("Save as PDF", systemImage: "doc.richtext")
                            }
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
                        if let v = x.tab { LabeledContent("On account", value: Money.format(v)) }
                        if let v = x.gift { LabeledContent("Gift card", value: Money.format(v)) }
                        if let v = x.points { LabeledContent("Points", value: Money.format(v)) }
                        if let v = x.giftSold { LabeledContent("Gift cards sold", value: Money.format(v)) }
                        if x.refunds > 0 { LabeledContent("Refunds", value: "\(x.refunds)") }
                    } header: {
                        Text(x.from.isEmpty ? String(localized: "So far") : String(localized: "Since \(SalesText.time(x.from))"))
                    }
                    Section {
                        LabeledContent("Opening float", value: Money.format(x.float))
                        LabeledContent("Cash in", value: Money.format(x.paidIn))
                        LabeledContent("Cash out", value: Money.format(x.paidOut))
                        if let v = x.tabPaid { LabeledContent("Accounts paid off", value: Money.format(v)) }
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
                        Text(till.severalTills ? String(localized: "Till \(till.code)'s cash drawer") : String(localized: "The cash drawer"))
                    } footer: {
                        Text("Count the notes and coins, then close the day. The next day starts from now; the report is kept below.")
                    }
                    Section {
                        Button("Close the day", role: .destructive) {
                            Gate.check(.closeDay, String(localized: "Close the day"), request: $approval) { by in
                                closeBy = by
                                confirm = true
                            }
                        }
                    }
                }
                let past = till.days.filter { $0.shop == shop }.sorted { $0.to > $1.to }
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
                                LabeledContent("Z\(day.number) · " + (till.severalTills ? (day.till ?? "A") + " · " : "") + SalesText.time(day.to), value: Money.format(day.takings))
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
                    closed = till.closeDay(shop: shop, counted: Money.parse(counted), approvedBy: closeBy)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(till.severalTills ? String(localized: "Closes till \(till.code)'s drawer. Sales from now on go on its next day's report.")
                                       : String(localized: "Sales from now on go on the next day's report."))
            }
            .managerApproval($approval)
        }
    }
}

/// More › Till › Till settings: receipts, cashiers, your own products.
struct TillSettingsView: View {
    /// Shown in a sheet (with a Done button).
    var done = false
    /// A manager has just allowed it at the till.
    var preApproved = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @ObservedObject private var till = TillStore.shared
    @ObservedObject private var screen = CustomerScreenLink.shared
    @State private var unlocked = false
    @State private var approval: ApprovalRequest?
    @State private var newRole: TillRole = .cashier
    @State private var renaming = false
    @State private var newCode = ""
    @State private var syncing = false

    private var allowed: Bool {
        preApproved || unlocked || !till.hasManagers || (till.cashier?.role ?? .cashier).isManager
    }
    @AppStorage(Shops.listKey) private var shopData = Data()
    @State private var addingCashier = false
    @State private var newName = ""
    @State private var newPin = ""
    @State private var resettingID: String?
    @State private var resetPin = ""
    @State private var importing = false
    @State private var imported: [ImportedProduct]?
    @State private var columns: [String: String] = [:]
    @State private var addingProduct = false
    @State private var notice: String?

    var body: some View {
        Group {
            if allowed {
                settings
            } else {
                ContentUnavailableView {
                    Label("Managers only", systemImage: "lock")
                } description: {
                    Text("Only a manager or the owner can change the till settings.")
                } actions: {
                    Button("Unlock") {
                        approval = ApprovalRequest(title: String(localized: "Change the till settings"), deviceOwner: true) { _ in unlocked = true }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Till settings")
        .themedScreen()
        .managerApproval($approval)
        .toolbar {
            if done {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var settings: some View {
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
                    Picker(selection: Binding(get: { cashier.role ?? .cashier }, set: { till.setRole($0, for: cashier.id) })) {
                        ForEach(TillRole.allCases, id: \.self) { role in
                            Text(RoleText.title(role)).tag(role)
                        }
                    } label: {
                        Label(cashier.name, systemImage: (cashier.role ?? .cashier).isManager ? "person.badge.key" : "person.crop.circle")
                    }
                    .contextMenu {
                        Button {
                            resettingID = cashier.id
                        } label: {
                            Label("Reset PIN", systemImage: "key.horizontal")
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { till.removeCashier(till.cashiers[index].id) }
                }
                Button {
                    newRole = till.cashiers.isEmpty ? .owner : .cashier
                    addingCashier = true
                } label: {
                    Label("Add a person", systemImage: "person.badge.plus")
                }
                NavigationLink {
                    TillPermissionsView()
                } label: {
                    Label("What cashiers can do", systemImage: "lock.shield")
                }
                NavigationLink {
                    ShiftsView()
                } label: {
                    Label("Staff hours", systemImage: "clock")
                }
            } header: {
                Text("People")
            } footer: {
                Text(till.cashiers.isEmpty
                     ? String(localized: "With people added, the till asks for a 4-digit PIN and every sale shows who served. Make yourself the owner: refunds, discounts, taking cash out and closing the day then need a manager's PIN.")
                     : (till.hasManagers
                        ? String(localized: "Refunds, discounts, cash out and closing the day need a manager's or the owner's PIN unless cashiers are allowed. Swipe left to remove someone; touch and hold to reset their PIN.")
                        : String(localized: "Nobody is a manager or the owner yet, so cashiers can do everything. Tap a name to change their role.")))
            }

            thisTill

            Section {
                NavigationLink {
                    PrinterSettingsView()
                } label: {
                    LabeledContent {
                        Text(PrinterText.summary(ReceiptPrinter.shared.settings))
                    } label: {
                        Label("Receipt printer and cash drawer", systemImage: "printer")
                    }
                }
                Toggle(isOn: Binding(get: { screen.tillOffers }, set: { screen.tillOffers = $0 })) {
                    Label("Customer screen", systemImage: "person.crop.rectangle")
                }
                if screen.tillOffers {
                    Text(screen.connected.isEmpty
                         ? String(localized: "On the iPhone or iPad facing the customer: More › Till › Be the customer screen. They find each other on the shop's Wi-Fi or Bluetooth.")
                         : String(localized: "Showing on: \(screen.connected.joined(separator: ", "))"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Hardware")
            }

            Section {
                NavigationLink {
                    DealsView()
                } label: {
                    LabeledContent {
                        Text("\(till.options.deals.filter { $0.off != true }.count)")
                    } label: {
                        Label("Meal deals", systemImage: "takeoutbag.and.cup.and.straw")
                    }
                }
                NavigationLink {
                    VouchersView()
                } label: {
                    LabeledContent {
                        Text("\(till.options.vouchers.filter { $0.off != true }.count)")
                    } label: {
                        Label("Vouchers", systemImage: "ticket")
                    }
                }
                Picker(selection: Binding(get: { till.options.scaleCarries }, set: { till.options.scaleCarries = $0; till.saveSettings() })) {
                    Text("The price").tag(ScaleLabelValue.price)
                    Text("The weight").tag(ScaleLabelValue.weight)
                } label: {
                    Label("Scale labels carry", systemImage: "scalemass")
                }
                Toggle(isOn: Binding(get: { till.options.loyaltyOn }, set: { till.options.loyaltyOn = $0; till.saveSettings() })) {
                    Label("Loyalty points", systemImage: "star.circle")
                }
                if till.options.loyaltyOn {
                    Stepper(value: Binding(get: { till.options.loyalty.perPound }, set: { till.options.loyalty.perPound = $0; till.saveSettings() }), in: 0...20, step: 1) {
                        LabeledContent(String(localized: "Points for every \(Money.format(1))"), value: till.options.loyalty.perPound.formatted())
                    }
                    Stepper(value: Binding(get: { (till.options.loyalty.worth * 100).rounded() }, set: { till.options.loyalty.worth = $0 / 100; till.saveSettings() }), in: 1...100, step: 1) {
                        LabeledContent("100 points are worth", value: Money.format(till.options.loyalty.worth * 100))
                    }
                }
            } header: {
                Text("Selling")
            } footer: {
                Text("Scale labels: barcodes starting with 2 printed by your shop scale. Give the item the first 7 digits of its label as a barcode. Points are earned on what's paid with money or on account, and spent at the till like money.")
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
                Label("Taking cards on this iPhone (Tap to Pay) needs an account with a card company such as Stripe, SumUp or Square, and Apple's approval for ChargeCheck. Until then, use your own card machine and choose Card at the till.", systemImage: "creditcard")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: till.receipt) { till.saveSettings() }
        .alert("This till's letter", isPresented: $renaming) {
            TextField("B", text: $newCode).textInputAutocapitalization(.characters)
            Button("Save") {
                if !till.rename(newCode) { notice = String(localized: "That letter is taken, or this till has already saved sales under its letter.") }
                newCode = ""
            }
            Button("Cancel", role: .cancel) { newCode = "" }
        } message: {
            Text("One to three letters or numbers, different on every till. It's on every receipt number from this till.")
        }
        .alert(newRole == .owner ? String(localized: "Add yourself, the owner") : String(localized: "Add a person"), isPresented: $addingCashier) {
            TextField("Name", text: $newName)
            SecureField("4-digit PIN", text: $newPin)
                .keyboardType(.numberPad)
            Button("Add") {
                let pin = PinCredentials.normalized(newPin).filter(\.isNumber)
                let name = newName.trimmingCharacters(in: .whitespaces)
                if pin.count != 4 || name.isEmpty || !till.addCashier(name: name, pin: pin, role: newRole) {
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
        .alert("Reset PIN", isPresented: Binding(get: { resettingID != nil }, set: { if !$0 { resettingID = nil } })) {
            SecureField("New 4-digit PIN", text: $resetPin)
                .keyboardType(.numberPad)
            Button("Save") {
                let pin = PinCredentials.normalized(resetPin).filter(\.isNumber)
                if let id = resettingID, pin.count != 4 || !till.resetPin(for: id, to: pin) {
                    notice = String(localized: "Use a 4-digit PIN that no one else has.")
                }
                resetPin = ""
                resettingID = nil
            }
            Button("Cancel", role: .cancel) {
                resetPin = ""
                resettingID = nil
            }
        } message: {
            Text("Their old PIN stops working straight away.")
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

    @ViewBuilder
    private var thisTill: some View {
        Section {
            LabeledContent("This till") {
                Text(till.code.isEmpty ? String(localized: "Not used yet") : till.code).fontWeight(.semibold)
            }
            if till.canRename {
                Button("Change its letter") {
                    newCode = till.code
                    renaming = true
                }
            }
            Toggle("Extra till", isOn: Binding(get: { till.isExtraTill }, set: { till.isExtraTill = $0 }))
            if till.severalTills {
                LabeledContent("Tills", value: till.tills.sorted().joined(separator: ", "))
            }
            if let last = till.lastSync {
                LabeledContent("Up to date with the other tills", value: last.formatted(date: .omitted, time: .shortened))
            }
            Button {
                syncing = true
                Task {
                    await till.sync(context: context, full: true)
                    syncing = false
                }
            } label: {
                Label(syncing ? String(localized: "Getting every till's sales…") : String(localized: "Get every till's sales now"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(syncing || !CloudFolder.isOn)
        } header: {
            Text("Several tills")
        } footer: {
            Text(CloudFolder.isOn
                 ? String(localized: "Every iPhone or iPad with ChargeCheck on the same iCloud (or the same shared folder in Settings › iCloud backup) is a till with its own letter and cash drawer. They share sales, stock, customers and gift cards every half minute while the till is open. Extra till: it gets its products and prices from the main iPhone, and the main iPhone makes the supplier orders.")
                 : String(localized: "Several tills share their sales through iCloud. Turn on iCloud backup (Settings › iCloud backup) on every till first."))
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
        context.saveOrReport()
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
                        context.saveOrReport()
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

enum PrinterText {
    static func summary(_ settings: PrinterSettings) -> String {
        switch settings.kind {
        case .none: return String(localized: "None")
        case .bluetooth: return settings.bluetoothName ?? String(localized: "Bluetooth")
        case .network: return settings.host
        }
    }
}

/// Till settings › Receipt printer: a Bluetooth or network receipt printer, and the drawer plugged into it.
struct PrinterSettingsView: View {
    @ObservedObject private var printer = ReceiptPrinter.shared

    var body: some View {
        List {
            Section {
                Picker("Printer", selection: $printer.settings.kind) {
                    Text("None (AirPrint only)").tag(PrinterSettings.Kind.none)
                    Text("Bluetooth").tag(PrinterSettings.Kind.bluetooth)
                    Text("Network (Wi-Fi or cable)").tag(PrinterSettings.Kind.network)
                }
            } footer: {
                Text("Most small receipt printers work: Epson, Star and the Bluetooth ones that use ESC/POS. Receipts print as a picture, so Arabic and Kurdish print correctly.")
            }
            if printer.settings.kind == .bluetooth {
                Section {
                    if let name = printer.settings.bluetoothName {
                        LabeledContent("Chosen", value: name)
                    }
                    Button {
                        printer.startScan()
                    } label: {
                        Label(printer.scanning ? String(localized: "Looking…") : String(localized: "Find printers"), systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(printer.scanning)
                    ForEach(printer.found) { found in
                        Button {
                            printer.choose(found)
                        } label: {
                            HStack {
                                Text(found.name)
                                Spacer()
                                if printer.settings.bluetoothID == found.id.uuidString { Image(systemName: "checkmark") }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Bluetooth printer")
                } footer: {
                    Text("Turn the printer on and keep it close. Bluetooth printers that pair in the iPhone's Settings (older “classic” ones) can't be used by apps; choose a Bluetooth LE or network printer.")
                }
            }
            if printer.settings.kind == .network {
                Section {
                    TextField("IP address, e.g. 192.168.1.50", text: $printer.settings.host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("Port") {
                        TextField("9100", value: $printer.settings.port, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Network printer")
                } footer: {
                    Text("The printer's address is on its settings page: hold the feed button while turning it on.")
                }
            }
            if printer.settings.kind != .none {
                Section {
                    Picker("Paper", selection: $printer.settings.wide) {
                        Text("80 mm").tag(true)
                        Text("58 mm").tag(false)
                    }
                    Toggle("Print every receipt", isOn: $printer.settings.autoPrint)
                    Toggle("Open the drawer for cash", isOn: $printer.settings.drawer)
                    Button {
                        printer.testPrint()
                    } label: {
                        Label("Print a test receipt", systemImage: "printer")
                    }
                    .disabled(!printer.settings.isSet || printer.busy)
                    Button {
                        printer.openDrawer()
                    } label: {
                        Label("Open the drawer", systemImage: "tray")
                    }
                    .disabled(!printer.settings.isSet || printer.busy)
                    if let problem = printer.problem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text("The cash drawer plugs into the printer. It opens by itself when a sale is paid in cash. Opening it without a sale is logged in Records.")
                }
            }
        }
        .navigationTitle("Receipt printer")
        .themedScreen()
        .onDisappear { printer.stopScan() }
    }
}
