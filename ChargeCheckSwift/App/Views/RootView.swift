import SwiftUI
import SwiftData

struct RootView: View {
    let storageProblem: Bool

    @AppStorage(SettingKey.mode) private var mode = "auto"
    @AppStorage(SettingKey.colour) private var colourID = "green"
    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var context
    @StateObject private var session = CheckSession()
    @State private var carriedOver = 0
    @State private var showCarriedOver = false
    /// Which tab is open. The cloud check can start on another tab with "-startTab prices".
    @State private var tab = UserDefaults.standard.string(forKey: "startTab") ?? "check"

    var body: some View {
        TabView(selection: $tab) {
            CheckView(storageProblem: storageProblem)
                .tabItem { Label("Check", systemImage: "doc.text.viewfinder") }
                .tag("check")
            PricesView()
                .tabItem { Label("Prices", systemImage: "tag") }
                .tag("prices")
            ReportsView()
                .tabItem { Label("Reports", systemImage: "chart.bar") }
                .tag("reports")
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag("settings")
        }
        .environmentObject(session)
        .tint(Themes.named(colourID).accent(for: scheme))
        .preferredColorScheme(mode == "light" ? .light : (mode == "dark" ? .dark : nil))
        .task {
            carriedOver = AppData.importLegacyBackupIfNeeded(context)
            showCarriedOver = carriedOver > 0
        }
        .alert("Your prices are here", isPresented: $showCarriedOver) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(carriedOver) prices and your reports were brought over from the previous version of the app.")
        }
    }
}
