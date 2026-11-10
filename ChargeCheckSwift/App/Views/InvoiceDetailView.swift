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
    @State private var editing: LineDraft?

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
