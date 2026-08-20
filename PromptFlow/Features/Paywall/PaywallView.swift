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

struct PaywallView: View {
    let source: String
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
    @State private var errorMessage: String?
    @State private var bottomSheetHeight: CGFloat = 320
    @State private var isExpanded: Bool = false
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
    /// A cache miss — prewarm unfinished, failed, or `.skipped` — logs `false`,
    /// which is the accurate answer at that instant: with no `.eligible` entry
    /// the paywall cannot present a trial, because `isEligibleForTrial` is not
    /// satisfied either.
    private func logPaywallShown() {
        guard !hasLoggedPaywallShown else { return }
        hasLoggedPaywallShown = true
        let trialAvailable: Bool = {
            guard let identifier = annualPackage?.storeProduct.productIdentifier else { return false }
            return manager.trialEligibility[identifier] == .eligible
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
    /// trial; otherwise today's Remote-Config-driven default.
    private var heroHeadlineText: String {
        showsTrialCopy ? PaywallConfig.trialHeadline : PaywallConfig.headline
    }

    /// Hero subtitle copy. When at least one visible package has an
    /// intro discount, surface the actual saved percentage — Apple's
    /// regional StoreKit pricing tiers don't always produce the
    /// nominally-targeted percent. Falls back to a percent-free
    /// variant when no visible plan has an active intro (e.g. user
    /// already used the intro for this subscription group).
    private var heroSubtitleText: String {
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
        return PaywallConfig.subtitleNoPct
    }

    /// The plan's price and NOTHING ELSE — no period suffix.
    ///
    /// The period is now stated by `billingPeriodText(for:)` on the line
    /// directly beneath, so keeping "/ year" here would print the term twice
    /// ("$79.99 / year" over "billed annually"). Dropping the suffix also drops
    /// the four `paywall.v2.pricePer*` wrapper keys, which had no other caller.
    ///
    /// ⚠️ The literals are LAST-RESORT fallbacks for the window before offerings
    /// load — they are not the source of truth and are known to be stale (annual
    /// is really $79.99, not $49.99). Real prices come from StoreKit via
    /// `localizedPriceString`; these are deliberately left at their existing
    /// values rather than guessed at, because App Store Connect is the only
    /// authority and it is not readable from this repo.
    private func priceText(for plan: PaywallPlan) -> String {
        switch plan {
        case .weekly:   return weeklyPackage?.localizedPriceString ?? "$2.99"
        case .monthly:  return monthlyPackage?.localizedPriceString ?? "$6.99"
        case .annual:   return annualPackage?.localizedPriceString ?? "$49.99"
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

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            scrollContent
            bottomSheet
        }
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
                    dismiss()
                }
            }
        } message: { message in
            Text(message)
        }
        .onPreferenceChange(BottomSheetHeightKey.self) { newHeight in
            bottomSheetHeight = newHeight
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
            logPaywallShown()
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
            if !renderablePlans.contains(selectedPlan) {
                selectedPlan = resolvedDefaultPlan
            }
        }
        .onDisappear {
            AppAnalytics.log("paywall_dismissed", params: [
                "source": source,
                "purchased": SubscriptionManager.shared.isSubscribed
            ])
        }
    }

    // MARK: - Scrollable hero content

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 28) {
                heroSection
                featuresList
                restoreRow
                dismissGroup
                Spacer().frame(height: bottomSheetHeight + 24)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Soft warm-orange glow behind the hero. Anchored to the ScrollView's
        // frame (not the inner content) so the glow stays fixed at the top of
        // the screen as the user scrolls. `.ignoresSafeArea()` on the gradient
        // itself pushes it under the status bar; the bottom sheet sits above
        // this layer in the parent ZStack so its material is unaffected.
        .background(
            RadialGradient(
                colors: [
                    Color.orange.opacity(0.18),
                    Color.orange.opacity(0.06),
                    Color.clear
                ],
                center: .top,
                startRadius: 40,
                endRadius: 380
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - Restore Purchases entry point (top of paywall)

    /// "Already subscribed? Restore" row. Sits inside the padded scrollContent
    /// VStack alongside the dismiss group, in the secondary-actions zone below
    /// the feature list. Reuses the same SubscriptionManager.restorePurchases()
    /// and localized result strings as the Settings → Subscription Restore
    /// Purchases button — no key duplication. On success, dismisses the
    /// paywall (user is now Pro).
    private var restoreRow: some View {
        HStack(spacing: 6) {
            Text(String(
                localized: "paywall.restore.prompt",
                defaultValue: "Already subscribed?",
                comment: "Caption preceding the inline Restore link at the bottom of the paywall, above the Dismiss link."
            ))
                .foregroundColor(.secondary)
            if isRestoring {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(action: { restoreTapped() }) {
                    Text(String(
                        localized: "settings.restore.button",
                        defaultValue: "Restore Purchases",
                        comment: "Settings button that triggers RevenueCat restorePurchases against the active Apple ID. Required by App Store review and used by users installing on a new device."
                    ))
                        .underline()
                        .foregroundColor(.primary)
                }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

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

    private var heroSection: some View {
        VStack(spacing: 12) {
            Text(heroHeadlineText)
                .font(.largeTitle.weight(.bold))
                .foregroundColor(.orange)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)

            Text(heroSubtitleText)
                .font(.title2)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Features list

    private var featuresList: some View {
        VStack(alignment: .leading, spacing: 28) {
            featureRow(
                icon: "drop.fill",
                title: String(
                    localized: "paywall.v2.feature.noWatermark",
                    defaultValue: "No watermark on recordings",
                    comment: "Paywall v2 feature row title."
                ),
                subtitle: String(
                    localized: "paywall.v2.feature.noWatermark.subtitle",
                    defaultValue: "Share videos without 'Made with SteadyEye'",
                    comment: "Paywall v2 feature row subtitle for the no-watermark feature."
                )
            )
            featureRow(
                icon: "text.alignleft",
                title: String(
                    localized: "paywall.v2.feature.unlimitedLength",
                    defaultValue: "Long-form scripts",
                    comment: "Paywall v2 feature row title."
                ),
                subtitle: String(
                    localized: "paywall.v2.feature.unlimitedLength.subtitle",
                    defaultValue: "Up to 5,000 characters per script",
                    comment: "Paywall v2 feature row subtitle for the long-form-scripts feature. The 5,000-character limit is the actual product cap for paying users — keep the number verbatim, localize the surrounding phrasing."
                )
            )
            featureRow(
                icon: "sparkles",
                title: String(
                    localized: "paywall.v2.feature.unlimitedAI",
                    defaultValue: "AI optimization for every script",
                    comment: "Paywall v2 feature row title for the AI optimization feature."
                ),
                subtitle: String(
                    localized: "paywall.v2.feature.unlimitedAI.subtitle",
                    defaultValue: "Optimize every script you write",
                    comment: "Paywall v2 feature row subtitle for the AI optimization feature."
                )
            )
            featureRow(
                icon: "4k.tv",
                title: String(
                    localized: "paywall.v2.feature.fourK",
                    defaultValue: "4K recording",
                    comment: "Paywall v2 feature row title. '4K' is a technical resolution label."
                ),
                subtitle: String(
                    localized: "paywall.v2.feature.fourK.subtitle",
                    defaultValue: "Cinematic quality for important shoots",
                    comment: "Paywall v2 feature row subtitle for the 4K recording feature."
                )
            )
            featureRow(
                icon: "hand.raised.fill",
                title: String(
                    localized: "paywall.v2.feature.stabilization",
                    defaultValue: "Steadicam stabilization",
                    comment: "Paywall v2 feature row title for the video stabilization feature."
                ),
                subtitle: String(
                    localized: "paywall.v2.feature.stabilization.subtitle",
                    defaultValue: "Smooth video while moving or walking",
                    comment: "Paywall v2 feature row subtitle for the video stabilization feature."
                )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 48)
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .foregroundColor(.orange)
                    .font(.system(size: 18, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Carousel (parked 2026-04-30 — see PaywallFeatureCard.swift)
    //
    // Reverted to static featuresList. Re-enable by swapping `featuresList`
    // → `featuresCarousel` in scrollContent. Card component lives in
    // PaywallFeatureCard.swift. Keep the watermark icon here in sync with
    // the row in featuresList (currently `drop.fill`).

    @State private var selectedFeatureIndex: Int? = 0

    private struct Feature {
        let icon: String
        let title: String
        let subtitle: String
    }

    private var features: [Feature] {
        [
            Feature(
                icon: "drop.fill",
                title: String(localized: "paywall.v2.feature.noWatermark", defaultValue: "No watermark on recordings", comment: "Paywall v2 feature card title."),
                subtitle: String(localized: "paywall.v2.feature.noWatermark.subtitle", defaultValue: "Share videos without 'Made with SteadyEye'", comment: "Paywall v2 feature card subtitle.")
            ),
            Feature(
                icon: "text.alignleft",
                title: String(localized: "paywall.v2.feature.unlimitedLength", defaultValue: "Long-form scripts", comment: "Paywall v2 feature card title."),
                subtitle: String(localized: "paywall.v2.feature.unlimitedLength.subtitle", defaultValue: "Up to 5,000 characters per script", comment: "Paywall v2 feature card subtitle.")
            ),
            Feature(
                icon: "sparkles",
                title: String(localized: "paywall.v2.feature.unlimitedAI", defaultValue: "AI optimization for every script", comment: "Paywall v2 feature card title."),
                subtitle: String(localized: "paywall.v2.feature.unlimitedAI.subtitle", defaultValue: "Optimize every script you write", comment: "Paywall v2 feature card subtitle.")
            ),
            Feature(
                icon: "4k.tv",
                title: String(localized: "paywall.v2.feature.fourK", defaultValue: "4K recording", comment: "Paywall v2 feature card title."),
                subtitle: String(localized: "paywall.v2.feature.fourK.subtitle", defaultValue: "Cinematic quality for important shoots", comment: "Paywall v2 feature card subtitle.")
            ),
            Feature(
                icon: "hand.raised.fill",
                title: String(localized: "paywall.v2.feature.stabilization", defaultValue: "Steadicam stabilization", comment: "Paywall v2 feature card title."),
                subtitle: String(localized: "paywall.v2.feature.stabilization.subtitle", defaultValue: "Smooth video while moving or walking", comment: "Paywall v2 feature card subtitle.")
            )
        ]
    }

    private var featuresCarousel: some View {
        VStack(spacing: 16) {
            GeometryReader { geo in
                let cardWidth = geo.size.width - 80   // 40pt peek per side
                let sidePadding = (geo.size.width - cardWidth) / 2

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(Array(features.enumerated()), id: \.offset) { index, feature in
                            PaywallFeatureCard(
                                icon: feature.icon,
                                title: feature.title,
                                subtitle: feature.subtitle
                            )
                            .frame(width: cardWidth)
                            .id(index)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, sidePadding)
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $selectedFeatureIndex)
            }
            .frame(height: 300)

            // Custom dot indicator (TabView's built-in dots are not used here
            // because the .page tabViewStyle can't produce the peek effect).
            HStack(spacing: 8) {
                ForEach(0..<features.count, id: \.self) { index in
                    Circle()
                        .fill(selectedFeatureIndex == index ? Color.white : Color.white.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
        }
    }

    private var dismissGroup: some View {
        VStack(spacing: 4) {
            Text(String(
                localized: "paywall.v2.notInterested",
                defaultValue: "Not interested?",
                comment: "Caption above the inline Dismiss link on the paywall."
            ))
                .font(.body)
                .foregroundColor(.secondary)
            Button {
                dismiss()
            } label: {
                Text(String(
                    localized: "paywall.v2.dismiss",
                    defaultValue: "Dismiss",
                    comment: "Inline link that dismisses the paywall and returns the user to the free tier."
                ))
                    .font(.body.weight(.semibold))
                    .foregroundColor(.primary)
                    .underline()
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(String(
                localized: "paywall.v2.dismissA11y",
                defaultValue: "Dismiss paywall and continue with free tier",
                comment: "VoiceOver label for the inline Dismiss link on the paywall."
            ))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Sticky bottom sheet

    /// Universal CTA copy sourced from Remote Config. Previously
    /// branched to "Start free trial" for annual; that branch was
    /// removed when discount_50 became the default. The label is now
    /// the same for every plan and lives in `paywall_cta_label` so
    /// marketing can A/B test wording without an app update. Default
    /// `"Continue"` matches the previous hardcoded copy.
    private var continueButtonLabel: String {
        showsTrialCopy ? PaywallConfig.trialCtaLabel : PaywallConfig.ctaLabel
    }

    private var bottomSheet: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                if isExpanded {
                    ForEach(renderablePlans) { plan in
                        planRow(plan: plan)
                    }
                } else {
                    planRow(plan: resolvedDefaultPlan)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
            }

            Button(action: { purchase(selectedPlan) }) {
                Text(continueButtonLabel)
                    .font(.body).bold()
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color.orange)
                    .cornerRadius(12)
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    if isExpanded {
                        selectedPlan = resolvedDefaultPlan
                    }
                    isExpanded.toggle()
                }
            } label: {
                Text(isExpanded
                    ? String(
                        localized: "paywall.v2.showLess",
                        defaultValue: "Show Less",
                        comment: "Paywall v2 collapse-link below the Continue button when the plan-list is expanded."
                    )
                    : String(
                        localized: "paywall.v2.allPlans",
                        defaultValue: "All Plans",
                        comment: "Paywall v2 expand-link below the Continue button when the collapsed annual card is shown."
                    ))
                    .font(.body)
                    .foregroundStyle(.white)
                    .underline()
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(Rectangle())
            }
        }
        .padding(20)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: BottomSheetHeightKey.self, value: geo.size.height)
            }
        }
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 24,
                style: .continuous
            )
            .fill(.ultraThinMaterial)
            .ignoresSafeArea(edges: .bottom)
            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: -4)
        )
    }

    private func planRow(plan: PaywallPlan) -> some View {
        let pkg = package(for: plan)
        // A genuine free trial takes precedence and suppresses the intro-discount
        // presentation entirely — otherwise its zero price scores 100% in
        // `savingsPercent` and renders as a "100% OFF" sale badge.
        let trial = pkg.flatMap { trialDisplay(for: $0.storeProduct) }
        let intro = trial == nil ? pkg.flatMap { introDisplay(for: $0.storeProduct) } : nil
        let basePrice = priceText(for: plan)
        let displayPrice = trial?.duration ?? intro?.primary ?? basePrice
        let isSelected = selectedPlan == plan
        return Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedPlan = plan
            }
        }) {
            HStack {
                HStack(spacing: 8) {
                    Text(plan.title)
                        .font(.body)
                        .bold()
                        .foregroundColor(.white)
                    // Trial rows carry no badge: the duration text on the
                    // right already says "Free for 7 days". The HStack stays
                    // because the DISCOUNT badge below still needs it, and a
                    // title-only row is not a new layout state — it is what
                    // already rendered whenever neither badge applied.
                    if let intro, intro.savingsPercent >= 30 {
                        Text(String(
                            localized: "paywall.intro.savingsBadge",
                            defaultValue: "\(intro.savingsPercent)% OFF",
                            comment: "Compact badge displayed next to a paywall plan title when the active intro discount saves the user 30% or more on the first period. %lld is the integer percent saved (e.g. 50)."
                        ))
                            .font(.caption2).bold()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green)
                            .foregroundColor(.black)
                            .clipShape(Capsule())
                    }
                }
                Spacer()
                // The value and the line qualifying it stack on the RIGHT.
                // The secondary used to sit under the plan TITLE, on the far
                // side of the row from the value it refers to, so the left
                // column read "Annual" / "then $79.99/year" — as though the
                // yearly price followed the plan name rather than the trial.
                // Applies to both presentations: the discount case is the same
                // sentence ("$X first year" / "then $79.99/year"), so the two
                // layouts must not diverge.
                //
                // `spacing: 4` is the rhythm the left column already used for
                // exactly this pairing — no new constant.
                VStack(alignment: .trailing, spacing: 4) {
                    Text(displayPrice)
                        .font(.body)
                        .foregroundColor(.white)
                    // Omitted entirely rather than rendered empty, so a row with
                    // no intro collapses to a single line at exactly its
                    // previous height.
                    // Priority: trial "then …" > intro "then …" > billing
                    // cadence. The third arm is what makes the line present on
                    // every row, so no row is a line shorter than its neighbours.
                    if let secondary = trial?.secondary
                        ?? intro?.secondary
                        ?? billingPeriodText(for: plan) {
                        Text(secondary)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                // Trailing alignment for wrapped lines, and ideal-height sizing
                // so long strings at large Dynamic Type WRAP instead of
                // truncating — a truncated price is worse than a tall row.
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.orange.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isSelected ? Color.orange : Color.gray.opacity(0.3),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Purchase action

    private func purchase(_ plan: PaywallPlan) {
        guard let pkg = package(for: plan) else {
            // RC offerings haven't loaded yet (DEV mode short-circuits, network
            // failure, or RC config error). Silent no-op — there is no
            // reasonable in-app fallback. The user can tap again once the
            // offerings load via .onAppear's loadOfferings task.
            return
        }
        errorMessage = nil
        let planName = plan.rawValue
        AppAnalytics.log("purchase_initiated", params: [
            "plan": planName,
            "source": source
        ])
        Task {
            let outcome = await manager.purchase(pkg)
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
                    // MMP trial event. Carries no revenue by construction: the
                    // provider's `trackEvent` seam has no revenue parameter.
                    AppServices.attribution?.trackEvent("trial_started")
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
                    AppServices.attribution?.trackPurchase(
                        revenue: recurringPrice,
                        currency: purchaseCurrency,
                        productId: purchasedProduct.productIdentifier
                    )
                }
                onPurchaseSuccess?()
                dismiss()
            case .userCancelled:
                AppAnalytics.log("purchase_cancelled_by_user", params: [
                    "plan": planName,
                    "source": source
                ])
            case .failed(let reason):
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

// MARK: - Preference key for measuring bottom sheet height

private struct BottomSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 320
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
