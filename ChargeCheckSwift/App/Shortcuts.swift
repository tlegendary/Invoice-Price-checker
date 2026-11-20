import AppIntents

/// "Hey Siri, check an invoice in ChargeCheck" – also in Spotlight, the Shortcuts app and the Action button.
/// Opens ChargeCheck on the Check tab with the camera scanner ready.
struct CheckInvoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "Check an invoice"
    static var description = IntentDescription("Opens ChargeCheck with the camera, ready to scan a supplier invoice.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentInbox.scanRequested = true
        NotificationCenter.default.post(name: IntentInbox.notification, object: nil)
        return .result()
    }
}

struct ChargeCheckShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CheckInvoiceIntent(),
                    phrases: ["Check an invoice in \(.applicationName)",
                              "Scan an invoice with \(.applicationName)",
                              "\(.applicationName) scan"],
                    shortTitle: "Check an invoice",
                    systemImageName: "doc.text.viewfinder")
    }
}

/// Hands a Siri / Shortcuts request over to the app's screens.
@MainActor
enum IntentInbox {
    static var scanRequested = false
    static let notification = Notification.Name("ChargeCheck.scanRequested")

    /// True once per request.
    static func takeScanRequest() -> Bool {
        defer { scanRequested = false }
        return scanRequested
    }
}
