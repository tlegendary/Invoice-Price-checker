import XCTest
@testable import ChargeCheckCore

final class LanguageTests: XCTestCase {
    override func tearDown() {
        InvoiceParser.language = "en"
        Money.currency = .gbp
        super.tearDown()
    }

    func testCurrencies() {
        XCTAssertEqual(Money.format(12.5), "£12.50")
        Money.currency = .eur
        XCTAssertEqual(Money.format(1234.5), "1234,50 €")
        XCTAssertEqual(Money.parse("1.234,50"), 1234.5)
        XCTAssertEqual(Money.parse("12,50 €"), 12.5)
        Money.currency = .iqd
        XCTAssertEqual(Money.format(25000), "25,000 IQD")
        XCTAssertEqual(Money.parse("25,000"), 25000)
        XCTAssertEqual(Money.parse("٢٥٬٠٠٠"), 25000)
        Money.currency = .gbp
        XCTAssertEqual(Money.parse("٢٥٫٥٠"), 25.5)
    }

    func testGermanInvoice() {
        InvoiceParser.language = "de"
        Money.currency = .eur
        let text = """
        Muster Großhandel GmbH
        Rechnungsnummer 45120
        Rechnungsdatum 05.11.2026
        Menge Bezeichnung Einzelpreis Gesamt MwSt
        2 Hähnchenflügel 10kg 14,99 29,98 7
        1 Pizzakartons 16 Zoll 1.016,99 1.016,99 19
        Nettobetrag 1.046,97
        Gesamtbetrag 1.155,30
        """
        let invoice = InvoiceParser.parseInvoice(text)
        XCTAssertEqual(invoice.supplier, "Muster Großhandel GmbH")
        XCTAssertEqual(invoice.invNo, "45120")
        XCTAssertEqual(invoice.date, "05.11.2026")
        XCTAssertEqual(invoice.printedNet, 1046.97)
        XCTAssertEqual(invoice.printedTotal, 1155.30)
        XCTAssertEqual(invoice.lines.count, 2)
        XCTAssertEqual(invoice.lines.first?.desc, "Hähnchenflügel 10kg")
        XCTAssertEqual(invoice.lines.first?.unit, 14.99)
        XCTAssertEqual(invoice.lines.first?.vat, 7)
        XCTAssertEqual(invoice.lines.last?.unit, 1016.99)
        XCTAssertFalse(InvoiceParser.looksGarbled("Hähnchenflügel"))
    }

    func testArabicInvoiceInDinars() {
        InvoiceParser.language = "ar"
        Money.currency = .iqd
        let text = """
        شركة النور للمواد الغذائية
        رقم الفاتورة 7781
        التاريخ ٠٥/١١/٢٠٢٦
        اجنحة دجاج ١٠ كغم ٢ ٢٥٬٠٠٠ ٥٠٬٠٠٠
        زيت نباتي ٢٠ لتر ١ ٣٢٬٥٠٠ ٣٢٬٥٠٠
        الإجمالي ٨٢٬٥٠٠
        """
        let invoice = InvoiceParser.parseInvoice(text)
        XCTAssertEqual(invoice.invNo, "7781")
        XCTAssertEqual(invoice.date, "05/11/2026")
        XCTAssertEqual(invoice.printedTotal, 82500)
        XCTAssertEqual(invoice.lines.count, 2)
        XCTAssertEqual(invoice.lines.first?.qty, 2)
        XCTAssertEqual(invoice.lines.first?.unit, 25000)
        XCTAssertEqual(invoice.lines.first?.desc, "اجنحة دجاج ١٠ كغم".replacingOccurrences(of: "١٠", with: "10"))
        XCTAssertEqual(invoice.lines.last?.unit, 32500)
        XCTAssertTrue(invoice.supplier.hasPrefix("شركة"))
    }

    func testNamesInOtherAlphabetsMatch() {
        // English stays exactly as it was
        XCTAssertEqual(TextTools.norm("Chicken Wings (10KG) – 2.5L!"), "chicken wings 10kg 2.5l")
        // accents are dropped, so a name matches with or without them
        XCTAssertEqual(TextTools.norm("Hähnchenflügel 10kg"), "hahnchenflugel 10kg")
        XCTAssertEqual(TextTools.norm("CAFÉ Crème"), "cafe creme")
        XCTAssertEqual(TextTools.norm("Großhandel"), "grosshandel")
        // Arabic and Kurdish: different ways of writing the same letter count as the same
        XCTAssertEqual(TextTools.norm("أجنحة دجاج ١٠ كغم"), TextTools.norm("اجنحه دجاج 10 كغم"))
        XCTAssertEqual(TextTools.norm("مریشک"), TextTools.norm("مريشك"))
        XCTAssertFalse(TextTools.norm("زيت نباتي").isEmpty)

        let wings = PriceItem(id: "w", cat: "Meat", name: "اجنحة دجاج 10 كغم", price: 25000)
        let oil = PriceItem(id: "o", cat: "Oil", name: "زيت نباتي 20 لتر", price: 32500)
        let german = PriceItem(id: "g", cat: "Meat", name: "Hähnchenflügel 10kg", price: 14.99)
        let items = [wings, oil, german]
        XCTAssertEqual(Matcher.match("أجنحة الدجاج ١٠ كغم", in: items).itemID, "w")
        XCTAssertEqual(Matcher.match("زيت نباتي ٢٠ لتر", in: items).itemID, "o")
        XCTAssertEqual(Matcher.match("HAHNCHENFLUGEL 10KG", in: items).itemID, "g")
        XCTAssertNil(Matcher.match("طحين ابيض", in: items).itemID)

        // supplier names in Arabic are kept, and compared
        XCTAssertEqual(TextTools.cleanSupplier("شركة النور 123 ##"), "شركة النور")
        XCTAssertTrue(TextTools.sameSupplier("شركة النور للمواد الغذائية", "شركة النور"))
        XCTAssertEqual(TextTools.cleanSupplier("NORTHGATE WHOLESALE LTD ~ 4"), "NORTHGATE WHOLESALE LTD")
    }

    func testPackSizeWarning() {
        XCTAssertEqual(PackSize.sizes(in: "CHICKEN WINGS 10KG").map { $0.label }, ["10kg"])
        XCTAssertEqual(PackSize.sizes(in: "Veg Oil 2.5 L").first?.amount, 2500)
        XCTAssertEqual(PackSize.sizes(in: "Mayo 4x500g").first?.amount, 500)
        XCTAssertNil(PackSize.mismatch(invoice: "CHICKEN WINGS 10 KG", item: "Chicken wings 10kg"))
        XCTAssertNil(PackSize.mismatch(invoice: "OIL 20LTR", item: "Vegetable Oil 20L"))
        XCTAssertNil(PackSize.mismatch(invoice: "CHICKEN WINGS", item: "Chicken wings 10kg"))
        XCTAssertNil(PackSize.mismatch(invoice: "PIZZA BOX 12 INCH", item: "Pizza box 16in"))
        XCTAssertEqual(PackSize.mismatch(invoice: "CHICKEN WINGS 5KG", item: "Chicken wings 10kg")?.invoice, "5kg")
        XCTAssertEqual(PackSize.mismatch(invoice: "اجنحة دجاج ٥ كغم", item: "اجنحة دجاج 10 كغم")?.item, "10كغم")

        let wings = PriceItem(id: "w", cat: "Meat", name: "Chicken wings 10kg", price: 15)
        let book = PriceBook([wings])
        let small = CheckLine(qty: 2, desc: "CHICKEN WINGS 5KG", unit: 15, matchId: "w", confident: true, reads: 2)
        let same = CheckLine(qty: 2, desc: "CHICKEN WINGS 10KG", unit: 15, matchId: "w", confident: true, reads: 2)
        XCTAssertEqual(InvoiceMaths.reasons(small, supplier: "", book: book, totalOk: true).count, 1)
        XCTAssertTrue(InvoiceMaths.reasons(same, supplier: "", book: book, totalOk: true).isEmpty)
    }

    func testEnglishIsUnchanged() {
        let line = InvoiceParser.parseLine("2.00 FRESH PRIME WING 14.99 29.98 0.00")
        XCTAssertEqual(line?.qty, 2)
        XCTAssertEqual(line?.unit, 14.99)
    }
}
