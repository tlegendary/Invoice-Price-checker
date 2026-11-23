import SwiftUI
import PhotosUI
import ChargeCheckCore

/// Photos of damaged, wrong or missing goods, kept with the invoice and sent with the credit request.
/// Saved smaller (like invoice copies) in Files › ChargeCheck › Invoices › Evidence, and to iCloud with them.
enum CreditPhotos {
    static func folder(_ entryID: String) -> URL? {
        AppFiles.documents?.appendingPathComponent("Invoices/Evidence/" + entryID, isDirectory: true)
    }

    static func list(_ entryID: String) -> [URL] {
        guard let folder = folder(entryID), let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasSuffix(".jpg") }.sorted().map { folder.appendingPathComponent($0) }
    }

    @discardableResult
    static func add(_ image: UIImage, for entryID: String) -> URL? {
        guard let folder = folder(entryID), let data = CloudCopies.compressed(image) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        let name = "Photo " + formatter.string(from: Date()) + ".jpg"
        let url = folder.appendingPathComponent(name)
        guard SaveWatch.write(data, to: url) else { return nil }
        let relative = "Invoices/Evidence/" + entryID
        if CloudCopies.wanted {
            DispatchQueue.global(qos: .utility).async {
                if CloudFolder.write(data, folder: relative, name: name) { CloudCopies.markUploaded(relative + "/" + name) }
            }
        }
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// On an invoice with something to credit: add photos, and send them with the credit request.
struct CreditPhotosRows: View {
    let entryID: String
    /// The credit request PDF, when the plan has it.
    let pdf: URL?

    @State private var photos: [URL] = []
    @State private var picks: [PhotosPickerItem] = []

    var body: some View {
        Group {
            PhotosPicker(selection: $picks, maxSelectionCount: 6, matching: .images) {
                Label(photos.isEmpty ? String(localized: "Add photos of the problem") : String(localized: "Add more photos"),
                      systemImage: "camera.on.rectangle")
            }
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photos, id: \.self) { url in
                            if let image = UIImage(contentsOfFile: url.path) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            CreditPhotos.remove(url)
                                            photos = CreditPhotos.list(entryID)
                                        } label: {
                                            Label("Remove the photo", systemImage: "trash")
                                        }
                                    }
                                    .accessibilityLabel(Text("Photo of the problem"))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                ShareLink(items: photos + (pdf.map { [$0] } ?? [])) {
                    Label(pdf == nil ? String(localized: "Send the photos") : String(localized: "Send the credit request with photos"),
                          systemImage: "paperplane")
                }
            }
        }
        .onAppear { photos = CreditPhotos.list(entryID) }
        .onChange(of: picks) {
            let chosen = picks
            picks = []
            Task {
                for item in chosen {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        CreditPhotos.add(image, for: entryID)
                    }
                }
                photos = CreditPhotos.list(entryID)
            }
        }
    }
}
