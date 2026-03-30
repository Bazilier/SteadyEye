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
                    Text("Unlock SteadyEye")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                    Text("Record with perfect eye contact")
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
                            title: "Annual",
                            price: annualPackage?.localizedPriceString ?? "$49.99/year",
                            detail: monthlyEquivalent,
                            badge: "BEST VALUE",
                            trial: trialText
                        )
                        planCard(
                            plan: .monthly,
                            title: "Monthly",
                            price: monthlyPackage?.localizedPriceString ?? "$6.99/month",
                            detail: nil,
                            badge: nil,
                            trial: nil
                        )
                        planCard(
                            plan: .lifetime,
                            title: "Lifetime",
                            price: lifetimePackage?.localizedPriceString ?? "$99.99",
                            detail: "Pay once, own forever",
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
                    Button("Restore Purchases") {
                        restorePurchases()
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))

                    // Legal
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Link("Privacy Policy", destination: URL(string: "https://bazilier.github.io/steadyeye-legal/privacy.html")!)
                            Text("•")
                            Link("Terms of Use", destination: URL(string: "https://bazilier.github.io/steadyeye-legal/terms.html")!)
                        }
                        .foregroundStyle(.white.opacity(0.4))
                        Text("7-day free trial, then $49.99/year. Cancel anytime.")
                        Text("Subscriptions auto-renew unless cancelled 24 hours before the end of the current period.")
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
        guard let annual = annualPackage else { return "$4.17/month" }
        let monthlyPrice = NSDecimalNumber(decimal: annual.storeProduct.price as Decimal / 12).doubleValue
        return String(format: "$%.2f/month", monthlyPrice)
    }

    private var trialText: String { "7-day free trial" }

    private var buttonLabel: String {
        switch selectedPlan {
        case .annual: return "Start Free Trial"
        case .monthly: return "Subscribe"
        case .lifetime: return "Buy Lifetime"
        }
    }

    // MARK: - Feature list

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            featureRow("Word-by-word teleprompter")
            featureRow("3-line reading mode")
            featureRow("AI script optimization")
            featureRow("Bulk script import")
            featureRow("4K recording")
            featureRow("Unlimited scripts")
            featureRow("External mic support")
        }
        .padding(.horizontal, 32)
    }

    private func featureRow(_ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.orange)
            Text(text)
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
            errorMessage = "Please select a plan"
            return
        }
        errorMessage = nil
        Task {
            let success = await manager.purchase(pkg)
            if success { dismiss() }
            else { errorMessage = "Purchase failed. Please try again." }
        }
    }

    private func restorePurchases() {
        errorMessage = nil
        Task {
            let success = await manager.restorePurchases()
            if success { dismiss() }
            else { errorMessage = "No active subscription found." }
        }
    }
}
