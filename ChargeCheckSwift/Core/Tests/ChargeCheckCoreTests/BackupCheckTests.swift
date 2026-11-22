import XCTest
@testable import ChargeCheckCore

final class BackupCheckTests: XCTestCase {
    private func backup(items: [PriceItem] = [PriceItem(id: "a", name: "Wings", price: 15.99)],
                        invoices: [HistoryEntry] = []) -> BackupFile {
        BackupFile(baseline: items, history: invoices)
    }

    func testAGoodBackupPasses() {
        let invoice = HistoryEntry(supplier: "Apex", net: 100, total: 120, over: 0, lines: [])
        XCTAssertEqual(BackupCheck.problems(backup(invoices: [invoice])), [])
    }

    func testAnEmptyBackupWouldOnlyWipeTheDevice() {
        XCTAssertEqual(BackupCheck.problems(backup(items: [])), [.empty])
    }

    func testANewerFormatIsRefused() {
        var b = backup()
        b.v = 4
        XCTAssertEqual(BackupCheck.problems(b), [.newerVersion(4)])
    }

    func testMoneyThatIsntANumberIsRefused() {
        let broken = HistoryEntry(supplier: "Apex", net: .nan, total: 120, over: 0, lines: [])
        let problems = BackupCheck.problems(backup(items: [PriceItem(id: "a", name: "x", price: .infinity)], invoices: [broken]))
        XCTAssertEqual(problems, [.badMoney(2)])
        XCTAssertTrue(problems.allSatisfy(\.blocks))
    }

    func testItemsWithoutAnIDAreRefused() {
        XCTAssertEqual(BackupCheck.problems(backup(items: [PriceItem(id: " ", name: "x", price: 1)])), [.missingIDs(1)])
    }
}
