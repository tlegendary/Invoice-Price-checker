import XCTest
@testable import ChargeCheckCore

/// Faults seen on a real invoice in the first beta (10 Nov 2026).
final class SecondReadTests: XCTestCase {
    func testInventedLettersAreNotChosenOrKept() {
        XCTAssertEqual(InvoiceParser.consensusDescription("16\" COLOUR PIZZA BOXES", "16Ą!¡COLOUR PIZZA BOXES"), "16\" COLOUR PIZZA BOXES")
        XCTAssertEqual(InvoiceParser.consensusDescription("16Ą!¡COLOUR PIZZA BOXES", "16 COLOUR PIZZA BOXES"), "16 COLOUR PIZZA BOXES")
        let cleaned = InvoiceParser.cleanDescription("16Ą!¡COLOUR PIZZA BOXES", known: [])
        XCTAssertEqual(cleaned, "16 COLOUR PIZZA BOXES")
        XCTAssertFalse(InvoiceParser.looksGarbled("BRAVO PIZZA FLOUR 16 Kg"))
        XCTAssertFalse(InvoiceParser.looksGarbled("CHICKEN WINGS 10KG!"))
        XCTAssertEqual(InvoiceParser.cleanDescription("WHITE PIZZA BOXES 1.00", known: []), "WHITE PIZZA BOXES")
    }

    func testSameLineReadTwiceIsNotAdded() {
        let first = ParsedInvoice(lines: [
            ParsedLine(qty: 1, desc: "BRAVO PIZZA FLOUR 16 Kg", unit: 13.99),
            ParsedLine(qty: 1, desc: "16 COLOUR PIZZA BOXES", unit: 16.99),
            ParsedLine(qty: 4, desc: "ORIGINAL BREADING", unit: 17.99)
        ])
        let second = ParsedInvoice(lines: [
            ParsedLine(qty: 1, desc: "BRAVO PIZZA FLOUR 16 Kg", unit: 13.99),
            ParsedLine(qty: 1, desc: "16 COLOUR PIZZA BOXES", unit: 16.99),
            ParsedLine(qty: 4, desc: "ORIGINAL BREADING", unit: 17.99),
            ParsedLine(qty: 1, desc: "VZNFIOUR16KO", unit: 13.99),
            ParsedLine(qty: 1, desc: "UĄITEŽZABOXES", unit: 16.99)
        ])
        let merged = InvoiceParser.mergeReads(first, second)
        XCTAssertEqual(merged.lines.count, 3)
        XCTAssertFalse(merged.lines.contains { $0.onlySecondRead })
    }

    func testMissingLineIsKeptWhenTheTotalNeedsIt() {
        let first = ParsedInvoice(printedNet: 47.97, lines: [
            ParsedLine(qty: 1, desc: "16 COLOUR PIZZA BOXES", unit: 16.99),
            ParsedLine(qty: 1, desc: "BRAVO PIZZA FLOUR 16 Kg", unit: 13.99)
        ])
        let second = ParsedInvoice(printedNet: 47.97, lines: [
            ParsedLine(qty: 1, desc: "16 COLOUR PIZZA BOXES", unit: 16.99),
            ParsedLine(qty: 1, desc: "BRAVO PIZZA FLOUR 16 Kg", unit: 13.99),
            ParsedLine(qty: 1, desc: "WHĮTE PIZZA BOXES", unit: 16.99)
        ])
        let merged = InvoiceParser.mergeReads(first, second)
        XCTAssertEqual(merged.lines.count, 3)
        XCTAssertEqual(merged.lines.last?.desc, "WHITE PIZZA BOXES")
        XCTAssertEqual(merged.lines.last?.onlySecondRead, true)
    }

    func testANewItemOnlyTheSecondReadSawIsStillAdded() {
        let first = ParsedInvoice(lines: [ParsedLine(qty: 2, desc: "HP10 BURGER BOXES", unit: 15)])
        let second = ParsedInvoice(lines: [
            ParsedLine(qty: 2, desc: "HP10 BURGER BOXES", unit: 15),
            ParsedLine(qty: 3, desc: "REAL MAYO 10L", unit: 10.99)
        ])
        XCTAssertEqual(InvoiceParser.mergeReads(first, second).lines.count, 2)
    }
}
