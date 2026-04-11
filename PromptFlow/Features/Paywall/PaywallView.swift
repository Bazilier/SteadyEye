import SwiftUI
import RevenueCat

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = SubscriptionManager.shared

    @State private var selectedPlan: Plan = .annual
    @State private var errorMessage: String?

    enum Plan { case monthly, annual, lifetime }

    // MARK: - Packages from offerings

    private var annualPackage: Package? { manager.offerings?.current?.annual }
    private var monthlyPackage: Package? { manager.offerings?.current?.monthly }
    private var lifetimePackage: Package? { manager.offerings?.current?.lifetime }

    private var selectedPackage: Package? {
        switch selectedPlan {
        case .annual: return annualPackage
        case .monthly: return monthlyPackage
        case .lifetime: return lifetimePackage
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header — pinned above scroll
                VStack(spacing: 8) {
                    Text("paywall.title", comment: "Paywall header title — 'SteadyEye' brand name must not be translated")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                    Text("paywall.subtitle", comment: "Paywall header subtitle — marketing tagline")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 20)
                .padding(.bottom, 20)

                ScrollView {
                VStack(spacing: 28) {
                    // Features
                    featureList

                    // Plan cards
                    VStack(spacing: 12) {
                        planCard(
                            plan: .annual,
                            title: String(localized: "paywall.plan.annual", defaultValue: "Annual", comment: "Annual plan card title"),
                            price: String(
                                localized: "paywall.price.perYear",
                                // Fallback "$49.99" only — shown if RC offerings fail to load. Intentionally not localized.
                                defaultValue: "\(annualPackage?.localizedPriceString ?? "$49.99")/year",
                                comment: "Annual plan card price label. %@ is the localized RC price."
                            ),
                            detail: monthlyEquivalent,
                            badge: String(localized: "paywall.plan.bestValueBadge", defaultValue: "BEST VALUE", comment: "Annual plan badge"),
                            trial: trialText
                        )
                        planCard(
                            plan: .monthly,
                            title: String(localized: "paywall.plan.monthly", defaultValue: "Monthly", comment: "Monthly plan card title"),
                            price: String(
                                localized: "paywall.price.perMonth",
                                // Fallback "$6.99" only — shown if RC offerings fail to load. Intentionally not localized.
                                defaultValue: "\(monthlyPackage?.localizedPriceString ?? "$6.99")/month",
                                comment: "Monthly plan card price label. %@ is the localized RC price."
                            ),
                            detail: nil,
                            badge: nil,
                            trial: nil
                        )
                        planCard(
                            plan: .lifetime,
                            title: String(localized: "paywall.plan.lifetime", defaultValue: "Lifetime", comment: "Lifetime plan card title"),
                            // Fallback only — shown if RC offerings fail to load. Intentionally not localized.
                            price: lifetimePackage?.localizedPriceString ?? "$99.99",
                            detail: String(localized: "paywall.plan.lifetime.detail", defaultValue: "Pay once, own forever", comment: "Subtitle under the lifetime plan title"),
                            badge: nil,
                            trial: nil
                        )
                    }
                    .padding(.horizontal, 20)

                    // Error
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    // Subscribe button
                    Button {
                        purchaseSelected()
                    } label: {
                        HStack {
                            if manager.isLoading {
                                ProgressView().tint(.white)
                            }
                            Text(buttonLabel)
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(manager.isLoading)
                    .padding(.horizontal, 20)

                    // Restore
                    Button {
                        restorePurchases()
                    } label: {
                        Text("paywall.restore", comment: "Restore Purchases button on the paywall")
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))

                    // Legal
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Link(destination: URL(string: "https://bazilier.github.io/steadyeye-legal/privacy.html")!) {
                                Text("common.privacyPolicy", comment: "Privacy policy link on paywall")
                            }
                            Text(verbatim: "•")
                            Link(destination: URL(string: "https://bazilier.github.io/steadyeye-legal/terms.html")!) {
                                Text("common.termsOfUse", comment: "Terms of use link on paywall")
                            }
                        }
                        .foregroundStyle(.white.opacity(0.4))
                        Text(legalTrialAndPriceText)
                        Text("paywall.legal.autoRenew", comment: "Apple-required auto-renew disclosure")
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            } // ScrollView
            } // VStack
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            selectedPlan = .annual
            Task { await manager.loadOfferings() }
        }
    }

    // MARK: - Computed helpers

    private var monthlyEquivalent: String? {
        guard let annual = annualPackage else {
            // Fallback only — shown if RC offerings fail to load. Intentionally not localized.
            return "$4.17/month"
        }
        let monthlyValue = (annual.storeProduct.price as Decimal) / 12
        // Use the StoreProduct's own NumberFormatter so the currency symbol and
        // decimal style match the user's App Store region (not the device locale).
        let formattedAmount: String
        if let formatter = annual.storeProduct.priceFormatter,
           let amount = formatter.string(from: monthlyValue as NSDecimalNumber) {
            formattedAmount = amount
        } else {
            formattedAmount = "\(NSDecimalNumber(decimal: monthlyValue).doubleValue)"
        }
        return String(
            localized: "paywall.monthlyEquivalent",
            defaultValue: "\(formattedAmount)/month",
            comment: "Small monthly-equivalent label under the annual plan price. %@ is the localized currency amount."
        )
    }

    private var trialText: String {
        String(localized: "paywall.trialText", defaultValue: "7-day free trial", comment: "Trial label on the annual plan card")
    }

    /// Legal disclosure under the subscribe button. Substitutes the formatted
    /// "$XX/year" label (already produced via `paywall.price.perYear`) into the
    /// format key `paywall.legal.trialAndPrice`, so RC-loaded and fallback paths
    /// produce identical structure: "7-day free trial, then [price]/year. Cancel anytime."
    private var legalTrialAndPriceText: String {
        let pricePerYear = String(
            localized: "paywall.price.perYear",
            // Fallback "$49.99" only — shown if RC offerings fail to load. Intentionally not localized.
            defaultValue: "\(annualPackage?.localizedPriceString ?? "$49.99")/year",
            comment: "Annual price with /year suffix, reused inside the legal disclosure."
        )
        return String(
            localized: "paywall.legal.trialAndPrice",
            defaultValue: "7-day free trial, then \(pricePerYear). Cancel anytime.",
            comment: "Legal disclosure under the subscribe button. %@ is the full annual price label including the /year suffix (e.g. '$49.99/year', 'R$ 249,90/ano')."
        )
    }

    private var buttonLabel: String {
        switch selectedPlan {
        case .annual:
            return String(localized: "paywall.button.startTrial", defaultValue: "Start Free Trial", comment: "Subscribe button when annual plan is selected")
        case .monthly:
            return String(localized: "paywall.button.subscribe", defaultValue: "Subscribe", comment: "Subscribe button when monthly plan is selected")
        case .lifetime:
            return String(localized: "paywall.button.buyLifetime", defaultValue: "Buy Lifetime", comment: "Subscribe button when lifetime plan is selected")
        }
    }

    // MARK: - Feature list

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            featureRow(Text("paywall.feature.wbw", comment: "Paywall feature row"))
            featureRow(Text("paywall.feature.threeLine", comment: "Paywall feature row"))
            featureRow(Text("paywall.feature.aiOptimization", comment: "Paywall feature row"))
            featureRow(Text("paywall.feature.bulkImport", comment: "Paywall feature row"))
            featureRow(Text("paywall.feature.fourK", comment: "Paywall feature row"))
            featureRow(Text("paywall.feature.unlimited", comment: "Paywall feature row"))
            featureRow(Text("paywall.feature.externalMic", comment: "Paywall feature row"))
        }
        .padding(.horizontal, 32)
    }

    private func featureRow(_ text: Text) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.orange)
            text
                .font(.subheadline)
                .foregroundStyle(.white)
        }
    }

    // MARK: - Plan cards

    private func planCard(
        plan: Plan, title: String, price: String,
        detail: String?, badge: String?, trial: String?
    ) -> some View {
        let isSelected = selectedPlan == plan

        return Button { selectedPlan = plan } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.headline).foregroundStyle(.white)
                        if let badge {
                            Text(badge)
                                .font(.caption2.bold())
                                .foregroundStyle(.black)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.orange, in: Capsule())
                        }
                    }
                    Text(price).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                    if let trial {
                        Text(trial).font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? .orange : .white.opacity(0.3))
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? .orange : .white.opacity(0.1), lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func purchaseSelected() {
        guard let pkg = selectedPackage else {
            errorMessage = String(
                localized: "paywall.error.noPlan",
                defaultValue: "Please select a plan",
                comment: "Defensive error if subscribe is tapped without a selected plan"
            )
            return
        }
        errorMessage = nil
        Task {
            let success = await manager.purchase(pkg)
            if success {
                dismiss()
            } else {
                errorMessage = String(
                    localized: "paywall.error.purchaseFailed",
                    defaultValue: "Purchase failed. Please try again.",
                    comment: "Error when a RevenueCat purchase attempt fails"
                )
            }
        }
    }

    private func restorePurchases() {
        errorMessage = nil
        Task {
            let success = await manager.restorePurchases()
            if success {
                dismiss()
            } else {
                errorMessage = String(
                    localized: "paywall.error.noSubscription",
                    defaultValue: "No active subscription found.",
                    comment: "Error when Restore Purchases finds nothing to restore"
                )
            }
        }
    }
}
