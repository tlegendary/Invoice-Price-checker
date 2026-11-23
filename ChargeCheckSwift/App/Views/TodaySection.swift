import ChargeCheckCore
import SwiftUI

/// Home's "Today" card: the till's takings since the day was last closed (the same figures as the end-of-day
/// report), how it was paid, and what's running low. Shown once the till is in use.
struct TodaySection: View {
    let items: [PriceItem]
    let entries: [HistoryEntry]
    @ObservedObject private var till = TillStore.shared

    var body: some View {
        let shop = LiveSettings.shared.shop
        let report = till.current(shop: shop)
        let levels = till.levels(items: items, shop: shop, invoices: entries)
        let today = TodaySummary(report: report, levels: levels)
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                FigureTile(title: "Takings", value: Money.format(today.takings),
                           note: today.sales == 1 ? String(localized: "1 sale") : String(localized: "\(today.sales) sales"),
                           colour: .primary)
                FigureTile(title: "Refunds", value: "\(today.refunds)", note: "",
                           colour: today.refunds > 0 ? .orange : .primary)
                FigureTile(title: "Cash", value: Money.format(today.cash), note: "", colour: .primary)
                FigureTile(title: "Card", value: Money.format(today.card),
                           note: today.other > 0.005 ? String(localized: "+ \(Money.format(today.other)) other") : "",
                           colour: .primary)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
            if today.lowCount > 0 {
                NavigationLink {
                    StockView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(today.lowCount == 1 ? String(localized: "1 item running low")
                              : String(localized: "\(today.lowCount) items running low"),
                              systemImage: "shippingbox.and.arrow.backward")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(lowLine(today))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        } header: {
            Text(today.quiet ? String(localized: "Today · no sales yet") : String(localized: "Today"))
        } footer: {
            Text("Since the day was last closed on this till.")
        }
    }

    private func lowLine(_ today: TodaySummary) -> String {
        let names = today.low.map { "\($0.name) (\($0.onHand.formatted()))" }.joined(separator: ", ")
        let more = today.lowCount - today.low.count
        return more > 0 ? names + " " + String(localized: "and \(more) more") : names
    }
}
