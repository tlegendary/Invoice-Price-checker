import XCTest
@testable import ChargeCheckCore

/// Checked against figures worked out by hand.
final class ProfitReportTests: XCTestCase {
    func testAgainstAHandCalculatedDay() {
        // 1) 2 burgers at £6 incl 20% VAT (net £5 each), cost £1.32 each → net 10, cost 2.64
        // 2) 3 colas at £1.20 incl 20% (net £1), cost £0.40 → net 3, cost 1.20
        // 3) 1 cake at £3, 0% VAT, cost unknown → net 3, no cost
        // 4) refund of 1 cola → net −1, cost −0.40
        let day = [
            Sale(number: 1, shop: "", at: "2026-11-23T12:00:00Z", lines: [
                SaleLine(name: "Burger", qty: 2, price: 6, vat: 20, cost: 1.32),
                SaleLine(name: "Cola", qty: 3, price: 1.2, vat: 20, cost: 0.4),
                SaleLine(name: "Cake", qty: 1, price: 3)], payment: .card),
            Sale(number: 2, shop: "", at: "2026-11-23T13:00:00Z", lines: [SaleLine(name: "Cola", qty: -1, price: 1.2, vat: 20, cost: 0.4)],
                 payment: .cash, refundOf: "x")
        ]
        let s = SaleMaths.summary(day)
        XCTAssertEqual(s.takings, 17.4)          // 12 + 3.6 + 3 − 1.2
        XCTAssertEqual(s.vat, 2.4)               // 2 + 0.6 − 0.2
        XCTAssertEqual(s.net, 15)
        XCTAssertEqual(s.costedNet, 12)          // 10 + 3 − 1
        XCTAssertEqual(s.cogs, 3.44)             // 2.64 + 1.20 − 0.40
        XCTAssertEqual(s.profit, 8.56)
        XCTAssertEqual(s.margin, 71.3)           // 8.56 ÷ 12
        XCTAssertEqual(s.coverage, 80)           // 12 of 15
        XCTAssertEqual(s.unknownCost, 1)
    }

    func testLowMarginItemsAreFlaggedLossesFirst() {
        let items = [
            PriceItem(id: "cola", name: "Cola", price: 0.9, till: TillInfo(sell: 1.2, vat: 20, tillOnly: true)),   // net 1.00, cost 0.90 → 10%
            PriceItem(id: "water", name: "Water", price: 1.1, till: TillInfo(sell: 1.2, vat: 20, tillOnly: true)), // net 1.00, cost 1.10 → −10%
            PriceItem(id: "cake", name: "Cake", price: 1, till: TillInfo(sell: 3, tillOnly: true))                // 0% VAT, 66.7%
        ]
        let alerts = MarginAlerts.find(items, threshold: 30)
        XCTAssertEqual(alerts.map(\.name), ["Water", "Cola"])
        XCTAssertEqual(alerts.map(\.margin), [-10, 10])
    }
}
