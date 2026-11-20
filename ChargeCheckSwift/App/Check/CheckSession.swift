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

struct LoweredPrices: Identifiable {
    let id = UUID()
    var changes: [PriceChange]
    var before: [PriceItem]

    var message: String {
        if changes.count == 1, let one = changes.first {
            return String(localized: "Your price for \(one.name) was lowered from \(Money.format(one.from)) to \(Money.format(one.to)), the cheaper price on this invoice.")
        }
        return String(localized: "\(changes.count) of your prices were lowered to the cheaper prices on this invoice.")
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
            let firstLines = outcome.invoice.lines.map { InvoiceMaths.makeLine($0, book: book, nameFixes: fixes, supplier: outcome.invoice.supplier) }
            // a credit note: it lowers what you owe that supplier, it isn't a new invoice
            if !sample, Insights.isCreditNote(outcome.rawText) {
                guard let self else { return }
                let amount = outcome.invoice.printedTotal ?? outcome.invoice.printedNet ?? InvoiceMaths.linesTotal(outcome.invoice.lines)
                self.update(id) { job in
                    job.draft.supplier = outcome.invoice.supplier
                    job.draft.invNo = outcome.invoice.invNo
                    job.draft.date = outcome.invoice.date
                    job.draft.printedTotal = amount > 0 ? amount : nil
                    job.draft.totalOnly = true
                    job.status = .done
                    job.creditNote = CreditNoteResult(supplier: outcome.invoice.supplier, number: outcome.invoice.invNo,
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
                    job.draft.invNo = outcome.invoice.invNo
                    job.draft.date = outcome.invoice.date
                    job.draft.printedNet = outcome.invoice.printedNet
                    job.draft.printedTotal = total > 0 ? total : nil
                    job.draft.passes = outcome.passes
                    job.draft.lines = firstLines
                    job.draft.totalOnly = true
                    job.status = .done
                    job.message = total > 0 ? "" : String(localized: "Couldn't read the invoice total. Type it in.")
                }
                self.saveIfChecked(id, context: context)
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
            let finalLines = firstLines.compactMap { line -> CheckLine? in
                sent.contains(line.id) ? checkedByID[line.id] : line
            }
            // nothing read from a photo: check whether it was too dark or blurry, to give a better tip
            let problem = finalLines.isEmpty && sourcePDF == nil ? pages.first.flatMap { ImageTools.problem(with: $0) } : nil
            guard let self else { return }
            self.update(id) { job in
                job.draft.supplier = outcome.invoice.supplier
                job.draft.invNo = outcome.invoice.invNo
                job.draft.date = outcome.invoice.date
                job.draft.printedNet = outcome.invoice.printedNet
                job.draft.printedTotal = outcome.invoice.printedTotal
                job.draft.passes = outcome.passes
                job.draft.lines = finalLines
                job.status = .done
                job.message = job.draft.lines.isEmpty ? Self.nothingReadMessage(problem) : ""
            }
            // also when Apple Intelligence found that none of the lines were products
            if finalLines.isEmpty { onNothingRead?() }
            self.saveIfChecked(id, context: context)
        }
        return id
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
    /// and each item only once per invoice so "Undo" sticks.
    private func lowerPrices(_ draft: InvoiceDraft, jobID: String, book: PriceBook, context: ModelContext) {
        if UserDefaults.standard.object(forKey: SettingKey.autoLower) as? Bool == false { return }
        guard InvoiceMaths.totals(draft, book: book, tolerance: AppData.tolerance).verified else { return }
        let changes = PriceTools.cheaper(in: draft, book: book).filter { loweredOnce.insert(jobID + "|" + $0.itemID).inserted }
        var before: [PriceItem] = []
        for change in changes {
            guard let item = book.item(change.itemID) else { continue }
            before.append(item)
            AppData.save(PriceTools.setting(change.to, on: item, supplier: draft.supplier), in: context)
        }
        if before.isEmpty { return }
        try? context.save()
        lowered = LoweredPrices(changes: changes, before: before)
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

    func undoLowered(_ note: LoweredPrices, context: ModelContext) {
        for item in note.before { AppData.save(item, in: context) }
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
        let entry = AppData.saveReport(&draft, book: book, context: context)
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
