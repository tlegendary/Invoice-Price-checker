import Foundation

/// Text helpers used to compare what an invoice says with the names in the price list.
public enum TextTools {
    static let stopWords: Set<String> = ["fresh", "halal", "the", "and", "of", "x", "pcs", "pc", "kg", "ltd", "ltrs", "ltr", "lt", "l"]

    /// Lower-case, keep only letters, digits and dots, single spaces.
    /// Works for every alphabet: accents are dropped (é → e, ü → u), and Arabic / Kurdish letters that
    /// are written or read in more than one way (ي ى ی, ك ک, ه ة ە, ا أ إ آ) count as the same letter.
    public static func norm(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSpace = true
        func keep(_ scalar: Unicode.Scalar) {
            out.append(scalar)
            lastWasSpace = false
        }
        for scalar in text.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            let v = scalar.value
            if (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || v == 46 {
                keep(scalar)
                continue
            }
            if v < 128 {
                if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            switch v {
            case 0x0660...0x0669: keep(Unicode.Scalar(UInt8(v - 0x0660 + 0x30)))      // ٠-٩
            case 0x06F0...0x06F9: keep(Unicode.Scalar(UInt8(v - 0x06F0 + 0x30)))      // ۰-۹
            case 0x0640: continue                                                      // ـ (stretching mark)
            case 0x0622, 0x0623, 0x0625, 0x0671: keep("\u{0627}")                      // آ أ إ ٱ → ا
            case 0x0649, 0x06CC, 0x06CE: keep("\u{064A}")                              // ى ی ێ → ي
            case 0x06A9: keep("\u{0643}")                                              // ک → ك
            case 0x0629, 0x06D5, 0x06BE, 0x06C0: keep("\u{0647}")                      // ة ە ھ → ه
            case 0x00DF: keep("s"); keep("s")                                          // ß
            case 0x00E6: keep("a"); keep("e")                                          // æ
            case 0x0153: keep("o"); keep("e")                                          // œ
            case 0x00F8: keep("o")                                                     // ø
            default:
                switch scalar.properties.generalCategory {
                case .nonspacingMark, .enclosingMark, .format:
                    continue                                                           // accents, Arabic vowel marks
                case .lowercaseLetter, .uppercaseLetter, .titlecaseLetter, .otherLetter, .modifierLetter, .decimalNumber:
                    keep(scalar)
                default:
                    if !lastWasSpace {
                        out.append(" ")
                        lastWasSpace = true
                    }
                }
            }
        }
        var result = String(out)
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    /// The meaningful words of a name (filler words and stray single letters removed).
    public static func tokens(_ text: String) -> [String] {
        norm(text).split(separator: " ").map(String.init).filter { token in
            !stopWords.contains(token) && (token.count > 1 || token.contains(where: { $0.isNumber }))
        }
    }

    /// Two words count as the same when equal, or when one starts with the other (4+ letters), e.g. "wing" / "wings".
    public static func tokenEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count >= 4 && b.count >= 4 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
        // Arabic "the": الدجاج and دجاج are the same word
        let x = withoutArabicThe(a), y = withoutArabicThe(b)
        return (x != a || y != b) && x == y
    }

    private static func withoutArabicThe(_ word: String) -> String {
        word.count >= 5 && word.hasPrefix("\u{0627}\u{0644}") ? String(word.dropFirst(2)) : word
    }

    /// A letter that can be part of a real name: plain A-Z, or a letter of a non-Latin alphabet (Arabic, Kurdish…).
    /// Accented Latin letters on their own don't count – the photo reader sometimes invents those.
    private static func isNameLetter(_ ch: Character) -> Bool {
        guard ch.isLetter else { return false }
        return ch.isASCII || (ch.unicodeScalars.first?.value ?? 0) >= 0x0370
    }

    /// Supplier names as read from invoices often carry stray marks; keep only real words.
    public static func cleanSupplier(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { word in
            let letters = word.filter { isNameLetter($0) }.count
            return letters >= 2 && hasTwoLettersInARow(word) && !word.contains(where: { $0.isNumber })
        }.joined(separator: " ")
    }

    private static func hasTwoLettersInARow(_ word: String) -> Bool {
        var run = 0
        for ch in word {
            if isNameLetter(ch) {
                run += 1
                if run >= 2 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    /// Same supplier, allowing for small reading mistakes ("FOOD DISTRIB TION" / "Food Distribution").
    public static func sameSupplier(_ a: String, _ b: String) -> Bool {
        let x = cleanSupplier(a).lowercased(), y = cleanSupplier(b).lowercased()
        if x.isEmpty || y.isEmpty { return false }
        if x == y || x.contains(y) || y.contains(x) { return true }
        return similarity(x, y) >= 0.5
    }

    /// Share of words two texts have in common (0...1).
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = tokens(a), y = tokens(b)
        if x.isEmpty || y.isEmpty { return 0 }
        var hit = 0
        for t in x where y.contains(where: { tokenEqual($0, t) }) { hit += 1 }
        return Double(2 * hit) / Double(x.count + y.count)
    }
}
