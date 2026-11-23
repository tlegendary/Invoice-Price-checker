import SwiftUI
import SwiftData
import ChargeCheckCore

// MARK: - Weighing

/// How much it weighs: typed from the scale (grams or kg). The price shows as it's typed.
struct WeightSheet: View {
    let item: PriceItem
    let onDone: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var kg: Double? { Weight.parse(text) }
    private var perKg: Double { item.till?.sell ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Grams, e.g. 450, or kg, e.g. 0.45"), text: $text)
                        .keyboardType(.decimalPad)
                        .font(.title2)
                        .focused($focused)
                    if let kg {
                        LabeledContent(Weight.text(kg)) {
                            Text(Money.format(Weight.price(kg: kg, perKg: perKg)))
                                .font(.title2.weight(.bold))
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    Text("\(Money.format(perKg)) a kg. A number without a point is grams.")
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { focused = true }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let kg { onDone(kg) }
                        dismiss()
                    }
                    .disabled(kg == nil)
                }
            }
        }
    }
}

// MARK: - Customers

/// Choose who's buying (for points, their account, an emailed receipt), or add them.
struct CustomerPicker: View {
    let onPick: (Customer) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var till = TillStore.shared
    @State private var search = ""
    @State private var adding = false

    private var shown: [Customer] {
        let q = TextTools.norm(search)
        guard !q.isEmpty else { return till.customers }
        let digits = search.filter(\.isNumber)
        return till.customers.filter {
            TextTools.norm($0.name).contains(q) || (!digits.isEmpty && $0.phone.filter(\.isNumber).contains(digits))
                || TextTools.norm($0.email).contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    adding = true
                } label: {
                    Label("New customer", systemImage: "person.badge.plus")
                }
                ForEach(shown) { customer in
                    Button {
                        onPick(customer)
                        dismiss()
                    } label: {
                        CustomerRow(customer: customer)
                    }
                    .foregroundStyle(.primary)
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Name or phone"))
            .navigationTitle("Customer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $adding) {
                CustomerEditor(customer: nil) { saved in
                    onPick(saved)
                    dismiss()
                }
            }
        }
    }
}

struct CustomerRow: View {
    let customer: Customer
    @ObservedObject private var till = TillStore.shared

    var body: some View {
        let balance = till.balance(customer)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(customer.name).font(.subheadline.weight(.semibold))
                Text([customer.phone, till.options.loyaltyOn ? String(localized: "\(balance.points) points") : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if abs(balance.tab) > 0.004 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Money.format(abs(balance.tab))).fontWeight(.semibold).monospacedDigit()
                        .foregroundStyle(balance.tab > 0 ? .orange : .green)
                    Text(balance.tab > 0 ? String(localized: "owed") : String(localized: "credit")).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct CustomerEditor: View {
    let customer: Customer?
    var onSave: (Customer) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var till = TillStore.shared
    @State private var name = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var note = ""
    @State private var tab = false
    @State private var limit = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Phone", text: $phone).keyboardType(.phonePad)
                TextField("Email, for receipts", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                TextField("Note", text: $note, axis: .vertical)
                Section {
                    Toggle("Can buy on account", isOn: $tab)
                    if tab {
                        LabeledContent("Most they can owe") {
                            TextField(Money.format(0), text: $limit).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                    }
                } footer: {
                    Text("On account: they take it now and pay later. The till won't let them owe more than this.")
                }
            }
            .navigationTitle(customer == nil ? String(localized: "New customer") : customer!.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard let customer else { return }
                name = customer.name
                phone = customer.phone
                email = customer.email
                note = customer.note
                tab = customer.tabLimit != nil
                limit = customer.tabLimit.map { String(format: "%.2f", $0) } ?? ""
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = customer ?? Customer(name: "", at: TillStore.now())
                        saved.name = name.trimmingCharacters(in: .whitespaces)
                        saved.phone = phone.trimmingCharacters(in: .whitespaces)
                        saved.email = email.trimmingCharacters(in: .whitespaces)
                        saved.note = note
                        saved.tabLimit = tab ? Money.round2(max(0, Money.parse(limit) ?? 0)) : nil
                        till.saveCustomer(saved)
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// Till › Customers: who owes what on account, points, and what they've bought.
struct CustomersView: View {
    @ObservedObject private var till = TillStore.shared
    @State private var search = ""
    @State private var adding = false

    var body: some View {
        let q = TextTools.norm(search)
        let shown = q.isEmpty ? till.customers : till.customers.filter { TextTools.norm($0.name + " " + $0.phone).contains(q) }
        let owed = Money.round2(till.customers.reduce(0) { $0 + max(0, till.balance($1).tab) })
        List {
            if owed > 0.004 {
                Section {
                    LabeledContent("Owed on accounts") {
                        Text(Money.format(owed)).fontWeight(.bold).foregroundStyle(.orange)
                    }
                }
            }
            Section {
                if till.customers.isEmpty {
                    Text("No customers yet. Add one here or at the till (Customer).").foregroundStyle(.secondary)
                }
                ForEach(shown) { customer in
                    NavigationLink {
                        CustomerDetail(id: customer.id)
                    } label: {
                        CustomerRow(customer: customer)
                    }
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Customers")
        .themedScreen()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    adding = true
                } label: {
                    Label("New customer", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $adding) { CustomerEditor(customer: nil) }
    }
}

struct CustomerDetail: View {
    let id: String
    @ObservedObject private var till = TillStore.shared
    @State private var editing = false
    @State private var paying = false
    @State private var payText = ""
    @State private var payCard = false
    @State private var approval: ApprovalRequest?
    @State private var opened: Sale?

    var body: some View {
        if let customer = till.customer(id) {
            let balance = till.balance(customer)
            let bought = till.sales.filter { $0.customer == id }
            List {
                Section {
                    if !customer.phone.isEmpty { LabeledContent("Phone", value: customer.phone) }
                    if !customer.email.isEmpty { LabeledContent("Email", value: customer.email) }
                    if !customer.note.isEmpty { Text(customer.note).font(.footnote) }
                    LabeledContent("Spent", value: Money.format(balance.spent))
                    LabeledContent("Visits", value: "\(balance.visits)")
                    if till.options.loyaltyOn {
                        LabeledContent("Points") {
                            Text("\(balance.points) · \(Money.format(CustomerMaths.worth(points: balance.points, loyalty: till.options.loyalty)))")
                        }
                    }
                }
                if customer.tabLimit != nil || abs(balance.tab) > 0.004 {
                    Section {
                        LabeledContent("Owed") {
                            Text(Money.format(balance.tab)).fontWeight(.bold).foregroundStyle(balance.tab > 0.004 ? .orange : .primary)
                        }
                        if let limit = customer.tabLimit { LabeledContent("Most they can owe", value: Money.format(limit)) }
                        if balance.tab > 0.004 {
                            Button {
                                payText = String(format: "%.2f", balance.tab)
                                paying = true
                            } label: {
                                Label("They're paying off their account", systemImage: "banknote")
                            }
                        }
                    } header: {
                        Text("Account")
                    }
                }
                Section("What they bought") {
                    if bought.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                    ForEach(bought.prefix(100)) { sale in
                        Button {
                            opened = sale
                        } label: {
                            LabeledContent(SalesText.time(sale.at) + " · #" + till.number(sale), value: Money.format(sale.total))
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle(customer.name)
            .themedScreen()
            .toolbar {
                Button("Edit") { editing = true }
            }
            .sheet(isPresented: $editing) { CustomerEditor(customer: customer) }
            .sheet(item: $opened) { SaleDetailView(sale: $0) }
            .managerApproval($approval)
            .alert("Paying off the account", isPresented: $paying) {
                TextField(Money.format(0), text: $payText).keyboardType(.decimalPad)
                Button("Cash") { pay(customer, card: false) }
                Button("Card") { pay(customer, card: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("How much are they paying? Cash goes in this till's drawer.")
            }
        } else {
            ContentUnavailableView("Customer not found", systemImage: "person.crop.circle.badge.questionmark")
        }
    }

    private func pay(_ customer: Customer, card: Bool) {
        guard let amount = Money.parse(payText), amount > 0 else { return }
        till.addCash(.tabPaid, amount: amount, note: customer.name, shop: LiveSettings.shared.shop, ref: customer.id, card: card ? true : nil)
    }
}

// MARK: - Gift cards

/// Till › Gift cards: every card sold, and what's left on it.
struct GiftCardsView: View {
    @ObservedObject private var till = TillStore.shared
    @State private var search = ""

    var body: some View {
        let cards = till.giftCards.filter { search.isEmpty || $0.code.contains(search.filter(\.isNumber)) }
        let outstanding = Money.round2(till.giftCards.reduce(0) { $0 + max(0, GiftCards.balance($1, sales: till.sales)) })
        let overspent = Overspends.find(cards: till.giftCards, sales: till.sales)
        List {
            if !overspent.isEmpty {
                // two tills spent the same card while offline: both sales are kept, the owner decides what to do
                Section {
                    ForEach(overspent) { o in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "Card \(o.code) went \(Money.format(o.over)) over"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.red)
                            Text(String(localized: "Sale at \(String(o.at.prefix(16)).replacingOccurrences(of: "T", with: " "))")
                                 + (o.till.map { " · " + String(localized: "till \($0)") } ?? ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Spent twice")
                } footer: {
                    Text("Two tills used the same gift card while they were offline. Both sales are kept; ask the customer to pay the difference, or write it off.")
                }
            }
            Section {
                LabeledContent("Still to be spent") {
                    Text(Money.format(outstanding)).fontWeight(.bold)
                }
            } footer: {
                Text("Money taken for gift cards isn't takings until the card is spent: it's owed to whoever holds the card.")
            }
            Section {
                if cards.isEmpty { Text("No gift cards sold yet. Sell one at the till: Sale › Sell a gift card.").foregroundStyle(.secondary) }
                ForEach(cards.sorted { $0.at > $1.at }) { card in
                    let left = GiftCards.balance(card, sales: till.sales)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.code).font(.subheadline.monospacedDigit().weight(.semibold))
                            Text(SalesText.time(card.at) + " · " + Shops.reportName(card.shop) + " · " + Money.format(card.amount))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Money.format(left)).fontWeight(.semibold).monospacedDigit()
                            .foregroundStyle(left > 0.004 ? .primary : .secondary)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: Text("Card number"))
        .navigationTitle("Gift cards")
        .themedScreen()
    }
}

// MARK: - Staff hours

/// Till › Staff hours: clock in and out, and the hours for this week and last.
struct ShiftsView: View {
    @ObservedObject private var till = TillStore.shared
    @State private var week = 0
    @State private var typing = false
    @State private var typed = ""

    private var range: (from: String, to: String) {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let start = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? calendar.startOfDay(for: Date())
        let from = calendar.date(byAdding: .day, value: -7 * week, to: start) ?? start
        let to = week == 0 ? Date() : (calendar.date(byAdding: .day, value: 7, to: from) ?? Date())
        let iso = ISO8601DateFormatter()
        return (iso.string(from: from), iso.string(from: to))
    }

    private var people: [String] {
        Array(Set(till.cashiers.map(\.name) + till.clock.map(\.person))).sorted()
    }

    var body: some View {
        let rows = Shifts.hours(till.clock, from: range.from, to: range.to)
        List {
            Section {
                ForEach(people, id: \.self) { person in
                    let isIn = till.isClockedIn(person)
                    HStack {
                        Label(person, systemImage: isIn ? "clock.badge.checkmark" : "clock")
                            .foregroundStyle(isIn ? Color.green : Color.primary)
                        Spacer()
                        Button(isIn ? String(localized: "Clock out") : String(localized: "Clock in")) {
                            till.punch(person, shop: LiveSettings.shared.shop, start: !isIn)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Button {
                    typing = true
                } label: {
                    Label("Someone else", systemImage: "person.badge.plus")
                }
            } header: {
                Text("Clock in and out")
            } footer: {
                Text("Cashiers can also clock in from the till menu after typing their PIN.")
            }
            Section {
                Picker("Week", selection: $week) {
                    Text("This week").tag(0)
                    Text("Last week").tag(1)
                }
                .pickerStyle(.segmented)
                if rows.isEmpty { Text("No hours yet.").foregroundStyle(.secondary) }
                ForEach(rows) { row in
                    LabeledContent(row.person) {
                        Text(String(localized: "\(row.hours.formatted(.number.precision(.fractionLength(0...2)))) h") + (row.inSince != nil ? " · " + String(localized: "in now") : ""))
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Hours")
            }
        }
        .navigationTitle("Staff hours")
        .themedScreen()
        .alert("Who's clocking in?", isPresented: $typing) {
            TextField("Name", text: $typed)
            Button("Clock in") {
                let name = typed.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { till.punch(name, shop: LiveSettings.shared.shop, start: true) }
                typed = ""
            }
            Button("Cancel", role: .cancel) { typed = "" }
        }
    }
}

// MARK: - Meal deals

/// Till settings › Meal deals: "sandwich + drink + snack for £4", taken off at the till by itself.
struct DealsView: View {
    @ObservedObject private var till = TillStore.shared
    @State private var editing: MealDeal?

    var body: some View {
        List {
            Section {
                ForEach(till.options.deals) { deal in
                    Button {
                        editing = deal
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(deal.name).font(.subheadline.weight(.semibold))
                                Text(deal.slots.map(\.name).joined(separator: " + ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Money.format(deal.price)).fontWeight(.semibold)
                            if deal.off == true { Text("Off").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    till.options.deals.remove(atOffsets: offsets)
                    till.saveSettings()
                }
                Button {
                    editing = MealDeal(name: String(localized: "Meal deal"), price: 0, slots: [DealSlot(name: String(localized: "Main")), DealSlot(name: String(localized: "Drink"))])
                } label: {
                    Label("Add a meal deal", systemImage: "plus.circle")
                }
            } footer: {
                Text("When everything in a deal is in the basket, the till charges the deal price, as many times as it fits, and only when it's cheaper for the customer.")
            }
        }
        .navigationTitle("Meal deals")
        .themedScreen()
        .sheet(item: $editing) { deal in
            DealEditor(deal: deal) { saved in
                if let index = till.options.deals.firstIndex(where: { $0.id == saved.id }) {
                    till.options.deals[index] = saved
                } else {
                    till.options.deals.append(saved)
                }
                till.saveSettings()
            }
        }
    }
}

struct DealEditor: View {
    let onSave: (MealDeal) -> Void
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \StoredPrice.name) private var prices: [StoredPrice]
    @State private var deal: MealDeal
    @State private var priceText: String
    @State private var pickingFor: Int?

    init(deal: MealDeal, onSave: @escaping (MealDeal) -> Void) {
        self.onSave = onSave
        _deal = State(initialValue: deal)
        _priceText = State(initialValue: deal.price > 0 ? String(format: "%.2f", deal.price) : "")
    }

    private var items: [PriceItem] { prices.map { $0.item }.filter { ($0.till?.sell ?? 0) > 0 } }
    private var categories: [String] { Array(Set(items.map { $0.cat.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $deal.name)
                    LabeledContent("Deal price") {
                        TextField(Money.format(0), text: $priceText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    Toggle("Turned on", isOn: Binding(get: { deal.off != true }, set: { deal.off = $0 ? nil : true }))
                }
                ForEach(Array(deal.slots.enumerated()), id: \.offset) { index, slot in
                    Section {
                        TextField("Part, e.g. Drink", text: Binding(get: { slot.name }, set: { value in change(index) { $0.name = value } }))
                        ForEach(categories, id: \.self) { cat in
                            Toggle(String(localized: "Anything in \(cat)"), isOn: Binding(
                                get: { slot.categories.contains(cat) },
                                set: { on in
                                    change(index) { part in
                                        part.categories.removeAll { $0 == cat }
                                        if on { part.categories.append(cat) }
                                    }
                                }))
                        }
                        ForEach(slot.items, id: \.self) { id in
                            Text(items.first { $0.id == id }?.name ?? id)
                        }
                        .onDelete { offsets in change(index) { $0.items.remove(atOffsets: offsets) } }
                        Button {
                            pickingFor = index
                        } label: {
                            Label("Add an item", systemImage: "plus")
                        }
                        if deal.slots.count > 2 {
                            Button("Remove this part", role: .destructive) {
                                DispatchQueue.main.async { if index < deal.slots.count { deal.slots.remove(at: index) } }
                            }
                        }
                    } header: {
                        Text(String(localized: "Part \(index + 1)"))
                    }
                }
                Button {
                    deal.slots.append(DealSlot(name: String(localized: "Snack")))
                } label: {
                    Label("Add a part", systemImage: "plus.circle")
                }
            }
            .navigationTitle(deal.name.isEmpty ? String(localized: "Meal deal") : deal.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        deal.price = Money.round2(Money.parse(priceText) ?? 0)
                        onSave(deal)
                        dismiss()
                    }
                    .disabled((Money.parse(priceText) ?? 0) <= 0 || deal.slots.contains { $0.items.isEmpty && $0.categories.isEmpty })
                }
            }
            .sheet(item: Binding(get: { pickingFor.map { SlotPick(index: $0) } }, set: { if $0 == nil { pickingFor = nil } })) { pick in
                ItemPicker(items: items, onPick: { item in
                    change(pick.index) { part in if !part.items.contains(item.id) { part.items.append(item.id) } }
                }, title: String(localized: "Add an item"))
            }
        }
    }

    /// Changes one part, if it's still there.
    private func change(_ index: Int, _ edit: (inout DealSlot) -> Void) {
        guard index < deal.slots.count else { return }
        edit(&deal.slots[index])
    }

    struct SlotPick: Identifiable {
        let index: Int
        var id: Int { index }
    }
}

// MARK: - Batches and expiry dates

/// Till › Expiry dates: batches running out of date, soonest first, and adding a batch as it comes in.
struct ExpiryView: View {
    @Query(sort: \StoredPrice.name) private var prices: [StoredPrice]
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @AppStorage(Shops.listKey) private var shopData = Data()
    @ObservedObject private var till = TillStore.shared
    @State private var adding = false
    @State private var showAll = false

    private var shop: String { TillShop.resolve(view: LiveSettings.shared.shop, shops: Shops.decode(shopData)) ?? "" }

    var body: some View {
        let items = prices.map { $0.item }.filter { $0.till?.batches == true && $0.isIn(shop: shop) }
        let levels = Dictionary(till.levels(items: items, shop: shop, invoices: reports.compactMap { $0.entry }).map { ($0.itemID, $0.onHand) },
                                uniquingKeysWith: { a, _ in a })
        let shelves = items.map { (name: $0.name, shelf: till.shelf(of: $0, shop: shop, onHand: levels[$0.id] ?? 0)) }
        let list = BatchMaths.expiring(shelves, within: showAll ? 100_000 : till.options.expiryDays)
        List {
            Section {
                Toggle("Show every batch", isOn: $showAll)
                Stepper(value: Binding(get: { till.options.expiryDays }, set: { till.options.expiryDays = $0; till.saveSettings() }), in: 1...365) {
                    LabeledContent("Warn this many days before", value: "\(till.options.expiryDays)")
                }
            }
            Section {
                if items.isEmpty {
                    Text("Turn on “Keep batches and expiry dates” for an item (price list › the item › Sell at the till), then add its batches here as they come in.")
                        .foregroundStyle(.secondary)
                } else if list.isEmpty {
                    Text("Nothing runs out of date in the next \(till.options.expiryDays) days.").foregroundStyle(.secondary)
                }
                ForEach(list) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.subheadline.weight(.semibold))
                            Text(String(localized: "Batch \(entry.batch.batch.code) · about \(entry.batch.left.formatted()) left"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(entry.batch.batch.expiry).monospacedDigit().fontWeight(.semibold)
                            Text(ExpiryText.days(entry.batch.days)).font(.caption2)
                                .foregroundStyle(entry.batch.days < 0 ? .red : (entry.batch.days <= 7 ? .orange : .secondary))
                        }
                    }
                    .swipeActions {
                        if entry.batch.batch.till == till.code || entry.batch.batch.till == nil {
                            Button("Delete", role: .destructive) { _ = till.removeBatch(entry.batch.batch.id) }
                        }
                    }
                }
            } footer: {
                if !items.isEmpty {
                    Text("What's left of each batch is worked out from the stock, assuming the shortest-dated ones are sold first. Expired batches show in red: take them off the shelf.")
                }
            }
        }
        .navigationTitle("Expiry dates")
        .themedScreen()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    adding = true
                } label: {
                    Label("Add a batch", systemImage: "plus")
                }
                .disabled(items.isEmpty)
            }
        }
        .sheet(isPresented: $adding) { BatchSheet(items: items, shop: shop) }
    }
}

enum ExpiryText {
    static func days(_ days: Int) -> String {
        if days < 0 { return String(localized: "expired \(-days) days ago") }
        if days == 0 { return String(localized: "expires today") }
        return String(localized: "in \(days) days")
    }
}

/// A batch coming in: which item, its batch (lot) number, use-by date, and how many.
struct BatchSheet: View {
    let items: [PriceItem]
    let shop: String
    var preset: PriceItem?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var till = TillStore.shared
    @State private var item: PriceItem?
    @State private var code = ""
    @State private var expiry = ""
    @State private var qty = ""
    @State private var picking = false

    private var parsedExpiry: String? { BatchMaths.parseExpiry(expiry) }

    var body: some View {
        NavigationStack {
            Form {
                Button {
                    picking = true
                } label: {
                    LabeledContent("Item", value: item?.name ?? String(localized: "Choose"))
                }
                .foregroundStyle(.primary)
                TextField("Batch or lot number", text: $code).textInputAutocapitalization(.characters)
                Section {
                    TextField("Use by, e.g. 03/2027 or 31/03/2027", text: $expiry)
                    if let parsedExpiry { LabeledContent("Expires", value: parsedExpiry) }
                }
                TextField("How many came in (single units)", text: $qty).keyboardType(.decimalPad)
            }
            .navigationTitle("Add a batch")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if item == nil { item = preset ?? (items.count == 1 ? items[0] : nil) } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let item, let parsedExpiry, let n = Double(qty.replacingOccurrences(of: ",", with: ".")), n > 0 else { return }
                        till.addBatch(itemID: item.id, name: item.name, shop: shop, code: code.trimmingCharacters(in: .whitespaces),
                                      expiry: parsedExpiry, qty: n)
                        dismiss()
                    }
                    .disabled(item == nil || parsedExpiry == nil || (Double(qty.replacingOccurrences(of: ",", with: ".")) ?? 0) <= 0
                              || code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $picking) {
                ItemPicker(items: items, onPick: { item = $0 }, title: String(localized: "Choose an item"))
            }
        }
    }
}

// MARK: - What cashiers may do

struct TillPermissionsView: View {
    @ObservedObject private var till = TillStore.shared

    var body: some View {
        List {
            Section {
                ForEach(TillPermission.allCases.filter { $0 != .settings }, id: \.self) { permission in
                    Toggle(PermissionText.title(permission), isOn: Binding(
                        get: { till.options.cashierPermissions.contains(permission) },
                        set: { on in
                            var set = till.options.cashierPermissions
                            if on { set.insert(permission) } else { set.remove(permission) }
                            till.options.cashierCan = set.map(\.rawValue).sorted()
                            till.saveSettings()
                        }))
                }
            } header: {
                Text("A cashier can do this alone")
            } footer: {
                Text(till.hasManagers
                     ? "Anything turned off needs a manager's or the owner's PIN at the till. Managers and the owner can do everything, and only they can change the till settings."
                     : "Nothing is locked until one person is a manager or the owner (Till settings › People).")
            }
        }
        .navigationTitle("What cashiers can do")
        .themedScreen()
    }
}
