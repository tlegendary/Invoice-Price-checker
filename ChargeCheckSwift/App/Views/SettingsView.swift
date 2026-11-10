import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ChargeCheckCore

struct SettingsView: View {
    @Binding var showPaywall: Bool

    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ads: AdService
    @Environment(\.modelContext) private var context
    @AppStorage(SettingKey.mode) private var mode = "auto"
    @AppStorage(SettingKey.colour) private var colourID = "green"
    @AppStorage(SettingKey.business) private var business = ""

    @State private var exportDocument: BackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var pendingRestore: BackupFile?
    @State private var notice: String?

    private let supportEmail = AppConfig.supportEmail
    @State private var restoring = false

    private var planName: String {
        store.subscribedProductID == Products.yearly ? "Unlimited – yearly" : "Unlimited – monthly"
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    private var exportName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "ChargeCheck-backup_" + formatter.string(from: Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: $mode) {
                        Text("Automatic").tag("auto")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                        ForEach(Themes.all) { theme in
                            Button {
                                colourID = theme.id
                            } label: {
                                Circle()
                                    .fill(LinearGradient(colors: [theme.dark, theme.main], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        if colourID == theme.id {
                                            Image(systemName: "checkmark")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(theme.name)
                            .accessibilityAddTraits(colourID == theme.id ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Look")
                } footer: {
                    Text("\(Themes.named(colourID).name). Automatic follows your iPhone's light or dark setting.")
                }

                Section {
                    if store.isSubscribed {
                        LabeledContent("Plan", value: planName)
                        if let manage = AppConfig.manageSubscriptionsURL {
                            Link("Manage or cancel subscription", destination: manage)
                        }
                    } else {
                        LabeledContent("Plan", value: "Free version (1 ad per scan)")
                        LabeledContent("Scans left", value: "\(store.credits)")
                        Button("Go unlimited or buy scans") {
                            showPaywall = true
                        }
                    }
                    Button(restoring ? "Checking…" : "Restore purchases") {
                        restoring = true
                        Task {
                            let found = await store.restore()
                            restoring = false
                            notice = found ? "Your subscription is active." : "No active subscription was found for this Apple ID."
                        }
                    }
                    .disabled(restoring)
                    if !store.isSubscribed && ads.privacyOptionsRequired {
                        Button("Ad privacy choices") {
                            Task { await ads.showPrivacyOptions() }
                        }
                    }
                    if AppConfig.testBuild {
                        Toggle("Test mode: use the free version", isOn: $store.testAsFree)
                        LabeledContent("Ads", value: ads.status)
                        LabeledContent("App Store", value: store.loadStatus)
                    }
                } header: {
                    Text("Your plan")
                } footer: {
                    if AppConfig.testBuild {
                        Text("Test mode is on: test ads are shown and nothing here is sent for review like this.")
                    }
                }

                Section {
                    TextField("Business name", text: $business)
                } header: {
                    Text("Your business")
                } footer: {
                    Text("Shown at the top of reports and credit requests.")
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Label("Save backup file", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Restore backup", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Your data")
                } footer: {
                    Text("A backup holds your prices, reports and settings. Everything stays on this phone unless you save a backup somewhere else.")
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                    if let mail = URL(string: "mailto:" + supportEmail) {
                        Link(destination: mail) {
                            LabeledContent("Help", value: supportEmail)
                        }
                    }
                    if let privacy = URL(string: "https://tlegendary.github.io/privacy.html") {
                        Link("Privacy Policy", destination: privacy)
                    }
                    if let support = URL(string: "https://tlegendary.github.io/support.html") {
                        Link("Support", destination: support)
                    }
                }
            }
            .navigationTitle("Settings")
            .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json, defaultFilename: exportName) { result in
                if case .failure = result { notice = "The backup couldn't be saved. Please try again." }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .plainText]) { result in
                open(result)
            }
            .confirmationDialog("Restore this backup?", isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ), titleVisibility: .visible, presenting: pendingRestore) { backup in
                Button("Replace what's on this phone", role: .destructive) {
                    AppData.restore(backup, into: context)
                    let scans = store.restoreScans(from: backup.scans)
                    notice = scans > 0 ? "Backup restored, with \(scans) unused scans." : "Backup restored."
                }
                Button("Cancel", role: .cancel) {}
            } message: { backup in
                Text("\(backup.baseline.count) prices and \(backup.history.count) reports. This replaces the prices and reports on this phone.")
            }
            .alert(notice ?? "", isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            )) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func save() {
        guard let data = try? AppData.backup(context, scans: store.ledger.forBackup).encoded() else {
            notice = "The backup couldn't be made. Please try again."
            return
        }
        exportDocument = BackupDocument(data: data)
        showExporter = true
    }

    private func open(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url), let backup = try? BackupFile.read(data) else {
            notice = "That isn't a ChargeCheck backup file."
            return
        }
        pendingRestore = backup
    }
}
