import Foundation

// MARK: - Who can do what at the till

/// Owner and managers can do everything; a cashier only what the owner allows.
public enum TillRole: String, Codable, CaseIterable, Sendable {
    case owner, manager, cashier

    public var isManager: Bool { self != .cashier }
}

/// Things at the till that can be kept for managers.
public enum TillPermission: String, Codable, CaseIterable, Sendable {
    case refund, discount, priceChange, customAmount, removeLine, cashIn, cashOut, float, noSale, closeDay, giftCard, tab, settings

    /// What a cashier may do until the owner changes it: the everyday things. Refunds, discounts, changing prices,
    /// taking cash out, opening the drawer, closing the day and the settings need a manager.
    public static let cashierDefault: Set<TillPermission> = [.customAmount, .removeLine, .cashIn, .float, .giftCard, .tab]
}

public enum TillRoles {
    /// `hasManagers`: until someone is a manager or the owner, nothing is locked (a till without cashiers works as before).
    public static func allows(_ role: TillRole?, _ permission: TillPermission, cashierCan: Set<TillPermission>, hasManagers: Bool) -> Bool {
        guard hasManagers else { return true }
        guard let role else { return false }
        if role.isManager { return true }
        return permission != .settings && cashierCan.contains(permission)
    }
}

// MARK: - Several tills: one file per till, merged

/// Every till writes only its own files ("Sales 2026-11 ~B.json"); the others read them. Nothing is ever overwritten
/// by another device, so two tills selling at the same moment can't lose each other's sales.
public enum TillSync {
    public static func fileName(_ base: String, till: String) -> String { base + " ~" + till + ".json" }

    /// The till a file belongs to ("B"), nil for a file from before tills had names.
    public static func till(ofFile name: String) -> String? {
        guard name.hasSuffix(".json"), let mark = name.range(of: " ~", options: .backwards) else { return nil }
        let code = name[mark.upperBound..<name.index(name.endIndex, offsetBy: -5)]
        return code.isEmpty ? nil : String(code)
    }

    /// Sales from every file: each one once (the first copy wins), newest first.
    public static func merge(_ lists: [[Sale]]) -> [Sale] {
        var seen = Set<String>()
        var out: [Sale] = []
        for list in lists {
            for sale in list where seen.insert(sale.id).inserted { out.append(sale) }
        }
        return out.sorted { $0.at != $1.at ? $0.at > $1.at : $0.id > $1.id }
    }

    public static func mergeIDs<T: Identifiable>(_ lists: [[T]]) -> [T] where T.ID == String {
        var seen = Set<String>()
        var out: [T] = []
        for list in lists {
            for value in list where seen.insert(value.id).inserted { out.append(value) }
        }
        return out
    }

    /// Stock counts from every till: the latest count of each item in each shop.
    public static func mergeCounts(_ lists: [[StockCount]]) -> [StockCount] {
        var best: [String: StockCount] = [:]
        for list in lists {
            for count in list {
                let key = count.shop + "|" + count.itemID
                if let old = best[key], old.at >= count.at { continue }
                best[key] = count
            }
        }
        return best.values.sorted { $0.at < $1.at }
    }

    /// The next free till letter: A, B, C… then A2, B2…
    public static func nextCode(taken: Set<String>) -> String {
        let letters = "ABCDEFGHJKLMNPQRSTUVWXYZ".map(String.init)
        var round = 1
        while true {
            for letter in letters {
                let code = round == 1 ? letter : letter + "\(round)"
                if !taken.contains(code) { return code }
            }
            round += 1
        }
    }
}

// MARK: - Sold by weight

public enum Weight {
    /// "0.452 kg", "1.2 kg"
    public static func text(_ kg: Double) -> String {
        let grams = (kg * 1000).rounded()
        let value = grams / 1000
        var s = String(format: "%.3f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + " kg"
    }

    /// Typed at the till: "452" (grams, no point) or "0.452" / "1,2" (kg).
    public static func parse(_ text: String, gramsWithoutPoint: Bool = true) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "kg", with: "").replacingOccurrences(of: "g", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = Double(t), value > 0 else { return nil }
        if gramsWithoutPoint && !t.contains(".") && value >= 10 { return value / 1000 }
        return value
    }

    /// kg × price per kg, to the penny.
    public static func price(kg: Double, perKg: Double) -> Double { Money.round2(kg * perKg) }
}

/// What a scale label's barcode carries.
public enum ScaleLabelValue: String, Codable, CaseIterable, Sendable {
    case price, weight
}

/// Labels printed by a shop scale: EAN-13 starting 2 (20–29). The first 7 digits name the item ("2012345"),
/// the next 5 are the price in pence or the weight in grams, then a check digit.
/// EAN/UPC check digit: weights 1,3,1,3… (or 3,1,3,1…) from the left.
func check(_ digits: [Int], oddWeight: Int) -> Int {
    var sum = 0
    for (index, digit) in digits.enumerated() {
        let weight: Int = index % 2 == 0 ? oddWeight : (oddWeight == 1 ? 3 : 1)
        sum += digit * weight
    }
    return (10 - sum % 10) % 10
}

public enum ScaleBarcode {
    public struct Read: Equatable, Sendable {
        /// What to look the item up by: the first 7 digits.
        public var lookup: String
        /// Price (pounds) or weight (kg), per the setting.
        public var value: Double
    }

    public static func read(_ code: String, carries: ScaleLabelValue) -> Read? {
        let digits = code.filter(\.isNumber)
        guard digits.count == 13, digits == code.trimmingCharacters(in: .whitespaces), digits.first == "2", checkDigitOK(digits) else { return nil }
        let chars = Array(digits)
        let lookup = String(chars[0..<7])
        guard let raw = Double(String(chars[7..<12])) else { return nil }
        let value = carries == .price ? raw / 100 : raw / 1000
        return Read(lookup: lookup, value: value)
    }

    public static func checkDigitOK(_ digits: String) -> Bool {
        let n = digits.compactMap { $0.wholeNumberValue }
        guard n.count == 13 else { return false }
        return check(Array(n[0..<12]), oddWeight: 1) == n[12]
    }
}

// MARK: - Batches and expiry dates

/// A delivery of one item with its own batch (lot) number and expiry date.
public struct StockBatch: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var itemID: String
    public var shop: String
    public var code: String
    /// yyyy-MM-dd
    public var expiry: String
    /// Units that came in.
    public var qty: Double
    public var at: String
    public var till: String?

    public init(id: String = UUID().uuidString, itemID: String, shop: String, code: String, expiry: String, qty: Double, at: String, till: String? = nil) {
        self.id = id
        self.itemID = itemID
        self.shop = shop
        self.code = code
        self.expiry = expiry
        self.qty = qty
        self.at = at
        self.till = till
    }
}

public struct BatchOnShelf: Equatable, Identifiable, Sendable {
    public var id: String { batch.id }
    public var batch: StockBatch
    /// Units of it thought to be left.
    public var left: Double
    /// Days to the expiry date (negative: expired).
    public var days: Int
}

/// A batch on the shelf that's out of date or soon will be.
public struct ExpiringBatch: Equatable, Identifiable, Sendable {
    public var id: String { batch.id }
    public var name: String
    public var batch: BatchOnShelf
}

public enum BatchMaths {
    /// Which batches are still on the shelf, assuming the shortest-dated ones were sold first: the stock there is
    /// now is filled from the latest-dated batches back. Oldest expiry first.
    public static func onShelf(_ batches: [StockBatch], onHand: Double, today: String) -> [BatchOnShelf] {
        var remaining = max(0, onHand)
        var out: [BatchOnShelf] = []
        for batch in batches.sorted(by: { $0.expiry != $1.expiry ? $0.expiry > $1.expiry : $0.at > $1.at }) {
            guard remaining > 0.0001 else { break }
            let left = min(batch.qty, remaining)
            remaining -= left
            out.append(BatchOnShelf(batch: batch, left: (left * 1000).rounded() / 1000, days: days(from: today, to: batch.expiry)))
        }
        return out.sorted { $0.batch.expiry < $1.batch.expiry }
    }

    /// The batch to sell from: the shortest-dated one left.
    public static func next(_ shelf: [BatchOnShelf]) -> BatchOnShelf? { shelf.first }

    /// Whole days between two yyyy-MM-dd dates.
    public static func days(from: String, to: String) -> Int {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let a = f.date(from: String(from.prefix(10))), let b = f.date(from: String(to.prefix(10))) else { return 0 }
        return Int((b.timeIntervalSince(a) / 86_400).rounded())
    }

    /// Everything expired or expiring within `within` days, soonest first.
    public static func expiring(_ shelves: [(name: String, shelf: [BatchOnShelf])], within: Int) -> [ExpiringBatch] {
        var out: [ExpiringBatch] = []
        for entry in shelves {
            for batch in entry.shelf where batch.days <= within {
                out.append(ExpiringBatch(name: entry.name, batch: batch))
            }
        }
        out.sort { a, b in
            if a.batch.days != b.batch.days { return a.batch.days < b.batch.days }
            return a.name < b.name
        }
        return out
    }

    /// Typed expiry dates: "2027-03-31", "31/03/2027", "03/27" (end of that month), "3/2027".
    public static func parseExpiry(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "/").replacingOccurrences(of: "-", with: "/")
        let parts = t.split(separator: "/").map(String.init)
        func ok(_ y: Int, _ m: Int, _ d: Int) -> String? {
            guard (1...12).contains(m), (1...31).contains(d), (2000...2100).contains(y) else { return nil }
            return String(format: "%04d-%02d-%02d", y, m, min(d, lastDay(y, m)))
        }
        if parts.count == 3, let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) {
            if parts[0].count == 4 { return ok(a, b, c) }
            return ok(c < 100 ? 2000 + c : c, b, a)
        }
        if parts.count == 2, let m = Int(parts[0]), let y = Int(parts[1]) {
            let year = y < 100 ? 2000 + y : y
            return ok(year, m, lastDay(year, m))
        }
        return nil
    }

    static func lastDay(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 2: return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}

// MARK: - Meal deals

/// One part of a deal: any of these items, or anything in these categories ("a sandwich").
public struct DealSlot: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var items: [String]
    public var categories: [String]

    public init(name: String, items: [String] = [], categories: [String] = []) {
        self.name = name
        self.items = items
        self.categories = categories
    }

    public func takes(itemID: String, category: String) -> Bool {
        items.contains(itemID) || categories.contains { TextTools.norm($0) == TextTools.norm(category) && !category.isEmpty }
    }
}

/// "Sandwich + drink + snack for £4".
public struct MealDeal: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var price: Double
    public var slots: [DealSlot]
    public var shops: [String]?
    public var off: Bool?

    public init(id: String = UUID().uuidString, name: String, price: Double, slots: [DealSlot], shops: [String]? = nil, off: Bool? = nil) {
        self.id = id
        self.name = name
        self.price = price
        self.slots = slots
        self.shops = shops
        self.off = off
    }

    public func isOn(shop: String) -> Bool {
        guard off != true, price > 0, slots.count >= 2 else { return false }
        let only = shops ?? []
        return only.isEmpty || only.contains(shop)
    }
}

/// A line of the basket, as deals see it.
public struct DealLine: Equatable, Sendable {
    public var key: String
    public var itemID: String?
    public var category: String
    /// Price of one.
    public var price: Double
    /// Whole units on the line (weighed lines and packs never go in a deal).
    public var qty: Int

    public init(key: String, itemID: String?, category: String, price: Double, qty: Int) {
        self.key = key
        self.itemID = itemID
        self.category = category
        self.price = price
        self.qty = qty
    }
}

public struct DealResult: Equatable, Sendable {
    /// Line key → money off from deals.
    public var off: [String: Double]
    /// Line key → units used in deals (the rest can still get a multi-buy).
    public var used: [String: Int]
    /// Line key → the deal's name.
    public var dealName: [String: String]
    /// Deal name → how many times.
    public var applied: [String: Int]
    public var total: Double
}

public enum DealMaths {
    /// Puts together as many deals as save the customer money. For each slot it takes the dearest item that fits
    /// and isn't used yet (so the saving is as big as it can be), and stops when a full set would cost no less.
    /// The saving is shared across the set's lines by their price; the last line takes the rounding.
    public static func apply(_ lines: [DealLine], deals: [MealDeal]) -> DealResult {
        var left = Dictionary(lines.map { ($0.key, $0.qty) }, uniquingKeysWith: +)
        var off: [String: Double] = [:], used: [String: Int] = [:], names: [String: String] = [:], applied: [String: Int] = [:]
        // bigger deals first, so a three-part deal isn't broken up by a two-part one
        let ordered = deals.filter { $0.price > 0 && $0.slots.count >= 2 }
            .sorted { $0.slots.count != $1.slots.count ? $0.slots.count > $1.slots.count : $0.name < $1.name }
        var total = 0.0
        for deal in ordered {
            while true {
                var picked: [DealLine] = []
                var taken: [String: Int] = [:]
                for slot in deal.slots {
                    var best: DealLine?
                    for line in lines {
                        guard let id = line.itemID, slot.takes(itemID: id, category: line.category) else { continue }
                        let free: Int = (left[line.key] ?? 0) - (taken[line.key] ?? 0)
                        guard free > 0 else { continue }
                        if let current = best, current.price > line.price || (current.price == line.price && current.key <= line.key) { continue }
                        best = line
                    }
                    guard let best else {
                        picked = []
                        break
                    }
                    picked.append(best)
                    taken[best.key, default: 0] += 1
                }
                guard picked.count == deal.slots.count else { break }
                var full = 0.0
                for line in picked { full += line.price }
                let saving = Money.round2(full - deal.price)
                guard saving > 0.004 else { break }
                var given = 0.0
                for (index, line) in picked.enumerated() {
                    let share = index == picked.count - 1 ? Money.round2(saving - given) : Money.round2(saving * line.price / full)
                    given += share
                    off[line.key, default: 0] += share
                    off[line.key] = Money.round2(off[line.key] ?? 0)
                    used[line.key, default: 0] += 1
                    names[line.key] = deal.name
                }
                for (key, n) in taken { left[key, default: 0] -= n }
                applied[deal.name, default: 0] += 1
                total += saving
            }
        }
        return DealResult(off: off, used: used, dealName: names, applied: applied, total: Money.round2(total))
    }
}

// MARK: - Customers, loyalty points, tabs, gift cards

public struct Customer: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var phone: String
    public var email: String
    public var note: String
    /// Most they can owe on their tab (nil: no tab allowed).
    public var tabLimit: Double?
    public var at: String

    public init(id: String = UUID().uuidString, name: String, phone: String = "", email: String = "", note: String = "",
                tabLimit: Double? = nil, at: String) {
        self.id = id
        self.name = name
        self.phone = phone
        self.email = email
        self.note = note
        self.tabLimit = tabLimit
        self.at = at
    }
}

public struct LoyaltySettings: Codable, Equatable, Sendable {
    /// Points for every 1 (pound) spent on goods. 0: no points.
    public var perPound: Double
    /// What one point is worth when it's spent.
    public var worth: Double

    public init(perPound: Double = 1, worth: Double = 0.01) {
        self.perPound = perPound
        self.worth = worth
    }
}

public struct CustomerBalance: Equatable, Sendable {
    public var points: Int
    /// Owed on the tab now.
    public var tab: Double
    public var spent: Double
    public var visits: Int
}

public enum CustomerMaths {
    /// Points earned on a sale: on what was paid with money or on the tab, not with points or gift cards.
    public static func pointsEarned(_ sale: Sale, perPound: Double) -> Int {
        guard perPound > 0 else { return 0 }
        var paid = 0.0
        for part in sale.payments where part.kind != .points && part.kind != .gift { paid += part.amount }
        var cards = 0.0
        for line in sale.lines where line.giftCard != nil { cards += line.gross }
        let goods = paid - cards
        let points: Double = (abs(goods) * perPound + 0.000_1).rounded(.down)
        return Int(goods < 0 ? -points : points)
    }

    public static func balance(_ customer: String, sales: [Sale], events: [CashEvent], loyalty: LoyaltySettings) -> CustomerBalance {
        var points = 0, visits = 0
        var tab = 0.0, spent = 0.0
        for sale in sales where sale.customer == customer {
            points += pointsEarned(sale, perPound: loyalty.perPound)
            if sale.refundOf == nil { visits += 1 }
            spent += sale.total
            for part in sale.payments {
                if part.kind == .tab { tab += part.amount }
                if part.kind == .points, loyalty.worth > 0 { points -= Int((part.amount / loyalty.worth).rounded()) }
            }
        }
        for event in events where event.kind == .tabPaid && event.ref == customer { tab -= event.amount }
        return CustomerBalance(points: points, tab: Money.round2(tab), spent: Money.round2(spent), visits: visits)
    }

    /// Money the points are worth.
    public static func worth(points: Int, loyalty: LoyaltySettings) -> Double { Money.round2(Double(max(0, points)) * loyalty.worth) }

    /// Can this much go on their tab?
    /// Can this much go on their account? Up to their limit, or (with no limit) only what's there as store credit.
    public static func tabAllows(_ customer: Customer, owed: Double, adding: Double) -> Bool {
        let limit = customer.tabLimit ?? 0
        return adding > 0 && owed + adding <= limit + 0.004
    }

    /// The most that can go on their account now (their limit less what they owe, or their store credit).
    public static func tabRoom(_ customer: Customer, owed: Double) -> Double {
        Money.round2(max(0, (customer.tabLimit ?? 0) - owed))
    }
}

public struct GiftCard: Codable, Equatable, Identifiable, Sendable {
    public var id: String { code }
    public var code: String
    /// What it was sold for (its starting value).
    public var amount: Double
    public var shop: String
    public var at: String
    /// The sale it was sold on.
    public var sale: String?

    public init(code: String, amount: Double, shop: String, at: String, sale: String? = nil) {
        self.code = code
        self.amount = amount
        self.shop = shop
        self.at = at
        self.sale = sale
    }
}

public enum GiftCards {
    /// What's left on a card: its value less what's been spent with it (refunds put it back).
    public static func balance(_ card: GiftCard, sales: [Sale]) -> Double {
        var left = card.amount
        for sale in sales {
            for part in sale.payments where part.kind == .gift && part.ref == card.code { left -= part.amount }
        }
        return Money.round2(left)
    }

    /// Cards sold on the till: one per gift card line.
    public static func sold(in sales: [Sale]) -> [GiftCard] {
        sales.filter { $0.refundOf == nil }.flatMap { sale in
            sale.lines.compactMap { line in
                line.giftCard.map { GiftCard(code: $0, amount: Money.round2(line.gross), shop: sale.shop, at: sale.at, sale: sale.id) }
            }
        }
    }

    /// A new code: 12 digits, the last a check digit, never one already used.
    public static func newCode(taken: Set<String>, random: () -> Int = { Int.random(in: 0...9) }) -> String {
        while true {
            var digits: [Int] = []
            for _ in 0..<11 { digits.append(random()) }
            if digits[0] == 0 { digits[0] = 7 }
            let code = digits.map { String($0) }.joined() + String(check(digits, oddWeight: 3))
            if !taken.contains(code) { return code }
        }
    }

    public static func looksValid(_ code: String) -> Bool {
        let d = code.compactMap { $0.wholeNumberValue }
        guard d.count == 12, code.count == 12 else { return false }
        return check(Array(d[0..<11]), oddWeight: 3) == d[11]
    }
}

// MARK: - Clocking in and out

public struct ClockEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var person: String
    public var shop: String
    public var at: String
    /// true: clocked in, false: clocked out.
    public var start: Bool
    public var till: String?

    public init(id: String = UUID().uuidString, person: String, shop: String, at: String, start: Bool, till: String? = nil) {
        self.id = id
        self.person = person
        self.shop = shop
        self.at = at
        self.start = start
        self.till = till
    }
}

public struct ShiftRow: Equatable, Identifiable, Sendable {
    public var id: String { person }
    public var person: String
    public var hours: Double
    public var shifts: Int
    /// Clocked in and not out yet (since then).
    public var inSince: String?
}

public enum Shifts {
    /// Hours worked between `from` and `to` (ISO), person by person. A shift still open counts up to `to`;
    /// a clock-out without a clock-in is ignored, and a second clock-in closes nothing (the first one stands).
    public static func hours(_ events: [ClockEvent], from: String, to: String) -> [ShiftRow] {
        let iso = ISO8601DateFormatter()
        var rows: [String: (hours: Double, shifts: Int, open: String?)] = [:]
        for event in events.sorted(by: { $0.at < $1.at }) where event.at <= to {
            var row = rows[event.person] ?? (0, 0, nil)
            if event.start {
                if row.open == nil { row.open = event.at }
            } else if let open = row.open {
                let start = max(open, from)
                if event.at > from, let a = iso.date(from: start), let b = iso.date(from: event.at) {
                    row.hours += b.timeIntervalSince(a) / 3600
                    row.shifts += 1
                }
                row.open = nil
            }
            rows[event.person] = row
        }
        var out: [ShiftRow] = []
        for (person, row) in rows {
            var hours: Double = row.hours
            if let open = row.open, let a = iso.date(from: max(open, from)), let b = iso.date(from: to) { hours += max(0, b.timeIntervalSince(a) / 3600) }
            let shifts: Int = row.shifts + (row.open == nil ? 0 : 1)
            let shift = ShiftRow(person: person, hours: (hours * 100).rounded() / 100, shifts: shifts, inSince: row.open)
            if shift.hours > 0 || shift.inSince != nil { out.append(shift) }
        }
        return out.sorted { $0.person < $1.person }
    }
}

// MARK: - Receipt printers (ESC/POS) and the cash drawer

/// Bytes for the small receipt printers most shops use (Epson, Star in ESC/POS mode, and most Bluetooth ones).
/// The receipt is sent as a picture, so Arabic, Kurdish and any other writing print exactly as on screen.
public enum EscPos {
    public static let reset: [UInt8] = [0x1B, 0x40]
    /// Feed a little and cut (printers without a cutter ignore it).
    public static let cut: [UInt8] = [0x1B, 0x64, 0x04, 0x1D, 0x56, 0x42, 0x00]
    /// Kick the cash drawer plugged into the printer (pin 2, then pin 5 for drawers wired the other way).
    public static let openDrawer: [UInt8] = [0x1B, 0x70, 0x00, 0x19, 0xFA, 0x1B, 0x70, 0x01, 0x19, 0xFA]

    /// A black-and-white picture (`pixels`: row by row, true = black) as a raster image command, in bands of
    /// at most 255 rows (some printers can't take taller in one go).
    public static func raster(width: Int, height: Int, pixels: [Bool]) -> [UInt8] {
        guard width > 0, height > 0, pixels.count >= width * height else { return [] }
        let bytesPerRow = (width + 7) / 8
        var out: [UInt8] = []
        var top = 0
        while top < height {
            let rows = min(255, height - top)
            out += [0x1D, 0x76, 0x30, 0x00, UInt8(bytesPerRow & 0xFF), UInt8(bytesPerRow >> 8), UInt8(rows & 0xFF), UInt8(rows >> 8)]
            for y in top..<(top + rows) {
                for byte in 0..<bytesPerRow {
                    var value: UInt8 = 0
                    for bit in 0..<8 {
                        let x = byte * 8 + bit
                        if x < width && pixels[y * width + x] { value |= UInt8(0x80 >> bit) }
                    }
                    out.append(value)
                }
            }
            top += rows
        }
        return out
    }

    /// A whole receipt: reset, the picture, cut, and the drawer when it was a cash sale.
    public static func receipt(width: Int, height: Int, pixels: [Bool], openDrawer drawer: Bool) -> [UInt8] {
        reset + raster(width: width, height: height, pixels: pixels) + cut + (drawer ? openDrawer : [])
    }

    /// Splits bytes into pieces a Bluetooth connection can take at once.
    public static func chunks(_ bytes: [UInt8], size: Int) -> [[UInt8]] {
        guard size > 0 else { return [bytes] }
        return stride(from: 0, to: bytes.count, by: size).map { Array(bytes[$0..<min($0 + size, bytes.count)]) }
    }
}


// MARK: - Item options (size, add-ons)

public struct OptionChoice: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Added to the price (0: free, negative: cheaper).
    public var price: Double

    public init(id: String = UUID().uuidString, name: String, price: Double = 0) {
        self.id = id
        self.name = name
        self.price = price
    }
}

/// "Size: Small / Large +£0.50", "Add-ons: Oat milk +£0.40, Extra shot +£0.60".
public struct OptionGroup: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var choices: [OptionChoice]
    /// One must be chosen (a size).
    public var required: Bool
    /// More than one can be chosen (add-ons).
    public var many: Bool

    public init(id: String = UUID().uuidString, name: String, choices: [OptionChoice], required: Bool = false, many: Bool = false) {
        self.id = id
        self.name = name
        self.choices = choices
        self.required = required
        self.many = many
    }
}

public enum ItemOptions {
    /// The price with the chosen options.
    public static func price(base: Double, chosen: [OptionChoice]) -> Double {
        var total = base
        for choice in chosen { total += choice.price }
        return Money.round2(max(0, total))
    }

    /// "Latte (Large, Oat milk)"
    public static func label(_ name: String, chosen: [OptionChoice]) -> String {
        chosen.isEmpty ? name : name + " (" + chosen.map(\.name).joined(separator: ", ") + ")"
    }

    /// Every required group has exactly one choice, and single-choice groups have at most one.
    public static func complete(_ groups: [OptionGroup], chosen: [String: [OptionChoice]]) -> Bool {
        for group in groups {
            let picked = chosen[group.id] ?? []
            if group.required && picked.isEmpty { return false }
            if !group.many && picked.count > 1 { return false }
        }
        return true
    }
}

// MARK: - Variants

public enum Variants {
    /// The variants of an item (its sizes or colours), by name.
    public static func of(_ parent: String, in items: [PriceItem]) -> [PriceItem] {
        items.filter { $0.till?.variantOf == parent }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

// MARK: - Money-off vouchers

public struct Voucher: Codable, Equatable, Identifiable, Sendable {
    public var id: String { code }
    public var code: String
    /// `value` is a % (else money off).
    public var percent: Bool
    public var value: Double
    /// Only when the sale is at least this.
    public var minSpend: Double?
    /// yyyy-MM-dd, last day it can be used.
    public var expiry: String?
    /// How many times it can be used in all (nil: no limit).
    public var uses: Int?
    public var off: Bool?

    public init(code: String, percent: Bool, value: Double, minSpend: Double? = nil, expiry: String? = nil, uses: Int? = nil, off: Bool? = nil) {
        self.code = code
        self.percent = percent
        self.value = value
        self.minSpend = minSpend
        self.expiry = expiry
        self.uses = uses
        self.off = off
    }
}

public enum VoucherCheck: Equatable, Sendable {
    case ok(Double)
    case unknown, turnedOff, expired, usedUp, spendMore(Double)
}

public enum Vouchers {
    public static func normal(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Times it's been used (a refund of the whole sale gives the use back).
    public static func used(_ code: String, sales: [Sale]) -> Int {
        let wanted = normal(code)
        let refunded = Set(sales.compactMap(\.refundOf))
        return sales.filter { $0.refundOf == nil && $0.voucher.map(normal) == wanted && !refunded.contains($0.id) }.count
    }

    /// Money off for a sale of `subtotal`, or why it can't be used.
    public static func check(_ code: String, vouchers: [Voucher], sales: [Sale], subtotal: Double, today: String) -> VoucherCheck {
        guard let voucher = vouchers.first(where: { normal($0.code) == normal(code) }) else { return .unknown }
        if voucher.off == true { return .turnedOff }
        if let expiry = voucher.expiry, today > expiry { return .expired }
        if let uses = voucher.uses, used(code, sales: sales) >= uses { return .usedUp }
        if let min = voucher.minSpend, subtotal < min - 0.004 { return .spendMore(min) }
        let off = voucher.percent ? subtotal * min(voucher.value, 100) / 100 : voucher.value
        return .ok(Money.round2(min(max(0, off), subtotal)))
    }
}

// MARK: - Layaways

/// Goods kept for a customer: they pay deposits, and take the goods when it's paid off. The sale (stock, takings,
/// profit) happens on the day they collect; deposits are money held for them until then.
public struct Layaway: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case open, collected, cancelled
    }
    public var id: String
    public var shop: String
    public var customer: String
    public var lines: [SaleLine]
    public var at: String
    public var status: Status
    /// Last change (the latest change wins between tills).
    public var updated: String
    public var till: String?
    /// The sale when it was collected.
    public var sale: String?

    public init(id: String = UUID().uuidString, shop: String, customer: String, lines: [SaleLine], at: String, status: Status = .open,
                updated: String, till: String? = nil, sale: String? = nil) {
        self.id = id
        self.shop = shop
        self.customer = customer
        self.lines = lines
        self.at = at
        self.status = status
        self.updated = updated
        self.till = till
        self.sale = sale
    }

    public var total: Double {
        var sum = 0.0
        for line in lines { sum += line.gross }
        return Money.round2(sum)
    }
}

public enum Layaways {
    /// Deposits paid on it so far (less any given back).
    public static func paid(_ id: String, events: [CashEvent]) -> Double {
        var sum = 0.0
        for event in events where event.kind == .deposit && event.ref == id { sum += event.amount }
        return Money.round2(sum)
    }

    public static func left(_ layaway: Layaway, events: [CashEvent]) -> Double {
        Money.round2(max(0, layaway.total - paid(layaway.id, events: events)))
    }

    /// The same layaway changed on two tills: the latest change wins.
    public static func merge(_ lists: [[Layaway]]) -> [Layaway] {
        var best: [String: Layaway] = [:]
        for list in lists {
            for item in list where (best[item.id]?.updated ?? "") <= item.updated { best[item.id] = item }
        }
        return best.values.sorted { $0.at > $1.at }
    }
}

/// A gift card spent past its balance: two tills each spent it while offline, before either saw the other's sale.
/// Sales are never deleted or changed (each till only adds to its own files), so this is found and shown, not lost.
public struct Overspend: Equatable, Identifiable, Sendable {
    public var id: String { code + "|" + sale }
    public var code: String
    /// The sale that took it below zero.
    public var sale: String
    public var till: String?
    /// How far below zero it went (positive).
    public var over: Double
    public var at: String
}

public enum Overspends {
    /// Each card's spending in time order; any sale taking the balance below zero (to the penny) is listed.
    public static func find(cards: [GiftCard], sales: [Sale]) -> [Overspend] {
        var out: [Overspend] = []
        for card in cards {
            guard var left = Pence(card.amount) else { continue }
            let uses = sales.filter { sale in sale.payments.contains { $0.kind == .gift && $0.ref == card.code } }
                .sorted { ($0.at, $0.id) < ($1.at, $1.id) }
            for sale in uses {
                for part in sale.payments where part.kind == .gift && part.ref == card.code {
                    left = left - (Pence(part.amount) ?? .zero)
                }
                if left.value < 0 {
                    out.append(Overspend(code: card.code, sale: sale.id, till: sale.till, over: Pence(value: -left.value).pounds, at: sale.at))
                }
            }
        }
        return out.sorted { $0.at > $1.at }
    }
}
