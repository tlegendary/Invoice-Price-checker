import XCTest
@testable import ChargeCheckCore

/// A big customer: 2,000 items in the price list, 40 suppliers, 10,000 checked invoices over three years.
/// Each test prints how long it took and fails only when it's far too slow to feel instant on a phone
/// (the limits are generous: the cloud check runs unoptimised code on a shared machine).
final class BigShopSpeedTests: XCTestCase {
    static let items: [PriceItem] = (0..<2000).map { i in
        let kinds = ["Chicken Breast", "Beef Mince", "Burger Box", "Chips", "Cola Can", "Napkins", "Cheese Slices", "Buns", "Oil", "Mayo"]
        return PriceItem(id: "i\(i)", cat: "Cat \(i % 12)", name: "\(kinds[i % kinds.count]) \(i) \(i % 20 + 1)kg",
                         price: Double(5 + i % 60) + 0.49, supplier: "Supplier \(i % 40)")
    }

    static let entries: [HistoryEntry] = (0..<10_000).map { n in
        let day = n % 28 + 1, month = n / 280 % 12 + 1, year = 2024 + n / 3400
        let lines = (0..<12).map { k -> HistoryLine in
            let item = items[(n * 7 + k * 13) % items.count]
            return HistoryLine(qty: Double(k % 4 + 1), desc: item.name, unit: item.price + (k == 3 ? 0.5 : 0), matchId: item.id,
                               item: item.name, base: item.price, over: k == 3 ? 0.5 : 0)
        }
        return HistoryEntry(supplier: "Supplier \(n % 40)", invNo: "INV\(n)", date: String(format: "%02d/%02d/%04d", day, month, year),
                            net: 500, total: 560, over: 2, lines: lines)
    }

    private func time(_ label: String, limit: Double, _ work: () throws -> Void) rethrows {
        let start = Date()
        try work()
        let seconds = Date().timeIntervalSince(start)
        print("SPEED \(label): \(String(format: "%.3f", seconds)) s (limit \(limit) s)")
        XCTAssertLessThan(seconds, limit, label)
    }

    func testMatchingAnInvoiceAgainstABigPriceList() {
        let book = PriceBook(Self.items)
        let prepared = book.prepared
        time("match 60 lines against 2,000 items", limit: 6) {
            for k in 0..<60 { _ = Matcher.match("CHICKEN BREAST \(k * 31) \(k % 20 + 1)KG", prepared: prepared) }
        }
    }

    func testSupplierAccounts() {
        time("supplier accounts, 10,000 invoices", limit: 6) {
            _ = SupplierAccounts.accounts(entries: Self.entries, payments: [], trusted: [])
        }
    }

    func testHomeOverview() {
        time("home overview, 10,000 invoices", limit: 10) {
            _ = OverviewMaths.make(entries: Self.entries, payments: [], trusted: [])
        }
    }

    func testPriceRises() {
        time("price rises, 10,000 invoices", limit: 10) {
            _ = Insights.priceRises(Self.entries)
        }
    }

    func testBackupRoundTrip() throws {
        try time("backup save and read, 10,000 invoices", limit: 15) {
            let data = try JSONEncoder().encode(BackupFile(baseline: Self.items, history: Self.entries))
            print("SPEED backup size: \(data.count / 1_000_000) MB")
            let read = try BackupFile.read(data)
            XCTAssertEqual(read.history.count, 10_000)
        }
    }

    func testNameSuggestionsForTheWholeList() {
        time("name suggestions, all 2,000 items", limit: 20) {
            let prepared = NameIdeas.prepare(Self.items)
            for item in Self.items { _ = NameIdeas.suggest(for: item, prepared: prepared, limit: 4) }
        }
    }
}
