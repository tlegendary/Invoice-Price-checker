import Foundation

/// "Bravo sells this cheaper": the same item bought from more than one supplier, from your own invoices.
public struct SupplierTip: Identifiable, Equatable, Sendable {
    public struct Price: Equatable, Sendable {
        public var supplier: String
        public var unit: Double
        /// When it was last bought at this price ("yyyy-MM-dd…").
        public var when: String
    }

    public var id: String { item }
    public var item: String
    /// Cheapest first.
    public var prices: [Price]
    /// Who you bought it from most recently.
    public var lastSupplier: String
    /// Saved per unit by buying from the cheapest supplier instead of the last one.
    public var savingEach: Double
    /// How many you bought in the last 30 days (to size the saving).
    public var boughtLately: Double
    /// About how much a month you'd save.
    public var savingMonth: Double

    public var cheapest: Price { prices[0] }
}

/// One month in plain numbers. Every figure comes from your saved invoices and payments.
public struct MonthSummary: Equatable, Sendable {
    public struct Rise: Equatable, Sendable {
        public var item: String
        public var supplier: String
        public var from: Double
        public var to: Double
    }

    public var month: String               // "2026-10"
    public var invoices: Int
    public var spent: Double               // invoice totals with VAT
    public var overcharged: Double         // overcharges + missing, with VAT
    public var bySupplier: [(name: String, spent: Double, overcharged: Double)]
    public var byShop: [(name: String, spent: Double)]
    public var rises: [Rise]
    public var creditsOwed: Double
    public var paid: Double
    public var owedNow: Double

    public static func == (a: MonthSummary, b: MonthSummary) -> Bool {
        a.month == b.month && a.invoices == b.invoices && a.spent == b.spent && a.overcharged == b.overcharged
            && a.bySupplier.map { "\($0.name)\($0.spent)\($0.overcharged)" } == b.bySupplier.map { "\($0.name)\($0.spent)\($0.overcharged)" }
            && a.byShop.map { "\($0.name)\($0.spent)" } == b.byShop.map { "\($0.name)\($0.spent)" }
            && a.rises == b.rises && a.creditsOwed == b.creditsOwed && a.paid == b.paid && a.owedNow == b.owedNow
    }
}

public enum Insights {
    /// The item a line is: its price-list item if matched, otherwise its name.
    static func itemKey(_ line: HistoryLine) -> (key: String, name: String)? {
        let name = line.item.isEmpty ? line.desc : line.item
        let key = line.matchId.map { "id:" + $0 } ?? "name:" + SupplierAccounts.key(name)
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, key.count > 5, line.unit > 0, !line.excluded else { return nil }
        return (key, name)
    }

    /// Items you've bought from more than one supplier where one is cheaper, biggest saving first.
    public static func supplierTips(_ entries: [HistoryEntry], now: Date = Date()) -> [SupplierTip] {
        let recent = SupplierAccounts.dayText(now.addingTimeInterval(-30 * 86_400))
        let newestFirst = entries.filter { !$0.totalOnly && !$0.supplier.isEmpty }.sorted { $0.savedAt > $1.savedAt }
        // item -> supplier key -> latest price
        var latest: [String: [String: SupplierTip.Price]] = [:]
        var names: [String: String] = [:]
        var last: [String: String] = [:]
        var lately: [String: Double] = [:]
        for entry in newestFirst {
            let who = SupplierAccounts.key(entry.supplier)
            for line in entry.lines {
                guard let found = itemKey(line) else { continue }
                let key = found.key, name = found.name
                names[key] = names[key] ?? name
                last[key] = last[key] ?? entry.supplier
                if String(entry.savedAt.prefix(10)) >= recent { lately[key, default: 0] += line.qty }
                if latest[key]?[who] == nil {
                    latest[key, default: [:]][who] = SupplierTip.Price(supplier: entry.supplier, unit: line.unit, when: entry.savedAt)
                }
            }
        }
        var tips: [SupplierTip] = []
        for (key, bySupplier) in latest where bySupplier.count > 1 {
            let prices = bySupplier.values.sorted { $0.unit != $1.unit ? $0.unit < $1.unit : $0.supplier < $1.supplier }
            guard let lastName = last[key], let lastPrice = bySupplier[SupplierAccounts.key(lastName)] else { continue }
            let saving = Money.round2(lastPrice.unit - prices[0].unit)
            // only worth showing when the cheaper one isn't the one you already use, and it's at least 1% cheaper
            guard saving > 0.005, saving >= lastPrice.unit * 0.01 else { continue }
            let bought = lately[key] ?? 0
            tips.append(SupplierTip(item: names[key] ?? key, prices: prices, lastSupplier: lastName, savingEach: saving,
                                    boughtLately: bought, savingMonth: Money.round2(saving * bought)))
        }
        return tips.sorted { $0.savingMonth != $1.savingMonth ? $0.savingMonth > $1.savingMonth : $0.savingEach > $1.savingEach }
    }

    /// The figures for one month ("yyyy-MM"), using the day each invoice was saved.
    public static func month(_ month: String, entries: [HistoryEntry], payments: [SupplierPayment], shops: [ShopInfo] = [],
                             trusted: [String] = []) -> MonthSummary {
        let inMonth = entries.filter { $0.savedAt.hasPrefix(month) }
        var suppliers: [String: (name: String, spent: Double, over: Double)] = [:]
        var shopSpend: [String: Double] = [:]
        for entry in inMonth {
            let k = SupplierAccounts.key(entry.supplier.isEmpty ? CoreText.t("Unknown supplier") : entry.supplier)
            let amounts = entry.amountToPay
            var row = suppliers[k] ?? (entry.supplier.isEmpty ? CoreText.t("Unknown supplier") : entry.supplier, 0, 0)
            row.spent += amounts.total
            row.over += amounts.less
            suppliers[k] = row
            shopSpend[entry.shopId, default: 0] += amounts.total
        }
        // price rises: the item's price this month against its price the last time before this month, same supplier
        var rises: [MonthSummary.Rise] = []
        let before = entries.filter { $0.savedAt < month && !$0.totalOnly }.sorted { $0.savedAt > $1.savedAt }
        var seen = Set<String>()
        for entry in inMonth.sorted(by: { $0.savedAt > $1.savedAt }) where !entry.totalOnly {
            let who = SupplierAccounts.key(entry.supplier)
            for line in entry.lines {
                guard let found = itemKey(line), !seen.contains(who + found.key) else { continue }
                let key = found.key, name = found.name
                seen.insert(who + key)
                func sameItem(_ other: HistoryLine) -> Bool { itemKey(other)?.key == key }
                let earlier = before.first { old in SupplierAccounts.key(old.supplier) == who && old.lines.contains(where: sameItem) }
                guard let old = earlier?.lines.first(where: sameItem)?.unit, line.unit > old + 0.005 else { continue }
                rises.append(MonthSummary.Rise(item: name, supplier: entry.supplier, from: old, to: line.unit))
            }
        }
        rises.sort { ($0.to - $0.from) / max($0.from, 0.01) > ($1.to - $1.from) / max($1.from, 0.01) }
        let shopNames = Dictionary(shops.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let accounts = SupplierAccounts.accounts(entries: entries, payments: payments, trusted: trusted)
        return MonthSummary(
            month: month,
            invoices: inMonth.count,
            spent: Money.round2(inMonth.reduce(0) { $0 + $1.amountToPay.total }),
            overcharged: Money.round2(inMonth.reduce(0) { $0 + $1.amountToPay.less }),
            bySupplier: suppliers.values.sorted { $0.spent > $1.spent }
                .map { (name: $0.name, spent: Money.round2($0.spent), overcharged: Money.round2($0.over)) },
            byShop: shopSpend.count > 1
                ? shopSpend.map { (name: shopNames[$0.key] ?? CoreText.t("No shop"), spent: Money.round2($0.value)) }.sorted { $0.spent > $1.spent }
                : [],
            rises: rises,
            creditsOwed: Money.round2(entries.compactMap { $0.credit }.filter { $0.isOwed }.reduce(0) { $0 + $1.amount }),
            paid: Money.round2(payments.filter { $0.kind == .payment && $0.date.hasPrefix(month) }.reduce(0) { $0 + $1.amount }),
            owedNow: Money.round2(accounts.filter { $0.balance > 0.005 }.reduce(0) { $0 + $1.balance }))
    }

    /// The summary in plain sentences (used as is, or handed to Apple Intelligence to say it more naturally).
    public static func sentences(_ s: MonthSummary, monthName: String) -> [String] {
        let t = CoreText.t
        var out: [String] = []
        guard s.invoices > 0 else { return [t("No invoices were checked in {1}.", monthName)] }
        out.append(t("In {1} you checked {2} invoices worth {3}.", monthName, String(s.invoices), Money.format(s.spent)))
        if s.overcharged > 0.005 {
            let worst = s.bySupplier.filter { $0.overcharged > 0.005 }.max { $0.overcharged < $1.overcharged }
            if let worst {
                out.append(t("You were overcharged {1} in total, {2} of it by {3}.", Money.format(s.overcharged),
                             Money.format(worst.overcharged), worst.name))
            }
        } else {
            out.append(t("Nobody charged more than your agreed prices."))
        }
        if let top = s.bySupplier.first {
            out.append(t("You spent most with {1}: {2}.", top.name, Money.format(top.spent)))
        }
        if s.byShop.count > 1, let first = s.byShop.first {
            out.append(t("{1} spent the most: {2}.", first.name, Money.format(first.spent)))
        }
        for rise in s.rises.prefix(3) {
            out.append(t("{1} went up at {2}, from {3} to {4}.", rise.item, rise.supplier, Money.format(rise.from), Money.format(rise.to)))
        }
        if s.creditsOwed > 0.005 { out.append(t("Suppliers still owe you {1} in credits.", Money.format(s.creditsOwed))) }
        if s.paid > 0.005 { out.append(t("You paid suppliers {1} this month.", Money.format(s.paid))) }
        if s.owedNow > 0.005 { out.append(t("You owe {1} in total now.", Money.format(s.owedNow))) }
        return out
    }

    // MARK: - credit notes

    /// Words that mark a credit note rather than an invoice, in every language the app reads.
    public static func isCreditNote(_ text: String) -> Bool {
        let s = text.lowercased()
        return ["credit note", "credit memo", "creditnote", "gutschrift", "avoir", "note de crédit", "إشعار دائن", "اشعار دائن", "إشعار خصم",
                "پسوولەی گەڕاندنەوە"].contains { s.contains($0) }
    }

    /// The invoice a scanned credit note answers: same supplier, credit asked for, about the same amount (VAT or not).
    public static func creditMatch(supplier: String, amount: Double, in entries: [HistoryEntry]) -> HistoryEntry? {
        let who = SupplierAccounts.key(supplier)
        guard !who.isEmpty, amount > 0 else { return nil }
        return entries
            .filter { SupplierAccounts.key($0.supplier) == who && ($0.credit?.isOwed ?? false) }
            .sorted { $0.savedAt > $1.savedAt }
            .first { entry in
                let asked = entry.credit?.amount ?? 0
                return abs(asked - amount) <= max(0.05, asked * 0.02) || abs(entry.amountToPayBeforeVat.less - amount) <= 0.05
            }
    }
}
