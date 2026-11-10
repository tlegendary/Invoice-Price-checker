import SwiftUI
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
        .task { attempt() }
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
