import Foundation

/// One line of an invoice being checked.
public struct CheckLine: Identifiable, Equatable, Sendable {
    public var id: String
    public var qty: Double
    public var desc: String
    /// The name as the reader gave it (used to learn the user's corrections).
    public var read: String
    public var unit: Double
    public var vat: Double
    public var warn: String
    /// Missing or returned: left out of the overcharge and taken off what to pay.
    public var excluded: Bool
    public var matchId: String?
    /// nil = no match, true = sure, false = not 100% sure.
    public var confident: Bool?
    public var reads: Int
    public var disagree: Bool
    public var onlySecondRead: Bool
    public var altQty: Double?
    public var altUnit: Double?
    /// The user has looked at this line and confirmed it.
    public var ok: Bool
    /// The user said this item is not in their price list (nothing to compare).
    public var noBase: Bool
    /// Delivery check: how many of `qty` didn't arrive (taken off what to pay, like a missing line).
    public var short: Double

    /// What was really delivered.
    public var received: Double { max(0, qty - short) }

    public init(id: String = UUID().uuidString, qty: Double = 1, desc: String = "", read: String = "", unit: Double = 0, vat: Double = 0,
                warn: String = "", excluded: Bool = false, matchId: String? = nil, confident: Bool? = nil, reads: Int = 0,
                disagree: Bool = false, onlySecondRead: Bool = false, altQty: Double? = nil, altUnit: Double? = nil,
                ok: Bool = false, noBase: Bool = false, short: Double = 0) {
        self.id = id
        self.qty = qty
        self.desc = desc
        self.read = read
        self.unit = unit
        self.vat = vat
        self.warn = warn
        self.excluded = excluded
        self.matchId = matchId
        self.confident = confident
        self.reads = reads
        self.disagree = disagree
        self.onlySecondRead = onlySecondRead
        self.altQty = altQty
        self.altUnit = altUnit
        self.ok = ok
        self.noBase = noBase
        self.short = short
    }
}

/// An invoice being checked (before it is saved to Reports).
public struct InvoiceDraft: Identifiable, Equatable, Sendable {
    public var id: String
    public var supplier: String
    public var invNo: String
    public var date: String
    public var lines: [CheckLine]
    /// The "Total Net Amount" printed on the invoice, used to check every line was read right.
    public var printedNet: Double?
    public var printedTotal: Double?
    /// The user accepted that the total doesn't match what was read.
    public var totalAcknowledged: Bool
    public var passes: Int
    public var shopId: String
    /// A trusted supplier: only the total counts, the lines aren't checked.
    public var totalOnly: Bool = false

    public init(id: String = UUID().uuidString, supplier: String = "", invNo: String = "", date: String = "", lines: [CheckLine] = [],
                printedNet: Double? = nil, printedTotal: Double? = nil, totalAcknowledged: Bool = false, passes: Int = 0, shopId: String = "") {
        self.id = id
        self.supplier = supplier
        self.invNo = invNo
        self.date = date
        self.lines = lines
        self.printedNet = printedNet
        self.printedTotal = printedTotal
        self.totalAcknowledged = totalAcknowledged
        self.passes = passes
        self.shopId = shopId
    }
}

public struct LineResult: Equatable, Sendable {
    public var item: PriceItem?
    public var net: Double
    public var vat: Double
    public var base: Double?
    public var diff: Double
    public var over: Double
    public var overVat: Double
    public var under: Double
}

public struct InvoiceTotals: Equatable, Sendable {
    public var net = 0.0
    public var vat = 0.0
    public var total = 0.0
    public var over = 0.0
    public var overVat = 0.0
    public var under = 0.0
    public var excluded = 0.0
    public var unmatched = 0
    /// Lines that need the user to look at them.
    public var needLook = 0
    public var totalKnown = false
    public var totalOk = false
    public var totalProblem = false
    public var reviewCount: Int { needLook + (totalProblem ? 1 : 0) }
    public var verified: Bool { reviewCount == 0 }
}

/// The price list, ready for quick look-ups while checking an invoice.
/// Worked out the first time it's asked for, then kept (safe from any thread).
final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private let make: @Sendable () -> Value

    init(_ make: @escaping @Sendable () -> Value) { self.make = make }

    var get: Value {
        lock.lock()
        defer { lock.unlock() }
        if let value { return value }
        let made = make()
        value = made
        return made
    }
}

public struct PriceBook: Sendable {
    public let items: [PriceItem]
    private let byID: [String: PriceItem]
    private let words: Once<Set<String>>
    private let ready: Once<[Matcher.Prepared]>

    /// Words from the price list, for cleaning up what the reader read. Worked out once, when first needed.
    public var knownWords: Set<String> { words.get }
    /// The items with their words already split, for matching. Worked out once, when first needed.
    public var prepared: [Matcher.Prepared] { ready.get }

    /// Cheap to make: screens build one just to look items up. The heavier lists above wait until a scan needs them.
    public init(_ items: [PriceItem]) {
        self.items = items
        var map: [String: PriceItem] = [:]
        for item in items { map[item.id] = item }
        byID = map
        words = Once { InvoiceParser.knownWords(items) }
        ready = Once { items.map(Matcher.prepare) }
    }

    public func item(_ id: String?) -> PriceItem? {
        guard let id else { return nil }
        return byID[id]
    }
}

/// Shop staff write on the paper invoice when an item didn't arrive or went back: "Retrn", "missing", "damaged".
/// The photo reader picks that up as part of the item's name.
public enum HandNote {
    private static let words: Set<String> = ["retrn", "retn", "rtn", "return", "returned", "returns", "missing", "mising",
                                             "misssing", "damaged", "damage"]

    /// The item's name without a hand-written note at the end, and the note if there was one.
    public static func split(_ text: String) -> (name: String, note: String?) {
        var parts = text.split(separator: " ").map(String.init)
        guard parts.count >= 2, let last = parts.last, words.contains(last.lowercased().filter { $0.isLetter }) else {
            return (text, nil)
        }
        parts.removeLast()
        // a cross or tick drawn next to the note
        while parts.count > 1, let mark = parts.last, ["x", "X", "×", "-", "/", "✓", "✗"].contains(mark) { parts.removeLast() }
        return (parts.joined(separator: " "), last)
    }
}

public enum InvoiceMaths {
    /// Turns a line read from the invoice into a line to check, matched to the price list.
    /// `nameFixes` are the user's earlier corrections (what the reader gave → what they typed).
    public static func makeLine(_ parsed: ParsedLine, book: PriceBook, nameFixes: [String: String] = [:], supplier: String = "") -> CheckLine {
        var desc = InvoiceParser.plainLetters(parsed.desc)
        let read = desc
        // a note written by hand after the name ("Retrn", "x missing") isn't part of the item's name
        desc = HandNote.split(desc).name
        if !desc.isEmpty, let fixed = nameFixes[TextTools.norm(desc)], !fixed.isEmpty { desc = fixed }
        var match = desc.isEmpty ? MatchResult(itemID: nil, confident: false) : Matcher.match(desc, prepared: book.prepared)
        if match.itemID == nil, !parsed.raw.isEmpty, parsed.raw != desc { match = Matcher.match(InvoiceParser.plainLetters(parsed.raw), prepared: book.prepared) }
        if match.itemID == nil, let byPrice = matchByPrice(desc, unit: parsed.unit, supplier: supplier, book: book) {
            // the name is too garbled to read: one item in the list has exactly this price – suggest it, never sure
            match = MatchResult(itemID: byPrice, confident: false)
        }
        return CheckLine(qty: parsed.qty == 0 ? 1 : parsed.qty, desc: desc, read: read, unit: parsed.unit, vat: parsed.vat, warn: parsed.warn,
                         matchId: match.itemID, confident: match.itemID == nil ? nil : match.confident, reads: parsed.reads,
                         disagree: parsed.disagree, onlySecondRead: parsed.onlySecondRead, altQty: parsed.altQty, altUnit: parsed.altUnit)
    }

    /// The only item whose agreed price is exactly this price (for this supplier); if several share it,
    /// the one whose name is closest, and only when the name gives it some support.
    static func matchByPrice(_ desc: String, unit: Double, supplier: String, book: PriceBook) -> String? {
        guard unit > 0 else { return nil }
        let same = book.items.filter { abs($0.basePrice(for: supplier) - unit) < 0.005 }
        if same.count == 1 { return same[0].id }
        guard same.count > 1, !desc.isEmpty else { return nil }
        let scored = same.map { ($0.id, Matcher.score(desc, item: $0)) }.sorted { $0.1 > $1.1 }
        guard scored[0].1 >= 0.25, scored[0].1 > scored[1].1 + 0.1 else { return nil }
        return scored[0].0
    }

    public static func lineResult(_ line: CheckLine, supplier: String, book: PriceBook, tolerance: Double = 0.01) -> LineResult {
        let item = book.item(line.matchId)
        let net = Money.round2(line.qty * line.unit)
        let vat = Money.round2(net * line.vat / 100)
        let base = item?.basePrice(for: supplier)
        var result = LineResult(item: item, net: net, vat: vat, base: base, diff: 0, over: 0, overVat: 0, under: 0)
        if let base, !line.excluded {
            result.diff = Money.round2(line.unit - base)
            let tol = max(0.01, tolerance)
            if result.diff >= tol - 1e-9 {
                result.over = Money.round2(result.diff * line.qty)
                result.overVat = Money.round2(result.over * line.vat / 100)
            } else if result.diff <= -0.01 {
                result.under = Money.round2(-result.diff * line.qty)
            }
        }
        return result
    }

    /// Why a line needs the user to look at it (empty = fine).
    public static func reasons(_ line: CheckLine, supplier: String, book: PriceBook, totalOk: Bool) -> [String] {
        if line.excluded || line.ok { return [] }
        var out: [String] = []
        if !line.warn.isEmpty && !totalOk { out.append(line.warn) }
        if line.disagree && !totalOk { out.append(CoreText.t("The two reads of the photo didn't agree on this line.")) }
        if let note = HandNote.split(line.read).note {
            out.append(CoreText.t("Handwritten on this line: “{1}”. If it was missing or sent back, mark the line as missing or returned.", note))
        }
        if line.onlySecondRead { out.append(CoreText.t("Only found on the second read – make sure it's really on the invoice.")) }
        if line.matchId == nil && !line.noBase { out.append(CoreText.t("Not in your price list – choose the matching item or mark it as not in your list.")) }
        if let item = book.item(line.matchId) {
            let base = item.basePrice(for: supplier)
            if line.confident == false { out.append(CoreText.t("Not 100% sure this is “{1}”.", item.name)) }
            if let sizes = PackSize.mismatch(invoice: line.desc, item: item.name) {
                // the right product in a different pack: the agreed price doesn't apply as it stands
                out.append(CoreText.t("The invoice says {1} but your item is {2} – check it's the same pack size.", sizes.invoice, sizes.item))
            }
            if base > 0 && abs(line.unit - base) / base > 0.35 {
                out.append(CoreText.t("Price is very different from your price ({1}) – wrong item or misread?", Money.format(base)))
            }
        }
        return out
    }

    public static func totals(_ invoice: InvoiceDraft, book: PriceBook, tolerance: Double = 0.01) -> InvoiceTotals {
        var t = InvoiceTotals()
        for line in invoice.lines {
            let c = lineResult(line, supplier: invoice.supplier, book: book, tolerance: tolerance)
            t.net += c.net
            t.vat += c.vat
            t.over += c.over
            t.overVat += c.overVat
            t.under += c.under
            if line.excluded {
                t.excluded += c.net
            } else {
                if line.short > 0 { t.excluded += Money.round2(min(line.short, line.qty) * line.unit) }
                if c.item == nil { t.unmatched += 1 }
            }
        }
        t.net = Money.round2(t.net)
        t.vat = Money.round2(t.vat)
        t.over = Money.round2(t.over)
        t.overVat = Money.round2(t.overVat)
        t.under = Money.round2(t.under)
        t.excluded = Money.round2(t.excluded)
        t.total = Money.round2(t.net + t.vat)
        let printed = invoice.printedNet ?? 0
        t.totalKnown = printed != 0
        t.totalOk = t.totalKnown && abs(printed - t.net) <= 0.05
        for line in invoice.lines where !reasons(line, supplier: invoice.supplier, book: book, totalOk: t.totalOk).isEmpty { t.needLook += 1 }
        t.totalProblem = t.totalKnown && !t.totalOk && !invoice.totalAcknowledged
        return t
    }

    /// The invoice as it is kept in Reports.
    /// What the read lines add up to with VAT (for an invoice whose printed total couldn't be read).
    public static func linesTotal(_ lines: [ParsedLine]) -> Double {
        Money.round2(lines.reduce(0) { sum, line in
            let net = Money.round2(line.qty * line.unit)
            return sum + net + Money.round2(net * line.vat / 100)
        })
    }

    public static func historyEntry(_ invoice: InvoiceDraft, book: PriceBook, tolerance: Double = 0.01, existing: HistoryEntry? = nil) -> HistoryEntry {
        let t = totals(invoice, book: book, tolerance: tolerance)
        let lines = invoice.lines.map { line -> HistoryLine in
            let c = lineResult(line, supplier: invoice.supplier, book: book, tolerance: tolerance)
            return HistoryLine(qty: line.qty, desc: line.desc, unit: line.unit, vat: line.vat, matchId: line.matchId, item: c.item?.name ?? "",
                               base: c.base, over: c.over, excluded: line.excluded, noBase: line.noBase,
                               short: line.excluded ? 0 : min(line.short, line.qty))
        }
        if invoice.totalOnly {
            let total = Money.round2(invoice.printedTotal ?? invoice.printedNet ?? 0)
            return HistoryEntry(id: existing?.id ?? invoice.id, shopId: invoice.shopId, supplier: invoice.supplier, invNo: invoice.invNo,
                                date: invoice.date, net: Money.round2(invoice.printedNet ?? total), total: total, over: 0,
                                verified: true, paid: existing?.paid, file: existing?.file, credit: existing?.credit, lines: [], totalOnly: true)
        }
        return HistoryEntry(id: existing?.id ?? invoice.id, shopId: invoice.shopId, supplier: invoice.supplier, invNo: invoice.invNo,
                            date: invoice.date, net: t.net, total: t.total, over: t.over, overVat: t.overVat, excluded: t.excluded,
                            verified: t.verified, paid: existing?.paid, file: existing?.file, credit: existing?.credit, lines: lines)
    }

    /// An invoice already in Reports that looks like the same one (so it is replaced, not saved twice).
    public static func duplicate(of invoice: InvoiceDraft, net: Double, in history: [HistoryEntry]) -> HistoryEntry? {
        history.first { entry in
            guard entry.id != invoice.id else { return false }
            guard TextTools.norm(entry.supplier) == TextTools.norm(invoice.supplier), entry.date == invoice.date else { return false }
            if !invoice.invNo.isEmpty { return entry.invNo == invoice.invNo }
            return net > 0 && abs(entry.net - net) < 0.01
        }
    }
}
