import ChargeCheckCore
import Foundation
import SwiftUI

/// The card companies ChargeCheck plugs into, all through the same `PaymentProvider` interface. Each goes live only
/// with the shop's own merchant account and keys; until then the till records card machine payments (CC-007).
enum CardProviders {
    struct Info: Identifiable {
        let id: String
        let name: String
        /// What's needed before it can take money.
        let needs: LocalizedStringKey
        let icon: String
    }

    static let all: [Info] = [
        Info(id: "tap-to-pay", name: "Tap to Pay on iPhone", needs: "Apple's approval for the app, plus an account with a supported card company.", icon: "wave.3.right"),
        Info(id: "stripe", name: "Stripe Terminal", needs: "A Stripe account, its keys, and a Stripe card reader or Tap to Pay.", icon: "creditcard"),
        Info(id: "square", name: "Square", needs: "A Square account and a Square reader.", icon: "square"),
        Info(id: "sumup", name: "SumUp", needs: "A SumUp account and a SumUp card reader.", icon: "creditcard.circle"),
        Info(id: "adyen", name: "Adyen", needs: "An Adyen merchant account and an Adyen terminal.", icon: "building.columns")
    ]

    /// None is connected yet: every card company needs the shop's own account first.
    static func isConnected(_ id: String) -> Bool { false }
}

/// Card payment attempts kept on this device, saved BEFORE a card company is asked (so a crash can't lead to a
/// second charge). One file, written atomically and protected while the phone is locked.
actor FileAttemptStore: PaymentAttemptStore {
    static let shared = FileAttemptStore()
    private let url: URL
    private var attempts: [String: PaymentAttempt]

    init(url: URL = URL.applicationSupportDirectory.appending(path: "Payments/attempts.json")) {
        self.url = url
        let data = try? Data(contentsOf: url)
        attempts = data.flatMap { try? JSONDecoder().decode([String: PaymentAttempt].self, from: $0) } ?? [:]
    }

    func save(_ attempt: PaymentAttempt) async throws {
        attempts[attempt.id] = attempt
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(attempts)
        guard SaveWatch.write(data, to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) else {
            throw ProviderError.refused("couldn't save the payment")
        }
    }

    func open() async -> [PaymentAttempt] { attempts.values.filter { !$0.status.isFinal } }

    /// Card payments without a final answer, read straight from the file (for the health report).
    nonisolated static func openCount() -> Int {
        let url = URL.applicationSupportDirectory.appending(path: "Payments/attempts.json")
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([String: PaymentAttempt].self, from: data) else { return 0 }
        return all.values.filter { !$0.status.isFinal }.count
    }
}

/// More › Card payments: which card companies can be connected and what each needs.
struct CardPaymentsView: View {
    var body: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Card machine").font(.headline)
                        Text("Working now: take the card on your own card machine and the till records who confirmed it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            Section {
                ForEach(CardProviders.all) { provider in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name).font(.headline)
                            Text(provider.needs).font(.footnote).foregroundStyle(.secondary)
                            Text("Not connected").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        }
                    } icon: {
                        Image(systemName: provider.icon)
                    }
                }
            } header: {
                Text("Card companies")
            } footer: {
                Text("Each card company connects through the same checkout once you have an account with it. The till never shows a card payment as paid until the card company confirms it.")
            }
        }
        .navigationTitle("Card payments")
    }
}
