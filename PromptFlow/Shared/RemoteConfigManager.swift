import Foundation
#if !DEV
import FirebaseRemoteConfig
#endif

/// Thin wrapper over Firebase Remote Config.
///
/// - All reads go through `string(_:)`. Type-safe accessors live in
///   feature-specific façades (e.g. `PaywallConfig`).
/// - `setDefaults()` is called once at app launch BEFORE the first
///   paywall render so reads always resolve to a non-empty value
///   even when the network is unreachable.
/// - `fetchAndActivate()` is a fire-and-forget async call after launch.
///   Failures are silent — last-activated values (or seeded defaults
///   on first run) remain in effect.
///
/// **DEV builds** skip Firebase entirely (FirebaseApp isn't configured
/// in `SteadyEyeApp.init`'s `#if !DEV` block, so calling
/// `RemoteConfig.remoteConfig()` would assert). Reads fall through
/// to the local defaults dict directly. Effect: every variant is
/// `"control"`, every paywall string matches the production default —
/// behavior is identical to control-group production.
///
/// All seven defaults match the current hardcoded production behavior,
/// so the app works identically when Firebase is offline or in DEV.
final class RemoteConfigManager {
    static let shared = RemoteConfigManager()

    // MARK: - RC Key Convention
    //
    // Text values that need localization are stored in Remote Config
    // as `*_key` suffixes — the values are String Catalog identifiers,
    // NOT raw user-facing text. The app resolves them via
    // `NSLocalizedString` at render time so each user sees their
    // language. The catalog (en + es-419 + pt-BR + ru) is the source
    // of truth for translations; Firebase Console only chooses WHICH
    // catalog key is active per-experiment.
    //
    // Example: `paywall_headline_key` = `paywall.v2.headline.lookConfident`
    //          → app shows "Look confident on camera" (en),
    //            "Pareça confiante na câmera" (pt-BR), etc.
    //
    // The `paywall_subtitle_*` parameters follow the same convention:
    // their values are catalog keys, resolved by `PaywallConfig` via
    // `NSLocalizedString`. Anyone overriding these in Firebase Console
    // must enter a catalog key (e.g. `paywall.v2.subtitle.getFullAccess`),
    // NOT translated prose — translations live in `Localizable.xcstrings`.
    //
    // Non-text RC values (`offering_id`, `default_plan`, `experiment_*`)
    // are stored as raw strings without the `_key` suffix.

    /// Defaults dict — single source of truth. Seeded into Firebase
    /// RC by `setDefaults()`, AND used directly by DEV builds (and
    /// as a fallback when RC returns empty for an unknown key).
    private let defaults: [String: String] = [
        "paywall_offering_id":       "discount_50",
        "paywall_headline_key":      "paywall.v2.headline.getFullAccess",
        "paywall_subtitle_with_pct": "paywall.v2.subtitle.specialOfferWithPct",
        "paywall_subtitle_no_pct":   "paywall.v2.subtitle.getFullAccess",
        "paywall_cta_key":           "paywall.v2.cta.continue",
        "paywall_default_plan":      "annual",
        "experiment_paywall_v1":     "control",
        "chat_enabled_for":          "all",
    ]

    #if !DEV
    private let remoteConfig: RemoteConfig
    #endif

    private init() {
        #if !DEV
        self.remoteConfig = RemoteConfig.remoteConfig()
        let settings = RemoteConfigSettings()
        // Debug-config builds always pull fresh values so QA can
        // verify experiment changes without the production cache
        // window. Release uses the standard 1-hour minimum to avoid
        // hammering the service.
        #if DEBUG
        settings.minimumFetchInterval = 0
        #else
        settings.minimumFetchInterval = 3600
        #endif
        self.remoteConfig.configSettings = settings
        #endif
    }

    /// Seeds in-process defaults so reads work BEFORE the first
    /// successful network fetch. Call once at app launch, after
    /// `FirebaseApp.configure()`. No-op in DEV.
    func setDefaults() {
        #if !DEV
        let nsObjectDefaults = defaults.mapValues { $0 as NSObject }
        remoteConfig.setDefaults(nsObjectDefaults)
        #endif
    }

    /// Async fetch + activate. Silent on failure — values stay at
    /// their last-activated state (defaults on first cold launch).
    /// No-op in DEV.
    func fetchAndActivate() async {
        #if !DEV
        do {
            _ = try await remoteConfig.fetchAndActivate()
            // Developer diagnostic: dump every known key with its currently
            // active value so it's obvious what the server delivered (or
            // what fell through to defaults). Iterates `defaults` so the
            // list stays exhaustive without extra wiring when new keys are
            // added. Visible in TestFlight / App Store builds via
            // Console.app over USB so we can verify what's actually live
            // on real devices.
            let dump = defaults.keys.sorted().map { key in
                "  \(key) = \(remoteConfig.configValue(forKey: key).stringValue)"
            }.joined(separator: "\n")
            print("[RemoteConfig] activated:\n\(dump)")
        } catch {
            // No-op. Defaults / last-fetched values remain in effect.
        }
        #endif
    }

    /// Returns the current activated string value for `key`.
    /// In !DEV: queries Firebase RC; falls through to the local
    /// defaults dict if RC returned empty (key not in setDefaults).
    /// In DEV: reads the local defaults dict directly.
    /// Thread-safe per Firebase SDK guarantees.
    func string(_ key: String) -> String {
        #if !DEV
        let value = remoteConfig.configValue(forKey: key).stringValue
        if !value.isEmpty { return value }
        #endif
        return defaults[key] ?? ""
    }
}
