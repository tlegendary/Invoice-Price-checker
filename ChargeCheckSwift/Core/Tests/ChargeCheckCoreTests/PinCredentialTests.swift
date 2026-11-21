import XCTest
@testable import ChargeCheckCore

final class PinCredentialTests: XCTestCase {
    /// A stand-in key function: different for every pin, salt and rounds (the app uses PBKDF2).
    private let fake: PinKDF = { pin, salt, rounds in
        SHA256.hash(Array(pin.utf8) + salt + Array(String(rounds).utf8))
    }

    func testSha256MatchesTheStandard() {
        XCTAssertEqual(PinCredentials.hex(SHA256.hash(Array("abc".utf8))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(PinCredentials.hex(SHA256.hash([])),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // the fingerprint older versions saved, so their cashiers can still sign in
        XCTAssertEqual(PinCredentials.legacy("1234"), "453963f961eff42e7002155c34fb9661461978e14acc85750b91dcb39ef91948")
        let long = [UInt8](repeating: 0x61, count: 200)   // crosses several 64-byte blocks
        XCTAssertEqual(SHA256.hash(long).count, 32)
    }

    func testNewCredentialsAreSaltedAndNeverHoldThePin() throws {
        let a = try XCTUnwrap(PinCredentials.make("1234", kdf: fake))
        let b = try XCTUnwrap(PinCredentials.make("1234", kdf: fake))
        XCTAssertEqual(a.version, 2)
        XCTAssertEqual(a.rounds, PinCredentials.currentRounds)
        XCTAssertEqual(a.salt.count, PinCredentials.saltBytes * 2)
        XCTAssertNotEqual(a.salt, b.salt, "every credential gets its own salt")
        XCTAssertNotEqual(a.hash, b.hash, "the same PIN never gives the same stored value")
        let saved = String(decoding: try JSONEncoder().encode(a), as: UTF8.self)
        XCTAssertFalse(saved.contains("1234"))
        XCTAssertNotEqual(a.hash, PinCredentials.legacy("1234"))
    }

    func testRightAndWrongPins() throws {
        let c = try XCTUnwrap(PinCredentials.make("4821", kdf: fake))
        XCTAssertEqual(PinCredentials.check("4821", credential: c, legacyHash: nil, kdf: fake), .yes(upgrade: nil))
        XCTAssertEqual(PinCredentials.check("4822", credential: c, legacyHash: nil, kdf: fake), .no)
        XCTAssertEqual(PinCredentials.check("", credential: c, legacyHash: nil, kdf: fake), .no)
        // a new credential wins over an old fingerprint left beside it
        XCTAssertEqual(PinCredentials.check("1234", credential: c, legacyHash: PinCredentials.legacy("1234"), kdf: fake), .no)
        XCTAssertEqual(PinCredentials.check("1234", credential: nil, legacyHash: nil, kdf: fake), .no)
        XCTAssertEqual(PinCredentials.check("1234", credential: nil, legacyHash: "", kdf: fake), .no)
    }

    func testOldPinsAreUpgradedOnTheFirstRightSignIn() {
        let old = PinCredentials.legacy("1234")
        guard case let .yes(upgrade?) = PinCredentials.check("1234", credential: nil, legacyHash: old, kdf: fake) else {
            return XCTFail("an old PIN must still work, and be upgraded")
        }
        XCTAssertEqual(upgrade.version, 2)
        XCTAssertEqual(PinCredentials.check("1234", credential: upgrade, legacyHash: nil, kdf: fake), .yes(upgrade: nil))
        XCTAssertEqual(PinCredentials.check("9999", credential: nil, legacyHash: old, kdf: fake), .no)
    }

    func testWeakerCredentialsAreStrengthened() throws {
        let weak = try XCTUnwrap(PinCredentials.make("1234", kdf: fake, rounds: 1_000))
        guard case let .yes(upgrade?) = PinCredentials.check("1234", credential: weak, legacyHash: nil, kdf: fake) else {
            return XCTFail("a weaker credential is upgraded")
        }
        XCTAssertEqual(upgrade.rounds, PinCredentials.currentRounds)
    }

    func testDamagedCredentialsNeverLetAnyoneIn() throws {
        let broken: PinKDF = { _, _, _ in [] }
        XCTAssertNil(PinCredentials.make("1234", kdf: broken), "a failed key is never saved")
        let good = try XCTUnwrap(PinCredentials.make("1234", kdf: fake))
        XCTAssertEqual(PinCredentials.check("1234", credential: good, legacyHash: nil, kdf: broken), .no)
        var bad = good
        bad.hash = ""
        XCTAssertEqual(PinCredentials.check("1234", credential: bad, legacyHash: nil, kdf: fake), .no)
        bad = good
        bad.salt = "zz"
        XCTAssertEqual(PinCredentials.check("1234", credential: bad, legacyHash: nil, kdf: fake), .no)
        bad.salt = ""
        XCTAssertEqual(PinCredentials.check("1234", credential: bad, legacyHash: nil, kdf: fake), .no)
    }

    func testPinRules() {
        XCTAssertTrue(PinCredentials.isValid("1234"))
        XCTAssertTrue(PinCredentials.isValid("12345678"))
        XCTAssertFalse(PinCredentials.isValid("123"))
        XCTAssertFalse(PinCredentials.isValid("123456789"))
        XCTAssertFalse(PinCredentials.isValid("12a4"))
        XCTAssertTrue(PinCredentials.isValid("١٢٣٤"), "typed on an Arabic keyboard")
        XCTAssertEqual(PinCredentials.normalized("١٢٣٤"), "1234")
        XCTAssertEqual(PinCredentials.normalized("۱۲۳۴"), "1234")
    }

    func testAPinTypedInArabicDigitsIsTheSamePin() throws {
        let c = try XCTUnwrap(PinCredentials.make("1234", kdf: fake))
        XCTAssertEqual(PinCredentials.check("١٢٣٤", credential: c, legacyHash: nil, kdf: fake), .yes(upgrade: nil))
    }
}
