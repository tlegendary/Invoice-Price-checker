import XCTest
@testable import ChargeCheckCore

// Five real invoices Ramyar sent on 12 Nov 2026, typed out row by row the way the photo reader gives them
// (supplier, shop and invoice numbers changed). They cover what real paper has: handwriting next to a line
// ("Retrn", "missing", a hand-written price before the printed one), a size range in a name ("110-130"),
// a name that starts with a number, inch marks, and VAT on some lines only.

private struct Expect {
    let qty: Double
    let unit: Double
    let vat: Double
    let word: String
}

final class RealInvoiceTests: XCTestCase {

    private func head(_ no: String, _ date: String) -> String {
        """
        NORTHGATE WHOLESALE LTD
        UNIT 1 SAMPLE TRADING ESTATE , MILL STREET
        INVOICE   Page 1
        SAMPLE CHICKEN (HIGH ST)   Invoice No   \(no)
        12   Invoice Date   \(date)
        HIGH STREET   Order No
        BIRMINGHAM   Account Ref   TOP410
        Quantity  Description  Unit Price  Disc Amt  Net Amt  VAT %  VAT

        """
    }

    private func foot(net: String, tax: String, total: String) -> String {
        """

        Total Discount   £   0.00
        Total Net Amount   £   \(net)
        Carriage Net   £   0.00
        Total Tax Amount   £   \(tax)
        Invoice Total   £   \(total)
        """
    }

    private func check(_ name: String, _ text: String, _ expected: [Expect], net: Double, total: Double,
                       file: StaticString = #filePath, line: UInt = #line) {
        let got = InvoiceParser.parseInvoice(text, known: [])
        let shown = got.lines.map { "\($0.qty) | \($0.desc) | \($0.unit) | vat \($0.vat) | \($0.warn)" }.joined(separator: "\n")
        print("REAL-INVOICE \(name): supplier=\(got.supplier) no=\(got.invNo) date=\(got.date) net=\(String(describing: got.printedNet)) total=\(String(describing: got.printedTotal))\n\(shown)")
        XCTAssertEqual(got.lines.count, expected.count, "\(name): number of lines\n\(shown)", file: file, line: line)
        for (index, want) in expected.enumerated() where index < got.lines.count {
            let have = got.lines[index]
            XCTAssertEqual(have.qty, want.qty, accuracy: 0.001, "\(name) line \(index + 1) quantity: \(have.desc)", file: file, line: line)
            XCTAssertEqual(have.unit, want.unit, accuracy: 0.001, "\(name) line \(index + 1) unit price: \(have.desc)", file: file, line: line)
            XCTAssertEqual(have.vat, want.vat, accuracy: 0.001, "\(name) line \(index + 1) VAT: \(have.desc)", file: file, line: line)
            XCTAssertTrue(have.desc.uppercased().contains(want.word), "\(name) line \(index + 1) name: \(have.desc)", file: file, line: line)
        }
        XCTAssertEqual(got.printedNet ?? -1, net, accuracy: 0.001, "\(name): printed net", file: file, line: line)
        XCTAssertEqual(got.printedTotal ?? -1, total, accuracy: 0.001, "\(name): printed total", file: file, line: line)
        XCTAssertEqual(got.supplier, "NORTHGATE WHOLESALE LTD", "\(name): supplier", file: file, line: line)
    }

    func testThirteenLinesWithHandwriting() {
        let rows = """
        1.00  1600GM FRESH HALAL CHICKEN  41.99  0.00  41.99  0.00  0.00
        2.00  FRESH HALAL FILLET 110-130 9KG  50.99  0.00  101.98  0.00  0.00
        3.00  FRESH PRIME WING  15.99  0.00  47.97  0.00  0.00
        2.00  ORIGINAL  BREADING  19.99  0.00  39.98  0.00  0.00
        x  1.00  SUPRANO CHEESE  Retrn  47.99  0.00  47.99  0.00  0.00
        3.00  PALMAX FAT 12.5 KG  21.99  0.00  65.97  0.00  0.00
        3.00  3 CHEFF REAL MAYO 10L  10.99  0.00  32.97  0.00  0.00
        2.00  LION VERY HOT CHILLI SAUCE 2X2.27 L  9.99  0.00  19.98  0.00  0.00
        1.00  KTC VEGETABLE OIL TIN 20 ltrs  27.99  0.00  27.99  0.00  0.00
        x  2.00  QUATER POUNDER 48X4OZ  x missing  24.99  0.00  49.98  0.00  0.00
        1.00  DISCOVERY TORTILLA WRAP 10'  14.99  0.00  14.99  0.00  0.00
        5.00  KETCH UP 2X4.5 LT  6.99  0.00  34.95  0.00  0.00
        1.00  CHICKEN POPCORN 3KG  19.99  0.00  19.99  0.00  0.00
        """
        check("13 lines", head("80001", "02/11/2026") + rows + foot(net: "546.73", tax: "0.00", total: "546.73"), [
            Expect(qty: 1, unit: 41.99, vat: 0, word: "HALAL CHICKEN"),
            Expect(qty: 2, unit: 50.99, vat: 0, word: "FILLET"),
            Expect(qty: 3, unit: 15.99, vat: 0, word: "PRIME WING"),
            Expect(qty: 2, unit: 19.99, vat: 0, word: "BREADING"),
            Expect(qty: 1, unit: 47.99, vat: 0, word: "SUPRANO CHEESE"),
            Expect(qty: 3, unit: 21.99, vat: 0, word: "PALMAX FAT"),
            Expect(qty: 3, unit: 10.99, vat: 0, word: "REAL MAYO"),
            Expect(qty: 2, unit: 9.99, vat: 0, word: "CHILLI SAUCE"),
            Expect(qty: 1, unit: 27.99, vat: 0, word: "VEGETABLE OIL"),
            Expect(qty: 2, unit: 24.99, vat: 0, word: "POUNDER"),
            Expect(qty: 1, unit: 14.99, vat: 0, word: "TORTILLA WRAP"),
            Expect(qty: 5, unit: 6.99, vat: 0, word: "KETCH UP"),
            Expect(qty: 1, unit: 19.99, vat: 0, word: "POPCORN")
        ], net: 546.73, total: 546.73)
    }

    func testTicksAndAScribbleNextToTheName() {
        let rows = """
        /  1.00  FRESH HALAL FILLET 110-130 9KG  11-130  50.99  0.00  50.99  0.00  0.00
        -  1.00  FRESH PRIME WING  15.99  0.00  15.99  0.00  0.00
        1.00  1600GM FRESH HALAL CHICKEN  41.99  0.00  41.99  0.00  0.00
        _  2.00  KTC VEGETABLE OIL TIN 20 ltrs  27.99  0.00  55.98  0.00  0.00
        """
        check("ticks", head("80002", "04/11/2026") + rows + foot(net: "164.95", tax: "0.00", total: "164.95"), [
            Expect(qty: 1, unit: 50.99, vat: 0, word: "FILLET"),
            Expect(qty: 1, unit: 15.99, vat: 0, word: "PRIME WING"),
            Expect(qty: 1, unit: 41.99, vat: 0, word: "HALAL CHICKEN"),
            Expect(qty: 2, unit: 27.99, vat: 0, word: "VEGETABLE OIL")
        ], net: 164.95, total: 164.95)
    }

    func testFiveCleanLines() {
        let rows = """
        3.00  FRESH HALAL FILLET 110-130 9KG  50.99  0.00  152.97  0.00  0.00
        2.00  FRESH PRIME WING  15.99  0.00  31.98  0.00  0.00
        1.00  PANINI SESAME NIGELLA 130g  23.99  0.00  23.99  0.00  0.00
        1.00  LAMBWESTON MOZRELLA STICK  44.99  0.00  44.99  0.00  0.00
        2.00  AMERICANA A4.5 SEED BURGER BUN 4X12  6.99  0.00  13.98  0.00  0.00
        """
        check("clean", head("80003", "06/11/2026") + rows + foot(net: "267.91", tax: "0.00", total: "267.91"), [
            Expect(qty: 3, unit: 50.99, vat: 0, word: "FILLET"),
            Expect(qty: 2, unit: 15.99, vat: 0, word: "PRIME WING"),
            Expect(qty: 1, unit: 23.99, vat: 0, word: "PANINI"),
            Expect(qty: 1, unit: 44.99, vat: 0, word: "MOZRELLA"),
            Expect(qty: 2, unit: 6.99, vat: 0, word: "BURGER BUN")
        ], net: 267.91, total: 267.91)
    }

    func testHandwrittenPricesBeforeThePrintedOnes() {
        let rows = """
        1.00  FRESH PRIME WING  15.99  0.00  15.99  0.00  0.00
        1.00  FRESH HALAL FILLET 110-130 9KG  50.99  0.00  50.99  0.00  0.00
        1.00  MEDUIM INNER FILLET FROZEN  32.-  42.99  0.00  42.99  0.00  0.00
        1.00  PANINI SESAME NIGELLA 130g  22.99  0.00  22.99  0.00  0.00
        1.00  DISCOVERY TORTILLA WRAP 10'  14.99  0.00  14.99  0.00  0.00
        2.00  PRIME REAL MAYONNAISE  10 LTRS  19.99  0.00  39.98  0.00  0.00
        1.00  WIPE UP TISSU  10X500  19 -  23.99  0.00  23.99  20.00  4.80
        3.00  AMERICANA A4.5 SEED BURGER BUN 4X12  7.29  0.00  21.87  0.00  0.00
        2.00  HP10 BURGER BOXES  15.99  0.00  31.98  20.00  6.40
        """
        check("handwritten prices", head("80004", "05/11/2026") + rows + foot(net: "265.77", tax: "11.20", total: "276.97"), [
            Expect(qty: 1, unit: 15.99, vat: 0, word: "PRIME WING"),
            Expect(qty: 1, unit: 50.99, vat: 0, word: "FILLET"),
            Expect(qty: 1, unit: 42.99, vat: 0, word: "INNER FILLET"),
            Expect(qty: 1, unit: 22.99, vat: 0, word: "PANINI"),
            Expect(qty: 1, unit: 14.99, vat: 0, word: "TORTILLA WRAP"),
            Expect(qty: 2, unit: 19.99, vat: 0, word: "MAYONNAISE"),
            Expect(qty: 1, unit: 23.99, vat: 20, word: "TISSU"),
            Expect(qty: 3, unit: 7.29, vat: 0, word: "BURGER BUN"),
            Expect(qty: 2, unit: 15.99, vat: 20, word: "BURGER BOXES")
        ], net: 265.77, total: 276.97)
    }

    func testVatOnSomeLinesAndInchMarks() {
        let rows = """
        6.00  FRESH PRIME WING  15.00  0.00  90.00  0.00  0.00
        5.00  FRESH HALAL FILLET 110-130 9KG  49.99  0.00  249.95  0.00  0.00
        2.00  1600GM FRESH HALAL CHICKEN  41.99  0.00  83.98  0.00  0.00
        2.00  MEDUIM INNER FILLET  42.99  0.00  85.98  0.00  0.00
        2.00  HP10 BURGER BOXES  15.00  0.00  30.00  20.00  6.00
        3.00  3 CHEFF REAL MAYO 10L  10.99  0.00  32.97  0.00  0.00
        1.00  16" COLOUR PIZZA BOXES 100  16.99  0.00  16.99  20.00  3.40
        1.00  BRAVO PIZZA FLOUR 16 Kg  13.99  0.00  13.99  0.00  0.00
        4.00  ORIGINAL  BREADING  17.99  0.00  71.96  0.00  0.00
        """
        check("some VAT", head("80005", "08/11/2026") + rows + foot(net: "675.82", tax: "9.40", total: "685.22"), [
            Expect(qty: 6, unit: 15.00, vat: 0, word: "PRIME WING"),
            Expect(qty: 5, unit: 49.99, vat: 0, word: "FILLET"),
            Expect(qty: 2, unit: 41.99, vat: 0, word: "HALAL CHICKEN"),
            Expect(qty: 2, unit: 42.99, vat: 0, word: "INNER FILLET"),
            Expect(qty: 2, unit: 15.00, vat: 20, word: "BURGER BOXES"),
            Expect(qty: 3, unit: 10.99, vat: 0, word: "REAL MAYO"),
            Expect(qty: 1, unit: 16.99, vat: 20, word: "PIZZA BOXES"),
            Expect(qty: 1, unit: 13.99, vat: 0, word: "PIZZA FLOUR"),
            Expect(qty: 4, unit: 17.99, vat: 0, word: "BREADING")
        ], net: 675.82, total: 685.22)
    }
}
