import SwiftUI
import UIKit
import LocalAuthentication

/// An optional lock: Face ID, Touch ID or the phone's passcode before ChargeCheck shows anything.
/// Useful on a phone that staff or family also use – prices, suppliers and payments stay private.
enum AppLock {
    static let settingKey = "security.lock"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    /// Whether this phone can lock the app (it has Face ID, Touch ID or a passcode set).
    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Asks for Face ID / Touch ID, falling back to the passcode. Returns true when it is the owner.
    static func unlock() async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                   localizedReason: String(localized: "Unlock ChargeCheck"))) ?? false
    }
}

/// Covers the app until it is unlocked.
struct LockScreen: View {
    let onUnlock: () -> Void
    @State private var trying = false
    /// Face ID is asked once each time the app comes to the front (not again straight after "Cancel").
    @State private var askedThisTime = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("ChargeCheck is locked")
                .font(.title3.weight(.semibold))
            Button {
                attempt()
            } label: {
                Label("Unlock", systemImage: "faceid")
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .disabled(trying)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task { askOnce() }
        .onChange(of: phase) {
            if phase == .background { askedThisTime = false }
            if phase == .active { askOnce() }
        }
    }

    private func askOnce() {
        guard UIApplication.shared.applicationState == .active, !askedThisTime else { return }
        askedThisTime = true
        attempt()
    }

    private func attempt() {
        guard !trying else { return }
        trying = true
        Task {
            let ok = await AppLock.unlock()
            trying = false
            if ok { onUnlock() }
        }
    }
}

/// Shows the lock screen in its own window above everything else – including any sheet
/// (an invoice, the paywall, an export) that was open when the app was left.
@MainActor
final class LockCover {
    static let shared = LockCover()
    private var window: UIWindow?

    var isShowing: Bool { window != nil }

    func show(onUnlock: @escaping () -> Void) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first(where: { $0.activationState == .foregroundInactive })
                ?? scenes.first else { return }
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        cover.rootViewController = UIHostingController(rootView: LockScreen { [weak self] in
            self?.hide()
            onUnlock()
        })
        cover.makeKeyAndVisible()
        window = cover
    }

    func hide() {
        guard let cover = window else { return }
        cover.isHidden = true
        window = nil
        cover.windowScene?.windows.first { $0 !== cover && !$0.isHidden }?.makeKey()
    }
}
