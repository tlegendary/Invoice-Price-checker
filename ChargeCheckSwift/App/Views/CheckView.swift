import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import ChargeCheckCore

/// The Check tab: scan or pick invoices, then see what each supplier overcharged.
struct CheckView: View {
    let storageProblem: Bool
    @Binding var showPaywall: Bool

    @EnvironmentObject private var session: CheckSession
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ads: AdService
    @Environment(\.modelContext) private var context
    @Query private var prices: [StoredPrice]

    @State private var path: [String] = []
    @State private var showScanner = false
    @State private var showFiles = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var notice: String?
    @State private var showPhotos = false
    @State private var showNeedScan = false
    /// What to open once a free user has earned a scan.
    @State private var afterScanEarned: (() -> Void)?

    /// Subscribers go straight through. A free user needs a scan first (from a pack or one ad).
    private func gated(_ action: @escaping () -> Void) {
        if store.canScan {
            action()
        } else {
            afterScanEarned = action
            showNeedScan = true
        }
    }

    /// Starts reading one invoice, using one scan for a free user. A scan is given back if nothing could be read.
    private func startReading(_ pages: [UIImage], sourcePDF: Data? = nil) -> Bool {
        if store.isSubscribed {
            session.read(pages: pages, sourcePDF: sourcePDF, context: context)
            return true
        }
        guard store.useScans(1) == 1 else { return false }
        session.read(pages: pages, sourcePDF: sourcePDF, context: context, onNothingRead: {
            store.refundScan()
            notice = String(localized: "That invoice couldn't be read, so your scan was given back.")
        })
        return true
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if storageProblem {
                    Label("Your saved data couldn't be opened. Anything you add now won't be kept. Close the app and open it again.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if store.checkedEntitlements && !store.isSubscribed {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Free version")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(store.credits == 1 ? "1 scan left" : "\(store.credits) scans left")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(store.credits > 0 ? Color.primary : Color.orange)
                            }
                            HStack(spacing: 8) {
                                Button("Watch an ad for 1 scan") {
                                    afterScanEarned = nil
                                    showNeedScan = true
                                }
                                .buttonStyle(.bordered)
                                Button("Go unlimited") {
                                    showPaywall = true
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .font(.footnote.weight(.semibold))
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section {
                    if DocumentScanner.isAvailable {
                        Button {
                            gated { showScanner = true }
                        } label: {
                            Label("Scan an invoice", systemImage: "doc.viewfinder")
                                .font(.headline)
                        }
                    }
                    Button {
                        gated { showPhotos = true }
                    } label: {
                        Label("Choose photos", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        gated { showFiles = true }
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
                        if !pages.isEmpty && !startReading(pages) { notice = String(localized: "You have no scans left. Watch an ad or buy scans to check this invoice.") }
                    },
                    onCancel: { showScanner = false }
                )
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: $showPhotos, selection: $picked, maxSelectionCount: 10, matching: .images)
            .sheet(isPresented: $showNeedScan) {
                NeedScanSheet(
                    onEarned: {
                        let next = afterScanEarned
                        afterScanEarned = nil
                        next?()
                    },
                    onShowPlans: { showPaywall = true }
                )
                .environmentObject(store)
                .environmentObject(ads)
            }
            .sheet(isPresented: Binding(get: { session.offerCopy != nil }, set: { if !$0 { session.offerCopy = nil } })) {
                if let copy = session.offerCopy {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                        Text("Keep a copy of this invoice")
                            .font(.title3.weight(.bold))
                        Text("A copy is already kept in the Files app › On My iPhone › ChargeCheck › Invoices. You can also save it somewhere else or send it on.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        ShareLink(item: copy) {
                            Label("Save or send a copy", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Not now") { session.offerCopy = nil }
                    }
                    .padding(24)
                    .presentationDetents([.medium])
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
                open(result)
            }
            .onChange(of: picked) {
                loadPicked()
            }
            .onChange(of: session.incoming) {
                takeIncoming()
            }
            .onAppear {
                takeIncoming()
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
            notice = String(localized: "The sample invoice is missing from the app.")
            return
        }
        if sideways { image = image.prepared(quarterTurns: 1) }
        let id = session.read(pages: [image], context: context, sample: true)
        if open { path = [id] }
    }

    /// Reads invoices shared into the app (one scan each for a free user, as usual).
    private func takeIncoming() {
        let urls = session.incoming
        if urls.isEmpty { return }
        session.incoming = []
        path = []
        gated {
            open(.success(urls))
            // "Copy to ChargeCheck" leaves a copy in the app's Inbox folder: not needed once read
            for url in urls where url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func loadPicked() {
        let items = picked
        if items.isEmpty { return }
        picked = []
        Task {
            var failed = 0
            var skipped = 0
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    if !startReading([image]) { skipped += 1 }
                } else {
                    failed += 1
                }
            }
            if skipped > 0 {
                notice = skipped == 1 ? String(localized: "1 invoice wasn't scanned because you had no scans left. One ad or one pack scan is needed for each invoice.") : String(localized: "\(skipped) invoices weren't scanned because you had no scans left. One ad or one pack scan is needed for each invoice.")
            } else if failed > 0 {
                notice = failed == 1 ? String(localized: "One photo couldn't be opened.") : String(localized: "\(failed) photos couldn't be opened.")
            }
        }
    }

    private func open(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        var failed = 0
        var skipped = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            var pages: [UIImage] = []
            var pdf: Data?
            if url.pathExtension.lowercased() == "pdf" {
                pages = ImageTools.pages(ofPDF: url)
                pdf = try? Data(contentsOf: url)
            } else if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                pages = [image]
            }
            if pages.isEmpty {
                failed += 1
            } else if !startReading(pages, sourcePDF: pdf) {
                skipped += 1
            }
        }
        if skipped > 0 {
            notice = skipped == 1 ? String(localized: "1 invoice wasn't scanned because you had no scans left. One ad or one pack scan is needed for each invoice.") : String(localized: "\(skipped) invoices weren't scanned because you had no scans left. One ad or one pack scan is needed for each invoice.")
        } else if failed > 0 {
            notice = failed == 1 ? String(localized: "One file couldn't be opened.") : String(localized: "\(failed) files couldn't be opened.")
        }
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
        if job.draft.totalOnly {
            Label {
                Text((job.draft.printedTotal ?? 0) > 0 ? String(localized: "Trusted · total \(Money.format(job.draft.printedTotal ?? 0))") : String(localized: "Trusted · type in the total"))
            } icon: {
                Image(systemName: "checkmark.shield.fill")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle((job.draft.printedTotal ?? 0) > 0 ? Color.green : Color.orange)
        } else if job.draft.lines.isEmpty {
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
