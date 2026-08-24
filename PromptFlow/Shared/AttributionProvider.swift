import Foundation
import AppsFlyerLib
import RevenueCat

/// Vendor-neutral MMP (mobile measurement partner) attribution seam.
///
/// This is intentionally SEPARATE from `AppAttributionService` — that service
/// bridges Apple Search Ads attribution from RevenueCat into Firebase user
/// properties for product analytics. This protocol is the MMP install/session
/// attribution surface (AppsFlyer today). Keep the two apart.
///
/// All vendor-specific SDK calls live behind a concrete implementation; no
/// `import AppsFlyerLib` should appear anywhere else in the app. Callers pass
/// the app's own semantic event names; mapping those onto the MMP's event
/// vocabulary is the provider's job, so vendor event names never leak into
/// feature code.
protocol AttributionProvider {
    /// Start MMP session/install tracking.
    ///
    /// Called unconditionally and early in `SteadyEyeApp.init`, and again on
    /// every foreground transition. Deliberately NOT gated on onboarding
    /// completion: a user who installs, opens the app and abandons onboarding
    /// must still register an install. The SDK is told separately to hold the
    /// first session back until ATT resolves (see
    /// `attAuthorizationWaitTimeout`), so calling this before the ATT prompt
    /// does not cost us the IDFA.
    ///
    /// Safe to call repeatedly — one-time configuration happens once, and the
    /// session ping is what the MMP uses for session counting.
    func start()

    /// Report a named funnel event to the MMP, using the app's own event name.
    /// The provider maps it onto the vendor's event vocabulary.
    func trackEvent(_ name: String)

    /// Report a purchase to the MMP. `revenue` and `currency` must come from
    /// the same values used for the GA4 `purchase` event so the two systems
    /// cannot report different numbers for the same transaction.
    func trackPurchase(revenue: Double, currency: String, productId: String)

    /// The MMP's own device/install identifier, if resolved.
    var attributionId: String? { get }

    /// Bridge the MMP's device identifiers into RevenueCat so RC forwards
    /// subscription events to the MMP. Safe to call repeatedly; it only latches
    /// once a write actually happens.
    func syncToRevenueCat()
}

/// AppsFlyer-backed `AttributionProvider`. Every AppsFlyer-SDK-specific call is
/// confined to this class.
///
/// The dev key is read once via `SecretsManager.appsFlyerDevKey()` (the key
/// lives only in the gitignored `Secrets.plist`). If the key is unconfigured
/// the provider no-ops gracefully rather than crashing. Live SDK calls are
/// gated behind `#if !DEV`, matching the app's analytics/attribution
/// convention — the Staging configuration does not define `DEV`, so this code
/// is exercised there under a debugger.
final class AppsFlyerAttributionProvider: AttributionProvider {
    /// App Store ID for this app, required by AppsFlyer to attribute iOS
    /// installs and to match SKAdNetwork postbacks.
    ///
    /// NOTE the format: AppsFlyer wants the BARE numeric iTunes ID, not the
    /// "id"-prefixed App Store URL form. The SDK header documents the parameter
    /// as "Your app's Apple App ID (e.g., \"123456789\")". The App Store URL
    /// .../app/id6761066976 therefore corresponds to appleAppID "6761066976".
    /// Passing the "id" prefix here silently breaks install attribution.
    private static let appleAppID = "6761066976"

    /// How long AppsFlyer holds the first session back waiting for the user to
    /// answer the ATT prompt. 60s is AppsFlyer's documented recommendation.
    ///
    /// It also fits this app's flow: the ATT prompt fires at the end of
    /// onboarding (`OnboardingView.finishOnboarding`), behind the camera, mic
    /// and photos prompts — realistically 15-45s after launch. 60s leaves
    /// headroom to capture the IDFA when the user grants, while still bounding
    /// the delay so a user who abandons onboarding registers an install in the
    /// same session rather than never.
    private static let attAuthorizationWaitTimeout: TimeInterval = 60

    /// App event name → AppsFlyer event name. `af_`-prefixed names are
    /// AppsFlyer's standard events; anything else is a custom event.
    /// `trial_started` is intentionally absent: RevenueCat's server-side
    /// AppsFlyer integration sends `rc_trial_started` for every trial, so the
    /// client-side `af_start_trial` this used to map was a duplicate.
    private static let eventNameMap: [String: String] = [
        "paywall_shown": AFEventContentView,
        "first_recording_completed": "first_recording_completed"
    ]

    private let devKey: String?
    /// One-shot guard for the one-time SDK configuration (keys, ATT wait,
    /// customer user ID). The session ping itself is NOT guarded — AppsFlyer
    /// counts a session per `start()` call.
    private var hasConfigured = false
    /// Latched only once a real write to RevenueCat succeeds, so an early call
    /// (before RC is configured) can still retry on a later invocation.
    private var hasSyncedToRevenueCat = false

    init() {
        devKey = SecretsManager.appsFlyerDevKey()
        if devKey == nil {
            print("[AppsFlyerAttributionProvider] AppsFlyer dev key not configured — attribution will no-op.")
        }
    }

    func start() {
        guard let devKey else { return }
        #if !DEV
        let lib = AppsFlyerLib.shared()
        if !hasConfigured {
            hasConfigured = true
            lib.appsFlyerDevKey = devKey
            lib.appleAppID = Self.appleAppID
            // Join key with RevenueCat. Set BEFORE the first `start()` so the
            // install event already carries it — AppsFlyer attaches the
            // customer user ID at send time, and a later assignment would
            // leave the install unjoinable.
            if Purchases.isConfigured {
                lib.customerUserID = Purchases.shared.appUserID
            }
            // Hold the first session until the ATT decision is in (or the
            // timeout elapses), so the IDFA is attached when the user grants.
            lib.waitForATTUserAuthorization(timeoutInterval: Self.attAuthorizationWaitTimeout)
        }
        lib.start()
        #endif // !DEV
    }

    func trackEvent(_ name: String) {
        guard devKey != nil else { return }
        #if !DEV
        guard let mapped = Self.eventNameMap[name] else {
            assertionFailure("[AppsFlyerAttributionProvider] unmapped attribution event: \(name)")
            return
        }
        AppsFlyerLib.shared().logEvent(mapped, withValues: nil)
        #endif // !DEV
    }

    func trackPurchase(revenue: Double, currency: String, productId: String) {
        guard devKey != nil else { return }
        #if !DEV
        AppsFlyerLib.shared().logEvent(
            AFEventPurchase,
            withValues: [
                AFEventParamRevenue: revenue,
                AFEventParamCurrency: currency,
                AFEventParamContentId: productId,
                AFEventParamQuantity: 1
            ]
        )
        #endif // !DEV
    }

    /// AppsFlyer's UID is a device-local identifier the SDK derives and
    /// persists itself — it does NOT require a server round-trip, so reading it
    /// does not race `start()`. It is read on demand rather than cached at
    /// start time, so a caller that arrives before the SDK is configured simply
    /// gets `nil` and can retry, instead of latching a stale value forever.
    var attributionId: String? {
        guard devKey != nil else { return nil }
        #if !DEV
        let uid = AppsFlyerLib.shared().getAppsFlyerUID()
        return uid.isEmpty ? nil : uid
        #else
        return nil
        #endif
    }

    func syncToRevenueCat() {
        guard devKey != nil else { return }
        #if !DEV
        // Needs RC configured with an app user ID, otherwise the subscriber
        // does not exist yet ("subscriber not found"). Retry on a later call.
        guard Purchases.isConfigured else { return }

        // The AppsFlyer UID is stable for the install, so write it once.
        if !hasSyncedToRevenueCat, let appsFlyerID = attributionId {
            hasSyncedToRevenueCat = true
            Purchases.shared.attribution.setAppsflyerID(appsFlyerID)
        }

        // $idfa is deliberately NOT latched. The launch-time call runs before
        // the user has answered the ATT prompt, so it writes the all-zeros
        // placeholder; the call from the ATT completion handler then replaces
        // it with the real IDFA once tracking is authorized. Latching this
        // would freeze the zeros in place for the life of the install.
        //
        // The attribute must be present (all-zeros when ATT is not granted) or
        // RC drops the events. This is NOT AppsFlyer-specific and applies to
        // every RevenueCat attribution integration.
        Purchases.shared.attribution.setAttributes(["$idfa": ATTManager.advertisingIdentifier])
        #endif // !DEV
    }
}

/// Holds app-lifecycle attribution services. Instantiated once in
/// `SteadyEyeApp.init`, where `start()` is also called immediately — unlike the
/// previous MMP wiring, initialization is not deferred to the end of onboarding.
enum AppServices {
    /// The active MMP provider, set during app init. Nil in DEV builds (where
    /// MMP is not instantiated), so callers use optional chaining to no-op.
    static var attribution: AttributionProvider?
}
