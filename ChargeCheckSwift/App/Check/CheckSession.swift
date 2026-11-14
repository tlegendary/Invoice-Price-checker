import SwiftUI
import SwiftData
import ChargeCheckCore

struct InvoiceJob: Identifiable, Equatable {
    enum Status: Equatable {
        case reading
        case done
    }

    let id: String
    var status: Status
    var message: String
    var draft: InvoiceDraft
    var isSample: Bool
    var thumbnail: UIImage?
    /// The invoice as it was last saved to Reports (nil = not saved yet).
    var saved: InvoiceDraft?
    /// The pictures (and the PDF, if it came from one) so a copy of the original can be kept.
    var pages: [UIImage] = []
    var sourcePDF: Data?
    var copyPath: String?
    /// A supplier's credit note, not an invoice: it's never saved to Reports, it lowers what you owe them instead.
    var creditNote: CreditNoteResult?
    /// A saved invoice this one looks like. It isn't saved until the user says whether it's the same invoice.
    var possibleDuplicate: HistoryEntry?
    /// The user's answer: true = the supplier billed twice (keep both), false = the same invoice (update it).
    var billedTwice: Bool?
}

/// What happened to a scanned credit note.
struct CreditNoteResult: Equatable {
    var supplier: String
    var number: String
    var amount: Double
    /// The invoice whose requested credit this note pays (marked "Credit received").
    var invoiceID: String?
    var invoiceNo: String
    /// The credit recorded against the supplier's balance (when it isn't for a credit you asked for).
    var paymentID: String?

    var message: String {
        if invoiceID != nil {
            return invoiceNo.isEmpty
                ? String(localized: "Credit received. It was already taken off what you pay \(supplier).")
                : String(localized: "Credit received for invoice \(invoiceNo). It was already taken off what you pay \(supplier).")
        }
        if paymentID != nil {
            return String(localized: "\(Money.format(amount)) taken off what you owe \(supplier).")
        }
        return String(localized: "Couldn't read the credit note's total. Type it in.")
    }
}

/// Items that were cheaper on a fully checked invoice than your agreed price. Nothing is changed until you say yes
/// (Ramyar, 14 Nov 2026): a one-off offer must not quietly become your agreed price.
struct LoweredPrices: Identifiable {
    let id = UUID()
    var changes: [PriceChange]
    var before: [PriceItem]
    var supplier: String = ""

    var message: String {
        if changes.count == 1, let one = changes.first {
            return String(localized: "\(one.name) is \(Money.format(one.to)) on this invoice. Your price is \(Money.format(one.from)). Update your price?")
        }
        return String(localized: "\(changes.count) items are cheaper on this invoice than your prices. Update them?")
    }
}

/// What the user corrected a misread name to, so the same misread is fixed next time.
enum NameFixes {
    private static let key = "nameFixes"

    static func all() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func learn(read: String, corrected: String) {
        let from = TextTools.norm(read)
        let to = corrected.trimmingCharacters(in: .whitespaces)
        if from.isEmpty || to.isEmpty || TextTools.norm(to) == from { return }
        var fixes = all()
        fixes[from] = String(to.prefix(120))
        if fixes.count > 800, let oldest = fixes.keys.sorted().first { fixes.removeValue(forKey: oldest) }
        UserDefaults.standard.set(fixes, forKey: key)
    }
}

/// The invoices being checked right now (the Check tab).
@MainActor
final class CheckSession: ObservableObject {
    @Published var jobs: [InvoiceJob] = []
    /// Invoices shared into the app from WhatsApp, Mail or Files, waiting for the Check tab to read them.
    @Published var incoming: [URL] = []
    /// Siri / Shortcuts asked to scan an invoice: the Check tab opens the camera.
    @Published var openScanner = false
    /// A copy of an invoice the user may want to save somewhere else too ("ask" setting).
    @Published var offerCopy: URL?
    /// Agreed prices that were just lowered to a cheaper invoice price (with what they were, to undo).
    @Published var lowered: LoweredPrices?
    private var loweredOnce = Set<String>()
    /// Called after anything is saved to Reports (used to refresh the automatic backup).
    var onSaved: (() -> Void)?
    private var queue: Task<Void, Never>?

    func job(_ id: String) -> InvoiceJob? {
        jobs.first { $0.id == id }
    }

    func update(_ id: String, _ change: (inout InvoiceJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    func remove(_ id: String) {
        jobs.removeAll { $0.id == id }
    }

    /// The prices an invoice is checked against.
    func items(for job: InvoiceJob, context: ModelContext) -> [PriceItem] {
        job.isSample ? SampleInvoice.prices : AppData.items(context)
    }

    /// Starts reading an invoice (one or more pages). Invoices are read one after another.
    @discardableResult
    func read(pages: [UIImage], sourcePDF: Data? = nil, context: ModelContext, sample: Bool = false, onNothingRead: (() -> Void)? = nil) -> String {
        let id = UUID().uuidString
        jobs.insert(InvoiceJob(id: id, status: .reading, message: "Waiting…", draft: InvoiceDraft(), isSample: sample,
                               thumbnail: pages.first?.thumbnail(), saved: nil, pages: sample ? [] : pages, sourcePDF: sourcePDF), at: 0)
        let items = sample ? SampleInvoice.prices : AppData.items(context)
        let suppliers = sample ? [] : AppData.knownSuppliers(context)
        let fixes = sample ? [:] : NameFixes.all()
        let trustedList = sample ? [] : Accounts.shared.trusted
        let previous = queue
        let report: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in
                self?.update(id) { $0.message = text }
            }
        }
        queue = Task { [weak self] in
            await previous?.value
            let book = PriceBook(items)
            // Settings › Checking: read each photo once (faster) or twice (double-checked)
            let twice = UserDefaults.standard.integer(forKey: SettingKey.photoReads) != 1
            let outcome = await InvoiceReader.read(pages: pages, pdf: sourcePDF, book: book, knownSuppliers: suppliers,
                                                   doubleCheck: twice, progress: report)
            // the invoice number and date: what the reader found, else Apple Intelligence looks for them
            var details = (number: outcome.invoice.invNo, date: outcome.invoice.date)
            if !sample, details.number.isEmpty || details.date.isEmpty {
                let found = await SmartCheck.findDetails(in: outcome.rawText, progress: report)
                if details.number.isEmpty { details.number = found.number }
                if details.date.isEmpty { details.date = found.date }
            }
            // what was scanned, and in which currency: a delivery note, quote or order isn't a bill, and an invoice in
            // another currency can't be checked against prices kept in this one – those are never saved on their own
            let warning = sample ? "" : Self.documentWarning(outcome.rawText, supplier: outcome.invoice.supplier)
            let firstLines = outcome.invoice.lines.map { InvoiceMaths.makeLine($0, book: book, nameFixes: fixes, supplier: outcome.invoice.supplier) }
            // a credit note: it lowers what you owe that supplier, it isn't a new invoice
            if !sample, Insights.isCreditNote(outcome.rawText) {
                guard let self else { return }
                let amount = outcome.invoice.printedTotal ?? outcome.invoice.printedNet ?? InvoiceMaths.linesTotal(outcome.invoice.lines)
                self.update(id) { job in
                    job.draft.supplier = outcome.invoice.supplier
                    job.draft.invNo = details.number
                    job.draft.date = details.date
                    job.draft.printedTotal = amount > 0 ? amount : nil
                    job.draft.totalOnly = true
                    job.status = .done
                    job.creditNote = CreditNoteResult(supplier: outcome.invoice.supplier, number: details.number,
                                                      amount: Money.round2(amount), invoiceID: nil, invoiceNo: "", paymentID: nil)
                }
                if amount > 0 { self.applyCreditNote(id, context: context) }
                return
            }
            // a trusted supplier: only the total counts, so the price check is skipped
            if SupplierAccounts.isTrusted(outcome.invoice.supplier, trusted: trustedList) {
                guard let self else { return }
                let total = outcome.invoice.printedTotal ?? outcome.invoice.printedNet ?? InvoiceMaths.linesTotal(outcome.invoice.lines)
                self.update(id) { job in
                    job.draft.supplier = outcome.invoice.supplier
                    job.draft.invNo = details.number
                    job.draft.date = details.date
                    job.draft.printedNet = outcome.invoice.printedNet
                    job.draft.printedTotal = total > 0 ? total : nil
                    job.draft.passes = outcome.passes
                    job.draft.lines = firstLines
                    job.draft.totalOnly = true
                    job.status = .done
                    job.message = total > 0 ? warning : String(localized: "Couldn't read the invoice total. Type it in.")
                }
                if warning.isEmpty { self.saveIfChecked(id, context: context) }
                return
            }
            // a name the user already corrected by hand is never second-guessed
            // speed: Apple Intelligence only looks at lines that need a second opinion. A line both reads agreed on,
            // with a readable name that clearly matches one price-list item, is already right.
            let toCheck = firstLines.filter { fixes[TextTools.norm($0.read)] == nil && Self.needsSecondOpinion($0) }
            let sent = Set(toCheck.map { $0.id })
            let checked = await SmartCheck.check(toCheck, supplier: outcome.invoice.supplier, book: book, progress: report)
            let checkedByID = Dictionary(checked.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // lines Apple Intelligence called "not a product" are missing from `checked` and drop out here
            var finalLines = firstLines.compactMap { line -> CheckLine? in
                sent.contains(line.id) ? checkedByID[line.id] : line
            }
            // Apple Intelligence never removes a real line: if the invoice only adds up with the lines it
            // called "not a product", they are put back (a missed line made the invoice total too small)
            let allLines = firstLines.map { checkedByID[$0.id] ?? $0 }
            if allLines.count > finalLines.count,
               !Self.addsUp(finalLines, invoice: outcome.invoice), Self.addsUp(allLines, invoice: outcome.invoice) {
                finalLines = allLines
            }
            // nothing read from a photo: check whether it was too dark or blurry, to give a better tip
            let problem = finalLines.isEmpty && sourcePDF == nil ? pages.first.flatMap { ImageTools.problem(with: $0) } : nil
            guard let self else { return }
            self.update(id) { job in
                job.draft.supplier = outcome.invoice.supplier
                job.draft.invNo = details.number
                job.draft.date = details.date
                job.draft.printedNet = outcome.invoice.printedNet
                job.draft.printedTotal = outcome.invoice.printedTotal
                job.draft.passes = outcome.passes
                job.draft.lines = finalLines
                job.status = .done
                job.message = job.draft.lines.isEmpty ? Self.nothingReadMessage(problem) : warning
            }
            // also when Apple Intelligence found that none of the lines were products
            if finalLines.isEmpty { onNothingRead?() }
            if warning.isEmpty { self.saveIfChecked(id, context: context) }
        }
        return id
    }

    /// Why this scan shouldn't be saved as an invoice without a look ("" when it's an ordinary invoice in your currency).
    nonisolated static func documentWarning(_ text: String, supplier: String = "") -> String {
        var parts: [String] = []
        switch DocumentFacts.kind(text) {
        case .deliveryNote: parts.append(String(localized: "This looks like a delivery note, not an invoice. Check it before saving."))
        case .quote: parts.append(String(localized: "This looks like a quote or pro forma, not an invoice. Check it before saving."))
        case .order: parts.append(String(localized: "This looks like an order, not an invoice. Check it before saving."))
        case .statement: parts.append(String(localized: "This looks like a statement. Check statements in Suppliers instead."))
        case .receipt, .invoice, .creditNote: break
        }
        // a supplier set to invoice in that currency (Suppliers › the supplier › Invoices in) is expected
        let expected = SupplierCurrency.code(supplier) ?? Money.currency.code
        if let printed = DocumentFacts.currency(text), printed != expected {
            parts.append(String(localized: "This invoice is in \(printed), but your prices are in \(expected). Check the prices before saving, or set this supplier to \(printed) in Suppliers."))
        }
        return parts.joined(separator: " ")
    }

    /// Whether the lines add up to the printed net (or, when only that was read, the printed invoice total).
    nonisolated static func addsUp(_ lines: [CheckLine], invoice: ParsedInvoice) -> Bool {
        let net = Money.round2(lines.reduce(0) { $0 + Money.round2($1.qty * $1.unit) })
        if let printed = invoice.printedNet, printed > 0 { return abs(net - printed) <= InvoiceMaths.totalAllowance(lines: lines.count, withVat: false) }
        guard let total = invoice.printedTotal, total > 0 else { return false }
        let withVat = Money.round2(lines.reduce(0) { sum, line in
            let n = Money.round2(line.qty * line.unit)
            return sum + n + Money.round2(n * line.vat / 100)
        })
        return abs(withVat - total) <= InvoiceMaths.totalAllowance(lines: lines.count, withVat: true)
    }

    /// Whether Apple Intelligence should look at this line: no clear match, the two reads differed, or the name looks misread.
    nonisolated static func needsSecondOpinion(_ line: CheckLine) -> Bool {
        line.matchId == nil || line.confident != true || line.disagree || line.onlySecondRead
            || InvoiceParser.looksGarbled(line.desc)
    }

    /// What to say when no item lines could be found.
    static func nothingReadMessage(_ problem: PhotoProblem?) -> String {
        switch problem {
        case .dark:
            return String(localized: "The photo looks too dark to read. Take it again in brighter light or with the flash, or add the lines by hand.")
        case .blurry:
            return String(localized: "The photo looks blurry. Hold the phone still and let it focus before taking the photo, or add the lines by hand.")
        case nil:
            return String(localized: "Couldn't find any item lines. Retake the photo flat and close, in good light, or add the lines by hand.")
        }
    }

    /// A blank invoice to type in by hand.
    @discardableResult
    func addBlank() -> String {
        let id = UUID().uuidString
        var draft = InvoiceDraft()
        draft.lines = [CheckLine()]
        jobs.insert(InvoiceJob(id: id, status: .done, message: "", draft: draft, isSample: false, thumbnail: nil, saved: nil), at: 0)
        return id
    }

    /// A cheaper price on a fully checked invoice becomes the agreed price. Never raised, never adds items,
    /// and each item is asked about only once per invoice. Nothing changes until the user taps Update.
    private func lowerPrices(_ draft: InvoiceDraft, jobID: String, book: PriceBook, context: ModelContext) {
        if UserDefaults.standard.object(forKey: SettingKey.autoLower) as? Bool == false { return }
        guard InvoiceMaths.totals(draft, book: book, tolerance: AppData.tolerance).verified else { return }
        let changes = PriceTools.cheaper(in: draft, book: book).filter { loweredOnce.insert(jobID + "|" + $0.itemID).inserted }
        let before = changes.compactMap { book.item($0.itemID) }
        if before.isEmpty { return }
        lowered = LoweredPrices(changes: changes.filter { change in before.contains { $0.id == change.itemID } },
                                before: before, supplier: draft.supplier)
    }

    /// "Update my price": the agreed prices become the cheaper ones on the invoice (each change is in the history).
    func acceptLowered(_ note: LoweredPrices, context: ModelContext) {
        for change in note.changes {
            guard let item = note.before.first(where: { $0.id == change.itemID }) else { continue }
            AppData.save(PriceTools.setting(change.to, on: item, supplier: note.supplier), in: context)
        }
        try? context.save()
    }

    /// Suppliers call the same item different names. On a fully checked invoice, each new name of an item the app
    /// is sure about is added to that item ("on invoices as"), so it is recognised straight away next time.
    private func learnNames(_ draft: InvoiceDraft, book: PriceBook, context: ModelContext) {
        if UserDefaults.standard.object(forKey: SettingKey.autoLearnNames) as? Bool == false { return }
        guard InvoiceMaths.totals(draft, book: book, tolerance: AppData.tolerance).verified else { return }
        var changed: [String: PriceItem] = [:]
        for name in PriceTools.newNames(in: draft, book: book) {
            guard var item = changed[name.itemID] ?? book.item(name.itemID) else { continue }
            item.aliases.append(name.spelling)
            changed[name.itemID] = item
        }
        if changed.isEmpty { return }
        for item in changed.values { AppData.save(item, in: context) }
        try? context.save()
    }

    /// Saves the invoice to Reports once every line is checked (or straight away when `anyway` is true).
    /// Uses a scanned credit note: pays off a credit you asked for, or comes off the supplier's balance.
    /// Calling it again (after the amount or supplier was corrected) first undoes what it did before.
    func applyCreditNote(_ id: String, context: ModelContext) {
        guard let job = jobs.first(where: { $0.id == id }), var note = job.creditNote else { return }
        undoCreditNote(note, context: context)
        note.supplier = job.draft.supplier
        note.number = job.draft.invNo
        note.amount = Money.round2(job.draft.printedTotal ?? 0)
        note.invoiceID = nil
        note.invoiceNo = ""
        note.paymentID = nil
        guard note.amount > 0, !note.supplier.trimmingCharacters(in: .whitespaces).isEmpty else {
            update(id) { $0.creditNote = note }
            return
        }
        if let invoice = Insights.creditMatch(supplier: note.supplier, amount: note.amount, in: AppData.entries(context)) {
            let stamp = ISO8601DateFormatter().string(from: Date())
            AppData.updateReports([invoice.id], context: context) { saved in
                saved.credit = CreditInfo(status: CreditInfo.received, amount: saved.credit?.amount ?? note.amount, at: saved.credit?.at, paidAt: stamp)
            }
            note.invoiceID = invoice.id
            note.invoiceNo = invoice.invNo
        } else {
            let payment = SupplierPayment(supplier: note.supplier, amount: note.amount, date: SupplierAccounts.dayText(Date()), kind: .credit,
                                          note: note.number.isEmpty ? "" : String(localized: "Credit note \(note.number)"))
            Accounts.shared.add(payment, context: context)
            note.paymentID = payment.id
        }
        update(id) { $0.creditNote = note }
        Accounts.shared.changed(context)
    }

    private func undoCreditNote(_ note: CreditNoteResult, context: ModelContext) {
        if let invoiceID = note.invoiceID {
            AppData.updateReports([invoiceID], context: context) { saved in
                if let credit = saved.credit { saved.credit = CreditInfo(status: CreditInfo.requested, amount: credit.amount, at: credit.at) }
            }
        }
        if let paymentID = note.paymentID { Accounts.shared.remove(paymentID, context: context) }
    }

    /// The answer to "Is this the same invoice?": save it as an update of the saved one, or as a second bill.
    func decideDuplicate(_ id: String, billedTwice: Bool, context: ModelContext) {
        update(id) { $0.billedTwice = billedTwice }
        // the question only comes up when the invoice was being saved, so it is saved now
        saveIfChecked(id, context: context, anyway: true)
    }

    func saveIfChecked(_ id: String, context: ModelContext, anyway: Bool = false) {
        guard let job = job(id), !job.isSample, job.status == .done else { return }
        let lines = job.draft.lines.filter { !$0.desc.trimmingCharacters(in: .whitespaces).isEmpty }
        guard job.saved != job.draft, job.creditNote == nil else { return }
        let book = PriceBook(AppData.items(context))
        if job.draft.totalOnly {
            guard (job.draft.printedTotal ?? job.draft.printedNet ?? 0) > 0 else { return }
        } else {
            guard !lines.isEmpty else { return }
            if !anyway && !InvoiceMaths.totals(job.draft, book: book, tolerance: AppData.tolerance).verified { return }
        }
        var draft = job.draft
        if draft.shopId.isEmpty { draft.shopId = Shops.current }
        let wasSaved = job.saved != nil
        // an invoice that looks like one already saved: ask before saving (never replace it silently)
        var choice: AppData.DuplicateChoice?
        if !wasSaved {
            if let other = job.possibleDuplicate, let twice = job.billedTwice {
                choice = twice ? .billedTwice(other) : .sameInvoice(other)
            } else if let other = AppData.possibleDuplicate(of: draft, book: book, context: context) {
                update(id) { $0.possibleDuplicate = other }
                return
            } else if job.possibleDuplicate != nil {
                // corrected (another number or date): it doesn't look like the saved invoice any more
                update(id) { $0.possibleDuplicate = nil }
            }
        }
        let entry = AppData.saveReport(&draft, book: book, context: context, duplicate: choice)
        let subject = entry.duplicateOf == nil ? RecordKeeping.subject(entry) : RecordKeeping.subject(entry) + " · " + String(localized: "billed twice")
        var updated = wasSaved
        if case .sameInvoice? = choice { updated = true }
        Records.shared.log(updated ? .invoiceUpdated : .invoiceSaved, subject, amount: entry.total)
        if !draft.totalOnly {
            lowerPrices(draft, jobID: id, book: book, context: context)
            learnNames(draft, book: book, context: context)
        }
        // keep a copy of the original invoice next to the report
        var copyPath = job.copyPath ?? entry.file
        if !job.pages.isEmpty || job.sourcePDF != nil {
            let first = job.copyPath == nil
            copyPath = InvoiceCopies.keep(pages: job.pages, sourcePDF: job.sourcePDF, entry: entry, replacing: job.copyPath)
            if let copyPath, copyPath != entry.file {
                AppData.updateReports([entry.id], context: context) { $0.file = copyPath }
            }
            if first, InvoiceCopies.mode == "ask", let copyPath, let url = AppFiles.url(forRelativePath: copyPath) { offerCopy = url }
        }
        update(id) {
            $0.draft = draft
            $0.saved = draft
            $0.copyPath = copyPath
        }
        onSaved?()
    }
}
