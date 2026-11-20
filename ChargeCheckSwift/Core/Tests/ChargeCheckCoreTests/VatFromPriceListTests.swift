import XCTest
@testable import ChargeCheckCore

final class VatFromPriceListTests: XCTestCase {
    private let book = PriceBook([
        PriceItem(id: "chicken", name: "Chicken Wings", price: 50, till: TillInfo(vat: 0)),
        PriceItem(id: "cola", name: "Cola 24x330ml", price: 10, till: TillInfo(vat: 20)),
        PriceItem(id: "nuts", name: "Nuts", price: 5)
    ])

    private func lines(_ colaUnit: Double = 10) -> [CheckLine] {
        [CheckLine(qty: 1, desc: "Chicken", unit: 50, matchId: "chicken"),
         CheckLine(qty: 5, desc: "Cola", unit: colaUnit, matchId: "cola")]
    }

    func testRatesThatAddUpToTheInvoicesVatAreFilledIn() {
        // £50 chicken (0%) + £50 cola (20%) = £100, VAT £10: the price list explains it exactly
        let out = InvoiceMaths.vatFromPriceList(lines(), book: book, printedNet: 100, printedTotal: 110)
        XCTAssertEqual(out.map(\.vat), [0, 20])
    }

    func testRatesThatDontAddUpAreNeverUsed() {
        // the invoice says £20 VAT: the price list's rates don't explain it, so nothing is filled in
        let out = InvoiceMaths.vatFromPriceList(lines(), book: book, printedNet: 100, printedTotal: 120)
        XCTAssertEqual(out.map(\.vat), [0, 0])
    }

    func testInvoiceRatesAndMissingTotalsAreLeftAlone() {
        var printed = lines()
        printed[1].vat = 5
        XCTAssertEqual(InvoiceMaths.vatFromPriceList(printed, book: book, printedNet: 100, printedTotal: 110).map(\.vat), [0, 5])
        XCTAssertEqual(InvoiceMaths.vatFromPriceList(lines(), book: book, printedNet: nil, printedTotal: 110).map(\.vat), [0, 0])
        XCTAssertEqual(InvoiceMaths.vatFromPriceList(lines(), book: book, printedNet: 100, printedTotal: 100).map(\.vat), [0, 0])
        // no item has a VAT rate set: nothing to go on
        let plain = [CheckLine(qty: 2, desc: "Nuts", unit: 5, matchId: "nuts")]
        XCTAssertEqual(InvoiceMaths.vatFromPriceList(plain, book: book, printedNet: 10, printedTotal: 12).map(\.vat), [0])
    }

    func testThenTheOverchargeLosesVatOnlyOnTheColas() {
        // cola charged £10.40 a case, agreed £10: £2 over; VAT £10.40 (20% of £52)
        let filled = InvoiceMaths.vatFromPriceList(lines(10.40), book: book, printedNet: 102, printedTotal: 112.40)
        XCTAssertEqual(filled.map(\.vat), [0, 20])
        let cola = InvoiceMaths.lineResult(filled[1], supplier: "", book: book)
        XCTAssertEqual(cola.over, 2)
        XCTAssertEqual(cola.overVat, 0.4)
        let entry = HistoryEntry(supplier: "Apex", net: 102, total: 112.4, over: 2, overVat: 0.4,
                                 lines: filled.map { HistoryLine(qty: $0.qty, desc: $0.desc, unit: $0.unit, vat: $0.vat) })
        XCTAssertEqual(entry.payment.pay, 110)
        XCTAssertEqual(entry.payment.payNet, 100)
        XCTAssertEqual(entry.payment.payVat, 10)
    }
}
