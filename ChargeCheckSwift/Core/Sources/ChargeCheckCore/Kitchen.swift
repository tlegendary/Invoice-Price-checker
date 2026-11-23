import Foundation

/// One dish or drink on a kitchen ticket.
public struct TicketItem: Codable, Equatable, Sendable {
    public var name: String
    public var qty: Double
    /// Options chosen at the till ("no onions", "large").
    public var notes: [String]
    public init(name: String, qty: Double, notes: [String] = []) {
        self.name = name
        self.qty = qty
        self.notes = notes
    }
}

public enum TicketStatus: String, Codable, CaseIterable, Sendable {
    case new, preparing, ready, collected, cancelled

    /// The order statuses move in. A later status always wins over an earlier one, whichever screen saw it first.
    var rank: Int {
        switch self {
        case .new: return 0
        case .preparing: return 1
        case .ready: return 2
        case .collected: return 3
        case .cancelled: return 4
        }
    }
}

/// What the kitchen gets for one station: a whole order, or only what was added to it later.
public struct KitchenTicket: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// The sale or open tab it belongs to.
    public var order: String
    /// Table, name or receipt number, as shown on the ticket.
    public var label: String
    public var station: String
    public var items: [TicketItem]
    /// Added to an order already sent (only the new items are on it).
    public var addOn: Bool
    public var at: String

    public init(id: String = UUID().uuidString, order: String, label: String, station: String, items: [TicketItem],
                addOn: Bool = false, at: String) {
        self.id = id
        self.order = order
        self.label = label
        self.station = station
        self.items = items
        self.addOn = addOn
        self.at = at
    }
}

/// A change of status, made on one screen. Kept, never edited: screens share their events and each works out the
/// same status from all of them, so two iPads tapping the same ticket can't lose either change.
public struct TicketEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var ticket: String
    public var status: TicketStatus
    /// Puts a ready or collected ticket back on the screen (a mistake, a dish sent back).
    public var recall: Bool
    public var device: String
    public var at: String

    public init(id: String = UUID().uuidString, ticket: String, status: TicketStatus, recall: Bool = false, device: String, at: String) {
        self.id = id
        self.ticket = ticket
        self.status = status
        self.recall = recall
        self.device = device
        self.at = at
    }
}

public enum Kitchen {
    /// Category → station ("Drinks" → "Bar"); anything else goes to `defaultStation`.
    public static let defaultStation = "Kitchen"

    /// The tickets for an order: one per station, with only the items not sent before (`alreadySent` counts by name).
    public static func tickets(order: String, label: String, lines: [(name: String, qty: Double, category: String?, notes: [String])],
                               routing: [String: String], alreadySent: [String: Double] = [:], at: String) -> [KitchenTicket] {
        var left = alreadySent
        var byStation: [String: [TicketItem]] = [:]
        for line in lines where line.qty > 0 {
            let sent = min(line.qty, left[line.name] ?? 0)
            left[line.name] = (left[line.name] ?? 0) - sent
            let qty = line.qty - sent
            guard qty > 0 else { continue }
            let station = line.category.flatMap { routing[$0] } ?? defaultStation
            byStation[station, default: []].append(TicketItem(name: line.name, qty: qty, notes: line.notes))
        }
        let addOn = !alreadySent.isEmpty
        return byStation.keys.sorted().map { station in
            KitchenTicket(order: order, label: label, station: station, items: byStation[station] ?? [], addOn: addOn, at: at)
        }
    }

    /// A ticket's status from every screen's events: the furthest status reached, unless a later recall put it back.
    public static func status(of ticket: String, events: [TicketEvent]) -> TicketStatus {
        var current = TicketStatus.new
        var seen = Set<String>()
        for event in events.filter({ $0.ticket == ticket }).sorted(by: { ($0.at, $0.id) < ($1.at, $1.id) })
            where seen.insert(event.id).inserted {
            if event.recall {
                current = event.status
            } else if event.status.rank > current.rank {
                current = event.status
            }
        }
        return current
    }

    /// Tickets still to do on a station's screen, oldest first.
    public static func open(_ tickets: [KitchenTicket], events: [TicketEvent], station: String) -> [KitchenTicket] {
        tickets.filter { $0.station == station }
            .filter { let s = status(of: $0.id, events: events); return s != .collected && s != .cancelled }
            .sorted { $0.at < $1.at }
    }

    /// The ticket as text for a kitchen printer, when no kitchen screen is in use.
    public static func printText(_ ticket: KitchenTicket) -> String {
        var out = [ticket.station.uppercased() + (ticket.addOn ? " – ADD-ON" : ""), ticket.label, String(ticket.at.prefix(16)).replacingOccurrences(of: "T", with: " "), ""]
        for item in ticket.items {
            out.append("\(item.qty.formatted()) × \(item.name)")
            out += item.notes.map { "   - " + $0 }
        }
        return out.joined(separator: "\n")
    }
}
