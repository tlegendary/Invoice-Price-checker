import SwiftUI

/// Shown when a free user has no scans left: watch one ad for one scan, buy scans, or subscribe.
/// A scan is only added when the ad was watched to the end.
struct NeedScanSheet: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var ads: AdService
    @Environment(\.dismiss) private var dismiss

    /// Called after a scan was earned.
    let onEarned: () -> Void
    let onShowPlans: () -> Void

    @State private var watching = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Watch a short ad to scan 1 invoice")
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("The free version gives you one scan for each ad you watch to the end.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                Button {
                    watch()
                } label: {
                    Group {
                        if watching {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Loading the ad…")
                            }
                        } else {
                            Text(problem == nil ? "Watch an ad" : "Try again")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(watching)
                Button {
                    dismiss()
                    onShowPlans()
                } label: {
                    Text("Buy scans or go unlimited – no ads")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(watching)
                if AppConfig.testBuild {
                    Text("Test mode · \(ads.status)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                    .disabled(watching)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(watching)
    }

    private func watch() {
        guard !watching else { return }
        watching = true
        problem = nil
        Task {
            let outcome = await ads.watch()
            watching = false
            switch outcome {
            case .rewarded:
                store.addAdReward()
                dismiss()
                onEarned()
            case .closedEarly:
                problem = String(localized: "The ad was closed before the end, so no scan was added.")
            case .failed(let reason):
                problem = String(localized: "No ad is available right now, so no scan was added. Check your connection and try again. (\(reason))")
            }
        }
    }
}
