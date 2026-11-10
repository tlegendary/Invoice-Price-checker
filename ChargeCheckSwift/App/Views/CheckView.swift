import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import ChargeCheckCore

/// The Check tab: scan or pick invoices, then see what each supplier overcharged.
struct CheckView: View {
    let storageProblem: Bool

    @EnvironmentObject private var session: CheckSession
    @Environment(\.modelContext) private var context
    @Query private var prices: [StoredPrice]

    @State private var path: [String] = []
    @State private var showScanner = false
    @State private var showFiles = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var notice: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if storageProblem {
                    Label("Your saved data couldn't be opened. Anything you add now won't be kept. Close the app and open it again.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Section {
                    if DocumentScanner.isAvailable {
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan an invoice", systemImage: "doc.viewfinder")
                                .font(.headline)
                        }
                    }
                    PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .images) {
                        Label("Choose photos", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showFiles = true
                    } label: {
                        Label("Choose a PDF or file", systemImage: "folder")
                    }
                    Button {
                        path = [session.addBlank()]
                    } label: {
                        Label("Type by hand", systemImage: "keyboard")
                    }
                    if session.jobs.isEmpty {
                        Button {
                            trySample()
                        } label: {
                            Label("Try a sample invoice", systemImage: "sparkles")
                        }
                    }
                } footer: {
                    Text(prices.isEmpty
                         ? "Read on this phone and double-checked. Add your agreed prices in Prices so there is something to compare with."
                         : "Photos or PDFs. Read on this phone, works offline, and every invoice is read twice.")
                }
                if !session.jobs.isEmpty {
                    Section("Invoices") {
                        ForEach(session.jobs) { job in
                            NavigationLink(value: job.id) {
                                JobRow(job: job, items: session.items(for: job, context: context))
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { session.jobs[$0].id }
                            for id in ids { session.remove(id) }
                        }
                    }
                }
            }
            .navigationTitle("ChargeCheck")
            .navigationDestination(for: String.self) { id in
                InvoiceDetailView(jobID: id)
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner(
                    onFinish: { pages in
                        showScanner = false
                        if !pages.isEmpty { session.read(pages: pages, context: context) }
                    },
                    onCancel: { showScanner = false }
                )
                .ignoresSafeArea()
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
                open(result)
            }
            .onChange(of: picked) {
                loadPicked()
            }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .task {
                // the cloud check starts the sample invoice with "-demoScan YES"
                // ("-demoScan sideways" turns it on its side first, to check that is handled)
                if let demo = UserDefaults.standard.string(forKey: "demoScan"), session.jobs.isEmpty {
                    trySample(open: true, sideways: demo == "sideways")
                }
            }
        }
    }

    private func trySample(open: Bool = false, sideways: Bool = false) {
        guard var image = SampleInvoice.image else {
            notice = "The sample invoice is missing from the app."
            return
        }
        if sideways { image = image.prepared(quarterTurns: 1) }
        let id = session.read(pages: [image], context: context, sample: true)
        if open { path = [id] }
    }

    private func loadPicked() {
        let items = picked
        if items.isEmpty { return }
        picked = []
        Task {
            var failed = 0
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    session.read(pages: [image], context: context)
                } else {
                    failed += 1
                }
            }
            if failed > 0 { notice = failed == 1 ? "One photo couldn't be opened." : "\(failed) photos couldn't be opened." }
        }
    }

    private func open(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        var failed = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            var pages: [UIImage] = []
            if url.pathExtension.lowercased() == "pdf" {
                pages = ImageTools.pages(ofPDF: url)
            } else if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                pages = [image]
            }
            if pages.isEmpty { failed += 1 } else { session.read(pages: pages, context: context) }
        }
        if failed > 0 { notice = failed == 1 ? "One file couldn't be opened." : "\(failed) files couldn't be opened." }
    }
}

/// One invoice in the list on the Check tab.
struct JobRow: View {
    let job: InvoiceJob
    let items: [PriceItem]

    var body: some View {
        HStack(spacing: 12) {
            if let thumbnail = job.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "doc.text")
                    .font(.title2)
                    .frame(width: 44, height: 56)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(job.draft.supplier.isEmpty ? (job.status == .reading ? "Reading…" : "Invoice") : job.draft.supplier)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if job.status == .reading {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text(job.message)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    summary
                }
            }
        }
    }

    @ViewBuilder private var summary: some View {
        let totals = InvoiceMaths.totals(job.draft, book: PriceBook(items), tolerance: AppData.tolerance)
        if job.draft.lines.isEmpty {
            Text("No lines found")
                .font(.footnote)
                .foregroundStyle(.orange)
        } else if totals.reviewCount > 0 {
            Text(totals.reviewCount == 1 ? "1 thing to check" : "\(totals.reviewCount) things to check")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
        } else if totals.over > 0.005 {
            Text("Overcharged \(Money.format(totals.over))")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.red)
        } else {
            Text("All prices match")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.green)
        }
    }
}
