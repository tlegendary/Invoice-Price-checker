import SwiftUI
import VisionKit
import ChargeCheckCore

/// Item editor › "Sell at the till": selling price, VAT, units per pack, barcodes and when to reorder.
struct TillFields: View {
    @Binding var till: TillInfo
    let name: String
    /// The agreed pack price being edited (nil while it isn't a valid number).
    let packPrice: Double?

    @State private var newBarcode = ""
    @State private var scanning = false

    private var perPack: Double { max(1, till.perPack ?? PackGuess.count(in: name)) }

    var body: some View {
        Section {
            Toggle("Sold by weight", isOn: Binding(get: { till.byWeight == true }, set: { till.byWeight = $0 ? true : nil }))
            LabeledContent(till.byWeight == true ? String(localized: "Price a kg") : String(localized: "Selling price")) {
                TextField(Money.format(0), value: $till.sell, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            Picker("VAT in the price", selection: Binding(get: { till.vat ?? 0 }, set: { till.vat = $0 == 0 ? nil : $0 })) {
                Text("None").tag(0.0)
                Text("5%").tag(5.0)
                Text("20%").tag(20.0)
            }
            Stepper(value: Binding(get: { perPack }, set: { till.perPack = $0 }), in: 1...10_000) {
                LabeledContent(till.byWeight == true ? String(localized: "kg in a pack") : String(localized: "Units in a pack"), value: perPack.formatted())
            }
            if perPack > 1 && till.byWeight != true {
                LabeledContent("Price for the whole pack") {
                    TextField("Not sold by the pack", value: $till.packSell, format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let packPrice, packPrice > 0 {
                let cost = packPrice / perPack
                LabeledContent("Cost of one", value: Money.format(Money.round2(cost)))
                if let sell = till.sell, sell > 0 {
                    let net = sell / (1 + (till.vat ?? 0) / 100)
                    let profit = net - cost
                    LabeledContent("Profit on one") {
                        Text("\(Money.format(Money.round2(profit))) (\((net > 0 ? profit / net * 100 : 0).formatted(.number.precision(.fractionLength(0))))%)")
                            .fontWeight(.semibold)
                            .foregroundStyle(profit < 0 ? .red : .green)
                    }
                }
                if let pack = till.packSell, pack > 0 {
                    let net = pack / (1 + (till.vat ?? 0) / 100)
                    LabeledContent("Profit on the pack") {
                        Text(Money.format(Money.round2(net - packPrice)))
                            .fontWeight(.semibold)
                            .foregroundStyle(net - packPrice < 0 ? .red : .green)
                    }
                }
            }
            Toggle("Only sold at the till", isOn: Binding(get: { till.tillOnly == true }, set: { till.tillOnly = $0 ? true : nil }))
            Toggle("Ask for ID (Challenge 25)", isOn: Binding(get: { till.ageCheck == true }, set: { till.ageCheck = $0 ? true : nil }))
            Toggle("Keep batches and expiry dates", isOn: Binding(get: { till.batches == true }, set: { till.batches = $0 ? true : nil }))
        } header: {
            Text("Sell at the till")
        } footer: {
            Text("You buy it by the pack and sell it one at a time, or the whole pack too. Profit is the price without VAT, less what it costs you. Only sold at the till: never matched to supplier invoices (your own products); its price above is what one costs you. Sold by weight: the till asks for the weight (or reads it from a scale label) and stock is in kg. Batches: add each delivery's batch and use-by date in Till › Expiry dates; the till warns before an out-of-date one is sold.")
        }

        Section {
            Stepper(value: Binding(get: { till.multiQty ?? 0 }, set: { till.multiQty = $0 < 2 ? nil : $0 }), in: 0...50) {
                LabeledContent("Buy", value: (till.multiQty ?? 0) < 2 ? String(localized: "No offer") : (till.multiQty ?? 0).formatted())
            }
            if (till.multiQty ?? 0) >= 2 {
                LabeledContent("For") {
                    TextField(Money.format(0), value: $till.multiPrice, format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("Multi-buy offer")
        } footer: {
            Text("For example 3 for £2. Taken off at the till for every full set.")
        }

        Section {
            ForEach(till.barcodes ?? [], id: \.self) { code in
                Text(code).monospacedDigit()
            }
            .onDelete { offsets in
                var list = till.barcodes ?? []
                list.remove(atOffsets: offsets)
                till.barcodes = list.isEmpty ? nil : list
            }
            HStack {
                TextField("Type a barcode", text: $newBarcode)
                    .keyboardType(.numberPad)
                Button("Add") { add(newBarcode) }
                    .buttonStyle(.borderless)
                    .disabled(newBarcode.trimmingCharacters(in: .whitespaces).isEmpty)
                if BarcodeScanner.canScan {
                    Button {
                        scanning = true
                    } label: {
                        Image(systemName: "barcode.viewfinder")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Scan a barcode"))
                }
            }
        } header: {
            Text("Barcodes")
        } footer: {
            Text("Scan it at the till to add it to the sale. An item can have more than one (different packs). Swipe left to remove one.")
        }

        Section {
            LabeledContent("Reorder when down to") {
                TextField("Not set", value: $till.low, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            if till.low != nil {
                LabeledContent("Packs to order") {
                    TextField("Automatic", value: $till.orderPacks, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("Stock")
        } footer: {
            Text("In single units. When a sale takes the stock down to this, an order for the supplier is made in Suppliers › Orders, ready to check and send. Automatic orders enough packs to get back to twice this level.")
        }
        .sheet(isPresented: $scanning) {
            BarcodeScanner { code in
                add(code)
                scanning = false
            }
            .ignoresSafeArea()
        }
    }

    private func add(_ code: String) {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var list = till.barcodes ?? []
        if !list.contains(clean) { list.append(clean) }
        till.barcodes = list
        newBarcode = ""
    }
}

/// The camera reading one barcode (VisionKit). Calls back with the first code it sees.
struct BarcodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    @MainActor static var canScan: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode()], qualityLevel: .fast,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let value = code.payloadStringValue, !value.isEmpty {
                    done = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onCode(value)
                    return
                }
            }
        }
    }
}
