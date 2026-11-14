import WidgetKit
import SwiftUI
import ChargeCheckCore

/// The home screen and lock screen widget: how much you owe, and to which suppliers.
@main
struct ChargeCheckWidgetBundle: WidgetBundle {
    var body: some Widget {
        OwedWidget()
    }
}

struct OwedEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct OwedProvider: TimelineProvider {
    static var group: String {
        Bundle.main.object(forInfoDictionaryKey: "CCAppGroup") as? String ?? "group.com.rjapps.invoicepricechecker"
    }

    static func load() -> WidgetSnapshot? {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
              let data = try? Data(contentsOf: folder.appendingPathComponent("widget.json")) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static let example = WidgetSnapshot(totalOwed: 1240.50, paidThisWeek: 300,
                                        suppliers: [.init(name: "Apex Foods", owed: 860.50, openInvoices: 3),
                                                    .init(name: "Bravo Meats", owed: 380, openInvoices: 1)],
                                        currency: "GBP", updated: Date())

    func placeholder(in context: Context) -> OwedEntry {
        OwedEntry(date: Date(), snapshot: Self.example)
    }

    func getSnapshot(in context: Context, completion: @escaping (OwedEntry) -> Void) {
        completion(OwedEntry(date: Date(), snapshot: context.isPreview ? Self.example : (Self.load() ?? Self.example)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OwedEntry>) -> Void) {
        // the app refreshes the widget whenever something changes; this is only a safety net
        let next = Calendar.current.date(byAdding: .hour, value: 6, to: Date()) ?? Date()
        completion(Timeline(entries: [OwedEntry(date: Date(), snapshot: Self.load())], policy: .after(next)))
    }
}

struct OwedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ChargeCheckOwed", provider: OwedProvider()) { entry in
            OwedView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "chargecheck://suppliers"))
        }
        .configurationDisplayName("What you owe")
        .description("How much you owe your suppliers, and to whom.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

struct OwedView: View {
    let entry: OwedEntry
    @Environment(\.widgetFamily) private var family

    private func money(_ value: Double) -> String {
        Money.currency = Currency.named(entry.snapshot?.currency)
        return Money.format(value)
    }

    var body: some View {
        if entry.snapshot?.locked == true {
            VStack(alignment: .leading, spacing: 4) {
                Text("ChargeCheck Pro")
                    .font(.caption.weight(.semibold))
                Text("The widget is part of Pro. Open ChargeCheck to see the plans.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if let snapshot = entry.snapshot {
            switch family {
            case .accessoryInline:
                Text("Owed \(money(snapshot.totalOwed))")
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text("You owe")
                        .font(.caption2)
                    Text(money(snapshot.totalOwed))
                        .font(.headline)
                    if let top = snapshot.suppliers.first {
                        Text("\(top.name) \(money(top.owed))")
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            case .systemSmall:
                VStack(alignment: .leading, spacing: 4) {
                    Label("You owe", systemImage: "shippingbox.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(money(snapshot.totalOwed))
                        .font(.title2.weight(.heavy))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    ForEach(snapshot.suppliers.prefix(2), id: \.name) { line in
                        HStack {
                            Text(line.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(money(line.owed)).fontWeight(.semibold)
                        }
                        .font(.caption2)
                    }
                }
            default:
                let rows = family == .systemLarge ? 6 : 3
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("You owe")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(money(snapshot.totalOwed))
                                .font(.title.weight(.heavy))
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("Paid this week")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(money(snapshot.paidThisWeek))
                                .font(.caption.weight(.semibold))
                        }
                    }
                    if snapshot.suppliers.isEmpty {
                        Text("Nothing to pay")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                    ForEach(snapshot.suppliers.prefix(rows), id: \.name) { line in
                        HStack {
                            Text(line.name)
                                .lineLimit(1)
                            if line.openInvoices > 0 {
                                Text(line.openInvoices == 1 ? LocalizedStringKey("1 invoice") : LocalizedStringKey("\(line.openInvoices) invoices"))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Text(money(line.owed))
                                .fontWeight(.semibold)
                        }
                        .font(.footnote)
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("ChargeCheck")
                    .font(.caption.weight(.semibold))
                Text("Open the app to see what you owe your suppliers.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
