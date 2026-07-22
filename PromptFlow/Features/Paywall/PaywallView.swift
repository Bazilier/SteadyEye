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

    @State private var selectedPlan: PaywallPlan = PaywallConfig.defaultPlan
    @State private var errorMessage: String?
    @State private var bottomSheetHeight: CGFloat = 320
    @State private var isExpanded: Bool = false
    @State private var isRestoring: Bool = false
    @State private var restoreResultMessage: String? = nil
    @State private var restoreSucceeded: Bool = false
    @State private var showRestoreAlert: Bool = false

    // MARK: - Packages from offerings

    private var resolvedOffering: Offering? {
        // Explicit caller override wins over both Remote Config and
        // the experiment assignment (used by A/B test landing pages,
        // future winback campaigns, etc.).
        if let explicit = offeringId { return manager.offering(for: explicit) }

        // Experiment override: users in `paywall_v1 == "trial"` see
        // the legacy `default` offering (7-day trial flow). All other
        // variants — including the seeded `"control"` default — fall
        // through to whatever `paywall_offering_id` dictates (currently
        // `discount_50`). Variant assignment is sticky per install
        // and gets logged to GA4 via the `paywall_shown` event below.
        let variant = ExperimentManager.shared.variant(for: .paywallV1)
        let chosenId: String = (variant == "trial") ? "default" : PaywallConfig.offeringId
        return manager.offering(for: chosenId) ?? manager.offering(for: nil)
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
    private func introDisplay(for product: StoreProduct) -> IntroPriceDisplay? {
        guard let intro = product.introductoryDiscount,
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

    /// Hero subtitle copy. When at least one visible package has an
    /// intro discount, surface the actual saved percentage — Apple's
    /// regional StoreKit pricing tiers don't always produce the
    /// nominally-targeted percent. Falls back to a percent-free
    /// variant when no visible plan has an active intro (e.g. user
    /// already used the intro for this subscription group).
    private var heroSubtitleText: String {
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

    private func priceText(for plan: PaywallPlan) -> String {
        switch plan {
        case .weekly:
            let raw = weeklyPackage?.localizedPriceString ?? "$2.99"
            return String(
                localized: "paywall.v2.pricePerWeek",
                defaultValue: "\(raw) / week",
                comment: "Paywall v2 weekly plan price label. %@ is the localized currency amount."
            )
        case .monthly:
            let raw = monthlyPackage?.localizedPriceString ?? "$6.99"
            return String(
                localized: "paywall.v2.pricePerMonth",
                defaultValue: "\(raw) / month",
                comment: "Paywall v2 monthly plan price label. %@ is the localized currency amount."
            )
        case .annual:
            let raw = annualPackage?.localizedPriceString ?? "$49.99"
            return String(
                localized: "paywall.v2.pricePerYear",
                defaultValue: "\(raw) / year",
                comment: "Paywall v2 annual plan price label. %@ is the localized currency amount."
            )
        case .lifetime:
            let raw = lifetimePackage?.localizedPriceString ?? "$99.99"
            return String(
                localized: "paywall.v2.priceLifetime",
                defaultValue: "\(raw) one-time",
                comment: "Paywall v2 lifetime plan price label. %@ is the localized currency amount."
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
            Task { await manager.loadOfferings() }
            // Stamp the shared "any paywall shown" timestamp on every appear,
            // regardless of source or build flavor. ContentView's cold-start
            // paywall trigger reads this same UserDefaults key to enforce its
            // 1-hour cross-source cooldown. Writing in DEV too so the cooldown
            // can be tested without flipping build configs.
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastAnyPaywallShownAt")
            let trialAvailable = resolvedOffering?.annual?.storeProduct.introductoryDiscount != nil
            AppAnalytics.log("paywall_shown", params: [
                "source": source,
                "trial_available": trialAvailable,
                "offering_id": resolvedOffering?.identifier ?? "default",
                "experiment_paywall_v1": ExperimentManager.shared.variant(for: .paywallV1)
            ])
            // MMP conversion-value event, same cadence as the log above.
            AppServices.attribution?.trackEvent("paywall_shown")
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
            Text(PaywallConfig.headline)
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
        PaywallConfig.ctaLabel
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
        let intro = pkg.flatMap { introDisplay(for: $0.storeProduct) }
        let basePrice = priceText(for: plan)
        let displayPrice = intro?.primary ?? basePrice
        let isSelected = selectedPlan == plan
        return Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedPlan = plan
            }
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(plan.title)
                            .font(.body)
                            .bold()
                            .foregroundColor(.white)
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
                    if let intro {
                        Text(intro.secondary)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Text(displayPrice)
                    .font(.body)
                    .foregroundColor(.white)
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
                // Standard Firebase purchase event for Google App Campaign
                // conversion tracking (fires alongside the custom event above,
                // on every successful purchase / plan). The value is the
                // EFFECTIVE first-period amount charged: the intro/disc50 price
                // when an intro offer applied to this purchase — using the same
                // `introductoryDiscount` signal the paywall uses to display
                // price — otherwise the base price. Read dynamically so it stays
                // correct whether disc50 is on or off; never a hardcoded price.
                let purchasedProduct = pkg.storeProduct
                let firstPeriodPrice = ((purchasedProduct.introductoryDiscount?.price
                    ?? purchasedProduct.price) as NSDecimalNumber).doubleValue
                AppAnalytics.log(AnalyticsEventPurchase, params: [
                    AnalyticsParameterValue: firstPeriodPrice,
                    AnalyticsParameterCurrency: purchasedProduct.currencyCode ?? "USD"
                ])
                // MMP conversion-value event carrying the first-period amount so
                // Tenjin buckets it into the right revenue range. Valued custom
                // event only — no revenue transaction, so it does not
                // double-count RC's server-side purchase forwarding.
                AppServices.attribution?.trackEvent("purchase", value: Int(firstPeriodPrice.rounded()))
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
