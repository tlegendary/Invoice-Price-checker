import XCTest
@testable import ChargeCheckCore

/// Invoice 82300 (13 Nov 2026), photographed on a curled page: the item lines rise towards the right, so with one
/// tilt for the whole page the PANINI line's prices landed on the row above and the line was lost (£147.87, not £170.86).
/// Positions are taken from Ramyar's photo.
final class CurledPageTests: XCTestCase {
    static let raw: [(String, Double, Double, Double, Double, Double)] = [
        ("APEX FOOD DISTRIBUTION LTD", 415, 150, 490, 24, -0.02),
        ("UNIT 06 MOTORWAY TRADING ESTATE , MILL STREET , B6 4BS", 405, 187, 465, 13, -0.02),
        ("INVOICE", 542, 257, 58, 12, 0),
        ("Page 1", 692, 251, 50, 12, 0),
        ("Invoice No", 547, 286, 72, 12, 0),
        ("82300", 690, 281, 40, 12, 0),
        ("UK FRIED CHICKEN (KINGS HEATH)", 200, 305, 210, 12, -0.02),
        ("Invoice Date", 558, 314, 86, 12, 0),
        ("11/11/2026", 708, 309, 70, 12, 0),
        ("5", 100, 327, 8, 12, 0),
        ("ALCASTER ROAD", 146, 339, 100, 12, -0.02),
        ("Order No", 547, 343, 60, 12, 0),
        ("BIRMINGHAM", 136, 355, 80, 12, 0),
        ("Account Ref", 556, 371, 76, 12, 0),
        ("UK005", 697, 364, 38, 12, 0),
        ("UK", 104, 371, 16, 12, 0),
        ("B14 7JJ", 118, 387, 40, 12, 0),
        ("Unit Price", 486, 449, 66, 12, -0.03),
        ("Disc Amt", 567, 444, 60, 12, -0.03),
        ("Net Amt", 651, 440, 56, 12, -0.03),
        ("VAT %", 714, 436, 46, 12, -0.03),
        ("VAT", 786, 432, 28, 12, -0.03),
        ("Quantity", 117, 466, 58, 12, -0.03),
        ("Description", 195, 461, 78, 12, -0.03),
        ("10.00", 128, 488, 32, 12, 0),
        ("AMERICANA A4.5 SEED BURGER BUN 4X12", 285, 480, 262, 12, -0.03),
        ("6.99", 511, 472, 26, 12, 0),
        ("0.00", 586, 468, 28, 12, 0),
        ("69.90", 668, 463, 34, 12, 0),
        ("0.00", 713, 461, 28, 12, 0),
        ("0.00", 792, 456, 28, 12, 0),
        ("3.00", 128, 505, 28, 12, 0),
        ("FRESH 9CUT CHICKEN ( 54)", 240, 500, 176, 12, -0.03),
        ("25.99", 511, 491, 34, 12, 0),
        ("0.00", 588, 487, 28, 12, 0),
        ("77.97", 668, 480, 34, 12, 0),
        ("0.00", 715, 479, 28, 12, 0),
        ("0.00", 796, 474, 28, 12, 0),
        ("1.00", 128, 522, 28, 12, 0),
        ("PANINI SESAME NIGELLA 130g", 246, 518, 190, 12, -0.03),
        ("22.99", 510, 508, 34, 12, 0),
        ("0.00", 590, 505, 28, 12, 0),
        ("22.99", 669, 500, 34, 12, 0),
        ("0.00", 718, 497, 28, 12, 0),
        ("0.00", 798, 492, 28, 12, 0),
        ("Total Discount", 581, 929, 100, 13, 0),
        ("£", 703, 928, 8, 13, 0),
        ("0.00", 803, 926, 28, 13, 0),
        ("Total Net Amount", 593, 959, 124, 13, 0),
        ("£", 703, 958, 8, 13, 0),
        ("170.86", 797, 957, 44, 13, 0),
        ("Carriage Net", 577, 991, 96, 13, 0),
        ("£", 705, 991, 8, 13, 0),
        ("0.00", 807, 991, 28, 13, 0),
        ("Total Tax Amount", 597, 1027, 128, 13, 0),
        ("£", 707, 1026, 8, 13, 0),
        ("0.00", 808, 1025, 28, 13, 0),
        ("Invoice Total", 580, 1062, 92, 13, 0),
        ("£", 710, 1061, 8, 13, 0),
        ("170.86", 804, 1060, 44, 13, 0)
    ]
    let pieces = CurledPageTests.raw.map { TextPiece(text: $0.0, confidence: 1, x: $0.1, y: $0.2, width: $0.3, height: $0.4, angle: $0.5) }

    func testEveryLineKeepsItsOwnPrices() {
        let text = InvoiceParser.followedRows(from: pieces)
        XCTAssertTrue(text.contains("1.00  PANINI SESAME NIGELLA 130g  22.99  0.00  22.99  0.00  0.00"), text)
        XCTAssertTrue(text.contains("3.00  FRESH 9CUT CHICKEN ( 54)  25.99  0.00  77.97  0.00  0.00"), text)
    }

    func testTheInvoiceAddsUp() {
        let invoice = InvoiceParser.parseInvoice(InvoiceParser.bestRows(from: pieces))
        XCTAssertEqual(invoice.lines.count, 3)
        XCTAssertEqual(Money.round2(invoice.lines.reduce(0) { $0 + Money.round2($1.qty * $1.unit) }), 170.86)
        XCTAssertEqual(invoice.printedTotal, 170.86)
        XCTAssertEqual(invoice.invNo, "82300")
        XCTAssertEqual(invoice.date, "11/11/2026")
    }

    func testAPageThatAlreadyAddsUpIsReadAsBefore() {
        let flat = """
        10.00  AMERICANA A4.5 SEED BURGER BUN 4X12  6.99  0.00  69.90  0.00  0.00
        Total Net Amount  £  69.90
        """
        let pieces = flat.components(separatedBy: "\n").enumerated().flatMap { row, line in
            line.components(separatedBy: "  ").enumerated().map { col, word in
                TextPiece(text: word, confidence: 1, x: 100 + Double(col) * 120, y: 100 + Double(row) * 30, width: 60, height: 12, angle: 0)
            }
        }
        XCTAssertEqual(InvoiceParser.bestRows(from: pieces), InvoiceParser.rows(from: pieces))
    }
}
