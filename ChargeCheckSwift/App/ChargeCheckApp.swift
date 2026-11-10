import SwiftUI
import SwiftData

@main
struct ChargeCheckApp: App {
    private let storage = AppStorageSetup.open()

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
        if let container = try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema)]) {
            return (container, false)
        }
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        if let container = try? ModelContainer(for: schema, configurations: [memory]) {
            return (container, true)
        }
        fatalError("ChargeCheck could not create any storage")
    }
}
