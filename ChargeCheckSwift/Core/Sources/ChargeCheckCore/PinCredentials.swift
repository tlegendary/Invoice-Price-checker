import Foundation

/// A till PIN, kept only as a slow, salted fingerprint (PBKDF2-HMAC-SHA256). The PIN itself is never stored.
///
/// The key-stretching itself is passed in (`PinKDF`): the app uses Apple's CommonCrypto; tests use a fake. That keeps
/// these rules testable on Linux and keeps crypto code out of the Core.
public struct PinCredential: Codable, Equatable, Hashable, Sendable {
    /// 2 = PBKDF2-HMAC-SHA256 with a random salt. (1 was SHA-256 of "chargecheck|PIN", no salt, kept in `pinHash`.)
    public var version: Int
    public var rounds: Int
    /// Random, unique per credential (hex).
    public var salt: String
    /// The derived key (hex).
    public var hash: String

    public init(version: Int, rounds: Int, salt: String, hash: String) {
        self.version = version
        self.rounds = rounds
        self.salt = salt
        self.hash = hash
    }
}

/// Derives a key from a PIN and salt: (pin, salt bytes, rounds) → key bytes.
public typealias PinKDF = @Sendable (_ pin: String, _ salt: [UInt8], _ rounds: Int) -> [UInt8]

public enum PinCredentials {
    public static let currentVersion = 2
    /// About 50 ms on a recent iPhone. A 4–8 digit PIN can't be made strong by hashing alone: this slows guessing
    /// from a copied file; the real protection is that the files stay on the owner's devices and iCloud.
    public static let currentRounds = 100_000
    public static let saltBytes = 16

    /// A new credential for this PIN, with a fresh random salt. nil if the key couldn't be made (never saved then).
    public static func make(_ pin: String, kdf: PinKDF, random: () -> [UInt8] = { randomBytes(saltBytes) },
                            rounds: Int = currentRounds) -> PinCredential? {
        let salt = random()
        let key = kdf(normalized(pin), salt, rounds)
        guard salt.count >= 8, key.count >= 16 else { return nil }
        return PinCredential(version: currentVersion, rounds: rounds, salt: hex(salt), hash: hex(key))
    }

    public enum Check: Equatable, Sendable {
        case no
        /// Right PIN. `upgrade` is set when the stored credential is old or weaker: save it in its place.
        case yes(upgrade: PinCredential?)
    }

    /// Checks a PIN against what's stored: the new credential if there is one, otherwise the old unsalted fingerprint.
    public static func check(_ pin: String, credential: PinCredential?, legacyHash: String?, kdf: PinKDF,
                             random: () -> [UInt8] = { randomBytes(saltBytes) }) -> Check {
        if let credential, credential.version >= currentVersion, let salt = bytes(credential.salt), !salt.isEmpty {
            // an empty or failed key never matches anything
            let derived = kdf(normalized(pin), salt, credential.rounds)
            guard !derived.isEmpty, !credential.hash.isEmpty, same(hex(derived), credential.hash) else { return .no }
            return .yes(upgrade: credential.rounds < currentRounds ? make(pin, kdf: kdf, random: random) : nil)
        }
        if let legacyHash, !legacyHash.isEmpty, same(legacy(normalized(pin)), legacyHash) {
            return .yes(upgrade: make(pin, kdf: kdf, random: random))
        }
        return .no
    }

    /// A PIN must be 4–8 digits (Arabic-Indic digits count as the same digits).
    public static func isValid(_ pin: String) -> Bool {
        let p = normalized(pin)
        return (4...8).contains(p.count) && p.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// "١٢٣٤" and "۱۲۳۴" → "1234", so a PIN typed on an Arabic or Kurdish keyboard is the same PIN. Other characters
    /// are kept (and then fail `isValid`).
    public static func normalized(_ pin: String) -> String {
        String(pin.map { c -> Character in
            guard !c.isASCII, let d = c.wholeNumberValue, (0...9).contains(d) else { return c }
            return Character(String(d))
        })
    }

    /// The version-1 fingerprint, only to recognise PINs saved before salting.
    public static func legacy(_ pin: String) -> String { hex(SHA256.hash(Array(("chargecheck|" + pin).utf8))) }

    public static func randomBytes(_ count: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &g) }
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func bytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    /// Compares without stopping at the first difference.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for k in 0..<x.count { diff |= x[k] ^ y[k] }
        return diff == 0
    }
}

/// SHA-256 (FIPS 180-4), for recognising old fingerprints in the Core without CryptoKit (which isn't on Linux).
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var m = message
        let bitLength = UInt64(message.count) * 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for i in (0..<8).reversed() { m.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8))) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: m.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(m[b]) << 24 | UInt32(m[b + 1]) << 16 | UInt32(m[b + 2]) << 8 | UInt32(m[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - $0 * 8)) } }
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
}
