import Foundation
import ChargeCheckCore

/// Looks up text that isn't written directly in a view (messages, PDFs, the reader's notes) in the translations.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

enum Translations {
    /// Lets the core (reader, reports) use the app's translations.
    static func connect() {
        CoreText.translate = { L($0) }
    }
}
