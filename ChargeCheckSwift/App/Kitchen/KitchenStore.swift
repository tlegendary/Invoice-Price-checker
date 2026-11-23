import ChargeCheckCore
import Foundation

/// Kitchen tickets and their status changes, shared between the tills and kitchen screens. Each device writes only
/// its own file (tickets it sent, statuses it set); everyone merges everyone's (rules in `Kitchen`).
@MainActor
final class KitchenStore: ObservableObject {
    static let shared = KitchenStore()
    static let folder = "Kitchen"

    struct Log: Codable {
        var tickets: [KitchenTicket] = []
        var events: [TicketEvent] = []
    }

    @Published private(set) var tickets: [KitchenTicket] = []
    @Published private(set) var events: [TicketEvent] = []
    private var own = Log()

    /// On: completed sales send their food and drink to the kitchen.
    var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: "kitchen.on") }
        set { UserDefaults.standard.set(newValue, forKey: "kitchen.on"); objectWillChange.send() }
    }

    /// Category → station ("Drinks" → "Bar"); anything else goes to the kitchen.
    var routing: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "kitchen.routing") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "kitchen.routing"); objectWillChange.send() }
    }

    /// The station this device shows when it's a kitchen screen.
    var station: String {
        get { UserDefaults.standard.string(forKey: "kitchen.station") ?? Kitchen.defaultStation }
        set { UserDefaults.standard.set(newValue, forKey: "kitchen.station"); objectWillChange.send() }
    }

    var stations: [String] { Array(Set([Kitchen.defaultStation] + routing.values)).sorted() }

    private var device: String {
        if let id = UserDefaults.standard.string(forKey: "kitchen.device") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "kitchen.device")
        return id
    }

    private var fileName: String { "Kitchen ~" + device + ".json" }

    private init() {
        if let url = AppFiles.url(forRelativePath: Self.folder + "/" + fileName), let data = try? Data(contentsOf: url),
           let log = try? JSONDecoder().decode(Log.self, from: data) {
            own = log
        }
        refresh()
    }

    /// A completed sale's items, to each station (nothing when the kitchen is off or nothing is for it).
    func send(order: String, label: String, lines: [(name: String, qty: Double, category: String?, notes: [String])]) {
        guard isOn else { return }
        let new = Kitchen.tickets(order: order, label: label, lines: lines, routing: routing,
                                  at: ISO8601DateFormatter().string(from: Date()))
        guard !new.isEmpty else { return }
        own.tickets += new
        save()
    }

    func mark(_ ticket: KitchenTicket, _ status: TicketStatus, recall: Bool = false) {
        own.events.append(TicketEvent(ticket: ticket.id, status: status, recall: recall, device: device,
                                      at: ISO8601DateFormatter().string(from: Date())))
        save()
    }

    func status(_ ticket: KitchenTicket) -> TicketStatus { Kitchen.status(of: ticket.id, events: events) }

    /// Everyone's tickets and statuses: this device's, and what the others wrote (on this device and in iCloud).
    func refresh() {
        var logs = [own]
        if let folder = AppFiles.url(forRelativePath: Self.folder),
           let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for name in names where name != fileName && name.hasSuffix(".json") {
                if let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                   let log = try? JSONDecoder().decode(Log.self, from: data) { logs.append(log) }
            }
        }
        apply(logs)
        guard CloudFolder.isOn else { return }
        let mine = fileName
        Task.detached(priority: .utility) {
            let files = CloudFolder.readAll(folder: KitchenStore.folder) { $0 != mine && $0.hasSuffix(".json") }
            let others = files.compactMap { try? JSONDecoder().decode(Log.self, from: $0.data) }
            await MainActor.run {
                for file in files { AppFiles.write(file.data, folder: KitchenStore.folder, name: file.name) }
                self.apply([self.own] + others)
            }
        }
    }

    private func apply(_ logs: [Log]) {
        tickets = TillSync.mergeIDs(logs.map(\.tickets))
        events = TillSync.mergeIDs(logs.map(\.events))
    }

    private func save() {
        // a day's tickets are plenty: keep the last two days in the file
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 86_400))
        own.tickets.removeAll { $0.at < cutoff }
        let kept = Set(own.tickets.map(\.id))
        own.events.removeAll { $0.at < cutoff && !kept.contains($0.ticket) }
        guard let data = try? JSONEncoder().encode(own) else { return }
        AppFiles.write(data, folder: Self.folder, name: fileName)
        if CloudFolder.isOn { CloudOutbox.send(data, folder: Self.folder, name: fileName) }
        refresh()
    }
}
