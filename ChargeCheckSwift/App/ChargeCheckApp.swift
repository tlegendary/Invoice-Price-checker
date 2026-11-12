import SwiftUI
import SwiftData

@main
struct ChargeCheckApp: App {
    private let storage = AppStorageSetup.open()
    /// Opens staff invite links (iCloud sharing).
    @UIApplicationDelegateAdaptor(TeamAppDelegate.self) private var teamDelegate

    init() {
        Regional.apply()
    }

    var body: some Scene {
        WindowGroup {
            RootView(storageProblem: storage.failed)
                .modelContainer(storage.container)
        }
    }
}

/// Opens the app's saved data. If the saved data can't be opened the app still starts
/// (with temporary storage) and tells the user, instead of crashing.
enum AppStorageSetup {
    static func open() -> (container: ModelContainer, failed: Bool) {
        let schema = Schema([StoredPrice.self, StoredReport.self])
        // IMPORTANT: `cloudKitDatabase: .none` and `groupContainer: .none` must stay.
        // Left on "automatic", SwiftData sees the app's iCloud entitlement (staff sharing) and tries to sync this store through
        // CloudKit, which this schema doesn't allow, so the store can't open at all – builds 14 and 15 crashed on launch from
        // exactly that (crash log 13 Nov 2026). And with an App Group (the widget) it would move the store to the group
        // folder, away from the user's existing data. The data stays where it has always been: Application Support.
        let onDisk = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, groupContainer: .none, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: schema, configurations: [onDisk]) {
            return (container, false)
        }
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, groupContainer: .none, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: schema, configurations: [memory]) {
            return (container, true)
        }
        fatalError("ChargeCheck could not create any storage")
    }
}
