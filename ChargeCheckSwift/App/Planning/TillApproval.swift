import SwiftUI
import LocalAuthentication
import ChargeCheckCore

/// Something the cashier isn't allowed to do alone, waiting for a manager's PIN.
struct ApprovalRequest: Identifiable {
    let id = UUID()
    let title: String
    /// The phone's own Face ID or passcode also unlocks it (the till settings: so the owner can never be locked out).
    var deviceOwner = false
    /// Called with the manager's name once they've typed their PIN.
    let then: (String) -> Void
}

extension View {
    /// Shows the manager PIN pad while a request is waiting.
    func managerApproval(_ request: Binding<ApprovalRequest?>) -> some View {
        sheet(item: request) { pending in
            ManagerPinSheet(request: pending) { request.wrappedValue = nil }
        }
    }
}

struct ManagerPinSheet: View {
    let request: ApprovalRequest
    let close: () -> Void
    @ObservedObject private var till = TillStore.shared

    private func approve(_ name: String) {
        close()
        // after the sheet has gone, so the next sheet can open
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { request.then(name) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text(request.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                PinPad(title: String(localized: "Manager's PIN")) { pin in
                    guard let manager = till.manager(pin: pin) else { return false }
                    approve(manager.name)
                    return true
                }
                if request.deviceOwner {
                    Button {
                        let context = LAContext()
                        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Unlock the till settings")) { ok, _ in
                            if ok { Task { @MainActor in approve(String(localized: "Owner")) } }
                        }
                    } label: {
                        Label("Use this iPhone's Face ID or passcode", systemImage: "faceid")
                    }
                    .padding(.bottom)
                }
            }
            .padding(.top)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close() }
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled()
    }
}

/// Asks for a manager only when the person serving can't do it alone.
@MainActor
enum Gate {
    /// Runs `action` straight away (approvedBy nil), or after a manager's PIN.
    static func check(_ permission: TillPermission, _ title: String, request: Binding<ApprovalRequest?>,
                      action: @escaping (String?) -> Void) {
        if TillStore.shared.may(permission) {
            action(nil)
        } else {
            request.wrappedValue = ApprovalRequest(title: title, deviceOwner: permission == .settings) { name in action(name) }
        }
    }
}

enum PermissionText {
    static func title(_ permission: TillPermission) -> String {
        switch permission {
        case .refund: return String(localized: "Give refunds")
        case .discount: return String(localized: "Give discounts")
        case .priceChange: return String(localized: "Change a price at the till")
        case .customAmount: return String(localized: "Sell something not in the list")
        case .removeLine: return String(localized: "Take items off a sale")
        case .cashIn: return String(localized: "Put cash in")
        case .cashOut: return String(localized: "Take cash out")
        case .float: return String(localized: "Enter the opening float")
        case .noSale: return String(localized: "Open the drawer without a sale")
        case .closeDay: return String(localized: "Close the day")
        case .giftCard: return String(localized: "Sell gift cards")
        case .tab: return String(localized: "Put sales on a customer's account")
        case .settings: return String(localized: "Change the till settings")
        }
    }
}

enum RoleText {
    static func title(_ role: TillRole) -> String {
        switch role {
        case .owner: return String(localized: "Owner")
        case .manager: return String(localized: "Manager")
        case .cashier: return String(localized: "Cashier")
        }
    }
}
