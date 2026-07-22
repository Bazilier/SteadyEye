import Foundation
import Combine
import RevenueCat
import FirebaseAnalytics

enum PurchaseOutcome {
    case succeeded(isTrial: Bool)
    case failed(reason: String)
    case userCancelled
}

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

    /// The actual RevenueCat-derived subscription state. In DEV builds this is
    /// forced to `true` by `configure()`. Use the computed `isSubscribed` for
    /// gating decisions — it consults `devSubscriptionOverride` first.
    @Published private(set) var isSubscribedReal: Bool = false
    @Published var isTrialActive: Bool = false
    @Published var offerings: Offerings?
    @Published var isLoading: Bool = false

    /// Internal change-detection flag for the customerInfoStream listener.
    /// Compared against the latest customerInfo's trial state on each tick
    /// to detect free→trial and trial→ended transitions, which drive the
    /// trial-related local notifications. Initialized after the first
    /// `checkAccess()` so the listener doesn't false-fire on launch.
    private var lastObservedTrialState: Bool = false

    /// DEV-only escape hatch for testing freemium gating without buying or
    /// cancelling a sandbox subscription. Values: "off", "free", "subscribed".
    /// Ignored entirely in Release builds. Persisted in UserDefaults so the
    /// override survives app restarts during a test session.
    @Published var devSubscriptionOverride: String =
        UserDefaults.standard.string(forKey: "devSubscriptionOverride") ?? "free"
    {
        didSet {
            UserDefaults.standard.set(devSubscriptionOverride, forKey: "devSubscriptionOverride")
        }
    }

    /// Effective subscription state, consulted by every gate. In DEV: respects
    /// the override; "off" falls through to `Self.devMode || isSubscribedReal`
    /// so DEV builds without the override remain fully unlocked. In Release:
    /// always the real RC value.
    var isSubscribed: Bool {
        #if DEV
        switch devSubscriptionOverride {
        case "subscribed": return true
        case "free": return false
        default: return Self.devMode || isSubscribedReal
        }
        #else
        return isSubscribedReal
        #endif
    }

    // MARK: - AI optimization daily limits

    /// Free tier: 1 optimize per calendar day. timeIntervalSince1970 of last use; 0 = never used.
    @Published var lastAIOptimizeDateInterval: Double = UserDefaults.standard.double(forKey: "lastAIOptimizeDate")

    /// Pro tier: 30 optimizes per calendar day.
    static let proOptimizationsPerDay = 30

    /// Pro counter — raw stored count. Reads zero on a new day even before
    /// `recordOptimizationUse()` runs (see `proOptimizationsToday`).
    @Published var proOptimizationsCount: Int = UserDefaults.standard.integer(forKey: "proOptimizationsCount")

    /// Effective Pro count for today. Returns 0 if the stored reset date is
    /// not today, so the view layer always shows the correct remaining quota
    /// even if no use has happened yet on the new day.
    var proOptimizationsToday: Int {
        let storedReset = UserDefaults.standard.double(forKey: "proOptimizationsResetDate")
        let resetDate = Date(timeIntervalSince1970: storedReset)
        if !Calendar.current.isDateInToday(resetDate) {
            return 0
        }
        return proOptimizationsCount
    }

    var canOptimizeAsPro: Bool {
        proOptimizationsToday < Self.proOptimizationsPerDay
    }

    func recordOptimizationUse() {
        if isSubscribed {
            // Pro path: increment the daily counter, resetting if we crossed midnight.
            let today = Calendar.current.startOfDay(for: Date())
            let storedReset = UserDefaults.standard.double(forKey: "proOptimizationsResetDate")
            let resetDate = Date(timeIntervalSince1970: storedReset)
            let newCount: Int
            if !Calendar.current.isDate(resetDate, inSameDayAs: today) {
                UserDefaults.standard.set(today.timeIntervalSince1970, forKey: "proOptimizationsResetDate")
                newCount = 1
            } else {
                newCount = proOptimizationsCount + 1
            }
            proOptimizationsCount = newCount
            UserDefaults.standard.set(newCount, forKey: "proOptimizationsCount")
        } else {
            // Free path: stamp today's date.
            let now = Date().timeIntervalSince1970
            lastAIOptimizeDateInterval = now
            UserDefaults.standard.set(now, forKey: "lastAIOptimizeDate")
        }
    }

    // MARK: - Feature access
    //
    // All gates flow through the computed `isSubscribed` (above), which already
    // folds in `Self.devMode` and `devSubscriptionOverride`. Don't add another
    // `Self.devMode ||` short-circuit here — it would defeat the DEV override.

    var canRecord: Bool { isSubscribed }
    var canOptimizeToday: Bool {
        if isSubscribed {
            return canOptimizeAsPro
        }
        if lastAIOptimizeDateInterval == 0 { return true }
        let lastDate = Date(timeIntervalSince1970: lastAIOptimizeDateInterval)
        return !Calendar.current.isDateInToday(lastDate)
    }
    var canBulkImport: Bool { isSubscribed }
    var canRecord4K: Bool { isSubscribed }
    var canUseStabilization: Bool { isSubscribed }
    var maxScriptWords: Int { isSubscribed ? .max : 50 }
    var showWatermark: Bool { !isSubscribed }

    private init() {}

    // MARK: - Analytics user property

    /// Sets Firebase's `subscription_state` user property to one of
    /// `free` / `trial` / `subscribed`. Once set, the property attaches
    /// to every subsequent event automatically, so any analytics query
    /// can pivot by sub state without joining a separate user table.
    /// Called from configure-time first resolution (`checkAccess`),
    /// every customerInfoStream tick, and the restore-success path.
    /// No-op in DEV (matches AppAnalytics.log gating).
    private func updateAnalyticsSubscriptionState() {
        #if !DEV
        let state: String
        if isSubscribed {
            state = isTrialActive ? "trial" : "subscribed"
        } else {
            state = "free"
        }
        Analytics.setUserProperty(state, forName: "subscription_state")
        #endif
    }

    // MARK: - Configuration

    func configure() {
        #if DEV
        isSubscribedReal = true
        return
        #else
        Task {
            await checkAccess()
            await loadOfferings()
        }
        // Long-running listener on RC's customerInfoStream. Fires whenever
        // RevenueCat detects an entitlement change — renewal, expiration,
        // refund, family-sharing change, restore from another device.
        // Loop never exits naturally; the singleton lives for the app's
        // lifetime, so the implicit "leak" is intentional. `@MainActor` keeps
        // the @Published writes on main.
        //
        // Skip spawning the listener if Purchases wasn't configured upstream
        // (e.g. missing apiKey in a CI build) — touching customerInfoStream
        // would fatal-error.
        guard Purchases.isConfigured else {
            print("⚠️ customerInfoStream listener skipped — Purchases not configured")
            return
        }
        Task { @MainActor in
            for await customerInfo in Purchases.shared.customerInfoStream {
                let entitlement = customerInfo.entitlements[Self.entitlementID]
                self.isSubscribedReal = entitlement?.isActive == true
                self.isTrialActive = entitlement?.periodType == .trial
                self.updateAnalyticsSubscriptionState()

                // Trial-state edge detection. `lastObservedTrialState`
                // is seeded by checkAccess on launch so the very first
                // tick here reflects a real change, not the initial read.
                let nowInTrial = entitlement?.periodType == .trial
                let wasInTrial = self.lastObservedTrialState
                self.lastObservedTrialState = nowInTrial

                if !wasInTrial && nowInTrial {
                    // free/none → trial
                    Task { @MainActor in
                        await NotificationScheduler.shared.schedule(.trialStarted, in: 60)
                        await NotificationScheduler.shared.schedule(.trialDay5, in: 5 * 24 * 3600)
                        await NotificationScheduler.shared.schedule(.trialEnding24h, in: 6 * 24 * 3600)
                    }
                } else if wasInTrial && !nowInTrial {
                    // trial → ended (cancelled or converted to paid)
                    NotificationScheduler.shared.cancel([.trialStarted, .trialDay5, .trialEnding24h])
                }
            }
        }
        #endif
    }

    // MARK: - RevenueCat calls

    @MainActor
    func checkAccess() async {
        #if DEV
        isSubscribedReal = true
        #else
        guard Purchases.isConfigured else {
            print("⚠️ checkAccess called before Purchases.configure (missing apiKey?)")
            return
        }
        do {
            let info = try await Purchases.shared.customerInfo()
            let entitlement = info.entitlements[Self.entitlementID]
            isSubscribedReal = entitlement?.isActive == true
            isTrialActive = entitlement?.periodType == .trial
            // Seed change-detection so the customerInfoStream listener
            // doesn't false-fire its trial→started branch on the first
            // tick (which echoes the values we just read here).
            lastObservedTrialState = isTrialActive
            updateAnalyticsSubscriptionState()
        } catch {
            // Keep current state on error
        }
        #endif
    }

    /// Re-arms the "we miss you" inactivity push to fire 3 days from now.
    /// Called from the App-level scenePhase observer on every `.active`
    /// and `.background` transition, so the timer effectively resets to
    /// "3 days of true inactivity from the last session boundary." Pro
    /// users skip — they don't need a reactivation push.
    @MainActor
    func rescheduleInactiveReminder() async {
        NotificationScheduler.shared.cancel(.inactive3Days)
        guard !isSubscribed else { return }
        await NotificationScheduler.shared.schedule(.inactive3Days, in: 3 * 24 * 3600)
    }

    /// Returns the offering with the given identifier, or `nil` if not
    /// present. Falls back to `offerings.current` when `id` is `nil`, so
    /// PaywallView callers that don't pass an `offeringId` keep their
    /// existing default-offering behavior. Also falls back to current
    /// when an unknown identifier is passed — degrades gracefully if a
    /// future offering is referenced before the RC dashboard adds it.
    func offering(for id: String?) -> Offering? {
        guard let id else { return offerings?.current }
        return offerings?[id] ?? offerings?.current
    }

    @MainActor
    func loadOfferings() async {
        #if DEV
        return
        #else
        guard Purchases.isConfigured else {
            print("⚠️ loadOfferings called before Purchases.configure (missing apiKey?)")
            return
        }
        do {
            offerings = try await Purchases.shared.offerings()
        } catch {
            // Offerings failed — paywall will show fallback prices
        }
        #endif
    }

    @MainActor
    func purchase(_ package: Package) async -> PurchaseOutcome {
        #if DEV
        // DEV builds don't talk to the live store. Today's paywall short-
        // circuits before reaching here (package(for:) returns nil because
        // offerings aren't loaded in DEV), so this is defense-in-depth.
        return .failed(reason: "not_configured")
        #else
        guard Purchases.isConfigured else {
            print("⚠️ purchase called before Purchases.configure")
            return .failed(reason: "not_configured")
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled {
                return .userCancelled
            }
            let entitlement = result.customerInfo.entitlements[Self.entitlementID]
            guard entitlement?.isActive == true else {
                return .failed(reason: "entitlement_inactive")
            }
            let isTrial = entitlement?.periodType == .trial
            isSubscribedReal = true
            isTrialActive = isTrial
            return .succeeded(isTrial: isTrial)
        } catch {
            guard let code = error as? RevenueCat.ErrorCode else {
                return .failed(reason: "unknown")
            }
            switch code {
            case .purchaseCancelledError:
                return .userCancelled
            case .networkError:
                return .failed(reason: "network")
            case .paymentPendingError:
                return .failed(reason: "payment_pending")
            case .productNotAvailableForPurchaseError:
                return .failed(reason: "product_unavailable")
            case .storeProblemError:
                return .failed(reason: "store_problem")
            default:
                return .failed(reason: "unknown")
            }
        }
        #endif
    }

    @MainActor
    func restorePurchases() async -> Bool {
        #if DEV
        // DEV builds never call Purchases.configure(); nothing to restore.
        return false
        #else
        AppAnalytics.log("restore_attempted")
        guard Purchases.isConfigured else {
            print("⚠️ restorePurchases called before Purchases.configure")
            AppAnalytics.log("restore_failed", params: ["error_reason": "not_configured"])
            return false
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let info = try await Purchases.shared.restorePurchases()
            let entitlement = info.entitlements[Self.entitlementID]
            isSubscribedReal = entitlement?.isActive == true
            isTrialActive = entitlement?.periodType == .trial
            AppAnalytics.log("restore_succeeded", params: [
                "had_active_entitlement": isSubscribedReal
            ])
            updateAnalyticsSubscriptionState()
            return isSubscribedReal
        } catch {
            AppAnalytics.log("restore_failed", params: [
                "error_reason": error.localizedDescription
            ])
            return false
        }
        #endif
    }

    /// Presents Apple's offer-code redemption sheet. Successful redemption
    /// updates `customerInfo` automatically via the `customerInfoStream`
    /// listener — there is no synchronous success signal to surface here,
    /// so we only log the open and any error from sheet presentation. A
    /// `redemption_succeeded` event would double-count with the existing
    /// `subscription_state` user-property flip and could fire spuriously
    /// when the user dismissed the sheet without redeeming.
    @MainActor
    func presentCodeRedemption() async {
        AppAnalytics.log("offer_code_redemption_opened")
        #if DEV
        return
        #else
        guard Purchases.isConfigured else {
            AppAnalytics.log("offer_code_redemption_failed", params: [
                "error_reason": "not_configured"
            ])
            return
        }
        do {
            try await Purchases.shared.presentCodeRedemptionSheet()
        } catch {
            AppAnalytics.log("offer_code_redemption_failed", params: [
                "error_reason": String(describing: type(of: error))
            ])
        }
        #endif
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
