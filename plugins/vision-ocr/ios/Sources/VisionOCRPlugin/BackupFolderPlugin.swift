import Foundation
import Capacitor
import UIKit
import UniformTypeIdentifiers

/// Lets the user pick a folder once (for example a "ChargeCheck" folder in iCloud Drive),
/// keeps access to it with a bookmark, and then saves backups and invoice copies there automatically.
@objc(BackupFolderPlugin)
public class BackupFolderPlugin: CAPPlugin, CAPBridgedPlugin, UIDocumentPickerDelegate {
    public let identifier = "BackupFolderPlugin"
    public let jsName = "BackupFolder"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "pick", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "status", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "write", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "read", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "forget", returnType: CAPPluginReturnPromise)
    ]

    private let bookmarkKey = "ChargeCheckBackupFolder"
    private var pickCall: CAPPluginCall?

    // MARK: - choosing the folder

    @objc func pick(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let vc = self.bridge?.viewController else {
                call.reject("Can't open the folder picker")
                return
            }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
            picker.delegate = self
            picker.allowsMultipleSelection = false
            self.pickCall = call
            vc.present(picker, animated: true, completion: nil)
        }
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let call = pickCall else { return }
        pickCall = nil
        guard let url = urls.first else {
            call.resolve(["cancelled": true])
            return
        }
        let ok = url.startAccessingSecurityScopedResource()
        defer {
            if ok { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            call.resolve(["name": BackupFolderPlugin.describe(url), "icloud": BackupFolderPlugin.isICloud(url)])
        } catch {
            call.reject("Couldn't keep access to that folder: \(error.localizedDescription)")
        }
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if let call = pickCall {
            pickCall = nil
            call.resolve(["cancelled": true])
        }
    }

    // MARK: - status / forget

    @objc func status(_ call: CAPPluginCall) {
        guard let url = folder() else {
            call.resolve(["chosen": false])
            return
        }
        call.resolve(["chosen": true, "name": BackupFolderPlugin.describe(url), "icloud": BackupFolderPlugin.isICloud(url)])
    }

    @objc func forget(_ call: CAPPluginCall) {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        call.resolve(["ok": true])
    }

    // MARK: - writing and reading files in the folder

    @objc func write(_ call: CAPPluginCall) {
        guard let name = call.getString("name"), let base64 = call.getString("data") else {
            call.reject("Missing file")
            return
        }
        let sub = call.getString("folder") ?? ""
        guard let root = folder() else {
            call.reject("No folder chosen")
            return
        }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            call.reject("Bad file data")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let ok = root.startAccessingSecurityScopedResource()
            defer {
                if ok { root.stopAccessingSecurityScopedResource() }
            }
            var dir = root
            for part in sub.split(separator: "/") where !part.isEmpty {
                dir = dir.appendingPathComponent(String(part), isDirectory: true)
            }
            let target = dir.appendingPathComponent(name, isDirectory: false)
            var coordError: NSError?
            var writeError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: .forReplacing, error: &coordError) { url in
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                    try data.write(to: url, options: .atomic)
                } catch {
                    writeError = error
                }
            }
            if let e = coordError {
                call.reject("Couldn't save: \(e.localizedDescription)")
                return
            }
            if let e = writeError {
                call.reject("Couldn't save: \(e.localizedDescription)")
                return
            }
            call.resolve(["ok": true])
        }
    }

    @objc func read(_ call: CAPPluginCall) {
        guard let name = call.getString("name") else {
            call.reject("Missing file name")
            return
        }
        let sub = call.getString("folder") ?? ""
        guard let root = folder() else {
            call.reject("No folder chosen")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let ok = root.startAccessingSecurityScopedResource()
            defer {
                if ok { root.stopAccessingSecurityScopedResource() }
            }
            var dir = root
            for part in sub.split(separator: "/") where !part.isEmpty {
                dir = dir.appendingPathComponent(String(part), isDirectory: true)
            }
            let target = dir.appendingPathComponent(name, isDirectory: false)
            // iCloud may only have a placeholder on this phone: ask for the real file first
            try? FileManager.default.startDownloadingUbiquitousItem(at: target)
            var coordError: NSError?
            var result: String?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: target, options: [], error: &coordError) { url in
                if let data = try? Data(contentsOf: url) {
                    result = String(data: data, encoding: .utf8)
                }
            }
            if let text = result {
                call.resolve(["data": text])
            } else {
                call.resolve(["missing": true])
            }
        }
    }

    // MARK: - helpers

    private func folder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale {
            let ok = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
            if ok { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    static func isICloud(_ url: URL) -> Bool {
        return url.path.contains("Mobile Documents")
    }

    static func describe(_ url: URL) -> String {
        let path = url.path
        if let range = path.range(of: "com~apple~CloudDocs") {
            let rest = path[range.upperBound...].split(separator: "/").map(String.init)
            return (["iCloud Drive"] + rest).joined(separator: " › ")
        }
        return url.lastPathComponent
    }
}
