import XCTest
@testable import ChargeCheckCore

final class FileCheckTests: XCTestCase {
    private func sale(_ id: String) -> Sale {
        Sale(id: id, number: 1, shop: "s", at: "2026-11-23T10:00:00Z", lines: [SaleLine(name: "x", qty: 1, price: 2)], payment: .cash)
    }
    private func data(_ sales: [Sale]) -> Data { try! JSONEncoder().encode(sales) }

    func testAGrowingFileIsTakenIn() {
        XCTAssertEqual(FileCheck.sales(new: data([sale("a"), sale("b")]), old: data([sale("a")])), .ok)
        XCTAssertEqual(FileCheck.sales(new: data([sale("a")]), old: nil), .ok)
    }

    func testAHalfDownloadedOrDamagedFileIsRefused() {
        let full = data([sale("a"), sale("b")])
        XCTAssertEqual(FileCheck.sales(new: full.prefix(full.count / 2), old: full), .damaged)
        XCTAssertEqual(FileCheck.sales(new: Data(), old: full), .damaged)
        XCTAssertEqual(FileCheck.json(Data("{\"a\":".utf8)), .damaged)
        XCTAssertEqual(FileCheck.json(Data("{\"a\":1}".utf8)), .ok)
    }

    func testAFileMissingSalesWeHadIsRefused() {
        XCTAssertEqual(FileCheck.sales(new: data([sale("a")]), old: data([sale("a"), sale("b"), sale("c")])), .shrank(missing: 2))
        XCTAssertEqual(FileCheck.sales(new: data([]), old: data([sale("a")])), .shrank(missing: 1))
    }
}
