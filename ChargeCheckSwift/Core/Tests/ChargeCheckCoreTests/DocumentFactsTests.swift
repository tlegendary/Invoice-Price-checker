import XCTest
@testable import ChargeCheckCore

/// Real papers that aren't plain invoices, currencies, discounts and dates that aren't the invoice date.
final class DocumentFactsTests: XCTestCase {
    override func tearDown() {
        Money.currency = .gbp
        super.tearDown()
    }

    func testKinds() {
        XCTAssertEqual(DocumentFacts.kind("APEX FOOD DISTRIBUTION LTD\nINVOICE   Page 1\nInvoice No   82300\nOrder No"), .invoice)
        XCTAssertEqual(DocumentFacts.kind("APEX FOOD DISTRIBUTION LTD\nDELIVERY NOTE\nDelivery No 5512"), .deliveryNote)
        XCTAssertEqual(DocumentFacts.kind("Bravo Meats\nQUOTATION\nValid for 30 days"), .quote)
        XCTAssertEqual(DocumentFacts.kind("Bravo Meats\nStatement of Account\nBalance 1,234.00"), .statement)
        XCTAssertEqual(DocumentFacts.kind("Bravo Meats\nCREDIT NOTE\nCredit No 12"), .creditNote)
        // "estimated delivery" on a real invoice doesn't make it a quote
        XCTAssertEqual(DocumentFacts.kind("Tax Invoice\nEstimate delivery Tuesday"), .invoice)
    }

    func testCurrency() {
        XCTAssertEqual(DocumentFacts.currency("Total Net Amount   £   170.86\nInvoice Total   £   170.86"), "GBP")
        XCTAssertEqual(DocumentFacts.currency("Summe 12,50 €\nGesamtbetrag 13,38 €"), "EUR")
        XCTAssertEqual(DocumentFacts.currency("العملة: دولار   Rahmkar Dr Kawan"), "USD")
        XCTAssertEqual(DocumentFacts.currency("المبلغ 250,000 دينار"), "IQD")
        XCTAssertNil(DocumentFacts.currency("European Foods Ltd\nInvoice Total 12.00"))
        XCTAssertNil(DocumentFacts.currency("Invoice Total 12.00"))
    }

    func testDiscountColumn() {
        // Quantity  Description  Unit Price  Disc Amt  Net Amt  VAT %  VAT
        let line = InvoiceParser.parseLine("2.00  FISH BURGER 100gm 30pcs  24.99  5.00  44.98  0.00  0.00")
        XCTAssertEqual(line?.qty, 2)
        XCTAssertEqual(Money.round2((line?.qty ?? 0) * (line?.unit ?? 0)), 44.98)
        XCTAssertTrue(line?.warn.contains("Discount") ?? false)
        // no discount: read exactly as before
        let plain = InvoiceParser.parseLine("2.00  FISH BURGER 100gm 30pcs  24.99  0.00  49.98  0.00  0.00")
        XCTAssertEqual(plain?.unit, 24.99)
        XCTAssertEqual(plain?.warn, "")
    }

    func testDiscountInPercent() {
        let line = InvoiceParser.parseLine("4.00  FRESH HALAL FILLET 110-130 9KG  50.00  10.00  180.00  0.00  0.00")
        XCTAssertEqual(line?.qty, 4)
        XCTAssertEqual(line?.unit, 45)
    }

    func testExpiryDateIsNotTheInvoiceDate() {
        XCTAssertEqual(InvoiceDetails.invoiceDate(in: "BF02028B   2029-02-01   687.5\n2026-11-10"), "2026-11-10")
    }
}
