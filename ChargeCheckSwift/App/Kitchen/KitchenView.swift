import ChargeCheckCore
import SwiftData
import SwiftUI

/// The kitchen screen: open tickets for one station, oldest first, tapped along as they're made.
/// Several screens can show the same station; their taps merge (`Kitchen.status`).
struct KitchenView: View {
    @ObservedObject private var kitchen = KitchenStore.shared
    @State private var settings = false
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let open = Kitchen.open(kitchen.tickets, events: kitchen.events, station: kitchen.station)
        ScrollView {
            if !kitchen.isOn {
                ContentUnavailableView {
                    Label("The kitchen is off", systemImage: "frying.pan")
                } description: {
                    Text("Turn it on in settings and sales from the till send their food and drinks here.")
                } actions: {
                    Button("Settings") { settings = true }
                }
            } else if open.isEmpty {
                ContentUnavailableView("Nothing to make", systemImage: "checkmark.circle",
                                       description: Text("New orders appear here as the till takes them."))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(open) { ticket in
                    TicketCard(ticket: ticket, status: kitchen.status(ticket))
                }
            }
            .padding()
        }
        .navigationTitle(kitchen.station)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Station", selection: Binding(get: { kitchen.station }, set: { kitchen.station = $0 })) {
                    ForEach(kitchen.stations, id: \.self) { Text($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { settings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
        .onReceive(tick) { _ in kitchen.refresh() }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            kitchen.refresh()
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(isPresented: $settings) { KitchenSettings() }
    }
}

private struct TicketCard: View {
    let ticket: KitchenTicket
    let status: TicketStatus
    @ObservedObject private var kitchen = KitchenStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ticket.label).font(.title3.weight(.bold))
                if ticket.addOn {
                    Text("Add-on").font(.caption.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                }
                Spacer()
                Text(age).font(.subheadline.monospacedDigit()).foregroundStyle(minutes >= 15 ? .red : .secondary)
            }
            ForEach(Array(ticket.items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.qty.formatted()) × \(item.name)").font(.headline)
                    ForEach(item.notes, id: \.self) { Text("– " + $0).font(.subheadline).foregroundStyle(.orange) }
                }
            }
            Button {
                kitchen.mark(ticket, next)
            } label: {
                Text(buttonTitle).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(status == .ready ? .green : (status == .preparing ? .orange : .blue))
            .controlSize(.large)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            Button("Back to preparing") { kitchen.mark(ticket, .preparing, recall: true) }
            Button("Cancel", role: .destructive) { kitchen.mark(ticket, .cancelled) }
        }
    }

    private var minutes: Int {
        guard let at = ISO8601DateFormatter().date(from: ticket.at) else { return 0 }
        return max(0, Int(Date().timeIntervalSince(at) / 60))
    }

    private var age: String { String(localized: "\(minutes) min") }

    private var next: TicketStatus {
        switch status {
        case .new: return .preparing
        case .preparing: return .ready
        default: return .collected
        }
    }

    private var buttonTitle: String {
        switch status {
        case .new: return String(localized: "Start")
        case .preparing: return String(localized: "Ready")
        default: return String(localized: "Collected")
        }
    }
}

private struct KitchenSettings: View {
    @ObservedObject private var kitchen = KitchenStore.shared
    @Query private var prices: [StoredPrice]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let categories = Array(Set(prices.map { $0.item.cat }.filter { !$0.isEmpty })).sorted()
        NavigationStack {
            Form {
                Section {
                    Toggle("Send sales to the kitchen", isOn: Binding(get: { kitchen.isOn }, set: { kitchen.isOn = $0 }))
                } footer: {
                    Text("Every till sale sends its items to the station of their category. Turn it on on each till.")
                }
                Section {
                    ForEach(categories, id: \.self) { category in
                        LabeledContent(category) {
                            TextField(Kitchen.defaultStation, text: Binding(
                                get: { kitchen.routing[category] ?? "" },
                                set: { value in
                                    var r = kitchen.routing
                                    let v = value.trimmingCharacters(in: .whitespaces)
                                    r[category] = v.isEmpty ? nil : v
                                    kitchen.routing = r
                                }))
                            .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text("Which station makes each category")
                } footer: {
                    Text("Leave empty for the kitchen. Type Bar for drinks, for example.")
                }
            }
            .navigationTitle("Kitchen")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
