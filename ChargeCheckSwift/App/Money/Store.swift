import Foundation
import StoreKit
import ChargeCheckCore

enum BuyOutcome: Equatable {
    /// Bought. `scans` is how many scans were added (0 for a subscription).
    case done(scans: Int)
    case cancelled
    /// Waiting for approval (Ask to Buy, bank check). It is added automatically when approved.
    case pending
    case failed(String)
}

/// Subscriptions, scan packs and the scans a non-subscriber has left (StoreKit 2).
@MainActor
final class Store: ObservableObject {
    @Published private(set) var plans: [Product] = []
    @Published private(set) var packs: [Product] = []
    /// The subscription the user has now, if any.
    @Published private(set) var subscribedProductID: String?
    @Published private(set) var trialAvailable = true
    @Published private(set) var ledger: ScanLedger
    @Published private(set) var loadStatus = String(localized: "Not loaded yet")
    @Published private(set) var checkedEntitlements = false
    /// Test mode only: behave as a free user even with a subscription.
    @Published var testAsFree: Bool {
        didSet { defaults.set(testAsFree, forKey: Keys.testAsFree) }
    }

    /// Test builds only: try the app as "free", "packs" or "pro" without buying ("" = what was really bought).
    @Published var testTier: String {
        didSet { defaults.set(testTier, forKey: Keys.testTier) }
    }

    private let defaults: UserDefaults
    private var updates: Task<Void, Never>?

    private enum Keys {
        static let ledger = "scan.ledger"
        static let testAsFree = "test.asFree"
        static let testTier = "test.tier"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.ledger), let saved = try? JSONDecoder().decode(ScanLedger.self, from: data) {
            ledger = saved
        } else {
            ledger = ScanLedger()
        }
        testAsFree = defaults.bool(forKey: Keys.testAsFree)
        testTier = defaults.string(forKey: Keys.testTier) ?? ""
        saveLedger()
    }

    var isSubscribed: Bool {
        if AppConfig.testBuild {
            if testTier == "pro" { return true }
            if testTier == "free" || testTier == "packs" { return false }
        }
        return subscribedProductID != nil && !(AppConfig.testBuild && testAsFree)
    }

    /// Free, scan packs (any pack bought, ever) or Pro (a subscription).
    var tier: Tier {
        if isSubscribed { return .pro }
        if AppConfig.testBuild {
            if testTier == "packs" { return .packs }
            if testTier == "free" { return .free }
        }
        return ledger.hasBought ? .packs : .free
    }

    func allows(_ feature: Feature) -> Bool {
        Plans.allows(feature, tier: tier)
    }

    var credits: Int { ledger.credits }

    /// A subscriber can always scan; a free user needs a scan (from a pack or an ad).
    var canScan: Bool { isSubscribed || credits > 0 }

    var yearly: Product? { plans.first { $0.id == Products.yearly } }
    var monthly: Product? { plans.first { $0.id == Products.monthly } }

    // MARK: - starting up

    /// Call once when the app opens.
    func start() {
        if updates == nil {
            updates = Task { [weak self] in
                for await result in Transaction.updates {
                    await self?.handle(result)
                }
            }
        }
        Task {
            await refresh()
            await finishUnfinished()
            await loadProducts()
        }
    }

    func loadProducts() async {
        do {
            let found = try await Product.products(for: Products.plans + Products.packOrder)
            plans = Products.plans.compactMap { id in found.first { $0.id == id } }
            packs = Products.packOrder.compactMap { id in found.first { $0.id == id } }
            loadStatus = "\(plans.count) of 2 plans and \(packs.count) of 3 packs returned by the App Store"
            if let subscription = (yearly ?? monthly)?.subscription {
                trialAvailable = await subscription.isEligibleForIntroOffer
            }
        } catch {
            loadStatus = String(localized: "App Store error: \(error.localizedDescription)")
        }
    }

    /// Works out whether there is an active subscription.
    func refresh() async {
        var active: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if Products.plans.contains(transaction.productID), active != Products.yearly {
                active = transaction.productID
            }
        }
        subscribedProductID = active
        checkedEntitlements = true
    }

    /// Pack purchases that were paid for but not yet counted (for example the app closed mid-purchase).
    private func finishUnfinished() async {
        for await result in Transaction.unfinished {
            await handle(result)
        }
    }

    // MARK: - purchases

    /// Counts a purchase. Only purchases Apple has verified are accepted.
    func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        if Products.packs[transaction.productID] != nil {
            if transaction.revocationDate == nil {
                ledger.creditPack(productID: transaction.productID, transactionID: String(transaction.id))
                saveLedger()
            }
            await transaction.finish()
        } else {
            await transaction.finish()
            await refresh()
        }
    }

    func buy(_ product: Product) async -> BuyOutcome {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified = verification else { return .failed(String(localized: "The App Store couldn't verify this purchase.")) }
                let before = credits
                await handle(verification)
                return .done(scans: credits - before)
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed(String(localized: "The purchase didn't finish."))
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// "Restore purchases": asks the App Store again, then re-checks. Returns true when a subscription was found.
    func restore() async -> Bool {
        try? await AppStore.sync()
        await finishUnfinished()
        await refresh()
        return subscribedProductID != nil
    }

    // MARK: - scans for free users

    /// Takes up to `wanted` scans. Returns how many could be taken.
    func useScans(_ wanted: Int = 1) -> Int {
        let taken = ledger.use(wanted)
        if taken > 0 { saveLedger() }
        return taken
    }

    func refundScan() {
        ledger.refund()
        saveLedger()
    }

    /// One scan for one ad. Only called when the ad network confirms the reward.
    func addAdReward() {
        ledger.addAdReward()
        saveLedger()
    }

    @discardableResult
    func restoreScans(from scans: ScanCredits?) -> Int {
        let added = ledger.restore(from: scans)
        if added > 0 { saveLedger() }
        return added
    }

    /// TEST BUILDS ONLY – Ramyar's own testing. Remove before the App Store release (see MIGRATION.md).
    func addTestScans(_ count: Int = 5) {
        guard AppConfig.testBuild else { return }
        ledger.refund(count)
        saveLedger()
    }

    func adoptLegacyScans(_ count: Int) {
        ledger.adopt(legacyCredits: count)
        saveLedger()
    }

    private func saveLedger() {
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Keys.ledger) }
    }
}
