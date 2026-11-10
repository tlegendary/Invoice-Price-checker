import SwiftUI
import SwiftData

struct RootView: View {
    let storageProblem: Bool

    @AppStorage(SettingKey.mode) private var mode = "auto"
    @AppStorage(SettingKey.colour) private var colourID = "green"
    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var context
    @State private var carriedOver = 0
    @State private var showCarriedOver = false

    var body: some View {
        TabView {
            CheckView(storageProblem: storageProblem)
                .tabItem { Label("Check", systemImage: "doc.text.viewfinder") }
            PricesView()
                .tabItem { Label("Prices", systemImage: "tag") }
            ReportsView()
                .tabItem { Label("Reports", systemImage: "chart.bar") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
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
