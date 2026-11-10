import SwiftUI
import StoreKit
import ChargeCheckCore

/// The plans: yearly or monthly subscription (7-day free trial), scan packs, or carry on free with ads.
/// It is a sheet with a close button; closing it carries on with the free version.
struct PaywallView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var selected = Products.yearly
    @State private var busy = false
    @State private var notice: String?

    private var chosen: Product? {
        store.plans.first { $0.id == selected } ?? store.plans.first
    }

    private func perMonth(_ yearly: Product) -> String {
        (yearly.price / 12).formatted(yearly.priceFormatStyle)
    }

    private var saving: Int {
        guard let yearly = store.yearly, let monthly = store.monthly else { return 0 }
        return Products.yearlySaving(yearly: NSDecimalNumber(decimal: yearly.price).doubleValue, monthly: NSDecimalNumber(decimal: monthly.price).doubleValue)
    }

    private var legal: String {
        guard let plan = chosen else { return "" }
        let period = plan.id == Products.yearly ? "year" : "month"
        let start = store.trialAvailable
            ? "7-day free trial, then \(plan.displayPrice) per \(period). Payment is charged to your Apple ID when you confirm (after the free trial ends)."
            : "\(plan.displayPrice) per \(period). Payment is charged to your Apple ID when you confirm."
        return start + " Your subscription renews automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel any time in your App Store account settings."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 6) {
                        Text(store.trialAvailable ? "Start your 7-day free trial" : "Go unlimited")
                            .font(.title.weight(.heavy))
                            .multilineTextAlignment(.center)
                        Text("Stop paying more than your agreed prices.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 10) {
                        benefit("Scan photo or PDF invoices – read on your phone, works offline")
                        benefit("Every invoice double-checked before you see the result")
                        benefit("See exactly how much each supplier overcharged you")
                        benefit("Unlimited scans, no ads")
                    }

                    if store.plans.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("The plans couldn't be loaded from the App Store. Check your internet connection and try again.")
                                .font(.subheadline)
                            Button("Try again") {
                                Task { await store.loadProducts() }
                            }
                            .buttonStyle(.bordered)
                            if AppConfig.testBuild {
                                Text(store.loadStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    } else {
                        VStack(spacing: 10) {
                            ForEach(store.plans, id: \.id) { plan in
                                planCard(plan)
                            }
                        }
                        Button {
                            subscribe()
                        } label: {
                            Group {
                                if busy {
                                    ProgressView()
                                } else {
                                    Text(store.trialAvailable ? "Start free trial" : "Subscribe")
                                        .font(.headline)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                    }

                    Button("Restore purchases") {
                        restore()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(busy)

                    VStack(alignment: .leading, spacing: 6) {
                        if !legal.isEmpty {
                            Text(legal)
                        }
                        HStack(spacing: 6) {
                            if let terms = AppConfig.termsURL { Link("Terms of Use", destination: terms) }
                            Text("·")
                            if let privacy = AppConfig.privacyURL { Link("Privacy Policy", destination: privacy) }
                        }
                        Text("Help: \(AppConfig.supportEmail)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if !store.packs.isEmpty {
                        Divider()
                        Text("Or buy scans – no subscription, no ads")
                            .font(.headline)
                        HStack(spacing: 8) {
                            ForEach(store.packs, id: \.id) { pack in
                                packButton(pack)
                            }
                        }
                    }

                    Divider()
                    Button {
                        dismiss()
                    } label: {
                        Text("Use the free version (1 ad per scan)")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(20)
            }
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
                }
            }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .task {
                if store.plans.isEmpty { await store.loadProducts() }
                if store.plans.first(where: { $0.id == selected }) == nil, let first = store.plans.first { selected = first.id }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func benefit(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .font(.subheadline)
    }

    private func planCard(_ plan: Product) -> some View {
        let isYearly = plan.id == Products.yearly
        let isSelected = plan.id == (chosen?.id ?? "")
        return Button {
            selected = plan.id
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isYearly ? "Yearly" : "Monthly")
                        .font(.headline)
                    Text(plan.displayPrice + (isYearly ? " / year" : " / month"))
                        .font(.title3.weight(.bold))
                    if isYearly {
                        Text(saving > 0 ? "\(perMonth(plan)) a month · Save \(saving)%" : "\(perMonth(plan)) a month")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    if store.trialAvailable {
                        Text("7-day free trial, then \(plan.displayPrice)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func packButton(_ pack: Product) -> some View {
        let scans = Products.packs[pack.id] ?? 0
        return Button {
            buy(pack)
        } label: {
            VStack(spacing: 2) {
                Text("\(scans) scans")
                    .font(.subheadline.weight(.semibold))
                Text(pack.displayPrice)
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .disabled(busy)
    }

    private func subscribe() {
        guard let plan = chosen, !busy else { return }
        busy = true
        Task {
            let outcome = await store.buy(plan)
            busy = false
            switch outcome {
            case .done:
                dismiss()
            case .pending:
                notice = "Your purchase is waiting for approval. It will be added as soon as it's approved."
            case .failed(let problem):
                notice = "The purchase didn't go through. \(problem)"
            case .cancelled:
                break
            }
        }
    }

    private func buy(_ pack: Product) {
        guard !busy else { return }
        busy = true
        Task {
            let outcome = await store.buy(pack)
            busy = false
            switch outcome {
            case .done:
                dismiss()
            case .pending:
                notice = "Your purchase is waiting for approval. The scans will be added as soon as it's approved."
            case .failed(let problem):
                notice = "The purchase didn't go through. \(problem)"
            case .cancelled:
                break
            }
        }
    }

    private func restore() {
        guard !busy else { return }
        busy = true
        Task {
            let found = await store.restore()
            busy = false
            if found {
                dismiss()
            } else {
                notice = "No active subscription was found for this Apple ID."
            }
        }
    }
}
