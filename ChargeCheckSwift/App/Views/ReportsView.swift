import SwiftUI
import SwiftData
import QuickLook
import ChargeCheckCore

/// Every checked invoice, what to pay each supplier, and exports for the accountant.
struct ReportsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var store: Store
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @AppStorage(SettingKey.paySkipped) private var skippedText = ""
    @AppStorage(SettingKey.payBeforeVat) private var beforeVat = false

    @State private var showChoose = false
    @State private var showExport = false
    @State private var confirmPaid = false
    @State private var notice: String?
    @State private var undoPaid: Set<String> = []

    @AppStorage(Shops.listKey) private var shopData = Data()
    /// "" = every shop
    @State private var shopFilter = ""

    private var shops: [ShopInfo] { Shops.decode(shopData) }

    private var entries: [HistoryEntry] {
        let all = reports.compactMap { $0.entry }
        if shopFilter.isEmpty || !shops.contains(where: { $0.id == shopFilter }) { return all }
        return all.filter { $0.shopId == shopFilter }
    }

    private var skipped: Set<String> {
        Set(skippedText.split(separator: ",").map(String.init))
    }

    private func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: Date())
    }

    /// Only used by the cloud check ("-demoReport YES") to open an invoice's details.
    @State private var demoPath: [String] = []

    var body: some View {
        NavigationStack(path: $demoPath) {
            let list = entries
            let pay = ReportMaths.paySummary(list, skipped: skipped, beforeVat: beforeVat)
            List {
                if list.isEmpty {
                    ContentUnavailableView {
                        Label(reports.isEmpty ? "No reports yet" : "No invoices for this shop", systemImage: "chart.bar")
                    } description: {
                        Text(reports.isEmpty ? "Every invoice you check is kept here, with what each supplier overcharged." : "Choose “All shops” at the top to see every invoice.")
                    }
                } else {
                    Section {
                        LabeledContent("Overcharged, all time") {
                            Text(Money.format(Money.round2(list.reduce(0) { $0 + $1.over })))
                                .foregroundStyle(.red)
                                .fontWeight(.bold)
                        }
                        LabeledContent("Invoices checked", value: "\(list.count)")
                        LabeledContent("Spend checked", value: Money.format(Money.round2(list.reduce(0) { $0 + $1.net })))
                        let owed = ReportMaths.creditsOwed(list)
                        if owed.count > 0 {
                            LabeledContent(owed.count == 1 ? String(localized: "1 credit still owed") : String(localized: "\(owed.count) credits still owed")) {
                                Text(Money.format(owed.amount))
                                    .foregroundStyle(.orange)
                                    .fontWeight(.semibold)
                            }
                        }
                        let received = ReportMaths.creditsReceived(list)
                        if received.count > 0 {
                            LabeledContent("Credits received", value: Money.format(received.amount))
                        }
                        Button {
                            showExport = true
                        } label: {
                            Label("Export for your accountant", systemImage: "square.and.arrow.up")
                        }
                        NavigationLink {
                            MonthlySummaryView()
                        } label: {
                            Label("Monthly summary", systemImage: "text.alignleft")
                        }
                        if shops.count > 1 {
                            NavigationLink {
                                CompareShopsView()
                            } label: {
                                Label("Compare shops", systemImage: "storefront")
                            }
                        }
                    }
                    paySection(pay)
                    Section("Checked invoices") {
                        ForEach(list) { entry in
                            NavigationLink(value: entry.id) {
                                ReportRow(entry: entry)
                            }
                        }
                        .onDelete { offsets in
                            for id in offsets.map({ list[$0].id }) { AppData.deleteReport(id, context: context) }
                        }
                        // staff phones: only the owner removes invoices
                        .deleteDisabled(CloudTeam.shared.isStaff)
                    }
                }
            }
            .navigationTitle("Reports")
            .toolbar {
                if !shops.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Picker("Shop", selection: $shopFilter) {
                            Text("All shops").tag("")
                            ForEach(shops, id: \.id) { shop in
                                Text(shop.name).tag(shop.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            .navigationDestination(for: String.self) { id in
                ReportDetailView(reportID: id)
            }
            .task {
                // the cloud check: open an overcharged invoice ("-demoCredit YES" marks its credit as asked for)
                guard UserDefaults.standard.bool(forKey: "demoReport"), demoPath.isEmpty,
                      let first = entries.first(where: { $0.amountToPay.less > 0 }) ?? entries.first else { return }
                if UserDefaults.standard.bool(forKey: "demoCredit"), first.credit == nil {
                    AppData.updateReports([first.id], context: context) { saved in
                        saved.credit = CreditInfo(status: CreditInfo.requested, amount: first.amountToPay.less,
                                                  at: ISO8601DateFormatter().string(from: Date()))
                    }
                }
                demoPath = [first.id]
            }
            .sheet(isPresented: $showChoose) {
                PayChooseView(entries: pay.unpaid, skippedText: $skippedText)
            }
            .sheet(isPresented: $showExport) {
                ExportView(entries: list)
            }
            .confirmationDialog("Mark \(pay.selected.count == 1 ? "1 invoice" : "\(pay.selected.count) invoices") as paid (\(Money.format(pay.pay)))?",
                                isPresented: $confirmPaid, titleVisibility: .visible) {
                Button("Mark as paid") {
                    let ids = Set(pay.selected.map { $0.id })
                    Accounts.shared.markPaid(pay.selected, context: context)
                    undoPaid = ids
                    AutoBackup.run(context, scans: store.ledger.forBackup)
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private func paySection(_ pay: PaySummary) -> some View {
        Section {
            if pay.unpaid.isEmpty {
                Text("Nothing to pay. Every checked invoice is marked as paid.")
                    .foregroundStyle(.secondary)
                if !undoPaid.isEmpty { undoButton }
            } else {
                Picker("VAT", selection: $beforeVat) {
                    Text("Including VAT").tag(false)
                    Text("Before VAT").tag(true)
                }
                .pickerStyle(.segmented)
                Button {
                    showChoose = true
                } label: {
                    LabeledContent {
                        Text("Choose")
                    } label: {
                        Label("\(pay.selected.count) of \(pay.unpaid.count) unpaid invoices selected", systemImage: "checklist")
                    }
                }
                ForEach(pay.suppliers) { supplier in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(supplier.name)
                            Text(String(localized: "Invoiced \(Money.format(supplier.total))") + (supplier.less > 0 ? " − \(Money.format(supplier.less))" : ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(Money.format(supplier.pay))
                            .fontWeight(.semibold)
                    }
                }
                if !pay.selected.isEmpty {
                    LabeledContent("Invoice totals", value: Money.format(pay.total))
                    if pay.less > 0 {
                        LabeledContent(pay.hasMissing ? "Overcharged / missing – take off" : "Overcharged – take off") {
                            Text("−" + Money.format(pay.less))
                                .foregroundStyle(.red)
                        }
                    }
                    LabeledContent {
                        Text(Money.format(pay.pay))
                            .font(.title2.weight(.heavy))
                            .foregroundStyle(.tint)
                    } label: {
                        Text("Amount to pay")
                        Text(beforeVat ? "Before VAT" : "Including VAT")
                    }
                    Group {
                        if beforeVat {
                            Text(pay.vat > 0.005
                                 ? String(localized: "With VAT it would be \(Money.format(pay.payWithVat)) (VAT \(Money.format(pay.vat)))")
                                 : String(localized: "These invoices have no VAT"))
                        } else {
                            Text("Before VAT \(Money.format(pay.payBeforeVat)) + VAT \(Money.format(pay.vat))")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    Button {
                        UIPasteboard.general.string = ReportMaths.paymentText(pay, today: today())
                        notice = String(localized: "Breakdown copied. Paste it into a message to your supplier.")
                    } label: {
                        Label("Copy breakdown", systemImage: "doc.on.doc")
                    }
                    // staff phones: payments are the owner's
                    if !CloudTeam.shared.isStaff {
                        Button {
                            confirmPaid = true
                        } label: {
                            Label("Mark as paid", systemImage: "checkmark.circle")
                        }
                    }
                }
                if !undoPaid.isEmpty { undoButton }
            }
        } header: {
            Text("To pay")
        } footer: {
            Text(beforeVat ? "Invoice totals before VAT, less overcharges and missing or returned items. Choose “Before VAT” for a shop that isn’t VAT registered."
                           : "Invoice totals with VAT, less overcharges and missing or returned items.")
        }
    }

    private var undoButton: some View {
        Button("Undo “mark as paid”") {
            Accounts.shared.markUnpaid(undoPaid, context: context)
            undoPaid = []
        }
    }
}

struct ReportRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.supplier.isEmpty ? L("Invoice") : entry.supplier)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 12)
                if entry.totalOnly {
                    Text(Money.format(entry.total))
                        .font(.subheadline.weight(.bold))
                } else {
                    Text(entry.over > 0.005 ? Money.format(entry.over) : L("OK"))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(entry.over > 0.005 ? Color.red : Color.green)
                }
            }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if !entry.invNo.isEmpty { parts.append("#" + entry.invNo) }
        if !entry.date.isEmpty { parts.append(entry.date) }
        if entry.totalOnly {
            parts.append(String(localized: "trusted supplier, prices not checked"))
        } else {
            parts.append(String(localized: "total \(Money.format(entry.total))"))
        }
        if entry.paid != nil { parts.append(String(localized: "paid")) }
        if !entry.verified { parts.append(String(localized: "not fully checked")) }
        return parts.joined(separator: " · ")
    }
}

/// Tick the unpaid invoices to include in "Amount to pay". Everything is ticked to begin with.
struct PayChooseView: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [HistoryEntry]
    @Binding var skippedText: String

    private var skipped: Set<String> { Set(skippedText.split(separator: ",").map(String.init)) }

    private func set(_ ids: Set<String>) {
        skippedText = ids.sorted().joined(separator: ",")
    }

    private var suppliers: [String] {
        var seen = Set<String>()
        return entries.map { $0.supplier.isEmpty ? L("Unknown supplier") : $0.supplier }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        NavigationStack {
            let pay = ReportMaths.paySummary(entries, skipped: skipped, beforeVat: UserDefaults.standard.bool(forKey: SettingKey.payBeforeVat))
            List {
                Section {
                    Button("Select all") { set([]) }
                    Button("Select none") { set(Set(entries.map { $0.id })) }
                    if suppliers.count > 1 {
                        ForEach(suppliers, id: \.self) { name in
                            Button("Only \(name)") {
                                set(Set(entries.filter { ($0.supplier.isEmpty ? L("Unknown supplier") : $0.supplier) != name }.map { $0.id }))
                            }
                        }
                    }
                }
                Section {
                    ForEach(entries) { entry in
                        let amounts = entry.amountToPay(beforeVat: pay.beforeVat)
                        Toggle(isOn: Binding(
                            get: { !skipped.contains(entry.id) },
                            set: { isOn in
                                var ids = skipped
                                if isOn { ids.remove(entry.id) } else { ids.insert(entry.id) }
                                set(ids)
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((entry.supplier.isEmpty ? L("Invoice") : entry.supplier) + (entry.invNo.isEmpty ? "" : "  #" + entry.invNo))
                                    .font(.subheadline.weight(.semibold))
                                Text(String(localized: "\(entry.date) · invoiced \(Money.format(amounts.total))") + (amounts.less > 0 ? " − \(Money.format(amounts.less))" : "") + " · " + String(localized: "pay \(Money.format(amounts.pay))"))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("\(pay.selected.count) of \(pay.unpaid.count) selected · pay \(Money.format(pay.pay))")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .navigationTitle("Choose invoices to pay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// One saved invoice: its lines, the original photo or PDF, and a credit request for the supplier.
struct ReportDetailView: View {
    let reportID: String

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var reports: [StoredReport]
    @AppStorage(SettingKey.business) private var business = ""
    @AppStorage(SettingKey.colour) private var colourID = "green"
    @State private var preview: URL?
    @State private var confirmDelete = false
    @State private var copied = false

    private var entry: HistoryEntry? { reports.first { $0.uid == reportID }?.entry }

    static func lineDetail(_ line: HistoryLine) -> String {
        var parts = ["\(PDFMaker.quantity(line.qty)) × \(Money.format(line.unit))"]
        if let base = line.base { parts.append(String(localized: "your price \(Money.format(base))")) }
        if line.excluded {
            parts.append(String(localized: "missing or returned"))
        } else if line.short > 0 {
            parts.append(String(localized: "\(PDFMaker.quantity(line.short)) didn't arrive"))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if let entry {
                let amounts = entry.amountToPay
                List {
                    Section {
                        LabeledContent("Supplier", value: entry.supplier)
                        if !entry.invNo.isEmpty { LabeledContent("Invoice no.", value: entry.invNo) }
                        if !entry.date.isEmpty { LabeledContent("Date", value: entry.date) }
                        LabeledContent("Invoice total", value: Money.format(amounts.total))
                        if amounts.less > 0 {
                            LabeledContent("Overcharged / missing") {
                                Text("−" + Money.format(amounts.less))
                                    .foregroundStyle(.red)
                            }
                        }
                        LabeledContent("To pay") {
                            Text(Money.format(amounts.pay))
                                .fontWeight(.bold)
                        }
                        Toggle("Paid", isOn: Binding(
                            get: { entry.paid != nil },
                            set: { isOn in
                                if isOn {
                                    Accounts.shared.markPaid([entry], context: context)
                                } else {
                                    Accounts.shared.markUnpaid([entry.id], context: context)
                                }
                            }
                        ))
                        .disabled(CloudTeam.shared.isStaff)
                    }
                    Section {
                        if let path = entry.file, let url = AppFiles.url(forRelativePath: path) {
                            Button {
                                preview = url
                            } label: {
                                Label("Original invoice", systemImage: "doc.text.magnifyingglass")
                            }
                            ShareLink(item: url) {
                                Label("Send the original invoice", systemImage: "square.and.arrow.up")
                            }
                        }
                        if amounts.less > 0 {
                            let message = ReportMaths.creditText(entry, business: business)
                            ShareLink(item: message, subject: Text("Credit request"), message: nil) {
                                Label("Credit request message (WhatsApp, email…)", systemImage: "text.bubble")
                            }
                            Button {
                                UIPasteboard.general.string = message
                                copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy the credit request", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            if let url = creditRequest(entry) {
                                ShareLink(item: url) {
                                    Label("Credit request for the supplier (PDF)", systemImage: "doc.richtext")
                                }
                            }
                        }
                    }
                    if amounts.less > 0 {
                        creditSection(entry, amount: amounts.less)
                    }
                    Section("Lines") {
                        ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.item.isEmpty ? line.desc : line.item)
                                        .font(.subheadline.weight(.semibold))
                                        .strikethrough(line.excluded)
                                    Text(Self.lineDetail(line))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if line.over > 0.005 && !line.excluded {
                                    Text("+" + Money.format(line.over))
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    Section {
                        Button("Delete this report", role: .destructive) {
                            guard !CloudTeam.shared.isStaff else { return }
                            confirmDelete = true
                        }
                    } footer: {
                        Text("The copy of the original invoice in the Files app is kept.")
                    }
                }
            } else {
                ContentUnavailableView("Report removed", systemImage: "doc.text")
            }
        }
        .navigationTitle("Invoice")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($preview)
        .confirmationDialog("Delete this report?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                AppData.deleteReport(reportID, context: context)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Keeps track of the credit: asked for, then received. A reminder comes after two weeks if it hasn't arrived.
    @ViewBuilder
    private func creditSection(_ entry: HistoryEntry, amount: Double) -> some View {
        Section {
            if let credit = entry.credit, credit.status == CreditInfo.received {
                Label("Credit of \(Money.format(credit.amount)) received", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Button("Not received after all") { setCredit(entry, nil, amount: amount) }
            } else if let credit = entry.credit, credit.isOwed {
                Label(String(localized: "Asked for \(Money.format(credit.amount))") + (credit.at.map { " · " + shortDate($0) } ?? ""), systemImage: "hourglass")
                    .foregroundStyle(.orange)
                Button {
                    setCredit(entry, CreditInfo.received, amount: credit.amount)
                } label: {
                    Label("Credit received", systemImage: "checkmark.circle")
                }
                Button("I haven't asked yet") { setCredit(entry, nil, amount: amount) }
            } else {
                Button {
                    setCredit(entry, CreditInfo.requested, amount: amount)
                } label: {
                    Label("I've asked for this credit", systemImage: "paperplane")
                }
            }
        } header: {
            Text("Credit")
        } footer: {
            Text("Mark the credit as asked for, and ChargeCheck reminds you after \(CreditReminder.days) days if it hasn't arrived.")
        }
    }

    private func setCredit(_ entry: HistoryEntry, _ status: String?, amount: Double) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let asked = entry.credit?.at
        AppData.updateReports([entry.id], context: context) { saved in
            if let status {
                saved.credit = CreditInfo(status: status, amount: amount, at: asked ?? stamp,
                                          paidAt: status == CreditInfo.received ? stamp : nil)
            } else {
                saved.credit = nil
            }
        }
        if status == CreditInfo.requested {
            Task { await CreditReminder.set(for: entry, amount: amount) }
        } else {
            CreditReminder.cancel(for: entry.id)
        }
    }

    private func shortDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func creditRequest(_ entry: HistoryEntry) -> URL? {
        let data = PDFMaker.creditRequest(entry, business: business, theme: Themes.named(colourID))
        return AppFiles.write(data, folder: "Exports", name: "Credit request " + ReportMaths.copyName(for: entry) + ".pdf")
    }
}

/// Export a period as a PDF or a spreadsheet, then save or send it.
struct ExportView: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [HistoryEntry]

    @AppStorage(SettingKey.business) private var business = ""
    @AppStorage(SettingKey.colour) private var colourID = "green"
    @State private var period = ReportPeriod.lastMonth
    @State private var made: URL?
    @State private var problem: String?

    private var chosen: [HistoryEntry] {
        ReportMaths.entries(entries, in: period, now: Date())
    }

    private func name(_ ending: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "ChargeCheck report " + period.title.lowercased() + " " + formatter.string(from: Date()) + "." + ending
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Period", selection: $period) {
                        ForEach(ReportPeriod.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } footer: {
                    Text(chosen.isEmpty ? "No checked invoices in this period." : "\(chosen.count == 1 ? "1 invoice" : "\(chosen.count) invoices") · overcharged \(Money.format(Money.round2(chosen.reduce(0) { $0 + $1.over })))")
                }
                Section {
                    Button {
                        let data = PDFMaker.report(chosen, period: period.title, business: business, theme: Themes.named(colourID))
                        finish(AppFiles.write(data, folder: "Exports", name: name("pdf")))
                    } label: {
                        Label("Make a PDF", systemImage: "doc.richtext")
                    }
                    Button {
                        let data = Data(("\u{FEFF}" + ReportMaths.reportCSV(chosen)).utf8)
                        finish(AppFiles.write(data, folder: "Exports", name: name("csv")))
                    } label: {
                        Label("Make a spreadsheet (CSV)", systemImage: "tablecells")
                    }
                }
                .disabled(chosen.isEmpty)
                if let made {
                    Section {
                        ShareLink(item: made) {
                            Label("Save or send “\(made.lastPathComponent)”", systemImage: "square.and.arrow.up")
                        }
                    } footer: {
                        Text("Also kept in the Files app › On My iPhone › ChargeCheck › Exports.")
                    }
                }
                if let problem {
                    Text(problem)
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: period) {
                made = nil
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func finish(_ url: URL?) {
        made = url
        problem = url == nil ? String(localized: "The file couldn't be made. Please try again.") : nil
    }
}
