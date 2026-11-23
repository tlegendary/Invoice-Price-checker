import XCTest
@testable import ChargeCheckCore

final class KitchenTests: XCTestCase {
    private let routing = ["Drinks": "Bar"]

    func testAnOrderIsSplitByStation() {
        let tickets = Kitchen.tickets(order: "tab1", label: "Table 4",
                                      lines: [("Burger", 2, "Mains", ["no onions"]), ("Cola", 2, "Drinks", []), ("Chips", 1, nil, [])],
                                      routing: routing, at: "2026-11-23T19:00:00Z")
        XCTAssertEqual(tickets.map(\.station), ["Bar", "Kitchen"])
        XCTAssertEqual(tickets.first { $0.station == "Kitchen" }?.items.map(\.name), ["Burger", "Chips"])
        XCTAssertEqual(tickets.first { $0.station == "Kitchen" }?.items.first?.notes, ["no onions"])
        XCTAssertFalse(tickets[0].addOn)
    }

    func testItemsAddedLaterGoAsAnAddOnWithOnlyTheNewOnes() {
        let more = Kitchen.tickets(order: "tab1", label: "Table 4", lines: [("Burger", 3, "Mains", []), ("Cola", 2, "Drinks", [])],
                                   routing: routing, alreadySent: ["Burger": 2, "Cola": 2], at: "2026-11-23T19:20:00Z")
        XCTAssertEqual(more.count, 1)
        XCTAssertTrue(more[0].addOn)
        XCTAssertEqual(more[0].items.map(\.qty), [1])
    }

    func testTwoIPadsTappingTheSameTicketLoseNothing() {
        // iPad A marks it preparing, iPad B (not yet seeing A) marks it ready: merged, it's ready
        let a = TicketEvent(ticket: "t", status: .preparing, device: "A", at: "2026-11-23T19:01:00Z")
        let b = TicketEvent(ticket: "t", status: .ready, device: "B", at: "2026-11-23T19:00:59Z")
        XCTAssertEqual(Kitchen.status(of: "t", events: [a, b]), .ready, "an earlier clock doesn't undo a later status")
        XCTAssertEqual(Kitchen.status(of: "t", events: [b, a]), .ready, "same answer in any order")
        XCTAssertEqual(Kitchen.status(of: "t", events: [a, b, a, b]), .ready, "the same event twice counts once")
    }

    func testARecallPutsItBack() {
        let events = [TicketEvent(ticket: "t", status: .ready, device: "A", at: "2026-11-23T19:05:00Z"),
                      TicketEvent(ticket: "t", status: .preparing, recall: true, device: "B", at: "2026-11-23T19:06:00Z")]
        XCTAssertEqual(Kitchen.status(of: "t", events: events), .preparing)
        let ticket = KitchenTicket(id: "t", order: "o", label: "Table 4", station: "Kitchen", items: [], at: "2026-11-23T19:00:00Z")
        XCTAssertEqual(Kitchen.open([ticket], events: events, station: "Kitchen").count, 1)
        let done = events + [TicketEvent(ticket: "t", status: .collected, device: "A", at: "2026-11-23T19:10:00Z")]
        XCTAssertEqual(Kitchen.open([ticket], events: done, station: "Kitchen").count, 0)
    }

    func testPrinterText() {
        let t = KitchenTicket(order: "o", label: "Table 4", station: "Kitchen", items: [TicketItem(name: "Burger", qty: 2, notes: ["no onions"])],
                              addOn: true, at: "2026-11-23T19:20:00Z")
        XCTAssertEqual(Kitchen.printText(t), "KITCHEN – ADD-ON\nTable 4\n2026-11-23 19:20\n\n2 × Burger\n   - no onions")
    }
}
