import XCTest
@testable import ChargeCheckCore

final class NameIdeasTests: XCTestCase {
    private func item(_ id: String, _ name: String, aliases: [String] = []) -> PriceItem {
        PriceItem(id: id, cat: "Food", name: name, price: 10, supplier: "", aliases: aliases)
    }

    func testQuarterPounderGetsShorthand() {
        let qp = item("1", "Quarter Pounder 48x113g")
        let ideas = NameIdeas.suggest(for: qp, among: [qp])
        XCTAssertTrue(ideas.contains("quarter pounder"), "\(ideas)")
        XCTAssertTrue(ideas.contains("qtr pounder"), "\(ideas)")
        XCTAssertTrue(ideas.contains("qtr pdr"), "\(ideas)")
    }

    func testBurgerBoxCodeOnItsOwn() {
        let box = item("1", "HP10 Burger Box 1x150")
        let ideas = NameIdeas.suggest(for: box, among: [box])
        XCTAssertTrue(ideas.contains("hp10"), "\(ideas)")
        XCTAssertTrue(ideas.contains("hp10 burger box"), "\(ideas)")
        XCTAssertTrue(ideas.contains("hp10 bgr box"), "\(ideas)")
    }

    func testNothingThatFitsAnotherItem() {
        // two sizes of the same thing: "chicken wings" would read as either, so it's never offered
        let big = item("1", "Chicken Wings 10kg"), small = item("2", "Chicken Wings 5kg")
        let ideas = NameIdeas.suggest(for: big, among: [big, small])
        XCTAssertFalse(ideas.contains("chicken wings"), "\(ideas)")
        XCTAssertFalse(ideas.contains("chkn wings"), "\(ideas)")
        // a code that is the start of another item's code
        let hp10 = item("3", "HP10 Box"), hp100 = item("4", "HP100 Box")
        XCTAssertFalse(NameIdeas.suggest(for: hp10, among: [hp10, hp100]).contains("hp10"))
        // another item already uses the name
        let veg = item("5", "Vegetable Oil 20L"), other = item("6", "Rapeseed Oil", aliases: ["veg oil"])
        XCTAssertFalse(NameIdeas.suggest(for: veg, among: [veg, other]).contains("veg oil"))
    }

    func testNotOfferedTwiceOrTooLoose() {
        let mayo = item("1", "Mayonnaise 10L", aliases: ["mayonnaise"])
        let ideas = NameIdeas.suggest(for: mayo, among: [mayo])
        XCTAssertFalse(ideas.contains("mayonnaise"), "already one of its names")
        XCTAssertFalse(ideas.contains("mayo"), "one short word is too loose")
        let oil = item("2", "Oil")
        XCTAssertEqual(NameIdeas.suggest(for: oil, among: [oil]), [])
    }

    func testSuggestedNameIsThenRecognisedWithConfidence() {
        let qp = item("1", "Quarter Pounder 48x113g"), half = item("2", "Half Pounder 24x227g")
        var withIdeas = qp
        withIdeas.aliases = NameIdeas.suggest(for: qp, among: [qp, half])
        let result = Matcher.match("QTR PDR BEEF 113G", in: [withIdeas, half])
        XCTAssertEqual(result.itemID, "1")
        XCTAssertTrue(result.confident)
        // and the other item isn't pulled in
        XCTAssertEqual(Matcher.match("HALF POUNDER 227G", in: [withIdeas, half]).itemID, "2")
    }

    func testSizesAndCodes() {
        for size in ["9kg", "10l", "4x12", "x50", "500", "1x150", "12pk", "113g"] { XCTAssertTrue(NameIdeas.isSize(size), size) }
        for word in ["hp10", "box", "c12x"] { XCTAssertFalse(NameIdeas.isSize(word), word) }
        XCTAssertTrue(NameIdeas.isCode("hp10"))
        XCTAssertFalse(NameIdeas.isCode("10kg"))
        XCTAssertFalse(NameIdeas.isCode("box"))
    }
}
