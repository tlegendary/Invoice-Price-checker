import SwiftUI
import SwiftData
import ChargeCheckCore

/// More › Recently deleted: invoices, payments and prices deleted in the last 30 days.
struct RecentlyDeletedView: View {
    @Environment(\.modelContext) private var context
    @ObservedObject private var records = Records.shared
    @State private var confirmEmpty = false
    @State private var notice: String?

    var body: some View {
        List {
            if records.bin.isEmpty {
                ContentUnavailableView {
                    Label("Nothing deleted", systemImage: "trash")
                } description: {
                    Text("Invoices, payments and prices you delete stay here for 30 days, so you can bring them back.")
                }
            } else {
                Section {
                    ForEach(records.bin) { item in
                        BinRow(item: item)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    restore(item)
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.green)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    records.forget(item)
                                } label: {
                                    Label("Delete now", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button {
                                    restore(item)
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                            }
                    }
                } footer: {
                    Text("Swipe right to restore, left to delete for good. Everything here goes by itself after 30 days.")
                }
                Section {
                    Button("Delete all for good", role: .destructive) { confirmEmpty = true }
                }
            }
        }
        .navigationTitle("Recently deleted")
        .onAppear { records.prune() }
        .confirmationDialog("Delete everything here for good?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Delete all for good", role: .destructive) { records.emptyBin() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func restore(_ item: BinItem) {
        records.restore(item, context: context)
        notice = String(localized: "Restored.")
    }
}

struct BinRow: View {
    let item: BinItem

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let amount {
                Text(Money.format(amount))
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private var icon: String {
        if item.invoice != nil { return "doc.text" }
        if item.payment != nil { return "banknote" }
        return "tag"
    }

    private var title: String {
        if let entry = item.invoice { return RecordKeeping.subject(entry) }
        if let payment = item.payment {
            switch payment.kind {
            case .payment: return String(localized: "Payment to \(payment.supplier)")
            case .credit: return String(localized: "Credit note from \(payment.supplier)")
            case .opening: return String(localized: "Older amount owed to \(payment.supplier)")
            }
        }
        return item.price?.name ?? ""
    }

    private var amount: Double? {
        item.invoice?.total ?? item.payment?.amount ?? item.price?.price
    }

    private var detail: String {
        let days = RecordKeeping.daysLeft(item)
        let deleted = String(localized: "deleted \(PayDates.show(item.deletedAt))")
        let left = days == 1 ? String(localized: "1 day left") : String(localized: "\(days) days left")
        return deleted + " · " + left
    }
}

/// More › History of changes: what was saved, paid, changed or deleted on this iPhone.
struct ChangeHistoryView: View {
    @ObservedObject private var records = Records.shared
    @State private var search = ""

    var body: some View {
        let query = TextTools.norm(search)
        let list = records.history.filter { query.isEmpty || TextTools.norm(ChangeText.title($0) + " " + $0.subject).contains(query) }
        let days = Dictionary(grouping: list) { String($0.at.prefix(10)) }
        List {
            if list.isEmpty {
                ContentUnavailableView {
                    Label("No changes yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Invoices saved, payments recorded, prices changed and anything deleted are listed here.")
                }
            }
            ForEach(days.keys.sorted(by: >), id: \.self) { day in
                Section(PayDates.show(day)) {
                    ForEach(days[day] ?? []) { entry in
                        ChangeRow(entry: entry)
                    }
                }
            }
        }
        .navigationTitle("History of changes")
        .searchable(text: $search)
    }
}

struct ChangeRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ChangeText.icon(entry.action))
                .foregroundStyle(ChangeText.colour(entry.action))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(ChangeText.title(entry))
                    .font(.subheadline.weight(.semibold))
                Text(entry.subject)
                    .font(.footnote)
                    .lineLimit(2)
                Text(time + (entry.by.isEmpty ? "" : " · " + entry.by))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if let value = ChangeText.amount(entry) {
                Text(value)
                    .font(.footnote.weight(.semibold))
            }
        }
    }

    private var time: String {
        guard let date = ISO8601DateFormatter().date(from: entry.at) else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

enum ChangeText {
    static func title(_ entry: ActivityEntry) -> String {
        switch entry.action {
        case .invoiceSaved: return String(localized: "Invoice saved")
        case .invoiceUpdated: return String(localized: "Invoice changed")
        case .invoiceDeleted: return String(localized: "Invoice deleted")
        case .invoiceRestored: return String(localized: "Invoice restored")
        case .paymentRecorded: return String(localized: "Payment recorded")
        case .paymentRemoved: return String(localized: "Payment removed")
        case .paymentRestored: return String(localized: "Payment restored")
        case .markedPaid: return String(localized: "Marked as paid")
        case .markedUnpaid: return String(localized: "Marked as unpaid")
        case .priceAdded: return String(localized: "Price added")
        case .priceChanged: return String(localized: "Price changed")
        case .priceDeleted: return String(localized: "Price deleted")
        case .priceRestored: return String(localized: "Price restored")
        case .creditAsked: return String(localized: "Credit asked for")
        case .creditReceived: return String(localized: "Credit received")
        case .creditCleared: return String(localized: "Credit cleared")
        case .supplierChanged: return String(localized: "Supplier setting changed")
        case .backupRestored: return String(localized: "Backup restored")
        case .binEmptied: return String(localized: "Recently deleted emptied")
        }
    }

    static func amount(_ entry: ActivityEntry) -> String? {
        if entry.action == .priceChanged, let old = entry.amount, let new = entry.newAmount {
            return Money.format(old) + " → " + Money.format(new)
        }
        if let value = entry.amount ?? entry.newAmount { return Money.format(value) }
        return nil
    }

    static func icon(_ action: ActivityEntry.Action) -> String {
        switch action {
        case .invoiceSaved, .invoiceUpdated: return "doc.text"
        case .invoiceDeleted, .paymentRemoved, .priceDeleted, .binEmptied: return "trash"
        case .invoiceRestored, .paymentRestored, .priceRestored, .backupRestored: return "arrow.uturn.backward"
        case .paymentRecorded, .markedPaid: return "banknote"
        case .markedUnpaid: return "arrow.uturn.left"
        case .priceAdded, .priceChanged: return "tag"
        case .creditAsked, .creditReceived, .creditCleared: return "arrow.uturn.backward.circle"
        case .supplierChanged: return "shippingbox"
        }
    }

    static func colour(_ action: ActivityEntry.Action) -> Color {
        switch action {
        case .invoiceDeleted, .paymentRemoved, .priceDeleted, .binEmptied: return .red
        case .invoiceRestored, .paymentRestored, .priceRestored, .creditReceived, .markedPaid, .paymentRecorded: return .green
        default: return .accentColor
        }
    }
}
