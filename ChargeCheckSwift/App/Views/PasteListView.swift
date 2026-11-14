import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PDFKit
import ChargeCheckCore

/// Paste a price list from WhatsApp, an email or a spreadsheet: one item per line, price at the end.
struct PasteListView: View {
    @Environment(\.dismiss) private var dismiss

    let existing: [PriceItem]
    let onAdd: ([PriceItem]) -> Void

    @State private var text = ""
    @State private var supplier = ""
    @State private var showFiles = false
    @State private var fileProblem: String?

    private var rows: [PriceListText.Row] { PriceListText.parse(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                    Button("Paste from clipboard") {
                        if let copied = UIPasteboard.general.string { text = copied }
                    }
                    if let fileProblem {
                        Text(fileProblem)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Button("Open a price list (PDF, CSV or text)") {
                        showFiles = true
                    }
                } header: {
                    Text("Your list")
                } footer: {
                    Text("One item per line with its price at the end, for example: Chicken wings 10kg \(Money.format(15))")
                }
                Section("Supplier (optional)") {
                    TextField("Who are these prices from?", text: $supplier)
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section(rows.isEmpty ? "Nothing found" : "Found \(rows.count) items") {
                        if rows.isEmpty {
                            Text("No lines with an item name and a price. Put one item per line with the price at the end.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack {
                                Text(row.name)
                                Spacer(minLength: 12)
                                Text(Money.format(row.price))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.pdf, .commaSeparatedText, .plainText]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
                fileProblem = nil
                guard let data = try? Data(contentsOf: url) else { return }
                if url.pathExtension.lowercased() == "pdf" || data.starts(with: Array("%PDF".utf8)) {
                    // a supplier's price list as a PDF: its text, page by page, one line per row
                    guard let document = PDFDocument(data: data) else {
                        fileProblem = String(localized: "That PDF couldn't be opened.")
                        return
                    }
                    let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
                    let found = pages.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if found.isEmpty {
                        fileProblem = String(localized: "This PDF is a scanned picture, so there's no text to read. Ask the supplier for the PDF they made on a computer, or a spreadsheet.")
                    } else {
                        text = found
                        if PriceListText.parse(found).isEmpty {
                            fileProblem = String(localized: "No prices were found in this PDF. Check each line has an item and a price.")
                        }
                    }
                    return
                }
                text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            }
            .navigationTitle("Paste a price list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(rows.isEmpty ? "Add" : "Add \(rows.count)") { add() }
                        .disabled(rows.isEmpty)
                }
            }
        }
    }

    private func add() {
        let from = supplier.trimmingCharacters(in: .whitespaces)
        var all = existing
        var changed: [PriceItem] = []
        for row in rows {
            let key = TextTools.norm(row.name)
            if let index = all.firstIndex(where: { TextTools.norm($0.name) == key }) {
                // already in the list: update its price
                all[index].price = row.price
                if all[index].supplier.isEmpty { all[index].supplier = from }
                changed.append(all[index])
            } else {
                var item = PriceItem(cat: "Other", name: row.name, price: row.price, supplier: from, aliases: [key])
                item.cat = Categoriser.suggest(for: item, in: all) ?? "Other"
                all.append(item)
                changed.append(item)
            }
        }
        onAdd(changed)
        dismiss()
    }
}
