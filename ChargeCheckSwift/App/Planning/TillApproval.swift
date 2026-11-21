import SwiftUI
import LocalAuthentication
import ChargeCheckCore

/// Something the cashier isn't allowed to do alone, waiting for a manager's PIN.
struct ApprovalRequest: Identifiable {
    let id = UUID()
    let title: String
    /// What the manager is saying yes to (the till store only lets these through once each).
    var permissions: [TillPermission] = []
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
                    guard let manager = till.approve(request.permissions, pin: pin) else { return false }
                    approve(manager.name)
                    return true
                }
                if till.pinLockout.wait(at: Date()) > 0 {
                    Text("Too many wrong PINs. Wait a moment, then try again.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if request.deviceOwner {
                    Button {
                        let context = LAContext()
                        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Unlock the till settings")) { ok, _ in
                            if ok {
                                Task { @MainActor in
                                    till.approveAsDeviceOwner(request.permissions)
                                    approve(String(localized: "Owner"))
                                }
                            }
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
    /// Changes to the sale on screen (the basket isn't saved until the sale is). For these the till store spends
    /// the manager's yes the moment the change is made, so nothing on screen can make one without it. Refunds, cash,
    /// closing the day and the like spend it inside the till store instead, when they're saved.
    static let basketChanges: Set<TillPermission> = [.discount, .priceChange, .customAmount, .removeLine, .giftCard, .tab]

    /// Runs `action` straight away (approvedBy nil), or after a manager's PIN.
    static func check(_ permission: TillPermission, _ title: String, request: Binding<ApprovalRequest?>,
                      action: @escaping (String?) -> Void) {
        check([permission], title, request: request, action: action)
    }

    /// Several things at once (one PIN for all): runs `action` only when the till store allows every one.
    static func check(_ permissions: [TillPermission], _ title: String, request: Binding<ApprovalRequest?>,
                      action: @escaping (String?) -> Void) {
        let till = TillStore.shared
        if permissions.allSatisfy({ till.may($0) }) {
            action(nil)
            return
        }
        request.wrappedValue = ApprovalRequest(title: title, permissions: permissions,
                                               deviceOwner: permissions == [.settings]) { name in
            // spend the yes now for changes to the basket; the rest is spent by the store when it's saved
            for permission in permissions where basketChanges.contains(permission) {
                guard till.authorize(permission) != nil else { return }
            }
            action(name)
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

/// A screen only a manager or the owner may change (prices, vouchers, permissions…): others unlock it with a
/// manager's PIN or the phone's Face ID.
struct ManagerOnly<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @ObservedObject private var till = TillStore.shared
    @State private var unlocked = false
    @State private var approval: ApprovalRequest?

    private var allowed: Bool { unlocked || !till.hasManagers || (till.cashier?.role ?? .cashier).isManager }

    var body: some View {
        if allowed {
            content()
        } else {
            ContentUnavailableView {
                Label("Managers only", systemImage: "lock")
            } description: {
                Text("Only a manager or the owner can change this.")
            } actions: {
                Button("Unlock") {
                    approval = ApprovalRequest(title: String(localized: "Change the till settings"), deviceOwner: true) { _ in unlocked = true }
                }
                .buttonStyle(.borderedProminent)
            }
            .managerApproval($approval)
        }
    }
}
