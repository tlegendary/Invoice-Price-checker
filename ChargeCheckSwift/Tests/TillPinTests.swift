import XCTest
import ChargeCheckCore
@testable import ChargeCheck

/// The real key function (CommonCrypto PBKDF2), checked on the simulator.
final class TillPinTests: XCTestCase {
    func testPbkdf2MatchesThePublishedTestVector() {
        // PBKDF2-HMAC-SHA256, "password" / "salt", 1 round, 32 bytes (RFC 7914 §11 and common test vectors)
        let key = TillPins.kdf("password", Array("salt".utf8), 1)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(),
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    func testRealCredentialsWorkAndOldOnesUpgrade() throws {
        let made = try XCTUnwrap(TillPins.make("2580"))
        let person = Cashier(id: "a", name: "Sara", pinHash: "", role: .cashier, pin: made)
        XCTAssertEqual(TillPins.check("2580", person), .yes(upgrade: nil))
        XCTAssertEqual(TillPins.check("2581", person), .no)
        let old = Cashier(id: "b", name: "Ali", pinHash: PinCredentials.legacy("1357"), role: .manager, pin: nil)
        guard case .yes(let upgrade?) = TillPins.check("1357", old) else { return XCTFail("old PIN must still work") }
        XCTAssertEqual(upgrade.rounds, PinCredentials.currentRounds)
        XCTAssertNotEqual(TillPins.make("2580")?.salt, made.salt)
    }
}
