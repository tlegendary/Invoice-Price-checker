import XCTest
@testable import ChargeCheckCore

final class SupportTests: XCTestCase {
    func testPrivateDetailsAreTakenOut() {
        XCTAssertEqual(Redact.text("mail sara.k@shop.co.uk now"), "mail [email] now")
        XCTAssertEqual(Redact.text("card 4111 1111 1111 1111 declined"), "card [number] declined")
        XCTAssertEqual(Redact.text("call +44 7700 900123"), "call [number]")
        XCTAssertEqual(Redact.text("account 12-34-56 12345678"), "account [number]")
        XCTAssertEqual(Redact.text("receipt 153, 24 cans, till B"), "receipt 153, 24 cans, till B", "short numbers stay")
    }

    func testTheReportHoldsNothingPrivate() {
        let failure = SaveFailure(area: .icloud, what: "Till/Sales 2026-11 ~A.json", reason: "owner bob@example.com, card 5555555555554444",
                                  at: Date(timeIntervalSince1970: 1_800_000_000), count: 3)
        let report = HealthReport(app: "2.0 (14)", system: "iOS 27.1", saves: [failure], waitingForICloud: 2,
                                  waitingSince: Date(timeIntervalSince1970: 1_800_000_000), openPayments: 1,
                                  giftCardsSpentTwice: 0, quarantinedFiles: 1)
        let text = report.text
        XCTAssertFalse(text.contains("bob@example.com"))
        XCTAssertFalse(text.contains("5555555555554444"))
        XCTAssertTrue(text.contains("icloud: Till/Sales 2026-11 ~A.json ×3"))
        XCTAssertTrue(text.contains("Waiting for iCloud: 2"))
        XCTAssertTrue(text.contains("Card payments being checked: 1"))
    }
}
