import SwiftUI
import SwiftData
import ChargeCheckCore

struct LineDraft: Identifiable {
    let id = UUID()
    var line: CheckLine
    var isNew: Bool
}

/// One invoice: what was read, what each line should have cost, and what was overcharged.
struct InvoiceDetailView: View {
    let jobID: String

    @EnvironmentObject private var session: CheckSession
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var prices: [StoredPrice]
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @State private var editing: LineDraft?
    @State private var checkingDelivery = false

    private var job: InvoiceJob? { session.job(jobID) }

    private func items(_ job: InvoiceJob) -> [PriceItem] {
        job.isSample ? SampleInvoice.prices : prices.map { $0.item }
    }

    var body: some View {
        Group {
            if let job {
                if job.status == .reading {
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text(job.message)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    content(job, book: PriceBook(items(job)))
                }
            } else {
                ContentUnavailableView("Invoice removed", systemImage: "doc.text")
            }
        }
        .navigationTitle(job?.draft.supplier.isEmpty == false ? (job?.draft.supplier ?? "") : "Invoice")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { draft in
            if let job {
                LineEditView(draft: draft, supplier: job.draft.supplier, items: items(job), isSample: job.isSample,
                             onSave: { saveLine($0, original: draft) },
                             onDelete: deleteAction(for: draft))
            }
        }
        .sheet(isPresented: $checkingDelivery) {
            if let job {
                DeliveryCheckView(lines: job.draft.lines) { received in
                    change { draft in
                        for index in draft.lines.indices {
                            if let got = received[draft.lines[index].id] {
                                draft.lines[index].short = max(0, draft.lines[index].qty - got)
                            }
                        }
                    }
                }
            }
        }
    }

    private func change(_ edit: (inout InvoiceDraft) -> Void) {
        session.update(jobID) { edit(&$0.draft) }
        session.saveIfChecked(jobID, context: context)
    }

    private func saveLine(_ line: CheckLine, original: LineDraft) {
        if !original.isNew && original.line.desc != line.desc && !line.read.isEmpty {
            NameFixes.learn(read: line.read, corrected: line.desc)
        }
        // remember how this supplier writes the item, so it is recognised next time
        if let id = line.matchId, id != original.line.matchId, job?.isSample == false,
           let stored = prices.first(where: { $0.uid == id }) {
            var item = stored.item
            let spelling = TextTools.norm(line.desc)
            if !spelling.isEmpty && !item.aliases.contains(spelling) {
                item.aliases.append(spelling)
                stored.update(from: item)
            }
        }
        change { draft in
            if let index = draft.lines.firstIndex(where: { $0.id == line.id }) {
                draft.lines[index] = line
            } else {
                draft.lines.append(line)
            }
        }
    }

    private func deleteAction(for draft: LineDraft) -> (() -> Void)? {
        if draft.isNew { return nil }
        let id = draft.line.id
        return { deleteLine(id) }
    }

    private func deleteLine(_ id: String) {
        change { $0.lines.removeAll { $0.id == id } }
    }

    private func addMissing(_ job: InvoiceJob, book: PriceBook) {
        var all = book.items
        change { draft in
            for index in draft.lines.indices where draft.lines[index].matchId == nil && !draft.lines[index].excluded && !draft.lines[index].noBase {
                let line = draft.lines[index]
                let name = line.desc.trimmingCharacters(in: .whitespaces)
                if name.isEmpty || line.unit <= 0 { continue }
                var item = PriceItem(cat: "Other", name: name.capitalized, price: Money.round2(line.unit), supplier: draft.supplier, aliases: [TextTools.norm(name)])
                item.cat = Categoriser.suggest(for: item, in: all) ?? "Other"
                all.append(item)
                AppData.save(item, in: context)
                draft.lines[index].matchId = item.id
                draft.lines[index].confident = true
            }
        }
    }

    @ViewBuilder
    private func content(_ job: InvoiceJob, book: PriceBook) -> some View {
        if let note = job.creditNote {
            CreditNoteView(job: job, note: note, change: change, apply: { session.applyCreditNote(jobID, context: context) }, remove: {
                session.remove(jobID)
                dismiss()
            })
        } else if job.draft.totalOnly {
            TotalOnlyView(job: job, change: change, remove: {
                session.remove(jobID)
                dismiss()
            })
        } else {
            checkedContent(job, book: book)
        }
    }

    @ViewBuilder
    private func checkedContent(_ job: InvoiceJob, book: PriceBook) -> some View {
        let totals = InvoiceMaths.totals(job.draft, book: book, tolerance: AppData.tolerance)
        let missing = job.draft.lines.filter { $0.matchId == nil && !$0.excluded && !$0.noBase && $0.unit > 0 && !$0.desc.isEmpty }.count
        List {
            Section {
                Hero(totals: totals, empty: job.draft.lines.isEmpty, message: job.message, sample: job.isSample)
            }
            Section("Invoice") {
                LabeledContent("Supplier") {
                    TextField("Supplier", text: Binding(get: { job.draft.supplier }, set: { value in change { $0.supplier = value } }))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Invoice no.") {
                    TextField("Number", text: Binding(get: { job.draft.invNo }, set: { value in change { $0.invNo = value } }))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Date") {
                    TextField("dd/mm/yyyy", text: Binding(get: { job.draft.date }, set: { value in change { $0.date = value } }))
                        .multilineTextAlignment(.trailing)
                }
            }
            Section {
                ForEach(job.draft.lines) { line in
                    Button {
                        editing = LineDraft(line: line, isNew: false)
                    } label: {
                        LineRow(line: line, result: InvoiceMaths.lineResult(line, supplier: job.draft.supplier, book: book, tolerance: AppData.tolerance),
                                reasons: InvoiceMaths.reasons(line, supplier: job.draft.supplier, book: book, totalOk: totals.totalOk))
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteLine(line.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                Button {
                    editing = LineDraft(line: CheckLine(), isNew: true)
                } label: {
                    Label("Add a line", systemImage: "plus")
                }
                if missing > 0 && !job.isSample {
                    Button {
                        addMissing(job, book: book)
                    } label: {
                        Label(missing == 1 ? "Add 1 new item to my price list" : "Add \(missing) new items to my price list", systemImage: "tag")
                    }
                }
            } header: {
                Text(job.draft.lines.count == 1 ? "1 line" : "\(job.draft.lines.count) lines")
            } footer: {
                if missing > 0 && !job.isSample {
                    Text("New items are added at the price on this invoice, so you'll be told if it goes up next time.")
                }
            }
            if !job.isSample {
                PriceRiseSection(rises: Insights.priceRises(on: job.draft.lines, supplier: job.draft.supplier,
                                                            history: reports.compactMap { $0.entry }, excluding: job.draft.id))
            }
            Section {
                Button {
                    checkingDelivery = true
                } label: {
                    Label("Check the delivery", systemImage: "shippingbox.and.arrow.backward")
                }
            } footer: {
                Text("Tick off what arrived. Anything short comes off what you pay and goes into the credit request.")
            }

            Section("Totals") {
                LabeledContent("Net", value: Money.format(totals.net))
                LabeledContent("VAT", value: Money.format(totals.vat))
                LabeledContent("Invoice total", value: Money.format(totals.total))
                if totals.excluded > 0 {
                    LabeledContent("Missing or returned", value: Money.format(totals.excluded))
                }
                if totals.over > 0.005 {
                    LabeledContent("Overcharged") {
                        Text(Money.format(totals.over))
                            .fontWeight(.bold)
                            .foregroundStyle(.red)
                    }
                    LabeledContent("You should pay") {
                        Text(Money.format(Money.round2(totals.total - totals.over - totals.overVat)))
                            .fontWeight(.bold)
                    }
                }
                if totals.totalKnown {
                    if totals.totalOk {
                        Label("Adds up to the total printed on the invoice", systemImage: "checkmark.seal.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("The lines add up to \(Money.format(totals.net)) but the invoice says \(Money.format(job.draft.printedNet ?? 0)). A line may be missing or misread.", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                            if !job.draft.totalAcknowledged {
                                Button("I've checked – it's fine") {
                                    change { $0.totalAcknowledged = true }
                                }
                                .font(.footnote.weight(.semibold))
                            }
                        }
                    }
                }
            }
            if !job.isSample {
                Section {
                    if job.saved == job.draft {
                        Label("Saved in Reports", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if !job.draft.lines.isEmpty {
                        Button("Save to Reports anyway") {
                            session.saveIfChecked(jobID, context: context, anyway: true)
                        }
                    }
                } footer: {
                    Text("An invoice is saved to Reports by itself once every line is checked.")
                }
            }
            Section {
                Button("Remove this invoice from the list", role: .destructive) {
                    session.remove(jobID)
                    dismiss()
                }
            } footer: {
                if job.saved != nil { Text("It stays in Reports.") }
            }
        }
    }
}

/// Tick off what arrived, line by line.
struct DeliveryCheckView: View {
    let lines: [CheckLine]
    let save: ([String: Double]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var received: [String: Double] = [:]

    private var shortValue: Double {
        lines.reduce(0) { sum, line in
            let got = received[line.id] ?? line.received
            return sum + Money.round2(max(0, line.qty - got) * line.unit)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(lines.filter { !$0.excluded && $0.qty > 0 }) { line in
                        let got = received[line.id] ?? line.received
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: got >= line.qty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .foregroundStyle(got >= line.qty ? Color.green : Color.orange)
                                Text(line.desc.isEmpty ? L("New line") : line.desc)
                                    .font(.subheadline.weight(.semibold))
                            }
                            Stepper(value: Binding(get: { got }, set: { received[line.id] = min(line.qty, max(0, $0)) }),
                                    in: 0...line.qty, step: 1) {
                                Text("Arrived: \(PDFMaker.quantity(got)) of \(PDFMaker.quantity(line.qty))")
                                    .font(.footnote)
                                    .foregroundStyle(got >= line.qty ? Color.secondary : Color.orange)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // a tap switches between all arrived and none arrived
                            received[line.id] = got >= line.qty ? 0 : line.qty
                        }
                    }
                } footer: {
                    Text("Tap an item to switch between all arrived and none arrived, or use − and + for part of it.")
                }
                Section {
                    LabeledContent("Short", value: Money.format(shortValue))
                        .fontWeight(.semibold)
                    Button("Everything arrived") {
                        for line in lines { received[line.id] = line.qty }
                    }
                }
            }
            .navigationTitle("Check the delivery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var all: [String: Double] = [:]
                        for line in lines { all[line.id] = received[line.id] ?? line.received }
                        save(all)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// A scanned credit note: it's not saved as an invoice, it pays off a credit or lowers what you owe.
struct CreditNoteView: View {
    let job: InvoiceJob
    let note: CreditNoteResult
    let change: ((inout InvoiceDraft) -> Void) -> Void
    let apply: () -> Void
    let remove: () -> Void

    @State private var totalText = ""
    @FocusState private var totalFocused: Bool

    private var edited: Bool {
        job.draft.supplier != note.supplier || job.draft.invNo != note.number || Money.round2(job.draft.printedTotal ?? 0) != note.amount
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.green)
                    Text("Credit note")
                        .font(.headline)
                    Text(Money.format(note.amount))
                        .font(.largeTitle.weight(.heavy))
                    Text(note.message)
                        .font(.footnote)
                        .foregroundStyle(note.amount > 0 ? Color.secondary : Color.orange)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section {
                LabeledContent("Supplier") {
                    TextField("Supplier", text: Binding(get: { job.draft.supplier }, set: { value in change { $0.supplier = value } }))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Number") {
                    TextField("Number", text: Binding(get: { job.draft.invNo }, set: { value in change { $0.invNo = value } }))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Credit total") {
                    TextField("0.00", text: $totalText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($totalFocused)
                        .fontWeight(.semibold)
                }
                if edited {
                    Button {
                        totalFocused = false
                        commit()
                        apply()
                    } label: {
                        Label("Use the corrected details", systemImage: "checkmark.circle")
                    }
                }
            } header: {
                Text("Credit note")
            } footer: {
                Text("A credit note isn't saved as an invoice. If you asked for this credit, it's marked as received. Otherwise it comes off what you owe the supplier.")
            }
            Section {
                Button("Remove from the list", role: .destructive, action: remove)
            }
        }
        .onAppear { totalText = note.amount > 0 ? String(format: "%.\(Money.currency.decimals)f", note.amount) : "" }
        .onChange(of: totalFocused) {
            if !totalFocused { commit() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { totalFocused = false }
            }
        }
    }

    private func commit() {
        guard let value = Money.parse(totalText).map(Money.round2), value > 0, value != job.draft.printedTotal else { return }
        change { $0.printedTotal = value }
    }
}

/// A trusted supplier's invoice: just the total, which is added to what you owe them.
struct TotalOnlyView: View {
    let job: InvoiceJob
    let change: ((inout InvoiceDraft) -> Void) -> Void
    let remove: () -> Void

    @State private var totalText = ""
    @FocusState private var totalFocused: Bool

    private func text(_ value: Double?) -> String {
        guard let value, value > 0 else { return "" }
        return String(format: "%.\(Money.currency.decimals)f", value)
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.green)
                    Text(Money.format(job.draft.printedTotal ?? 0))
                        .font(.largeTitle.weight(.heavy))
                    Text("Trusted supplier: only the total was read. The prices weren't checked.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !job.message.isEmpty {
                        Text(job.message)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section {
                LabeledContent("Supplier") {
                    TextField("Supplier", text: Binding(get: { job.draft.supplier }, set: { value in change { $0.supplier = value } }))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Invoice no.") {
                    TextField("Number", text: Binding(get: { job.draft.invNo }, set: { value in change { $0.invNo = value } }))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Date") {
                    TextField("dd/mm/yyyy", text: Binding(get: { job.draft.date }, set: { value in change { $0.date = value } }))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Invoice total") {
                    TextField("0.00", text: $totalText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($totalFocused)
                        .fontWeight(.semibold)
                }
            } header: {
                Text("Invoice")
            } footer: {
                Text("Check the total matches the invoice. Tap it to correct it.")
            }
            Section {
                if job.saved == job.draft {
                    Label("Added to what you owe them in Suppliers", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button {
                    change { $0.totalOnly = false }
                } label: {
                    Label("Check the prices on this invoice", systemImage: "doc.text.magnifyingglass")
                }
            } footer: {
                Text("To stop treating this supplier as trusted, go to Suppliers and turn off “Trusted supplier”.")
            }
            Section {
                Button("Remove this invoice from the list", role: .destructive, action: remove)
            } footer: {
                if job.saved != nil { Text("It stays in Reports.") }
            }
        }
        .onAppear { totalText = text(job.draft.printedTotal) }
        .onChange(of: totalFocused) {
            if !totalFocused { commit() }
        }
        .onSubmit(commit)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { totalFocused = false }
            }
        }
    }

    private func commit() {
        let value = Money.parse(totalText).map(Money.round2)
        guard let value, value > 0, value != job.draft.printedTotal else { return }
        change {
            $0.printedTotal = value
            if let net = $0.printedNet, net > value { $0.printedNet = nil }
        }
    }
}

/// The big result at the top of an invoice.
struct Hero: View {
    let totals: InvoiceTotals
    let empty: Bool
    let message: String
    let sample: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if empty {
                Label("No lines found", systemImage: "questionmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message.isEmpty ? String(localized: "Add the lines by hand with “Add a line”.") : message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if totals.reviewCount > 0 {
                Label(totals.reviewCount == 1 ? "1 thing to check" : "\(totals.reviewCount) things to check", systemImage: "exclamationmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(totals.over > 0.005 ? "Overcharged \(Money.format(totals.over)) so far. Tap the orange lines to confirm them." : "Tap the orange lines to confirm them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if totals.over > 0.005 {
                Text("Overcharged")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Text(Money.format(totals.over))
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(.red)
                Text(totals.overVat > 0 ? "Plus \(Money.format(totals.overVat)) VAT on top. Every line double-checked." : "Every line double-checked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Label("All prices match", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text(totals.under > 0.005 ? "You paid \(Money.format(totals.under)) less than your agreed prices." : "Nothing was charged above your agreed prices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if sample {
                Text("Sample invoice with example prices. Nothing here is saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct LineRow: View {
    let line: CheckLine
    let result: LineResult
    let reasons: [String]

    private func quantity(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(line.desc.isEmpty ? String(localized: "New line") : line.desc)
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(line.excluded)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(reasons, id: \.self) { reason in
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            badge
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        var text = "\(quantity(line.qty)) × \(Money.format(line.unit))"
        if line.excluded { return text + " · " + String(localized: "missing or returned") }
        if line.short > 0 { text += " · " + String(localized: "\(quantity(line.short)) didn't arrive") }
        if let item = result.item, let base = result.base {
            text += " · " + String(localized: "your price \(Money.format(base))")
            if TextTools.norm(item.name) != TextTools.norm(line.desc) { text += " (\(item.name))" }
        } else if line.noBase {
            text += " · " + String(localized: "not in your price list")
        }
        return text
    }

    @ViewBuilder private var badge: some View {
        if line.excluded {
            Text("off")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        } else if !reasons.isEmpty {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        } else if result.over > 0.005 {
            Text("+" + Money.format(result.over))
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.red)
                .monospacedDigit()
        } else if result.item != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Text(Money.format(result.net))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
