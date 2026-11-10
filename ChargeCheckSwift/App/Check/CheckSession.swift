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
    func read(pages: [UIImage], context: ModelContext, sample: Bool = false, onNothingRead: (() -> Void)? = nil) -> String {
        let id = UUID().uuidString
        jobs.insert(InvoiceJob(id: id, status: .reading, message: "Waiting…", draft: InvoiceDraft(), isSample: sample,
                               thumbnail: pages.first?.thumbnail(), saved: nil), at: 0)
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
            guard let self else { return }
            self.update(id) { job in
                job.draft.supplier = outcome.invoice.supplier
                job.draft.invNo = outcome.invoice.invNo
                job.draft.date = outcome.invoice.date
                job.draft.printedNet = outcome.invoice.printedNet
                job.draft.printedTotal = outcome.invoice.printedTotal
                job.draft.passes = outcome.passes
                job.draft.lines = outcome.invoice.lines.map { InvoiceMaths.makeLine($0, book: book, nameFixes: fixes) }
                job.status = .done
                job.message = job.draft.lines.isEmpty
                    ? "Couldn't find any item lines. Retake the photo flat and close, in good light, or add the lines by hand."
                    : ""
            }
            if outcome.invoice.lines.isEmpty { onNothingRead?() }
            self.saveIfChecked(id, context: context)
        }
        return id
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

    /// Saves the invoice to Reports once every line is checked (or straight away when `anyway` is true).
    func saveIfChecked(_ id: String, context: ModelContext, anyway: Bool = false) {
        guard let job = job(id), !job.isSample, job.status == .done else { return }
        let lines = job.draft.lines.filter { !$0.desc.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty, job.saved != job.draft else { return }
        let book = PriceBook(AppData.items(context))
        if !anyway && !InvoiceMaths.totals(job.draft, book: book, tolerance: AppData.tolerance).verified { return }
        var draft = job.draft
        AppData.saveReport(&draft, book: book, context: context)
        update(id) {
            $0.draft = draft
            $0.saved = draft
        }
    }
}
