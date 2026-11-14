import SwiftUI
import ChargeCheckCore

/// Opens the plans screen for a locked feature, from anywhere in the app.
@MainActor
final class Upsell: ObservableObject {
    static let shared = Upsell()
    @Published var feature: Feature?
    /// Asks the root view to open the plans screen.
    @Published var open = false

    func show(_ feature: Feature?) {
        self.feature = feature
        open = true
    }
}

/// The plan the user is on, for code that has no view around it (the widget data, Apple Intelligence).
enum PlanMirror {
    private static let key = "plan.tier"

    static var tier: Tier { Tier(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .free }

    static func set(_ tier: Tier) {
        guard UserDefaults.standard.integer(forKey: key) != tier.rawValue || UserDefaults.standard.object(forKey: key) == nil else { return }
        UserDefaults.standard.set(tier.rawValue, forKey: key)
    }

    static func allows(_ feature: Feature) -> Bool { Plans.allows(feature, tier: tier) }
}

/// "PRO" or "PACK" in a small capsule next to a locked feature.
struct PlanTag: View {
    let tier: Tier

    var body: some View {
        Text(tier == .pro ? "PRO" : "PACK")
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tier == .pro ? Color.purple : Color.blue))
            .foregroundStyle(.white)
            .accessibilityLabel(tier == .pro ? Text("Pro feature") : Text("Comes with any scan pack"))
    }
}

/// A row that opens `destination` when the plan allows it, and otherwise shows the feature with its tag
/// and opens the plans screen.
struct GatedLink<Content: View, Destination: View>: View {
    let feature: Feature
    let destination: () -> Destination
    let label: () -> Content

    @EnvironmentObject private var store: Store

    init(_ feature: Feature, @ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: @escaping () -> Content) {
        self.feature = feature
        self.destination = destination
        self.label = label
    }

    var body: some View {
        if store.allows(feature) {
            NavigationLink(destination: destination, label: label)
        } else {
            LockedRow(feature: feature, label: label)
        }
    }
}

/// A locked feature: its usual label, the plan tag, and a tap that opens the plans screen.
struct LockedRow<Content: View>: View {
    let feature: Feature
    @ViewBuilder let label: () -> Content

    var body: some View {
        Button {
            Upsell.shared.show(feature)
        } label: {
            HStack {
                label()
                Spacer(minLength: 8)
                PlanTag(tier: feature.tier)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A button that runs `action` when allowed, otherwise opens the plans screen.
struct GatedButton<Content: View>: View {
    let feature: Feature
    let action: () -> Void
    @ViewBuilder let label: () -> Content

    @EnvironmentObject private var store: Store

    var body: some View {
        if store.allows(feature) {
            Button(action: action, label: label)
        } else {
            LockedRow(feature: feature, label: label)
        }
    }
}

/// What a feature is called and what it does, for the plans screen.
enum FeatureText {
    static func title(_ feature: Feature) -> String {
        switch feature {
        case .fullHistory: return String(localized: "Full invoice history")
        case .exports: return String(localized: "Exports for your accountant")
        case .creditPDF: return String(localized: "Credit request PDFs")
        case .deliveryCheck: return String(localized: "Delivery check")
        case .statementCheck: return String(localized: "Statement check")
        case .moneyLeaks: return String(localized: "Money leaks and savings")
        case .priceRises: return String(localized: "Price-rise alerts")
        case .cheaperElsewhere: return String(localized: "Cheaper elsewhere")
        case .supplierScores: return String(localized: "Supplier profiles and scores")
        case .supplierReport: return String(localized: "Supplier report PDF")
        case .dueDates: return String(localized: "Payment due dates")
        case .payRun: return String(localized: "Pay run")
        case .weeklyReminder: return String(localized: "Weekly payment reminder")
        case .shops: return String(localized: "Several shops")
        case .staff: return String(localized: "Staff on their own iPhones")
        case .widget: return String(localized: "Home screen widget")
        case .smartCheck: return String(localized: "Apple Intelligence check")
        case .monthlySummary: return String(localized: "Monthly summary")
        case .changeHistory: return String(localized: "History of changes")
        }
    }

    static func why(_ feature: Feature) -> String {
        switch feature {
        case .fullHistory: return String(localized: "The free version shows the last 30 days. Any scan pack keeps every invoice, for good.")
        case .exports: return String(localized: "PDF and spreadsheet reports for any period, ready to send to your accountant.")
        case .creditPDF: return String(localized: "A proper credit request to send your supplier, with every overcharge and missing item.")
        case .deliveryCheck: return String(localized: "Tick off what arrived; anything short comes off what you pay.")
        case .statementCheck: return String(localized: "Scan a supplier's statement and see anything that doesn't match your records.")
        case .moneyLeaks: return String(localized: "See what price rises and missing credits cost you each month, and everything ChargeCheck caught.")
        case .priceRises: return String(localized: "Know straight away when a supplier charges more than last time.")
        case .cheaperElsewhere: return String(localized: "Items another supplier sells you for less, and what switching would save a month.")
        case .supplierScores: return String(localized: "A score out of 100 for each supplier: prices, deliveries and invoice accuracy.")
        case .supplierReport: return String(localized: "A full report on one supplier to keep or take to a meeting.")
        case .dueDates: return String(localized: "Credit periods for each supplier, with overdue invoices and the cash you need this week.")
        case .payRun: return String(localized: "Pay several suppliers at once and record every payment in one go.")
        case .weeklyReminder: return String(localized: "A reminder on the day you pay your suppliers.")
        case .shops: return String(localized: "Keep each shop's invoices apart and compare them.")
        case .staff: return String(localized: "Staff check invoices on their own iPhones and everything comes to yours.")
        case .widget: return String(localized: "What you owe and to whom, on your home screen.")
        case .smartCheck: return String(localized: "Apple Intelligence double-checks names and matches on your iPhone.")
        case .monthlySummary: return String(localized: "Your month in plain words: what you spent, who overcharged, what went up.")
        case .changeHistory: return String(localized: "Who saved, paid, changed or deleted what, and when.")
        }
    }
}
