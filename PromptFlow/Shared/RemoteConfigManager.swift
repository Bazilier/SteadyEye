import Foundation
import Combine
#if !DEV
import FirebaseCore
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
final class RemoteConfigManager: ObservableObject {
    static let shared = RemoteConfigManager()

    /// Incremented after every successful activation. Views that render
    /// Remote-Config-driven values observe this object and re-render when it
    /// changes.
    ///
    /// A counter rather than the values themselves: every accessor
    /// (`PaywallConfig.*`, `string(_:)`, `decodeJSON(_:as:)`) already reads
    /// live from the Firebase SDK on each call, so the only thing missing was
    /// a change signal for SwiftUI. Publishing one token keeps the read path
    /// untouched and avoids mirroring nine keys into stored properties that
    /// could drift from what the SDK holds.
    @Published private(set) var activationCount: Int = 0

    /// True when this build is pointed at a NON-PRODUCTION Firebase project.
    ///
    /// Derived from the very same allowlist check that selects the zero fetch
    /// interval (see `fastFetchProjectIDs`), so the two can never disagree —
    /// duplicating the project-id comparison elsewhere would recreate the drift
    /// risk that single source exists to prevent.
    ///
    /// Exists to gate developer-only controls that must never render in Release.
    /// `false` in DEV builds: Firebase is not configured there at all, so there
    /// is no project to be pointed at.
    let isNonProductionFirebaseProject: Bool

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
        "paywall_offering_id":       "default",
        "paywall_mode":              "default",
        "paywall_plans":             "[\"monthly\",\"annual\",\"lifetime\"]",
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
    /// The resolved minimum fetch interval, retained so the diagnostic line can
    /// report which policy is actually in effect without reading source.
    private let minimumFetchInterval: TimeInterval
    /// Firebase project this instance is bound to. `nil` means
    /// `FirebaseApp.app()?.options.projectID` could not be read — see the
    /// diagnostic line, which calls that out explicitly.
    private let firebaseProjectID: String?

    /// Firebase projects that get a ZERO minimum fetch interval, so console
    /// changes reach the device immediately during development.
    ///
    /// This is an ALLOWLIST BY DESIGN, and the direction is deliberate.
    /// Membership is keyed on the Firebase project the build is actually
    /// pointed at (each configuration bundles a different
    /// `GoogleService-Info.plist`), NOT on a compilation condition — Staging
    /// and Release resolve to an identical, empty
    /// `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, so no `#if` can tell them apart.
    ///
    /// DO NOT INVERT THIS to "everything except production gets 0". Inverting
    /// makes the unsafe value the default: a nil `projectID` (initialization
    /// ordering regression), a typo, or a newly added project would all
    /// silently resolve to 0 — and a zero interval against the PRODUCTION
    /// project would hammer the Remote Config backend and risk server-side
    /// throttling for real users. As written, anything unrecognised falls
    /// through to the safe 3600s value; only an explicitly listed project
    /// opts into fast fetching.
    private static let fastFetchProjectIDs: Set<String> = ["steadyeye-staging2"]

    /// Throttled interval used for production and for anything unrecognised.
    private static let throttledFetchInterval: TimeInterval = 3600
    #endif

    private init() {
        #if !DEV
        self.remoteConfig = RemoteConfig.remoteConfig()

        // Which Firebase project are we actually talking to? The
        // "Select GoogleService-Info for configuration" build phase decides
        // that per configuration, so reading it back here derives the fetch
        // policy from the real target rather than from a build flag.
        // Safe by construction: Release bundles the production project, which
        // is not in the allowlist, so it resolves to the throttled value.
        let projectID = FirebaseApp.app()?.options.projectID
        self.firebaseProjectID = projectID
        let usesFastFetch = projectID.map(Self.fastFetchProjectIDs.contains) ?? false
        self.isNonProductionFirebaseProject = usesFastFetch
        let interval: TimeInterval = usesFastFetch ? 0 : Self.throttledFetchInterval
        self.minimumFetchInterval = interval

        let settings = RemoteConfigSettings()
        settings.minimumFetchInterval = interval
        self.remoteConfig.configSettings = settings
        #else
        self.isNonProductionFirebaseProject = false
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
    @MainActor
    func fetchAndActivate() async {
        #if !DEV
        do {
            let status = try await remoteConfig.fetchAndActivate()
            // Signal SwiftUI. Bumped on every successful activation, including
            // one that reused pre-fetched data: a redundant re-render is
            // cheap and idempotent, whereas a missed one leaves the paywall
            // showing last session's config.
            activationCount &+= 1
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
            print("[RemoteConfig] activated #\(activationCount) (\(Self.describe(status)), \(fetchPolicyDescription)):\n\(dump)")
        } catch {
            // No-op. Defaults / last-fetched values remain in effect.
        }
        #endif
    }

    #if !DEV
    /// Fetch policy in effect, for the diagnostic line.
    ///
    /// A `nil` `projectID` is called out loudly rather than left to look like
    /// ordinary throttled behaviour: it means `FirebaseApp` was not configured
    /// when this singleton was first touched, which is an initialization
    /// ordering regression, and the resulting 3600s is a fallback rather than
    /// a deliberate choice.
    private var fetchPolicyDescription: String {
        let interval = "minimumFetchInterval=\(Int(minimumFetchInterval))s"
        guard let firebaseProjectID else {
            return "project=NIL — FirebaseApp.options.projectID unreadable, check init ordering; \(interval) (fallback)"
        }
        return "project=\(firebaseProjectID), \(interval)"
    }

    /// Human-readable activation status for the diagnostic line above.
    /// `fetchAndActivate` throws on failure, so only the two success cases
    /// reach the log — but they mean different things: `fetched-from-remote`
    /// is a real network round-trip, `pre-fetched` means the throttle
    /// (`minimumFetchInterval`) suppressed the fetch and the previously
    /// downloaded payload was activated instead. Without this it is
    /// impossible to tell from the log whether the server was consulted.
    private static func describe(_ status: RemoteConfigFetchAndActivateStatus) -> String {
        switch status {
        case .successFetchedFromRemote:   return "fetched-from-remote"
        case .successUsingPreFetchedData: return "pre-fetched (throttled)"
        case .error:                      return "error"
        @unknown default:                 return "unknown"
        }
    }
    #endif

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

    /// Decodes a JSON-typed Remote Config value into `T`. Works in both
    /// build flavors: in !DEV it reads the native `RemoteConfigValue`
    /// (so the console parameter can be typed JSON) and, if that value is
    /// absent/unparseable, falls back to parsing the compiled default
    /// string; in DEV (where `remoteConfig` doesn't exist) it parses the
    /// compiled default string directly. Returns nil only when both paths
    /// fail — callers apply their own fail-safe.
    func decodeJSON<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        #if !DEV
        // Live RC: read native JSON value, re-encode to Data, decode to T.
        let rcValue = remoteConfig.configValue(forKey: key)
        if let obj = rcValue.jsonValue,
           let data = try? JSONSerialization.data(withJSONObject: obj),
           let decoded = try? JSONDecoder().decode(T.self, from: data) {
            return decoded
        }
        // Fall through to defaults if live value is absent/unparseable.
        #endif
        // DEV build AND !DEV fallback: parse the compiled default string.
        if let raw = defaults[key],
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(T.self, from: data) {
            return decoded
        }
        return nil
    }
}
