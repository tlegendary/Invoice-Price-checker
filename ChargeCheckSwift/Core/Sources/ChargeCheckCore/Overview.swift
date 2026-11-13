import Foundation

/// Money ChargeCheck caught: overcharges and missing goods taken off what you pay.
public struct Savings: Equatable, Sendable {
    public var overcharges: Double = 0
    /// Items missing, returned or short on delivery, with their VAT.
    public var missing: Double = 0
    /// Credits suppliers actually sent back.
    public var creditsReceived: Double = 0
    /// Invoices where something was caught.
    public var invoices: Int = 0

    public init(overcharges: Double = 0, missing: Double = 0, creditsReceived: Double = 0, invoices: Int = 0) {
        self.overcharges = overcharges
        self.missing = missing
        self.creditsReceived = creditsReceived
        self.invoices = invoices
    }

    /// Overcharges + missing goods. Credits are how that money came back, so they aren't added on top.
    public var total: Double { Money.round2(overcharges + missing) }
}

/// Something on the Home screen that needs the owner.
public struct Attention: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Saved invoices that weren't fully checked.
        case notChecked
        /// Credits asked for more than two weeks ago that haven't arrived.
        case creditsLate
        /// Invoices past their payment due date.
        case overdue
        /// Invoices due in the next 7 days.
        case dueSoon
        /// Price rises this month.
        case priceRises
    }
    public var id: String { kind.rawValue }
    public var kind: Kind
    public var count: Int
    public var amount: Double

    public init(kind: Kind, count: Int, amount: Double) {
        self.kind = kind
        self.count = count
        self.amount = amount
    }
}

/// The Home screen figures: where the business stands, readable in five seconds.
public struct Overview: Equatable, Sendable {
    /// What you owe suppliers now, and to how many.
    public var owed: Double
    public var suppliersOwed: Int
    public var spentThisMonth: Double
    public var invoicesThisMonth: Int
    public var paidThisWeek: Double
    public var savedThisMonth: Savings
    public var savedAllTime: Savings
    /// Price rises this month and what they cost you on those invoices.
    public var risesThisMonth: [PriceRise]
    public var risesCost: Double
    /// Credits asked for that haven't arrived yet.
    public var creditsOwed: Double
    /// About how much a month buying each item from your cheapest supplier would save.
    public var cheaperElsewhere: Double
    /// The supplier whose prices went up the most this month.
    public var risingSupplier: String?
    public var attention: [Attention]

    /// "You may have lost" this month: price rises paid + credits still not back.
    public var lostThisMonth: Double { Money.round2(risesCost + creditsOwed) }
}

public enum OverviewMaths {
    /// Overcharges and missing goods caught on one invoice.
    public static func caught(_ entry: HistoryEntry) -> (overcharges: Double, missing: Double) {
        let less = entry.amountToPay.less
        guard less > 0.005 else { return (0, 0) }
        let overcharges = min(less, Money.round2(entry.over + entry.overVat))
        return (overcharges, Money.round2(less - overcharges))
    }

    public static func savings(_ entries: [HistoryEntry]) -> Savings {
        var s = Savings()
        for entry in entries {
            let c = caught(entry)
            s.overcharges += c.overcharges
            s.missing += c.missing
            if c.overcharges + c.missing > 0.005 { s.invoices += 1 }
            if let credit = entry.credit, credit.status == CreditInfo.received { s.creditsReceived += credit.amount }
        }
        s.overcharges = Money.round2(s.overcharges)
        s.missing = Money.round2(s.missing)
        s.creditsReceived = Money.round2(s.creditsReceived)
        return s
    }

    /// What a price rise cost on the invoice that had it: (new − old) × the quantity that arrived.
    public static func cost(of rise: PriceRise, in entries: [HistoryEntry]) -> Double {
        guard let entry = entries.first(where: { $0.id == rise.invoiceID }) else { return 0 }
        let line = entry.lines.first { line in
            !line.excluded && abs(line.unit - rise.to) < 0.005 && (line.item.isEmpty ? line.desc : line.item) == rise.item
        }
        guard let line else { return 0 }
        return Money.round2(max(0, line.qty - line.short) * (rise.to - rise.from))
    }

    public static func make(entries: [HistoryEntry], payments: [SupplierPayment], trusted: [String],
                            creditDays: [String: Int] = [:], now: Date = Date()) -> Overview {
        let today = SupplierAccounts.dayText(now)
        let month = String(today.prefix(7))
        let accounts = SupplierAccounts.accounts(entries: entries, payments: payments, trusted: trusted, now: now)
        let owing = accounts.filter { $0.balance > 0.005 }
        let inMonth = entries.filter { $0.savedAt.hasPrefix(month) }

        let rises = Insights.priceRises(entries, since: month + "-01")
        let risesCost = Money.round2(rises.reduce(0) { $0 + cost(of: $1, in: entries) })
        var bySupplier: [String: (name: String, cost: Double)] = [:]
        for rise in rises {
            let k = SupplierAccounts.key(rise.supplier)
            bySupplier[k] = (rise.supplier, (bySupplier[k]?.cost ?? 0) + cost(of: rise, in: entries) + rise.percent / 1_000_000)
        }

        let owedCredits = entries.compactMap { $0.credit }.filter { $0.isOwed }
        let tips = Insights.supplierTips(entries, now: now)

        var attention: [Attention] = []
        let unchecked = entries.filter { !$0.verified && !$0.totalOnly }
        if !unchecked.isEmpty { attention.append(Attention(kind: .notChecked, count: unchecked.count, amount: 0)) }
        let late = SupplierAccounts.dayText(now.addingTimeInterval(-14 * 86_400))
        let lateCredits = owedCredits.filter { ($0.at.map { String($0.prefix(10)) } ?? today) <= late }
        if !lateCredits.isEmpty {
            attention.append(Attention(kind: .creditsLate, count: lateCredits.count,
                                       amount: Money.round2(lateCredits.reduce(0) { $0 + $1.amount })))
        }
        let dues = DueDates.open(accounts: accounts, creditDays: creditDays, now: now)
        let overdue = dues.filter { $0.daysLeft < 0 }
        if !overdue.isEmpty {
            attention.append(Attention(kind: .overdue, count: overdue.count, amount: Money.round2(overdue.reduce(0) { $0 + $1.amount })))
        }
        let soon = dues.filter { $0.daysLeft >= 0 && $0.daysLeft <= 7 }
        if !soon.isEmpty {
            attention.append(Attention(kind: .dueSoon, count: soon.count, amount: Money.round2(soon.reduce(0) { $0 + $1.amount })))
        }
        if !rises.isEmpty { attention.append(Attention(kind: .priceRises, count: rises.count, amount: risesCost)) }

        return Overview(
            owed: Money.round2(owing.reduce(0) { $0 + $1.balance }),
            suppliersOwed: owing.count,
            spentThisMonth: Money.round2(inMonth.reduce(0) { $0 + $1.amountToPay.total }),
            invoicesThisMonth: inMonth.count,
            paidThisWeek: Money.round2(accounts.reduce(0) { $0 + $1.paidThisWeek }),
            savedThisMonth: savings(inMonth),
            savedAllTime: savings(entries),
            risesThisMonth: rises,
            risesCost: risesCost,
            creditsOwed: Money.round2(owedCredits.reduce(0) { $0 + $1.amount }),
            cheaperElsewhere: Money.round2(tips.reduce(0) { $0 + $1.savingMonth }),
            risingSupplier: bySupplier.values.max { $0.cost < $1.cost }?.name,
            attention: attention)
    }
}
