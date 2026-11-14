import Foundation

enum AppConfig {
    /// Test mode (set by `CCTestBuild` in project.yml): Google's test ads are shown instead of
    /// real ones, and Settings has a switch to try the free version. Must be off for App Review.
    static var testBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CCTestBuild") as? Bool ?? false
    }

    static let supportEmail = "r93.hamad@gmail.com"
    static let privacyURL = URL(string: "https://tlegendary.github.io/privacy.html")
    static let supportURL = URL(string: "https://tlegendary.github.io/support.html")
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
    static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")

    /// The rewarded ad shown for one free scan.
    static var rewardedAdUnit: String {
        testBuild ? "ca-app-pub-3940256099942544/1712485313"      // Google's public test ad
                  : "ca-app-pub-2905482277981262/8963561619"      // ChargeCheck "Scan reward"
    }
}
