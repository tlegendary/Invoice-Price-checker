import Foundation

/// Takes out what could identify a person or an account before anything is sent to support: email addresses and
/// runs of 7 or more digits (card, phone and account numbers, even with spaces or dashes inside). Short numbers –
/// a receipt number, a count – stay, so the report still makes sense.
public enum Redact {
    public static func text(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, with: "[email]", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\+?\d(?:[ \-]?\d){6,}"#, with: "[number]", options: .regularExpression)
        return out
    }
}

/// What support needs to see when something isn't working, with nothing private in it.
public struct HealthReport: Equatable, Sendable {
    public var app: String
    public var system: String
    public var saves: [SaveFailure]
    /// Files not yet in iCloud, and since when.
    public var waitingForICloud: Int
    public var waitingSince: Date?
    /// Card payments without a final answer.
    public var openPayments: Int
    public var giftCardsSpentTwice: Int
    public var quarantinedFiles: Int

    public init(app: String, system: String, saves: [SaveFailure], waitingForICloud: Int, waitingSince: Date?,
                openPayments: Int, giftCardsSpentTwice: Int, quarantinedFiles: Int) {
        self.app = app
        self.system = system
        self.saves = saves
        self.waitingForICloud = waitingForICloud
        self.waitingSince = waitingSince
        self.openPayments = openPayments
        self.giftCardsSpentTwice = giftCardsSpentTwice
        self.quarantinedFiles = quarantinedFiles
    }

    public var text: String {
        let iso = ISO8601DateFormatter()
        var lines = ["ChargeCheck health report", "App: \(app)", "System: \(system)", ""]
        lines.append(saves.isEmpty ? "Saving: OK" : "Not saved (\(saves.count)):")
        for f in saves {
            lines.append("- \(f.area.rawValue): \(Redact.text(f.what)) ×\(f.count), last \(iso.string(from: f.at)): \(Redact.text(f.reason))")
        }
        lines.append("Waiting for iCloud: \(waitingForICloud)" + (waitingSince.map { " since \(iso.string(from: $0))" } ?? ""))
        lines.append("Card payments being checked: \(openPayments)")
        lines.append("Gift cards spent twice: \(giftCardsSpentTwice)")
        lines.append("Files set aside (quarantine): \(quarantinedFiles)")
        return lines.joined(separator: "\n")
    }
}
