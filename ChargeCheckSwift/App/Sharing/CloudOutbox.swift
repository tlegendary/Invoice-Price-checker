import ChargeCheckCore
import Foundation

/// Sends till files to iCloud and keeps trying the ones that didn't go (rules in `SyncOutbox`). The file is always
/// on this device already (`AppFiles`), so a retry just sends the latest copy of it.
enum CloudOutbox {
    private static let key = "cloudOutbox"
    private static let queue = DispatchQueue(label: "cloud-outbox")

    private static func load() -> SyncOutbox {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(SyncOutbox.self, from: $0) } ?? SyncOutbox()
    }

    private static func store(_ box: SyncOutbox) {
        UserDefaults.standard.set(try? JSONEncoder().encode(box), forKey: key)
    }

    /// Instead of `CloudFolder.write`: off the main thread, and remembered if it doesn't go.
    static func send(_ data: Data, folder: String, name: String) {
        queue.async {
            let ok = CloudFolder.write(data, folder: folder, name: name)
            var box = load()
            if ok { box.sent(folder: folder, name: name) } else { box.failed(folder: folder, name: name, at: Date()) }
            store(box)
        }
    }

    /// Sends what's due again (on opening the app, and every minute while it's open).
    static func retryDue() {
        queue.async {
            guard CloudFolder.isOn else { return }
            var box = load()
            for item in box.due(at: Date()) {
                guard let url = AppFiles.url(forRelativePath: item.folder + "/" + item.name),
                      let data = try? Data(contentsOf: url) else {
                    box.sent(folder: item.folder, name: item.name)   // the file is gone: nothing left to send
                    continue
                }
                if CloudFolder.write(data, folder: item.folder, name: item.name) {
                    box.sent(folder: item.folder, name: item.name)
                } else {
                    box.failed(folder: item.folder, name: item.name, at: Date())
                }
            }
            store(box)
        }
    }
}
