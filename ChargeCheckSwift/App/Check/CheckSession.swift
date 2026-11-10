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
        let previous = queue
        let report: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in
                self?.update(id) { $0.message = text }
            }
        }
        queue = Task { [weak self] in
            await previous?.value
            let book = PriceBook(items)
            let outcome = await InvoiceReader.read(pages: pages, book: book, knownSuppliers: suppliers, progress: report)
            let firstLines = outcome.invoice.lines.map { InvoiceMaths.makeLine($0, book: book, nameFixes: fixes, supplier: outcome.invoice.supplier) }
            // a name the user already corrected by hand is never second-guessed
            let checked = await SmartCheck.check(firstLines.filter { fixes[TextTools.norm($0.read)] == nil }, supplier: outcome.invoice.supplier,
                                                 book: book, progress: report)
            let checkedByID = Dictionary(checked.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // lines Apple Intelligence called "not a product" are missing from `checked` and drop out here
            let finalLines = firstLines.compactMap { line -> CheckLine? in
                fixes[TextTools.norm(line.read)] != nil ? line : checkedByID[line.id]
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

    func undoLowered(_ note: LoweredPrices, context: ModelContext) {
        for item in note.before { AppData.save(item, in: context) }
        try? context.save()
    }

    /// Saves the invoice to Reports once every line is checked (or straight away when `anyway` is true).
    func saveIfChecked(_ id: String, context: ModelContext, anyway: Bool = false) {
        guard let job = job(id), !job.isSample, job.status == .done else { return }
        let lines = job.draft.lines.filter { !$0.desc.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty, job.saved != job.draft else { return }
        let book = PriceBook(AppData.items(context))
        if !anyway && !InvoiceMaths.totals(job.draft, book: book, tolerance: AppData.tolerance).verified { return }
        var draft = job.draft
        if draft.shopId.isEmpty { draft.shopId = Shops.current }
        let entry = AppData.saveReport(&draft, book: book, context: context)
        lowerPrices(draft, jobID: id, book: book, context: context)
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
