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
        let summary = Insights.month(month, entries: reports.compactMap { $0.entry }, payments: accounts.payments,
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
        guard SmartCheck.status.isEmpty, !facts.isEmpty else { return nil }
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
