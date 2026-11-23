import Foundation

/// What a card company is asked to do.
public struct ChargeRequest: Equatable, Sendable {
    public var saleID: String
    public var amount: Pence
    public var currency: String
    /// The attempt's key: a repeat with the same key is the same payment, never a second charge.
    public var idempotencyKey: String

    public init(saleID: String, amount: Pence, currency: String, idempotencyKey: String) {
        self.saleID = saleID
        self.amount = amount
        self.currency = currency
        self.idempotencyKey = idempotencyKey
    }
}

/// A card company's answer.
public enum ProviderAnswer: Equatable, Sendable {
    case approved(reference: String)
    case declined(reason: String?)
    case cancelled
    /// Still going (the customer is tapping, the bank is slow): ask again later.
    case pending
}

public enum ProviderError: Error, Equatable, Sendable {
    /// No answer in time: the money may or may not have been taken.
    case timeout
    case offline
    /// No merchant account or keys yet.
    case notConfigured
    case refused(String)
}

/// One card company. Each (Stripe Terminal, Square, SumUp, Adyen, Tap to Pay on iPhone) has an adapter in the app
/// that keeps its own SDK there; the Core only knows this.
public protocol PaymentProvider: Sendable {
    var id: String { get }
    func charge(_ request: ChargeRequest) async throws -> ProviderAnswer
    /// The answer for a key asked before (after a timeout or a restart). nil: the card company never got it.
    func status(idempotencyKey: String) async throws -> ProviderAnswer?
    func refund(reference: String, amount: Pence, refundID: String) async throws -> ProviderAnswer
}

/// Where attempts are kept: saved BEFORE a card company is asked, so nothing is lost if the app stops halfway.
public protocol PaymentAttemptStore: Sendable {
    func save(_ attempt: PaymentAttempt) async throws
    func open() async -> [PaymentAttempt]
}

/// Takes and recovers card payments with the rules in `PaymentAttempt`.
public struct PaymentRunner: Sendable {
    public let provider: PaymentProvider
    public let store: PaymentAttemptStore
    public var now: @Sendable () -> Date

    public init(provider: PaymentProvider, store: PaymentAttemptStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.store = store
        self.now = now
    }

    /// Asks the card company once. Saved first; a timeout or lost connection leaves it `unknown`, never failed, so
    /// `recover` asks what happened instead of charging again. Saving failing means the card company isn't asked.
    public func take(_ attempt: PaymentAttempt) async -> PaymentAttempt {
        var a = attempt
        a.apply(.submitted, at: now())
        do {
            try await store.save(a)
        } catch {
            a.apply(.failed(reason: "couldn't be saved before asking the card company"), at: now())
            return a
        }
        let request = ChargeRequest(saleID: a.saleID, amount: a.amount, currency: a.currency, idempotencyKey: a.idempotencyKey)
        do {
            let answer = try await provider.charge(request)
            apply(answer, to: &a)
        } catch ProviderError.notConfigured {
            a.apply(.failed(reason: "card payments aren't set up"), at: now())
        } catch ProviderError.refused(let why) {
            a.apply(.failed(reason: why), at: now())
        } catch {
            a.apply(.timedOut, at: now())
        }
        try? await store.save(a)
        return a
    }

    /// For an attempt without a clear answer: asks the card company, with the same key. Never charges again.
    public func recover(_ attempt: PaymentAttempt) async -> PaymentAttempt {
        var a = attempt
        guard a.status == .unknown || a.status == .pending else { return a }
        if a.status == .pending { a.apply(.timedOut, at: now()) }
        do {
            if let answer = try await provider.status(idempotencyKey: a.idempotencyKey) {
                apply(answer, to: &a)
            } else {
                // the card company never got it: nothing was taken
                a.apply(.failed(reason: "the card company has no record of it"), at: now())
            }
        } catch {
            // still no answer: stays unknown, ask again later
        }
        try? await store.save(a)
        return a
    }

    /// Every attempt left open by a crash or timeout, checked again (on launch).
    public func recoverAll() async -> [PaymentAttempt] {
        var out: [PaymentAttempt] = []
        for attempt in await store.open() where !attempt.status.isFinal {
            out.append(await recover(attempt))
        }
        return out
    }

    public func refund(_ attempt: PaymentAttempt, amount: Pence, refundID: String) async -> PaymentAttempt {
        var a = attempt
        guard let reference = a.reference, amount <= a.refundable, amount.value > 0 else { return a }
        if let answer = try? await provider.refund(reference: reference, amount: amount, refundID: refundID),
           case .approved(let ref) = answer {
            a.apply(.refunded(id: refundID, amount: amount, reference: ref), at: now())
            try? await store.save(a)
        }
        return a
    }

    private func apply(_ answer: ProviderAnswer, to a: inout PaymentAttempt) {
        switch answer {
        case .approved(let ref): a.apply(.approved(reference: ref), at: now())
        case .declined(let why): a.apply(.declined(reason: why), at: now())
        case .cancelled: a.apply(.cancelled, at: now())
        case .pending: break
        }
    }
}

/// A pretend card company for tests and the app's test mode. It takes each key once, like a real one.
public actor FakePaymentProvider: PaymentProvider {
    public enum Script: Sendable { case approve, decline, cancel, timeout, timeoutButCharged, offline }

    public nonisolated let id = "fake"
    private var script: [Script]
    /// key → answer, as a card company remembers them.
    private var seen: [String: ProviderAnswer] = [:]
    public private(set) var charges = 0
    private var counter = 0

    public init(_ script: [Script]) { self.script = script }

    public func charge(_ request: ChargeRequest) async throws -> ProviderAnswer {
        if let earlier = seen[request.idempotencyKey] { return earlier }
        let next = script.isEmpty ? .approve : script.removeFirst()
        switch next {
        case .approve: return record(request, .approved(reference: nextRef()), charged: true)
        case .decline: return record(request, .declined(reason: "card declined"), charged: false)
        case .cancel: return record(request, .cancelled, charged: false)
        case .timeout: throw ProviderError.timeout
        case .timeoutButCharged:
            _ = record(request, .approved(reference: nextRef()), charged: true)
            throw ProviderError.timeout
        case .offline: throw ProviderError.offline
        }
    }

    public func status(idempotencyKey: String) async throws -> ProviderAnswer? { seen[idempotencyKey] }

    public func refund(reference: String, amount: Pence, refundID: String) async throws -> ProviderAnswer {
        .approved(reference: "re_" + refundID)
    }

    private func record(_ request: ChargeRequest, _ answer: ProviderAnswer, charged: Bool) -> ProviderAnswer {
        seen[request.idempotencyKey] = answer
        if charged { charges += 1 }
        return answer
    }

    private func nextRef() -> String {
        counter += 1
        return "fake_\(counter)"
    }
}

/// Attempts kept in memory (tests).
public actor MemoryAttemptStore: PaymentAttemptStore {
    private var attempts: [String: PaymentAttempt] = [:]
    public var failSaving = false
    public init() {}
    public func setFailSaving(_ fail: Bool) { failSaving = fail }
    public func save(_ attempt: PaymentAttempt) async throws {
        if failSaving { throw ProviderError.refused("disk full") }
        attempts[attempt.id] = attempt
    }
    public func open() async -> [PaymentAttempt] { Array(attempts.values) }
}
