import XCTest
@testable import ChargeCheckCore

final class AccountingExportTests: XCTestCase {
    private func entry(_ supplier: String, no: String, date: String, net: Double, total: Double, over: Double = 0) -> HistoryEntry {
        HistoryEntry(supplier: supplier, invNo: no, date: date, net: net, total: total, over: over, lines: [], currency: "GBP")
    }

    func testXeroBillAsTheSupplierIssuedIt() {
        let csv = AccountingExport.xeroBills([entry("APEX FOOD, LTD", no: "82044", date: "06/11/2026", net: 100, total: 112.40, over: 4.5)],
                                             creditDays: { _ in 30 })
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "*ContactName,*InvoiceNumber,*InvoiceDate,*DueDate,Description,*Quantity,*UnitAmount,*AccountCode,*TaxType,TaxAmount,Currency")
        XCTAssertTrue(lines[1].hasPrefix("\"APEX FOOD, LTD\",82044,06/11/2026,06/12/2026,"), lines[1])
        XCTAssertTrue(lines[1].contains(",1,100.00,310,20% (VAT on Expenses),12.40,GBP"), lines[1])
        XCTAssertTrue(lines[1].contains("4.50"), "the overcharge is noted")
    }

    func testNoVatAndNoNumberAndDuplicatesLeftOut() {
        var twice = entry("APEX", no: "1", date: "06/11/2026", net: 10, total: 10)
        twice.duplicateOf = "x"
        let csv = AccountingExport.xeroBills([entry("APEX", no: "", date: "06/11/2026", net: 50, total: 50), twice], creditDays: { _ in 0 })
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains(",CC-"), lines[1])
        XCTAssertTrue(lines[1].contains("06/11/2026,06/11/2026"), "pay on delivery: due the same day")
        XCTAssertTrue(lines[1].contains(",No VAT,0.00,"), lines[1])
    }

    func testQuickBooks() {
        let csv = AccountingExport.quickBooksBills([entry("Brakes", no: "B7", date: "01/11/2026", net: 20, total: 24)], creditDays: { _ in 14 })
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertTrue(lines[0].hasPrefix("Bill No,Supplier,Bill Date,Due Date"))
        XCTAssertEqual(lines[1], "B7,Brakes,01/11/2026,15/11/2026,310,Invoice B7,20.00,20.0% S,4.00,GBP")
    }
}
