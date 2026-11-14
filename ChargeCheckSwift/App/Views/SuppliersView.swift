import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import ChargeCheckCore

/// Every supplier: what you owe them, what you paid this week, and their trusted setting.
struct SuppliersView: View {
    @Environment(\.modelContext) private var context
    /// Staff phones see balances but can't record payments or change suppliers.
    @ObservedObject private var team = CloudTeam.shared
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
            // suppliers who invoice in another currency are added up on their own
            let home = accounts.homeCurrencyAccounts(all)
            let owed = Money.round2(home.filter { $0.balance > 0.005 }.reduce(0) { $0 + $1.balance })
            let thisWeek = Money.round2(home.reduce(0) { $0 + $1.paidThisWeek })
            let other = OtherCurrencyTotals.make(all.filter { accounts.otherCurrency($0.name) != nil })
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
                        ForEach(other, id: \.code) { row in
                            LabeledContent(String(localized: "Also owed in \(row.code)"), value: Money.format(row.owed, code: row.code))
                        }
                    }
                    Section {
                        ForEach(all) { account in
                            NavigationLink(value: account.id) {
                                SupplierRow(account: account)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if !team.isStaff {
                                    Button {
                                        paying = account
                                    } label: {
                                        Label("Pay", systemImage: "banknote")
                                    }
                                    .tint(.green)
                                }
                            }
                        }
                    } header: {
                        Text("Suppliers")
                    } footer: {
                        Text("Swipe left on a supplier to record a payment. Balance = their invoices (less overcharges and missing items) − your payments and credit notes.")
                    }
                    let monthRises = Insights.priceRises(reports.compactMap { $0.entry }, since: SupplierAccounts.dayText(Date().addingTimeInterval(-30 * 86_400)))
                    if !monthRises.isEmpty {
                        Section {
                            ForEach(monthRises.prefix(2)) { rise in
                                PriceRiseRow(rise: rise, showSupplier: true)
                            }
                            NavigationLink {
                                PriceRisesView(supplier: nil)
                            } label: {
                                Text(monthRises.count == 1 ? String(localized: "See the price rise") : String(localized: "See all \(monthRises.count) price rises"))
                            }
                        } header: {
                            Label("Price rises, last 30 days", systemImage: "arrow.up.right")
                        }
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
                    if owed > 0.005 && !team.isStaff {
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
                if !team.isStaff {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAdd = true
                        } label: {
                            Label("Add a supplier", systemImage: "plus")
                        }
                    }
                }
            }
            .refreshable { await team.refresh() }
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
            Text(Money.format(account.balance, supplier: account.name))
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
            parts.append(String(localized: "last paid \(Money.format(last.amount, supplier: account.name)) on \(PayDates.show(last.date))"))
        }
        return parts.joined(separator: " · ")
    }
}

/// What you owe suppliers in each other currency.
enum OtherCurrencyTotals {
    struct Row { let code: String; let owed: Double }

    @MainActor static func make(_ accounts: [SupplierAccount]) -> [Row] {
        var totals: [String: Double] = [:]
        for account in accounts where account.balance > 0.005 {
            guard let code = Accounts.shared.otherCurrency(account.name) else { continue }
            totals[code, default: 0] += account.balance
        }
        return totals.keys.sorted().map { Row(code: $0, owed: Money.round2(totals[$0] ?? 0)) }
    }
}

enum PayDates {
    /// "2026-11-04" → "4 Nov 2026" in the phone's language.
    static func show(_ text: String) -> String {
        guard let date = SupplierAccounts.day(text) else { return text }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The supplier's profile: purchases, accuracy, a score out of 100 and a report to send or keep.
struct SupplierProfileSection: View {
    let account: SupplierAccount
    let profile: SupplierProfile

    @ObservedObject private var accounts = Accounts.shared
    @AppStorage(SettingKey.business) private var business = ""
    @AppStorage(SettingKey.colour) private var colourID = "green"
    @State private var showScore = false
    @State private var made: URL?

    var body: some View {
        Section {
            Button {
                showScore.toggle()
            } label: {
                HStack {
                    ScoreBadge(score: profile.score)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Supplier score")
                            .font(.subheadline.weight(.semibold))
                        Text(profile.score == nil ? String(localized: "Needs \(SupplierProfile.minimumInvoices) checked invoices")
                             : String(localized: "Prices, deliveries and invoice accuracy"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: showScore ? "chevron.up" : "chevron.down")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if showScore {
                percentRow("Charged the agreed price", profile.parts.invoiceAccuracy)
                percentRow("Delivered in full", profile.parts.deliveryAccuracy)
                percentRow("Prices that stayed the same (90 days)", profile.parts.priceStability)
                percentRow("Cheapest for items you also buy elsewhere", profile.parts.priceCompetitiveness)
            }
            LabeledContent("Bought this month", value: Money.format(profile.purchasesThisMonth, supplier: account.name))
            LabeledContent("Last month", value: Money.format(profile.purchasesLastMonth, supplier: account.name))
            LabeledContent("Average invoice", value: Money.format(profile.averageInvoice, supplier: account.name))
            if profile.disputed > 0 {
                LabeledContent(profile.disputed == 1 ? String(localized: "1 invoice with a problem") : String(localized: "\(profile.disputed) invoices with a problem")) {
                    Text(Money.format(Money.round2(profile.overcharged + profile.missing), supplier: account.name))
                        .foregroundStyle(.red)
                }
            }
            if profile.creditsOwed > 0.005 {
                LabeledContent("Credits still owed") {
                    Text(Money.format(profile.creditsOwed, supplier: account.name)).foregroundStyle(.orange)
                }
            }
            if let made {
                ShareLink(item: made) {
                    Label("Save or send the supplier report", systemImage: "square.and.arrow.up")
                }
            } else {
                Button {
                    made = report()
                } label: {
                    Label("Make a supplier report (PDF)", systemImage: "doc.richtext")
                }
            }
        } header: {
            Text("Profile")
        }
    }

    private func percentRow(_ title: LocalizedStringKey, _ value: Double?) -> some View {
        LabeledContent(title) {
            Text(value.map { String(format: "%.0f%%", $0) } ?? "–")
                .foregroundStyle(value.map { $0 >= 90 ? Color.green : $0 >= 70 ? Color.orange : Color.red } ?? Color.secondary)
        }
        .font(.footnote)
    }

    private func report() -> URL? {
        let due = DueDates.open(accounts: [account], creditDays: accounts.creditDays)
        let data = PDFMaker.supplierReport(account, profile: profile, due: due, business: business, theme: Themes.named(colourID))
        let safe = account.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: " ")
        return AppFiles.write(data, folder: "Exports", name: "Supplier report " + safe + ".pdf")
    }
}

/// A supplier's score in a coloured circle.
struct ScoreBadge: View {
    let score: Int?

    var body: some View {
        ZStack {
            Circle()
                .fill(colour.opacity(0.15))
            Text(score.map { "\($0)" } ?? "–")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(colour)
        }
        .frame(width: 40, height: 40)
        .accessibilityLabel(score.map { String(localized: "Score \($0) out of 100") } ?? String(localized: "No score yet"))
    }

    private var colour: Color {
        guard let score else { return .secondary }
        return score >= 85 ? .green : score >= 65 ? .orange : .red
    }
}

/// One supplier's account: balance, what's still open, payments, and the trusted switch.
struct SupplierDetailView: View {
    let key: String

    @Environment(\.modelContext) private var context
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @Query private var prices: [StoredPrice]
    @ObservedObject private var accounts = Accounts.shared
    @ObservedObject private var team = CloudTeam.shared
    @State private var addKind: SupplierPayment.Kind?
    @State private var showPayInvoices = false
    @State private var showStatement = false
    @State private var copied = false
    @State private var confirmDeleteAll = false

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
                            Text(Money.format(account.balance, supplier: account.name))
                                .font(.title.weight(.heavy))
                                .foregroundStyle(account.balance > 0.005 ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.green))
                        }
                        if account.opening != 0 { LabeledContent("Starting balance", value: Money.format(account.opening, supplier: account.name)) }
                        LabeledContent("Invoices", value: Money.format(account.invoiced, supplier: account.name))
                        if account.settledOutside > 0.005 {
                            LabeledContent("Marked paid before", value: "−" + Money.format(account.settledOutside, supplier: account.name))
                        }
                        if account.paid > 0.005 { LabeledContent("Payments", value: "−" + Money.format(account.paid, supplier: account.name)) }
                        if account.credits > 0.005 { LabeledContent("Credit notes", value: "−" + Money.format(account.credits, supplier: account.name)) }
                        LabeledContent("Paid this week", value: Money.format(account.paidThisWeek, supplier: account.name))
                    } footer: {
                        if account.balance < -0.005 {
                            Text("You've paid \(Money.format(-account.balance, supplier: account.name)) more than they invoiced. It comes off their next invoices.")
                        }
                    }

                    if !team.isStaff && !account.entries.isEmpty {
                        SupplierProfileSection(account: account, profile: SupplierProfiles.make(account, all: reports.compactMap { $0.entry }))
                    }

                    // staff phones: payments, special prices and the trusted setting are the owner's
                    if !team.isStaff {
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
                                showStatement = true
                            } label: {
                                Label("Check their statement", systemImage: "list.bullet.clipboard")
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

                        let rises = Insights.priceRises(account.entries, since: SupplierAccounts.dayText(Date().addingTimeInterval(-90 * 86_400)))
                        if !rises.isEmpty {
                            Section {
                                ForEach(rises.prefix(3)) { rise in
                                    PriceRiseRow(rise: rise, showSupplier: false)
                                }
                                if rises.count > 3 {
                                    NavigationLink {
                                        PriceRisesView(supplier: account.name)
                                    } label: {
                                        Text("See all \(rises.count) price rises")
                                    }
                                }
                            } header: {
                                Label("Price rises, last 90 days", systemImage: "arrow.up.right")
                            }
                        }

                        Section {
                            NavigationLink {
                                SupplierPricesView(supplier: account.name)
                            } label: {
                                LabeledContent("Special prices") {
                                    Text("\(SupplierPrices.count(for: account.name, items: prices.map { $0.item }))")
                                }
                            }
                        } footer: {
                            Text("Prices agreed with this supplier that differ from your standard prices.")
                        }

                        Section {
                            Toggle("Trusted supplier", isOn: Binding(
                                get: { account.trusted },
                                set: { accounts.setTrusted(account.name, $0, context: context) }
                            ))
                        } footer: {
                            Text("Invoices from a trusted supplier aren't price-checked. Scanning one just reads the total and adds it to what you owe them.")
                        }

                        Section {
                            Picker("Invoices in", selection: Binding(
                                get: { accounts.currency(for: account.name).code },
                                set: { accounts.setCurrency(account.name, $0, context: context) }
                            )) {
                                ForEach(Currency.all) { currency in
                                    Text(Regional.currencyName(currency)).tag(currency.code)
                                }
                            }
                            Picker("Pay within", selection: Binding(
                                get: { accounts.creditPeriod(account.name) ?? -1 },
                                set: { accounts.setCreditPeriod(account.name, $0 < 0 ? nil : $0, context: context) }
                            )) {
                                Text("No due date").tag(-1)
                                Text("On delivery").tag(0)
                                ForEach([7, 14, 21, 28, 30, 45, 60, 90], id: \.self) { days in
                                    Text("\(days) days").tag(days)
                                }
                            }
                        } footer: {
                            Text("Each invoice is due this many days after its date. Overdue invoices and what you need to pay this week show on Home. A supplier who invoices in another currency is added up separately, never mixed with your own currency.")
                        }
                    }

                    if !account.open.isEmpty {
                        let due = Dictionary(DueDates.open(accounts: [account], creditDays: accounts.creditDays).map { ($0.id, $0) },
                                             uniquingKeysWith: { a, _ in a })
                        Section("Still to pay") {
                            ForEach(account.open) { entry in
                                NavigationLink(value: ReportLink(id: entry.id)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        InvoiceMoneyRow(entry: entry)
                                        if let row = due[entry.id] {
                                            Label(DueRow.when(row), systemImage: row.daysLeft < 0 ? "exclamationmark.circle.fill" : "calendar")
                                                .font(.caption)
                                                .foregroundStyle(row.daysLeft < 0 ? Color.red : Color.secondary)
                                        }
                                    }
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

                    // owner only: clear this supplier out in one go instead of one invoice at a time
                    if !team.isStaff && (!account.entries.isEmpty || !account.payments.isEmpty) {
                        Section {
                            Button(role: .destructive) {
                                confirmDeleteAll = true
                            } label: {
                                Label(account.entries.count == 1 ? String(localized: "Delete this supplier's invoice")
                                      : String(localized: "Delete all \(account.entries.count) of this supplier's invoices"),
                                      systemImage: "trash")
                            }
                        } footer: {
                            Text("Your prices and this supplier's special prices are kept.")
                        }
                        .confirmationDialog("Delete \(account.name)'s invoices?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                            if !account.entries.isEmpty {
                                Button("Delete invoices, keep payments", role: .destructive) { deleteAll(account, payments: false) }
                            }
                            Button("Delete invoices and payments", role: .destructive) { deleteAll(account, payments: true) }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("They stay in More › Recently deleted for 30 days, so you can bring them back. Deleting the payments too starts this supplier's balance from zero.")
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
                .sheet(isPresented: $showStatement) {
                    StatementCheckView(account: account)
                }
            } else {
                ContentUnavailableView("Supplier removed", systemImage: "shippingbox")
            }
        }
    }

    private func deleteAll(_ account: SupplierAccount, payments: Bool) {
        let ids = Set(account.entries.map { $0.id })
        CloudTeam.shared.allowBulkDelete()
        AppData.deleteReports(ids, context: context)
        // payments for exactly those invoices go with them, so the balance doesn't go below zero
        accounts.removePayments(supplier: account.name, onlyFor: payments ? nil : ids, context: context)
    }

    private func statement(_ account: SupplierAccount) -> String {
        let today = Date().formatted(date: .abbreviated, time: .omitted)
        var lines = [String(localized: "Statement – \(account.name) – \(today)"), ""]
        for entry in account.open.reversed() {
            let number = entry.invNo.isEmpty ? L("Invoice") : String(localized: "Invoice \(entry.invNo)")
            lines.append("• " + number + (entry.date.isEmpty ? "" : " · " + entry.date) + " · " + Money.format(entry.amountToPay.pay, supplier: account.name))
        }
        if let last = account.lastPayment {
            lines.append("")
            lines.append(String(localized: "Last payment: \(Money.format(last.amount, supplier: account.name)) on \(PayDates.show(last.date))"))
        }
        lines.append(String(localized: "Balance owed: \(Money.format(account.balance, supplier: account.name))"))
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
            Text(Money.format(entry.amountToPay.pay, supplier: entry.supplier))
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
            Text((payment.kind == .opening ? "+" : "−") + Money.format(payment.amount, supplier: payment.supplier))
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
                        Button("Pay the whole balance: \(Money.format(suggested, supplier: supplier))") {
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
                                Text("Owed \(Money.format(account.balance, supplier: account.name))")
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
                    Text("\(chosen.count) of \(open.count) selected · pay \(Money.format(total, supplier: supplier))")
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

/// The prices agreed with one supplier that differ from the standard price. Invoices from them are checked against these.
struct SupplierPricesView: View {
    let supplier: String

    @Environment(\.modelContext) private var context
    @Query private var prices: [StoredPrice]
    @State private var editing: PriceItem?
    @State private var adding = false

    private var items: [PriceItem] { prices.map { $0.item } }

    var body: some View {
        let rows = SupplierPrices.rows(for: supplier, items: items)
        List {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("No special prices", systemImage: "tag")
                } description: {
                    Text("Add a price you agreed with \(supplier) when it differs from your standard price. Their invoices are then checked against it.")
                }
            } else {
                Section {
                    ForEach(rows) { row in
                        Button {
                            editing = row.item
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.item.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("Standard price \(Money.format(row.standard))")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(Money.format(row.special, supplier: supplier))
                                        .fontWeight(.bold)
                                        .foregroundStyle(.primary)
                                    if abs(row.difference) > 0.005 {
                                        Text((row.difference > 0 ? "+" : "−") + Money.format(abs(row.difference)))
                                            .font(.caption)
                                            .foregroundStyle(row.difference > 0 ? Color.red : Color.green)
                                    }
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for row in offsets.map({ rows[$0] }) {
                            AppData.save(SupplierPrices.set(nil, for: supplier, on: row.item), in: context)
                        }
                    }
                } footer: {
                    Text("Invoices from \(supplier) are checked against these prices instead of the standard ones. Swipe left to remove one.")
                }
            }
        }
        .navigationTitle(String(localized: "Prices – \(supplier)"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    adding = true
                } label: {
                    Label("Add a special price", systemImage: "plus")
                }
                .disabled(items.isEmpty)
            }
        }
        .sheet(item: $editing) { item in
            SpecialPriceEditView(item: item, supplier: supplier) { price in
                AppData.save(SupplierPrices.set(price, for: supplier, on: item), in: context)
            }
        }
        .sheet(isPresented: $adding) {
            PickItemView(items: items.filter { item in !rows.contains { $0.id == item.id } }) { item in
                adding = false
                // open the price sheet once the list has closed
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { editing = item }
            }
        }
    }
}

/// Type in one supplier's price for an item.
struct SpecialPriceEditView: View {
    let item: PriceItem
    let supplier: String
    let save: (Double?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var value: Double? {
        guard let v = Money.parse(text), v > 0, v < 1_000_000_000 else { return nil }
        return Money.round2(v)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(Money.currency.symbol)
                            .foregroundStyle(.secondary)
                        TextField("Price agreed with this supplier", text: $text)
                            .keyboardType(.decimalPad)
                            .font(.title3.weight(.semibold))
                    }
                    LabeledContent("Standard price", value: Money.format(item.price))
                } header: {
                    Text(item.name)
                } footer: {
                    Text("Only invoices from \(supplier) are checked against this price.")
                }
                if item.sp.contains(where: { TextTools.sameSupplier($0.s, supplier) }) {
                    Section {
                        Button("Remove this special price", role: .destructive) {
                            save(nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(supplier)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(value)
                        dismiss()
                    }
                    .disabled(value == nil)
                }
            }
            .onAppear {
                let current = item.basePrice(for: supplier)
                text = String(format: "%.\(Money.currency.decimals)f", current)
            }
        }
        .presentationDetents([.medium])
    }
}

/// Choose an item from the price list.
struct PickItemView: View {
    let items: [PriceItem]
    let pick: (PriceItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var shown: [PriceItem] {
        let sorted = items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let words = search.lowercased().split(separator: " ")
        if words.isEmpty { return sorted }
        return sorted.filter { item in words.allSatisfy { item.name.lowercased().contains($0) } }
    }

    var body: some View {
        NavigationStack {
            List(shown) { item in
                Button {
                    pick(item)
                } label: {
                    HStack {
                        Text(item.name).foregroundStyle(.primary)
                        Spacer()
                        Text(Money.format(item.price)).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $search, prompt: "Search your price list")
            .navigationTitle("Choose an item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Scan a supplier's statement and tick it off against your invoices and payments.
struct StatementCheckView: View {
    let account: SupplierAccount

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var accounts = Accounts.shared
    @AppStorage(SettingKey.business) private var business = ""
    @State private var showScanner = false
    @State private var showFiles = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var reading = false
    @State private var progress = ""
    @State private var result: StatementResult?
    @State private var problem: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                if let result {
                    resultSections(result)
                } else if reading {
                    Section {
                        HStack {
                            ProgressView()
                            Text(progress.isEmpty ? String(localized: "Reading the statement…") : progress)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        if DocumentScanner.isAvailable {
                            Button {
                                showScanner = true
                            } label: {
                                Label("Scan the statement", systemImage: "doc.viewfinder")
                            }
                        }
                        PhotosPicker(selection: $picked, maxSelectionCount: 6, matching: .images) {
                            Label("Choose photos", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showFiles = true
                        } label: {
                            Label("Choose a PDF or file", systemImage: "folder")
                        }
                    } footer: {
                        Text("ChargeCheck reads the statement and ticks it off against \(account.name)'s invoices and your payments. It doesn't use a scan.")
                    }
                    if let problem {
                        Section {
                            Text(problem)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Check a statement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if result != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Another") {
                            result = nil
                            problem = nil
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner(onFinish: { pages in
                    showScanner = false
                    read(pages: pages, pdf: nil)
                }, onCancel: { showScanner = false })
                .ignoresSafeArea()
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .image]) { outcome in
                guard case .success(let url) = outcome else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if url.pathExtension.lowercased() == "pdf" {
                    read(pages: ImageTools.pages(ofPDF: url), pdf: try? Data(contentsOf: url))
                } else if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                    read(pages: [image], pdf: nil)
                }
            }
            .onChange(of: picked) {
                let items = picked
                guard !items.isEmpty else { return }
                picked = []
                Task {
                    var pages: [UIImage] = []
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { pages.append(image) }
                    }
                    read(pages: pages, pdf: nil)
                }
            }
        }
    }

    private func read(pages: [UIImage], pdf: Data?) {
        guard !pages.isEmpty || pdf != nil else { return }
        reading = true
        problem = nil
        let account = account
        let payments = accounts.payments
        Task {
            let outcome = await InvoiceReader.read(pages: pages, pdf: pdf, book: PriceBook([]), knownSuppliers: [], doubleCheck: false) { text in
                Task { @MainActor in progress = text }
            }
            let statement = StatementCheck.parse(outcome.rawText)
            reading = false
            if statement.lines.isEmpty {
                problem = String(localized: "No statement lines were found. Each line needs a date and an amount. Try a clearer photo, or the PDF the supplier sent.")
            } else {
                result = StatementCheck.compare(statement, account: account, payments: payments)
            }
        }
    }

    @ViewBuilder
    private func resultSections(_ r: StatementResult) -> some View {
        Section {
            if r.allClear {
                Label("Everything on the statement matches your records", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Some things don't match", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let theirs = r.theirBalance {
                LabeledContent("They say you owe", value: Money.format(theirs, supplier: account.name))
            }
            LabeledContent("ChargeCheck says", value: Money.format(r.yourBalance, supplier: account.name))
            if let theirs = r.theirBalance, theirs - r.yourBalance > 0.05, r.takenOff > 0.005 {
                Text("Part of the difference is the \(Money.format(r.takenOff, supplier: account.name)) of overcharges and missing items you took off their invoices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        if !r.amountDiffers.isEmpty {
            Section("Amount differs") {
                ForEach(r.amountDiffers) { item in
                    LabeledContent {
                        VStack(alignment: .trailing) {
                            Text(Money.format(item.line.amount, supplier: account.name)).foregroundStyle(.orange)
                            Text("yours \(Money.format(item.yours, supplier: account.name))").font(.caption).foregroundStyle(.secondary)
                        }
                    } label: {
                        statementLabel(item.line)
                    }
                }
            }
        }
        if !r.notInReports.isEmpty {
            Section {
                ForEach(r.notInReports) { line in
                    LabeledContent { Text(Money.format(line.amount, supplier: account.name)).foregroundStyle(.red) } label: { statementLabel(line) }
                }
            } header: {
                Text("Not in your Reports")
            } footer: {
                Text("You haven't checked these invoices in ChargeCheck, or never received them. Ask for a copy if you don't have one.")
            }
        }
        if !r.paymentsNotCounted.isEmpty {
            Section("Your payments missing from the statement") {
                ForEach(r.paymentsNotCounted) { payment in
                    PaymentRow(payment: payment)
                }
            }
        }
        if !r.paymentsUnknown.isEmpty {
            Section {
                ForEach(r.paymentsUnknown) { line in
                    LabeledContent { Text(Money.format(line.amount, supplier: account.name)) } label: { statementLabel(line) }
                }
            } header: {
                Text("Payments and credits you have no record of")
            } footer: {
                Text("Record them in the supplier's account if they're right.")
            }
        }
        if !r.notOnStatement.isEmpty {
            Section {
                ForEach(r.notOnStatement) { entry in
                    InvoiceMoneyRow(entry: entry)
                }
            } header: {
                Text("Your invoices not on the statement")
            } footer: {
                Text("Usually invoices that arrived after the statement was printed.")
            }
        }
        if !r.matched.isEmpty || !r.paymentsMatched.isEmpty {
            Section("Matches") {
                Label(r.matched.count == 1 ? String(localized: "1 invoice matches") : String(localized: "\(r.matched.count) invoices match"),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if !r.paymentsMatched.isEmpty {
                    Label(r.paymentsMatched.count == 1 ? String(localized: "1 payment or credit matches")
                          : String(localized: "\(r.paymentsMatched.count) payments and credits match"),
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        if !r.allClear {
            Section {
                Button {
                    UIPasteboard.general.string = StatementCheck.query(r, supplier: account.name, business: business)
                    copied = true
                } label: {
                    Label(copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy a message to the supplier"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            } footer: {
                Text("Lists every difference, ready to paste into WhatsApp or an email.")
            }
        }
    }

    private func statementLabel(_ line: StatementLine) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line.reference.isEmpty ? L(kindName(line.kind)) : line.reference)
                .font(.subheadline.weight(.semibold))
            Text(line.date)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func kindName(_ kind: StatementLine.Kind) -> String {
        switch kind {
        case .invoice: return "Invoice"
        case .payment: return "Payment"
        case .credit: return "Credit note"
        }
    }
}
