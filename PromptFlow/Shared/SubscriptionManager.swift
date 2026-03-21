import Foundation
import Combine

/// Manages subscription state and paywall logic.
/// Uses RevenueCat SDK when devMode is false.
/// During development, all features are unlocked.
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    /// Set to false when ready to test real purchases
    static var devMode = true

    @Published var isSubscribed: Bool = true
    @Published var isTrialActive: Bool = false

    private init() {}

    // MARK: - Configuration

    func configure() {
        if Self.devMode {
            isSubscribed = true
            return
        }

        // TODO: Uncomment when RevenueCat SDK is added and API key is set
        // guard let apiKey = revenueCatAPIKey(), !apiKey.isEmpty else { return }
        // Purchases.configure(withAPIKey: apiKey)
        // Task { await checkSubscriptionStatus() }
    }

    // MARK: - Subscription status

    func checkSubscriptionStatus() async {
        if Self.devMode {
            isSubscribed = true
            return
        }

        // TODO: Uncomment when RevenueCat SDK is added
        // do {
        //     let customerInfo = try await Purchases.shared.customerInfo()
        //     let premium = customerInfo.entitlements["premium"]
        //     await MainActor.run {
        //         isSubscribed = premium?.isActive == true
        //         isTrialActive = premium?.periodType == .trial
        //     }
        // } catch {
        //     // Keep current state on error
        // }
    }

    // MARK: - Purchases

    func purchaseMonthly() async throws {
        // TODO: Implement with RevenueCat
        // let offerings = try await Purchases.shared.offerings()
        // guard let package = offerings.current?.monthly else { return }
        // let (_, customerInfo, _) = try await Purchases.shared.purchase(package: package)
        // await checkSubscriptionStatus()
    }

    func purchaseAnnual() async throws {
        // TODO: Implement with RevenueCat
    }

    func purchaseLifetime() async throws {
        // TODO: Implement with RevenueCat
    }

    func restorePurchases() async throws {
        // TODO: Implement with RevenueCat
        // let customerInfo = try await Purchases.shared.restorePurchases()
        // await checkSubscriptionStatus()
    }

    // MARK: - Feature access

    var canUseCamera: Bool { Self.devMode || isSubscribed }
    var canOptimize: Bool { Self.devMode || isSubscribed }
    var canBulkImport: Bool { Self.devMode || isSubscribed }
    var canRecord4K: Bool { Self.devMode || isSubscribed }
    var showWatermark: Bool { !Self.devMode && !isSubscribed }

    // MARK: - API Key

    private func revenueCatAPIKey() -> String? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let key = plist["REVENUECAT_API_KEY"] as? String,
              !key.isEmpty
        else { return nil }
        return key
    }
}

// MARK: - Product IDs (for App Store Connect)
extension SubscriptionManager {
    enum ProductID {
        static let monthly = "steadyeye_monthly"    // $6.99/mo
        static let annual = "steadyeye_annual"       // $49.99/yr, 7-day trial
        static let lifetime = "steadyeye_lifetime"   // $99.99
    }

    static let entitlementID = "premium"
}
