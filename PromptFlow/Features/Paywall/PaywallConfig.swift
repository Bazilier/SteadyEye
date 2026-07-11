import Foundation

/// Typed accessors over Remote Config keys used by `PaywallView`.
/// Keeps the view free of `RemoteConfigManager.shared.string("...")`
/// boilerplate and centralizes default-value behavior in one place.
///
/// All accessors are computed (no caching) so a fresh `fetchAndActivate`
/// reflects in the very next paywall render. Cost per access is a
/// dictionary lookup inside the Firebase SDK — negligible.
enum PaywallConfig {
    /// RC offering identifier the paywall should display. Default
    /// `"discount_50"` — matches the hardcoded value before the RC
    /// migration. The experiment override in `PaywallView` may swap
    /// this for `"default"` based on `paywall_v1` variant assignment.
    static var offeringId: String {
        RemoteConfigManager.shared.string("paywall_offering_id")
    }

    /// Hero headline copy. Remote Config delivers a String Catalog
    /// KEY (e.g. `"paywall.v2.headline.getFullAccess"`); we resolve
    /// it via `NSLocalizedString` so the user sees their language.
    /// Falls back to the default key if RC returned empty (e.g. an
    /// experiment variant rolled out without a corresponding entry
    /// in defaults).
    static var headline: String {
        let key = RemoteConfigManager.shared.string("paywall_headline_key")
        let resolvedKey = key.isEmpty ? "paywall.v2.headline.getFullAccess" : key
        return NSLocalizedString(resolvedKey, comment: "Paywall headline (variant via Remote Config)")
    }

    /// Subtitle copy used when at least one visible package has an
    /// active intro discount. Remote Config delivers a String Catalog
    /// KEY (e.g. `"paywall.v2.subtitle.specialOffer"`); we resolve it
    /// via `NSLocalizedString` so the user sees their language. Falls
    /// back to the default key if RC returned empty.
    static var subtitleWithPct: String {
        let key = RemoteConfigManager.shared.string("paywall_subtitle_with_pct")
        let resolvedKey = key.isEmpty ? "paywall.v2.subtitle.specialOffer" : key
        return NSLocalizedString(resolvedKey, comment: "Paywall subtitle when an intro discount is active (variant via Remote Config)")
    }

    /// Subtitle copy used when no visible package has an intro
    /// discount (returning subscriber, intro-eligible-once-per-group
    /// rule already consumed). Remote Config delivers a String Catalog
    /// KEY (e.g. `"paywall.v2.subtitle.getFullAccess"`); we resolve it
    /// via `NSLocalizedString` so the user sees their language. Falls
    /// back to the default key if RC returned empty.
    static var subtitleNoPct: String {
        let key = RemoteConfigManager.shared.string("paywall_subtitle_no_pct")
        let resolvedKey = key.isEmpty ? "paywall.v2.subtitle.getFullAccess" : key
        return NSLocalizedString(resolvedKey, comment: "Paywall subtitle when no intro discount is active (variant via Remote Config)")
    }

    /// Primary CTA button label. Remote Config delivers a String
    /// Catalog KEY (e.g. `"paywall.v2.cta.continue"`); we resolve it
    /// via `NSLocalizedString` so the user sees their language.
    /// Falls back to the default key if RC returned empty.
    /// Single label across all plans — the trial-specific branching
    /// (legacy `paywall.v2.startFreeTrial`) was removed when
    /// discount_50 became the default.
    static var ctaLabel: String {
        let key = RemoteConfigManager.shared.string("paywall_cta_key")
        let resolvedKey = key.isEmpty ? "paywall.v2.cta.continue" : key
        return NSLocalizedString(resolvedKey, comment: "Paywall CTA label (variant via Remote Config)")
    }

    /// Plan that should be pre-selected when the paywall mounts.
    /// Defaults to `.annual`; falls through unknown values (or any
    /// future variant string) to `.annual` so a misconfigured RC
    /// value never leaves the user on a blank selection.
    static var defaultPlan: PaywallPlan {
        switch RemoteConfigManager.shared.string("paywall_default_plan") {
        case "monthly":  return .monthly
        case "lifetime": return .lifetime
        default:         return .annual
        }
    }

    /// Ordered set of plans the paywall should display, driven by the
    /// `paywall_plans` Remote Config key (a JSON array of plan raw values,
    /// e.g. `["monthly","annual","lifetime"]`). Unknown strings are ignored
    /// so a future plan id in the console can't crash older clients. Any
    /// bad / empty / non-JSON value fails safe to the three shipped plans.
    /// Note: weekly appears here only if the console explicitly lists it.
    static var visiblePlans: [PaywallPlan] {
        let ids = RemoteConfigManager.shared.decodeJSON("paywall_plans", as: [String].self) ?? []
        let parsed = ids.compactMap { PaywallPlan(rawValue: $0) }
        return parsed.isEmpty ? [.monthly, .annual, .lifetime] : parsed
    }
}
