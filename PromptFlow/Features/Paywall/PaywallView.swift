import SwiftUI
import RevenueCat
import FirebaseAnalytics

enum PaywallPlan: String, CaseIterable, Identifiable {
    case weekly, monthly, annual, lifetime
    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekly:
            return String(
                localized: "paywall.v2.plan.weekly",
                defaultValue: "Weekly",
                comment: "Paywall v2 plan row title."
            )
        case .monthly:
            return String(
                localized: "paywall.v2.plan.monthly",
                defaultValue: "Monthly",
                comment: "Paywall v2 plan row title."
            )
        case .annual:
            return String(
                localized: "paywall.v2.plan.annual",
                defaultValue: "Annual",
                comment: "Paywall v2 plan row title."
            )
        case .lifetime:
            return String(
                localized: "paywall.v2.plan.lifetime",
                defaultValue: "Lifetime",
                comment: "Paywall v2 plan row title."
            )
        }
    }
}

/// Presentation token for `fullScreenCover(item:)`, carrying the analytics
/// `source` alongside the presented/not-presented state so the two move in a
/// SINGLE state write.
///
/// With two independent `@State` values — a `Bool` and a separate source
/// `String` — SwiftUI can build `PaywallView` before the source assignment has
/// landed. `source` is a `let` on a struct that is rebuilt on every re-render
/// while the view's own `@State` survives, so `paywall_shown` (emitted once
/// from `.onAppear`, latched) could report the stale value while every later
/// event in the same presentation reported the fresh one. Binding the source to
/// the item removes the window rather than papering over it: the closure below
/// receives the value that triggered the presentation.
struct PaywallPresentation: Identifiable {
    let id = UUID()
    let source: String
    /// See `PaywallView.pillPhrase`.
    var pillPhrase: String? = nil
    /// See `PaywallView.eyeContact`.
    var eyeContact: Double? = nil
}

struct PaywallView: View {
    let source: String
    /// Words from the user's own script for the prompter pill at the top.
    /// Nil: the pill cycles a line about the app instead.
    var pillPhrase: String? = nil
    /// Share of the user's last take spent looking at the lens, 0...1. Shown
    /// as a chip only from `eyeContactChipThreshold` up: a low number would
    /// argue against buying.
    var eyeContact: Double? = nil
    /// Optional RC offering identifier. Explicit override — when set,
    /// packages resolve from the named offering directly. When `nil`
    /// (default for all current call sites), the offering is chosen from
    /// `PaywallConfig.offeringId` / the `paywall_v1` experiment, falling
    /// back to `offerings.current`.
    var offeringId: String? = nil
    var onPurchaseSuccess: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = SubscriptionManager.shared
    /// Re-renders this view when a new Remote Config activates, so a
    /// config published mid-session reaches an already-visible paywall.
    @ObservedObject private var remoteConfig = RemoteConfigManager.shared

    @State private var selectedPlan: PaywallPlan = PaywallConfig.defaultPlan
    /// Set only by an explicit plan row tap. Until then, `selectedPlan` keeps
    /// catching up to `resolvedDefaultPlan` as offerings load and Remote
    /// Config activates.
    @State private var userDidPickPlan = false
    @State private var errorMessage: String?
    @State private var isRestoring: Bool = false
    @State private var restoreResultMessage: String? = nil
    @State private var restoreSucceeded: Bool = false
    @State private var showRestoreAlert: Bool = false

    /// Whether THIS user can still receive the introductory offer.
    ///
    /// A tri-state, not a boolean: `.unknown` is genuinely different from
    /// `.ineligible`, and RevenueCat supplies it as a first-class case rather
    /// than something we synthesise. Starts `.unknown` and is replaced once
    /// `refreshTrialEligibility()` resolves.
    @State private var trialEligibility: IntroEligibilityStatus = .unknown

    /// One-shot guard for `paywall_shown`. The event is deferred until the
    /// offering resolves, and several lifecycle hooks race to emit it.
    @State private var hasLoggedPaywallShown: Bool = false

    /// One-shot guard for `paywall_dismissed`, mirroring `hasLoggedPaywallShown`.
    /// `onDisappear` fires more than once per presentation — StoreKit's payment
    /// sheet covering this `fullScreenCover` triggers one on its own — so the
    /// event needs the same latch the appear side already has.
    @State private var hasLoggedPaywallDismissed: Bool = false

    /// Whether this presentation ended in the user holding `access`, by purchase
    /// or by restore. Read by `paywall_dismissed`, which cannot ask
    /// `SubscriptionManager` directly: `onDisappear` can fire while the purchase
    /// is still in flight, long before `isSubscribedReal` is written.
    @State private var didPurchase: Bool = false

    /// True only while THIS view's purchase is awaiting the store. Owned here
    /// rather than read from `SubscriptionManager.isLoading`, which is also
    /// raised by `restorePurchases()` — a restore in flight would otherwise
    /// suppress a genuine dismissal, since the Dismiss button stays tappable
    /// throughout one.
    @State private var isPurchaseInFlight: Bool = false

    /// Re-entrancy lock for `purchase(_:)`. Deliberately SEPARATE state from
    /// `isPurchaseInFlight`, because the two have different lifetimes and
    /// merging them would break one of them:
    ///
    ///  - `isPurchaseInFlight` must clear the INSTANT the store call returns,
    ///    so `onDisappear` can tell a real dismissal from the payment sheet
    ///    covering this view (see the comment there). It cannot stay set across
    ///    `dismiss()`.
    ///  - This flag must stay set ACROSS `dismiss()`. The success path clears
    ///    `isPurchaseInFlight` and then runs ~60 lines before calling
    ///    `dismiss()`, whose `fullScreenCover` animation takes ~0.35s more —
    ///    and the CTA is mounted and hit-testable that whole time. A second tap
    ///    in that window re-purchased an already-owned product, StoreKit
    ///    returned the existing transaction, and the entire `.succeeded` branch
    ///    ran twice: duplicate `purchase_succeeded`, `trial_started` and, on the
    ///    paid branch, a second `af_purchase` carrying revenue.
    ///
    /// Cleared on `.userCancelled` and `.failed` so a retry works; deliberately
    /// NOT cleared on `.succeeded`, where this presentation is on its way out.
    @State private var isPurchaseLocked: Bool = false

    /// A purchase or restore is awaiting the store: the CTA shows a spinner
    /// and the plan controls are disabled. Derived, not stored.
    private var isTransactionInFlight: Bool { isPurchaseInFlight || isRestoring }

    // MARK: - Packages from offerings

    /// SINGLE SOURCE OF TRUTH for which offering is displayed and whether trial
    /// presentation is permitted. Both are returned together so the products on
    /// screen and the copy describing them can never disagree.
    ///
    /// `paywall_mode` is authoritative. In any NON-DEFAULT mode (`.trial` and
    /// `.hybrid` alike) it selects the offering outright and
    /// `paywall_offering_id` is inert; in default mode `paywall_offering_id`
    /// chooses as it always has — which is what keeps `discount_50` reachable.
    /// An operator therefore cannot express an inconsistent pair: mode wins,
    /// and the losing key simply does not apply.
    ///
    /// The resolved mode is returned VERBATIM rather than collapsed to
    /// `.trial`, so a caller can still tell `.hybrid` from `.trial`. Nothing on
    /// the paywall needs that distinction today — presentation is identical —
    /// but flattening it here would silently discard the only signal that says
    /// which mode is live.
    private var paywallResolution: (offering: Offering?, mode: PaywallMode) {
        // Explicit caller override wins over both Remote Config and
        // the experiment assignment (used by A/B test landing pages,
        // future winback campaigns, etc.). Always default presentation:
        // a caller naming an offering directly is not asking for trial copy.
        if let explicit = offeringId {
            return (manager.offering(for: explicit), .default)
        }

        // `!= .default` rather than `== .trial`: this is a PRESENTATION
        // decision, and `.hybrid` presents exactly as `.trial` does. Every
        // future non-default mode should opt in here by construction.
        let configuredMode = PaywallConfig.mode
        if configuredMode != .default {
            // Resolve BY NAME, deliberately NOT via `manager.offering(for:)` —
            // that helper silently substitutes `offerings.current` on a miss,
            // which here would paint trial copy over non-trial products. A miss
            // must degrade to default mode entirely, not inherit the dashboard's
            // current offering.
            if let trialOffering = manager.offerings?[PaywallConfig.trialOfferingId] {
                return (trialOffering, configuredMode)
            }
            // Report the mode that was ACTUALLY configured, never a hardcoded
            // `.trial`. This value reaches both the console warning and the
            // `paywall_mode_fallback` event, and naming the wrong mode would
            // send whoever reads it to the wrong Remote Config parameter.
            PaywallDiagnostics.trialOfferingUnresolved(
                attemptedMode: configuredMode,
                offeringId: PaywallConfig.trialOfferingId
            )
            // Fall through to default mode, copy included.
        }

        // Experiment override: users in `paywall_v1 == "trial"` see
        // the legacy `default` offering (7-day trial flow). All other
        // variants — including the seeded `"control"` default — fall
        // through to whatever `paywall_offering_id` dictates (currently
        // `discount_50`). Variant assignment is sticky per install
        // and gets logged to GA4 via the `paywall_shown` event below.
        // NOTE: this variant's `"trial"` is unrelated to `paywall_mode`
        // `"trial"` — see the warning on `PaywallMode`.
        let variant = ExperimentManager.shared.variant(for: .paywallV1)
        let chosenId: String = (variant == "trial") ? "default" : PaywallConfig.offeringId
        return (manager.offering(for: chosenId) ?? manager.offering(for: nil), .default)
    }

    private var resolvedOffering: Offering? { paywallResolution.offering }

    /// Whether the paywall should render trial copy for the CURRENTLY SELECTED
    /// plan. Driven by the selected plan's product, not by the mode, so tapping
    /// Monthly in trial mode shows freemium copy and tapping Annual restores
    /// trial copy — live, because `selectedPlan` is `@State` and re-renders
    /// `body`.
    ///
    /// Requires BOTH conditions, and fails closed on either:
    ///  - the product carries an actual FREE TRIAL (`paymentMode == .freeTrial`,
    ///    not merely the presence of an introductory discount, which is also
    ///    true for a paid intro offer), and
    ///  - the plan is annual, because the trial subtitle is written for an
    ///    annual term.
    private var showsTrialCopy: Bool {
        // Eligibility first: a user who has already consumed the group's
        // introductory offer must never be promised it again.
        guard isEligibleForTrial else { return false }
        // `!= .default` for the same reason as the offering resolution above:
        // hero copy is presentation, and `.hybrid` presents as `.trial`.
        guard paywallResolution.mode != .default,
              let product = package(for: selectedPlan)?.storeProduct,
              product.introductoryDiscount?.paymentMode == .freeTrial
        else { return false }

        guard selectedPlan == .annual else {
            PaywallDiagnostics.trialOnNonAnnualPlan(selectedPlan.rawValue)
            return false
        }
        return true
    }
    private var annualPackage: Package? { resolvedOffering?.annual }
    private var monthlyPackage: Package? { resolvedOffering?.monthly }
    private var lifetimePackage: Package? { resolvedOffering?.lifetime }
    private var weeklyPackage: Package? { resolvedOffering?.weekly }

    private func package(for plan: PaywallPlan) -> Package? {
        switch plan {
        case .weekly: return weeklyPackage
        case .monthly: return monthlyPackage
        case .annual: return annualPackage
        case .lifetime: return lifetimePackage
        }
    }

    // MARK: - Remote-Config-driven visible plan set

    /// Plans listed in `paywall_plans` that also have a resolved package.
    /// A plan appears only if it is BOTH configured as visible AND its
    /// RevenueCat package exists — so a plan in the JSON with no product
    /// (e.g. weekly before its RC product ships) silently collapses out.
    private var renderablePlans: [PaywallPlan] {
        let visible = PaywallConfig.visiblePlans.filter { package(for: $0) != nil }
        if !visible.isEmpty { return visible }
        // Offering not loaded yet (or none of the configured plans have a
        // package): fall back to whatever packages exist, in fixed order,
        // and never render zero plans.
        let fallback: [PaywallPlan] = [.monthly, .annual, .lifetime].filter { package(for: $0) != nil }
        return fallback.isEmpty ? [.annual] : fallback
    }

    /// The pre-selected / collapsed plan, honoring `paywall_default_plan`
    /// but constrained to something actually on screen: the RC default if
    /// it is renderable, else the first renderable plan, else annual.
    private var resolvedDefaultPlan: PaywallPlan {
        let d = PaywallConfig.defaultPlan
        if renderablePlans.contains(d) { return d }
        return renderablePlans.first ?? .annual
    }

    // MARK: - Intro pricing helper

    /// Two-line label for plan rows when the underlying StoreProduct has an
    /// active intro offer (intro discount or free trial). Primary is the
    /// intro price + period; secondary is the post-intro recurring price.
    private struct IntroPriceDisplay {
        let primary: String
        let secondary: String
        let savingsPercent: Int
    }

    /// Returns nil when the product has no `introductoryDiscount` (user is
    /// either ineligible or the product carries no intro at all). The plan
    /// row falls back to `priceText(for:)` in that case.
    ///
    /// ALSO returns nil for a FREE TRIAL, and that exclusion is load-bearing.
    /// A free trial has `intro.price == 0`, which scores exactly 100 in the
    /// savings arithmetic below — the source of the fabricated "100% OFF"
    /// badge, "$0.00 first week" row and "Special offer — 100%% off" hero.
    /// A free trial is `trialDisplay(for:)`'s responsibility EXCLUSIVELY; this
    /// helper presents genuine PAID intro offers only (`.payAsYouGo` /
    /// `.payUpFront`, e.g. the parked `discount_50` offering).
    ///
    /// Guarding here rather than at the call site is deliberate: `planRow` is
    /// not the only caller — `maxSavingsPercent` reaches this directly, and it
    /// drives the hero subtitle. One guard covers both.
    private func introDisplay(for product: StoreProduct) -> IntroPriceDisplay? {
        guard let intro = product.introductoryDiscount,
              intro.paymentMode != .freeTrial,
              let basePeriod = product.subscriptionPeriod
        else { return nil }
        let totalUnits = intro.subscriptionPeriod.value * intro.numberOfPeriods
        let primary = formatIntroPrimary(
            price: intro.localizedPriceString,
            unit: intro.subscriptionPeriod.unit,
            totalUnits: totalUnits
        )
        let secondary = formatIntroSecondary(
            price: product.localizedPriceString,
            unit: basePeriod.unit
        )
        let base = (product.price as NSDecimalNumber).doubleValue
        let disc = (intro.price as NSDecimalNumber).doubleValue
        let pct = base > 0 ? Int(((base - disc) / base) * 100) : 0
        return IntroPriceDisplay(primary: primary, secondary: secondary, savingsPercent: pct)
    }

    private func formatIntroPrimary(price: String, unit: SubscriptionPeriod.Unit, totalUnits: Int) -> String {
        if totalUnits == 1 {
            switch unit {
            case .day:   return String(localized: "paywall.intro.firstDay",   defaultValue: "\(price) first day",   comment: "Paywall plan row primary line shown when an intro discount lasts one day. %@ is the localized intro price.")
            case .week:  return String(localized: "paywall.intro.firstWeek",  defaultValue: "\(price) first week",  comment: "Paywall plan row primary line shown when an intro discount lasts one week. %@ is the localized intro price.")
            case .month: return String(localized: "paywall.intro.firstMonth", defaultValue: "\(price) first month", comment: "Paywall plan row primary line shown when an intro discount lasts one month. %@ is the localized intro price.")
            case .year:  return String(localized: "paywall.intro.firstYear",  defaultValue: "\(price) first year",  comment: "Paywall plan row primary line shown when an intro discount lasts one year. %@ is the localized intro price.")
            @unknown default: return price
            }
        }
        switch unit {
        case .day:   return String(localized: "paywall.intro.firstDays",   defaultValue: "\(price) for first \(totalUnits) days",   comment: "Paywall plan row primary line for a multi-day intro discount. %1$@ is the price; %2$lld is the day count.")
        case .week:  return String(localized: "paywall.intro.firstWeeks",  defaultValue: "\(price) for first \(totalUnits) weeks",  comment: "Paywall plan row primary line for a multi-week intro discount. %1$@ is the price; %2$lld is the week count.")
        case .month: return String(localized: "paywall.intro.firstMonths", defaultValue: "\(price) for first \(totalUnits) months", comment: "Paywall plan row primary line for a multi-month intro discount. %1$@ is the price; %2$lld is the month count.")
        case .year:  return String(localized: "paywall.intro.firstYears",  defaultValue: "\(price) for first \(totalUnits) years",  comment: "Paywall plan row primary line for a multi-year intro discount. %1$@ is the price; %2$lld is the year count.")
        @unknown default: return price
        }
    }

    private func formatIntroSecondary(price: String, unit: SubscriptionPeriod.Unit) -> String {
        switch unit {
        case .day:   return String(localized: "paywall.intro.thenPerDay",   defaultValue: "then \(price)/day",   comment: "Paywall plan row secondary line shown beneath an intro price, indicating the regular daily price after intro ends. %@ is the localized recurring price.")
        case .week:  return String(localized: "paywall.intro.thenPerWeek",  defaultValue: "then \(price)/week",  comment: "Paywall plan row secondary line shown beneath an intro price, indicating the regular weekly price after intro ends. %@ is the localized recurring price.")
        case .month: return String(localized: "paywall.intro.thenPerMonth", defaultValue: "then \(price)/month", comment: "Paywall plan row secondary line shown beneath an intro price, indicating the regular monthly price after intro ends. %@ is the localized recurring price.")
        case .year:  return String(localized: "paywall.intro.thenPerYear",  defaultValue: "then \(price)/year",  comment: "Paywall plan row secondary line shown beneath an intro price, indicating the regular annual price after intro ends. %@ is the localized recurring price.")
        @unknown default: return price
        }
    }

    // MARK: - Free-trial row presentation

    /// Row presentation for a product whose introductory offer is an actual
    /// FREE TRIAL (`paymentMode == .freeTrial`), as opposed to a paid
    /// introductory discount.
    ///
    /// Deliberately SEPARATE from `introDisplay(for:)` rather than a change to
    /// it. That helper drives the `discount_50` offering's rows and the hero
    /// subtitle's savings percentage, and a free trial lands in its percentage
    /// formula as a 100% discount — which is where the green "100% OFF" badge
    /// came from. Branching here leaves every non-trial presentation byte for
    /// byte identical.
    private struct TrialRowDisplay {
        /// Trial length, stated explicitly and derived from the offer period.
        /// This is the row's ONLY trial signal — a "FREE" pill next to the plan
        /// title used to sit beside it, but "Annual" + "FREE" + "Free for 7
        /// days" said "free" twice and read as though the yearly subscription
        /// itself were free.
        let duration: String
        /// Recurring price and term once the trial ends.
        let secondary: String
    }

    /// Returns nil unless the product carries a genuine free trial, so callers
    /// fall through to the existing intro/base-price presentation.
    private func trialDisplay(for product: StoreProduct) -> TrialRowDisplay? {
        // Same eligibility input as `showsTrialCopy`, so the row and the copy
        // can never disagree about whether a trial is on offer.
        guard isEligibleForTrial else { return nil }
        guard let intro = product.introductoryDiscount,
              intro.paymentMode == .freeTrial,
              let basePeriod = product.subscriptionPeriod
        else { return nil }

        let count = intro.subscriptionPeriod.value * intro.numberOfPeriods
        let duration: String
        switch intro.subscriptionPeriod.unit {
        case .day:
            duration = trialDurationInDays(count)
        case .week:
            // Converted to days on purpose. App Store Connect offers no "7
            // days" option — a seven-day trial is configured as 1 week — so
            // StoreKit reports `.week`, and the row used to read "first week".
            // Stating "7 days" is the point of this whole change: it is the
            // number a reviewer checks against the three-day minimum.
            duration = trialDurationInDays(count * 7)
        case .month:
            duration = trialDurationInMonths(count)
        case .year:
            duration = trialDurationInYears(count)
        @unknown default:
            return nil
        }

        return TrialRowDisplay(
            duration: duration,
            // Reuses the existing, already-localized secondary line so the
            // recurring price and term stay visible after the trial.
            secondary: formatIntroSecondary(
                price: product.localizedPriceString,
                unit: basePeriod.unit
            )
        )
    }

    private func trialDurationInDays(_ count: Int) -> String {
        String(
            localized: "paywall.v2.trial.freeForDays",
            defaultValue: "Free for \(count) days",
            comment: "Paywall plan row duration line for a free trial measured in days. %lld is the day count."
        )
    }

    private func trialDurationInMonths(_ count: Int) -> String {
        String(
            localized: "paywall.v2.trial.freeForMonths",
            defaultValue: "Free for \(count) months",
            comment: "Paywall plan row duration line for a free trial measured in months. %lld is the month count."
        )
    }

    private func trialDurationInYears(_ count: Int) -> String {
        String(
            localized: "paywall.v2.trial.freeForYears",
            defaultValue: "Free for \(count) years",
            comment: "Paywall plan row duration line for a free trial measured in years. %lld is the year count."
        )
    }

    // MARK: - Introductory-offer eligibility

    /// The single eligibility input consulted by BOTH trial decisions —
    /// `showsTrialCopy` (headline/subtitle/CTA, selection-scoped) and
    /// `trialDisplay(for:)` (the plan row, per-product). They are deliberately
    /// different conditions, but they share this value, so neither can present
    /// a trial the other hides.
    ///
    /// UNKNOWN FAILS TOWARD HIDING. Showing default copy to an eligible user
    /// understates the offer and the StoreKit sheet then over-delivers; showing
    /// trial copy to an ineligible user overstates it and the sheet contradicts
    /// it. Only one of those is a broken promise. `.noIntroOfferExists` lands
    /// here too — there is no trial to present.
    private var isEligibleForTrial: Bool {
        trialEligibility == .eligible
    }

    /// Resolves eligibility for the annual product.
    ///
    /// Apple grants one introductory offer per SUBSCRIPTION GROUP, and the
    /// trial and default annual SKUs share a group, so the annual answer is the
    /// group's answer — which is why one query gates every row.
    ///
    /// NO NETWORK CALL, but only for the CURRENT configuration: RevenueCat 5.x
    /// defaults to `StoreKitVersion.storeKit2`, and the app calls plain
    /// `Purchases.configure(withAPIKey:)` with no override, so this resolves via
    /// StoreKit 2's on-device `isEligibleForIntroOffer` against products the
    /// offerings fetch already cached. If RevenueCat is ever pinned to
    /// StoreKit 1, the SK1 path reads the local receipt and FALLS BACK TO A
    /// BACKEND CALL — at which point this becomes a network dependency on the
    /// paywall path. Do not assume it is unconditionally local.
    private func refreshTrialEligibility() async {
        // `Purchases.shared` fatal-errors when unconfigured, which is the case
        // in DEV builds. Today `annualPackage` is always nil there (DEV skips
        // `loadOfferings`), so the guard below would suffice — but relying on
        // that coincidence is how the next refactor crashes a debug build.
        guard Purchases.isConfigured else {
            trialEligibility = .unknown
            return
        }
        guard let product = annualPackage?.storeProduct else {
            // Offerings not loaded yet. Stay `.unknown`, which hides the trial.
            trialEligibility = .unknown
            return
        }
        // Prewarmed answer, resolved at launch by
        // `SubscriptionManager.prewarmPaywallData()`. On the common path it is
        // already here, so this view never issues a query and its first paint
        // is its settled paint.
        if let cached = manager.trialEligibility[product.productIdentifier] {
            trialEligibility = cached
            return
        }
        // FALLBACK — byte-identical to the pre-prewarm behaviour. Reached when
        // the prewarm failed, was `.skipped` for a subscriber who has since
        // lapsed, has not finished yet, or did not cover this product.
        trialEligibility = await Purchases.shared.checkTrialOrIntroDiscountEligibility(product: product)
    }

    /// Emits `paywall_shown` exactly once per presentation, from `onAppear`.
    ///
    /// Fires SYNCHRONOUSLY during appear so it always precedes any
    /// `paywall_dismissed` or purchase event from the same presentation. It is
    /// no longer deferred until the offering resolves: `trial_available` now
    /// comes from the launch-time prewarm cache, which is already populated on
    /// the common path, so waiting bought nothing and let the event land after
    /// dismissal.
    ///
    /// `trial_available` is THREE-VALUED, not a Bool. A cache miss — prewarm
    /// unfinished, failed, or `.skipped`, or the annual package not yet resolved
    /// — reports `"unknown"`, never `"not_eligible"`. The two are genuinely
    /// different: an eligible user whose prewarm has not landed sees trial copy
    /// moments later, once `refreshTrialEligibility()`'s live fallback resolves,
    /// so collapsing that case into a negative under-reported real eligibility
    /// and made the parameter unusable as a denominator.
    ///
    /// The values are deliberately not `"true"` / `"false"`: the parameter
    /// previously carried a Bool, and a string that reads like one would merge
    /// with that history in GA4 instead of showing up as a clean break.
    private func logPaywallShown() {
        guard !hasLoggedPaywallShown else { return }
        hasLoggedPaywallShown = true
        let trialAvailable: String = {
            guard let identifier = annualPackage?.storeProduct.productIdentifier else { return "unknown" }
            switch manager.trialEligibility[identifier] {
            case .eligible:                      return "eligible"
            case .ineligible, .noIntroOfferExists: return "not_eligible"
            // `.unknown` and a cache miss (`nil`) are the same statement: the
            // answer is not in yet.
            case .unknown, .none:                return "unknown"
            @unknown default:                    return "unknown"
            }
        }()
        AppAnalytics.log("paywall_shown", params: [
            "source": source,
            "trial_available": trialAvailable,
            "offering_id": resolvedOffering?.identifier ?? "default",
            "experiment_paywall_v1": ExperimentManager.shared.variant(for: .paywallV1)
        ])
        // MMP funnel event, same cadence as the log above.
        AppServices.attribution?.trackEvent("paywall_shown")
    }

    /// Highest intro savings percentage across the visible subscription
    /// packages (monthly + annual). Used by the hero subtitle and any
    /// other top-level "X% OFF" copy. Returns nil when no package has an
    /// active intro — in that case the subtitle should fall back to a
    /// non-percentage variant.
    private var maxSavingsPercent: Int? {
        let percents: [Int] = [monthlyPackage, annualPackage]
            .compactMap { $0?.storeProduct }
            .compactMap { introDisplay(for: $0)?.savingsPercent }
            .filter { $0 > 0 }
        return percents.max()
    }

    /// Hero headline copy. Trial variant when the selected plan carries a free
    /// trial; after a take of the user's own script, a line about that take;
    /// otherwise today's Remote-Config-driven default.
    private var heroHeadlineText: String {
        if showsTrialCopy { return PaywallConfig.trialHeadline }
        if pillPhrase != nil {
            return String(
                localized: "paywall.v3.headline.keepFilming",
                defaultValue: "Keep filming like this",
                comment: "Paywall headline shown right after the user's first take of their own script; the prompter pill above it shows that script."
            )
        }
        return PaywallConfig.headline
    }

    /// Hero subtitle copy. When at least one visible package has an
    /// intro discount, surface the actual saved percentage — Apple's
    /// regional StoreKit pricing tiers don't always produce the
    /// nominally-targeted percent. Falls back to a percent-free
    /// variant when no visible plan has an active intro (e.g. user
    /// already used the intro for this subscription group).
    ///
    /// Nil when there is no offer to state: the plans below already say
    /// what full access costs, so a generic line would only repeat the
    /// headline.
    private var heroSubtitleText: String? {
        // Trial copy substitutes the localized recurring price through the same
        // localized-format-string mechanism the percentage subtitle uses below
        // (`%@` here, `%lld` there). Never a hardcoded currency or amount.
        // Falls through to the existing logic if the catalog entry or the price
        // is unavailable.
        if showsTrialCopy,
           let template = PaywallConfig.trialSubtitleFormat,
           let price = package(for: selectedPlan)?.storeProduct.localizedPriceString {
            return String(format: template, price)
        }
        if let pct = maxSavingsPercent, pct >= 1 {
            // Template is a localized format string with a `%lld`
            // placeholder for the integer percent (and `%%` for the
            // literal percent sign). Resolved by `subtitleWithPct`
            // through Remote Config → catalog key → `NSLocalizedString`,
            // then formatted here against the runtime `pct` value.
            let template = PaywallConfig.subtitleWithPct
            return String(format: template, pct)
        }
        return nil
    }

    /// The plan's price and NOTHING ELSE — no period suffix.
    ///
    /// The period is now stated by `billingPeriodText(for:)` on the line
    /// directly beneath, so keeping "/ year" here would print the term twice
    /// ("$79.99 / year" over "billed annually"). Dropping the suffix also drops
    /// the four `paywall.v2.pricePer*` wrapper keys, which had no other caller.
    ///
    /// ⚠️ The literals are a LAST-RESORT fallback for the window before offerings
    /// load, and they are NOT the source of truth. Real prices come from StoreKit
    /// via `localizedPriceString`; these are US-dollar list prices shown only if
    /// that is unavailable, and they are neither localized nor currency-converted.
    /// App Store Connect is the only authority, and it is not readable from this
    /// repo — so THESE MUST BE UPDATED BY HAND whenever a price changes there, or
    /// the paywall will briefly show a price the user will not be charged.
    private func priceText(for plan: PaywallPlan) -> String {
        switch plan {
        case .weekly:   return weeklyPackage?.localizedPriceString ?? "$4.99"
        case .monthly:  return monthlyPackage?.localizedPriceString ?? "$13.99"
        case .annual:   return annualPackage?.localizedPriceString ?? "$79.99"
        case .lifetime: return lifetimePackage?.localizedPriceString ?? "$99.99"
        }
    }

    /// Billing cadence for the row's secondary line — the fallback when there is
    /// no trial and no intro offer, so EVERY row is two lines and their heights
    /// match.
    ///
    /// Derived from the plan, never from parsing the price string. Optional by
    /// contract: a plan without a key renders no secondary rather than a raw key
    /// name. The switch is exhaustive today, so nil is currently unreachable —
    /// adding a `PaywallPlan` case would fail to compile here, which is the
    /// louder failure and the one we want.
    private func billingPeriodText(for plan: PaywallPlan) -> String? {
        switch plan {
        case .annual:
            return String(
                localized: "paywall.v2.billing.annually",
                defaultValue: "billed annually",
                comment: "Paywall plan row secondary line stating the billing cadence of an annual subscription. Shown beneath the price when the plan has no free trial and no introductory offer."
            )
        case .monthly:
            return String(
                localized: "paywall.v2.billing.monthly",
                defaultValue: "billed monthly",
                comment: "Paywall plan row secondary line stating the billing cadence of a monthly subscription. Shown beneath the price when the plan has no free trial and no introductory offer."
            )
        case .weekly:
            return String(
                localized: "paywall.v2.billing.weekly",
                defaultValue: "billed weekly",
                comment: "Paywall plan row secondary line stating the billing cadence of a weekly subscription. Shown beneath the price when the plan has no free trial and no introductory offer."
            )
        case .lifetime:
            return String(
                localized: "paywall.v2.billing.oneTime",
                defaultValue: "one-time payment",
                comment: "Paywall plan row secondary line for the lifetime plan, which is a single purchase rather than a recurring subscription. Shown beneath the price."
            )
        }
    }

    // MARK: - Layout inputs

    /// Lowest `eyeContact` the chip states.
    static let eyeContactChipThreshold = 0.8

    /// The pill always shows the three-line reader, whatever the user picked
    /// for the camera: one word at a time says too little at a glance.
    private let isClassicMode = true

    /// Nil on every device but iPhone Duo.
    @Environment(DuoDisplayMonitor.self) private var duoMonitor: DuoDisplayMonitor?

    /// What the pill cycles: the start of the user's own script, else a line
    /// about the app.
    private var pillText: String {
        pillPhrase ?? String(
            localized: "paywall.v3.pillPhrase",
            defaultValue: "Read your script, film in one take and shine",
            comment: "Words cycled through the prompter pill at the top of the paywall, three at a time, one word per line, when the user has no script of their own yet. Keep it short and natural."
        )
    }

    private var eyeContactPercent: Int? {
        guard let eyeContact, eyeContact >= Self.eyeContactChipThreshold else { return nil }
        return Int((eyeContact * 100).rounded())
    }

    var body: some View {
        layout
            .background(backdrop)
            .statusBarHidden(true)
            .preferredColorScheme(.dark)
            .interactiveDismissDisabled(true)
            .alert(
                restoreSucceeded
                    ? String(
                        localized: "settings.restore.success.title",
                        defaultValue: "Subscription restored",
                        comment: "Title of the alert shown when Restore Purchases finds an active subscription on the user's Apple ID."
                    )
                    : String(
                        localized: "settings.restore.empty.title",
                        defaultValue: "No purchases found",
                        comment: "Title of the alert shown when Restore Purchases finds no active subscription on the user's Apple ID."
                    ),
                isPresented: $showRestoreAlert,
                presenting: restoreResultMessage
            ) { _ in
                Button("common.ok", role: .cancel) {
                    if restoreSucceeded {
                        // User is now Pro — dismissing the paywall drops them back
                        // into the app instead of leaving them stranded on a wall
                        // they no longer need.
                        //
                        // A restore onto an active entitlement ends the presentation
                        // in the same state a purchase does, so it reports
                        // `purchased=true` too. Set here rather than where
                        // `restoreSucceeded` is assigned: this alert's only control
                        // is this button, so a successful restore cannot reach
                        // dismissal by any other route.
                        didPurchase = true
                        dismiss()
                    }
                }
            } message: { message in
                Text(message)
            }
            .onAppear {
                selectedPlan = resolvedDefaultPlan
                // Offerings normally arrive from the launch-time prewarm. Load here
                // only if that did not produce them — a `.skipped` prewarm whose
                // subscriber lapsed mid-session, a failed prewarm, or a paywall
                // opened before it finished.
                if manager.offerings == nil {
                    Task { await manager.loadOfferings() }
                }
                // Stamp the shared "any paywall shown" timestamp on every appear,
                // regardless of source or build flavor. ContentView's cold-start
                // paywall trigger reads this same UserDefaults key to enforce its
                // 1-hour cross-source cooldown. Writing in DEV too so the cooldown
                // can be tested without flipping build configs.
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastAnyPaywallShownAt")
                // Every paywall — automatic or user-initiated — counts toward the
                // arbiter's gap and suppresses the review prompt for this session.
                // Automatic ones have already called `didPresent`; repeating the
                // note here is harmless.
                PromptArbiter.shared.noteExternalPresentation(isPaywall: true)
                logPaywallShown()
            }
            .onDisappear {
                PromptArbiter.shared.didDismiss()
            }
            // Re-runs whenever the annual product changes identity — including nil →
            // resolved when offerings finish loading, and on an offering swap after
            // a Remote Config activation. Fits the existing re-render pattern
            // (activationCount, selectedPlan) rather than adding new machinery, and
            // adds no offerings fetch of its own.
            .task(id: annualPackage?.storeProduct.productIdentifier) {
                await refreshTrialEligibility()
            }
            .onChange(of: remoteConfig.activationCount) { _, _ in
                // The body re-renders on its own (every PaywallConfig accessor
                // reads live), but `selectedPlan` is @State and survives the
                // re-render. If the newly activated `paywall_plans` no longer
                // contains it, the CTA would stay bound to a plan that is not on
                // screen — so re-clamp to the configured default.
                if !userDidPickPlan || !renderablePlans.contains(selectedPlan) {
                    selectedPlan = resolvedDefaultPlan
                }
            }
            // Offerings can land after `onAppear` already picked a selection from
            // the fallback plan list. Catch up to the configured default unless the
            // user has already chosen a plan themselves.
            .onChange(of: manager.offerings) { _, _ in
                if !userDidPickPlan {
                    selectedPlan = resolvedDefaultPlan
                }
            }
            .onDisappear {
                // A purchase in flight means this is NOT a dismissal: StoreKit's
                // payment sheet presenting over this `fullScreenCover` fires
                // `onDisappear` seconds before the purchase resolves. The flag is
                // set synchronously on the main actor before the store call, and
                // cleared the instant it returns — before the success path calls
                // `dismiss()` — so the real dismissal always logs.
                guard !isPurchaseInFlight else { return }
                guard !hasLoggedPaywallDismissed else { return }
                hasLoggedPaywallDismissed = true
                AppAnalytics.log("paywall_dismissed", params: [
                    "source": source,
                    "purchased": didPurchase
                ])
            }
    }

    // MARK: - Layouts

    /// iPhone: the pill hangs from the camera as it does when recording. Duo:
    /// it floats beside the close button, and the unfolded screen splits
    /// along the crease — what you get on one side, the plans on the other.
    /// Everywhere the plans and the button stay pinned to the bottom; only
    /// what is above them scrolls on a short screen.
    @ViewBuilder
    private var layout: some View {
        if let duo = duoMonitor?.state {
            if duo.posture == .unfolded, let crease = duo.creaseFrame {
                splitLayout(crease: crease)
            } else {
                coverScreenLayout(duo)
            }
        } else {
            cameraPillLayout
        }
    }

    private var cameraPillLayout: some View {
        GeometryReader { geo in
            let g = PrompterPillPreview.Layout(
                safeTop: geo.safeAreaInsets.top,
                screenWidth: geo.size.width,
                isClassicMode: isClassicMode,
                spacing: 28
            )
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    fillingScroll(topInset: g.contentTop) {
                        headline
                        featuresList
                            .padding(.top, 20)
                    }
                    purchaseBlock
                }
                PrompterPillPreview(
                    phrase: pillText,
                    isClassicMode: isClassicMode
                )
                .allowsHitTesting(false)
                closeButton(size: g.closeSize)
                    .padding(.leading, g.closeLeading)
                    .offset(y: g.closeTop)
            }
        }
    }

    private func splitLayout(crease: CGRect) -> some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let local = crease.offsetBy(dx: -origin.x, dy: -origin.y)
            let isSideBySide = local.height >= local.width
            let firstLength = max(0, isSideBySide ? local.minX : local.minY)
            let stack = isSideBySide
                ? AnyLayout(HStackLayout(spacing: local.width))
                : AnyLayout(VStackLayout(spacing: local.height))
            stack {
                fillingScroll(topInset: 8) {
                    floatingPillHeader
                    headline
                    Spacer(minLength: 20)
                    featuresList
                }
                .frame(
                    width: isSideBySide ? firstLength : nil,
                    height: isSideBySide ? nil : firstLength
                )
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(
                        localized: "paywall.v3.choosePlan",
                        defaultValue: "Choose your plan",
                        comment: "Title above the plan list on the plans half of the paywall on iPhone Duo's unfolded screen."
                    ))
                    .font(.title2.bold())
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    Spacer(minLength: 0)
                    purchaseBlock
                }
            }
        }
    }

    /// Duo folded: the pill sits on the lens in the top corner, as it does
    /// when recording, and the close button and headline take the space
    /// beside it. The side insets are dropped: they only keep clear of the
    /// status bar, which the paywall hides; the lens itself is covered by
    /// the black pill.
    private func coverScreenLayout(_ duo: DuoDisplayState) -> some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let lens = duo.lensFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            let lensOnRight = lens.midX > geo.size.width / 2
            let pillWidth = min(260, geo.size.width * 0.56)
            let pillTop = max(0, lens.minY - 12)
            let pillEdgeInset = max(8, lensOnRight ? geo.size.width - lens.maxX - 12 : lens.minX - 12)
            // The words sit beside the lens, as on the camera, not below it.
            let lensBand = lens.width + (lensOnRight ? geo.size.width - lens.maxX : lens.minX) - pillEdgeInset + 6
            let pill = FloatingPrompterPill(
                phrase: pillText,
                isClassicMode: isClassicMode,
                textTop: 10,
                lensSide: lensOnRight ? .trailing : .leading,
                lensBand: lensBand
            )
            .frame(width: pillWidth)
            // The headline's last line sits on the pill's bottom edge; the
            // close button takes the corner above it, clear of the edges.
            let side = headline(fontSize: 26)
                .padding(.top, 16 + 44 + 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 0) {
                fillingScroll(topInset: 0) {
                    HStack(alignment: .bottom, spacing: 12) {
                        if lensOnRight {
                            side
                            pill.padding(.top, pillTop).padding(.trailing, pillEdgeInset - 20)
                        } else {
                            pill.padding(.top, pillTop).padding(.leading, pillEdgeInset - 20)
                            side
                        }
                    }
                    .overlay(alignment: lensOnRight ? .topLeading : .topTrailing) {
                        closeButton(size: 42)
                            .padding(.top, 16)
                            .padding(lensOnRight ? .leading : .trailing, 4)
                    }
                    featuresList
                        .padding(.top, 20)
                }
                purchaseBlock
            }
        }
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    /// Duo: the close button and the pill share the top row, so the pill
    /// costs no extra height on the short cover screen.
    private var floatingPillHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            closeButton(size: 42)
                .padding(.leading, -8)
            FloatingPrompterPill(phrase: pillText, isClassicMode: isClassicMode)
                .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 20)
    }

    /// The plans and the button under them: pinned to the bottom, so prices
    /// and the button stay on screen however short it is; what is above
    /// them scrolls instead.
    private var purchaseBlock: some View {
        VStack(spacing: 12) {
            plansList
            checkout
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    /// Scrolls only when the content is taller than its space; otherwise
    /// fills it, so a `Spacer` inside pushes what follows to the bottom.
    private func fillingScroll<Content: View>(
        topInset: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let content = content()
        return GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, topInset)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Lit at the top like onboarding, so the black pill stands out.
    private var backdrop: some View {
        ZStack(alignment: .top) {
            Color.black
            LinearGradient(
                colors: [Color(white: 0.16), Color(red: 0.1, green: 0.04, blue: 0), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 360)
        }
        .ignoresSafeArea()
    }

    // MARK: - What you get

    /// The eye-contact chip when there is one, the headline, and the offer
    /// line when there is an offer.
    private var headline: some View { headline(fontSize: 32) }

    private func headline(fontSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let percent = eyeContactPercent {
                eyeContactChip(percent)
                    .padding(.bottom, 10)
            }
            Text(heroHeadlineText)
                .font(.system(size: fontSize, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = heroSubtitleText {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }

    private func eyeContactChip(_ percent: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .foregroundStyle(.green)
            Text(String(
                localized: "paywall.v3.eyeContactChip",
                defaultValue: "\(percent)% eye contact in your first take",
                comment: "Chip above the paywall headline after the user's first take of their own script. %lld is the share of the take they spent looking at the lens, as a whole percent."
            ))
            .foregroundStyle(.white.opacity(0.9))
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.green.opacity(0.14), in: Capsule())
    }

    private var featuresList: some View {
        VStack(alignment: .leading, spacing: 12) {
            featureLine(
                icon: "drop.fill",
                title: String(
                    localized: "paywall.v3.feature.noWatermark",
                    defaultValue: "No watermark.",
                    comment: "Paywall feature line, bold lead-in. Followed by its detail sentence on the same line."
                ),
                detail: String(
                    localized: "paywall.v3.feature.noWatermark.detail",
                    defaultValue: "Post takes as they are.",
                    comment: "Paywall feature line, detail after 'No watermark.'"
                )
            )
            featureLine(
                icon: "waveform",
                title: String(
                    localized: "paywall.v3.feature.studioSound",
                    defaultValue: "Studio sound.",
                    comment: "Paywall feature line, bold lead-in: Studio Sound, enhancement that removes noise and echo from the recording's audio. Followed by its detail sentence on the same line."
                ),
                detail: String(
                    localized: "paywall.v3.feature.studioSound.detail",
                    defaultValue: "Your voice without noise or echo.",
                    comment: "Paywall feature line, detail after 'Studio sound.'"
                )
            )
            featureLine(
                icon: "sparkles",
                title: String(
                    localized: "paywall.v3.feature.ai",
                    defaultValue: "AI scripts.",
                    comment: "Paywall feature line, bold lead-in: AI drafting and optimizing of scripts. Followed by its detail sentence on the same line."
                ),
                detail: String(
                    localized: "paywall.v3.feature.ai.detail",
                    defaultValue: "Draft and polish every video.",
                    comment: "Paywall feature line, detail after 'AI scripts.'"
                )
            )
            featureLine(
                icon: "video.fill",
                title: String(
                    localized: "paywall.v3.feature.quality",
                    defaultValue: "4K, stabilized.",
                    comment: "Paywall feature line, bold lead-in: 4K recording and video stabilization. Followed by its detail sentence on the same line."
                ),
                detail: String(
                    localized: "paywall.v3.feature.quality.detail",
                    defaultValue: "Sharp and steady on the move.",
                    comment: "Paywall feature line, detail after '4K, stabilized.'"
                )
            )
        }
    }

    private func featureLine(icon: String, title: String, detail: String) -> some View {
        var lead = AttributedString(title)
        lead.font = .body.weight(.semibold)
        lead.foregroundColor = .white
        var rest = AttributedString(" " + detail)
        rest.font = .body
        rest.foregroundColor = Color(.secondaryLabel)
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(lead + rest)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Restore Purchases

    private func restoreTapped() {
        Task {
            isRestoring = true
            defer { isRestoring = false }
            let restored = await SubscriptionManager.shared.restorePurchases()
            restoreSucceeded = restored
            restoreResultMessage = restored
                ? String(
                    localized: "settings.restore.success.message",
                    defaultValue: "Welcome back! Your subscription has been restored.",
                    comment: "Body of the alert shown when Restore Purchases succeeds."
                )
                : String(
                    localized: "settings.restore.empty.message",
                    defaultValue: "Couldn't find an active subscription on your Apple ID.",
                    comment: "Body of the alert shown when Restore Purchases finds no entitlement."
                )
            showRestoreAlert = true
        }
    }

    /// Same path as the former inline Dismiss link: `dismiss()`, with
    /// `paywall_dismissed` logged from `onDisappear`. Sized and placed like
    /// the camera's close button, which sits in the same spot.
    private func closeButton(size: CGFloat) -> some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.14), in: Circle())
                .frame(width: max(size, 44), height: max(size, 44))
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(
            localized: "paywall.v2.dismissA11y",
            defaultValue: "Dismiss paywall and continue with free tier",
            comment: "VoiceOver label for the inline Dismiss link on the paywall."
        ))
    }

    // MARK: - Plans and checkout

    /// Universal CTA copy sourced from Remote Config. Previously
    /// branched to "Start free trial" for annual; that branch was
    /// removed when discount_50 became the default. The label is now
    /// the same for every plan and lives in `paywall_cta_label` so
    /// marketing can A/B test wording without an app update. Default
    /// `"Continue"` matches the previous hardcoded copy.
    private var continueButtonLabel: String {
        showsTrialCopy ? PaywallConfig.trialCtaLabel : PaywallConfig.ctaLabel
    }

    /// Every configured plan, always on screen: nothing cheaper hides behind
    /// a toggle.
    private var plansList: some View {
        VStack(spacing: 8) {
            ForEach(renderablePlans) { plan in
                planRow(plan: plan)
            }
        }
    }

    private var checkout: some View {
        VStack(spacing: 10) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
            }

            Button(action: { purchase(selectedPlan) }) {
                // Opacity swap, not if/else, so the button keeps the label's
                // size while the spinner shows (same as the editor's Optimize).
                ZStack {
                    Text(continueButtonLabel)
                        .opacity(isTransactionInFlight ? 0 : 1)
                    ProgressView()
                        .tint(Theme.onAccent)
                        .opacity(isTransactionInFlight ? 1 : 0)
                }
                .frame(maxWidth: .infinity)
            }
            .primaryButtonStyle()
            .disabled(isTransactionInFlight)

            // What the plan charges and the small links, packed tight under
            // the button: they are reference, not choices.
            VStack(spacing: 0) {
                Text(footnoteText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                legalLinks
            }
        }
    }

    private var legalLinks: some View {
        HStack(spacing: 6) {
            Button(action: restoreTapped) {
                ZStack {
                    Text(String(
                        localized: "paywall.v3.restore",
                        defaultValue: "Restore",
                        comment: "Short link at the bottom of the paywall that restores purchases made on this Apple ID."
                    ))
                    .opacity(isRestoring ? 0 : 1)
                    ProgressView()
                        .controlSize(.mini)
                        .opacity(isRestoring ? 1 : 0)
                }
            }
            .disabled(isTransactionInFlight)
            Text(verbatim: "·")
            Link(destination: URL(string: "https://bazilier.github.io/steadyeye-legal/terms.html")!) {
                Text("common.termsOfUse", comment: "Terms of use link in Settings")
            }
            Text(verbatim: "·")
            Link(destination: URL(string: "https://bazilier.github.io/steadyeye-legal/privacy.html")!) {
                Text("common.privacyPolicy", comment: "Privacy policy link in Settings")
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, minHeight: 28)
    }

    /// What the selected plan will charge, under the button.
    private var footnoteText: String {
        let product = package(for: selectedPlan)?.storeProduct
        if product.flatMap({ trialDisplay(for: $0) }) != nil {
            return String(
                localized: "paywall.v3.footnote.trial",
                defaultValue: "Nothing to pay today. Cancel anytime.",
                comment: "Line under the paywall button when the selected plan starts with a free trial."
            )
        }
        if product.flatMap({ introDisplay(for: $0) }) != nil {
            // The plan row states the discounted first period and the price
            // after it; repeating only the regular price here would misstate
            // the first charge.
            return String(
                localized: "paywall.v3.footnote.cancelAnytime",
                defaultValue: "Cancel anytime.",
                comment: "Line under the paywall button when the selected plan starts with a paid introductory price."
            )
        }
        let price = priceText(for: selectedPlan)
        switch selectedPlan {
        case .annual:
            return String(
                localized: "paywall.v3.footnote.yearly",
                defaultValue: "Billed \(price) a year. Cancel anytime.",
                comment: "Line under the paywall button for the annual plan. %@ is the localized yearly price."
            )
        case .monthly:
            return String(
                localized: "paywall.v3.footnote.monthly",
                defaultValue: "Billed \(price) a month. Cancel anytime.",
                comment: "Line under the paywall button for the monthly plan. %@ is the localized monthly price."
            )
        case .weekly:
            return String(
                localized: "paywall.v3.footnote.weekly",
                defaultValue: "Billed \(price) a week. Cancel anytime.",
                comment: "Line under the paywall button for the weekly plan. %@ is the localized weekly price."
            )
        case .lifetime:
            return String(
                localized: "paywall.v3.footnote.lifetime",
                defaultValue: "One payment. No subscription.",
                comment: "Line under the paywall button for the lifetime plan, a single purchase."
            )
        }
    }

    // MARK: - Savings from the store's prices

    /// What a subscription plan costs over a year at its regular price, from
    /// the store's actual product. Nil for lifetime and before offerings load.
    private func annualizedPrice(for plan: PaywallPlan) -> Double? {
        guard plan != .lifetime,
              let product = package(for: plan)?.storeProduct,
              let period = product.subscriptionPeriod,
              period.value > 0
        else { return nil }
        let perYear: Double
        switch period.unit {
        case .day: perYear = 365
        case .week: perYear = 52
        case .month: perYear = 12
        case .year: perYear = 1
        @unknown default: return nil
        }
        return (product.price as NSDecimalNumber).doubleValue * perYear / Double(period.value)
    }

    /// The subscription plan on screen that costs least over a year, and how
    /// much it saves against the dearest one at the same prices. Nil unless
    /// two subscription plans are on screen and the saving is at least 10%.
    private var bestValue: (plan: PaywallPlan, percent: Int)? {
        let priced = renderablePlans.compactMap { plan in
            annualizedPrice(for: plan).map { (plan: plan, yearly: $0) }
        }
        guard priced.count >= 2,
              let dearest = priced.map(\.yearly).max(), dearest > 0,
              let cheapest = priced.min(by: { $0.yearly < $1.yearly })
        else { return nil }
        let percent = Int(((dearest - cheapest.yearly) / dearest * 100).rounded(.down))
        return percent >= 10 ? (cheapest.plan, percent) : nil
    }

    /// The row's line under the plan name: the price per week (when weekly is
    /// on screen) or per month, for plans billed less often, so they compare
    /// with the shortest plan; else the billing cadence.
    private func planDetail(for plan: PaywallPlan) -> String? {
        let product = package(for: plan)?.storeProduct
        let comparesWeekly = renderablePlans.contains(.weekly)
        switch plan {
        case .annual:
            if comparesWeekly, let perWeek = product?.localizedPricePerWeek {
                return String(
                    localized: "paywall.v3.perWeekBilledYearly",
                    defaultValue: "\(perWeek) a week, billed yearly",
                    comment: "Paywall annual plan row, under the plan name. %@ is the localized yearly price divided per week."
                )
            }
            if let perMonth = product?.localizedPricePerMonth {
                return String(
                    localized: "paywall.v3.perMonthBilledYearly",
                    defaultValue: "\(perMonth) a month, billed yearly",
                    comment: "Paywall annual plan row, under the plan name. %@ is the localized yearly price divided per month."
                )
            }
        case .monthly:
            if comparesWeekly, let perWeek = product?.localizedPricePerWeek {
                return String(
                    localized: "paywall.v3.perWeekBilledMonthly",
                    defaultValue: "\(perWeek) a week, billed monthly",
                    comment: "Paywall monthly plan row, under the plan name. %@ is the localized monthly price divided per week."
                )
            }
        case .weekly, .lifetime:
            break
        }
        return billingPeriodText(for: plan).map { text in
            text.prefix(1).uppercased() + text.dropFirst()
        }
    }

    private func planRow(plan: PaywallPlan) -> some View {
        let pkg = package(for: plan)
        // A genuine free trial takes precedence and suppresses the intro-discount
        // presentation entirely — otherwise its zero price scores 100% in
        // `savingsPercent` and renders as a "100% OFF" sale badge.
        let trial = pkg.flatMap { trialDisplay(for: $0.storeProduct) }
        let intro = trial == nil ? pkg.flatMap { introDisplay(for: $0.storeProduct) } : nil
        let displayPrice = trial?.duration ?? intro?.primary ?? priceText(for: plan)
        let isSelected = selectedPlan == plan
        let badge: (text: String, color: Color)? = {
            if let intro, intro.savingsPercent >= 30 {
                return (String(
                    localized: "paywall.intro.savingsBadge",
                    defaultValue: "\(intro.savingsPercent)% OFF",
                    comment: "Compact badge displayed next to a paywall plan title when the active intro discount saves the user 30% or more on the first period. %lld is the integer percent saved (e.g. 50)."
                ), .green)
            }
            if let best = bestValue, best.plan == plan {
                return (String(
                    localized: "paywall.v3.saveBadge",
                    defaultValue: "Save \(best.percent)%",
                    comment: "Badge next to the paywall plan that costs least over a year. %lld is the whole percent it saves against the dearest subscription plan on screen, from store prices. Shown in capitals."
                ), Theme.accent)
            }
            return nil
        }()
        return Button(action: {
            userDidPickPlan = true
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedPlan = plan
            }
        }) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Theme.accent : Color(white: 0.39), lineWidth: 2)
                    Circle()
                        .fill(Theme.accent)
                        .padding(6)
                        .opacity(isSelected ? 1 : 0)
                }
                .frame(width: 22, height: 22)

                // A trial or intro row states its terms on the right in two
                // lines, so its left side has no detail line, and the badge
                // takes that line instead of squeezing in beside the name.
                let detail = (trial == nil && intro == nil) ? planDetail(for: plan) : nil
                let badgeView = badge.map { badge in
                    Text(badge.text)
                        .textCase(.uppercase)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(badge.color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(plan.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                        if detail != nil { badgeView }
                    }
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        badgeView
                    }
                }
                // Takes the width it needs before the spacer splits the rest,
                // so the detail line stays on one line.
                .layoutPriority(1)

                Spacer(minLength: 8)

                // The value and the line qualifying it ("then $79.99/year")
                // stack on the RIGHT, next to the value they refer to.
                VStack(alignment: .trailing, spacing: 2) {
                    Text(displayPrice)
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let secondary = trial?.secondary ?? intro?.secondary {
                        Text(secondary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                // Trailing alignment for wrapped lines, and ideal-height sizing
                // so long strings at large Dynamic Type WRAP instead of
                // truncating — a truncated price is worse than a tall row.
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.12) : Color(white: 0.11))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isTransactionInFlight)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Purchase action

    private func purchase(_ plan: PaywallPlan) {
        // Re-entrancy guard, FIRST statement: a second tap while a purchase is
        // already locked does nothing at all — no store call, no events, not
        // even `purchase_initiated`. Enforced here rather than by disabling the
        // CTA so every present and future caller of this method is covered by
        // one authoritative check.
        guard !isPurchaseLocked else { return }
        guard let pkg = package(for: plan) else {
            // RC offerings haven't loaded yet (DEV mode short-circuits, network
            // failure, or RC config error). No in-app fallback — the user can
            // tap again once the offerings load via .onAppear's loadOfferings
            // task — but the tap is reported, because an unreported one makes
            // the user look like they never tried.
            //
            // Deliberately NOT `purchase_initiated`: no purchase started, and
            // emitting it here would depress the initiated→succeeded ratio with
            // attempts that never reached the store.
            AppAnalytics.log("purchase_unavailable", params: [
                "plan": plan.rawValue,
                "source": source
            ])
            return
        }
        errorMessage = nil
        let planName = plan.rawValue
        // Raised here, synchronously, rather than as the Task's first statement:
        // the store call cannot begin before this line has run, so there is no
        // scheduling order in which the payment sheet's `onDisappear` beats it.
        isPurchaseInFlight = true
        // Same synchronous main-actor write, but this one outlives the store
        // call — see the property's own comment.
        isPurchaseLocked = true
        AppAnalytics.log("purchase_initiated", params: [
            "plan": planName,
            "source": source
        ])
        Task {
            let outcome = await manager.purchase(pkg)
            // Cleared before the switch, so every outcome — including the
            // success path's `dismiss()` below — sees a settled purchase.
            isPurchaseInFlight = false
            switch outcome {
            case .succeeded(let isTrial):
                AppAnalytics.log("purchase_succeeded", params: [
                    "plan": planName,
                    "source": source,
                    "was_trial": isTrial
                ])
                let purchasedProduct = pkg.storeProduct
                // The offering is switched remotely between plain products and
                // products carrying a free-trial introductory offer, so this
                // branch — not a build flag — is what keeps both modes correct.
                //
                // `isTrial` is RevenueCat's `periodType == .trial` for the
                // entitlement this purchase produced. Note `.intro` (a PAID
                // introductory price) is deliberately NOT a trial and takes the
                // revenue path below.
                if isTrial {
                    // Free trial started: no money has changed hands, so NO
                    // revenue event fires here — neither GA4 `purchase` nor
                    // `af_purchase`. Reporting revenue now would make every
                    // trial start look like income and would over-report every
                    // trial that later cancels.
                    //
                    // The trial→paid conversion is not observable reliably on
                    // the client (it needs the user to reopen the app after
                    // renewal); it will be reported server-side from RevenueCat
                    // webhooks in a separate task. Until that lands, a converted
                    // trial produces no purchase event anywhere.
                    AppAnalytics.log("trial_started", params: [
                        "plan": planName,
                        "source": source
                    ])
                    // NO MMP trial event here. RevenueCat's own AppsFlyer
                    // integration delivers `rc_trial_started` server-side for
                    // every trial, and the client-side `af_start_trial` that
                    // used to fire on this line was a duplicate of it — an
                    // unreliable one. Over four organic trials the server-side
                    // event fired exactly once each time while the client-side
                    // one fired 0, 1, 1 and 2 times. The client path also
                    // structurally cannot see a trial that starts by restore,
                    // offer-code redemption, Ask to Buy, a network error after
                    // Apple completed the transaction, or app termination
                    // during the StoreKit sheet — all of which the server sees.
                } else {
                    // Money received. Report the product's full recurring price
                    // rather than the first-period amount, so a paid
                    // introductory offer does not depress the bidding signal.
                    let recurringPrice = (purchasedProduct.price as NSDecimalNumber).doubleValue
                    // Bound once and shared by both destinations below, so the
                    // GA4 purchase event and the MMP revenue event can never
                    // report different amounts or currencies for the same
                    // transaction.
                    let purchaseCurrency = purchasedProduct.currencyCode ?? "USD"
                    AppAnalytics.log(AnalyticsEventPurchase, params: [
                        AnalyticsParameterValue: recurringPrice,
                        AnalyticsParameterCurrency: purchaseCurrency
                    ])
                    // MMP revenue event, from the identical values.
                    //
                    // SUSPECTED DUPLICATE, deliberately kept. RevenueCat's
                    // AppsFlyer integration is configured to send `af_purchase`
                    // server-side for an initial purchase, which would make this
                    // the same duplication `af_start_trial` had. Unlike that one
                    // the server-side counterpart has NOT yet been observed in
                    // AppsFlyer raw data, so removing this now risks losing the
                    // event outright. Confirm in raw data first, then drop
                    // whichever side is redundant.
                    AppServices.attribution?.trackPurchase(
                        revenue: recurringPrice,
                        currency: purchaseCurrency,
                        productId: purchasedProduct.productIdentifier
                    )
                }
                // Set before `dismiss()` so the `onDisappear` this triggers
                // reports the purchase rather than re-reading subscription state
                // that may not have propagated yet.
                didPurchase = true
                onPurchaseSuccess?()
                dismiss()
            case .userCancelled:
                // Released here, not in a `defer`: the presentation stays on
                // screen after a cancel, so the CTA must be live again for the
                // retry. The success case above deliberately keeps the lock.
                isPurchaseLocked = false
                AppAnalytics.log("purchase_cancelled_by_user", params: [
                    "plan": planName,
                    "source": source
                ])
            case .failed(let reason):
                isPurchaseLocked = false
                AppAnalytics.log("purchase_failed", params: [
                    "plan": planName,
                    "source": source,
                    "error_reason": reason
                ])
                errorMessage = String(
                    localized: "paywall.error.purchaseFailed",
                    defaultValue: "Purchase failed. Please try again.",
                    comment: "Error when a RevenueCat purchase attempt fails."
                )
            }
        }
    }
}
