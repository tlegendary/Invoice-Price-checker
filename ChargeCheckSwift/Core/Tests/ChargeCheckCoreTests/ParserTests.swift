import XCTest
@testable import ChargeCheckCore

// Checks the Swift invoice reader gives exactly the same answers as the first version of
// the app. Fixtures/parser.json holds hundreds of inputs with the answers the old app gave
// (real rows read from invoice photos, plus many made-up noisy ones).

private struct LineOut: Decodable {
    let qty: Double
    let desc: String
    let raw: String
    let unit: Double
    let vat: Double
    let warn: String
    let reads: Int?
    let disagree: Bool?
    let onlyB: Bool?
    let altQty: Double?
    let altUnit: Double?
}

private struct LineCase: Decodable {
    let input: String
    let out: LineOut?
    enum CodingKeys: String, CodingKey { case input = "in", out }
}

private struct TextCase: Decodable {
    let input: String
    let out: String
    enum CodingKeys: String, CodingKey { case input = "in", out }
}

private struct PairCase: Decodable {
    let a: String
    let b: String
    let out: String
}

private struct InvoiceOut: Decodable {
    let supplier: String
    let invNo: String
    let date: String
    let printedNet: Double?
    let printedTotal: Double?
    let lines: [LineOut]
}

private struct InvoiceCase: Decodable {
    let text: String
    let out: InvoiceOut
}

private struct MergeCase: Decodable {
    let a: String
    let b: String
    let known: [String]
    let out: InvoiceOut
}

private struct PieceIn: Decodable {
    let t: String
    let c: Double
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let a: Double
}

private struct RowsCase: Decodable {
    let items: [PieceIn]
    let out: String
}

private struct Fixture: Decodable {
    let names: [String]
    let known: [String]
    let lines: [LineCase]
    let clean: [TextCase]
    let consensus: [PairCase]
    let invoices: [InvoiceCase]
    let merges: [MergeCase]
    let rows: [RowsCase]
}

final class ParserTests: XCTestCase {
    private static let fixture: Fixture? = {
        guard let url = Bundle.module.url(forResource: "parser", withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Fixture.self, from: data)
    }()

    private var fx: Fixture {
        guard let f = ParserTests.fixture else {
            XCTFail("Fixtures/parser.json could not be loaded")
            return Fixture(names: [], known: [], lines: [], clean: [], consensus: [], invoices: [], merges: [], rows: [])
        }
        return f
    }

    private var known: Set<String> {
        InvoiceParser.knownWords(fx.names.map { PriceItem(name: $0, price: 1) })
    }

    private func close(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x - y) < 1e-6
        default: return false
        }
    }

    private func describe(_ line: ParsedLine?) -> String {
        guard let l = line else { return "nil" }
        return "qty \(l.qty) | \(l.desc) | raw \(l.raw) | unit \(l.unit) | vat \(l.vat) | reads \(l.reads) dis \(l.disagree) onlyB \(l.onlySecondRead) alt \(String(describing: l.altQty))/\(String(describing: l.altUnit)) | \(l.warn)"
    }

    private func describe(_ o: LineOut?) -> String {
        guard let l = o else { return "nil" }
        return "qty \(l.qty) | \(l.desc) | raw \(l.raw) | unit \(l.unit) | vat \(l.vat) | reads \(l.reads ?? 0) dis \(l.disagree ?? false) onlyB \(l.onlyB ?? false) alt \(String(describing: l.altQty))/\(String(describing: l.altUnit)) | \(l.warn)"
    }

    private func same(_ got: ParsedLine?, _ want: LineOut?, merged: Bool) -> Bool {
        guard let g = got, let w = want else { return got == nil && want == nil }
        var ok = close(g.qty, w.qty) && g.desc == w.desc && g.raw == w.raw && close(g.unit, w.unit) && close(g.vat, w.vat) && g.warn == w.warn
        if merged {
            ok = ok && g.reads == (w.reads ?? 0) && g.disagree == (w.disagree ?? false) && g.onlySecondRead == (w.onlyB ?? false)
                && close(g.altQty, w.altQty) && close(g.altUnit, w.altUnit)
        }
        return ok
    }

    private func report(_ name: String, total: Int, problems: [String]) {
        if problems.isEmpty { return }
        print("==== \(name): \(problems.count) of \(total) differ ====")
        for p in problems.prefix(12) { print(p) }
        XCTFail("\(name): \(problems.count) of \(total) differ from the old app")
    }

    func testKnownWords() {
        XCTAssertEqual(known, Set(fx.known))
    }

    func testLines() {
        var problems: [String] = []
        for c in fx.lines {
            let got = InvoiceParser.parseLine(c.input, known: known)
            if !same(got, c.out, merged: false) {
                problems.append("IN   \(c.input)\nWANT \(describe(c.out))\nGOT  \(describe(got))")
            }
        }
        XCTAssertGreaterThan(fx.lines.count, 500)
        report("lines", total: fx.lines.count, problems: problems)
    }

    func testCleanNames() {
        var problems: [String] = []
        for c in fx.clean {
            let got = InvoiceParser.cleanDescription(c.input, known: known)
            if got != c.out { problems.append("IN   \(c.input)\nWANT \(c.out)\nGOT  \(got)") }
        }
        report("clean names", total: fx.clean.count, problems: problems)
    }

    func testConsensus() {
        var problems: [String] = []
        for c in fx.consensus {
            let got = InvoiceParser.consensusDescription(c.a, c.b)
            if got != c.out { problems.append("A    \(c.a)\nB    \(c.b)\nWANT \(c.out)\nGOT  \(got)") }
        }
        report("consensus", total: fx.consensus.count, problems: problems)
    }

    private func compare(_ got: ParsedInvoice, _ want: InvoiceOut, merged: Bool) -> String? {
        var diffs: [String] = []
        if got.supplier != want.supplier { diffs.append("supplier want \(want.supplier) got \(got.supplier)") }
        if got.invNo != want.invNo { diffs.append("invNo want \(want.invNo) got \(got.invNo)") }
        if got.date != want.date { diffs.append("date want \(want.date) got \(got.date)") }
        if !close(got.printedNet, want.printedNet) { diffs.append("printedNet want \(String(describing: want.printedNet)) got \(String(describing: got.printedNet))") }
        if !close(got.printedTotal, want.printedTotal) { diffs.append("printedTotal want \(String(describing: want.printedTotal)) got \(String(describing: got.printedTotal))") }
        if got.lines.count != want.lines.count { diffs.append("line count want \(want.lines.count) got \(got.lines.count)") }
        for (i, w) in want.lines.enumerated() where i < got.lines.count && !same(got.lines[i], w, merged: merged) {
            diffs.append("line \(i)\n  WANT \(describe(w))\n  GOT  \(describe(got.lines[i]))")
        }
        return diffs.isEmpty ? nil : diffs.prefix(4).joined(separator: "\n")
    }

    func testWholeInvoices() {
        var problems: [String] = []
        for c in fx.invoices {
            let got = InvoiceParser.parseInvoice(c.text, known: known)
            if let d = compare(got, c.out, merged: false) { problems.append(d) }
        }
        report("invoices", total: fx.invoices.count, problems: problems)
    }

    func testMergingTwoReads() {
        var problems: [String] = []
        for c in fx.merges {
            let a = InvoiceParser.parseInvoice(c.a, known: known)
            let b = InvoiceParser.parseInvoice(c.b, known: known)
            let got = InvoiceParser.mergeReads(a, b, knownSuppliers: c.known)
            if let d = compare(got, c.out, merged: true) { problems.append(d) }
        }
        report("merges", total: fx.merges.count, problems: problems)
    }

    func testRowsFromPositions() {
        var problems: [String] = []
        for c in fx.rows {
            let pieces = c.items.map { TextPiece(text: $0.t, confidence: $0.c, x: $0.x, y: $0.y, width: $0.w, height: $0.h, angle: $0.a) }
            let got = InvoiceParser.rows(from: pieces)
            if got != c.out { problems.append("WANT\n\(c.out)\nGOT\n\(got)") }
        }
        report("rows", total: fx.rows.count, problems: problems)
    }

    func testCheckingAnInvoice() {
        let items = [
            PriceItem(id: "wing", cat: "Meat & Poultry", name: "Fresh Prime Wing", price: 14.99, aliases: ["fresh prime wing"]),
            PriceItem(id: "bun", cat: "Bakery", name: "Seed Burger Bun 4x12", price: 6.99, aliases: ["seed burger bun"], sp: [SupplierPrice(s: "Bakery Direct", p: 6.5)])
        ]
        let book = PriceBook(items)
        let text = """
        Sample Foods Ltd
        Invoice No 82044
        Invoice Date 06/11/2026
        3.00  FRESH PRIME WING  15.99  47.97  0.00
        7.00  SEED BURGER BUN 4X12  6.99  48.93  0.00
        2.00  PEPSI CAN 24X330 ML  8.29  16.58  20.00
        Total Net Amount 113.48
        """
        let parsed = InvoiceParser.parseInvoice(text, known: book.knownWords)
        XCTAssertEqual(parsed.lines.count, 3)
        XCTAssertEqual(parsed.invNo, "82044")
        XCTAssertEqual(parsed.date, "06/11/2026")
        XCTAssertEqual(parsed.printedNet, 113.48)
        var draft = InvoiceDraft(supplier: parsed.supplier, invNo: parsed.invNo, date: parsed.date,
                                 lines: parsed.lines.map { InvoiceMaths.makeLine($0, book: book) }, printedNet: parsed.printedNet)
        XCTAssertEqual(draft.lines[0].matchId, "wing")
        XCTAssertEqual(draft.lines[1].matchId, "bun")
        XCTAssertNil(draft.lines[2].matchId)
        var totals = InvoiceMaths.totals(draft, book: book)
        XCTAssertEqual(totals.net, 113.48)
        XCTAssertEqual(totals.vat, 3.32)
        XCTAssertEqual(totals.over, 3.0)          // 3 × (15.99 − 14.99)
        XCTAssertTrue(totals.totalOk)
        XCTAssertEqual(totals.needLook, 1)        // Pepsi isn't in the price list
        XCTAssertFalse(totals.verified)
        draft.lines[2].noBase = true
        totals = InvoiceMaths.totals(draft, book: book)
        XCTAssertTrue(totals.verified)
        // a supplier's own agreed price is used when the invoice is from that supplier
        draft.supplier = "BAKERY DIRECT LTD"
        XCTAssertEqual(InvoiceMaths.totals(draft, book: book).over, 6.43)   // 3.00 + 7 × 0.49
        draft.supplier = parsed.supplier
        // a learned name correction
        let fixed = InvoiceMaths.makeLine(ParsedLine(qty: 1, desc: "FRSH PRME WNG", unit: 15.99), book: book, nameFixes: ["frsh prme wng": "Fresh Prime Wing"])
        XCTAssertEqual(fixed.matchId, "wing")
        XCTAssertEqual(fixed.read, "FRSH PRME WNG")
        // saving to Reports
        let entry = InvoiceMaths.historyEntry(draft, book: book)
        XCTAssertEqual(entry.over, 3.0)
        XCTAssertEqual(entry.lines[0].item, "Fresh Prime Wing")
        XCTAssertEqual(entry.lines[0].base, 14.99)
        XCTAssertEqual(entry.amountToPay.pay, 113.8)   // 116.80 total − 3.00 overcharge
        XCTAssertNotNil(InvoiceMaths.duplicate(of: InvoiceDraft(supplier: "sample foods ltd", invNo: "82044", date: "06/11/2026"), net: 1, in: [entry]))
        XCTAssertNil(InvoiceMaths.duplicate(of: InvoiceDraft(supplier: "Sample Foods Ltd", invNo: "82045", date: "06/11/2026"), net: 113.48, in: [entry]))
    }
}
