import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ChargeCheckCore

struct SettingsView: View {
    @Binding var showPaywall: Bool
    @ObservedObject private var team = CloudTeam.shared

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
    @AppStorage(SettingKey.keepCopies) private var keepCopies = "phone"
    @AppStorage(SettingKey.cloudCopies) private var cloudCopies = true
    @AppStorage(SettingKey.reminder) private var reminder = false
    @AppStorage(CloudFolder.nameKey) private var cloudName = ""
    @AppStorage(CloudFolder.lastSavedKey) private var cloudSaved = 0.0
    @AppStorage(AutoBackup.lastKey) private var lastBackup = 0.0
    @State private var showFolderPicker = false
    @AppStorage(SettingKey.autoLower) private var autoLower = true
    @AppStorage(SettingKey.autoLearnNames) private var autoLearnNames = true
    @AppStorage(AppLock.settingKey) private var lockOn = false
    @AppStorage(SmartCheck.settingKey) private var smartCheck = true
    @AppStorage(SettingKey.photoReads) private var photoReads = 2
    @AppStorage(Regional.languageKey) private var invoiceLanguage = Regional.deviceLanguage
    @AppStorage(Regional.currencyKey) private var currencyCode = Regional.deviceCurrency
    @AppStorage(SettingKey.tolerance) private var toleranceValue = 0.01
    @AppStorage(Shops.listKey) private var shopData = Data()
    @State private var showPricesShare: URL?

    private func when(_ seconds: Double) -> String {
        if seconds <= 0 { return String(localized: "not yet") }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private func pickedFolder(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        guard let name = CloudFolder.choose(url) else {
            notice = String(localized: "That folder couldn't be used. Please choose another one.")
            return
        }
        cloudName = name
        // a backup already in that folder (for example from your old phone) is offered when this phone is empty
        let empty = AppData.items(context).isEmpty && AppData.entries(context).isEmpty
        if empty, let found = CloudFolder.readBackup(), !found.baseline.isEmpty || !found.history.isEmpty {
            pendingRestore = found
        } else {
            AutoBackup.run(context, scans: store.ledger.forBackup)
            notice = String(localized: "Backups will now also be saved in \(name).")
        }
    }

    private var planName: String {
        store.subscribedProductID == Products.yearly ? String(localized: "Unlimited – yearly") : String(localized: "Unlimited – monthly")
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

    /// Opened from the More tab, inside its navigation, rather than as a tab of its own.
    var embedded = false

    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }

    private var content: some View {
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
                            .accessibilityLabel(L(theme.name))
                            .accessibilityAddTraits(colourID == theme.id ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Look")
                } footer: {
                    Text("\(L(Themes.named(colourID).name)). Automatic follows your iPhone's light or dark setting.")
                }

                Section {
                    Picker("Invoices are in", selection: $invoiceLanguage) {
                        ForEach(Regional.languages) { language in
                            Text(language.name).tag(language.id)
                        }
                    }
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(Currency.all) { currency in
                            Text(Regional.currencyName(currency)).tag(currency.code)
                        }
                    }
                    if let open = URL(string: UIApplication.openSettingsURLString) {
                        Link("App language", destination: open)
                    }
                } header: {
                    Text("Language and money")
                } footer: {
                    Text("Choose the language your supplier invoices are written in. To change the language of the app itself, tap App language and choose Language.")
                }
                .onChange(of: invoiceLanguage) { Regional.apply() }
                .onChange(of: currencyCode) { Regional.apply() }

                Section {
                    if store.isSubscribed {
                        LabeledContent("Plan", value: planName)
                        if let manage = AppConfig.manageSubscriptionsURL {
                            Link("Manage or cancel subscription", destination: manage)
                        }
                    } else {
                        LabeledContent("Plan", value: store.tier == .packs ? String(localized: "Scan packs (pack features unlocked)")
                                                                          : String(localized: "Free version (1 ad per scan)"))
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
                            notice = found ? String(localized: "Your subscription is active.") : String(localized: "No active subscription was found for this Apple ID.")
                        }
                    }
                    .disabled(restoring)
                    if !store.isSubscribed && ads.privacyOptionsRequired {
                        Button("Ad privacy choices") {
                            Task { await ads.showPrivacyOptions() }
                        }
                    }
                    if AppConfig.testBuild {
                        // TEST BUILDS ONLY – remove before the App Store release
                        Button("Test: add 5 free scans") {
                            store.addTestScans(5)
                        }
                        Toggle("Test mode: use the free version", isOn: $store.testAsFree)
                        Picker("Test: try the app as", selection: $store.testTier) {
                            Text("What I bought").tag("")
                            Text("Free").tag("free")
                            Text("Scan packs").tag("packs")
                            Text("Pro").tag("pro")
                        }
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

                // staff phones: the business, prices, data and backups are the owner's
                if !team.isStaff {
                    Section {
                        TextField("Business name", text: $business)
                    } header: {
                        Text("Your business")
                    } footer: {
                        Text("The name is shown at the top of reports and credit requests.")
                    }

                    if AppLock.available || lockOn {
                        Section {
                            Toggle("Lock with Face ID or passcode", isOn: Binding(
                                get: { lockOn },
                                set: { wanted in
                                    // check it's the owner before turning the lock off or on
                                    Task { if await AppLock.unlock() { lockOn = wanted } }
                                }
                            ))
                        } footer: {
                            Text("Asks for Face ID, Touch ID or your passcode each time ChargeCheck opens, so staff or family using this phone can't see your prices and payments.")
                        }
                    }
                    Section {
                        Picker("Ignore differences up to", selection: $toleranceValue) {
                            Text(Money.format(0.01)).tag(0.01)
                            Text(Money.format(0.02)).tag(0.02)
                            Text(Money.format(0.05)).tag(0.05)
                            Text(Money.format(0.1)).tag(0.1)
                        }
                        Toggle("Lower my prices when an invoice is cheaper", isOn: $autoLower)
                        Toggle("Learn the names suppliers use", isOn: $autoLearnNames)
                    } header: {
                        Text("Checking")
                    } footer: {
                        Text("Prices are only lowered for items already in your list, only on a fully checked invoice, and never raised. You can undo it each time.")
                            + Text(verbatim: "\n\n")
                            + Text("Suppliers often call the same item different names. When a fully checked invoice shows a new name for an item the app is sure about, the name is added to that item, so it is recognised straight away next time. See or remove the names under each item in Prices.")
                    }

                    Section {
                        Picker("Read each photo", selection: $photoReads) {
                            Text("Once (faster)").tag(1)
                            Text("Twice (double-checked)").tag(2)
                        }
                        if !store.allows(.smartCheck) {
                            LockedRow(feature: .smartCheck) { Text("Also check with Apple Intelligence") }
                        } else if SmartCheck.status.isEmpty {
                            Toggle("Also check with Apple Intelligence", isOn: $smartCheck)
                        } else {
                            // this iPhone can't run Apple Intelligence: shown off, and never used
                            Toggle("Also check with Apple Intelligence", isOn: .constant(false))
                                .disabled(true)
                        }
                    } header: {
                        Text("How invoices are read")
                    } footer: {
                        let status = SmartCheck.status
                        Text("Twice is safest: the photo is read two different ways and the app points out any line where the two reads differ. Once is about twice as fast.\n\nApple Intelligence fixes misread names and picks the right item from your list, on your iPhone and offline. It never changes a quantity or a price. It makes a scan slower.")
                            + Text(verbatim: status.isEmpty ? "" : "\n\n" + status)
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
                        LabeledContent("Automatic backup", value: when(lastBackup))
                    } header: {
                        Text("Your data")
                    } footer: {
                        Text("A backup holds your prices, reports and settings. One is kept automatically in the Files app › On My iPhone › ChargeCheck, with a copy for each of the last 14 days.")
                    }

                    Section {
                        if cloudName.isEmpty {
                            Button {
                                showFolderPicker = true
                            } label: {
                                Label("Choose an iCloud Drive folder", systemImage: "icloud")
                            }
                        } else {
                            LabeledContent("Folder", value: cloudName)
                            LabeledContent("Last saved there", value: when(cloudSaved))
                            Toggle("Also save invoice copies there", isOn: $cloudCopies)
                            Button("Change folder") { showFolderPicker = true }
                            Button("Stop saving there", role: .destructive) {
                                CloudFolder.forget()
                                cloudName = ""
                            }
                        }
                    } header: {
                        Text("iCloud backup")
                    } footer: {
                        Text("Choose a folder once (for example make a “ChargeCheck” folder in iCloud Drive) and every backup is also saved there. Safe even if you lose or change your phone.")
                    }

                    Section {
                        Picker("Invoice copies", selection: $keepCopies) {
                            Text("Keep on this phone").tag("phone")
                            Text("Keep + ask where else").tag("ask")
                            Text("Don't keep copies").tag("off")
                        }
                        Toggle("Monthly reminder", isOn: Binding(
                            get: { reminder },
                            set: { isOn in
                                Task {
                                    let ok = await MonthlyReminder.set(isOn)
                                    reminder = isOn && ok
                                    if isOn && !ok { notice = String(localized: "Notifications are turned off for ChargeCheck. Turn them on in the Settings app to get the reminder.") }
                                }
                            }
                        ))
                        Button {
                            let data = PDFMaker.priceList(AppData.items(context), business: business, theme: Themes.named(colourID))
                            showPricesShare = AppFiles.write(data, folder: "Exports", name: "ChargeCheck price list.pdf")
                        } label: {
                            Label("Price list as a PDF", systemImage: "doc.richtext")
                        }
                        if let showPricesShare {
                            ShareLink(item: showPricesShare) {
                                Label("Save or send the price list", systemImage: "square.and.arrow.up")
                            }
                        }
                    } header: {
                        Text("Invoices and reports")
                    } footer: {
                        Text("Copies of the original photo or PDF are kept in the Files app › ChargeCheck › Invoices, by month. The reminder arrives on the 1st of each month to send last month's report to your accountant.")
                    }

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
                if case .failure = result { notice = String(localized: "The backup couldn't be saved. Please try again.") }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .plainText]) { result in
                open(result)
            }
            .background {
                // a second file picker has to hang off a different view
                Color.clear
                    .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                        pickedFolder(result)
                    }
            }
            .confirmationDialog("Restore this backup?", isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ), titleVisibility: .visible, presenting: pendingRestore) { backup in
                Button("Replace what's on this phone", role: .destructive) {
                    AppData.restore(backup, into: context)
                    let scans = store.restoreScans(from: backup.scans)
                    notice = scans > 0 ? String(localized: "Backup restored, with \(scans) unused scans.") : String(localized: "Backup restored.")
                    AutoBackup.run(context, scans: store.ledger.forBackup)
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

    private func save() {
        guard let data = try? AppData.backup(context, scans: store.ledger.forBackup).encoded() else {
            notice = String(localized: "The backup couldn't be made. Please try again.")
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
            notice = String(localized: "That isn't a ChargeCheck backup file.")
            return
        }
        pendingRestore = backup
    }
}
