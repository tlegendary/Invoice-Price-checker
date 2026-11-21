import XCTest
import ChargeCheckCore
@testable import ChargeCheck

/// The till store itself refuses manager-only actions: going round the screens doesn't work.
@MainActor
final class TillPermissionTests: XCTestCase {
    private let till = TillStore.shared
    private var added: [String] = []

    override func tearDown() async throws {
        for id in added { till.removeCashier(id) }
        till.cashier = nil
    }

    private func person(_ name: String, _ pin: String, _ role: TillRole) throws {
        XCTAssertTrue(till.addCashier(name: name, pin: pin, role: role))
        added.append(try XCTUnwrap(till.cashiers.last).id)
    }

    func testACashierCantTakeCashOutOrCloseTheDayWithoutAManager() throws {
        guard till.cashiers.isEmpty, !till.training else { throw XCTSkip("needs a till with no people set up") }
        try person("Owner Test", "9182", .owner)
        try person("Cashier Test", "7364", .cashier)
        XCTAssertTrue(till.signIn(pin: "7364"))
        XCTAssertFalse(till.may(.cashOut), "cashiers can't take cash out until the owner allows it")

        let before = till.cash.count
        till.addCash(.paidOut, amount: 20, note: "test", shop: "")
        XCTAssertEqual(till.cash.count, before, "refused: no manager said yes")
        XCTAssertNil(till.closeDay(shop: "", counted: nil))

        // a wrong PIN gives no yes
        XCTAssertNil(till.approve([.cashOut], pin: "0000"))
        till.addCash(.paidOut, amount: 20, note: "test", shop: "")
        XCTAssertEqual(till.cash.count, before)

        // the owner's PIN: one cash out goes through, recorded with who said yes, and only once
        XCTAssertNotNil(till.approve([.cashOut], pin: "9182"))
        till.addCash(.paidOut, amount: 20, note: "test", shop: "")
        XCTAssertEqual(till.cash.count, before + 1)
        XCTAssertEqual(till.cash.last?.approvedBy, "Owner Test")
        till.addCash(.paidOut, amount: 20, note: "test", shop: "")
        XCTAssertEqual(till.cash.count, before + 1, "the yes was used up")

        // money from customers never needs a manager
        till.addCash(.tabPaid, amount: 5, note: "test", shop: "")
        XCTAssertEqual(till.cash.count, before + 2)
    }
}
