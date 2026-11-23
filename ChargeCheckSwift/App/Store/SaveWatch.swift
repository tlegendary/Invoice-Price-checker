import ChargeCheckCore
import Foundation
import SwiftData
import SwiftUI

/// Notices when something doesn't save (the rules are in `SaveHealth`), so a problem is never silent.
@MainActor
final class SaveWatch: ObservableObject {
    static let shared = SaveWatch()
    @Published private(set) var health = SaveHealth()

    /// From any thread.
    nonisolated static func failed(_ area: SaveArea, _ what: String, _ error: Error?) {
        let reason = error.map { String(describing: $0) } ?? "unknown"
        Task { @MainActor in shared.health.failed(area, what, reason: reason, at: Date()) }
    }

    /// From any thread. Cheap when nothing has failed.
    nonisolated static func saved(_ area: SaveArea, _ what: String) {
        Task { @MainActor in
            guard !shared.health.isHealthy else { return }
            shared.health.saved(area, what)
        }
    }

    /// Writes a file and says so if it couldn't (instead of `try? data.write`).
    @discardableResult
    nonisolated static func write(_ data: Data, to url: URL, options: Data.WritingOptions = .atomic,
                                  area: SaveArea = .phone) -> Bool {
        let what = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
        do {
            try data.write(to: url, options: options)
            saved(area, what)
            return true
        } catch {
            failed(area, what, error)
            return false
        }
    }

    /// The label every database save uses: one database, so any good save means it's writable again.
    static let database = "Invoices and prices"
}

extension ModelContext {
    /// Saves, and says so on screen if it can't (instead of `try? save()`).
    func saveOrReport() {
        do {
            try save()
            SaveWatch.saved(.database, SaveWatch.database)
        } catch {
            SaveWatch.failed(.database, SaveWatch.database, error)
        }
    }
}

/// Shown at the top while something isn't saved.
struct SaveBanner: View {
    @ObservedObject private var watch = SaveWatch.shared
    @State private var details = false

    var body: some View {
        if let worst = watch.health.worst {
            Button {
                details = true
            } label: {
                Label(title(worst.area), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(worst.area == .icloud ? Color.orange : Color.red)
            }
            .accessibilityHint(Text("Shows what didn't save"))
            .sheet(isPresented: $details) { SaveProblemsView() }
        }
    }

    private func title(_ area: SaveArea) -> String {
        switch area {
        case .database: return String(localized: "Your last changes didn't save. Tap for details.")
        case .phone: return String(localized: "Something didn't save on this device. Tap for details.")
        case .icloud: return String(localized: "Not saved to iCloud yet. Tap for details.")
        }
    }
}

struct SaveProblemsView: View {
    @ObservedObject private var watch = SaveWatch.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(watch.health.failures, id: \.what) { failure in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failure.what).font(.headline)
                            Text(failure.at.formatted(date: .abbreviated, time: .shortened)
                                 + (failure.count > 1 ? " · ×\(failure.count)" : ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(failure.reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                } footer: {
                    Text("Free up space on this device and check iCloud is signed in. The warning goes when it saves. If it stays, send this to support from Settings.")
                }
            }
            .navigationTitle(Text("Not saved"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
