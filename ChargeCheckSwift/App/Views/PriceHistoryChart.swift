import SwiftUI
import Charts
import ChargeCheckCore

/// What suppliers charged for one item over time, against the agreed price.
struct PriceHistoryChart: View {
    let points: [PricePoint]
    let agreed: Double

    private var summary: String {
        guard let first = points.first, let last = points.last else { return "" }
        let low = points.map { $0.unit }.min() ?? last.unit
        let high = points.map { $0.unit }.max() ?? last.unit
        var text = "Bought \(points.count == 1 ? "once" : "\(points.count) times") · last \(Money.format(last.unit)) on \(last.label)"
        if points.count > 1 {
            text += " · lowest \(Money.format(low)), highest \(Money.format(high))"
            let change = Money.round2(last.unit - first.unit)
            if abs(change) > 0.005 { text += " · \(change > 0 ? "up" : "down") \(Money.format(abs(change))) since \(first.label)" }
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Charged", point.unit))
                        .interpolationMethod(.stepEnd)
                    PointMark(x: .value("Date", point.date), y: .value("Charged", point.unit))
                        .foregroundStyle(point.unit > agreed + 0.005 ? Color.red : Color.accentColor)
                }
                if agreed > 0 {
                    RuleMark(y: .value("Your price", agreed))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .leading) {
                            Text("Your price \(Money.format(agreed))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(Money.format(amount)) }
                    }
                }
            }
            .frame(height: 170)
            .accessibilityLabel("Price history")
            .accessibilityValue(summary)
            Text(summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
