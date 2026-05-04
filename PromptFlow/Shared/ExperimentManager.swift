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
