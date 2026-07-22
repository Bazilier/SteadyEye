import Foundation
import TenjinSDK
import RevenueCat

/// Vendor-neutral MMP (mobile measurement partner) attribution seam.
///
/// This is intentionally SEPARATE from `AppAttributionService` — that service
/// bridges Apple Search Ads attribution from RevenueCat into Firebase user
/// properties for product analytics. This protocol is the MMP install/session
/// attribution surface (Tenjin today). Keep the two apart.
///
/// All vendor-specific SDK calls live behind a concrete implementation; no
/// `import TenjinSDK` should appear anywhere else in the app.
protocol AttributionProvider {
    /// Start the MMP session/install tracking. Must be called AFTER the ATT
    /// prompt has resolved (granted or denied) so IDFA — when authorized — is
    /// available for the first install event.
    func connect()

    /// Report a named attribution event to the MMP. Used to drive the MMP's
    /// SKAdNetwork conversion-value mapping (events matched by exact name).
    func trackEvent(_ name: String)

    /// Report a named attribution event carrying an integer value — drives the
    /// MMP's conversion-value mapping for value-bucketed events (e.g. purchase
    /// revenue ranges). This sends a valued custom event only; it does NOT
    /// record a revenue transaction, so it does not double-count revenue that
    /// RevenueCat already forwards server-side.
    func trackEvent(_ name: String, value: Int)

    /// Report a purchase/revenue event to the MMP.
    ///
    /// ⚠️ Intentionally NEVER called from the purchase flow. Purchases reach
    /// Tenjin SERVER-SIDE via RevenueCat's Tenjin integration (the $tenjinId +
    /// $idfa bridge set up in `syncToRevenueCat()`), which is the single source
    /// of truth for Tenjin revenue. Calling this client-side would DOUBLE-COUNT
    /// revenue in Tenjin. Kept only as a vendor-neutral seam for a hypothetical
    /// future MMP that lacks server-side purchase forwarding.
    func trackPurchase(revenue: Double, currency: String, productId: String)

    /// The MMP's own device/install identifier, if resolved. Nil until the SDK
    /// has connected and reported one. Phase 2 bridges this into RevenueCat.
    var attributionId: String? { get }

    /// Bridge the MMP's device identifiers (install ID + IDFA) into RevenueCat
    /// so RC forwards subscription events to the MMP. Call after `connect()`
    /// and after RevenueCat has been configured.
    func syncToRevenueCat()
}

/// Tenjin-backed `AttributionProvider`. Every Tenjin-SDK-specific call is
/// confined to this class.
///
/// The SDK key is read once via `SecretsManager.tenjinSDKKey()` (the key lives
/// only in the gitignored `Secrets.plist`). If the key is unconfigured the
/// provider no-ops gracefully rather than crashing. Live SDK calls are gated
/// behind `#if !DEV`, matching the app's analytics/attribution convention.
final class TenjinAttributionProvider: AttributionProvider {
    private let sdkKey: String?
    private var cachedAttributionId: String?
    /// One-shot guard: `connect()` may be reached from both the onboarding
    /// completion path and the launch path for returning users. Ensures the
    /// Tenjin session connect fires at most once per launch (per instance).
    private var hasConnected = false
    /// One-shot guard for the RevenueCat attribute bridge (Phase 2). Only set
    /// once a real sync completes, so an early call (before Tenjin connected or
    /// RC configured) can still retry.
    private var hasSyncedToRevenueCat = false

    init() {
        sdkKey = SecretsManager.tenjinSDKKey()
        if sdkKey == nil {
            print("[TenjinAttributionProvider] Tenjin SDK key not configured — attribution will no-op.")
        }
    }

    func connect() {
        guard !hasConnected else { return }
        hasConnected = true
        guard let key = sdkKey else { return }
        #if !DEV
        TenjinSDK.getInstance(key)
        TenjinSDK.connect()
        // Cache Tenjin's analytics installation ID for later bridging (Phase 2).
        // Per the resolved TenjinSDK 1.17.1 header, `getAnalyticsInstallationId`
        // is a synchronous getter returning the cached ID (may be nil until
        // `connect` resolves) — not an async completion-handler API.
        cachedAttributionId = TenjinSDK.getAnalyticsInstallationId()
        #endif // !DEV
    }

    func trackEvent(_ name: String) {
        guard sdkKey != nil else { return }
        #if !DEV
        TenjinSDK.sendEvent(withName: name)
        #endif // !DEV
    }

    func trackEvent(_ name: String, value: Int) {
        guard sdkKey != nil else { return }
        #if !DEV
        // `sendEventWithName:andValue:` sends a valued custom event for the
        // SKAN conversion-value mapping WITHOUT recording a revenue
        // transaction (unlike `transaction(...)`), so it never double-counts
        // revenue that RevenueCat forwards to Tenjin server-side.
        TenjinSDK.sendEvent(withName: name, andValue: value)
        #endif // !DEV
    }

    // ⚠️ Deliberately unused — do NOT call from the purchase flow. RevenueCat
    // forwards purchases to Tenjin server-side; a client-side call here would
    // double-count revenue. See the protocol doc for details.
    func trackPurchase(revenue: Double, currency: String, productId: String) {
        guard sdkKey != nil else { return }
        #if !DEV
        TenjinSDK.transaction(
            withProductName: productId,
            andCurrencyCode: currency,
            andQuantity: 1,
            andUnitPrice: NSDecimalNumber(value: revenue)
        )
        #endif // !DEV
    }

    var attributionId: String? { cachedAttributionId }

    func syncToRevenueCat() {
        guard !hasSyncedToRevenueCat else { return }
        // Needs Tenjin's install ID (connect() must have run). If not yet
        // available, no-op and allow a later call to retry.
        guard let installationID = attributionId else {
            print("[TenjinAttributionProvider] syncToRevenueCat skipped — Tenjin not connected yet.")
            return
        }
        #if !DEV
        // Needs RC configured with an app user ID, otherwise the subscriber
        // does not exist yet ("subscriber not found"). Retry on a later call.
        guard Purchases.isConfigured else { return }
        hasSyncedToRevenueCat = true
        // Reserved attributes RC forwards to the Tenjin integration. $idfa must
        // be present (all-zeros when ATT not granted) or RC drops the events.
        Purchases.shared.attribution.setTenjinAnalyticsInstallationID(installationID)
        Purchases.shared.attribution.setAttributes(["$idfa": ATTManager.advertisingIdentifier])
        #endif // !DEV
    }
}

/// Holds app-lifecycle attribution services. Instantiated once in
/// `SteadyEyeApp.init`; `connect()` is invoked separately from the ATT
/// completion handler at the end of onboarding, never at instantiation time.
enum AppServices {
    /// The active MMP provider, set during app init. Nil in DEV builds (where
    /// MMP is not instantiated), so callers use optional chaining to no-op.
    static var attribution: AttributionProvider?
}
