import SwiftUI
import SwiftData
import ChargeCheckCore

/// Every supplier: what you owe them, what you paid this week, and their trusted setting.
struct SuppliersView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @ObservedObject private var accounts = Accounts.shared
    @AppStorage(WeeklyPayReminder.dayKey) private var payDay = 0
    @State private var showAdd = false
    @State private var notice: String?

    private var list: [SupplierAccount] {
        SupplierAccounts.accounts(entries: reports.compactMap { $0.entry }, payments: accounts.payments, trusted: accounts.trusted)
    }

    var body: some View {
        NavigationStack {
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
                        }
                    } header: {
                        Text("Suppliers")
                    } footer: {
                        Text("Balance = their invoices (less overcharges and missing items) − your payments and credit notes.")
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
                            Label(copied ? "Copied" : "Copy statement", systemImage: copied ? "checkmark" : "doc.on.doc")
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

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text([PayDates.show(payment.date), payment.note].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text((payment.kind == .opening ? "+" : "−") + Money.format(payment.amount))
                .fontWeight(.semibold)
                .foregroundStyle(payment.kind == .opening ? Color.primary : Color.green)
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

/// Type in a payment, credit note or starting balance.
struct RecordPaymentView: View {
    let supplier: String
    let kind: SupplierPayment.Kind
    let suggested: Double

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var amountText = ""
    @State private var date = Date()
    @State private var note = ""

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
                    TextField(kind == .credit ? "Credit note number (optional)" : "Note, e.g. bank transfer (optional)", text: $note)
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
                        Accounts.shared.add(SupplierPayment(supplier: supplier, amount: amount, date: SupplierAccounts.dayText(date), kind: kind,
                                                            note: note.trimmingCharacters(in: .whitespaces)), context: context)
                        dismiss()
                    }
                    .disabled(amount == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        switch kind {
        case .payment: return String(localized: "Record a payment")
        case .credit: return String(localized: "Add a credit note")
        case .opening: return String(localized: "Starting balance")
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
