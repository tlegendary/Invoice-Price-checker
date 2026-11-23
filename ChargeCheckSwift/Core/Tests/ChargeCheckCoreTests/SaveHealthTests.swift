import XCTest
@testable import ChargeCheckCore

final class SaveHealthTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAFailureStaysUntilTheSameThingSaves() {
        var h = SaveHealth()
        XCTAssertTrue(h.isHealthy)
        h.failed(.phone, "Till sales", reason: "disk full", at: t0)
        h.saved(.phone, "Orders")
        XCTAssertFalse(h.isHealthy, "something else saving doesn't clear it")
        h.saved(.icloud, "Till sales")
        XCTAssertFalse(h.isHealthy, "the same thing in another place doesn't clear it")
        h.saved(.phone, "Till sales")
        XCTAssertTrue(h.isHealthy)
    }

    func testRepeatsAreCountedNotListedTwice() {
        var h = SaveHealth()
        h.failed(.database, "Invoices", reason: "a", at: t0)
        h.failed(.database, "Invoices", reason: "b", at: t0.addingTimeInterval(5))
        XCTAssertEqual(h.failures.count, 1)
        XCTAssertEqual(h.failures[0].count, 2)
        XCTAssertEqual(h.failures[0].reason, "b")
    }

    func testTheWorstComesFirst() {
        var h = SaveHealth()
        h.failed(.icloud, "Till sales", reason: "offline", at: t0.addingTimeInterval(9))
        h.failed(.phone, "Settings", reason: "x", at: t0.addingTimeInterval(5))
        XCTAssertEqual(h.worst?.area, .phone)
        h.failed(.database, "Invoices", reason: "x", at: t0)
        XCTAssertEqual(h.worst?.area, .database, "money records matter most")
    }

    func testTheListStaysSmall() {
        var h = SaveHealth()
        for i in 0..<(SaveHealth.limit + 5) { h.failed(.phone, "File \(i)", reason: "x", at: t0) }
        XCTAssertEqual(h.failures.count, SaveHealth.limit)
        XCTAssertEqual(h.failures.first?.what, "File 5", "the oldest go first")
    }
}
