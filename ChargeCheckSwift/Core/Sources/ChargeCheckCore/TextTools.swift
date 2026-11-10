import Foundation

/// Text helpers used to compare what an invoice says with the names in the price list.
public enum TextTools {
    static let stopWords: Set<String> = ["fresh", "halal", "the", "and", "of", "x", "pcs", "pc", "kg", "ltd", "ltrs", "ltr", "lt", "l"]

    /// Lower-case, keep only letters, digits and dots, single spaces.
    public static func norm(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in text.lowercased().unicodeScalars {
            let v = scalar.value
            let keep = (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || v == 46
            if keep {
                out.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
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
        return a.count >= 4 && b.count >= 4 && (a.hasPrefix(b) || b.hasPrefix(a))
    }

    /// Supplier names as read from invoices often carry stray marks; keep only real words.
    public static func cleanSupplier(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { word in
            let letters = word.filter { $0.isASCII && $0.isLetter }.count
            return letters >= 2 && hasTwoLettersInARow(word) && !word.contains(where: { $0.isNumber })
        }.joined(separator: " ")
    }

    private static func hasTwoLettersInARow(_ word: String) -> Bool {
        var run = 0
        for ch in word {
            if ch.isASCII && ch.isLetter {
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
