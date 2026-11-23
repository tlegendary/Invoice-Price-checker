import XCTest
@testable import ChargeCheckCore

final class TeamSyncTests: XCTestCase {
    private let entry = HistoryEntry(id: "r1", savedAt: "2026-11-12T10:00:00Z", supplier: "Apex", invNo: "1", date: "", net: 10, total: 12,
                                     over: 0, lines: [])
    private let price = PriceItem(id: "p1", name: "Wings", price: 15)
    private let payment = SupplierPayment(id: "pay1", supplier: "Apex", amount: 50, date: "2026-11-12")
    private let settings = TeamSettings(business: "RJ", shops: [ShopInfo(id: "s1", name: "High St")], trusted: ["Bravo"])

    func testRecordNames() {
        XCTAssertEqual(TeamSync.recordName(.report, "r1"), "Report_r1")
        XCTAssertEqual(TeamSync.parse("Price_ab_c")?.kind, .price)
        XCTAssertEqual(TeamSync.parse("Price_ab_c")?.id, "ab_c")
        XCTAssertNil(TeamSync.parse("Nothing_1"))
    }

    func testOwnerSendsEverythingOnce() {
        let items = TeamSync.items(entries: [entry], prices: [price], payments: [payment], settings: settings, staff: false)
        XCTAssertEqual(items.map { $0.recordName }, ["Report_r1", "Price_p1", "Payment_pay1", "TeamSettings_business"])
        let first = TeamSync.changes(items, synced: [:], staff: false)
        XCTAssertEqual(first.save.count, 4)
        XCTAssertTrue(first.delete.isEmpty)
        // after sending, nothing changes until the data does
        let synced = Dictionary(uniqueKeysWithValues: items.map { ($0.recordName, $0.hash) })
        XCTAssertTrue(TeamSync.changes(items, synced: synced, staff: false).save.isEmpty)
        var cheaper = price
        cheaper.price = 14
        let again = TeamSync.items(entries: [], prices: [cheaper], payments: [payment], settings: settings, staff: false)
        let next = TeamSync.changes(again, synced: synced, staff: false)
        XCTAssertEqual(next.save.map { $0.recordName }, ["Price_p1"])
        XCTAssertEqual(next.delete, ["Report_r1"])
    }

    func testStaffOnlySendReports() {
        let items = TeamSync.items(entries: [entry], prices: [price], payments: [payment], settings: settings, staff: true)
        XCTAssertEqual(items.map { $0.kind }, [.report])
        // the owner's prices synced to this phone are never deleted by it
        let synced = ["Price_p1": "x", "Report_old": "y"]
        XCTAssertEqual(TeamSync.changes(items, synced: synced, staff: true).delete, ["Report_old"])
    }

    func testRoundTripAndStableHash() {
        let items = TeamSync.items(entries: [entry], prices: [price], payments: [payment], settings: settings, staff: false)
        XCTAssertEqual(TeamSync.decodeReport(items[0].data)?.total, 12)
        XCTAssertEqual(TeamSync.decodePrice(items[1].data)?.name, "Wings")
        XCTAssertEqual(TeamSync.decodePayment(items[2].data)?.amount, 50)
        XCTAssertEqual(TeamSync.decodeSettings(items[3].data), settings)
        let again = TeamSync.items(entries: [entry], prices: [price], payments: [payment], settings: settings, staff: false)
        XCTAssertEqual(items.map { $0.hash }, again.map { $0.hash })
    }
}

final class PreparedMatchTests: XCTestCase {
    func testPreparedMatchingGivesTheSameAnswers() {
        let items = [
            PriceItem(id: "w", name: "Chicken Wings 10kg", price: 15, aliases: ["prime wing", "wings 10 kg"]),
            PriceItem(id: "o", name: "Vegetable Oil 20L", price: 30),
            PriceItem(id: "b", name: "Pizza Boxes 16 inch", price: 20, aliases: ["16 colour pizza boxes"])
        ]
        let book = PriceBook(items)
        for text in ["FRESH PRIME WING", "veg oil 20l", "16 COLOUR PIZZA BOXES", "Ketchup sachets", "chicken wings", ""] {
            XCTAssertEqual(Matcher.match(text, prepared: book.prepared), Matcher.match(text, in: items), text)
        }
        XCTAssertEqual(Matcher.match("FRESH PRIME WING", prepared: book.prepared).itemID, "w")
        XCTAssertFalse(book.knownWords.isEmpty)
    }
}
