import XCTest
@testable import ChargeCheckCore

final class OverviewTests: XCTestCase {
    private let now = SupplierAccounts.day("2026-11-14")!

    private func line(_ name: String, qty: Double, unit: Double, base: Double? = nil, short: Double = 0, excluded: Bool = false) -> HistoryLine {
        let over = base.map { max(0, ($0 < unit ? unit - $0 : 0) * qty) } ?? 0
        return HistoryLine(qty: qty, desc: name, unit: unit, matchId: name, item: name, base: base, over: over, excluded: excluded, short: short)
    }

    private func entry(_ id: String, _ supplier: String, _ saved: String, date: String = "", over: Double = 0, excluded: Double = 0,
                       verified: Bool = true, paid: String? = nil, credit: CreditInfo? = nil, _ lines: [HistoryLine]) -> HistoryEntry {
        let net = lines.reduce(0) { $0 + $1.qty * $1.unit }
        return HistoryEntry(id: id, savedAt: saved + "T10:00:00Z", supplier: supplier, invNo: id, date: date, net: net, total: net,
                            over: over, excluded: excluded, verified: verified, paid: paid, credit: credit, lines: lines)
    }

    func testHomeFigures() {
        let entries = [
            entry("a1", "Apex Foods", "2026-10-20", [line("Oil 20L", qty: 2, unit: 30)]),
            entry("a2", "Apex Foods", "2026-11-03", over: 4, [line("Oil 20L", qty: 2, unit: 32, base: 30)]),
            entry("b1", "Bravo", "2026-11-05", excluded: 10, verified: false, [line("Wings", qty: 1, unit: 10, excluded: true),
                                                                                line("Rice 10kg", qty: 2, unit: 20)])
        ]
        let o = OverviewMaths.make(entries: entries, payments: [], trusted: [], now: now)
        XCTAssertEqual(o.owed, 60 + 60 + 40)          // 60 + (64−4) + (50−10)
        XCTAssertEqual(o.suppliersOwed, 2)
        XCTAssertEqual(o.invoicesThisMonth, 2)
        XCTAssertEqual(o.spentThisMonth, 114)
        XCTAssertEqual(o.savedThisMonth.overcharges, 4)
        XCTAssertEqual(o.savedThisMonth.missing, 10)
        XCTAssertEqual(o.savedThisMonth.total, 14)
        XCTAssertEqual(o.savedThisMonth.invoices, 2)
        // oil went from 30 to 32 at Apex: 2 × 2 = 4 more this month
        XCTAssertEqual(o.risesThisMonth.count, 1)
        XCTAssertEqual(o.risesCost, 4)
        XCTAssertEqual(o.risingSupplier, "Apex Foods")
        XCTAssertEqual(o.attention.map { $0.kind }, [.notChecked, .priceRises])
    }

    func testLateCreditsAndLostMoney() {
        let entries = [
            entry("c1", "Apex", "2026-10-01", over: 5,
                  credit: CreditInfo(status: CreditInfo.requested, amount: 5, at: "2026-10-02T09:00:00Z"),
                  [line("Oil", qty: 1, unit: 35, base: 30)]),
            entry("c2", "Apex", "2026-11-10", over: 2,
                  credit: CreditInfo(status: CreditInfo.requested, amount: 2, at: "2026-11-10T09:00:00Z"),
                  [line("Salt", qty: 1, unit: 3, base: 1)]),
            entry("c3", "Apex", "2026-09-01", over: 1,
                  credit: CreditInfo(status: CreditInfo.received, amount: 1, at: "2026-09-02T09:00:00Z"),
                  [line("Salt", qty: 1, unit: 2, base: 1)])
        ]
        let o = OverviewMaths.make(entries: entries, payments: [], trusted: [], now: now)
        XCTAssertEqual(o.creditsOwed, 7)
        let late = o.attention.first { $0.kind == .creditsLate }
        XCTAssertEqual(late?.count, 1)                // only the one asked for over two weeks ago
        XCTAssertEqual(late?.amount, 5)
        XCTAssertEqual(o.savedAllTime.creditsReceived, 1)
        XCTAssertEqual(o.savedAllTime.overcharges, 8)
        // salt went from 2 to 3 this month: 1 more, plus 7 in credits still owed
        XCTAssertEqual(o.lostThisMonth, 8)
    }

    func testDueDates() {
        let entries = [
            entry("d1", "Apex", "2026-10-01", date: "01/10/2026", [line("Oil", qty: 1, unit: 100)]),
            entry("d2", "Apex", "2026-11-10", date: "10/11/2026", [line("Oil", qty: 1, unit: 50)]),
            entry("d3", "Bravo", "2026-11-01", [line("Rice", qty: 1, unit: 20)])
        ]
        // 30 paid towards Apex's balance: it comes off the oldest invoice
        let payments = [SupplierPayment(supplier: "Apex", amount: 30, date: "2026-11-02")]
        let accounts = SupplierAccounts.accounts(entries: entries, payments: payments, trusted: [], now: now)
        let due = DueDates.open(accounts: accounts, creditDays: ["apex": 30], now: now)
        XCTAssertEqual(due.count, 2)                  // Bravo has no credit period, so it isn't listed
        XCTAssertEqual(due[0].entry.id, "d1")
        XCTAssertEqual(due[0].amount, 70)
        XCTAssertEqual(due[0].dueDate, "2026-10-31")
        XCTAssertEqual(due[0].daysLeft, -14)
        XCTAssertEqual(due[1].dueDate, "2026-12-10")
        XCTAssertEqual(due[1].daysLeft, 26)
        XCTAssertEqual(DueDates.cashNeeded(due), 70)
        let o = OverviewMaths.make(entries: entries, payments: payments, trusted: [], creditDays: ["apex": 30], now: now)
        XCTAssertEqual(o.attention.first { $0.kind == .overdue }?.amount, 70)
    }

    func testDueDateIgnoresAnUnlikelyPrintedDate() {
        let e = entry("x", "Apex", "2026-11-10", date: "10/11/2019", [line("Oil", qty: 1, unit: 1)])
        XCTAssertEqual(SupplierAccounts.dayText(DueDates.start(of: e)), "2026-11-10")
    }

    func testSearchEverything() {
        let entries = [
            entry("82300", "Panini Foods", "2026-11-10", [line("Chicken breast", qty: 2, unit: 10)]),
            entry("57", "Dilsagh", "2026-11-11", [line("طماطم", qty: 1, unit: 170.86)])
        ]
        let payments = [SupplierPayment(supplier: "Dilsagh", amount: 500, date: "2026-11-12", method: "cash", reference: "REF-778")]
        let items = [PriceItem(name: "Chicken breast", price: 9, aliases: ["CHKN BRST"])]

        var r = Search.find("panini", entries: entries, payments: payments, items: items)
        XCTAssertEqual(r.suppliers, ["Panini Foods"])
        XCTAssertEqual(r.invoices.map { $0.id }, ["82300"])

        r = Search.find("chkn", entries: entries, payments: payments, items: items)
        XCTAssertEqual(r.items.map { $0.name }, ["Chicken breast"])

        r = Search.find("chicken", entries: entries, payments: payments, items: items)
        XCTAssertEqual(r.matchedLine["82300"], "Chicken breast")

        r = Search.find("82300", entries: entries, payments: payments, items: items)
        XCTAssertEqual(r.invoices.map { $0.id }, ["82300"])

        r = Search.find("170.86", entries: entries, payments: payments, items: items)
        XCTAssertEqual(r.invoices.map { $0.id }, ["57"])

        r = Search.find("ref 778", entries: entries, payments: payments, items: items)
        XCTAssertEqual(r.payments.count, 1)

        r = Search.find("طماطم", entries: entries, payments: payments, items: items)
        XCTAssertEqual(r.invoices.map { $0.id }, ["57"])

        XCTAssertTrue(Search.find("  ", entries: entries, payments: payments, items: items).isEmpty)
    }
}

final class SupplierProfileTests: XCTestCase {
    private let now = SupplierAccounts.day("2026-11-14")!

    private func entry(_ id: String, _ supplier: String, _ saved: String, _ lines: [HistoryLine]) -> HistoryEntry {
        let net = lines.reduce(0) { $0 + $1.qty * $1.unit }
        let over = lines.reduce(0) { $0 + $1.over }
        let excluded = lines.filter { $0.excluded }.reduce(0) { $0 + $1.qty * $1.unit }
        return HistoryEntry(id: id, savedAt: saved + "T10:00:00Z", supplier: supplier, net: net, total: net, over: over,
                            excluded: excluded, lines: lines)
    }

    private func l(_ name: String, _ qty: Double, _ unit: Double, base: Double, short: Double = 0, excluded: Bool = false) -> HistoryLine {
        HistoryLine(qty: qty, desc: name, unit: unit, matchId: name, item: name, base: base,
                    over: max(0, unit - base) * qty, excluded: excluded, short: short)
    }

    func testScoreAndFigures() {
        let apex = [
            entry("1", "Apex", "2026-09-10", [l("Oil", 1, 30, base: 30), l("Rice", 1, 20, base: 20), l("Salt", 1, 1, base: 1)]),
            entry("2", "Apex", "2026-10-10", [l("Oil", 1, 30, base: 30), l("Rice", 1, 22, base: 20), l("Salt", 2, 1, base: 1, short: 1)]),
            entry("3", "Apex", "2026-11-10", [l("Oil", 1, 30, base: 30), l("Rice", 1, 22, base: 20), l("Salt", 1, 1, base: 1, excluded: true)])
        ]
        let bravo = [entry("4", "Bravo", "2026-11-11", [l("Oil", 1, 28, base: 30), l("Rice", 1, 22, base: 22)])]
        let all = apex + bravo
        let account = SupplierAccounts.accounts(entries: all, payments: [], trusted: [], now: now).first { $0.id == "apex" }!
        let p = SupplierProfiles.make(account, all: all, now: now)
        XCTAssertEqual(p.invoices, 3)
        XCTAssertEqual(p.purchasesThisMonth, 53)
        XCTAssertEqual(p.purchasesLastMonth, 54)
        XCTAssertEqual(p.overcharged, 4)
        XCTAssertEqual(p.missing, 1)
        XCTAssertEqual(p.disputed, 2)
        // 9 lines, 8 priced and not missing, 2 of them over the agreed price
        XCTAssertEqual(p.parts.invoiceAccuracy, 75)
        // 9 lines: one short, one missing
        XCTAssertEqual(p.parts.deliveryAccuracy, 77.8)
        // oil, rice and salt bought lately; rice went up
        XCTAssertEqual(p.parts.priceStability, 66.7)
        // oil is cheaper at Bravo, rice costs the same: 1 of 2
        XCTAssertEqual(p.parts.priceCompetitiveness, 50)
        XCTAssertNotNil(p.score)
        // 75 × 0.3 + 77.8 × 0.25 + 66.7 × 0.2 + 50 × 0.25 = 67.8
        XCTAssertEqual(p.score, 68)
        // Bravo has one invoice: too few for a score
        let b = SupplierAccounts.accounts(entries: all, payments: [], trusted: [], now: now).first { $0.id == "bravo" }!
        XCTAssertNil(SupplierProfiles.make(b, all: all, now: now).score)
    }
}

final class SupplierCurrencyTests: XCTestCase {
    func testDollarSupplierKeptApart() {
        let now = SupplierAccounts.day("2026-11-14")!
        let lines = [HistoryLine(qty: 1, desc: "Tomato", unit: 100)]
        let entries = [
            HistoryEntry(id: "1", savedAt: "2026-11-10T10:00:00Z", supplier: "Dilsagh", net: 1808.68, total: 1808.68, over: 0, lines: lines),
            HistoryEntry(id: "2", savedAt: "2026-11-11T10:00:00Z", supplier: "Bazar", net: 250_000, total: 250_000, over: 0, lines: lines)
        ]
        let o = OverviewMaths.make(entries: entries, payments: [], trusted: [], currencies: ["dilsagh": "USD"], main: "IQD", now: now)
        XCTAssertEqual(o.owed, 250_000)
        XCTAssertEqual(o.spentThisMonth, 250_000)
        XCTAssertEqual(o.owedOther["USD"], 1808.68)
        XCTAssertEqual(Money.format(1808.68, code: "USD"), "$1808.68")
        XCTAssertEqual(Money.format(250_000, code: "IQD"), "250,000 IQD")
        // a supplier set to the main currency counts as usual
        let same = OverviewMaths.make(entries: entries, payments: [], trusted: [], currencies: ["dilsagh": "IQD"], main: "IQD", now: now)
        XCTAssertTrue(same.owedOther.isEmpty)
    }
}
