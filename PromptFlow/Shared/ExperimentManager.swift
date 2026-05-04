import Foundation
import FirebaseAnalytics

/// Sticky variant assignment for paywall A/B/n experiments.
///
/// First read for a given experiment key:
///  1. Pulls the variant from `RemoteConfigManager` (Firebase Console
///     conditions perform the random split server-side; whatever RC
///     returns is the user's assignment).
///  2. Persists the result to `UserDefaults` under
///     `experiment_<key>_variant` — locks the user into that variant
///     for the rest of the install. Subsequent calls read straight
///     from UserDefaults.
///  3. Sets the variant as a Firebase Analytics user property
///     `exp_<key>` so funnel events can be segmented by experiment
///     group in GA4 dashboards. Only set on the first call (sticky
///     storage prevents re-setting on later calls).
///
/// `"control"` is the universal no-op variant. When Firebase isn't
/// reachable on a fresh install, defaults set in `RemoteConfigManager`
/// keep every device on `"control"` — current production behavior is
/// preserved without any backend involvement.
final class ExperimentManager {
    static let shared = ExperimentManager()
    private init() {}

    /// Once-per-process latch for the `chat_gated_unavailable`
    /// analytics event. Avoids spamming the funnel with a row for
    /// every Settings render while the gate is closed.
    private var hasLoggedChatGatedThisSession = false

    /// Returns the variant the user is locked into. First call for a
    /// given experiment performs assignment + persistence + analytics
    /// user-property write; subsequent calls are pure reads.
    func variant(for experiment: ExperimentKey) -> String {
        let storageKey = "experiment_\(experiment.rawValue)_variant"
        if let stored = UserDefaults.standard.string(forKey: storageKey) {
            return stored
        }
        let rcKey = "experiment_\(experiment.rawValue)"
        let assigned = RemoteConfigManager.shared.string(rcKey)
        UserDefaults.standard.set(assigned, forKey: storageKey)
        // Analytics.setUserProperty is no-op'd in DEV to match the
        // surrounding pattern (`AppAnalytics.log`, etc.) — Firebase
        // isn't configured in DEV builds, so user-property writes
        // would be silently dropped anyway.
        #if !DEV
        Analytics.setUserProperty(assigned, forName: "exp_\(experiment.rawValue)")
        #endif
        return assigned
    }

    // MARK: - Chat audience policy
    //
    // Unlike `variant(for:)`, the chat-availability flag is NOT
    // sticky — a user transitioning trial→paid (or paid→free) needs
    // their gate state to follow them, so we read RC live every time.
    // Allowed values for `chat_enabled_for`: "all", "trial_or_paid",
    // "paid", "none". Default `"all"` is seeded in
    // `RemoteConfigManager.defaults`.

    /// Raw policy string. Useful for analytics segmentation; most
    /// callers want `isChatAvailable` instead.
    var chatEnabledFor: String {
        let value = RemoteConfigManager.shared.string("chat_enabled_for")
        return value.isEmpty ? "all" : value
    }

    /// Whether the chat surface should render for the current user.
    /// Combines the live RC policy with `SubscriptionManager.shared`.
    /// Unknown / future policy values fall through to `true` so a
    /// misconfigured RC value never silently hides the feature.
    @MainActor
    var isChatAvailable: Bool {
        let policy = chatEnabledFor
        let sub = SubscriptionManager.shared
        let available: Bool
        switch policy {
        case "all":            available = true
        case "trial_or_paid":  available = sub.isSubscribed
        case "paid":           available = sub.isSubscribed && !sub.isTrialActive
        case "none":           available = false
        default:               available = true
        }
        if !available, !hasLoggedChatGatedThisSession {
            hasLoggedChatGatedThisSession = true
            AppAnalytics.log("chat_gated_unavailable", params: ["policy": policy])
        }
        return available
    }
}

/// Experiment registry. Add a new case here to introduce a new
/// experiment, then wire its variant into the relevant call site.
/// `rawValue` is the suffix used for both the RC key
/// (`experiment_<rawValue>`) and the GA4 user property
/// (`exp_<rawValue>`).
enum ExperimentKey: String {
    /// Paywall offering selection: `control` (discount_50) vs
    /// `trial` (default offering with the 7-day trial flow). Used
    /// to validate which monetization model produces better LTV.
    case paywallV1 = "paywall_v1"
}
