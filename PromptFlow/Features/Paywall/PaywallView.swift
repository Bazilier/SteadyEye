import SwiftUI

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = SubscriptionManager.shared

    @State private var selectedPlan: Plan = .annual
    @State private var isPurchasing = false
    @State private var errorMessage: String?

    enum Plan { case monthly, annual, lifetime }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    // Header
                    VStack(spacing: 8) {
                        Text("SteadyEye Premium")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                        Text("Unlock everything")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.top, 20)

                    // Features
                    featureList

                    // Plan cards
                    VStack(spacing: 12) {
                        planCard(
                            plan: .annual,
                            title: "Annual",
                            price: "$49.99/year",
                            detail: "$4.17/month",
                            badge: "BEST VALUE",
                            trial: "7-day free trial"
                        )
                        planCard(
                            plan: .monthly,
                            title: "Monthly",
                            price: "$6.99/month",
                            detail: nil,
                            badge: nil,
                            trial: nil
                        )
                        planCard(
                            plan: .lifetime,
                            title: "Lifetime",
                            price: "$99.99",
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
                        purchase()
                    } label: {
                        HStack {
                            if isPurchasing {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(buttonLabel)
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isPurchasing)
                    .padding(.horizontal, 20)

                    // Restore
                    Button("Restore Purchases") {
                        restore()
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
                        Text("Subscriptions auto-renew unless cancelled 24 hours before the end of the current period.")
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Feature list

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            featureRow("Word-by-word teleprompter")
            featureRow("Classic scroll mode")
            featureRow("AI script optimization")
            featureRow("Bulk script import")
            featureRow("4K recording")
            featureRow("Unlimited scripts")
            featureRow("No watermark")
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
        plan: Plan,
        title: String,
        price: String,
        detail: String?,
        badge: String?,
        trial: String?
    ) -> some View {
        let isSelected = selectedPlan == plan

        return Button {
            selectedPlan = plan
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.white)
                        if let badge {
                            Text(badge)
                                .font(.caption2.bold())
                                .foregroundStyle(.black)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.orange, in: Capsule())
                        }
                    }
                    Text(price)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    if let trial {
                        Text(trial)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? .orange : .white.opacity(0.3))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? .orange : .white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Button label

    private var buttonLabel: String {
        switch selectedPlan {
        case .annual: return "Start Free Trial"
        case .monthly: return "Subscribe"
        case .lifetime: return "Buy"
        }
    }

    // MARK: - Actions

    private func purchase() {
        isPurchasing = true
        errorMessage = nil
        Task {
            do {
                switch selectedPlan {
                case .monthly: try await manager.purchaseMonthly()
                case .annual: try await manager.purchaseAnnual()
                case .lifetime: try await manager.purchaseLifetime()
                }
                dismiss()
            } catch {
                errorMessage = "Purchase failed. Please try again."
            }
            isPurchasing = false
        }
    }

    private func restore() {
        isPurchasing = true
        errorMessage = nil
        Task {
            do {
                try await manager.restorePurchases()
                if manager.isSubscribed {
                    dismiss()
                } else {
                    errorMessage = "No active subscription found."
                }
            } catch {
                errorMessage = "Restore failed. Please try again."
            }
            isPurchasing = false
        }
    }
}
