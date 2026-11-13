import XCTest
@testable import ChargeCheckCore

/// Invoice number and date when the usual labels aren't read (13 Nov 2026: Ramyar's Iraqi invoice showed neither).
final class InvoiceDetailsTests: XCTestCase {
    override func tearDown() {
        InvoiceParser.language = "en"
        super.tearDown()
    }

    /// The phone set to English doesn't read the Arabic labels "رقم الفاتورة:" and "التاريخ:" – only the numbers.
    func testArabicHeaderWithLabelsNotRead() {
        let text = """
        Dilsagh Company
        Rahmkar Dr Kawan   2026 - 57
        2026-11-10
        09:51
        BF02028B   2029-02-01   687.5   2.75   0   250   STELLA- HAIR GROW SHAMPOO   1
        """
        let invoice = InvoiceParser.parseInvoice(text)
        XCTAssertEqual(invoice.invNo, "57")
        XCTAssertEqual(invoice.date, "2026-11-10")
    }

    func testArabicLabelsRead() {
        let text = "2026 - 57   رقم الفاتورة:\n2026-11-10   التاريخ:\n09:51"
        XCTAssertEqual(InvoiceParser.parseInvoice(text).invNo, "57")
        XCTAssertEqual(InvoiceParser.parseInvoice(text).date, "2026-11-10")
    }

    func testOtherWordings() {
        XCTAssertEqual(InvoiceDetails.invoiceNumber(in: "Tax Invoice\nInvoice #: INV-2041\nDate: 3 Nov 2026"), "INV-2041")
        XCTAssertEqual(InvoiceDetails.invoiceDate(in: "Tax Invoice\nInvoice #: INV-2041\nDate: 3 Nov 2026"), "3 Nov 2026")
        XCTAssertEqual(InvoiceDetails.invoiceNumber(in: "Bill No. 7713"), "7713")
        XCTAssertEqual(InvoiceDetails.invoiceDate(in: "Tax point: November 4, 2026"), "November 4, 2026")
    }

    func testHeaderBoxWithValuesUnderneath() {
        let text = "Invoice No   Date   Account\n82044   06/11/2026   A123"
        XCTAssertEqual(InvoiceDetails.invoiceNumber(in: text), "82044")
        XCTAssertEqual(InvoiceDetails.invoiceDate(in: text), "06/11/2026")
    }

    func testDueAndExpiryDatesAreSkipped() {
        let text = "Due date: 30/11/2026\nExpiry 01/02/2029\nPrinted for you   12/11/2026"
        XCTAssertEqual(InvoiceDetails.invoiceDate(in: "Due date: 30/11/2026\n12/11/2026"), "12/11/2026")
        XCTAssertEqual(InvoiceDetails.invoiceDate(in: text), "")
    }

    func testDatesAndPricesAreNotInvoiceNumbers() {
        XCTAssertEqual(InvoiceDetails.numberWithYear(in: ["2026-11-10", "10/11/2026", "12.50"]), "")
        XCTAssertNil(InvoiceDetails.usableNumber("06/11/2026"))
        XCTAssertNil(InvoiceDetails.usableNumber("1,234.56"))
    }

    /// Invoice 82262 (photo slightly tilted): the number's box lands on the row above "Invoice No".
    func testNumberOnTheRowAboveItsLabel() {
        let text = """
        APEX FOOD DISTRIBUTION LTD
        INVOICE   Page 1   82262
        UK FRIED CHICKEN (KINGS HEATH)   Invoice No
        5   Invoice Date   10/11/2026
        B14 7JJ   Account Ref   UK005
        """
        XCTAssertEqual(InvoiceParser.parseInvoice(text).invNo, "82262")
        XCTAssertEqual(InvoiceParser.parseInvoice(text).date, "10/11/2026")
    }

    func testPostcodeIsNotTheInvoiceNumber() {
        XCTAssertEqual(InvoiceDetails.invoiceNumber(in: "B14 7JJ   Invoice No\nUK   Order No"), "")
    }
}
