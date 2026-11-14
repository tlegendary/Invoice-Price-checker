import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import ChargeCheckCore

/// Invoices in the iPhone's search (swipe down on the home screen): type a supplier or an invoice number,
/// tap the result and ChargeCheck opens on that invoice. Only the newest 500 are listed, and nothing
/// leaves the phone (the search index is on the device).
enum InvoiceSearch {
    static let domain = "invoices"
    private static let signatureKey = "spotlight.signature"

    /// Re-lists invoices when they changed since the last time.
    static func refresh(_ entries: [HistoryEntry]) {
        let newest = entries.sorted { $0.savedAt > $1.savedAt }.prefix(500)
        let signature = "\(entries.count)|\(newest.first?.id ?? "")|\(newest.first?.savedAt ?? "")|\(Money.currency.code)"
        guard UserDefaults.standard.string(forKey: signatureKey) != signature else { return }
        UserDefaults.standard.set(signature, forKey: signatureKey)
        let items = newest.map { entry -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            let supplier = entry.supplier.isEmpty ? String(localized: "Invoice") : entry.supplier
            attributes.title = entry.invNo.isEmpty ? supplier : supplier + " · " + entry.invNo
            attributes.contentDescription = [entry.date, Money.format(entry.total, code: entry.currency)].filter { !$0.isEmpty }.joined(separator: " · ")
            attributes.keywords = [entry.supplier, entry.invNo, String(localized: "invoice")].filter { !$0.isEmpty }
            return CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: domain, attributeSet: attributes)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(Array(items)) { _ in }
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: signatureKey)
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    }
}
