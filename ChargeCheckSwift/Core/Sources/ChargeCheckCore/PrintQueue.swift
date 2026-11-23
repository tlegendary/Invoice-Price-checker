import Foundation

/// Receipts, kitchen tickets and reports waiting to print. A job is kept until the printer took it, so a printer
/// that's off, out of paper or out of range never loses a receipt; printing it again later says COPY on it.
public struct PrintJob: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case receipt, kitchen, report }
    public enum State: String, Codable, Sendable { case waiting, printed, failed }

    public var id: String
    public var kind: Kind
    /// What it's for (a sale's or ticket's ID), so the same thing is never queued twice by accident.
    public var source: String
    public var text: String
    public var state: State = .waiting
    public var attempts = 0
    public var lastError: String?
    public var copies = 0
    public var at: String

    public init(id: String = UUID().uuidString, kind: Kind, source: String, text: String, at: String) {
        self.id = id
        self.kind = kind
        self.source = source
        self.text = text
        self.at = at
    }
}

public struct PrintQueue: Codable, Equatable, Sendable {
    public private(set) var jobs: [PrintJob] = []
    /// After this many failures a job waits for a person to tap Print again.
    public static let maxAttempts = 3

    public init() {}

    /// Adds a job, unless one for the same thing is already waiting.
    @discardableResult
    public mutating func add(_ job: PrintJob) -> Bool {
        guard !jobs.contains(where: { $0.source == job.source && $0.kind == job.kind && $0.state != .printed }) else { return false }
        jobs.append(job)
        return true
    }

    /// The next job to send to the printer.
    public var next: PrintJob? { jobs.first { $0.state == .waiting } }

    public mutating func printed(_ id: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].state = .printed
    }

    public mutating func failed(_ id: String, error: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].attempts += 1
        jobs[i].lastError = error
        if jobs[i].attempts >= Self.maxAttempts { jobs[i].state = .failed }
    }

    /// Prints a job again on purpose: the reprint is marked COPY so it can't pass for a second sale.
    public mutating func reprint(_ id: String, at: String) -> PrintJob? {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return nil }
        if jobs[i].state == .failed {
            jobs[i].state = .waiting
            jobs[i].attempts = 0
            return jobs[i]
        }
        jobs[i].copies += 1
        var copy = PrintJob(kind: jobs[i].kind, source: jobs[i].source + "#copy\(jobs[i].copies)",
                            text: "*** COPY ***\n" + jobs[i].text, at: at)
        copy.copies = jobs[i].copies
        jobs.append(copy)
        return copy
    }

    public var waiting: Int { jobs.filter { $0.state == .waiting }.count }
    public var failedJobs: [PrintJob] { jobs.filter { $0.state == .failed } }

    /// Printed jobs older than this are dropped (the receipt itself is kept with the sale).
    public mutating func trim(before cutoff: String) {
        jobs.removeAll { $0.state == .printed && $0.at < cutoff }
    }
}
