import XCTest
@testable import ChargeCheckCore

/// Ramyar's test invoice (13 Nov 2026): an Iraqi wholesaler, Arabic headings, English item names, US dollars,
/// columns right to left: no., item, quantity, gifts, price, total, expiry, batch, note.
final class AnyLayoutTests: XCTestCase {
    override func tearDown() {
        InvoiceParser.language = "en"
        Money.currency = .gbp
        super.tearDown()
    }

    /// How the phone reads it left to right (the app set to English).
    let leftToRight = """
    Dilsagh Company   شركة دل ساغ
    General trading, Medicine &   للتجارة العامة و الادوية و
    WHOL SALE STELLA
    العملة: دولار   Rahmkar Dr Kawan   اسم العميل:   2026 - 57   رقم الفاتورة:
    2026-11-10   التاريخ:
    ملاحظة   رقم الدفعة   تاريخ الانتهاء   الاحمالي   السعر   الهدايا   الكمية   اسم المادة   م
    BF02028B   2029-02-01   687.5   2.75   0   250   STELLA- HAIR GROW SHAMPOO   1
    BE11198A   2028-11-18   403.09   2.33   0   173   STELLA-SUN SCREEN OILY   2
    BE11188C   2028-11-17   403.09   2.33   0   173   STELLA-SUNSCREEN -DRY   3
    BE08128D   2028-08-11   315   3.15   0   100   Skin Toner_Stella   4
    28,718.9   الرصيد السابق:   1,808.68   صافي الفاتورة:   1,808.68   احمالي الفاتورة:
    30,527.58   الرصيد الحالي:   0.00   %
    السائق : كاك دانا   07502295589
    """

    /// The same invoice read right to left (the app set to Arabic or Kurdish).
    var rightToLeft: String {
        leftToRight.split(separator: "\n").map { line in
            line.components(separatedBy: "   ").reversed().joined(separator: "   ")
        }.joined(separator: "\n")
    }

    private func check(_ invoice: ParsedInvoice, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(invoice.lines.count, 4, file: file, line: line)
        XCTAssertEqual(invoice.lines.map { $0.qty }, [250, 173, 173, 100], file: file, line: line)
        XCTAssertEqual(invoice.lines.map { $0.unit }, [2.75, 2.33, 2.33, 3.15], file: file, line: line)
        XCTAssertTrue(invoice.lines.first?.desc.uppercased().contains("HAIR GROW SHAMPOO") ?? false, file: file, line: line)
        XCTAssertEqual(invoice.lines.last?.desc.lowercased().contains("toner"), true, file: file, line: line)
        // the lines add up to the printed total, so the invoice checks out
        let net = invoice.lines.reduce(0) { $0 + Money.round2($1.qty * $1.unit) }
        XCTAssertEqual(Money.round2(net), 1808.68, file: file, line: line)
        XCTAssertEqual(invoice.printedTotal, 1808.68, file: file, line: line)
        XCTAssertEqual(invoice.date, "2026-11-10", file: file, line: line)
    }

    func testReadInEnglishWhateverTheCurrency() {
        for currency in Currency.all {
            Money.currency = currency
            check(InvoiceParser.parseInvoice(leftToRight))
        }
    }

    func testReadInArabicAndKurdish() {
        for language in ["ar", "ckb"] {
            InvoiceParser.language = language
            for currency in Currency.all {
                Money.currency = currency
                check(InvoiceParser.parseInvoice(rightToLeft))
            }
        }
    }

    func testTheBalanceIsNeverTakenAsTheTotal() {
        let invoice = InvoiceParser.parseInvoice(leftToRight)
        XCTAssertNotEqual(invoice.printedTotal, 28718.9)
        XCTAssertNotEqual(invoice.printedTotal, 30527.58)
        XCTAssertEqual(invoice.invNo, "2026-57")
        XCTAssertTrue(invoice.supplier.contains("Dilsagh"))
    }

    func testRowsWithoutQuantityTimesPriceAreNotItems() {
        XCTAssertNil(InvoiceParser.parseTableRow("28,718.9   الرصيد السابق:   1,808.68   صافي الفاتورة:"))
        XCTAssertNil(InvoiceParser.parseTableRow("السائق : كاك دانا   07502295589"))
        XCTAssertNil(InvoiceParser.parseTableRow("2026-11-10   التاريخ:   09:51"))
    }

    func testAmountsInAnyCurrencySetting() {
        Money.currency = .iqd
        XCTAssertEqual(Money.parse("1,808.68"), 1808.68)
        XCTAssertEqual(Money.parse("25,000"), 25000)
        XCTAssertEqual(InvoiceParser.cellNumber("687.5"), 687.5)
        XCTAssertEqual(InvoiceParser.cellNumber("1,234"), 1234)
        XCTAssertNil(InvoiceParser.cellNumber("BF02028B"))
        XCTAssertNil(InvoiceParser.cellNumber("07502295589"))
    }
}
