import SwiftUI
import UIKit
import CoreBluetooth
import Network
import MultipeerConnectivity
import ChargeCheckCore

// MARK: - Receipt printer and cash drawer

/// The receipt printer of this till (each till has its own), saved on the device.
struct PrinterSettings: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case none, bluetooth, network
    }
    var kind: Kind = .none
    var bluetoothID: String?
    var bluetoothName: String?
    var host = ""
    var port = 9100
    /// 80 mm paper (576 dots); off: 58 mm (384 dots).
    var wide = true
    /// Print every receipt by itself.
    var autoPrint = false
    /// The drawer plugged into the printer opens for cash sales.
    var drawer = true

    var width: Int { wide ? 576 : 384 }
    var isSet: Bool {
        switch kind {
        case .none: return false
        case .bluetooth: return bluetoothID != nil
        case .network: return !host.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

/// Sends receipts to a Bluetooth (BLE) or network (Wi-Fi/Ethernet, port 9100) ESC/POS printer, and kicks the drawer.
/// The receipt goes as a picture, so every language prints as it looks on screen.
@MainActor
final class ReceiptPrinter: NSObject, ObservableObject {
    static let shared = ReceiptPrinter()
    private static let key = "till.printer"

    @Published var settings: PrinterSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.key) }
            if oldValue.bluetoothID != settings.bluetoothID { disconnect() }
        }
    }
    @Published private(set) var found: [FoundPrinter] = []
    @Published private(set) var scanning = false
    /// The last problem, in words for the shop (nil: fine).
    @Published var problem: String?
    @Published private(set) var busy = false

    struct FoundPrinter: Identifiable, Equatable {
        let id: UUID
        let name: String
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var queue: [[UInt8]] = []
    private var wantScan = false

    private override init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode(PrinterSettings.self, from: data) {
            settings = saved
        } else {
            settings = PrinterSettings()
        }
        super.init()
    }

    // MARK: what the till asks for

    func print(_ text: String, openDrawer: Bool) {
        let picture = ReceiptImage.bitmap(text, width: settings.width)
        guard picture.height > 0 else {
            problem = String(localized: "The receipt couldn't be drawn for the printer.")
            return
        }
        send(EscPos.receipt(width: picture.width, height: picture.height, pixels: picture.pixels, openDrawer: openDrawer && settings.drawer))
    }

    func openDrawer() { send(EscPos.openDrawer) }

    func testPrint() {
        print(String(localized: "ChargeCheck test receipt") + "\n" + "English · العربية · کوردی · Deutsch · Français\n£1.23 €4.56\n\n" + String(localized: "The printer works."),
              openDrawer: false)
    }

    private func send(_ bytes: [UInt8]) {
        problem = nil
        switch settings.kind {
        case .none:
            return
        case .network:
            sendNetwork(bytes)
        case .bluetooth:
            queue += EscPos.chunks(bytes, size: 150)
            busy = true
            if writer != nil, peripheral?.state == .connected { flush() } else { connect() }
        }
    }

    // MARK: network printers

    private func sendNetwork(_ bytes: [UInt8]) {
        let host = settings.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: UInt16(clamping: settings.port)) else { return }
        busy = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let timeout = DispatchWorkItem { [weak self] in
            connection.cancel()
            Task { @MainActor in
                self?.busy = false
                self?.problem = String(localized: "The printer at \(host) didn't answer. Check it's on and on the same Wi-Fi.")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                connection.send(content: Data(bytes), completion: .contentProcessed { error in
                    timeout.cancel()
                    // let the printer take it all before closing
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { connection.cancel() }
                    Task { @MainActor in
                        self?.busy = false
                        if error != nil { self?.problem = String(localized: "The receipt didn't reach the printer.") }
                    }
                })
            case .failed:
                timeout.cancel()
                connection.cancel()
                Task { @MainActor in
                    self?.busy = false
                    self?.problem = String(localized: "The printer at \(host) didn't answer. Check it's on and on the same Wi-Fi.")
                }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    // MARK: Bluetooth printers

    func startScan() {
        found = []
        wantScan = true
        scanning = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else if central?.state == .poweredOn {
            central?.scanForPeripherals(withServices: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.stopScan() }
    }

    func stopScan() {
        wantScan = false
        scanning = false
        central?.stopScan()
    }

    func choose(_ printer: FoundPrinter) {
        stopScan()
        settings.bluetoothID = printer.id.uuidString
        settings.bluetoothName = printer.name
        settings.kind = .bluetooth
    }

    private func connect() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
            return   // continues once Bluetooth is on
        }
        guard central?.state == .poweredOn else { return }
        guard let id = settings.bluetoothID.flatMap(UUID.init(uuidString:)),
              let target = central?.retrievePeripherals(withIdentifiers: [id]).first else {
            fail(String(localized: "The Bluetooth printer wasn't found. Turn it on, or choose it again in Till settings › Receipt printer."))
            return
        }
        peripheral = target
        target.delegate = self
        central?.connect(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.busy, self.writer == nil else { return }
            self.fail(String(localized: "The Bluetooth printer didn't connect. Turn it on and keep it close."))
        }
    }

    private func disconnect() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writer = nil
    }

    private func fail(_ message: String) {
        queue = []
        busy = false
        problem = message
    }

    private func flush() {
        guard let peripheral, let writer else { return }
        let noReply = writer.properties.contains(.writeWithoutResponse)
        while !queue.isEmpty {
            if noReply && !peripheral.canSendWriteWithoutResponse { return }   // continues in peripheralIsReady
            let piece = queue.removeFirst()
            peripheral.writeValue(Data(piece), for: writer, type: noReply ? .withoutResponse : .withResponse)
            if !noReply { return }   // the next piece after the printer says it got this one
        }
        busy = false
    }
}

extension ReceiptPrinter: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if wantScan { central.scanForPeripherals(withServices: nil) }
                if busy && writer == nil { connect() }
            case .unauthorized:
                fail(String(localized: "ChargeCheck isn't allowed to use Bluetooth. Turn it on in Settings › ChargeCheck."))
                scanning = false
            case .poweredOff:
                if busy { fail(String(localized: "Bluetooth is off. Turn it on to print.")) }
                scanning = false
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let id = peripheral.identifier
        MainActor.assumeIsolated {
            guard !name.isEmpty, !found.contains(where: { $0.id == id }) else { return }
            found.append(FoundPrinter(id: id, name: name))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { fail(String(localized: "The Bluetooth printer didn't connect. Turn it on and keep it close.")) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { writer = nil }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: service) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard writer == nil else { return }
            if let found = service.characteristics?.first(where: { $0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write) }) {
                writer = found
                flush()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if error != nil {
                fail(String(localized: "The receipt didn't reach the printer."))
            } else {
                flush()
            }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { flush() }
    }
}

/// Draws receipt text as a black-and-white picture the width of the paper.
enum ReceiptImage {
    static func bitmap(_ text: String, width: Int) -> (width: Int, height: Int, pixels: [Bool]) {
        let font = UIFont.monospacedSystemFont(ofSize: width >= 576 ? 22 : 17, weight: .semibold)
        let style = NSMutableParagraphStyle()
        style.alignment = .natural
        style.baseWritingDirection = .natural
        style.lineBreakMode = .byWordWrapping
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.black, .paragraphStyle: style])
        let drawWidth = CGFloat(width - 8)
        let bounds = string.boundingRect(with: CGSize(width: drawWidth, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let height = min(20_000, Int(bounds.height.rounded(.up)) + 24)
        guard height > 24, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return (width, 0, [])
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        string.draw(with: CGRect(x: 4, y: 8, width: drawWidth, height: bounds.height + 8), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        UIGraphicsPopContext()
        guard let data = context.data else { return (width, 0, []) }
        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height)
        var pixels = [Bool](repeating: false, count: width * height)
        for index in 0..<(width * height) { pixels[index] = buffer[index] < 150 }
        return (width, height, pixels)
    }
}

// MARK: - Customer screen (a second iPhone or iPad facing the customer)

struct ScreenLine: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var detail: String
    var amount: String
}

struct ScreenState: Codable, Equatable {
    var shop = ""
    var lines: [ScreenLine] = []
    var total = ""
    var saving: String?
    /// "Change £3.50", "Thank you"…
    var message: String?
}

/// The till shows its basket on a nearby iPhone or iPad (no internet needed: they find each other on Wi-Fi or
/// Bluetooth). The till offers it; the customer screen finds the till and joins.
@MainActor
final class CustomerScreenLink: NSObject, ObservableObject {
    static let shared = CustomerScreenLink()
    static let service = "cc-screen"
    static let onKey = "till.customerScreen"

    @Published private(set) var state = ScreenState()
    @Published private(set) var connected: [String] = []
    @Published private(set) var isScreen = false

    private let me = MCPeerID(displayName: UIDevice.current.name)
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    var tillOffers: Bool {
        get { UserDefaults.standard.bool(forKey: Self.onKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.onKey)
            objectWillChange.send()
            if newValue { startTill() } else { stop() }
        }
    }

    private func newSession() -> MCSession {
        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        session = s
        return s
    }

    /// On the till: let customer screens join.
    func startTill() {
        guard advertiser == nil, !isScreen else { return }
        _ = newSession()
        let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: ["shop": state.shop], serviceType: Self.service)
        a.delegate = self
        a.startAdvertisingPeer()
        advertiser = a
    }

    /// On the customer screen: find the till.
    func startScreen() {
        stop()
        isScreen = true
        _ = newSession()
        let b = MCNearbyServiceBrowser(peer: me, serviceType: Self.service)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        connected = []
        isScreen = false
    }

    /// The till's basket changed.
    func show(_ new: ScreenState) {
        guard new != state else { return }
        state = new
        guard let session, !session.connectedPeers.isEmpty, let data = try? JSONEncoder().encode(new) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }
}

extension CustomerScreenLink: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let names = session.connectedPeers.map(\.displayName)
        Task { @MainActor in
            self.connected = names
            // a screen that just joined gets the basket as it is now
            if !self.isScreen, state == .connected, let data = try? JSONEncoder().encode(self.state) {
                try? session.send(data, toPeers: [peerID], with: .reliable)
            }
            if self.isScreen, state == .notConnected { self.browser?.startBrowsingForPeers() }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let new = try? JSONDecoder().decode(ScreenState.self, from: data) else { return }
        Task { @MainActor in if self.isScreen { self.state = new } }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in invitationHandler(self.session != nil, self.session) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard let session = self.session, session.connectedPeers.isEmpty else { return }
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}

/// Full screen, facing the customer: what's in the basket and the total. On the customer's iPhone or iPad
/// (More › Till › Customer screen), or on the till itself turned round (Show the customer).
struct CustomerScreenView: View {
    /// This device is the customer screen (it joins the till); otherwise it's the till showing its own basket.
    var joins = true
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var link = CustomerScreenLink.shared
    @State private var showClose = false

    var body: some View {
        let state = link.state
        VStack(spacing: 18) {
            Text(state.shop.isEmpty ? String(localized: "Welcome") : state.shop)
                .font(.largeTitle.weight(.bold))
                .padding(.top, 30)
            if state.lines.isEmpty {
                Spacer()
                Image(systemName: "cart")
                    .font(.system(size: 70))
                    .foregroundStyle(.secondary)
                if joins && link.connected.isEmpty {
                    Text("Looking for the till…").foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List(state.lines) { line in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(line.name).font(.title3)
                                if !line.detail.isEmpty { Text(line.detail).font(.subheadline).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(line.amount).font(.title3.weight(.semibold)).monospacedDigit()
                        }
                        .id(line.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: state.lines.count) { if let last = state.lines.last?.id { proxy.scrollTo(last) } }
                }
            }
            if let saving = state.saving {
                Text(saving).font(.title3.weight(.semibold)).foregroundStyle(.green)
            }
            if let message = state.message {
                Text(message).font(.title.weight(.bold)).foregroundStyle(.green)
            }
            if !state.total.isEmpty {
                HStack {
                    Text("Total").font(.title.weight(.semibold))
                    Spacer()
                    Text(state.total).font(.system(size: 54, weight: .bold, design: .rounded)).monospacedDigit()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.secondary.opacity(0.4))
            }
            .accessibilityLabel(Text("Close"))
            .padding()
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if joins { link.startScreen() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if joins {
                link.stop()
                if link.tillOffers { link.startTill() }
            }
        }
    }
}
