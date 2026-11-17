import SwiftUI
import ChargeCheckCore

/// Money off the whole sale (amount or %).
struct BasketDiscountSheet: View {
    let subtotal: Double
    let current: Double
    let onDone: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var percent = true
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Sale", value: Money.format(subtotal))
                Picker("Money off", selection: $percent) {
                    Text("%").tag(true)
                    Text("Amount").tag(false)
                }
                .pickerStyle(.segmented)
                TextField(percent ? "10" : Money.format(0), text: $text)
                    .keyboardType(.decimalPad)
                HStack {
                    ForEach([5, 10, 15, 20], id: \.self) { p in
                        Button("\(p)%") {
                            percent = true
                            text = "\(p)"
                        }
                        .buttonStyle(.bordered)
                    }
                }
                if current > 0 {
                    Button("Remove the discount", role: .destructive) {
                        onDone(0)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Discount on the sale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let typed = Money.parse(text) ?? 0
                        onDone(Money.round2(min(subtotal, max(0, percent ? subtotal * min(typed, 100) / 100 : typed))))
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Parked sales to pick up again.
struct ParkedList: View {
    let shop: String
    let onPick: (ParkedSale) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var till = TillStore.shared

    var body: some View {
        NavigationStack {
            List {
                ForEach(till.parked.filter { $0.shop == shop }) { parked in
                    Button {
                        onPick(parked)
                        dismiss()
                    } label: {
                        LabeledContent(parked.name.isEmpty ? SalesText.time(parked.at) : parked.name,
                                       value: Money.format(Money.round2(parked.lines.reduce(0) { $0 + $1.gross })))
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button("Delete", role: .destructive) { _ = till.unpark(parked.id) }
                    }
                }
            }
            .navigationTitle("Parked sales")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

/// Cash put in or taken out of the drawer.
struct CashSheet: View {
    let kind: CashEvent.Kind
    let onSave: (Double, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var note = ""

    private var title: String {
        switch kind {
        case .float: return String(localized: "Opening float")
        case .paidIn: return String(localized: "Cash in")
        case .paidOut: return String(localized: "Cash out")
        case .tabPaid: return String(localized: "Account paid")
        case .noSale: return String(localized: "No sale")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(Money.format(0), text: $amount)
                    .keyboardType(.decimalPad)
                    .font(.title2)
                TextField(kind == .paidOut ? String(localized: "What for, e.g. paid the window cleaner") : String(localized: "Note (optional)"), text: $note)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let value = Money.parse(amount), value > 0 { onSave(value, note.trimmingCharacters(in: .whitespaces)) }
                        dismiss()
                    }
                    .disabled((Money.parse(amount) ?? 0) <= 0)
                }
            }
        }
    }
}

/// A PIN pad: four digits sign a cashier in.
struct PinPad: View {
    let title: String
    let check: (String) -> Bool
    @State private var pin = ""
    @State private var wrong = false

    var body: some View {
        VStack(spacing: 20) {
            Text(title).font(.title2.weight(.bold))
            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < pin.count ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 16, height: 16)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(pin.count) of 4 digits"))
            if wrong {
                Text("That PIN isn't right.").foregroundStyle(.red).font(.footnote)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(84)), count: 3), spacing: 14) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"], id: \.self) { key in
                    if key.isEmpty {
                        Color.clear.frame(height: 64)
                    } else {
                        Button {
                            press(key)
                        } label: {
                            Text(key)
                                .font(.title.weight(.semibold))
                                .frame(width: 84, height: 64)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(key == "⌫" ? String(localized: "Delete") : key))
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func press(_ key: String) {
        wrong = false
        if key == "⌫" {
            if !pin.isEmpty { pin.removeLast() }
            return
        }
        guard pin.count < 4 else { return }
        pin += key
        if pin.count == 4 {
            if !check(pin) {
                wrong = true
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            pin = ""
        }
    }
}

/// AirPrint for a plain text receipt or report.
enum Printing {
    @MainActor
    static func printText(_ text: String, title: String) {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .grayscale
        info.jobName = title
        controller.printInfo = info
        let formatter = UISimpleTextPrintFormatter(text: text)
        formatter.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        formatter.perPageContentInsets = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        controller.printFormatter = formatter
        controller.present(animated: true)
    }
}
