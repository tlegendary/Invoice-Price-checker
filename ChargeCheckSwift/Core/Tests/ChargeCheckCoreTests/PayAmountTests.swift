import XCTest
@testable import ChargeCheckCore

/// Invoice 82300 (13 Nov 2026): three lines, £170.86, but "Choose invoices to pay" showed £147.87 –
/// the PANINI line was missing and the invoice was saved with what the remaining lines added up to.
final class PayAmountTests: XCTestCase {
    private func lines(_ withPanini: Bool) -> [CheckLine] {
        var out = [CheckLine(qty: 10, desc: "AMERICANA A4.5 SEED BURGER BUN 4X12", unit: 6.99),
                   CheckLine(qty: 3, desc: "FRESH 9CUT CHICKEN (54)", unit: 25.99)]
        if withPanini { out.append(CheckLine(qty: 1, desc: "PANINI SESAME NIGELLA 130g", unit: 22.99)) }
        return out
    }

    func testAMissedLineIsNoticedFromTheInvoiceTotalAlone() {
        var draft = InvoiceDraft(supplier: "APEX FOOD DISTRIBUTION LTD", invNo: "82300")
        draft.lines = lines(false)
        draft.printedTotal = 170.86
        let totals = InvoiceMaths.totals(draft, book: PriceBook([]))
        XCTAssertTrue(totals.totalKnown)
        XCTAssertFalse(totals.totalOk)
        XCTAssertFalse(totals.verified)    // not saved on its own: the user is asked to look
        draft.lines = lines(true)
        XCTAssertTrue(InvoiceMaths.totals(draft, book: PriceBook([])).totalOk)
    }

    func testThePrintedTotalIsWhatIsInvoiced() {
        var draft = InvoiceDraft(supplier: "APEX FOOD DISTRIBUTION LTD", invNo: "82300", printedNet: 170.86, printedTotal: 170.86)
        draft.lines = lines(false)
        let entry = InvoiceMaths.historyEntry(draft, book: PriceBook([]))
        XCTAssertEqual(entry.total, 170.86)
        XCTAssertEqual(entry.amountToPay.total, 170.86)
        XCTAssertEqual(entry.amountToPay.pay, 170.86)
    }

    func testAMisreadTotalIsNotUsed() {
        // 17086 read for 170.86: the total doesn't fit the net, so the lines' own total is kept
        var draft = InvoiceDraft(supplier: "APEX", invNo: "82300", printedNet: 170.86, printedTotal: 17086)
        draft.lines = lines(true)
        XCTAssertEqual(InvoiceMaths.historyEntry(draft, book: PriceBook([])).total, 170.86)
    }
}
