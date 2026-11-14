import XCTest
@testable import ChargeCheckCore

final class PlanTests: XCTestCase {
    func testWhatEachTierUnlocks() {
        XCTAssertFalse(Plans.allows(.exports, tier: .free))
        XCTAssertTrue(Plans.allows(.exports, tier: .packs))
        XCTAssertTrue(Plans.allows(.exports, tier: .pro))
        XCTAssertFalse(Plans.allows(.supplierScores, tier: .packs))
        XCTAssertTrue(Plans.allows(.supplierScores, tier: .pro))
        for feature in Feature.allCases { XCTAssertTrue(Plans.allows(feature, tier: .pro)) }
    }

    func testFreeSeesThirtyDays() {
        let now = SupplierAccounts.day("2026-11-14")!
        let entries = ["2026-11-10", "2026-10-20", "2026-09-01"].enumerated().map { i, day in
            HistoryEntry(id: "\(i)", savedAt: day + "T10:00:00Z", supplier: "Apex", net: 1, total: 1, over: 0, lines: [])
        }
        XCTAssertEqual(Plans.visible(entries, tier: .free, now: now).map { $0.id }, ["0", "1"])
        XCTAssertEqual(Plans.hidden(entries, tier: .free, now: now), 1)
        XCTAssertEqual(Plans.visible(entries, tier: .packs, now: now).count, 3)
    }

    func testPackBoughtStaysAfterScansAreUsed() {
        var ledger = ScanLedger(device: "a")
        XCTAssertFalse(ledger.hasBought)
        ledger.addAdReward()
        XCTAssertFalse(ledger.hasBought)
        ledger.creditPack(productID: "ipc_scans_3", transactionID: "t1")
        ledger.use(3)
        XCTAssertEqual(ledger.credits, 1)
        XCTAssertTrue(ledger.hasBought)
        // a backup taken to a new phone carries it, even with no scans left
        ledger.use(1)
        var other = ScanLedger(device: "b")
        other.restore(from: ledger.forBackup)
        XCTAssertTrue(other.hasBought)
        // an old saved ledger without the new field still reads
        let old = #"{"credits":2,"seenTransactions":[],"device":"c"}"#
        let decoded = try? JSONDecoder().decode(ScanLedger.self, from: Data(old.utf8))
        XCTAssertEqual(decoded?.credits, 2)
        XCTAssertEqual(decoded?.hasBought, false)
    }
}
