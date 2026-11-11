import Foundation

/// Finds the weight or volume in an item name ("10kg", "2.5 L", "4x500g", "١٠ كغم") so a line that
/// matched the right product in the wrong pack size can be pointed out.
public enum PackSize {
    public enum Kind: Sendable { case weight, volume }

    public struct Size: Equatable, Sendable {
        public let kind: Kind
        /// Grams or millilitres.
        public let amount: Double
        /// As written, e.g. "10kg".
        public let label: String
    }

    /// Unit → (kind, how many grams or millilitres it is).
    private static let units: [String: (Kind, Double)] = [
        "kg": (.weight, 1000), "kgs": (.weight, 1000), "kilo": (.weight, 1000), "kilos": (.weight, 1000),
        "g": (.weight, 1), "gr": (.weight, 1), "gm": (.weight, 1), "grm": (.weight, 1), "gms": (.weight, 1),
        "l": (.volume, 1000), "lt": (.volume, 1000), "ltr": (.volume, 1000), "ltrs": (.volume, 1000),
        "litre": (.volume, 1000), "litres": (.volume, 1000), "liter": (.volume, 1000), "liters": (.volume, 1000),
        "ml": (.volume, 1), "cl": (.volume, 10),
        // Arabic and Kurdish (as TextTools.norm writes them)
        "كغم": (.weight, 1000), "كجم": (.weight, 1000), "كغ": (.weight, 1000), "كيلو": (.weight, 1000), "كيلوغرام": (.weight, 1000),
        "غم": (.weight, 1), "غرام": (.weight, 1), "جم": (.weight, 1), "گرام": (.weight, 1),
        "لتر": (.volume, 1000), "ليتر": (.volume, 1000), "مل": (.volume, 1)
    ]

    /// Every weight and volume written in a name.
    public static func sizes(in text: String) -> [Size] {
        var words: [String] = []
        for word in TextTools.norm(text).split(separator: " ") {
            // "4x2.5kg" is four packs of 2.5kg: look at each part
            for part in word.split(separator: "x") where !part.isEmpty { words.append(String(part)) }
        }
        var found: [Size] = []
        var index = 0
        while index < words.count {
            var word = words[index]
            while word.hasSuffix(".") { word.removeLast() }
            let number = String(word.prefix { $0.isASCII && ($0.isNumber || $0 == ".") })
            var unit = String(word.dropFirst(number.count))
            var used = 1
            if !number.isEmpty, unit.isEmpty, index + 1 < words.count {
                // "10 kg": the unit is the next word
                var next = words[index + 1]
                while next.hasSuffix(".") { next.removeLast() }
                if units[next] != nil {
                    unit = next
                    used = 2
                }
            }
            if let value = Double(number), value > 0, let (kind, factor) = units[unit] {
                let shown = value == value.rounded() ? String(Int(value)) : String(value)
                found.append(Size(kind: kind, amount: (value * factor * 100).rounded() / 100, label: shown + unit))
                index += used
            } else {
                index += 1
            }
        }
        return found
    }

    /// The two sizes, when the invoice line and the price-list item each name exactly one weight (or one volume)
    /// and they are not the same. nil when they agree or when either side doesn't say.
    public static func mismatch(invoice: String, item: String) -> (invoice: String, item: String)? {
        let a = sizes(in: invoice), b = sizes(in: item)
        for kind in [Kind.weight, Kind.volume] {
            let x = a.filter { $0.kind == kind }, y = b.filter { $0.kind == kind }
            guard x.count == 1, y.count == 1 else { continue }
            if abs(x[0].amount - y[0].amount) > 0.001 { return (x[0].label, y[0].label) }
        }
        return nil
    }
}
