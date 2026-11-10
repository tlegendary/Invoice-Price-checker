import Foundation

public enum Money {
    /// Round to pennies.
    public static func round2(_ value: Double) -> Double {
        ((value + Double.ulpOfOne) * 100).rounded() / 100
    }

    /// "£12.50" / "-£3.00"
    public static func format(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        return sign + "£" + String(format: "%.2f", abs(value))
    }

    /// Reads "£12.50", "12,50", " 7 " … Returns nil when there is no number.
    public static func parse(_ text: String) -> Double? {
        let swapped = text.replacingOccurrences(of: ",", with: ".")
        let cleaned = swapped.filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }
}
