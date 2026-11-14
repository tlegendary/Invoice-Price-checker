import XCTest
@testable import ChargeCheckCore

/// STANDARDS.md §6: never create an overcharge from an uncertain product match.
final class UnsureMatchTests: XCTestCase {
    private let oil = PriceItem(id: "o", name: "Vegetable oil 20L", price: 30)
    private let salt = PriceItem(id: "s", name: "Salt 1kg", price: 1)

    func testUnsureMatchIsNotCountedUntilConfirmed() {
        let book = PriceBook([oil, salt])
        var draft = InvoiceDraft(supplier: "Apex", lines: [
            CheckLine(qty: 2, desc: "COOKING OIL DRUM", unit: 35, vat: 20, matchId: "o", confident: false),
            CheckLine(qty: 3, desc: "SALT 1KG", unit: 1.5, matchId: "s", confident: true)
        ])
        var t = InvoiceMaths.totals(draft, book: book)
        // only the sure line counts: 3 × 0.50
        XCTAssertEqual(t.over, 1.5)
        XCTAssertEqual(t.overVat, 0)
        // the unsure one is shown as possible, not claimed
        XCTAssertEqual(t.pendingOver, 10)
        XCTAssertEqual(t.pendingLines, 1)
        let unsure = InvoiceMaths.lineResult(draft.lines[0], supplier: "Apex", book: book)
        XCTAssertEqual(unsure.over, 0)
        XCTAssertEqual(unsure.pendingOver, 10)
        XCTAssertTrue(InvoiceMaths.reasons(draft.lines[0], supplier: "Apex", book: book, totalOk: true)
            .contains { $0.contains("Confirm the match") })
        // saved before confirming: nothing is taken off what you pay
        var saved = InvoiceMaths.historyEntry(draft, book: book)
        XCTAssertEqual(saved.over, 1.5)
        XCTAssertEqual(saved.lines[0].over, 0)

        // confirmed by the user: now it counts, with its VAT
        draft.lines[0].ok = true
        t = InvoiceMaths.totals(draft, book: book)
        XCTAssertEqual(t.over, 11.5)
        XCTAssertEqual(t.overVat, 2)
        XCTAssertEqual(t.pendingOver, 0)
        saved = InvoiceMaths.historyEntry(draft, book: book)
        XCTAssertEqual(saved.lines[0].over, 10)
    }

    func testSureAndUnknownMatchesUnchanged() {
        let book = PriceBook([oil])
        // a sure match counts as before; a line without a confidence value (typed in by hand) counts too
        for confident in [true, nil] as [Bool?] {
            let draft = InvoiceDraft(supplier: "Apex", lines: [CheckLine(qty: 1, desc: "OIL", unit: 32, matchId: "o", confident: confident)])
            XCTAssertEqual(InvoiceMaths.totals(draft, book: book).over, 2)
        }
        // an unsure line that is cheaper is simply cheaper: nothing pending
        let cheaper = InvoiceDraft(supplier: "Apex", lines: [CheckLine(qty: 1, desc: "OIL", unit: 28, matchId: "o", confident: false)])
        XCTAssertEqual(InvoiceMaths.totals(cheaper, book: book).pendingOver, 0)
        // a missing (excluded) line is never pending
        let missing = InvoiceDraft(supplier: "Apex", lines: [CheckLine(qty: 1, desc: "OIL", unit: 40, excluded: true, matchId: "o", confident: false)])
        XCTAssertEqual(InvoiceMaths.totals(missing, book: book).pendingOver, 0)
    }
}
