import SwiftUI
import SwiftData
import ChargeCheckCore

/// Suppliers › Orders: orders to send, orders waiting for their delivery, and orders compared with their invoice.
struct OrdersView: View {
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @Environment(\.modelContext) private var context
    @ObservedObject private var store = OrderStore.shared
    @State private var editing: PurchaseOrder?
    @State private var choosingSupplier = false

    private var visible: [PurchaseOrder] {
        let shop = LiveSettings.shared.shop
        return store.orders.filter { shop.isEmpty || $0.shop.isEmpty || $0.shop == shop }
    }

    var body: some View {
        let drafts = visible.filter { !$0.sent }
        // an order that came in part stays waiting until the rest arrives
        let entries = reports.compactMap { $0.entry }
        let partly = Set(visible.filter { $0.invoiceID != nil && OrderMaths.receipt($0, invoices: entries).status == .part }.map(\.id))
        let waiting = visible.filter { $0.sent && ($0.invoiceID == nil || partly.contains($0.id)) }
        let done = visible.filter { $0.invoiceID != nil && !partly.contains($0.id) }
        List {
            if visible.isEmpty {
                ContentUnavailableView {
                    Label("No orders yet", systemImage: "cart")
                } description: {
                    Text("Make an order from what you usually buy and send it by WhatsApp, text or email. When the invoice comes, ChargeCheck compares what you ordered, what arrived and what you were billed.")
                } actions: {
                    Button("Make an order") { choosingSupplier = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            section("To send", drafts)
            section("Waiting for the invoice", waiting)
            section("Compared with the invoice", Array(done.prefix(30)))
        }
        .navigationTitle("Orders")
        .themedScreen()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    choosingSupplier = true
                } label: {
                    Label("Make an order", systemImage: "plus")
                }
            }
        }
        .navigationDestination(for: OrderLink.self) { link in
            OrderDetailView(orderID: link.id)
        }
        .sheet(isPresented: $choosingSupplier) {
            SupplierChoice(suppliers: AppData.knownSuppliers(context)) { supplier in
                editing = OrderEditView.newOrder(for: supplier, entries: reports.compactMap { $0.entry })
            }
        }
        .sheet(item: $editing) { order in
            OrderEditView(order: order) { store.save($0) }
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ list: [PurchaseOrder]) -> some View {
        if !list.isEmpty {
            Section(title) {
                ForEach(list) { order in
                    NavigationLink(value: OrderLink(id: order.id)) {
                        OrderRow(order: order, gaps: gaps(order))
                    }
                }
            }
        }
    }

    private func gaps(_ order: PurchaseOrder) -> [OrderGap]? {
        guard let id = order.invoiceID, let entry = reports.first(where: { $0.uid == id })?.entry else { return nil }
        return OrderMaths.compare(order, with: entry)
    }
}

struct OrderLink: Hashable { let id: String }

private struct OrderRow: View {
    let order: PurchaseOrder
    let gaps: [OrderGap]?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(order.supplier)
                .font(.subheadline.weight(.semibold))
            Text(order.lines.count == 1 ? String(localized: "\(OrderDates.text(order.day)) · 1 item") : String(localized: "\(OrderDates.text(order.day)) · \(order.lines.count) items"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let gaps {
                if gaps.isEmpty {
                    Label("Arrived and billed as ordered", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                } else {
                    Label(gaps.count == 1 ? String(localized: "1 difference") : String(localized: "\(gaps.count) differences"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

enum OrderDates {
    static func text(_ day: String) -> String {
        guard let date = SupplierAccounts.day(day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// Pick who the order is for.
private struct SupplierChoice: View {
    let suppliers: [String]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Another supplier", text: $typed)
                        Button("Use") {
                            onPick(typed.trimmingCharacters(in: .whitespaces))
                            dismiss()
                        }
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Your suppliers") {
                    ForEach(suppliers, id: \.self) { name in
                        Button(name) {
                            onPick(name)
                            dismiss()
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Order from")
            .themedScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Make or change an order: starts with what is usually bought from this supplier.
struct OrderEditView: View {
    let onSave: (PurchaseOrder) -> Void
    @Query(sort: \StoredPrice.name) private var prices: [StoredPrice]
    @Environment(\.dismiss) private var dismiss
    @State private var order: PurchaseOrder
    @State private var picking = false

    init(order: PurchaseOrder, onSave: @escaping (PurchaseOrder) -> Void) {
        self.onSave = onSave
        _order = State(initialValue: order)
    }

    static func newOrder(for supplier: String, entries: [HistoryEntry]) -> PurchaseOrder {
        PurchaseOrder(supplier: supplier, shop: LiveSettings.shared.shop, day: SupplierAccounts.dayText(Date()),
                      lines: OrderMaths.usual(from: entries, supplier: supplier))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Supplier", value: order.supplier)
                } footer: {
                    if order.lines.isEmpty {
                        Text("Add what you need. Next time, ChargeCheck starts the order with what you usually buy from them.")
                    } else {
                        Text("Started with what you usually buy from them. Change the amounts, or set one to 0 to leave it out.")
                    }
                }
                Section("Items") {
                    ForEach($order.lines) { $line in
                        Stepper(value: $line.qty, in: 0...999, step: 1) {
                            HStack {
                                Text(line.name)
                                    .lineLimit(2)
                                Spacer()
                                Text(line.qty == line.qty.rounded() ? "\(Int(line.qty))" : "\(line.qty)")
                                    .monospacedDigit()
                                    .fontWeight(.semibold)
                                    .foregroundStyle(line.qty == 0 ? .secondary : .primary)
                            }
                        }
                    }
                    .onDelete { order.lines.remove(atOffsets: $0) }
                    Button {
                        picking = true
                    } label: {
                        Label("Add an item", systemImage: "plus.circle")
                    }
                }
                Section("Note for the supplier") {
                    TextField("e.g. Please deliver before 11am", text: $order.note, axis: .vertical)
                }
            }
            .navigationTitle("Order")
            .themedScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = order
                        saved.lines.removeAll { $0.qty <= 0 }
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(!order.lines.contains { $0.qty > 0 })
                }
            }
            .sheet(isPresented: $picking) {
                ItemPicker(items: prices.map { $0.item }) { item in
                    if let index = order.lines.firstIndex(where: { $0.itemID == item.id }) {
                        order.lines[index].qty += 1
                    } else {
                        order.lines.append(OrderLine(itemID: item.id, name: item.name, qty: 1))
                    }
                }
            }
        }
    }
}

/// One order: send it, then compare it with its invoice.
struct OrderDetailView: View {
    let orderID: String
    @Query(sort: \StoredReport.savedAt, order: .reverse) private var reports: [StoredReport]
    @ObservedObject private var store = OrderStore.shared
    @State private var editing: PurchaseOrder?
    @State private var choosingInvoice = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    private var order: PurchaseOrder? { store.orders.first { $0.id == orderID } }

    var body: some View {
        if let order {
            let entries = reports.compactMap { $0.entry }
            let invoice = order.invoiceID.flatMap { id in entries.first { $0.id == id } }
            List {
                Section {
                    ForEach(order.lines) { line in
                        LabeledContent(line.name, value: line.qty == line.qty.rounded() ? "\(Int(line.qty))" : "\(line.qty)")
                    }
                    if !order.note.isEmpty {
                        Text(order.note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(OrderDates.text(order.day))
                }

                if !order.sent {
                    Section {
                        ShareLink(item: OrderMaths.message(order, from: Shops.reportName(order.shop), deliveryDay: "")) {
                            Label("Send the order", systemImage: "paperplane")
                        }
                        Button {
                            var sent = order
                            sent.sent = true
                            store.save(sent)
                        } label: {
                            Label("I've sent it", systemImage: "checkmark")
                        }
                        Button {
                            editing = order
                        } label: {
                            Label("Change the order", systemImage: "pencil")
                        }
                    } footer: {
                        Text("Send it by WhatsApp, text or email, then tap I've sent it. When the invoice is checked, compare it here.")
                    }
                } else if let invoice {
                    let gaps = OrderMaths.compare(order, with: invoice)
                    Section {
                        NavigationLink(value: ReportLink(id: invoice.id)) {
                            LabeledContent(invoice.invNo.isEmpty ? String(localized: "Invoice") : String(localized: "Invoice \(invoice.invNo)"),
                                           value: invoice.date)
                        }
                        if gaps.isEmpty {
                            Label("Everything arrived and was billed as ordered.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        ForEach(gaps) { gap in
                            GapRow(gap: gap, supplier: order.supplier)
                        }
                        Button("Not this invoice") {
                            var undone = order
                            undone.invoiceID = nil
                            undone.moreInvoices = []
                            store.save(undone)
                        }
                    } header: {
                        Text("Ordered, delivered and billed")
                    } footer: {
                        Text("Delivered comes from ticking off the delivery on the invoice. Billed but not delivered: ask for a credit from the invoice.")
                    }
                    deliveriesSection(order, entries: entries)
                } else {
                    Section {
                        let suggestion = OrderMaths.likelyInvoice(for: order, in: entries, taken: store.takenInvoices)
                        if let suggestion {
                            Button {
                                match(order, suggestion.id)
                            } label: {
                                Label(String(localized: "Compare with invoice \(suggestion.invNo.isEmpty ? suggestion.date : suggestion.invNo)"),
                                      systemImage: "arrow.left.arrow.right")
                            }
                        } else {
                            Text("Waiting for \(order.supplier)'s invoice. Check it as usual, then come back here.")
                                .foregroundStyle(.secondary)
                        }
                        Button("Choose the invoice") { choosingInvoice = true }
                    } header: {
                        Text("When the invoice comes")
                    }
                }

                Section {
                    Button("Delete this order", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(order.supplier)
            .themedScreen()
            .sheet(item: $editing) { order in
                OrderEditView(order: order) { store.save($0) }
            }
            .sheet(isPresented: $choosingInvoice) {
                InvoiceChoice(entries: entries.filter { TextTools.sameSupplier($0.supplier, order.supplier) && $0.duplicateOf == nil }) { id in
                    match(order, id)
                }
            }
            .confirmationDialog("Delete this order?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    store.delete(order.id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("Order deleted", systemImage: "cart")
        }
    }

    /// Matches an invoice: the first delivery, or the next one when the order came in parts.
    private func match(_ order: PurchaseOrder, _ invoiceID: String) {
        var matched = order
        if matched.invoiceID == nil {
            matched.invoiceID = invoiceID
        } else if !matched.invoiceIDs.contains(invoiceID) {
            matched.moreInvoices.append(invoiceID)
        }
        matched.sent = true
        store.save(matched)
    }

    /// Across every delivery: what's still to come, and a way to match the next delivery's invoice.
    @ViewBuilder
    private func deliveriesSection(_ order: PurchaseOrder, entries: [HistoryEntry]) -> some View {
        let receipt = OrderMaths.receipt(order, invoices: entries)
        if receipt.status == .part || receipt.deliveries > 1 {
            Section {
                ForEach(Array(receipt.stillToCome.enumerated()), id: \.offset) { _, line in
                    LabeledContent(line.name, value: String(localized: "\(line.outstanding.formatted()) to come"))
                        .foregroundStyle(.orange)
                }
                if receipt.status != .part {
                    Label("Everything ordered has now arrived.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if receipt.status == .part {
                    Button("Match the next delivery's invoice") { choosingInvoice = true }
                }
            } header: {
                Text(receipt.deliveries == 1 ? String(localized: "1 delivery so far")
                     : String(localized: "\(receipt.deliveries) deliveries so far"))
            }
        }
    }
}

private struct GapRow: View {
    let gap: OrderGap
    let supplier: String

    private func n(_ value: Double) -> String { value == value.rounded() ? "\(Int(value))" : "\(value)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(gap.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if gap.amount > 0.005 {
                    Text(Money.format(gap.amount, supplier: supplier))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(gap.kind == .billedNotDelivered || gap.kind == .extra ? .red : .orange)
                }
            }
            Text(what)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var what: String {
        switch gap.kind {
        case .billedNotDelivered:
            return String(localized: "Billed \(n(gap.invoiced)), only \(n(gap.delivered)) arrived")
        case .extra:
            return String(localized: "Ordered \(n(gap.ordered)), billed \(n(gap.invoiced))")
        case .notOrdered:
            return String(localized: "Not on your order, billed \(n(gap.invoiced))")
        case .short:
            return String(localized: "Ordered \(n(gap.ordered)), only \(n(gap.invoiced)) came")
        case .notArrived:
            return String(localized: "Ordered \(n(gap.ordered)), not on the invoice")
        }
    }
}

private struct InvoiceChoice: View {
    let entries: [HistoryEntry]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(entries.prefix(40)) { entry in
                Button {
                    onPick(entry.id)
                    dismiss()
                } label: {
                    LabeledContent(entry.invNo.isEmpty ? entry.date : entry.invNo, value: Money.format(entry.total, supplier: entry.supplier))
                }
                .foregroundStyle(.primary)
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No invoices from this supplier yet", systemImage: "doc.text")
                }
            }
            .navigationTitle("Which invoice?")
            .themedScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
