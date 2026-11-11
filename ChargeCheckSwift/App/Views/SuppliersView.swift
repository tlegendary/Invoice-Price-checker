import SwiftUI
import SwiftData
import PhotosUI
import ChargeCheckCore

/// Every supplier: what you owe them, what you paid this week, and their trusted setting.
struct SuppliersView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @ObservedObject private var accounts = Accounts.shared
    @AppStorage(WeeklyPayReminder.dayKey) private var payDay = 0
    @State private var showAdd = false
    @State private var showPayRun = false
    @State private var paying: SupplierAccount?
    @State private var notice: String?
    @State private var path = NavigationPath()

    private var list: [SupplierAccount] {
        SupplierAccounts.accounts(entries: reports.compactMap { $0.entry }, payments: accounts.payments, trusted: accounts.trusted)
    }

    var body: some View {
        NavigationStack(path: $path) {
            let all = list
            let owed = Money.round2(all.filter { $0.balance > 0.005 }.reduce(0) { $0 + $1.balance })
            let thisWeek = Money.round2(all.reduce(0) { $0 + $1.paidThisWeek })
            List {
                if all.isEmpty {
                    ContentUnavailableView {
                        Label("No suppliers yet", systemImage: "shippingbox")
                    } description: {
                        Text("Suppliers appear here when you check their invoices. Add one with + to record a starting balance or make them trusted.")
                    }
                } else {
                    Section {
                        LabeledContent("You owe") {
                            Text(Money.format(owed))
                                .font(.title2.weight(.heavy))
                                .foregroundStyle(.tint)
                        }
                        LabeledContent("Paid this week", value: Money.format(thisWeek))
                    }
                    Section {
                        ForEach(all) { account in
                            NavigationLink(value: account.id) {
                                SupplierRow(account: account)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    paying = account
                                } label: {
                                    Label("Pay", systemImage: "banknote")
                                }
                                .tint(.green)
                            }
                        }
                    } header: {
                        Text("Suppliers")
                    } footer: {
                        Text("Swipe left on a supplier to record a payment. Balance = their invoices (less overcharges and missing items) − your payments and credit notes.")
                    }
                    let tips = Insights.supplierTips(reports.compactMap { $0.entry })
                    if !tips.isEmpty {
                        Section {
                            ForEach(tips.prefix(2)) { tip in
                                SupplierTipRow(tip: tip)
                            }
                            if tips.count > 2 {
                                NavigationLink {
                                    SupplierTipsView(tips: tips)
                                } label: {
                                    Text("See all \(tips.count) cheaper items")
                                }
                            }
                        } header: {
                            Label("Cheaper elsewhere", systemImage: "tag")
                        }
                    }
                    if owed > 0.005 {
                        Section {
                            Button {
                                showPayRun = true
                            } label: {
                                Label("Pay run: pay several suppliers at once", systemImage: "list.bullet.rectangle")
                            }
                        }
                    }
                }
                Section {
                    Picker("Weekly payment day", selection: Binding(get: { payDay }, set: { day in
                        payDay = day
                        Task {
                            if !(await WeeklyPayReminder.set(day)) {
                                payDay = 0
                                notice = String(localized: "Notifications are turned off for ChargeCheck. Turn them on in the Settings app to get the reminder.")
                            }
                        }
                    })) {
                        Text("Off").tag(0)
                        ForEach(1...7, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                } footer: {
                    Text("A reminder at 9am on the day you pay your suppliers.")
                }
            }
            .navigationTitle("Suppliers")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add a supplier", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: String.self) { key in
                SupplierDetailView(key: key)
            }
            .navigationDestination(for: ReportLink.self) { link in
                ReportDetailView(reportID: link.id)
            }
            .sheet(isPresented: $showAdd) {
                AddSupplierView()
            }
            .sheet(isPresented: $showPayRun) {
                PayRunView(accounts: list)
            }
            .sheet(item: $paying) { account in
                RecordPaymentView(supplier: account.name, kind: .payment, suggested: max(0, account.balance))
            }
            .task {
                // the cloud check opens the first supplier with "-demoSupplier YES"
                if UserDefaults.standard.bool(forKey: "demoSupplier"), let first = list.first { path.append(first.id) }
            }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }
}

/// Opens a saved invoice from the Suppliers tab.
struct ReportLink: Hashable {
    let id: String
}

struct SupplierRow: View {
    let account: SupplierAccount

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if account.trusted {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .accessibilityLabel("Trusted")
                    }
                }
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(Money.format(account.balance))
                .fontWeight(.bold)
                .foregroundStyle(account.balance > 0.005 ? Color.primary : Color.green)
        }
    }

    private var detail: String {
        var parts: [String] = []
        let open = account.open.count
        if open > 0 {
            parts.append(open == 1 ? String(localized: "1 invoice to pay") : String(localized: "\(open) invoices to pay"))
        } else if account.balance <= 0.005 {
            parts.append(String(localized: "nothing owed"))
        }
        if let last = account.lastPayment {
            parts.append(String(localized: "last paid \(Money.format(last.amount)) on \(PayDates.show(last.date))"))
        }
        return parts.joined(separator: " · ")
    }
}

enum PayDates {
    /// "2026-11-04" → "4 Nov 2026" in the phone's language.
    static func show(_ text: String) -> String {
        guard let date = SupplierAccounts.day(text) else { return text }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// One supplier's account: balance, what's still open, payments, and the trusted switch.
struct SupplierDetailView: View {
    let key: String

    @Environment(\.modelContext) private var context
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @ObservedObject private var accounts = Accounts.shared
    @State private var addKind: SupplierPayment.Kind?
    @State private var showPayInvoices = false
    @State private var copied = false

    private var account: SupplierAccount? {
        SupplierAccounts.accounts(entries: reports.compactMap { $0.entry }, payments: accounts.payments, trusted: accounts.trusted)
            .first { $0.id == key }
    }

    var body: some View {
        Group {
            if let account {
                List {
                    Section {
                        LabeledContent("You owe") {
                            Text(Money.format(account.balance))
                                .font(.title.weight(.heavy))
                                .foregroundStyle(account.balance > 0.005 ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.green))
                        }
                        if account.opening != 0 { LabeledContent("Starting balance", value: Money.format(account.opening)) }
                        LabeledContent("Invoices", value: Money.format(account.invoiced))
                        if account.settledOutside > 0.005 {
                            LabeledContent("Marked paid before", value: "−" + Money.format(account.settledOutside))
                        }
                        LabeledContent("Payments", value: "−" + Money.format(account.paid))
                        if account.credits > 0.005 { LabeledContent("Credit notes", value: "−" + Money.format(account.credits)) }
                        LabeledContent("Paid this week", value: Money.format(account.paidThisWeek))
                    } footer: {
                        if account.balance < -0.005 {
                            Text("You've paid \(Money.format(-account.balance)) more than they invoiced. It comes off their next invoices.")
                        }
                    }

                    Section {
                        Button {
                            addKind = .payment
                        } label: {
                            Label("Record a payment", systemImage: "banknote")
                        }
                        if !account.open.isEmpty {
                            Button {
                                showPayInvoices = true
                            } label: {
                                Label("Pay invoices one by one", systemImage: "checklist")
                            }
                        }
                        Button {
                            addKind = .credit
                        } label: {
                            Label("Add a credit note", systemImage: "arrow.uturn.backward.circle")
                        }
                        Button {
                            addKind = .opening
                        } label: {
                            Label("Add an older amount owed", systemImage: "plus.circle")
                        }
                        Button {
                            UIPasteboard.general.string = statement(account)
                            copied = true
                        } label: {
                            Label(copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy statement"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    } footer: {
                        Text("Record any amount you paid towards the balance; it pays off the oldest invoices first. Or tick the exact invoices a payment covers.")
                    }

                    Section {
                        Toggle("Trusted supplier", isOn: Binding(
                            get: { account.trusted },
                            set: { accounts.setTrusted(account.name, $0, context: context) }
                        ))
                    } footer: {
                        Text("Invoices from a trusted supplier aren't price-checked. Scanning one just reads the total and adds it to what you owe them.")
                    }

                    if !account.open.isEmpty {
                        Section("Still to pay") {
                            ForEach(account.open) { entry in
                                NavigationLink(value: ReportLink(id: entry.id)) {
                                    InvoiceMoneyRow(entry: entry)
                                }
                            }
                        }
                    }

                    let shown = account.payments.filter { $0.amount > 0.005 }
                    if !shown.isEmpty {
                        Section {
                            ForEach(shown) { payment in
                                PaymentRow(payment: payment)
                            }
                            .onDelete { offsets in
                                let ids = offsets.map { shown[$0].id }
                                for id in ids { accounts.remove(id, context: context) }
                            }
                        } header: {
                            Text("Payments and credits")
                        } footer: {
                            Text("Swipe left on one to remove it.")
                        }
                    }

                    let paidOff = account.entries.filter { entry in !account.open.contains(where: { $0.id == entry.id }) }
                    if !paidOff.isEmpty {
                        Section("Paid invoices") {
                            ForEach(paidOff.prefix(30)) { entry in
                                NavigationLink(value: ReportLink(id: entry.id)) {
                                    InvoiceMoneyRow(entry: entry)
                                }
                            }
                        }
                    }
                }
                .navigationTitle(account.name)
                .sheet(item: $addKind) { kind in
                    RecordPaymentView(supplier: account.name, kind: kind, suggested: max(0, account.balance))
                }
                .sheet(isPresented: $showPayInvoices) {
                    PayInvoicesView(supplier: account.name, open: account.open)
                }
            } else {
                ContentUnavailableView("Supplier removed", systemImage: "shippingbox")
            }
        }
    }

    private func statement(_ account: SupplierAccount) -> String {
        let today = Date().formatted(date: .abbreviated, time: .omitted)
        var lines = [String(localized: "Statement – \(account.name) – \(today)"), ""]
        for entry in account.open.reversed() {
            let number = entry.invNo.isEmpty ? L("Invoice") : String(localized: "Invoice \(entry.invNo)")
            lines.append("• " + number + (entry.date.isEmpty ? "" : " · " + entry.date) + " · " + Money.format(entry.amountToPay.pay))
        }
        if let last = account.lastPayment {
            lines.append("")
            lines.append(String(localized: "Last payment: \(Money.format(last.amount)) on \(PayDates.show(last.date))"))
        }
        lines.append(String(localized: "Balance owed: \(Money.format(account.balance))"))
        return lines.joined(separator: "\n")
    }
}

extension SupplierPayment.Kind: Identifiable {
    public var id: String { rawValue }
}

struct InvoiceMoneyRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.invNo.isEmpty ? L("Invoice") : String(localized: "Invoice \(entry.invNo)"))
                    .font(.subheadline.weight(.semibold))
                Text([entry.date, entry.totalOnly ? String(localized: "total only") : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Money.format(entry.amountToPay.pay))
                .fontWeight(.semibold)
        }
    }
}

struct PaymentRow: View {
    let payment: SupplierPayment
    @State private var showReceipt = false

    var body: some View {
        HStack {
            if payment.kind == .payment {
                Image(systemName: PayMethod.icon(payment.method))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text([PayDates.show(payment.date), PayMethod.name(payment.method), payment.reference, payment.note]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if payment.receipt != nil {
                Button {
                    showReceipt = true
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Show the receipt")
            }
            Text((payment.kind == .opening ? "+" : "−") + Money.format(payment.amount))
                .fontWeight(.semibold)
                .foregroundStyle(payment.kind == .opening ? Color.primary : Color.green)
        }
        .sheet(isPresented: $showReceipt) {
            ReceiptView(payment: payment)
        }
    }

    private var title: String {
        switch payment.kind {
        case .payment:
            let count = payment.invoiceIDs.count
            if count == 0 { return String(localized: "Payment") }
            return count == 1 ? String(localized: "Payment for 1 invoice") : String(localized: "Payment for \(count) invoices")
        case .credit: return String(localized: "Credit note")
        case .opening: return String(localized: "Starting balance")
        }
    }
}

/// How a payment was made, in words.
enum PayMethod {
    static func name(_ code: String) -> String {
        switch code {
        case "transfer": return String(localized: "Bank transfer")
        case "cash": return String(localized: "Cash")
        case "card": return String(localized: "Card")
        case "cheque": return String(localized: "Cheque")
        default: return ""
        }
    }

    static func icon(_ code: String) -> String {
        switch code {
        case "transfer": return "building.columns"
        case "cash": return "banknote"
        case "card": return "creditcard"
        case "cheque": return "doc.plaintext"
        default: return "sterlingsign.circle"
        }
    }
}

/// How it was paid, the reference, and a photo of the receipt.
struct PaymentExtras: View {
    @Binding var method: String
    @Binding var reference: String
    @Binding var receipt: UIImage?
    @State private var picked: PhotosPickerItem?

    var body: some View {
        Picker("Paid by", selection: $method) {
            ForEach(SupplierPayment.methods, id: \.self) { code in
                Text(PayMethod.name(code)).tag(code)
            }
        }
        if method == "transfer" || method == "cheque" || method == "card" {
            TextField(method == "cheque" ? LocalizedStringKey("Cheque number (optional)") : LocalizedStringKey("Reference (optional)"),
                      text: $reference)
                .textInputAutocapitalization(.characters)
        }
        PhotosPicker(selection: $picked, matching: .images) {
            Label(receipt == nil ? LocalizedStringKey("Add a photo of the receipt") : LocalizedStringKey("Change the receipt photo"),
                  systemImage: "paperclip")
        }
        .onChange(of: picked) {
            guard let picked else { return }
            Task {
                if let data = try? await picked.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    receipt = image
                }
                self.picked = nil
            }
        }
        if let receipt {
            HStack {
                Image(uiImage: receipt)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Receipt attached")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    self.receipt = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove the receipt")
            }
        }
    }
}

/// Type in a payment, credit note or starting balance.
struct RecordPaymentView: View {
    let supplier: String
    let kind: SupplierPayment.Kind
    let suggested: Double

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage("pay.lastMethod") private var lastMethod = "transfer"
    @State private var amountText = ""
    @State private var date = Date()
    @State private var note = ""
    @State private var method = ""
    @State private var reference = ""
    @State private var receipt: UIImage?

    private var amount: Double? {
        guard let value = Money.parse(amountText), value > 0, value < 1_000_000_000 else { return nil }
        return Money.round2(value)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(Money.currency.symbol)
                            .foregroundStyle(.secondary)
                        TextField("Amount", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.title2.weight(.semibold))
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                } header: {
                    Text(supplier)
                } footer: {
                    if kind == .payment && suggested > 0.005 {
                        Button("Pay the whole balance: \(Money.format(suggested))") {
                            amountText = String(format: "%.\(Money.currency.decimals)f", suggested)
                        }
                        .font(.footnote.weight(.semibold))
                    }
                }
                if kind == .payment {
                    Section {
                        PaymentExtras(method: $method, reference: $reference, receipt: $receipt)
                    }
                }
                Section {
                    TextField(kind == .credit ? LocalizedStringKey("Credit note number (optional)") : LocalizedStringKey("Note (optional)"), text: $note)
                } footer: {
                    if kind == .credit {
                        Text("Only for credits that weren't already taken off one of their invoices in ChargeCheck.")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let amount else { return }
                        let accounts = Accounts.shared
                        let file = receipt.flatMap { accounts.saveReceipt($0) }
                        accounts.add(SupplierPayment(supplier: supplier, amount: amount, date: SupplierAccounts.dayText(date), kind: kind,
                                                     note: note.trimmingCharacters(in: .whitespaces),
                                                     method: kind == .payment ? method : "",
                                                     reference: kind == .payment ? reference.trimmingCharacters(in: .whitespaces) : "",
                                                     receipt: file), context: context)
                        if kind == .payment { lastMethod = method }
                        dismiss()
                    }
                    .disabled(amount == nil)
                }
            }
            .onAppear { if method.isEmpty { method = lastMethod } }
        }
        .presentationDetents([.large])
    }

    private var title: String {
        switch kind {
        case .payment: return String(localized: "Record a payment")
        case .credit: return String(localized: "Add a credit note")
        case .opening: return String(localized: "Starting balance")
        }
    }
}

/// A payment's receipt photo, to look at or send on.
struct ReceiptView: View {
    let payment: SupplierPayment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let name = payment.receipt, let url = Accounts.shared.receiptURL(name), let image = UIImage(contentsOfFile: url.path) {
                    ScrollView {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding()
                    }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: url) {
                                Label("Send", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No receipt", systemImage: "paperclip")
                }
            }
            .navigationTitle(String(localized: "Receipt – \(payment.supplier)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

/// The weekly pay run: everyone you owe on one screen. Type what you paid each, save them all at once.
struct PayRunView: View {
    let accounts: [SupplierAccount]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage("pay.lastMethod") private var lastMethod = "transfer"
    @State private var amounts: [String: String] = [:]
    @State private var method = ""
    @State private var date = Date()

    private var owing: [SupplierAccount] { accounts.filter { $0.balance > 0.005 } }

    private func value(_ id: String) -> Double? {
        guard let text = amounts[id], let v = Money.parse(text), v > 0, v < 1_000_000_000 else { return nil }
        return Money.round2(v)
    }

    private var total: Double { Money.round2(owing.compactMap { value($0.id) }.reduce(0, +)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(owing) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text("Owed \(Money.format(account.balance))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            TextField("0", text: Binding(get: { amounts[account.id] ?? "" }, set: { amounts[account.id] = $0 }))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 110)
                                .fontWeight(.semibold)
                        }
                    }
                } header: {
                    Text("What you paid each supplier")
                } footer: {
                    Text("Leave a supplier empty if you didn't pay them. Each amount pays off that supplier's oldest invoices first.")
                }
                Section {
                    Button("Fill in every full balance") {
                        for account in owing {
                            amounts[account.id] = String(format: "%.\(Money.currency.decimals)f", account.balance)
                        }
                    }
                    Button("Clear", role: .destructive) { amounts = [:] }
                        .disabled(amounts.isEmpty)
                }
                Section {
                    Picker("Paid by", selection: $method) {
                        ForEach(SupplierPayment.methods, id: \.self) { code in
                            Text(PayMethod.name(code)).tag(code)
                        }
                    }
                    DatePicker("Paid on", selection: $date, displayedComponents: .date)
                    LabeledContent("Total paid") {
                        Text(Money.format(total)).fontWeight(.bold)
                    }
                }
            }
            .navigationTitle("Pay run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let day = SupplierAccounts.dayText(date)
                        for account in owing {
                            guard let amount = value(account.id) else { continue }
                            Accounts.shared.add(SupplierPayment(supplier: account.name, amount: amount, date: day, method: method), context: context)
                        }
                        lastMethod = method
                        dismiss()
                    }
                    .disabled(total <= 0)
                }
            }
            .onAppear { if method.isEmpty { method = lastMethod } }
        }
    }
}

/// Tick exactly which invoices a payment covers.
struct PayInvoicesView: View {
    let supplier: String
    let open: [HistoryEntry]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var ticked: Set<String> = []
    @State private var date = Date()

    private var chosen: [HistoryEntry] { open.filter { ticked.contains($0.id) } }

    var body: some View {
        NavigationStack {
            let total = Money.round2(chosen.reduce(0) { $0 + $1.amountToPay.pay })
            List {
                Section {
                    ForEach(open) { entry in
                        Toggle(isOn: Binding(
                            get: { ticked.contains(entry.id) },
                            set: { if $0 { ticked.insert(entry.id) } else { ticked.remove(entry.id) } }
                        )) {
                            InvoiceMoneyRow(entry: entry)
                        }
                    }
                } footer: {
                    Text("\(chosen.count) of \(open.count) selected · pay \(Money.format(total))")
                        .font(.subheadline.weight(.semibold))
                }
                Section {
                    DatePicker("Paid on", selection: $date, displayedComponents: .date)
                }
            }
            .navigationTitle("Pay invoices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Mark as paid") {
                        Accounts.shared.markPaid(chosen, date: date, context: context)
                        dismiss()
                    }
                    .disabled(chosen.isEmpty)
                }
            }
            .onAppear { ticked = Set(open.map { $0.id }) }
        }
    }
}

/// Add a supplier before their first invoice: to make them trusted or set what you already owe them.
struct AddSupplierView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var trusted = false
    @State private var openingText = ""

    private var cleanName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Supplier name, as on their invoices", text: $name)
                        .textInputAutocapitalization(.words)
                    Toggle("Trusted supplier", isOn: $trusted)
                } footer: {
                    Text("Invoices from a trusted supplier aren't price-checked. Scanning one just reads the total and adds it to what you owe them.")
                }
                Section {
                    HStack {
                        Text(Money.currency.symbol)
                            .foregroundStyle(.secondary)
                        TextField("What you owe them now (optional)", text: $openingText)
                            .keyboardType(.decimalPad)
                    }
                } footer: {
                    Text("For invoices from before you used ChargeCheck. Leave it empty if you owe them nothing.")
                }
            }
            .navigationTitle("Add a supplier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let accounts = Accounts.shared
                        if trusted || accounts.isTrusted(cleanName) { accounts.setTrusted(cleanName, trusted, context: context) }
                        if let opening = Money.parse(openingText), opening > 0 {
                            accounts.add(SupplierPayment(supplier: cleanName, amount: Money.round2(opening), date: SupplierAccounts.dayText(Date()),
                                                         kind: .opening), context: context)
                        } else if !trusted {
                            // nothing else to keep: a supplier only exists through invoices, payments or the trusted list
                            accounts.add(SupplierPayment(supplier: cleanName, amount: 0, date: SupplierAccounts.dayText(Date()), kind: .opening),
                                         context: context)
                        }
                        dismiss()
                    }
                    .disabled(cleanName.count < 2)
                }
            }
        }
    }
}
