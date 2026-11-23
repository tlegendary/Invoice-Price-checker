import XCTest
@testable import ChargeCheckCore

final class PackGuessTests: XCTestCase {
    func testGuesses() {
        XCTAssertEqual(PackGuess.count(in: "Quarter Pounder 48x113g"), 48)
        XCTAssertEqual(PackGuess.count(in: "Cups 4x50"), 200)
        XCTAssertEqual(PackGuess.count(in: "Napkins x500"), 500)
        XCTAssertEqual(PackGuess.count(in: "Chicken Wings 10kg"), 1)
        XCTAssertEqual(PackGuess.count(in: "Wooden forks 100pcs"), 100)
        XCTAssertEqual(PackGuess.count(in: "Box"), 1)
    }
}
