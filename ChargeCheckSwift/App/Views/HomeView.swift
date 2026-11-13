import SwiftUI
import SwiftData
import ChargeCheckCore

/// The Home tab: where the business stands in five seconds, what needs attention, and a big Scan button.
struct HomeView: View {
    @Binding var tab: String

    @EnvironmentObject private var session: CheckSession
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @Query(sort: \StoredPrice.name) private var prices: [StoredPrice]
    @ObservedObject private var accounts = Accounts.shared
    @ObservedObject private var team = CloudTeam.shared
    @AppStorage(SettingKey.business) private var business = ""
    @State private var search = ""

    var body: some View {
        NavigationStack {
            let entries = reports.compactMap { $0.entry }
            let overview = OverviewMaths.make(entries: entries, payments: accounts.payments, trusted: accounts.trusted,
                                              creditDays: accounts.creditDays)
            List {
                if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResultsSections(results: Search.find(search, entries: entries,
                                                               payments: team.isStaff ? [] : accounts.payments,
                                                               items: team.isStaff ? [] : prices.map { $0.item }))
                } else {
                    if !team.isStaff { owedSection(overview) }
                    scanSection
                    figuresSection(overview)
                    attentionSection(overview)
                    if !team.isStaff { leaksSection(overview) }
                    savingsSection(overview)
                }
            }
            .navigationTitle(business.isEmpty ? "ChargeCheck" : business)
            .searchable(text: $search, prompt: "Search invoices, suppliers, items, payments")
            .navigationDestination(for: ReportLink.self) { link in
                ReportDetailView(reportID: link.id)
            }
            .navigationDestination(for: String.self) { key in
                SupplierDetailView(key: key)
            }
        }
    }

    // MARK: - sections

    private func owedSection(_ o: Overview) -> some View {
        Section {
            Button {
                tab = "suppliers"
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Total outstanding")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(Money.format(o.owed))
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(.tint)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(o.suppliersOwed == 0 ? String(localized: "You don't owe any supplier")
                         : o.suppliersOwed == 1 ? String(localized: "Owed to 1 supplier")
                         : String(localized: "Across \(o.suppliersOwed) suppliers"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    private var scanSection: some View {
        Section {
            Button {
                tab = "invoices"
                session.openScanner = true
            } label: {
                Label("Scan an invoice", systemImage: "doc.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            let waiting = session.jobs.count
            if waiting > 0 {
                Button {
                    tab = "invoices"
                } label: {
                    Label(waiting == 1 ? String(localized: "1 scanned invoice open") : String(localized: "\(waiting) scanned invoices open"),
                          systemImage: "doc.text")
                }
            }
        }
    }

    private func figuresSection(_ o: Overview) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                FigureTile(title: "Spent this month", value: Money.format(o.spentThisMonth),
                           note: o.invoicesThisMonth == 1 ? String(localized: "1 invoice") : String(localized: "\(o.invoicesThisMonth) invoices"),
                           colour: .primary)
                FigureTile(title: "Caught this month", value: Money.format(o.savedThisMonth.total),
                           note: String(localized: "overcharges + missing"), colour: .green)
                if !team.isStaff {
                    FigureTile(title: "Paid this week", value: Money.format(o.paidThisWeek), note: "", colour: .primary)
                    FigureTile(title: "Price rises", value: "\(o.risesThisMonth.count)",
                               note: o.risingSupplier.map { String(localized: "most at \($0)") } ?? String(localized: "this month"),
                               colour: o.risesThisMonth.isEmpty ? .primary : .orange)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func attentionSection(_ o: Overview) -> some View {
        let items = o.attention.filter { !team.isStaff || $0.kind == .notChecked }
        Section {
            if items.isEmpty {
                Label("Nothing needs your attention", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
            ForEach(items) { item in
                NavigationLink {
                    destination(item.kind)
                } label: {
                    AttentionRow(item: item)
                }
            }
        } header: {
            Text("Needs attention")
        }
    }

    @ViewBuilder
    private func destination(_ kind: Attention.Kind) -> some View {
        switch kind {
        case .notChecked: NotCheckedView()
        case .creditsLate: CreditsOwedView()
        case .overdue, .dueSoon: DuePaymentsView()
        case .priceRises: PriceRisesView(supplier: nil)
        }
    }

    @ViewBuilder
    private func leaksSection(_ o: Overview) -> some View {
        if o.lostThisMonth > 0.005 || o.cheaperElsewhere > 0.005 {
            Section {
                if o.risesCost > 0.005 {
                    NavigationLink {
                        PriceRisesView(supplier: nil)
                    } label: {
                        LabeledContent("Price rises this month") {
                            Text(Money.format(o.risesCost)).foregroundStyle(.red)
                        }
                    }
                }
                if o.creditsOwed > 0.005 {
                    NavigationLink {
                        CreditsOwedView()
                    } label: {
                        LabeledContent("Credits not back yet") {
                            Text(Money.format(o.creditsOwed)).foregroundStyle(.orange)
                        }
                    }
                }
                if o.cheaperElsewhere > 0.005 {
                    NavigationLink {
                        SupplierTipsView(tips: Insights.supplierTips(reports.compactMap { $0.entry }))
                    } label: {
                        LabeledContent("Cheaper elsewhere, a month") {
                            Text(Money.format(o.cheaperElsewhere)).foregroundStyle(.green)
                        }
                    }
                }
            } header: {
                Label("Money leaks", systemImage: "drop.triangle")
            } footer: {
                if o.lostThisMonth > 0.005 {
                    Text("You may have lost \(Money.format(o.lostThisMonth)) this month through price rises and credits that haven't come back.")
                }
            }
        }
    }

    private func savingsSection(_ o: Overview) -> some View {
        Section {
            NavigationLink {
                SavingsView()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ChargeCheck has caught")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(Money.format(o.savedAllTime.total))
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(.green)
                    Text(o.savedAllTime.invoices == 1 ? String(localized: "on 1 invoice, since you started")
                         : String(localized: "on \(o.savedAllTime.invoices) invoices, since you started"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Label("Money protected", systemImage: "shield.lefthalf.filled")
        }
    }
}

/// A figure in the Home grid.
struct FigureTile: View {
    let title: LocalizedStringKey
    let value: String
    let note: String
    let colour: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(colour)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(note.isEmpty ? " " : note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AttentionRow: View {
    let item: Attention

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(colour)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if item.amount > 0.005 {
                    Text(Money.format(item.amount))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var icon: String {
        switch item.kind {
        case .notChecked: return "exclamationmark.magnifyingglass"
        case .creditsLate: return "hourglass"
        case .overdue: return "exclamationmark.circle.fill"
        case .dueSoon: return "calendar.badge.clock"
        case .priceRises: return "arrow.up.right"
        }
    }

    private var colour: Color {
        switch item.kind {
        case .overdue: return .red
        case .priceRises, .creditsLate, .notChecked: return .orange
        case .dueSoon: return .blue
        }
    }

    private var title: String {
        let n = item.count
        switch item.kind {
        case .notChecked:
            return n == 1 ? String(localized: "1 invoice not fully checked") : String(localized: "\(n) invoices not fully checked")
        case .creditsLate:
            return n == 1 ? String(localized: "1 credit not back after 2 weeks") : String(localized: "\(n) credits not back after 2 weeks")
        case .overdue:
            return n == 1 ? String(localized: "1 invoice overdue") : String(localized: "\(n) invoices overdue")
        case .dueSoon:
            return n == 1 ? String(localized: "1 invoice due in the next 7 days") : String(localized: "\(n) invoices due in the next 7 days")
        case .priceRises:
            return n == 1 ? String(localized: "1 price rise this month") : String(localized: "\(n) price rises this month")
        }
    }
}

// MARK: - lists the Home screen opens

/// Saved invoices that weren't fully checked.
struct NotCheckedView: View {
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]

    var body: some View {
        let list = reports.compactMap { $0.entry }.filter { !$0.verified && !$0.totalOnly }
        List {
            if list.isEmpty {
                ContentUnavailableView("Every invoice is checked", systemImage: "checkmark.seal")
            }
            Section {
                ForEach(list) { entry in
                    NavigationLink(value: ReportLink(id: entry.id)) {
                        ReportRow(entry: entry)
                    }
                }
            } footer: {
                if !list.isEmpty {
                    Text("These were saved before every line was matched to your prices. Open one to see its lines.")
                }
            }
        }
        .navigationTitle("Not fully checked")
    }
}

/// Credits asked for that haven't arrived yet, oldest first.
struct CreditsOwedView: View {
    @Query(sort: \StoredReport.savedAt) private var reports: [StoredReport]

    var body: some View {
        let list = reports.compactMap { $0.entry }.filter { $0.credit?.isOwed ?? false }
        List {
            if list.isEmpty {
                ContentUnavailableView("No credits owed", systemImage: "checkmark.seal")
            }
            ForEach(list) { entry in
                NavigationLink(value: ReportLink(id: entry.id)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.supplier.isEmpty ? L("Invoice") : entry.supplier)
                                .font(.subheadline.weight(.semibold))
                            Text(askedText(entry))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Money.format(entry.credit?.amount ?? 0))
                            .fontWeight(.semibold)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("Credits owed")
    }

    private func askedText(_ entry: HistoryEntry) -> String {
        var parts: [String] = []
        if !entry.invNo.isEmpty { parts.append("#" + entry.invNo) }
        if let at = entry.credit?.at { parts.append(String(localized: "asked \(PayDates.show(at))")) }
        return parts.joined(separator: " · ")
    }
}

/// Unpaid invoices of suppliers with a credit period: overdue, due this week, later.
struct DuePaymentsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @ObservedObject private var accounts = Accounts.shared

    var body: some View {
        let accountsList = SupplierAccounts.accounts(entries: reports.compactMap { $0.entry }, payments: accounts.payments,
                                                     trusted: accounts.trusted)
        let due = DueDates.open(accounts: accountsList, creditDays: accounts.creditDays)
        let overdue = due.filter { $0.daysLeft < 0 }
        let week = due.filter { $0.daysLeft >= 0 && $0.daysLeft <= 7 }
        let later = due.filter { $0.daysLeft > 7 }
        List {
            if due.isEmpty {
                ContentUnavailableView {
                    Label("No due dates", systemImage: "calendar")
                } description: {
                    Text("Open a supplier and set “Pay within” to see when each of their invoices is due.")
                }
            } else {
                Section {
                    LabeledContent("Needed in the next 7 days") {
                        Text(Money.format(DueDates.cashNeeded(due)))
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(.tint)
                    }
                } footer: {
                    Text("Overdue invoices are included.")
                }
            }
            dueSection("Overdue", overdue)
            dueSection("Due in the next 7 days", week)
            dueSection("Later", later)
        }
        .navigationTitle("Payments due")
    }

    @ViewBuilder
    private func dueSection(_ title: LocalizedStringKey, _ rows: [DueInvoice]) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { row in
                    NavigationLink(value: ReportLink(id: row.entry.id)) {
                        DueRow(row: row)
                    }
                }
            }
        }
    }
}

struct DueRow: View {
    let row: DueInvoice

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.supplier + (row.entry.invNo.isEmpty ? "" : "  #" + row.entry.invNo))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(Self.when(row))
                    .font(.footnote)
                    .foregroundStyle(row.daysLeft < 0 ? Color.red : Color.secondary)
            }
            Spacer(minLength: 8)
            Text(Money.format(row.amount))
                .fontWeight(.semibold)
        }
    }

    static func when(_ row: DueInvoice) -> String {
        let day = PayDates.show(row.dueDate)
        switch row.daysLeft {
        case ..<(-1): return String(localized: "due \(day) · \(-row.daysLeft) days late")
        case -1: return String(localized: "due \(day) · 1 day late")
        case 0: return String(localized: "due today")
        case 1: return String(localized: "due tomorrow")
        default: return String(localized: "due \(day) · in \(row.daysLeft) days")
        }
    }
}

/// How much ChargeCheck has caught, this month and since the start.
struct SavingsView: View {
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @ObservedObject private var accounts = Accounts.shared

    var body: some View {
        let entries = reports.compactMap { $0.entry }
        let o = OverviewMaths.make(entries: entries, payments: accounts.payments, trusted: accounts.trusted)
        let rises = Insights.priceRises(entries)
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Money.format(o.savedAllTime.total))
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(.green)
                    Text("caught on your invoices since you started")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            savings("This month", o.savedThisMonth)
            savings("Since you started", o.savedAllTime)
            Section {
                LabeledContent("Price rises spotted", value: "\(rises.count)")
                if o.cheaperElsewhere > 0.005 {
                    LabeledContent("Cheaper elsewhere, a month", value: Money.format(o.cheaperElsewhere))
                }
            } footer: {
                Text("Overcharges and missing goods are taken off what you pay each supplier. Credits received are the money suppliers sent back for them.")
            }
        }
        .navigationTitle("Money protected")
    }

    private func savings(_ title: LocalizedStringKey, _ s: Savings) -> some View {
        Section(title) {
            LabeledContent("Overcharges caught", value: Money.format(s.overcharges))
            LabeledContent("Missing goods taken off", value: Money.format(s.missing))
            LabeledContent("Credits received", value: Money.format(s.creditsReceived))
            LabeledContent("Invoices with a problem", value: "\(s.invoices)")
        }
    }
}
