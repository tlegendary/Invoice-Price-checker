import SwiftUI

/// Scanning arrives in stage 3 of the Swift rewrite (camera, Apple's text reader, price matching).
struct CheckView: View {
    let storageProblem: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if storageProblem {
                    Label("Your saved data couldn't be opened. Anything you add now won't be kept. Close the app and open it again.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .padding(12)
                        .background(.yellow.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }
                ContentUnavailableView {
                    Label("Scanning is being rebuilt", systemImage: "doc.text.viewfinder")
                } description: {
                    Text("This is the new Swift version of ChargeCheck. Your price list is ready in Prices. Invoice scanning is the next part to be added.")
                }
            }
            .navigationTitle("ChargeCheck")
        }
    }
}
