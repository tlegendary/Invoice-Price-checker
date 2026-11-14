import SwiftUI
import SwiftData
import StoreKit

struct RootView: View {
    let storageProblem: Bool

    @AppStorage(SettingKey.mode) private var mode = "auto"
    @AppStorage(SettingKey.colour) private var colourID = "green"
    @AppStorage(SettingKey.choseFree) private var choseFree = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var team = CloudTeam.shared
    @ObservedObject private var upsell = Upsell.shared
    @Environment(\.requestReview) private var requestReview
    @StateObject private var session = CheckSession()
    @StateObject private var store = Store()
    @StateObject private var ads = AdService()
    @State private var carriedOver = 0
    @State private var showCarriedOver = false
    @State private var showPaywall = false
    /// Settings › Lock with Face ID: the app is covered until unlocked, and again after leaving it.
    @State private var locked = AppLock.isOn
    /// Which tab is open. The cloud check can start on another tab with "-startTab prices".
    @State private var tab = RootView.firstTab
    /// "-startTab prices" / "settings" open those pages inside More.
    private static let startPage = UserDefaults.standard.string(forKey: "startTab").flatMap { MoreView.Page(rawValue: $0) }

    private static var firstTab: String {
        let wanted = UserDefaults.standard.string(forKey: "startTab") ?? ""
        if UserDefaults.standard.string(forKey: "demoScan") != nil { return "invoices" }
        switch wanted {
        case "check", "invoices": return "invoices"
        case "reports", "suppliers", "home", "more": return wanted
        case "": return "home"
        default: return MoreView.Page(rawValue: wanted) != nil ? "more" : "home"
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            HomeView(tab: $tab)
                .tabItem { Label("Home", systemImage: "house") }
                .tag("home")
            CheckView(storageProblem: storageProblem, showPaywall: $showPaywall)
                .tabItem { Label("Invoices", systemImage: "doc.text.viewfinder") }
                .tag("invoices")
            SuppliersView()
                .tabItem { Label("Suppliers", systemImage: "shippingbox") }
                .tag("suppliers")
            ReportsView()
                .tabItem { Label("Reports", systemImage: "chart.bar") }
                .tag("reports")
            MoreView(showPaywall: $showPaywall, open: Self.startPage)
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag("more")
        }
        .environmentObject(session)
        .environmentObject(store)
        .environmentObject(ads)
        .onOpenURL { url in
            // the home screen widget
            if url.scheme == "chargecheck" {
                if url.host == "suppliers" { tab = "suppliers" }
                return
            }
            // an invoice shared into ChargeCheck
            let kind = url.pathExtension.lowercased()
            guard url.isFileURL, ["pdf", "jpg", "jpeg", "png", "heic", "heif"].contains(kind) else { return }
            tab = "invoices"
            session.incoming.append(url)
        }
        .tint(Themes.named(colourID).accent(for: scheme))
        .preferredColorScheme(mode == "light" ? .light : (mode == "dark" ? .dark : nil))
        .task {
            CloudTeam.shared.start(context)
            if let legacy = AppData.importLegacyBackupIfNeeded(context) {
                // prices, reports and unused scans from the previous version of the app
                store.adoptLegacyScans(legacy.scans?.n ?? 0)
                carriedOver = legacy.baseline.count
                showCarriedOver = carriedOver > 0
            }
            session.onSaved = {
                Accounts.shared.changed(context)
                AutoBackup.run(context, scans: store.ledger.forBackup)
                askForRating()
            }
            if UserDefaults.standard.bool(forKey: "demoExport") {
                // the cloud check: write each kind of PDF so they can be looked at
                let all = AppData.entries(context)
                let theme = Themes.named(colourID)
                AppFiles.write(PDFMaker.report(all, period: "All time", business: "", theme: theme), folder: "Exports", name: "demo-report.pdf")
                AppFiles.write(PDFMaker.priceList(AppData.items(context), business: "", theme: theme), folder: "Exports", name: "demo-prices.pdf")
                if let first = all.first(where: { $0.over > 0.005 }) ?? all.first {
                    AppFiles.write(PDFMaker.creditRequest(first, business: "", theme: theme), folder: "Exports", name: "demo-credit.pdf")
                }
                AutoBackup.run(context, scans: store.ledger.forBackup)
            }
            Accounts.shared.changed(context)
            store.start()
            await store.refresh()
            if IntentInbox.takeScanRequest() {
                // opened by Siri / Shortcuts: "Check an invoice"
                tab = "invoices"
                session.openScanner = true
            }
            // first open without a subscription: show the plans once. Closing them carries on with the free version.
            let quiet = UserDefaults.standard.object(forKey: "startTab") != nil || UserDefaults.standard.object(forKey: "demoScan") != nil
            if UserDefaults.standard.bool(forKey: "showPaywall") || (!store.isSubscribed && !choseFree && !showCarriedOver && !quiet) {
                showPaywall = true
            }
        }
        .onAppear {
            if locked { LockCover.shared.show { locked = false } }
        }
        .onChange(of: locked) {
            // the cover is a separate window, so it also hides a sheet that was left open
            if locked { LockCover.shared.show { locked = false } } else { LockCover.shared.hide() }
        }
        .onReceive(NotificationCenter.default.publisher(for: IntentInbox.notification)) { _ in
            if IntentInbox.takeScanRequest() {
                tab = "invoices"
                session.openScanner = true
            }
        }
        .onChange(of: phase) {
            // leaving the app: make sure the automatic backup is up to date
            if phase != .active { AutoBackup.run(context, scans: store.ledger.forBackup) }
            if phase == .active { Task { await CloudTeam.shared.refresh() } }
            if phase == .background && AppLock.isOn { locked = true }
            if phase == .active && IntentInbox.takeScanRequest() {
                tab = "invoices"
                session.openScanner = true
            }
            // coming back to the app: check the subscription again, in case it ended or was renewed meanwhile
            if phase == .active && store.checkedEntitlements { Task { await store.refresh() } }
        }
        .alert("Price lowered", isPresented: Binding(get: { session.lowered != nil }, set: { if !$0 { session.lowered = nil } }), presenting: session.lowered) { note in
            Button("Undo") { session.undoLowered(note, context: context) }
            Button("OK", role: .cancel) {}
        } message: { note in
            Text(note.message + " " + String(localized: "You can turn this off in Settings."))
        }
        .alert("Your prices are here", isPresented: $showCarriedOver) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(carriedOver) prices and your reports were brought over from the previous version of the app.")
        }
        .onChange(of: upsell.open) {
            if upsell.open {
                upsell.open = false
                showPaywall = true
            }
        }
        .onChange(of: store.tier) { PlanMirror.set(store.tier) }
        .onAppear { PlanMirror.set(store.tier) }
        .sheet(isPresented: $showPaywall, onDismiss: {
            choseFree = true
            upsell.feature = nil
            PlanMirror.set(store.tier)
            Accounts.shared.changed(context)
        }) {
            PaywallView(reason: upsell.feature)
                .environmentObject(store)
                .tint(Themes.named(colourID).accent(for: scheme))
        }
    }

    /// After a few saved invoices, ask for an App Store rating. Apple decides whether to show it
    /// (three times a year at most); the app asks no more than once every four months.
    private func askForRating() {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: SettingKey.lastRatingAsk)
        let now = Date().timeIntervalSince1970
        guard AppData.entries(context).count >= 3, now - last > 120 * 86_400 else { return }
        defaults.set(now, forKey: SettingKey.lastRatingAsk)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            requestReview()
        }
    }
}
