import Foundation

/// How a payment is taken.
public enum PaymentChannel: Codable, Hashable, Sendable {
    case cash
    /// A separate card machine; the till only hears about it from the cashier.
    case externalTerminal(label: String?)
    /// A card company connected to the app (Stripe, Square, SumUp, Adyen, Tap to Pay…), by its ID.
    case provider(String)

    /// Only a connected card company can confirm a payment by itself.
    public var canVerify: Bool { if case .provider = self { return true } else { return false } }
}

public enum PaymentStatus: String, Codable, Sendable {
    case created, pending, approved, declined, cancelled, failed
    /// Asked, but no clear answer (a timeout, the app closed): check before doing anything else.
    case unknown

    /// No further answer changes it (refunds aside).
    public var isFinal: Bool { self == .approved || self == .declined || self == .cancelled || self == .failed }
}

/// Something that happened to a payment.
public enum PaymentEvent: Codable, Equatable, Sendable {
    case submitted
    case approved(reference: String?)
    case declined(reason: String?)
    case cancelled
    case failed(reason: String?)
    /// No answer in time: the money may or may not have been taken.
    case timedOut
    /// Cash counted, or the separate card machine said approved: the cashier says so.
    case confirmedByCashier(by: String, reference: String?)
    case refunded(id: String, amount: Pence, reference: String?)
}

public struct PaymentRefund: Codable, Equatable, Sendable {
    public var id: String
    public var amount: Pence
    public var reference: String?
    public var at: Date
}

public struct PaymentLogEntry: Codable, Equatable, Sendable {
    public var event: PaymentEvent
    public var at: Date
    /// What the rules did with it.
    public var outcome: String
}

/// One go at taking a payment: kept from before the card company is asked, so a crash or timeout can never lead to
/// charging twice (the same `idempotencyKey` is reused for every retry of this attempt).
public struct PaymentAttempt: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var saleID: String
    /// Sent with every request for this attempt; a card company treats repeats as the same payment.
    public var idempotencyKey: String
    public var amount: Pence
    /// ISO currency code ("GBP"); never converted.
    public var currency: String
    public var channel: PaymentChannel
    public private(set) var status: PaymentStatus = .created
    /// Confirmed by the card company itself. A cashier's word (cash, a separate card machine) is never "verified".
    public private(set) var verified = false
    public private(set) var reference: String?
    public private(set) var confirmedBy: String?
    public private(set) var refunds: [PaymentRefund] = []
    /// Set when answers contradict each other: a person must look.
    public private(set) var needsReview: String?
    public private(set) var log: [PaymentLogEntry] = []
    public var createdAt: Date

    public init(id: String = UUID().uuidString, saleID: String, amount: Pence, currency: String, channel: PaymentChannel,
                idempotencyKey: String? = nil, at: Date) {
        self.id = id
        self.saleID = saleID
        self.idempotencyKey = idempotencyKey ?? id
        self.amount = amount
        self.currency = currency
        self.channel = channel
        self.createdAt = at
    }

    public enum Result: Equatable, Sendable {
        case changed
        /// The same thing again (a repeated callback): nothing to do.
        case ignored
        case refused(String)
    }

    public var refunded: Pence { refunds.reduce(.zero) { $0 + $1.amount } }
    /// What can still be given back.
    public var refundable: Pence { status == .approved ? amount - refunded : .zero }
    /// Money actually taken and kept.
    public var kept: Pence { status == .approved ? amount - refunded : .zero }

    @discardableResult
    public mutating func apply(_ event: PaymentEvent, at now: Date) -> Result {
        let result = decide(event)
        let outcome: String
        switch result {
        case .changed: outcome = "changed to \(status.rawValue)"
        case .ignored: outcome = "ignored (same as before)"
        case .refused(let why): outcome = "refused: \(why)"
        }
        log.append(PaymentLogEntry(event: event, at: now, outcome: outcome))
        if case .refund(let refund) = pendingRefund(event, at: now), result == .changed { refunds.append(refund) }
        return result
    }

    private enum Pending { case refund(PaymentRefund), none }

    private func pendingRefund(_ event: PaymentEvent, at now: Date) -> Pending {
        if case let .refunded(id, amount, reference) = event {
            return .refund(PaymentRefund(id: id, amount: amount, reference: reference, at: now))
        }
        return .none
    }

    private mutating func decide(_ event: PaymentEvent) -> Result {
        switch event {
        case .submitted:
            switch status {
            case .created: status = .pending; return .changed
            case .pending, .unknown: return .ignored
            default: return .refused("already \(status.rawValue)")
            }

        case .approved(let ref):
            guard channel.canVerify else { return .refused("only a connected card company can approve by itself") }
            return settle(.approved, reference: ref, verified: true)

        case .declined, .cancelled, .failed:
            let target: PaymentStatus
            switch event {
            case .declined: target = .declined
            case .cancelled: target = .cancelled
            default: target = .failed
            }
            return settle(target, reference: nil, verified: false)

        case .timedOut:
            guard status == .pending else { return status == .unknown ? .ignored : .refused("not waiting for an answer") }
            status = .unknown
            return .changed

        case let .confirmedByCashier(by, ref):
            guard !channel.canVerify else { return .refused("a connected card company's payment can't be approved by hand") }
            if status == .approved { return confirmedBy == by && reference == ref ? .ignored : .refused("already approved") }
            guard status == .created || status == .pending else { return .refused("already \(status.rawValue)") }
            guard !by.trimmingCharacters(in: .whitespaces).isEmpty else { return .refused("who confirmed it is needed") }
            status = .approved
            confirmedBy = by
            reference = ref
            return .changed

        case let .refunded(id, amount, _):
            guard status == .approved else { return .refused("only an approved payment can be refunded") }
            if refunds.contains(where: { $0.id == id }) { return .ignored }
            guard amount.value > 0, amount <= refundable else { return .refused("more than can be refunded") }
            return .changed
        }
    }

    /// A final answer. The same answer again is ignored; a different one after a final answer is never applied
    /// silently: it's refused and the payment is marked for a person to check.
    private mutating func settle(_ target: PaymentStatus, reference ref: String?, verified: Bool) -> Result {
        if status == target { return .ignored }
        if status.isFinal {
            needsReview = "said \(status.rawValue), then \(target.rawValue)"
            return .refused("contradicts the earlier answer")
        }
        status = target
        if let ref { reference = ref }
        self.verified = verified && target == .approved
        return .changed
    }
}

/// Where a sale's payments stand, across all its attempts (split payments).
public struct PaymentSummary: Equatable, Sendable {
    public var due: Pence
    /// Approved and kept (refunds taken off).
    public var paid: Pence
    /// Asked for but not answered yet, or unknown: not paid, and not to be asked for again.
    public var waiting: Pence
    public var remaining: Pence
    /// Paid beyond what's due (cash change is handled before it gets here).
    public var over: Pence
    /// Something no one can be sure of: a timeout or contradicting answers.
    public var needsChecking: Bool

    public init(due: Pence, attempts: [PaymentAttempt]) {
        self.due = due
        paid = attempts.reduce(.zero) { $0 + $1.kept }
        waiting = attempts.filter { $0.status == .pending || $0.status == .unknown || $0.status == .created }
            .reduce(.zero) { $0 + $1.amount }
        let left = due - paid
        remaining = left.value > 0 ? left : .zero
        over = left.value < 0 ? Pence(value: -left.value) : .zero
        needsChecking = attempts.contains { $0.status == .unknown || $0.needsReview != nil }
    }

    /// Can another card payment be started? Not while one might still go through.
    public var canAskForMore: Bool { remaining.value > 0 && waiting.value == 0 && !needsChecking }
    public var isPaid: Bool { remaining.value == 0 && waiting.value == 0 }
}
