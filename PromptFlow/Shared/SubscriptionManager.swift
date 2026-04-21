import Foundation
import Combine
import RevenueCat

/// Manages subscription state via RevenueCat.
/// In DEV builds, all features are unlocked without RC calls.
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    static var devMode: Bool {
        #if DEV
        return true
        #else
        return false
        #endif
    }

    @Published var isSubscribed: Bool = false
    @Published var isTrialActive: Bool = false
    @Published var offerings: Offerings?
    @Published var isLoading: Bool = false

    // MARK: - Free optimization tracking

    @Published var freeOptimizationsUsed: Int = UserDefaults.standard.integer(forKey: "freeOptimizationsUsed")

    static let freeOptimizationLimit = 3

    var freeOptimizationsRemaining: Int {
        max(0, Self.freeOptimizationLimit - freeOptimizationsUsed)
    }

    func recordOptimizationUse() {
        guard !isSubscribed else { return }
        freeOptimizationsUsed += 1
        UserDefaults.standard.set(freeOptimizationsUsed, forKey: "freeOptimizationsUsed")
    }

    // MARK: - Feature access

    var canRecord: Bool { Self.devMode || isSubscribed }
    var canOptimize: Bool {
        if Self.devMode || isSubscribed { return true }
        return freeOptimizationsUsed < Self.freeOptimizationLimit
    }
    var canBulkImport: Bool { Self.devMode || isSubscribed }
    var canRecord4K: Bool { Self.devMode || isSubscribed }
    var showWatermark: Bool { !Self.devMode && !isSubscribed }

    private init() {}

    // MARK: - Configuration

    func configure() {
        #if DEV
        isSubscribed = true
        return
        #else
        Task {
            await checkAccess()
            await loadOfferings()
        }
        #endif
    }

    // MARK: - RevenueCat calls

    @MainActor
    func checkAccess() async {
        #if DEV
        isSubscribed = true
        #else
        do {
            let info = try await Purchases.shared.customerInfo()
            let entitlement = info.entitlements[Self.entitlementID]
            isSubscribed = entitlement?.isActive == true
            isTrialActive = entitlement?.periodType == .trial
        } catch {
            // Keep current state on error
        }
        #endif
    }

    @MainActor
    func loadOfferings() async {
        #if DEV
        return
        #else
        do {
            offerings = try await Purchases.shared.offerings()
        } catch {
            // Offerings failed — paywall will show fallback prices
        }
        #endif
    }

    @MainActor
    func purchase(_ package: Package) async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            let entitlement = result.customerInfo.entitlements[Self.entitlementID]
            isSubscribed = entitlement?.isActive == true
            return isSubscribed
        } catch {
            return false
        }
    }

    @MainActor
    func restorePurchases() async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            let info = try await Purchases.shared.restorePurchases()
            let entitlement = info.entitlements[Self.entitlementID]
            isSubscribed = entitlement?.isActive == true
            return isSubscribed
        } catch {
            return false
        }
    }

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

// MARK: - Product IDs
extension SubscriptionManager {
    enum ProductID {
        static let monthly = "steadyeye_monthly"
        static let annual = "steadyeye_annual"
        static let lifetime = "steadyeye_lifetime"
    }

    static let entitlementID = "access"
}
