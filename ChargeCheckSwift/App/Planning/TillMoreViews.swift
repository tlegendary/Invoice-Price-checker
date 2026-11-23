import SwiftUI
import SwiftData
import ChargeCheckCore

// MARK: - Options and variants at the till

/// Choosing an item's options: a size, add-ons. The price updates as they're picked.
struct OptionsSheet: View {
    let item: PriceItem
    let base: Double
    let onDone: ([OptionChoice]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: [String: [OptionChoice]] = [:]

    private var groups: [OptionGroup] { item.till?.options ?? [] }
    private var picked: [OptionChoice] { groups.flatMap { chosen[$0.id] ?? [] } }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.choices) { choice in
                            Button {
                                toggle(choice, in: group)
                            } label: {
                                HStack {
                                    Image(systemName: isOn(choice, in: group) ? (group.many ? "checkmark.square.fill" : "largecircle.fill.circle")
                                                                              : (group.many ? "square" : "circle"))
                                        .foregroundStyle(isOn(choice, in: group) ? Color.accentColor : Color.secondary)
                                    Text(choice.name)
                                    Spacer()
                                    if choice.price != 0 {
                                        Text((choice.price > 0 ? "+" : "−") + Money.format(abs(choice.price))).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    } header: {
                        Text(group.name)
                    } footer: {
                        if group.required { Text("Choose one.") }
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // a required single choice starts on its first option
                for group in groups where group.required && !group.many && chosen[group.id] == nil {
                    if let first = group.choices.first { chosen[group.id] = [first] }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Add · \(Money.format(ItemOptions.price(base: base, chosen: picked)))")) {
                        onDone(picked)
                        dismiss()
                    }
                    .disabled(!ItemOptions.complete(groups, chosen: chosen))
                }
            }
        }
    }

    private func isOn(_ choice: OptionChoice, in group: OptionGroup) -> Bool {
        (chosen[group.id] ?? []).contains(choice)
    }

    private func toggle(_ choice: OptionChoice, in group: OptionGroup) {
        var list = chosen[group.id] ?? []
        if list.contains(choice) {
            if !(group.required && !group.many) { list.removeAll { $0 == choice } }
        } else {
            list = group.many ? list + [choice] : [choice]
        }
        chosen[group.id] = list
    }
}

/// Which one: the sizes or colours of an item.
struct VariantSheet: View {
    let parent: PriceItem
    let variants: [PriceItem]
    let onPick: (PriceItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(variants) { item in
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onPick(item) }
                } label: {
                    HStack {
                        Text(item.name)
                        Spacer()
                        if let sell = item.till?.sell, sell > 0 {
                            Text(Money.format(sell)).fontWeight(.semibold).monospacedDigit()
                        } else {
                            Text("No price").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle(parent.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Layaways

/// The first deposit when goods are kept for a customer.
struct DepositSheet: View {
    let total: Double
    let customer: String
    let onDone: (Double, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var card = false

    private var amount: Double? {
        guard let value = Money.parse(text) else { return text.isEmpty ? 0 : nil }
        return value >= 0 && value <= total + 0.004 ? Money.round2(value) : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Total", value: Money.format(total))
                    LabeledContent("Deposit now") {
                        TextField(Money.format(0), text: $text).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    Picker("Paid by", selection: $card) {
                        Text("Cash").tag(false)
                        Text("Card").tag(true)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Kept for \(customer). It's sold, and comes off stock, when they collect it and it's paid off: Till › Layaways.")
                }
            }
            .navigationTitle("Layaway")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Keep it") {
                        if let amount { onDone(amount, card) }
                        dismiss()
                    }
                    .disabled(amount == nil)
                }
            }
        }
    }
}

/// Till › Layaways: what's kept for whom, paid so far, payments, collecting and cancelling.
struct LayawaysView: View {
    @Environment(\.modelContext) private var context
    @ObservedObject private var till = TillStore.shared
    @State private var showClosed = false
    @State private var paying: Layaway?
    @State private var payText = ""
    @State private var collecting: Layaway?
    @State private var cancelling: Layaway?
    @State private var approval: ApprovalRequest?
    @State private var done: Sale?

    var body: some View {
        let open = till.layaways.filter { $0.status == .open }
        let closed = till.layaways.filter { $0.status != .open }
        List {
            Section {
                if open.isEmpty {
                    Text("Nothing kept for anyone. At the till: Sale › Layaway, with a customer chosen.").foregroundStyle(.secondary)
                }
                ForEach(open) { layaway in row(layaway) }
            } header: {
                Text("Kept for customers")
            } footer: {
                if !open.isEmpty {
                    Text("Deposits are money held for the customer. The sale (takings, profit, stock) happens when they collect.")
                }
            }
            if !closed.isEmpty {
                Section {
                    Toggle("Show collected and cancelled", isOn: $showClosed)
                    if showClosed {
                        ForEach(closed) { layaway in
                            LabeledContent(name(layaway) + " · " + SalesText.time(layaway.updated),
                                           value: layaway.status == .collected ? String(localized: "Collected") : String(localized: "Cancelled"))
                        }
                    }
                }
            }
        }
        .navigationTitle("Layaways")
        .themedScreen()
        .managerApproval($approval)
        .sheet(item: $done) { ReceiptSheet(sale: $0) }
        .alert("Payment", isPresented: Binding(get: { paying != nil }, set: { if !$0 { paying = nil } }), presenting: paying) { layaway in
            TextField(Money.format(0), text: $payText).keyboardType(.decimalPad)
            Button("Cash") { pay(layaway, card: false) }
            Button("Card") { pay(layaway, card: true) }
            Button("Cancel", role: .cancel) { payText = "" }
        } message: { layaway in
            Text("\(Money.format(Layaways.left(layaway, events: till.cash))) left to pay.")
        }
        .confirmationDialog("Collect", isPresented: Binding(get: { collecting != nil }, set: { if !$0 { collecting = nil } }),
                            presenting: collecting) { layaway in
            let left = Layaways.left(layaway, events: till.cash)
            if left > 0.004 {
                Button(String(localized: "They pay the rest, \(Money.format(left)), in cash")) { collect(layaway, rest: .cash) }
                Button(String(localized: "They pay the rest, \(Money.format(left)), by card")) { collect(layaway, rest: .card) }
            } else {
                Button("They take it now") { collect(layaway, rest: .cash) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { layaway in
            Text("The goods come off stock and the sale is recorded now.")
        }
        .confirmationDialog("Cancel the layaway", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }),
                            presenting: cancelling) { layaway in
            let back = till.paid(layaway)
            if back > 0.004 {
                Button(String(localized: "Give back \(Money.format(back)) in cash"), role: .destructive) { cancel(layaway, card: false) }
                Button(String(localized: "Give back \(Money.format(back)) by card"), role: .destructive) { cancel(layaway, card: true) }
            } else {
                Button("Cancel it", role: .destructive) { cancel(layaway, card: false) }
            }
            Button("Keep it", role: .cancel) {}
        }
    }

    private func name(_ layaway: Layaway) -> String {
        till.customer(layaway.customer)?.name ?? String(localized: "Customer")
    }

    private func row(_ layaway: Layaway) -> some View {
        let paid = till.paid(layaway)
        let left = Layaways.left(layaway, events: till.cash)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name(layaway)).font(.subheadline.weight(.semibold))
                Spacer()
                Text(Money.format(layaway.total)).fontWeight(.semibold).monospacedDigit()
            }
            Text(layaway.lines.map { ($0.qty == 1 ? "" : "\($0.qty.formatted()) × ") + $0.name }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text(String(localized: "Paid \(Money.format(paid)) · \(Money.format(left)) left") + " · " + SalesText.time(layaway.at))
                    .font(.caption).monospacedDigit()
                Spacer()
            }
            HStack {
                if left > 0.004 {
                    Button("Payment") {
                        payText = String(format: "%.2f", left)
                        paying = layaway
                    }
                    .buttonStyle(.bordered)
                }
                Button("Collect") { collecting = layaway }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Cancel", role: .destructive) {
                    Gate.check(.refund, String(localized: "Cancel the layaway"), request: $approval) { _ in cancelling = layaway }
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func pay(_ layaway: Layaway, card: Bool) {
        guard let amount = Money.parse(payText), amount > 0 else { return }
        till.pay(layaway, amount: min(Money.round2(amount), Layaways.left(layaway, events: till.cash)), card: card)
        payText = ""
    }

    private func collect(_ layaway: Layaway, rest: PaymentKind) {
        done = till.collect(layaway, rest: rest, context: context)
    }

    private func cancel(_ layaway: Layaway, card: Bool) {
        till.cancel(layaway, card: card, approvedBy: nil)
    }
}

// MARK: - Vouchers

/// Till settings › Vouchers: money-off codes the till accepts.
struct VouchersView: View {
    @ObservedObject private var till = TillStore.shared
    @State private var editing: Voucher?
    @State private var isNew = false

    var body: some View {
        List {
            Section {
                ForEach(till.options.vouchers) { voucher in
                    Button {
                        isNew = false
                        editing = voucher
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(voucher.code).font(.subheadline.monospaced().weight(.semibold))
                                Text(VoucherText.describe(voucher, used: Vouchers.used(voucher.code, sales: till.sales)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if voucher.off == true { Text("Off").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    till.options.vouchers.remove(atOffsets: offsets)
                    till.saveSettings()
                }
                Button {
                    isNew = true
                    editing = Voucher(code: "", percent: true, value: 10)
                } label: {
                    Label("Add a voucher", systemImage: "plus.circle")
                }
            } footer: {
                Text("At the till: Sale › Voucher, and type the code. The money off is shared over the items, so profit and VAT stay right.")
            }
        }
        .navigationTitle("Vouchers")
        .themedScreen()
        .sheet(item: $editing) { voucher in
            VoucherEditor(voucher: voucher, isNew: isNew) { saved in
                if let index = till.options.vouchers.firstIndex(where: { Vouchers.normal($0.code) == Vouchers.normal(voucher.code) }), !isNew {
                    till.options.vouchers[index] = saved
                } else {
                    till.options.vouchers.append(saved)
                }
                till.saveSettings()
            }
        }
    }
}

enum VoucherText {
    static func describe(_ voucher: Voucher, used: Int) -> String {
        var parts = [voucher.percent ? String(localized: "\(voucher.value.formatted())% off") : String(localized: "\(Money.format(voucher.value)) off")]
        if let min = voucher.minSpend { parts.append(String(localized: "on \(Money.format(min)) or more")) }
        if let expiry = voucher.expiry { parts.append(String(localized: "until \(expiry)")) }
        parts.append(voucher.uses.map { String(localized: "used \(used) of \($0)") } ?? String(localized: "used \(used) times"))
        return parts.joined(separator: " · ")
    }
}

struct VoucherEditor: View {
    let isNew: Bool
    let onSave: (Voucher) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var till = TillStore.shared
    @State private var code: String
    @State private var percent: Bool
    @State private var value: String
    @State private var minSpend: String
    @State private var expiry: String
    @State private var uses: String
    @State private var on: Bool

    init(voucher: Voucher, isNew: Bool, onSave: @escaping (Voucher) -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        _code = State(initialValue: voucher.code)
        _percent = State(initialValue: voucher.percent)
        _value = State(initialValue: voucher.value > 0 ? voucher.value.formatted() : "")
        _minSpend = State(initialValue: voucher.minSpend.map { String(format: "%.2f", $0) } ?? "")
        _expiry = State(initialValue: voucher.expiry ?? "")
        _uses = State(initialValue: voucher.uses.map(String.init) ?? "")
        _on = State(initialValue: voucher.off != true)
    }

    private var clean: String { Vouchers.normal(code) }
    private var taken: Bool { isNew && till.options.vouchers.contains { Vouchers.normal($0.code) == clean } }
    private var amount: Double? { Money.parse(value).flatMap { $0 > 0 && (!percent || $0 <= 100) ? $0 : nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Code, e.g. SAVE10", text: $code)
                        .textInputAutocapitalization(.characters)
                        .disabled(!isNew)
                    if taken { Text("There's already a voucher with this code.").font(.footnote).foregroundStyle(.red) }
                    Picker("Money off", selection: $percent) {
                        Text("%").tag(true)
                        Text("Amount").tag(false)
                    }
                    .pickerStyle(.segmented)
                    TextField(percent ? "10" : Money.format(5), text: $value).keyboardType(.decimalPad)
                }
                Section {
                    LabeledContent("Only on a sale of at least") {
                        TextField(String(localized: "Any"), text: $minSpend).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Last day") {
                        TextField("31/12/2026", text: $expiry).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Times it can be used") {
                        TextField(String(localized: "No limit"), text: $uses).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    Toggle("Turned on", isOn: $on)
                }
            }
            .navigationTitle(isNew ? String(localized: "New voucher") : clean)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let amount else { return }
                        let date = expiry.trimmingCharacters(in: .whitespaces).isEmpty ? nil : BatchMaths.parseExpiry(expiry)
                        onSave(Voucher(code: clean, percent: percent, value: amount, minSpend: Money.parse(minSpend).map { Money.round2($0) },
                                       expiry: date, uses: Int(uses.filter(\.isNumber)), off: on ? nil : true))
                        dismiss()
                    }
                    .disabled(clean.isEmpty || taken || amount == nil
                              || (!expiry.trimmingCharacters(in: .whitespaces).isEmpty && BatchMaths.parseExpiry(expiry) == nil))
                }
            }
        }
    }
}

// MARK: - Moving stock between shops

/// Stock › Move stock: units taken off one shop's stock and added to another's.
struct MoveStockSheet: View {
    let items: [PriceItem]
    let from: String
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @AppStorage(Shops.listKey) private var shopData = Data()
    @ObservedObject private var till = TillStore.shared
    @State private var item: PriceItem?
    @State private var to = ""
    @State private var qty = ""
    @State private var picking = false

    private var shops: [ShopInfo] { Shops.decode(shopData).filter { $0.id != from } }
    private var units: Double? { Double(qty.replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("From", value: Shops.reportName(from))
                Picker("To", selection: $to) {
                    Text("Choose").tag("")
                    ForEach(shops, id: \.id) { shop in Text(shop.name).tag(shop.id) }
                }
                Button {
                    picking = true
                } label: {
                    LabeledContent("Item", value: item?.name ?? String(localized: "Choose"))
                }
                .foregroundStyle(.primary)
                TextField(item?.isByWeight == true ? String(localized: "How many kg") : String(localized: "How many (single units)"), text: $qty)
                    .keyboardType(.decimalPad)
            }
            .navigationTitle("Move stock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        guard let item, let units, !to.isEmpty else { return }
                        till.move(units, of: item, from: from, to: to, invoices: reports.compactMap { $0.entry })
                        dismiss()
                    }
                    .disabled(item == nil || units == nil || to.isEmpty)
                }
            }
            .sheet(isPresented: $picking) {
                ItemPicker(items: items, onPick: { item = $0 }, title: String(localized: "Choose an item"))
            }
        }
    }
}

// MARK: - Item options and variants in the item editor

/// Price list › an item › Sell at the till › Options: sizes and add-ons.
struct OptionsEditor: View {
    @Binding var groups: [OptionGroup]
    @State private var adding = false

    var body: some View {
        List {
            ForEach($groups) { $group in
                Section {
                    TextField("Name, e.g. Size", text: $group.name)
                    Toggle("Must choose one", isOn: $group.required)
                    Toggle("Can choose several", isOn: $group.many)
                    ForEach($group.choices) { $choice in
                        HStack {
                            TextField("Choice", text: $choice.name)
                            TextField("+0.00", value: $choice.price, format: .number.precision(.fractionLength(2)))
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                        }
                    }
                    .onDelete { group.choices.remove(atOffsets: $0) }
                    Button {
                        group.choices.append(OptionChoice(name: String(localized: "New choice \(group.choices.count + 1)")))
                    } label: {
                        Label("Add a choice", systemImage: "plus")
                    }
                } header: {
                    Text(group.name.isEmpty ? String(localized: "Option") : group.name)
                }
            }
            .onDelete { groups.remove(atOffsets: $0) }
            Button {
                groups.append(OptionGroup(name: String(localized: "Size"), choices: [OptionChoice(name: String(localized: "Small")),
                                                                                   OptionChoice(name: String(localized: "Large"), price: 0.5)],
                                          required: true))
            } label: {
                Label("Add a size", systemImage: "plus.circle")
            }
            Button {
                groups.append(OptionGroup(name: String(localized: "Add-ons"), choices: [OptionChoice(name: String(localized: "Extra"), price: 0.5)],
                                          many: true))
            } label: {
                Label("Add add-ons", systemImage: "plus.circle")
            }
        }
        .navigationTitle("Options")
        .themedScreen()
    }
}

// MARK: - PDF exports of the till's reports

enum TillPDF {
    /// Sales and profit for a period, with the best sellers.
    @MainActor
    static func sales(_ sales: [Sale], period: String, items: [PriceItem], theme: AppTheme) -> Data {
        let summary = SaleMaths.summary(sales)
        return PDFMaker.make(title: "Sales and profit", subtitle: period + " · " + Shops.reportName(), theme: theme) { page in
            page.heading(L("Summary"))
            page.pair(L("Takings"), Money.format(summary.takings), bold: true)
            page.pair(L("Sales"), "\(summary.sales)")
            page.pair(L("Refunds"), "\(summary.refunds)")
            page.pair(L("VAT"), Money.format(summary.vat))
            page.pair(L("Profit"), Money.format(summary.profit), bold: true)
            if summary.unknownCost > 0 { page.paragraph(String(localized: "\(summary.unknownCost) lines had no cost and are left out of the profit."), size: 9) }
            for kind in PaymentKind.allCases {
                if let value = summary.byPayment[kind], abs(value) > 0.004 { page.pair(SaleMaths.payName(kind), Money.format(value)) }
            }
            if summary.giftSold > 0 { page.pair(L("Gift cards sold"), Money.format(summary.giftSold)) }
            let money: (Double?) -> String = { $0.map { Money.format($0) } ?? "–" }
            page.heading(L("Best sellers"))
            page.table(headers: [L("Item"), L("Sold"), L("Takings"), L("Profit")], widths: [5, 1.5, 2, 2], right: [1, 2, 3],
                       rows: SalesReports.byItem(sales).prefix(60).map { [$0.name, $0.qty.formatted(), Money.format($0.takings), money($0.profit)] })
            page.heading(L("By hour"))
            page.table(headers: [L("Hour"), L("Sold"), L("Takings")], widths: [3, 2, 2], right: [1, 2],
                       rows: SalesReports.byHour(sales).map { [$0.name, $0.qty.formatted(), Money.format($0.takings)] })
            page.heading(L("By cashier"))
            page.table(headers: [L("Cashier"), L("Sold"), L("Takings")], widths: [4, 2, 2], right: [1, 2],
                       rows: SalesReports.byCashier(sales, nobody: L("No cashier")).map { [$0.name, $0.qty.formatted(), Money.format($0.takings)] })
        }
    }

    /// An end-of-day (Z) report.
    @MainActor
    static func day(_ report: DayReport, theme: AppTheme) -> Data {
        let text = CashDay.text(report, shopName: Shops.reportName(report.shop), currency: Money.currency.code)
        return PDFMaker.make(title: "End of day", subtitle: "Z\(report.number) · " + SalesText.time(report.to), theme: theme) { page in
            for line in text.components(separatedBy: "\n") { page.paragraph(line, size: 11) }
        }
    }
}
