import SwiftUI
import RevenueCat

enum PaywallPlan: String, CaseIterable, Identifiable {
    case monthly, annual, lifetime
    var id: String { rawValue }

    var title: String {
        switch self {
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
    /// packages resolve from the named offering directly, bypassing
    /// OfferEngine. When `nil` (default for all current call sites),
    /// OfferEngine decides which offering to use based on user state
    /// (active discount window, etc.), falling back to `offerings.current`
    /// if no offer is active.
    var offeringId: String? = nil
    var onPurchaseSuccess: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = SubscriptionManager.shared

    @State private var selectedPlan: PaywallPlan = .annual
    @State private var errorMessage: String?
    @State private var bottomSheetHeight: CGFloat = 320
    @State private var isExpanded: Bool = false
    @State private var isRestoring: Bool = false
    @State private var restoreResultMessage: String? = nil
    @State private var restoreSucceeded: Bool = false
    @State private var showRestoreAlert: Bool = false
    /// Explicit synchronous marker that a purchase succeeded inside this
    /// PaywallView's lifetime. Used by `.onDisappear` to gate OfferEngine's
    /// dismiss-without-purchase signal — `SubscriptionManager.isSubscribed`
    /// can lag the dismiss by one runloop tick because RC's
    /// customerInfoStream is async, which would otherwise let
    /// `paywallDismissedWithoutPurchase` fire for a user who just bought.
    @State private var didPurchaseSuccessfully: Bool = false

    // MARK: - Packages from offerings

    private var resolvedOffering: Offering? {
        // Explicit override wins. Otherwise consult OfferEngine, which
        // returns a non-nil offering id only when an offer is active
        // for this user (e.g. discount_50 window). When OfferEngine
        // returns nil, `manager.offering(for: nil)` falls back to
        // `offerings.current` — matching pre-Phase-3 behavior.
        if let explicit = offeringId {
            return manager.offering(for: explicit)
        }
        let engineId = OfferEngine.shared.resolveOfferingId(source: source)
        return manager.offering(for: engineId)
    }
    private var annualPackage: Package? { resolvedOffering?.annual }
    private var monthlyPackage: Package? { resolvedOffering?.monthly }
    private var lifetimePackage: Package? { resolvedOffering?.lifetime }

    private func package(for plan: PaywallPlan) -> Package? {
        switch plan {
        case .monthly: return monthlyPackage
        case .annual: return annualPackage
        case .lifetime: return lifetimePackage
        }
    }

    private func priceText(for plan: PaywallPlan) -> String {
        switch plan {
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
            selectedPlan = .annual
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
                "trial_available": trialAvailable
            ])
        }
        .onDisappear {
            AppAnalytics.log("paywall_dismissed", params: [
                "source": source,
                "purchased": SubscriptionManager.shared.isSubscribed
            ])
            // Notify OfferEngine on dismiss-without-purchase so it can
            // start the discount window on first dismiss. Skip when the
            // user just purchased — `purchaseCompleted` handles that.
            // Reads the local `didPurchaseSuccessfully` flag rather than
            // `manager.isSubscribed` because the latter lags by one runloop
            // tick (customerInfoStream is async), which would otherwise
            // false-fire `offer_started` for a converted user.
            if !didPurchaseSuccessfully {
                OfferEngine.shared.paywallDismissedWithoutPurchase(source: source)
            }
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
            Text(String(
                localized: "paywall.v2.headline",
                defaultValue: "Get full access now",
                comment: "Paywall v2 hero headline. Marketing copy — translate naturally for each locale."
            ))
                .font(.largeTitle.weight(.bold))
                .foregroundColor(.orange)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)

            Text(String(
                localized: "paywall.v2.subheadline",
                defaultValue: "Start trial for free",
                comment: "Paywall v2 hero subheadline shown directly under the SteadyEye headline."
            ))
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

    /// CTA copy switches to "Start free trial" when annual is selected
    /// (the trial-eligible plan) and falls back to "Continue" for monthly /
    /// lifetime. SwiftUI re-renders the button automatically when
    /// `selectedPlan` changes — no onChange handler needed.
    private var continueButtonLabel: String {
        if selectedPlan == .annual {
            return String(
                localized: "paywall.v2.startFreeTrial",
                defaultValue: "Start free trial",
                comment: "Paywall v2 CTA label shown when annual plan is selected (trial-eligible)."
            )
        } else {
            return String(
                localized: "paywall.v2.continueButton",
                defaultValue: "Continue",
                comment: "Paywall v2 CTA label shown when monthly or lifetime plan is selected."
            )
        }
    }

    private var bottomSheet: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                if isExpanded {
                    planRow(plan: .monthly)
                    planRow(plan: .annual)
                    planRow(plan: .lifetime)
                } else {
                    planRow(plan: .annual)
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
                        selectedPlan = .annual
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
        let price = priceText(for: plan)
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
                        if plan == .annual {
                            Text(String(
                                localized: "paywall.v2.bestValue",
                                defaultValue: "Best Value",
                                comment: "Paywall v2 static badge marking the recommended plan. Shown on the annual row regardless of which plan is currently selected."
                            ))
                                .font(.caption2).bold()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange)
                                .foregroundColor(.black)
                                .clipShape(Capsule())
                        }
                    }
                    if plan == .annual {
                        Text(String(
                            localized: "paywall.v2.collapsed.trialCaption",
                            defaultValue: "7 days free, then \(price)",
                            comment: "Caption on the annual row reminding users of the free-trial offer. %@ is the localized annual price including period suffix (e.g. '$49.99 / year'). Apple's StoreKit sheet handles actual eligibility — this string is shown unconditionally."
                        ))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Text(price)
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
                didPurchaseSuccessfully = true
                onPurchaseSuccess?()
                dismiss()
            case .userCancelled:
                AppAnalytics.log("purchase_failed", params: [
                    "plan": planName,
                    "source": source,
                    "error_reason": "user_cancelled"
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
