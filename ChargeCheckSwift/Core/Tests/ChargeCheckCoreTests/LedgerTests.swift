import XCTest
@testable import ChargeCheckCore

final class LedgerTests: XCTestCase {
    func testProductsMatchAppStoreConnect() {
        XCTAssertEqual(Products.yearly, "ipc_yearly")
        XCTAssertEqual(Products.monthly, "ipc_monthlyy")      // two y's: that is the real product ID
        XCTAssertEqual(Products.packs, ["ipc_scans_3": 3, "ipc_scans_10": 10, "ipc_scans_30": 30])
        XCTAssertEqual(Products.yearlySaving(yearly: 89.99, monthly: 8.99), 17)
        XCTAssertEqual(Products.yearlySaving(yearly: 0, monthly: 8.99), 0)
        XCTAssertEqual(Products.yearlySaving(yearly: 200, monthly: 8.99), 0)
    }

    func testAPackIsOnlyCountedOnce() {
        var ledger = ScanLedger(device: "a")
        XCTAssertEqual(ledger.creditPack(productID: "ipc_scans_10", transactionID: "t1"), 10)
        XCTAssertEqual(ledger.creditPack(productID: "ipc_scans_10", transactionID: "t1"), 0)
        XCTAssertEqual(ledger.creditPack(productID: "ipc_scans_3", transactionID: "t2"), 3)
        XCTAssertEqual(ledger.creditPack(productID: "ipc_yearly", transactionID: "t3"), 0)
        XCTAssertEqual(ledger.creditPack(productID: "something_else", transactionID: "t4"), 0)
        XCTAssertEqual(ledger.credits, 13)
    }

    func testUsingScans() {
        var ledger = ScanLedger(device: "a", credits: 2)
        XCTAssertEqual(ledger.use(1), 1)
        XCTAssertEqual(ledger.use(5), 1)        // only one left
        XCTAssertEqual(ledger.use(1), 0)        // none left: no scan
        XCTAssertEqual(ledger.credits, 0)
        ledger.addAdReward()
        XCTAssertEqual(ledger.credits, 1)
        ledger.refund()
        XCTAssertEqual(ledger.credits, 2)
        XCTAssertEqual(ledger.use(-3), 0)
        XCTAssertEqual(ledger.credits, 2)
    }

    func testRestoringABackupCannotBringBackUsedScans() {
        var ledger = ScanLedger(device: "thisphone", credits: 2)
        XCTAssertEqual(ledger.restore(from: ScanCredits(n: 30, dev: "thisphone")), 0)   // same phone: ignored
        XCTAssertEqual(ledger.credits, 2)
        XCTAssertEqual(ledger.restore(from: ScanCredits(n: 30, dev: "oldphone")), 28)    // moved from another phone
        XCTAssertEqual(ledger.credits, 30)
        XCTAssertEqual(ledger.restore(from: ScanCredits(n: 5, dev: "oldphone")), 0)      // never lowers
        XCTAssertEqual(ledger.restore(from: nil), 0)
        XCTAssertEqual(ledger.forBackup, ScanCredits(n: 30, dev: "thisphone"))
    }

    func testSavedAndLoaded() throws {
        var ledger = ScanLedger(device: "a")
        ledger.creditPack(productID: "ipc_scans_3", transactionID: "t1")
        let again = try JSONDecoder().decode(ScanLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(again, ledger)
        var copy = again
        XCTAssertEqual(copy.creditPack(productID: "ipc_scans_3", transactionID: "t1"), 0)
    }
}
