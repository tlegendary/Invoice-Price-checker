import SwiftUI
import SwiftData
import ChargeCheckCore

/// Reports › VAT you paid: VAT on supplier invoices per quarter, for the VAT return (input tax).
struct VATSummaryView: View {
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @State private var shared: URL?

    var body: some View {
        let entries = Accounts.shared.inShop(reports.compactMap { $0.entry })
        let main = Money.currency.code
        let currencyOf: (HistoryEntry) -> String = { $0.currency ?? Accounts.shared.currency(for: $0.supplier).code }
        let quarters = VATSummary.quarters(entries, currency: main, currencyOf: currencyOf)
        List {
            if quarters.isEmpty {
                ContentUnavailableView("No VAT yet", systemImage: "percent",
                                       description: Text("VAT on the invoices you check is added up here, quarter by quarter."))
            }
            ForEach(quarters) { quarter in
                Section {
                    LabeledContent("VAT you paid") {
                        Text(Money.format(quarter.vat)).fontWeight(.bold)
                    }
                    LabeledContent("Before VAT", value: Money.format(quarter.net))
                    LabeledContent("Invoices", value: "\(quarter.invoices)")
                    ForEach(quarter.bySupplier.prefix(5), id: \.name) { row in
                        LabeledContent(row.name, value: Money.format(row.vat))
                            .font(.footnote)
                    }
                    if let shared, shared.lastPathComponent == fileName(quarter) {
                        ShareLink(item: shared) {
                            Label("Share the spreadsheet", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button {
                            let csv = VATSummary.csv(entries, quarter: quarter, currency: main, currencyOf: currencyOf)
                            shared = AppFiles.write(Data(csv.utf8), folder: "Exports", name: fileName(quarter))
                        } label: {
                            Label("Spreadsheet for this quarter", systemImage: "tablecells")
                        }
                    }
                } header: {
                    Text(title(quarter))
                }
            }
        }
        .navigationTitle("VAT you paid")
        .safeAreaInset(edge: .bottom) {
            Text("By each invoice's date, calendar quarters. Check the dates match your VAT periods. Invoices billed twice and other currencies are left out.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
    }

    private func fileName(_ q: VATQuarter) -> String { "VAT \(q.year) Q\(q.quarter).csv" }

    private func title(_ q: VATQuarter) -> String {
        let months = ["Jan–Mar", "Apr–Jun", "Jul–Sep", "Oct–Dec"]
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale.current
        let first = calendar.date(from: DateComponents(year: q.year, month: (q.quarter - 1) * 3 + 1, day: 1))
        let last = calendar.date(from: DateComponents(year: q.year, month: (q.quarter - 1) * 3 + 3, day: 1))
        if let first, let last {
            return first.formatted(.dateTime.month(.abbreviated)) + "–" + last.formatted(.dateTime.month(.abbreviated).year())
        }
        return months[q.quarter - 1] + " \(q.year)"
    }
}

/// Reports › Spending by category: this month against last month, so a jump stands out.
struct CategorySpendView: View {
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @Query private var prices: [StoredPrice]

    var body: some View {
        let rows = Spending.byCategory(Accounts.shared.inShop(reports.compactMap { $0.entry }), items: prices.map { $0.item },
                                       other: String(localized: "Other"))
        let top = rows.map(\.thisMonth).max() ?? 0
        List {
            if rows.isEmpty {
                ContentUnavailableView("Nothing bought this month yet", systemImage: "chart.bar",
                                       description: Text("Spending is grouped by the categories in your price list."))
            }
            Section {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(row.category)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(Money.format(row.thisMonth))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.accentColor.opacity(0.8))
                                .frame(width: top > 0 ? max(4, geo.size.width * row.thisMonth / top) : 4)
                        }
                        .frame(height: 6)
                        .accessibilityHidden(true)
                        HStack {
                            Text("Last month \(Money.format(row.lastMonth))")
                            Spacer()
                            if let change = row.change {
                                Text(change >= 0 ? "+\(change.formatted(.number.precision(.fractionLength(0))))%"
                                                 : "\(change.formatted(.number.precision(.fractionLength(0))))%")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(change > 15 ? .red : (change < -15 ? .green : .secondary))
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                if !rows.isEmpty {
                    Text("Before VAT, by each invoice's date. Missing or returned items aren't counted. Give items a category in your price list to sort them here.")
                }
            }
        }
        .navigationTitle("Spending by category")
    }
}

/// Reports › Budgets: a month's limit per supplier or category; Home warns at 80%.
struct BudgetsView: View {
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @Query private var prices: [StoredPrice]
    @Environment(\.modelContext) private var context
    @ObservedObject private var store = BudgetStore.shared
    @State private var editing: Budget?

    var body: some View {
        let items = prices.map { $0.item }
        let status = BudgetMaths.status(store.budgets, entries: Accounts.shared.inShop(reports.compactMap { $0.entry }), items: items,
                                        other: String(localized: "Other"))
        List {
            if status.isEmpty {
                ContentUnavailableView {
                    Label("No budgets yet", systemImage: "gauge.with.dots.needle.33percent")
                } description: {
                    Text("Set a monthly limit for a supplier or a category. Home warns you when 80% is used.")
                }
            }
            Section {
                ForEach(status) { row in
                    Button {
                        editing = row.budget
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(row.budget.name)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(row.percent.formatted(.number.precision(.fractionLength(0))))%")
                                    .fontWeight(.bold)
                                    .foregroundStyle(row.over ? .red : (row.warning ? .orange : .green))
                            }
                            ProgressView(value: min(row.percent, 100), total: 100)
                                .tint(row.over ? .red : (row.warning ? .orange : .green))
                            Text("\(Money.format(row.spent)) of \(Money.format(row.budget.monthly)) this month")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button(role: .destructive) {
                            store.delete(row.budget.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                if !status.isEmpty {
                    Text("Suppliers: invoice totals with VAT (what you pay them). Categories: before VAT, from your price list's categories.")
                }
            }
        }
        .navigationTitle("Budgets")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("For a supplier") { editing = Budget(kind: .supplier, name: "", monthly: 0) }
                    Button("For a category") { editing = Budget(kind: .category, name: "", monthly: 0) }
                } label: {
                    Label("Add a budget", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { budget in
            BudgetEditView(budget: budget,
                           names: budget.kind == .supplier ? AppData.knownSuppliers(context)
                                                            : Array(Set(items.map { $0.cat }.filter { !$0.isEmpty })).sorted()) { store.save($0) }
        }
    }
}

private struct BudgetEditView: View {
    let names: [String]
    let onSave: (Budget) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var budget: Budget
    @State private var amount: String

    init(budget: Budget, names: [String], onSave: @escaping (Budget) -> Void) {
        self.names = names
        self.onSave = onSave
        _budget = State(initialValue: budget)
        _amount = State(initialValue: budget.monthly > 0 ? String(format: "%.0f", budget.monthly) : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(budget.kind == .supplier ? "Supplier" : "Category", selection: $budget.name) {
                        Text("Choose").tag("")
                        ForEach(names, id: \.self) { Text($0).tag($0) }
                    }
                    LabeledContent("A month") {
                        TextField(Money.format(0), text: $amount)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = budget
                        saved.monthly = Money.parse(amount) ?? 0
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(budget.name.isEmpty || (Money.parse(amount) ?? 0) <= 0)
                }
            }
        }
    }
}

/// Home › agreed prices ending.
struct DealsEndingView: View {
    @ObservedObject private var store = BudgetStore.shared

    var body: some View {
        let ending = DealDates.ending(store.deals, within: 60)
        List {
            if ending.isEmpty {
                ContentUnavailableView("No agreed prices ending soon", systemImage: "calendar",
                                       description: Text("Set the date a supplier's prices end on their page in Suppliers."))
            }
            ForEach(ending) { deal in
                LabeledContent(deal.supplier) {
                    Text(deal.daysLeft < 0 ? String(localized: "Ended \(-deal.daysLeft) days ago")
                         : deal.daysLeft == 0 ? String(localized: "Ends today") : String(localized: "Ends in \(deal.daysLeft) days"))
                        .foregroundStyle(deal.daysLeft <= 7 ? .red : .orange)
                }
            }
        }
        .navigationTitle("Agreed prices ending")
    }
}
