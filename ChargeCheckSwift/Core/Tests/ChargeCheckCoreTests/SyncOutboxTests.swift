import XCTest
@testable import ChargeCheckCore

final class SyncOutboxTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testItWaitsLongerAfterEachFailureButNeverMoreThanAnHour() {
        var box = SyncOutbox()
        box.failed(folder: "Till", name: "Sales 2026-11 ~A.json", at: t0)
        XCTAssertEqual(box.due(at: t0.addingTimeInterval(29)).count, 0)
        XCTAssertEqual(box.due(at: t0.addingTimeInterval(30)).count, 1)
        box.failed(folder: "Till", name: "Sales 2026-11 ~A.json", at: t0)
        XCTAssertEqual(box.items.values.first?.nextTry, t0.addingTimeInterval(60))
        for _ in 0..<20 { box.failed(folder: "Till", name: "Sales 2026-11 ~A.json", at: t0) }
        XCTAssertEqual(box.items.values.first?.nextTry, t0.addingTimeInterval(SyncOutbox.longestWait))
        XCTAssertEqual(box.items.count, 1, "the same file is one entry")
    }

    func testOfflineThenBackOnline() {
        // three sales while offline: the same month file fails three times, then goes once
        var box = SyncOutbox()
        for i in 0..<3 { box.failed(folder: "Till", name: "Sales 2026-11 ~A.json", at: t0.addingTimeInterval(Double(i))) }
        box.failed(folder: "Till", name: "Settings.json", at: t0.addingTimeInterval(5))
        let due = box.due(at: t0.addingTimeInterval(10_000))
        XCTAssertEqual(due.map(\.name), ["Sales 2026-11 ~A.json", "Settings.json"], "the longest waiting first")
        box.sent(folder: "Till", name: "Sales 2026-11 ~A.json")
        box.sent(folder: "Till", name: "Settings.json")
        XCTAssertTrue(box.isEmpty)
    }

    func testItSurvivesAnAppRestart() throws {
        var box = SyncOutbox()
        box.failed(folder: "Till", name: "Cash ~A.json", at: t0)
        let back = try JSONDecoder().decode(SyncOutbox.self, from: JSONEncoder().encode(box))
        XCTAssertEqual(back, box)
        XCTAssertEqual(back.oldest(), t0)
    }
}
