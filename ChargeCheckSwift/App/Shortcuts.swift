import AppIntents
import ChargeCheckCore

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
        AppShortcut(intent: OwedIntent(),
                    phrases: ["What do I owe in \(.applicationName)",
                              "How much do I owe suppliers in \(.applicationName)",
                              "\(.applicationName) what do I owe"],
                    shortTitle: "What do I owe?",
                    systemImageName: "banknote")
        AppShortcut(intent: DueThisWeekIntent(),
                    phrases: ["What's due this week in \(.applicationName)",
                              "What do I have to pay this week in \(.applicationName)",
                              "\(.applicationName) what's due"],
                    shortTitle: "What's due this week?",
                    systemImageName: "calendar.badge.clock")
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

/// What Siri answers from, saved by the app whenever invoices or payments change (Accounts.refreshWidget),
/// so a question is answered instantly without opening the app.
struct SiriFacts: Codable {
    struct Owed: Codable { var name: String; var amount: Double; var currency: String; var beforeVat: Double? }
    struct Due: Codable { var supplier: String; var amount: Double; var currency: String; var daysLeft: Int }
    var owed: [Owed]
    var due: [Due]
    var currency: String

    static let key = "siri.facts"

    static func save(_ facts: SiriFacts) {
        if let data = try? JSONEncoder().encode(facts) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func load() -> SiriFacts? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SiriFacts.self, from: data)
    }
}

/// "Hey Siri, what do I owe in ChargeCheck?" – in the main currency; another currency is said separately.
struct OwedIntent: AppIntent {
    static var title: LocalizedStringResource = "What do I owe?"
    static var description = IntentDescription("Says what you owe your suppliers, and to whom the most.")
    static var openAppWhenRun = false

    @Parameter(title: "Supplier")
    var supplier: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let facts = SiriFacts.load() else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Open ChargeCheck once so it can work this out.")))
        }
        if let wanted = supplier?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty {
            let key = SupplierAccounts.key(wanted)
            guard let row = facts.owed.first(where: { SupplierAccounts.key($0.name) == key || SupplierAccounts.key($0.name).contains(key) }) else {
                return .result(dialog: IntentDialog(stringLiteral: String(localized: "You don't owe \(wanted) anything.")))
            }
            var said = String(localized: "You owe \(row.name) \(Money.format(row.amount, code: row.currency)).")
            if let before = row.beforeVat { said += " " + String(localized: "That's \(Money.format(before, code: row.currency)) before VAT.") }
            return .result(dialog: IntentDialog(stringLiteral: said))
        }
        let main = facts.owed.filter { $0.currency == facts.currency }
        guard !main.isEmpty else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "You don't owe any suppliers anything.")))
        }
        let total = Money.round2(main.reduce(0) { $0 + $1.amount })
        let top = main.max { $0.amount < $1.amount }!
        var text = main.count == 1
            ? String(localized: "You owe \(top.name) \(Money.format(total, code: facts.currency)).")
            : String(localized: "You owe \(Money.format(total, code: facts.currency)) to \(main.count) suppliers. The most is \(top.name): \(Money.format(top.amount, code: facts.currency)).")
        let befores = main.compactMap(\.beforeVat)
        if befores.count == main.count, !befores.isEmpty {
            text += " " + String(localized: "That's \(Money.format(Money.round2(befores.reduce(0, +)), code: facts.currency)) before VAT.")
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

/// "Hey Siri, what's due this week in ChargeCheck?"
struct DueThisWeekIntent: AppIntent {
    static var title: LocalizedStringResource = "What's due this week?"
    static var description = IntentDescription("Says which supplier invoices are due in the next 7 days, and any overdue.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let facts = SiriFacts.load() else {
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Open ChargeCheck once so it can work this out.")))
        }
        let week = facts.due.filter { $0.daysLeft >= 0 && $0.daysLeft < 7 && $0.currency == facts.currency }
        let late = facts.due.filter { $0.daysLeft < 0 && $0.currency == facts.currency }
        var parts: [String] = []
        if week.isEmpty {
            parts.append(String(localized: "Nothing is due this week."))
        } else {
            let total = Money.round2(week.reduce(0) { $0 + $1.amount })
            let names = Array(Set(week.map(\.supplier))).sorted().prefix(3).joined(separator: ", ")
            parts.append(week.count == 1 ? String(localized: "1 invoice is due this week: \(Money.format(total, code: facts.currency)) to \(names).")
                                         : String(localized: "\(week.count) invoices are due this week: \(Money.format(total, code: facts.currency)), to \(names)."))
        }
        if !late.isEmpty {
            let total = Money.round2(late.reduce(0) { $0 + $1.amount })
            parts.append(late.count == 1 ? String(localized: "1 is overdue: \(Money.format(total, code: facts.currency)).")
                                         : String(localized: "\(late.count) are overdue: \(Money.format(total, code: facts.currency))."))
        }
        return .result(dialog: IntentDialog(stringLiteral: parts.joined(separator: " ")))
    }
}
