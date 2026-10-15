import SwiftUI

/// Satisfaction pre-prompt, asked at a happy moment (see
/// `ReviewPromptManager.Trigger`): after watching a take that held eye
/// contact, with its score up top, or after coming back from sharing one.
///
/// Yes asks, as a second step, whether they would rate the app, and only an
/// agreement there opens the App Store review page — never straight from
/// Yes, which reads as being thrown out of the app. No opens the founder
/// chat — so the App Store only ever hears from people who already said they
/// were happy, and everyone else reaches a person instead of a rating field.
/// Structure deliberately mirrors `SoftAskNotificationView`, the house
/// pattern for a two-button app-styled prompt.
///
/// Arbiter wiring lives at the call site (`VideoPreviewView`), not here.
struct SatisfactionPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var trigger: ReviewPromptManager.Trigger = .afterExport
    /// The take's eye contact, 0...100, shown above the question.
    var eyeContactPercent: Int? = nil
    /// Yes, and then agreed to rate.
    let onRate: () -> Void
    let onNo: () -> Void

    /// Yes moves the sheet to the rating ask instead of closing it.
    @State private var isAskingToRate = false

    /// Drives the one-shot pulse of the badge star. Never animates under
    /// Reduce Motion — see `pulseStarOnce()`.
    @State private var starScale: CGFloat = 1

    /// Measured, so the sheet is exactly as tall as its content at any
    /// text size.
    @State private var contentHeight: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            iconBlock

            if !isAskingToRate, let percent = eyeContactPercent {
                Label {
                    Text(String(
                        localized: "review.satisfaction.eye_contact",
                        defaultValue: "\(percent)% eye contact",
                        comment: "Pill above the satisfaction question after a take: the take's eye contact score, e.g. '92% eye contact'."
                    ))
                } icon: {
                    Image(systemName: "eye.fill")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.16), in: Capsule())
                .padding(.top, 20)
            }

            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, isAskingToRate || eyeContactPercent == nil ? 24 : 12)

            Text(isAskingToRate ? "review.satisfaction.rate.body" : "review.satisfaction.body")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                // Narrower than the sheet so lines break evenly instead of
                // running edge to edge.
                .frame(maxWidth: 300)
                .padding(.top, 10)

            Spacer().frame(height: 28)

            if isAskingToRate {
                rateButtons
            } else {
                questionButtons
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .presentationBackground(Color(white: 0.11))
        .preferredColorScheme(.dark)
        .onAppear {
            AppAnalytics.log("satisfaction_prompt_shown", params: [
                "trigger": trigger.rawValue,
                "eye_contact_pct": eyeContactPercent ?? -1
            ])
            pulseStarOnce()
        }
    }

    private var questionButtons: some View {
        VStack(spacing: 12) {
            Button {
                AppAnalytics.log("satisfaction_prompt_yes", params: ["trigger": trigger.rawValue])
                withAnimation(.easeInOut(duration: 0.25)) { isAskingToRate = true }
            } label: {
                Text("review.satisfaction.yes")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            // Same construction as the soft-ask's Allow CTA — the app's
            // primary button. Tint re-applied because sheets don't
            // inherit the TabView's `.tint`.
            .primaryButtonStyle()
            .tint(Theme.accent)

            Button {
                AppAnalytics.log("satisfaction_prompt_no", params: ["trigger": trigger.rawValue])
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

    /// Second step, after Yes. Not now just closes: nothing is burned, so
    /// the usual re-ask window applies.
    private var rateButtons: some View {
        VStack(spacing: 12) {
            Button {
                AppAnalytics.log("satisfaction_rate_yes", params: ["trigger": trigger.rawValue])
                onRate()
                dismiss()
            } label: {
                Text("review.satisfaction.rate.yes")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .primaryButtonStyle()
            .tint(Theme.accent)

            Button {
                AppAnalytics.log("satisfaction_rate_later", params: ["trigger": trigger.rawValue])
                dismiss()
            } label: {
                Text("review.satisfaction.rate.later")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private var title: String {
        if isAskingToRate {
            return String(localized: "review.satisfaction.rate.title", defaultValue: "Glad to hear it!", comment: "Title of the satisfaction prompt's second step, shown after the user said they are happy. Keep it ungendered.")
        }
        switch trigger {
        case .greatTake:
            return String(localized: "review.satisfaction.title.take", defaultValue: "Happy with this take?", comment: "Satisfaction question right after the user watched a take that held eye contact.")
        case .afterExport:
            return String(localized: "review.satisfaction.title.export", defaultValue: "How did your video turn out?", comment: "Satisfaction question when the user comes back to the app after exporting a take to share.")
        case .studioSound:
            return String(localized: "review.satisfaction.title.studio", defaultValue: "How does it sound?", comment: "Satisfaction question after the user compared the original and the Studio Sound (enhanced) audio of a take and watched it to the end.")
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
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .shadow(color: Theme.accent.opacity(0.35), radius: 18, x: 0, y: 10)

            Image(systemName: "star.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .scaleEffect(starScale)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.accent))
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
            SatisfactionPromptView(onRate: {}, onNo: {})
        }
        .preferredColorScheme(.dark)
}

#Preview("Satisfaction — xxLarge") {
    Color.black
        .sheet(isPresented: .constant(true)) {
            SatisfactionPromptView(onRate: {}, onNo: {})
                .dynamicTypeSize(.xxLarge)
        }
        .preferredColorScheme(.dark)
}
#endif
