import Foundation

// Turns the text read from an invoice photo into item lines (quantity, name, unit price),
// and merges two independent reads of the same photo. Ported from the first version of
// the app; the tests check it gives the same answers.

/// Small regular-expression helpers.
enum Rx {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func regex(_ pattern: String, ci: Bool = false) -> NSRegularExpression? {
        let key = (ci ? "i:" : "s:") + pattern
        lock.lock()
        defer { lock.unlock() }
        if let found = cache[key] { return found }
        guard let made = try? NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : []) else { return nil }
        cache[key] = made
        return made
    }

    static func test(_ text: String, _ pattern: String, ci: Bool = false) -> Bool {
        guard let rx = regex(pattern, ci: ci) else { return false }
        return rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func replace(_ text: String, _ pattern: String, _ template: String, ci: Bool = false) -> String {
        guard let rx = regex(pattern, ci: ci) else { return text }
        return rx.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// The first capture group of the first match, or "".
    static func group(_ text: String, _ pattern: String, ci: Bool = false) -> String {
        guard let rx = regex(pattern, ci: ci),
              let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return "" }
        return String(text[r])
    }
}

extension String {
    var hasAsciiDigit: Bool { unicodeScalars.contains { $0.value >= 48 && $0.value <= 57 } }
    var hasAsciiLetter: Bool { unicodeScalars.contains { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) } }
    var endsWithAsciiDigit: Bool {
        guard let last = unicodeScalars.last else { return false }
        return last.value >= 48 && last.value <= 57
    }

    /// Replaces only the first comma with a dot.
    var firstCommaToDot: String {
        guard let i = firstIndex(of: ",") else { return self }
        var copy = self
        copy.replaceSubrange(i...i, with: ".")
        return copy
    }

    func splitOnWhitespace() -> [String] {
        split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}

/// One item line as read from an invoice, before it is matched to the price list.
public struct ParsedLine: Equatable, Sendable {
    public var qty: Double
    public var desc: String
    /// The name exactly as read, before tidying.
    public var raw: String
    public var unit: Double
    public var vat: Double
    public var warn: String
    /// How many of the two reads agreed on this line (0 when typed by hand).
    public var reads: Int
    public var disagree: Bool
    public var onlySecondRead: Bool
    public var altQty: Double?
    public var altUnit: Double?

    public init(qty: Double, desc: String, raw: String = "", unit: Double, vat: Double = 0, warn: String = "", reads: Int = 0,
                disagree: Bool = false, onlySecondRead: Bool = false, altQty: Double? = nil, altUnit: Double? = nil) {
        self.qty = qty
        self.desc = desc
        self.raw = raw
        self.unit = unit
        self.vat = vat
        self.warn = warn
        self.reads = reads
        self.disagree = disagree
        self.onlySecondRead = onlySecondRead
        self.altQty = altQty
        self.altUnit = altUnit
    }
}

public struct ParsedInvoice: Equatable, Sendable {
    public var supplier: String
    public var invNo: String
    public var date: String
    public var printedNet: Double?
    public var printedTotal: Double?
    public var lines: [ParsedLine]

    public init(supplier: String = "", invNo: String = "", date: String = "", printedNet: Double? = nil, printedTotal: Double? = nil, lines: [ParsedLine] = []) {
        self.supplier = supplier
        self.invNo = invNo
        self.date = date
        self.printedNet = printedNet
        self.printedTotal = printedTotal
        self.lines = lines
    }
}

/// A piece of text found on the page by Apple's reader, with where it sits.
public struct TextPiece: Equatable, Sendable {
    public var text: String
    public var confidence: Double
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var angle: Double

    public init(text: String, confidence: Double, x: Double, y: Double, width: Double, height: Double, angle: Double) {
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.angle = angle
    }
}

public enum InvoiceParser {

    // MARK: - small pieces

    private static let leadingStrip: Set<Character> = ["£", "$", "€", "*", "~", "'", "\"", "`", "|", "(", ")", "[", "]", "{", "}", ",", ";", ":", "_", "—", "–", "-", "=", "/", "\\"]
    private static let trailingStrip: Set<Character> = [")", "]", "(", "{", "}", "[", ",", ";", ":", "'", "\"", "`", "|", "_", "—", "–", "-", "=", "/", "\\"]

    static func stripToken(_ token: String) -> String {
        var chars = Array(token)
        var start = 0
        while start < chars.count, leadingStrip.contains(chars[start]) { start += 1 }
        chars = Array(chars[start...])
        while let last = chars.last, trailingStrip.contains(last) { chars.removeLast() }
        return String(chars)
    }

    /// Like JavaScript's parseFloat: reads the longest number at the start of the text.
    static func leadingNumber(_ text: String) -> Double? {
        var out = ""
        var seenDot = false
        var seenDigit = false
        for (i, ch) in text.enumerated() {
            if ch == "-" && i == 0 { out.append(ch); continue }
            if ch.isASCII && ch.isNumber { out.append(ch); seenDigit = true; continue }
            if ch == "." && !seenDot { seenDot = true; out.append(ch); continue }
            break
        }
        guard seenDigit, let value = Double(out), value.isFinite else { return nil }
        return value
    }

    /// A money amount in a line. `explicit` is false when the decimal point was lost ("2499" for 24.99).
    static func numberInfo(_ token: String) -> (value: Double, explicit: Bool)? {
        var s = stripToken(token)
        if !s.hasAsciiDigit || !Rx.test(s, "^[0-9OoIlS.,]+$") { return nil }
        if Money.currency.decimals == 0 {
            // dinars and similar: whole amounts, thousands grouped with , or .
            if Rx.test(s, "^[0-9]{1,3}([.,][0-9]{3})+$") || Rx.test(s, "^[0-9]{1,9}$"),
               let v = Double(s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: "")) { return (v, true) }
            return nil
        }
        if Rx.test(s, "^[0-9]{1,3}([.,][0-9]{3})+[.,][0-9]{2}$") {
            // "1.234,56" or "1,234.56"
            let digits = s.filter { $0.isASCII && $0.isNumber }
            if let v = Double(digits) { return (v / 100, true) }
        }
        s = s.replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "o", with: "0")
            .replacingOccurrences(of: "I", with: "1").replacingOccurrences(of: "l", with: "1")
            .replacingOccurrences(of: "S", with: "5").firstCommaToDot
        if Rx.test(s, "^[0-9]{1,5}\\.[0-9]{1,2}$"), let v = Double(s) { return (v, true) }
        if Rx.test(s, "^\\.[0-9]{2}$"), let v = Double("0" + s) { return (v, true) }
        if Rx.test(s, "^[0-9]{3,6}$"), let v = Int(s) { return (Double(v) / 100, false) }
        if Rx.test(s, "^0{1,2}$") { return (0, true) }
        return nil
    }

    static func quantityToken(_ token: String, decimalOnly: Bool = false) -> Double? {
        let s = stripToken(token).replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "o", with: "0").firstCommaToDot
        if Rx.test(s, "^[0-9]{1,3}\\.[0-9]{2}$") { return Double(s) }
        if decimalOnly { return nil }
        if Money.currency.decimals > 0, Rx.test(s, "^[1-9]00$"), let v = Int(s) { return Double(v) / 100 }
        if Rx.test(s, "^[0-9]{1,2}$"), let v = Int(s), v > 0 { return Double(v) }
        return nil
    }

    static func isJunk(_ token: String, trailing: Bool = false) -> Bool {
        let s = stripToken(token)
        if s.isEmpty || Rx.test(token, "^[^\\p{L}\\p{N}]+$") { return true }
        if trailing { return s.count <= 3 && !Rx.test(s, "[0-9][.,][0-9]") }
        return s.count <= 2 && !s.hasAsciiDigit
    }

    // MARK: - tidying item names

    static let keepShort: Set<String> = Set("bun buns oil mix pot pots cup cups lid lids tub tubs box bag bags can cans jar ham egg eggs ice tea veg pie pies hot dog red raw rib ribs leg legs cod fry pan bbq mac oat soy pea peas jam fat ale gin rum wet dry big new med sm lg xl xxl kg ml lt ltr ltrs cl oz lb lbs pk pkt pcs pc ea cs ctn dz doz pack tray roll rolls hat mat net top tip tin tins jug".split(separator: " ").map(String.init))

    /// The words used in the price list: these are never treated as stray marks.
    public static func knownWords(_ items: [PriceItem]) -> Set<String> {
        var words = Set<String>()
        for item in items {
            for word in TextTools.norm(item.name).split(separator: " ") where word.count >= 2 { words.insert(String(word)) }
        }
        return words
    }

    private static func isSize(_ word: String) -> Bool {
        let w = word.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        return Rx.test(w, "^[0-9]+([.,][0-9]+)?(x[0-9]+([.,][0-9]+)?)?(kg|g|gr|gm|grm|ml|l|lt|ltr|ltrs|cl|oz|lb|lbs|pk|pcs?|s|in|cm|mm)?$", ci: true)
            || Rx.test(w, "^[0-9]+x[0-9]", ci: true)
    }

    /// Drops product codes, stray letters, pen marks and prices the reader glued onto an item name.
    /// The second read (no spelling help) sometimes invents letters like Ą or Ž, or ¡ and ! for an inch mark.
    /// The language invoices are written in: "en", "de", "fr", "ar" or "ckb" (set by the app).
    public static var language = "en"
    static var rightToLeft: Bool { language == "ar" || language == "ckb" }

    /// Arabic-Indic and Persian digits (٠١٢ / ۰۱۲) become 0-9; the Arabic decimal and thousands marks become . and ,
    public static func westernDigits(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0x0660...0x066C).contains($0.value) || (0x06F0...0x06F9).contains($0.value) || $0.value == 0x060C }) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.value {
            case 0x0660...0x0669: return Unicode.Scalar(scalar.value - 0x0660 + 0x30)!
            case 0x06F0...0x06F9: return Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!
            case 0x066B: return "."
            case 0x066C, 0x060C: return ","
            default: return scalar
            }
        }))
    }

    /// Characters a UK invoice really uses beyond plain ASCII. Anything else the reader made up.
    private static let realSymbols: Set<Unicode.Scalar> = ["£", "€", "“", "”", "‘", "’", "–", "—", "×", "°", "½", "¼", "¾", "•", "©", "®", "™", "\u{00A0}"]

    public static func looksGarbled(_ text: String) -> Bool {
        // only English invoices: other languages really use these letters
        guard language == "en" else { return false }
        return text.unicodeScalars.contains { $0.value > 0x7F && !realSymbols.contains($0) }
            || Rx.test(text, "[A-Za-z0-9]![A-Za-z0-9!]|![A-Za-z]")
    }

    /// Ą → A, Ž → Z; ¡ ¿ and a "!" inside a word go. Invoices here are in English.
    static func plainLetters(_ text: String) -> String {
        guard looksGarbled(text) else { return text }
        var s = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_GB"))
        s = s.replacingOccurrences(of: "ß", with: "SS").replacingOccurrences(of: "Ł", with: "L").replacingOccurrences(of: "ł", with: "l")
            .replacingOccurrences(of: "Ø", with: "O").replacingOccurrences(of: "ø", with: "o").replacingOccurrences(of: "Đ", with: "D")
        // whatever is still not plain text (Greek, Cyrillic look-alikes, odd marks) becomes a gap
        s = String(String.UnicodeScalarView(s.unicodeScalars.map { $0.value <= 0x7F || realSymbols.contains($0) ? $0 : " " }))
        s = Rx.replace(s, "[¡¿]+", " ")
        s = Rx.replace(s, "([0-9])[A-Za-z]?!+(?=[\\sA-Za-z])", "$1\" ")
        s = Rx.replace(s, "!+", " ")
        return s
    }

    public static func cleanDescription(_ text: String, known: Set<String>) -> String {
        var s = Rx.replace(plainLetters(text), "[|«»©®™~_¦§¬¥€$*#@^<>{}\\[\\]]+", " ")
        s = Rx.replace(s, "(^|[\\sxX])([0-9])[0O][zZ]\\b", "$1$2oz")
        s = Rx.replace(s, "\\bI(trs?)\\b", "L$1")
        s = Rx.replace(s, "\\bi(trs?)\\b", "l$1")
        var t: [String] = s.splitOnWhitespace().map { word in
            var w = Rx.replace(word, "^[^\\p{L}\\p{N}(£€$]+|[^\\p{L}\\p{N})%]+$", "")
            if w.hasSuffix(")") && !w.contains("(") { w.removeLast() }
            if Rx.test(w, "^[0-9]+[xX][0-9SOo]+$"), let cut = w.firstIndex(where: { $0 == "x" || $0 == "X" }) {
                let head = w[...cut]
                let tail = w[w.index(after: cut)...].replacingOccurrences(of: "S", with: "5")
                    .replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "o", with: "0")
                w = String(head) + tail
            }
            return w
        }.filter { !$0.isEmpty }

        // a price glued into the name: the rest is other columns
        if let k = t.indices.first(where: { $0 >= 2 && Rx.test(t[$0], "^[0-9]{1,4}[.,][0-9]{2}$") }), k > 0 {
            t = Array(t[..<k])
        }
        // a quantity like "2.00" repeated in front of the name
        if t.count > 2, Rx.test(t[0], "^[0-9]{1,3}[.,][0-9]{2}$") { t.removeFirst() }

        // product / stock codes in front of the name
        while t.count > 1, Rx.test(t[0], "^[0-9]{4,}$") || (t[0].hasAsciiDigit && Rx.test(t[0], "^[A-Z0-9\\-/]{5,}$") && !isSize(t[0])) {
            t.removeFirst()
        }

        func junk(_ w: String, _ prev: String?) -> Bool {
            let lw = w.lowercased()
            if known.contains(lw) || keepShort.contains(lw) { return false }
            // Arabic and Kurdish words are never stray marks
            if w.unicodeScalars.contains(where: { $0.value >= 0x0600 && $0.value <= 0x06FF }) { return false }
            if Rx.test(w, "^[0-9]$") { return prev != nil && !(prev ?? "").isEmpty }
            if Rx.test(w, "^0+$") { return true }
            if w.hasAsciiDigit { return !isSize(w) && w.hasAsciiLetter && w.count <= 5 }
            if w.count == 1 { return !((prev ?? "").endsWithAsciiDigit && Rx.test(w, "^[lgx]$", ci: true)) }
            if w.count <= 3 { return true }
            return !Rx.test(w, "[aeiouy]", ci: true) && w.count <= 4
        }
        while t.count > 1, junk(t[t.count - 1], t[t.count - 2]) { t.removeLast() }
        while t.count > 1, t[0].count == 1, !t[0].hasAsciiDigit, !Rx.test(t[0], "^[ax]$", ci: true), !known.contains(t[0].lowercased()) {
            t.removeFirst()
        }
        // single stray letters inside the name ("Chicken l Wings")
        let before = t
        t = before.enumerated().filter { i, w in
            !(w.count == 1 && Rx.test(w, "[a-z]", ci: true) && !Rx.test(w, "^[ax&]$", ci: true) && !(i > 0 && before[i - 1].endsWithAsciiDigit))
        }.map { $0.element }
        return t.joined(separator: " ")
    }

    private static func jsSplit(_ text: String) -> [String] {
        let parts = text.splitOnWhitespace()
        return parts.isEmpty ? [""] : parts
    }

    /// The same item read twice: keep only the words both reads agree on at the start and end.
    public static func consensusDescription(_ a: String, _ b: String) -> String {
        let A = jsSplit(plainLetters(a)), B = jsSplit(plainLetters(b))
        func inB(_ w: String) -> Bool { B.contains { TextTools.tokenEqual($0.lowercased(), w.lowercased()) } }
        func inA(_ w: String) -> Bool { A.contains { TextTools.tokenEqual($0.lowercased(), w.lowercased()) } }
        func weak(_ w: String) -> Bool { w.count <= 3 || (!w.hasAsciiDigit && !Rx.test(w, "[aeiouy]", ci: true)) }
        var s = 0, e = A.count
        while s < e - 1, !inB(A[s]), weak(A[s]) { s += 1 }
        while e - 1 > s, !inB(A[e - 1]), weak(A[e - 1]) { e -= 1 }
        var s2 = 0, e2 = B.count
        while s2 < e2 - 1, !inA(B[s2]), weak(B[s2]) { s2 += 1 }
        while e2 - 1 > s2, !inA(B[e2 - 1]), weak(B[e2 - 1]) { e2 -= 1 }
        let x = A[s..<e].joined(separator: " "), y = B[s2..<e2].joined(separator: " ")
        let badX = looksGarbled(x), badY = looksGarbled(y)
        if badX != badY { return badY ? x : y }
        return x.utf16.count >= y.utf16.count ? x : y
    }

    // MARK: - one line

    static var vatRates: [Double] { language == "de" ? [19, 7] : language == "fr" ? [20, 10, 5.5] : [20, 5] }

    public static func parseLine(_ raw: String, known: Set<String> = []) -> ParsedLine? {
        var t = raw.splitOnWhitespace()
        // European invoices often end a line with the VAT rate as a plain "7" or "19%"
        var tailRate = 0.0
        if language != "en", t.count > 3, let last = t.last,
           let rate = Double(stripToken(last).replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")),
           vatRates.contains(rate), !Rx.test(last, "[.,][0-9]{2}$") {
            tailRate = rate
            t.removeLast()
        }
        if t.count < 2 { return nil }
        var qi = -1
        var qty: Double = 1
        var found = false
        for decimalOnly in [true, false] {
            for k in 0..<min(3, t.count) {
                if let q = quantityToken(t[k], decimalOnly: decimalOnly), q > 0 {
                    qi = k
                    qty = q
                    found = true
                    break
                }
            }
            if found { break }
        }
        if found {
            for k in 0..<qi where !isJunk(t[k]) {
                found = false
                break
            }
        }
        var qtyGuess = false
        if !found {
            qty = 1
            qtyGuess = true
            qi = -1
            while qi + 1 < t.count, isJunk(t[qi + 1]) || Rx.test(stripToken(t[qi + 1]), "^0{1,3}$") { qi += 1 }
        }

        var T: [Double] = []
        var E: [Bool] = []
        var i = t.count - 1
        while i > qi {
            if let n = numberInfo(t[i]) {
                T.insert(n.value, at: 0)
                E.insert(n.explicit, at: 0)
                i -= 1
                continue
            }
            if isJunk(t[i], trailing: T.isEmpty) && (T.isEmpty || (i - 1 > qi && numberInfo(t[i - 1]) != nil)) {
                i -= 1
                continue
            }
            break
        }
        if T.isEmpty { return nil }
        var descTokens: [String] = (qi + 1 <= i) ? Array(t[(qi + 1)...i]) : []
        if T.count > 5 {
            let k = T.count - 5
            descTokens += T[..<k].map { String(format: "%.2f", $0) }
            T.removeFirst(k)
            E.removeFirst(k)
        }

        if !found, rightToLeft, descTokens.count > 1, let q = quantityToken(descTokens[descTokens.count - 1]), q > 0,
           T.indices.contains(where: { a in T.indices.contains { b in b > a && abs(q * T[a] - T[b]) < 0.06 } }) {
            qty = q
            qtyGuess = false
            descTokens.removeLast()
        }
        var unit: Double?
        var net: Double?
        var ni = -1
        var warn = ""
        search: for a in 0..<T.count {
            for b in (a + 1)..<max(a + 1, T.count) where T[a] > 0 && abs(qty * T[a] - T[b]) < 0.06 {
                unit = T[a]
                net = T[b]
                ni = b
                break search
            }
        }
        if unit == nil {
            search2: for a in 0..<T.count {
                for b in (a + 1)..<max(a + 1, T.count) {
                    if T[a] < 0.5 || T[b] <= T[a] { continue }
                    let r = T[b] / T[a]
                    let q = (r + 0.5).rounded(.down)
                    if q >= 1 && q <= 200 && abs(r - q) < 0.002 {
                        let old = qty
                        qty = q
                        unit = T[a]
                        net = T[b]
                        ni = b
                        if q != old || qtyGuess {
                            warn = CoreText.t("Quantity was hard to read – worked out {1} from the line total. Check.", String(Int(q)))
                        }
                        if let first = descTokens.first, quantityToken(first) == q || Double(stripToken(first)) == q * 100 {
                            descTokens.removeFirst()
                        }
                        break search2
                    }
                }
            }
        }
        if unit == nil {
            if qtyGuess && T.count < 3 { return nil }
            if T.count >= 3 && T[2] > 0 && !E[0] && (E[2] || T[2] >= T[0] * qty) {
                net = T[2]
                ni = 2
                unit = Money.round2(T[2] / qty)
                warn = CoreText.t("Price was hard to read – worked out from the line total. Check.")
            } else {
                unit = T[0]
                warn = CoreText.t("Couldn't confirm this price against the line total – check the price and quantity.")
            }
            if qtyGuess { warn = CoreText.t("Quantity and price were hard to read – check this line.") }
        }

        let rawDesc = descTokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = cleanDescription(rawDesc, known: known)
        let desc = cleaned.isEmpty ? rawDesc : cleaned
        if desc.isEmpty || !Rx.test(desc, "\\p{L}{2}") { return nil }

        var vat = 0.0
        let after: [Double] = ni >= 0 && ni + 1 < T.count ? Array(T[(ni + 1)...]) : []
        let rates = vatRates
        for v in after where rates.contains(v) {
            vat = v
            break
        }
        if vat == 0, let n = net, n != 0, let last = after.last, last > 0, let rate = rates.first, abs(last - n * rate / 100) < 0.03 { vat = rate }
        if vat == 0 { vat = tailRate }
        return ParsedLine(qty: qty, desc: desc, raw: rawDesc, unit: unit ?? 0, vat: vat, warn: warn)
    }

    // MARK: - the whole invoice

    private static func printedAmount(_ text: String, _ pattern: String) -> Double? {
        let found = Rx.group(text, pattern, ci: true)
        if found.isEmpty { return nil }
        let digits = found.filter { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," }
        if Money.currency.decimals == 0 || Set(digits.filter { $0 == "." || $0 == "," }).count == 2 { return Money.parse(digits) ?? 0 }
        let cleaned = digits.firstCommaToDot.filter { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "-" }
        return leadingNumber(cleaned) ?? 0
    }

    /// The words that mark totals, invoice numbers and dates. English invoices use exactly the English words;
    /// other languages add their own words to the English ones.
    enum Words {
        private static func pick(_ en: String, _ others: [String: String]) -> String {
            guard language != "en", let extra = others[language] else { return en }
            // inner brackets must not capture: the number is the only thing captured
            return en + "|" + extra.replacingOccurrences(of: "(", with: "(?:")
        }
        static var skip: String {
            pick("total|invoice\\s*no|account|page\\s*[0-9]|quantity\\s+desc", [
                "de": "summe|gesamt|rechnungs?\\s*(nr|nummer)|seite\\s*[0-9]|menge\\s+(bezeichnung|artikel)|netto|brutto|mwst|ust",
                "fr": "montant|facture\\s*(n°|no|num)|quantit[ée]\\s+d[ée]sign|sous-total|total\\s*h\\.?t|ttc|tva",
                "ar": "المجموع|الإجمالي|الاجمالي|اجمالي|رقم الفاتورة|الكمية|الصافي|المبلغ|الضريبة",
                "ckb": "کۆی گشتی|کۆی|ژمارەی پسوولە|ژمارەی وەسڵ|بڕ\\s|کۆ\\s|باج"
            ])
        }
        static var company: String {
            pick("\\b(ltd|limited|wholesale|distribution|foods?)\\b", [
                "de": "\\b(gmbh|ag|kg|großhandel|grosshandel|lebensmittel)\\b",
                "fr": "\\b(sarl|sas|eurl|sa|alimentaire|grossiste)\\b",
                "ar": "شركة|مؤسسة|مخازن",
                "ckb": "کۆمپانیا|کۆمپانیای|کۆگا"
            ])
        }
        static var date: String {
            pick("invoice\\s*date", [
                "de": "rechnungsdatum|datum",
                "fr": "date\\s*(de\\s*)?(la\\s*)?facture|date",
                "ar": "تاريخ الفاتورة|التاريخ",
                "ckb": "بەروار"
            ])
        }
        static var invoiceNo: String {
            pick("invoice\\s*no", [
                "de": "rechnungs?\\s*(nr|nummer)",
                "fr": "facture\\s*(n°|no|num[ée]ro)",
                "ar": "رقم الفاتورة",
                "ckb": "ژمارەی پسوولە|ژمارەی وەسڵ|ژمارەی فاتورە"
            ])
        }
        static var net: String {
            pick("total\\s*net\\s*amount", [
                "de": "nettobetrag|summe\\s*netto|gesamt\\s*netto|netto\\s*summe",
                "fr": "total\\s*h\\.?t\\.?|montant\\s*h\\.?t\\.?",
                "ar": "المجموع قبل الضريبة|المبلغ الصافي|الصافي",
                "ckb": "کۆی بێ باج"
            ])
        }
        static var total: String {
            pick("invoice\\s*total", [
                "de": "gesamtbetrag|rechnungsbetrag|endbetrag|summe\\s*brutto",
                "fr": "total\\s*ttc|net\\s*à\\s*payer",
                "ar": "الإجمالي|الاجمالي|المجموع الكلي|المبلغ المستحق|المجموع",
                "ckb": "کۆی گشتی"
            ])
        }
    }

    public static func parseInvoice(_ text: String, known: Set<String> = []) -> ParsedInvoice {
        let text = westernDigits(text)
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var out: [ParsedLine] = []
        for line in lines {
            if Rx.test(line, Words.skip, ci: true) { continue }
            if let parsed = parseLine(line, known: known) { out.append(parsed) }
        }
        let supplierLine = lines.first { Rx.test($0, Words.company, ci: true) && !Rx.test($0, "fried chicken|fc\\b", ci: true) } ?? ""
        let supplier = String(Rx.replace(supplierLine, "[^\\p{L}0-9&().,' -]", "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        var date = Rx.group(text, "(?:" + Words.date + ")[^0-9\\n]{0,10}([0-9]{1,2}[/.\\-][0-9]{1,2}[/.\\-][0-9]{2,4})", ci: true)
        if date.isEmpty { date = Rx.group(text, language == "en" ? "([0-9]{2}/[0-9]{2}/[0-9]{4})" : "([0-9]{2}[/.][0-9]{2}[/.][0-9]{4})") }
        return ParsedInvoice(
            supplier: supplier,
            invNo: Rx.group(text, "(?:" + Words.invoiceNo + ")\\.?[^0-9\\n]{0,10}([0-9]{3,})", ci: true),
            date: date,
            printedNet: printedAmount(text, "(?:" + Words.net + ")[^0-9\\n]{0,40}([0-9.,]+)"),
            printedTotal: printedAmount(text, "(?:" + Words.total + ")[^0-9\\n]{0,40}([0-9.,]+)"),
            lines: out
        )
    }

    // MARK: - double check: merge two independent reads

    /// The supplier name, tidied, preferring one the user already has.
    public static func bestSupplier(_ candidates: [String], known: [String]) -> String {
        let cands = candidates.map { TextTools.cleanSupplier($0) }.filter { !$0.isEmpty }
        var best: String?
        var bestScore = 0.0
        for c in cands {
            for k in known {
                let s = TextTools.similarity(c, k)
                if s > bestScore {
                    bestScore = s
                    best = k
                }
            }
        }
        if let best, bestScore >= 0.5 { return best }
        var longest = ""
        for c in cands where c.utf16.count > longest.utf16.count { longest = c }
        return longest
    }

    private static func sum(_ lines: [ParsedLine]) -> Double {
        Money.round2(lines.reduce(0) { $0 + $1.qty * $1.unit })
    }

    public static func mergeReads(_ A: ParsedInvoice, _ B: ParsedInvoice, knownSuppliers: [String] = []) -> ParsedInvoice {
        var used = Set<Int>()
        var out: [ParsedLine] = []
        for a in A.lines {
            var bi = -1
            var bs = 0.0
            for (i, b) in B.lines.enumerated() where !used.contains(i) {
                let s = TextTools.similarity(a.desc, b.desc)
                if s > bs {
                    bs = s
                    bi = i
                }
            }
            if bi >= 0 && bs >= 0.4 {
                used.insert(bi)
                let b = B.lines[bi]
                let same = abs(a.qty - b.qty) < 0.001 && abs(a.unit - b.unit) < 0.005
                let desc = consensusDescription(a.desc, b.desc)
                var line: ParsedLine
                if same {
                    line = a
                    line.reads = 2
                    line.warn = (!a.warn.isEmpty && !b.warn.isEmpty) ? a.warn : ""
                } else if a.warn.isEmpty && !b.warn.isEmpty {
                    line = a
                    line.reads = 1
                } else if !a.warn.isEmpty && b.warn.isEmpty {
                    line = b
                    line.reads = 1
                } else {
                    line = a
                    line.reads = 1
                    line.disagree = true
                    line.altQty = b.qty
                    line.altUnit = b.unit
                }
                line.desc = desc
                out.append(line)
            } else {
                var line = a
                line.reads = 1
                out.append(line)
            }
        }
        let printedNet = (A.printedNet ?? 0) != 0 ? A.printedNet : B.printedNet
        for (i, b) in B.lines.enumerated() where !used.contains(i) && b.warn.isEmpty {
            if A.lines.contains(where: { TextTools.similarity($0.desc, b.desc) >= 0.3 }) { continue }
            let copiesALine = A.lines.contains { abs($0.qty - b.qty) < 0.001 && abs($0.unit - b.unit) < 0.005 }
            if copiesALine {
                // keep it only if the printed total says a line is missing and this is exactly it
                guard let target = printedNet, target != 0,
                      abs(sum(out) - target) > 0.05,
                      abs(sum(out) + Money.round2(b.qty * b.unit) - target) <= 0.05 else { continue }
            }
            var line = b
            line.reads = 1
            line.onlySecondRead = true
            line.desc = plainLetters(line.desc)
            out.append(line)
        }
        let printedTotal = (A.printedTotal ?? 0) != 0 ? A.printedTotal : B.printedTotal

        func finish(_ lines: [ParsedLine]) -> ParsedInvoice {
            let lines = lines.map { line -> ParsedLine in
                var copy = line
                copy.desc = plainLetters(copy.desc)
                return copy
            }
            return ParsedInvoice(supplier: bestSupplier([A.supplier, B.supplier], known: knownSuppliers),
                          invNo: A.invNo.isEmpty ? B.invNo : A.invNo,
                          date: A.date.isEmpty ? B.date : A.date,
                          printedNet: printedNet, printedTotal: printedTotal, lines: lines)
        }

        // if one read on its own matches the printed total exactly, trust it
        if let target = printedNet, target != 0, abs(sum(out) - target) > 0.05 {
            for (own, other) in [(A, B), (B, A)] where !own.lines.isEmpty && abs(sum(own.lines) - target) <= 0.05 {
                let lines = own.lines.map { line -> ParsedLine in
                    var copy = line
                    let agreed = other.lines.contains { o in
                        TextTools.similarity(o.desc, line.desc) >= 0.4 && abs(o.qty - line.qty) < 0.001 && abs(o.unit - line.unit) < 0.005
                    }
                    copy.reads = agreed ? 2 : 1
                    return copy
                }
                return finish(lines)
            }
        }
        return finish(out)
    }

    // MARK: - rebuilding rows from positions

    /// Straightens a tilted photo, then puts pieces of text that sit on the same line together, left to right.
    public static func rows(from pieces: [TextPiece]) -> String {
        let items = pieces.filter { piece in
            !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (piece.confidence >= 0.3 || piece.text.hasAsciiDigit)
        }
        if items.isEmpty { return "" }
        let angles = items.filter { $0.width > 3 * $0.height }.map { $0.angle }.sorted()
        var angle = angles.isEmpty ? 0 : angles[angles.count >> 1]
        if abs(angle) > 0.35 { angle = 0 }
        let c = cos(angle), sn = sin(angle)

        struct Placed {
            let text: String
            let x: Double
            let y: Double
            let h: Double
            let order: Int
        }
        var placed: [Placed] = items.enumerated().map { index, piece in
            Placed(text: piece.text.trimmingCharacters(in: .whitespacesAndNewlines),
                   x: piece.x * c + piece.y * sn,
                   y: -piece.x * sn + piece.y * c,
                   h: piece.height == 0 ? 10 : piece.height,
                   order: index)
        }
        let heights = placed.map { $0.h }.sorted()
        var medianHeight = heights[heights.count >> 1]
        if medianHeight == 0 { medianHeight = 10 }
        placed.sort { $0.y != $1.y ? $0.y < $1.y : $0.order < $1.order }

        var rows: [(y: Double, items: [Placed])] = []
        for p in placed {
            if let last = rows.indices.last, abs(p.y - rows[last].y) <= medianHeight * 0.55 {
                rows[last].items.append(p)
                rows[last].y += (p.y - rows[last].y) / Double(rows[last].items.count)
            } else {
                rows.append((p.y, [p]))
            }
        }
        return rows.map { row in
            row.items.enumerated()
                .sorted { $0.element.x != $1.element.x ? (rightToLeft ? $0.element.x > $1.element.x : $0.element.x < $1.element.x) : $0.offset < $1.offset }
                .map { $0.element.text }
                .joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
