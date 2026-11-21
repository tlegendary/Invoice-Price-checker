import UIKit
import AppTrackingTransparency
import GoogleMobileAds
import UserMessagingPlatform

enum AdOutcome: Equatable {
    /// The ad was watched to the end and Google confirmed the reward.
    case rewarded
    /// The ad was closed before the end: no scan.
    case closedEarly
    /// No ad could be shown: no scan.
    case failed(String)
}

/// Lets a callback be used at most once (the ad SDK and a time limit both race to answer).
final class OnceGate: @unchecked Sendable {
    private var used = false
    private let lock = NSLock()

    func pass() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

/// Rewarded ads for the free version: one ad watched to the end = one scan.
/// Subscribers never reach this code.
@MainActor
final class AdService: NSObject, ObservableObject, FullScreenContentDelegate {
    @Published private(set) var status = "not started"
    @Published private(set) var privacyOptionsRequired = false

    private var started = false
    private var starting: Task<Bool, Never>?
    private var ready: RewardedAd?
    private var loading: Task<Bool, Never>?
    private var earned = false
    private var finish: ((AdOutcome) -> Void)?

    /// The screen on top, to show an ad or a consent form from.
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private func wait<T>(seconds: Double, fallback: T, _ work: @escaping (@escaping (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let gate = OnceGate()
            work { value in
                if gate.pass() { continuation.resume(returning: value) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                if gate.pass() { continuation.resume(returning: fallback) }
            }
        }
    }

    // MARK: - starting

    /// Consent (where the law needs it), Apple's tracking question, then the ads SDK. Done once.
    func start() async -> Bool {
        if started { return true }
        if let starting { return await starting.value }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            await self.askConsent()
            await self.askTracking()
            MobileAds.shared.start(completionHandler: nil)
            self.started = true
            self.status = AppConfig.testBuild ? "ads started (test ads)" : "ads started"
            return true
        }
        starting = task
        let ok = await task.value
        starting = nil
        return ok
    }

    private func askConsent() async {
        let parameters = RequestParameters()
        let _: Bool = await wait(seconds: 8, fallback: false) { done in
            ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { error in
                done(error == nil)
            }
        }
        if ConsentInformation.shared.formStatus == .available, let top = AdService.topViewController() {
            try? await ConsentForm.loadAndPresentIfRequired(from: top)
        }
        privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
    }

    private func askTracking() async {
        guard ATTrackingManager.trackingAuthorizationStatus == .notDetermined else { return }
        _ = await ATTrackingManager.requestTrackingAuthorization()
    }

    /// "Ad privacy choices" in Settings.
    func showPrivacyOptions() async {
        _ = await start()
        guard let top = AdService.topViewController() else { return }
        try? await ConsentForm.presentPrivacyOptionsForm(from: top)
    }

    // MARK: - loading

    /// Gets the next ad ready. Tries once more on a slow connection.
    @discardableResult
    func preload() async -> Bool {
        if ready != nil { return true }
        if let loading { return await loading.value }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            guard await self.start() else { return false }
            for attempt in 0..<2 {
                self.status = attempt == 0 ? "loading ad…" : "slow network – trying again…"
                let unit = AppConfig.rewardedAdUnit
                let result: (ad: RewardedAd?, problem: String) = await self.wait(seconds: 45, fallback: (nil, "timed out")) { done in
                    RewardedAd.load(with: unit, request: Request()) { ad, error in
                        done((ad, error?.localizedDescription ?? ""))
                    }
                }
                if let ad = result.ad {
                    self.ready = ad
                    self.status = "ad ready"
                    return true
                }
                self.status = "no ad: " + (result.problem.isEmpty ? "unknown" : result.problem)
                let slow = result.problem.range(of: "time ?out|timed out|network|internet|connection", options: [.regularExpression, .caseInsensitive]) != nil
                if !slow { break }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            return false
        }
        loading = task
        let ok = await task.value
        loading = nil
        return ok
    }

    // MARK: - showing

    /// Shows one rewarded ad. The answer is `.rewarded` ONLY when Google confirms it was watched to the end.
    func watch() async -> AdOutcome {
        if finish != nil { return .failed("an ad is already showing") }
        guard await preload(), let ad = ready else { return .failed(status) }
        guard let top = AdService.topViewController() else { return .failed("couldn't show the ad") }
        ready = nil
        earned = false
        status = "showing ad"
        let outcome: AdOutcome = await withCheckedContinuation { (continuation: CheckedContinuation<AdOutcome, Never>) in
            let gate = OnceGate()
            finish = { result in
                if gate.pass() { continuation.resume(returning: result) }
            }
            ad.fullScreenContentDelegate = self
            ad.present(from: top) { [weak self] in
                Task { @MainActor in
                    self?.earned = true
                }
            }
        }
        finish = nil
        status = outcome == .rewarded ? "ad watched" : status
        Task { await preload() }
        return outcome
    }

    nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.earned { self.status = "ad closed before the end" }
            self.finish?(self.earned ? .rewarded : .closedEarly)
        }
    }

    nonisolated func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        let problem = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.status = "ad couldn't show: " + problem
            self.finish?(.failed(self.status))
        }
    }
}
