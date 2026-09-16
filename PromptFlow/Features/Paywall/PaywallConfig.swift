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
    /// `"default"` (see `RemoteConfigManager` defaults). The experiment
    /// override in `PaywallView` selects `"default"` for the `trial`
    /// variant of `paywall_v1`; other variants use this RC value.
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
        let raw = RemoteConfigManager.shared.string("paywall_default_plan")
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .lowercased()
        if let plan = PaywallPlan(rawValue: normalized) { return plan }
        if !normalized.isEmpty {
            PaywallDiagnostics.unrecognisedDefaultPlan(raw)
        }
        return .annual
    }

    /// Active presentation mode, from the `paywall_mode` Remote Config key.
    /// See `PaywallMode` for the vocabulary-collision warning about the
    /// similarly named `paywall_v1` experiment variant.
    static var mode: PaywallMode {
        // A frozen value always wins. Once an install has resolved its mode it
        // keeps it for life, so flipping the Remote Config key never changes
        // the experience of a user who has already been shown one.
        if let stored = UserDefaults.standard.string(forKey: persistedModeKey),
           let frozen = PaywallMode(rawValue: stored) {
            return frozen
        }

        let resolved = PaywallMode.parse(RemoteConfigManager.shared.string("paywall_mode"))

        // Freeze ONLY once this process has confirmed a successful activation.
        //
        // `activationCount` is incremented inside `fetchAndActivate()`'s `do`
        // block, after `try await remoteConfig.fetchAndActivate()` returns, so
        // the throwing path (offline, server error) can never reach it. A value
        // above zero therefore proves real server data has been applied.
        //
        // Persisting before that would freeze every install on the COMPILED
        // default — trial mode would never reach anyone, silently and
        // irreversibly. An offline first launch instead behaves as default for
        // that session and resolves properly on the next launch with
        // connectivity: one inconsistent session, rather than a permanently
        // wrong mode.
        //
        // The counter is per-process, so on later launches there is a brief
        // window where Firebase already holds correct persisted values but no
        // activation has been confirmed yet. Deferring the freeze by that
        // fraction of a second is deliberate — provenance we can prove beats
        // provenance we assume.
        if RemoteConfigManager.shared.activationCount > 0 {
            UserDefaults.standard.set(resolved.rawValue, forKey: persistedModeKey)
        }
        return resolved
    }

    /// UserDefaults key holding the frozen mode. Plain-noun camelCase, matching
    /// `teleprompterMode` / `devSubscriptionOverride`.
    private static let persistedModeKey = "paywallMode"

    /// The FROZEN mode, or `nil` if this install has not committed to one yet.
    ///
    /// Unlike `mode`, this never falls back to a live Remote Config read. Any
    /// caller whose behaviour must not change under an uncommitted mode reads
    /// this instead — `mode` can return `.trial` from a live resolution before
    /// anything is persisted, and acting on that would apply trial rules to an
    /// install that may yet resolve to default.
    ///
    /// `nil` for an absent key and for an unrecognised stored value, so a
    /// hand-edited or future-version value degrades to "not frozen" rather than
    /// to a guess.
    static var persistedMode: PaywallMode? {
        guard let stored = UserDefaults.standard.string(forKey: persistedModeKey) else { return nil }
        return PaywallMode(rawValue: stored)
    }

    /// Developer-only. Clears the frozen mode so the next resolution re-reads
    /// Remote Config and re-freezes. Surfaced in Settings on non-production
    /// Firebase projects only.
    static func resetPersistedMode() {
        UserDefaults.standard.removeObject(forKey: persistedModeKey)
    }

    /// RevenueCat offering identifier backing trial mode. Fixed rather than
    /// Remote-Config-driven on purpose: `paywall_mode` is the single source of
    /// truth for which offering trial mode requests, so there is no second key
    /// an operator could set to an inconsistent value.
    static let trialOfferingId = "trial"

    // MARK: - Trial-mode copy
    //
    // Catalog keys are fixed here rather than routed through Remote Config.
    // RC carries exactly ONE headline/subtitle/CTA triple
    // (`paywall_headline_key` etc.); making those mode-dependent would let an
    // operator pair trial copy with freemium products, which is the
    // inconsistency this design exists to prevent.

    private static let trialHeadlineKey = "paywall.v2.headline.freeTrial"
    private static let trialSubtitleKey = "paywall.v2.subtitle.freeTrialPerYear"
    private static let trialCtaKey      = "paywall.v2.cta.startFilmingFree"

    /// Trial headline, falling back to the default-mode headline if the catalog
    /// entry is missing.
    static var trialHeadline: String {
        localizedOrNil(trialHeadlineKey, comment: "Paywall hero headline shown when the selected plan carries a free trial.")
            ?? headline
    }

    /// Trial subtitle FORMAT string containing a single `%@` placeholder for the
    /// localized price. Returns nil when the catalog entry is missing, so the
    /// caller falls back to the existing default-mode subtitle logic.
    static var trialSubtitleFormat: String? {
        localizedOrNil(trialSubtitleKey, comment: "Paywall hero subtitle shown when the selected plan carries a free trial. %@ is the localized recurring price.")
    }

    /// Trial CTA, falling back to the default-mode CTA if the catalog entry is
    /// missing.
    static var trialCtaLabel: String {
        localizedOrNil(trialCtaKey, comment: "Paywall primary CTA shown when the selected plan carries a free trial.")
            ?? ctaLabel
    }

    /// `NSLocalizedString` returns the key itself when the key is absent from
    /// the catalog. Detect that and report nil so callers can fall back to the
    /// corresponding default-mode string rather than rendering a raw key.
    private static func localizedOrNil(_ key: String, comment: String) -> String? {
        let resolved = NSLocalizedString(key, comment: comment)
        guard resolved != key, !resolved.isEmpty else { return nil }
        return resolved
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

// MARK: - Paywall presentation mode

/// Which presentation the paywall should use, driven by the `paywall_mode`
/// Remote Config key.
///
/// ⚠️ VOCABULARY COLLISION — READ BEFORE EDITING.
/// This is NOT the same axis as the `paywall_v1` A/B experiment, which also has
/// a variant literally named `"trial"`. That experiment's `"trial"` variant maps
/// to the RevenueCat offering named `"default"` (see
/// `PaywallView.paywallResolution`) and predates this key entirely. The two are
/// unrelated: `paywall_mode` selects freemium-vs-free-trial presentation, while
/// `experiment_paywall_v1` selects which offering the legacy A/B test shows.
/// Changing one does not affect the other, and "trial" means different things
/// in each.
enum PaywallMode: String {
    /// Today's live freemium presentation. The fallback for every failure path.
    case `default`
    /// Free-trial presentation, backed by the RevenueCat offering named `trial`.
    /// Once the entitlement lapses, the gates lock recording and AI
    /// optimisation entirely — see `SubscriptionManager.canRecord`.
    case trial
    /// Free-trial presentation, IDENTICAL to `.trial` in every presentational
    /// respect and backed by the same `trial` offering. The two diverge only
    /// AFTER the entitlement lapses: `.hybrid` falls back to freemium gating
    /// (watermarked recording, one AI optimisation per calendar day) where
    /// `.trial` locks the user out.
    ///
    /// This split is what every call site keys on, and the two tests are not
    /// interchangeable:
    ///  - PRESENTATION reads `!= .default`, so `.hybrid` is carried along.
    ///  - ENTITLEMENT GATING reads `== .trial`, so `.hybrid` is excluded.
    case hybrid

    /// Parses a raw Remote Config value. ANYTHING unrecognised — including an
    /// empty string, a typo, or a value from a newer app version — resolves to
    /// `.default`. Never invert this: the freemium paywall is live in
    /// production and must be what a misconfiguration degrades to.
    static func parse(_ raw: String) -> PaywallMode {
        if let mode = PaywallMode(rawValue: raw) { return mode }
        PaywallDiagnostics.unrecognisedMode(raw)
        return .default
    }
}

/// One-shot diagnostics for paywall configuration problems. Latched so a
/// misconfiguration is reported once per session rather than on every render —
/// these are read from computed properties inside `body`.
enum PaywallDiagnostics {
    private static var loggedUnrecognisedMode = false
    private static var loggedUnrecognisedDefaultPlan = false
    private static var loggedTrialOfferingUnresolved = false
    private static var loggedNonAnnualTrialPlans: Set<String> = []

    static func unrecognisedMode(_ raw: String) {
        guard !loggedUnrecognisedMode else { return }
        loggedUnrecognisedMode = true
        print("""
        ⚠️ PAYWALL MISCONFIGURATION: unrecognised paywall_mode value \"\(raw)\". \
        Recognised values are \"default\" and \"trial\". Falling back to default \
        (freemium) presentation. Check the paywall_mode parameter in Firebase Remote Config.
        """)
    }

    static func unrecognisedDefaultPlan(_ raw: String) {
        guard !loggedUnrecognisedDefaultPlan else { return }
        loggedUnrecognisedDefaultPlan = true
        print("""
        ⚠️ PAYWALL MISCONFIGURATION: unrecognised paywall_default_plan value \"\(raw)\". \
        Recognised values are \"weekly\", \"monthly\", \"annual\" and \"lifetime\". Falling back to annual. \
        Check the paywall_default_plan parameter in Firebase Remote Config.
        """)
    }

    /// The operator asked for trial mode and the app could not honour it. A live
    /// paywall is showing different copy and different products than intended,
    /// so this is deliberately loud and greppable on either "PAYWALL" or the
    /// warning glyph, without needing to know the key name in advance.
    ///
    /// Also reported to Firebase. A Console line only helps someone who is
    /// already watching Console; in production this failure is SILENT — it
    /// looks exactly like normal freemium behaviour and would surface only as
    /// an unexplained conversion drop. The event makes it visible in aggregate.
    /// Latched with the print below so a broken config reports once per session
    /// rather than once per render.
    ///
    /// Deliberately the ONLY fallback path with an event: an unrecognised
    /// `paywall_mode` is an operator typo caught within minutes, and a missing
    /// localization string degrades to correct copy. Neither is silent AND
    /// consequential; this one is both.
    static func trialOfferingUnresolved(attemptedMode: PaywallMode, offeringId: String) {
        guard !loggedTrialOfferingUnresolved else { return }
        loggedTrialOfferingUnresolved = true
        AppAnalytics.log("paywall_mode_fallback", params: [
            "attempted_mode": attemptedMode.rawValue,
            "offering_id": offeringId
        ])
        print("""
        ⚠️⚠️ PAYWALL MISCONFIGURATION — TRIAL MODE NOT APPLIED ⚠️⚠️
        paywall_mode=trial, but the RevenueCat offering \"\(offeringId)\" could not be resolved.
        The paywall has fallen back ENTIRELY to default (freemium) products AND copy.
        Users are seeing something other than what was configured.
        Fix: confirm an offering with identifier \"\(offeringId)\" exists and is published
        in the RevenueCat dashboard, and that offerings have loaded on this device.
        """)
    }

    /// Trial copy says "per year" because only the annual product carries a
    /// trial. A trial on any other plan is a configuration the app must not
    /// present, so it degrades to default copy rather than showing wrong copy.
    static func trialOnNonAnnualPlan(_ plan: String) {
        guard !loggedNonAnnualTrialPlans.contains(plan) else { return }
        loggedNonAnnualTrialPlans.insert(plan)
        print("""
        ⚠️ PAYWALL MISCONFIGURATION: the \"\(plan)\" plan carries a free trial, but trial copy \
        is written for an annual term ("per year"). Showing default copy for this plan instead. \
        Either remove the trial from \"\(plan)\" or add term-specific trial copy.
        """)
    }
}
