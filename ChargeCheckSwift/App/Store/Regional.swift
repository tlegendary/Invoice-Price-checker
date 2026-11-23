import Foundation
import ChargeCheckCore

/// The language invoices are written in and the currency they use. Both start from the iPhone's own settings.
enum Regional {
    static let languageKey = "invoice.language"
    static let currencyKey = "money.currency"

    struct InvoiceLanguage: Identifiable {
        let id: String
        let name: String
        /// What Apple's text reader is asked to read, best first.
        let vision: [String]
    }

    static let languages: [InvoiceLanguage] = [
        InvoiceLanguage(id: "en", name: "English", vision: ["en-GB", "en-US"]),
        InvoiceLanguage(id: "de", name: "Deutsch", vision: ["de-DE", "en-GB"]),
        InvoiceLanguage(id: "fr", name: "Français", vision: ["fr-FR", "en-GB"]),
        InvoiceLanguage(id: "ar", name: "العربية", vision: ["ar-SA", "ars-SA", "en-GB"]),
        // Apple's reader has no Kurdish yet: the Arabic reader is the closest (same alphabet)
        InvoiceLanguage(id: "ckb", name: "کوردی (سۆرانی)", vision: ["ar-SA", "ars-SA", "en-GB"])
    ]

    static var deviceLanguage: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return languages.contains { $0.id == code } ? code : "en"
    }

    static var deviceCurrency: String {
        let code = Locale.current.currency?.identifier ?? "GBP"
        return Currency.all.contains { $0.code == code } ? code : "GBP"
    }

    static var language: InvoiceLanguage {
        let id = UserDefaults.standard.string(forKey: languageKey) ?? deviceLanguage
        return languages.first { $0.id == id } ?? languages[0]
    }

    static var currency: Currency {
        Currency.named(UserDefaults.standard.string(forKey: currencyKey) ?? deviceCurrency)
    }

    /// The currency is chosen once and then kept, so amounts never change meaning when the iPhone's region changes.
    /// A new install starts from the iPhone's region; a phone that already has ChargeCheck data (which was all kept
    /// in pounds before currencies could be chosen) starts from pounds.
    static func settleCurrency() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: currencyKey) == nil else { return }
        defaults.set(hasSavedData ? Currency.gbp.code : deviceCurrency, forKey: currencyKey)
    }

    private static var hasSavedData: Bool {
        if UserDefaults.standard.data(forKey: "scan.ledger") != nil { return true }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        return ["default.store", "payments.json"].contains { FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path) }
    }

    /// "Ignore differences up to" choices that make sense in this currency (no pennies in dinars).
    static func toleranceChoices(_ currency: Currency) -> [Double] {
        currency.decimals == 0 ? [1, 250, 500, 1000] : [0.01, 0.02, 0.05, 0.1, 0.5, 1]
    }

    /// Hands the choices to the reader and to every amount shown. Call at start-up and after a change.
    static func apply() {
        settleCurrency()
        Translations.connect()
        InvoiceParser.language = language.id
        Money.currency = currency
    }

    static func currencyName(_ currency: Currency) -> String {
        switch currency.code {
        case "GBP": return String(localized: "Pound (£)")
        case "EUR": return String(localized: "Euro (€)")
        case "USD": return String(localized: "Dollar ($)")
        case "IQD": return String(localized: "Iraqi dinar (IQD)")
        default: return currency.code
        }
    }
}
