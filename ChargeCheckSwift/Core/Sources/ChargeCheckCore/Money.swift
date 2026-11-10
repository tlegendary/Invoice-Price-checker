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

    /// Round to the currency's smallest unit (pennies, cents; whole dinars).
    public static func round2(_ value: Double) -> Double {
        ((value + Double.ulpOfOne) * 100).rounded() / 100
    }

    /// "£12.50", "12,50 €", "25,000 IQD" / "-£3.00"
    public static func format(_ value: Double) -> String {
        let c = currency
        let sign = value < 0 ? "-" : ""
        var number = String(format: "%.\(c.decimals)f", abs(value))
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
            kept.removeAll { $0 == "." || $0 == "," }
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
