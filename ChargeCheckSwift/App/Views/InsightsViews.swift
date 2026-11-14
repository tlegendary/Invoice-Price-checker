import SwiftUI
import SwiftData
import ChargeCheckCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Items another supplier sells you cheaper, from your own invoices.
struct SupplierTipsView: View {
    let tips: [SupplierTip]

    var body: some View {
        List {
            if tips.isEmpty {
                ContentUnavailableView {
                    Label("No cheaper suppliers found", systemImage: "tag")
                } description: {
                    Text("When you buy the same item from two suppliers, ChargeCheck shows here if the other one is cheaper.")
                }
            } else {
                Section {
                    ForEach(tips) { tip in
                        SupplierTipRow(tip: tip)
                    }
                } footer: {
                    Text("From the last price each supplier charged you for the item. Prices can differ in pack size or quality, so check before you switch.")
                }
            }
        }
        .navigationTitle("Cheaper elsewhere")
    }
}

struct SupplierTipRow: View {
    let tip: SupplierTip

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tip.item)
                .font(.subheadline.weight(.semibold))
            Text("\(tip.cheapest.supplier) is \(Money.format(tip.savingEach)) cheaper than \(tip.lastSupplier)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.green)
            Text(tip.prices.map { "\($0.supplier) \(Money.format($0.unit))" }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if tip.savingMonth > 0.005 {
                Text("About \(Money.format(tip.savingMonth)) a month at what you bought lately")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One month in plain words: what you spent, who overcharged you, what went up.
struct MonthlySummaryView: View {
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @ObservedObject private var accounts = Accounts.shared
    @State private var month = MonthlySummaryView.lastMonth
    @State private var written: [String: String] = [:]
    @State private var writing = false

    static var lastMonth: String {
        let date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        return String(SupplierAccounts.dayText(date).prefix(7))
    }

    private var months: [String] {
        (0..<12).compactMap { back in
            Calendar.current.date(byAdding: .month, value: -back, to: Date()).map { String(SupplierAccounts.dayText($0).prefix(7)) }
        }
    }

    static func name(_ month: String) -> String {
        guard let date = SupplierAccounts.day(month + "-01") else { return month }
        return date.formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        let all = reports.compactMap { $0.entry }
        let summary = Insights.month(month, entries: accounts.inShop(all), payments: accounts.shopPayments(all),
                                     shops: Shops.all, trusted: accounts.trusted)
        let sentences = Insights.sentences(summary, monthName: Self.name(month))
        List {
            Section {
                Picker("Month", selection: $month) {
                    ForEach(months, id: \.self) { Text(Self.name($0)).tag($0) }
                }
            }
            if let text = written[month] {
                Section {
                    Text(text)
                } header: {
                    Label("In plain words", systemImage: "sparkles")
                } footer: {
                    Text("Written by Apple Intelligence from the figures below. The figures come from your own invoices.")
                }
            } else if writing {
                Section {
                    HStack {
                        ProgressView()
                        Text("Apple Intelligence is writing your summary…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("The figures") {
                ForEach(sentences, id: \.self) { line in
                    Text(line)
                }
            }
            if summary.invoices > 0 {
                Section("By supplier") {
                    ForEach(summary.bySupplier, id: \.name) { row in
                        LabeledContent(row.name) {
                            VStack(alignment: .trailing) {
                                Text(Money.format(row.spent)).fontWeight(.semibold)
                                if row.overcharged > 0.005 {
                                    Text("overcharged \(Money.format(row.overcharged))")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
                if summary.byShop.count > 1 {
                    Section("By shop") {
                        ForEach(summary.byShop, id: \.name) { row in
                            LabeledContent(row.name, value: Money.format(row.spent))
                        }
                    }
                }
                if !summary.rises.isEmpty {
                    Section("Prices that went up") {
                        ForEach(summary.rises, id: \.item) { rise in
                            LabeledContent {
                                Text("\(Money.format(rise.from)) → \(Money.format(rise.to))")
                                    .foregroundStyle(.red)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(rise.item)
                                    Text(rise.supplier).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    ShareLink(item: ([String(localized: "ChargeCheck summary – \(Self.name(month))"), ""] + [written[month] ?? ""] + sentences)
                        .filter { !$0.isEmpty }.joined(separator: "\n")) {
                        Label("Send this summary", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("Monthly summary")
        .task(id: month) {
            guard summary.invoices > 0, written[month] == nil else { return }
            writing = true
            if let text = await SummaryWriter.write(sentences) { written[month] = text }
            writing = false
        }
    }
}

/// Turns the month's figures into a few friendly sentences with Apple Intelligence (iOS 26). It never adds numbers of its own.
enum SummaryWriter {
    static func write(_ facts: [String]) async -> String? {
        guard SmartCheck.status.isEmpty, PlanMirror.allows(.monthlySummary), !facts.isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let language = Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "English"
            let session = LanguageModelSession(instructions: """
            You write a short monthly summary for a takeaway or restaurant owner about their supplier invoices.
            Use only the facts given. Copy every amount, name and number exactly as written. Never add a number, a reason or advice.
            Write 2 to 4 short, friendly sentences in \(language). Plain words, no lists, no headings.
            """)
            do {
                let reply = try await session.respond(to: "Facts:\n" + facts.map { "- " + $0 }.joined(separator: "\n"))
                let text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}

/// Prices suppliers put up since the last time you bought from them.
struct PriceRisesView: View {
    /// nil = every supplier
    let supplier: String?

    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @State private var days = 90

    var body: some View {
        let since = SupplierAccounts.dayText(Date().addingTimeInterval(-Double(days) * 86_400))
        let all = Insights.priceRises(Accounts.shared.inShop(reports.compactMap { $0.entry }), since: since)
            .filter { rise in supplier.map { SupplierAccounts.key($0) == SupplierAccounts.key(rise.supplier) } ?? true }
        let groups = Dictionary(grouping: all) { SupplierAccounts.key($0.supplier) }
            .values.sorted { ($0.first?.supplier ?? "") < ($1.first?.supplier ?? "") }
        List {
            Section {
                Picker("Period", selection: $days) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                .pickerStyle(.segmented)
            }
            if all.isEmpty {
                ContentUnavailableView {
                    Label("No price rises", systemImage: "arrow.up.right")
                } description: {
                    Text("When a supplier charges more than the last time you bought the same item from them, it shows here.")
                }
            }
            ForEach(groups, id: \.first?.id) { rises in
                Section(rises.first?.supplier ?? "") {
                    ForEach(rises) { rise in
                        PriceRiseRow(rise: rise, showSupplier: false)
                    }
                }
            }
        }
        .navigationTitle(supplier.map { String(localized: "Price rises – \($0)") } ?? String(localized: "Price rises"))
    }
}

struct PriceRiseRow: View {
    let rise: PriceRise
    let showSupplier: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rise.item)
                    .font(.subheadline.weight(.semibold))
                Text([showSupplier ? rise.supplier : "", "\(Money.format(rise.from)) → \(Money.format(rise.to))", day(rise.when)]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("+\(rise.percent.formatted(.number.precision(.fractionLength(0...1))))%")
                .fontWeight(.bold)
                .foregroundStyle(.red)
        }
    }

    private func day(_ stamp: String) -> String {
        guard !stamp.isEmpty, let date = SupplierAccounts.day(stamp) else { return "" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// On an invoice being checked: what went up since the last time you bought it from this supplier.
struct PriceRiseSection: View {
    let rises: [PriceRise]
    @EnvironmentObject private var store: Store

    var body: some View {
        if !rises.isEmpty {
            Section {
                if store.allows(.priceRises) {
                    ForEach(rises) { rise in
                        PriceRiseRow(rise: rise, showSupplier: false)
                    }
                } else {
                    // the free version and scan packs see that prices went up, Pro sees which and by how much
                    LockedRow(feature: .priceRises) {
                        Text(rises.count == 1 ? String(localized: "1 item costs more than last time") : String(localized: "\(rises.count) items cost more than last time"))
                            .font(.subheadline.weight(.semibold))
                    }
                }
            } header: {
                Label("Up since last time", systemImage: "arrow.up.right")
                    .foregroundStyle(.red)
            } footer: {
                Text("Compared with the last invoice from this supplier, even when it's still within your agreed price.")
            }
        }
    }
}

/// Every shop side by side: spend, overcharges and credits.
struct CompareShopsView: View {
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @State private var period = "month"

    private var range: (since: String?, until: String?) {
        let calendar = Calendar.current
        let now = Date()
        func start(_ unit: Calendar.Component, back: Int = 0) -> String? {
            guard let begin = calendar.dateInterval(of: unit, for: now)?.start,
                  let date = calendar.date(byAdding: unit, value: -back, to: begin) else { return nil }
            return SupplierAccounts.dayText(date)
        }
        switch period {
        case "month": return (start(.month), nil)
        case "lastMonth": return (start(.month, back: 1), start(.month))
        case "90": return (SupplierAccounts.dayText(now.addingTimeInterval(-90 * 86_400)), nil)
        case "year": return (start(.year), nil)
        default: return (nil, nil)
        }
    }

    var body: some View {
        let rows = Insights.compareShops(reports.compactMap { $0.entry }, shops: Shops.all, since: range.since, until: range.until)
        let maxOver = rows.map { $0.overchargedPercent }.max() ?? 0
        List {
            Section {
                Picker("Period", selection: $period) {
                    Text("This month").tag("month")
                    Text("Last month").tag("lastMonth")
                    Text("Last 90 days").tag("90")
                    Text("This year").tag("year")
                    Text("All time").tag("all")
                }
            }
            if rows.count < 2 {
                ContentUnavailableView {
                    Label("Add your shops first", systemImage: "storefront")
                } description: {
                    Text("Add your shops in Settings › Shops and choose a shop when you scan. Then each shop's figures appear here side by side.")
                }
            } else {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 10) {
                            GridRow {
                                Text("")
                                ForEach(rows) { row in
                                    Text(row.name)
                                        .font(.subheadline.weight(.bold))
                                        .lineLimit(2)
                                        .frame(minWidth: 90, alignment: .trailing)
                                }
                            }
                            Divider()
                            metric("Invoices", rows) { Text("\($0.invoices)") }
                            metric("Spent", rows) { Text(Money.format($0.spent)).fontWeight(.semibold) }
                            metric("Overcharged", rows) { row in
                                Text(Money.format(row.overcharged))
                                    .foregroundStyle(row.overcharged > 0.005 ? Color.red : Color.secondary)
                            }
                            metric("Of spend", rows) { row in
                                Text("\(row.overchargedPercent.formatted(.number.precision(.fractionLength(1))))%")
                                    .fontWeight(row.overchargedPercent >= maxOver && maxOver > 0 ? .bold : .regular)
                                    .foregroundStyle(row.overchargedPercent >= maxOver && maxOver > 0 ? Color.red : Color.primary)
                            }
                            metric("Credits owed", rows) { row in
                                Text(Money.format(row.creditsOwed))
                                    .foregroundStyle(row.creditsOwed > 0.005 ? Color.orange : Color.secondary)
                            }
                            metric("Credits received", rows) { Text(Money.format($0.creditsReceived)) }
                            metric("Top supplier", rows) { row in
                                Text(row.topSupplier.isEmpty ? "–" : row.topSupplier)
                                    .lineLimit(2)
                                    .font(.footnote)
                            }
                        }
                        .font(.subheadline)
                        .padding(.vertical, 6)
                    }
                } footer: {
                    Text("Swipe sideways to see every shop. The shop overcharged most, as a share of its spend, is in red.")
                }
                Section("Overcharged, as a share of spend") {
                    ForEach(rows.sorted { $0.overchargedPercent > $1.overchargedPercent }) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.name)
                                Spacer()
                                Text("\(row.overchargedPercent.formatted(.number.precision(.fractionLength(1))))%")
                                    .fontWeight(.semibold)
                            }
                            .font(.subheadline)
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(Color.red.opacity(0.75))
                                    .frame(width: maxOver > 0 ? proxy.size.width * row.overchargedPercent / maxOver : 0)
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
        }
        .navigationTitle("Compare shops")
    }

    private func metric<V: View>(_ title: LocalizedStringKey, _ rows: [ShopFigures], @ViewBuilder value: @escaping (ShopFigures) -> V) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
                .lineLimit(1)
            ForEach(rows) { row in
                value(row)
            }
        }
    }
}

/// Every supplier with enough invoices, best score first.
struct SupplierScoresView: View {
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @ObservedObject private var accounts = Accounts.shared

    var body: some View {
        let all = reports.compactMap { $0.entry }
        let entries = accounts.inShop(all)
        let list = SupplierAccounts.accounts(entries: entries, payments: accounts.shopPayments(all), trusted: accounts.trusted)
            .filter { !$0.trusted && !$0.entries.isEmpty }
            .map { (account: $0, profile: SupplierProfiles.make($0, all: entries)) }
            .sorted { ($0.profile.score ?? -1, $0.account.name) > ($1.profile.score ?? -1, $1.account.name) }
        List {
            if list.isEmpty {
                ContentUnavailableView("No suppliers yet", systemImage: "shippingbox")
            }
            Section {
                ForEach(list.indices, id: \.self) { index in
                    let row = list[index]
                    NavigationLink {
                        SupplierDetailView(key: row.account.id)
                    } label: {
                        HStack(spacing: 12) {
                            ScoreBadge(score: row.profile.score)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.account.name)
                                    .font(.subheadline.weight(.semibold))
                                Text(row.profile.invoices == 1 ? String(localized: "1 invoice") : String(localized: "\(row.profile.invoices) invoices"))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Out of 100: how often they charge your agreed price, deliver in full, keep prices steady, and how their prices compare with your other suppliers. Trusted suppliers aren't scored.")
            }
        }
        .navigationTitle("Supplier scores")
    }
}
