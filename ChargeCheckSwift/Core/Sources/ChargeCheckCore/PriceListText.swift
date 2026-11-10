import Foundation

/// Reads a pasted price list: one item per line with its price at the end,
/// e.g. "Chicken wings 10kg £15.00" (from WhatsApp, an email or a spreadsheet).
public enum PriceListText {
    public struct Row: Equatable, Sendable {
        public var name: String
        public var price: Double
    }

    private static let lineRegex = try? NSRegularExpression(
        pattern: "^(.*?[A-Za-z].*?)[\\s,;:\\t-]+£?\\s*(\\d{1,4}[.,]\\d{2})\\s*(?:[A-Za-z()/ ]{0,12})?$")

    public static func parse(_ text: String) -> [Row] {
        guard let regex = lineRegex else { return [] }
        var rows: [Row] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let m = regex.firstMatch(in: line, range: range),
                  let nameRange = Range(m.range(at: 1), in: line),
                  let priceRange = Range(m.range(at: 2), in: line) else { continue }
            var name = String(line[nameRange])
            while let last = name.last, " ,;:-–£\t".contains(last) { name.removeLast() }
            name = name.split(whereSeparator: { $0 == " " }).joined(separator: " ")
            guard name.count >= 3, let price = Money.parse(String(line[priceRange])) else { continue }
            rows.append(Row(name: name, price: Money.round2(price)))
        }
        return rows
    }
}
