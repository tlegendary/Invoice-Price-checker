import Foundation

/// How money is written: the symbol, where it goes, and how many decimals the currency uses.
public struct Currency: Equatable, Sendable, Identifiable {
    public var code: String
    public var symbol: String
    public var decimals: Int
    public var symbolAfter: Bool
    public var decimalComma: Bool
    public var id: String { code }

    public static let gbp = Currency(code: "GBP", symbol: "£", decimals: 2, symbolAfter: false, decimalComma: false)
    public static let eur = Currency(code: "EUR", symbol: "€", decimals: 2, symbolAfter: true, decimalComma: true)
    public static let usd = Currency(code: "USD", symbol: "$", decimals: 2, symbolAfter: false, decimalComma: false)
    public static let iqd = Currency(code: "IQD", symbol: "IQD", decimals: 0, symbolAfter: true, decimalComma: false)
    public static let all: [Currency] = [.gbp, .eur, .usd, .iqd]

    public static func named(_ code: String?) -> Currency {
        all.first { $0.code == code } ?? .gbp
    }
}

public enum Money {
    /// The currency the user chose (set by the app at start-up and when the setting changes).
    public static var currency: Currency = .gbp

    /// Called each time an amount is written out. The app uses it so a screen showing amounts redraws straight away
    /// when the currency (or a supplier's currency) changes, instead of after the app is opened again.
    public static var willFormat: (() -> Void)?

    /// Round to two decimal places (pennies, cents), halves away from zero: 4.185 → 4.19, −1.005 → −1.01.
    /// Whole-dinar amounts have nothing after the point, so they come back unchanged.
    ///
    /// Amounts are `Double`s, so a half penny the app works out (0.25 kg × £16.74 = 4.185) is often stored a hair
    /// below the half (4.18499999…). The old rounding added `Double.ulpOfOne`, which is too small to lift anything of
    /// 2 or more over the half, so about 1 in 22 half pennies (and about 1 in 60 weighed line totals) lost a penny,
    /// and minus amounts rounded differently from the same amount plus. A value within a few steps of Double's
    /// precision of a half penny is now treated as that half penny; every other value rounds exactly as before.
    ///
    /// Why that can't catch a real amount by mistake: everything the app rounds comes from quantities with at most
    /// three decimals, prices with at most three and VAT rates with at most one, so a real amount that isn't a half
    /// penny is at least 0.0001 of a penny away from one – a thousand times more than the 0.0000001 allowed here.
    /// Already saved invoices and payments keep their saved amounts; only new calculations use this.
    public static func round2(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let pennies = value * 100
        // beyond this a Double can't hold fractions of a penny, so there is nothing to decide
        guard abs(pennies) < 1e15 else { return pennies.rounded() / 100 }
        let whole = pennies.rounded(.towardZero)
        // how far arithmetic can push a stored half penny off the half: a few steps of precision at this size
        let slack = min(0.001, max(1e-7, pennies.ulp * 8))
        let rounded = abs(abs(pennies - whole) - 0.5) <= slack ? whole + (pennies < 0 ? -1 : 1) : pennies.rounded()
        // never "-0": a tiny minus that rounds to nothing is plain zero (backups would otherwise save "-0")
        return rounded == 0 ? 0 : rounded / 100
    }

    /// "£12.50", "12,50 €", "25,000 IQD" / "-£3.00"
    public static func format(_ value: Double) -> String {
        format(value, in: currency)
    }

    /// The same in another currency (a supplier who invoices in dollars while you keep accounts in dinars).
    public static func format(_ value: Double, code: String?) -> String {
        format(value, in: code.flatMap { code in Currency.all.first { $0.code == code } } ?? currency)
    }

    public static func format(_ value: Double, in c: Currency) -> String {
        willFormat?()
        var number = String(format: "%.\(c.decimals)f", abs(value))
        // "-0 IQD": a tiny minus that rounds to nothing has no sign
        let sign = value < 0 && number.contains(where: { $0 != "0" && $0 != "." }) ? "-" : ""
        if c.decimals == 0 {
            // whole amounts are long: group the thousands
            var grouped = ""
            for (i, ch) in number.reversed().enumerated() {
                if i > 0 && i % 3 == 0 { grouped.append(",") }
                grouped.append(ch)
            }
            number = String(grouped.reversed())
        } else if c.decimalComma {
            number = number.replacingOccurrences(of: ".", with: ",")
        }
        return c.symbolAfter ? sign + number + " " + c.symbol : sign + c.symbol + number
    }

    /// Reads "£12.50", "12,50", "1.234,50", "25,000", "٢٥٫٥٠", " 7 " … Returns nil when there is no number.
    public static func parse(_ text: String) -> Double? {
        let plain = InvoiceParser.westernDigits(text)
        var kept = plain.filter { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," || $0 == "-" }
        let separators = kept.filter { $0 == "." || $0 == "," }
        if currency.decimals == 0 {
            // whole-number currencies: separators group thousands – unless the last one has just 1–2 digits after it
            // ("1,808.68" on a dollar invoice read by someone who keeps prices in dinars)
            if let last = kept.lastIndex(where: { $0 == "." || $0 == "," }),
               (1...2).contains(kept.distance(from: kept.index(after: last), to: kept.endIndex)) {
                let tail = kept[kept.index(after: last)...]
                kept = String(kept[..<last].filter { $0 != "." && $0 != "," }) + "." + tail
            } else {
                kept.removeAll { $0 == "." || $0 == "," }
            }
        } else if Set(separators).count == 2, let last = kept.lastIndex(where: { $0 == "." || $0 == "," }) {
            // "1.234,50" or "1,234.50": the last mark is the decimal point, the others group thousands
            let decimalMark = kept[last]
            kept = String(kept.enumerated().compactMap { i, ch -> Character? in
                if ch == "." || ch == "," { return kept.index(kept.startIndex, offsetBy: i) == last ? "." : nil }
                return ch
            })
            _ = decimalMark
        } else if separators.count > 1 {
            // "1.234.567" – only grouping
            kept.removeAll { $0 == "." || $0 == "," }
        } else {
            kept = kept.replacingOccurrences(of: ",", with: ".")
        }
        guard !kept.isEmpty, let value = Double(kept), value.isFinite else { return nil }
        return value
    }
}
