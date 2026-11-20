import CommonCrypto
import ChargeCheckCore
import Foundation

/// PBKDF2-HMAC-SHA256 from Apple's CommonCrypto, for till PINs (the rules are in `PinCredentials`).
enum TillPins {
    static let kdf: PinKDF = { pin, salt, rounds in
        let password = Array(pin.utf8)
        var key = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBufferPointer { pw in
            pw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(1, password.count)) { pwChars in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwChars, password.count, salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(max(1, rounds)), &key, key.count)
            }
        }
        return status == kCCSuccess ? key : []
    }

    /// Fresh random bytes from the system's secure generator.
    static func salt() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: PinCredentials.saltBytes)
        return SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess ? bytes : []
    }

    static func make(_ pin: String) -> PinCredential? { PinCredentials.make(pin, kdf: kdf, random: salt) }

    static func check(_ pin: String, _ cashier: Cashier) -> PinCredentials.Check {
        PinCredentials.check(pin, credential: cashier.pin, legacyHash: cashier.pinHash, kdf: kdf, random: salt)
    }
}
