import XCTest
import StoreKit
import StoreKitTest
import SwiftUI
import ChargeCheckCore
@testable import ChargeCheck

/// Buys things for real against Apple's StoreKit test server (no money involved) to check
/// the money logic: products and trial, packs counted once, subscriptions unlock and expire.
@MainActor
final class StoreTests: XCTestCase {
    private var session: SKTestSession!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "Products")
        session.resetToDefaultState()
        session.clearTransactions()
        // the prices in Products.storekit are UK prices: never let the cloud Mac's own country change them
        session.storefront = "GBR"
        session.locale = Locale(identifier: "en_GB")
        session.disableDialogs = true
        defaults = UserDefaults(suiteName: "chargecheck.store.tests")
        defaults.removePersistentDomain(forName: "chargecheck.store.tests")
    }

    /// Buys through the StoreKit test session (no purchase sheet, which can hang on the cloud simulators), then waits
    /// up to 30 s for the store to take it in. The store's own money logic (handle, refresh) does the rest.
    private func purchase(_ id: String, on store: Store, until done: @MainActor () -> Bool) async throws {
        _ = try await session.buyProduct(identifier: id)
        for _ in 0..<60 {
            if let latest = await Transaction.latest(for: id) { await store.handle(latest) }
            await store.refresh()
            if done() { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTFail("the store didn't take in \(id) within 30 s")
    }

    private func makeStore() async -> Store {
        let store = Store(defaults: defaults)
        await store.loadProducts()
        await store.refresh()
        return store
    }

    func testProductsAndTrial() async throws {
        let store = await makeStore()
        XCTAssertEqual(store.plans.map { $0.id }, [Products.yearly, Products.monthly], store.loadStatus)
        XCTAssertEqual(store.packs.map { $0.id }, Products.packOrder, store.loadStatus)
        let yearly = try XCTUnwrap(store.yearly)
        let monthly = try XCTUnwrap(store.monthly)
        XCTAssertEqual(yearly.price, Decimal(string: "89.99"), "storefront \(session.storefront), \(yearly.displayPrice)")
        XCTAssertEqual(monthly.price, Decimal(string: "8.99"))
        let offer = try XCTUnwrap(yearly.subscription?.introductoryOffer)
        XCTAssertEqual(offer.paymentMode, .freeTrial)
        XCTAssertEqual(offer.period.unit, .week)
        XCTAssertEqual(offer.period.value, 1)
        XCTAssertEqual(try XCTUnwrap(monthly.subscription?.introductoryOffer).paymentMode, .freeTrial)
        XCTAssertTrue(store.trialAvailable)
        XCTAssertFalse(store.isSubscribed)
        XCTAssertFalse(store.canScan)
    }

    func testBuyingPacksAddsScansOnce() async throws {
        let store = await makeStore()
        XCTAssertNotNil(store.packs.first { $0.id == "chargecheck_scans_10" })
        try await purchase("chargecheck_scans_10", on: store) { store.credits >= 10 }
        XCTAssertEqual(store.credits, 10, "handled several times, counted once")
        XCTAssertTrue(store.canScan)
        XCTAssertFalse(store.isSubscribed)
        XCTAssertNotNil(store.packs.first { $0.id == "chargecheck_scans_3" })
        try await purchase("chargecheck_scans_3", on: store) { store.credits >= 13 }
        XCTAssertEqual(store.credits, 13)
        // looking at every purchase again must not add scans twice
        if let latest = await Transaction.latest(for: "chargecheck_scans_3") { await store.handle(latest) }
        XCTAssertEqual(store.credits, 13)
        // scans are saved: a fresh start on the same phone still has them
        let again = Store(defaults: defaults)
        XCTAssertEqual(again.credits, 13)
        XCTAssertEqual(again.useScans(1), 1)
        XCTAssertEqual(Store(defaults: defaults).credits, 12)
    }

    func testUsingScansAndAdReward() async throws {
        let store = await makeStore()
        XCTAssertEqual(store.useScans(1), 0)     // nothing to use: no scan
        store.addAdReward()
        XCTAssertEqual(store.credits, 1)
        XCTAssertEqual(store.useScans(1), 1)
        XCTAssertFalse(store.canScan)
        store.refundScan()
        XCTAssertEqual(store.credits, 1)
    }

    func testSubscribingUnlocksAndExpiryLocks() async throws {
        let store = await makeStore()
        XCTAssertNotNil(store.yearly)
        try await purchase(Products.yearly, on: store) { store.isSubscribed }
        XCTAssertEqual(store.subscribedProductID, Products.yearly)
        XCTAssertTrue(store.isSubscribed)
        XCTAssertTrue(store.canScan)
        XCTAssertEqual(store.credits, 0)
        // a fresh start (or Restore purchases) finds it again
        let again = await makeStore()
        XCTAssertTrue(again.isSubscribed)
        // test mode can pretend to be a free user
        again.testAsFree = true
        XCTAssertEqual(again.isSubscribed, !AppConfig.testBuild)
        again.testAsFree = false
        // when it ends, the app is free again
        try session.expireSubscription(productIdentifier: Products.yearly)
        // the test server takes a moment to pass the news on (on the cloud Macs sometimes over 10 seconds)
        for _ in 0..<60 {
            await store.refresh()
            if !store.isSubscribed { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertFalse(store.isSubscribed)
        XCTAssertFalse(store.canScan)
    }

    func testMonthlyPlan() async throws {
        let store = await makeStore()
        XCTAssertNotNil(store.monthly)
        try await purchase(Products.monthly, on: store) { store.isSubscribed }
        XCTAssertEqual(store.subscribedProductID, Products.monthly)
        XCTAssertTrue(store.isSubscribed)
    }

    /// Not a check: saves a picture of the plans screen with the test prices, for the build log.
    func testPicturePaywall() async throws {
        let store = await makeStore()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let window = scene?.windows.first, let root = window.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let host = UIHostingController(rootView: PaywallView().environmentObject(store))
        host.modalPresentationStyle = .fullScreen
        top.present(host, animated: false)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let picture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let data = picture.pngData() {
            try? data.write(to: URL(fileURLWithPath: "/tmp/shot-9-plans.png"))
        }
        host.dismiss(animated: false)
    }
}
