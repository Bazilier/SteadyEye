import SwiftUI

/// Satisfaction pre-prompt shown after the first Camera Roll save of a
/// recording made from a user-written script.
///
/// Yes routes to the App Store review page, No opens the founder chat — so
/// the App Store only ever hears from people who already said they were
/// happy, and everyone else reaches a person instead of a rating field.
/// Structure deliberately mirrors `SoftAskNotificationView`, the house
/// pattern for a two-button app-styled prompt.
///
/// Arbiter wiring lives at the call site (`VideoPreviewView`), not here.
struct SatisfactionPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onYes: () -> Void
    let onNo: () -> Void

    /// Drives the one-shot pulse of the badge star. Never animates under
    /// Reduce Motion — see `pulseStarOnce()`.
    @State private var starScale: CGFloat = 1

    /// A fixed-height detent cannot grow with its content, so it has to clear
    /// the tallest layout it will ever hold. Same ladder as the soft-ask:
    /// identical icon block, body width and two-button stack.
    private var detentHeight: CGFloat {
        if dynamicTypeSize >= .accessibility1 { return 620 }
        if dynamicTypeSize >= .xxLarge { return 520 }
        return 420
    }

    var body: some View {
        VStack(spacing: 0) {
            iconBlock

            Text("review.satisfaction.title")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 24)

            Text("review.satisfaction.body")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                // Narrower than the sheet so lines break evenly instead of
                // running edge to edge.
                .frame(maxWidth: 300)
                .padding(.top, 10)

            Spacer(minLength: 32)

            VStack(spacing: 12) {
                Button {
                    AppAnalytics.log("satisfaction_prompt_yes")
                    onYes()
                    dismiss()
                } label: {
                    Text("review.satisfaction.yes")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                // Same construction as the soft-ask's Allow CTA — the app's
                // primary button. `Color.accentColor` is deliberately avoided:
                // AccentColor.colorset carries no value, so it resolves to
                // system blue.
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button {
                    AppAnalytics.log("satisfaction_prompt_no")
                    onNo()
                    dismiss()
                } label: {
                    Text("review.satisfaction.no")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .presentationDetents([.height(detentHeight)])
        .presentationDragIndicator(.visible)
        .onAppear {
            AppAnalytics.log("satisfaction_prompt_shown")
            pulseStarOnce()
        }
    }

    // MARK: - Icon block

    /// The app mark as the tile, clipped exactly as the soft-ask clips it,
    /// with a warm glow beneath. The review meaning comes from the badge.
    private var iconBlock: some View {
        ZStack(alignment: .topTrailing) {
            Image("Icon")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Color.orange.opacity(0.35), radius: 18, x: 0, y: 10)

            Image(systemName: "star.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .scaleEffect(starScale)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.orange))
                .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                .offset(x: 9, y: -9)
        }
        // Balances the badge's offset so the tile still reads as centred.
        .padding(.top, 9)
        .padding(.trailing, 9)
    }

    /// Swells the badge star once, ~0.4 s in total, on appearance.
    /// Skipped entirely under Reduce Motion — the star simply sits still.
    private func pulseStarOnce() {
        guard !reduceMotion else { return }
        Task { @MainActor in
            let steps: [(scale: CGFloat, duration: Double)] = [
                (1.35, 0.2), (1.0, 0.2)
            ]
            for step in steps {
                withAnimation(.easeInOut(duration: step.duration)) {
                    starScale = step.scale
                }
                try? await Task.sleep(for: .seconds(step.duration))
            }
        }
    }
}

#if DEBUG
#Preview("Satisfaction") {
    Color.black
        .sheet(isPresented: .constant(true)) {
            SatisfactionPromptView(onYes: {}, onNo: {})
        }
        .preferredColorScheme(.dark)
}

#Preview("Satisfaction — xxLarge") {
    Color.black
        .sheet(isPresented: .constant(true)) {
            SatisfactionPromptView(onYes: {}, onNo: {})
                .dynamicTypeSize(.xxLarge)
        }
        .preferredColorScheme(.dark)
}
#endif
