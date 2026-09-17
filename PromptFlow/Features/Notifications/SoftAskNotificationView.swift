import SwiftUI

/// In-app soft ask shown before triggering iOS's notification permission
/// prompt. Improves grant rate by pre-qualifying users before the system
/// prompt — once the user denies the system prompt, we lose the surface
/// for the lifetime of the install.
struct SoftAskNotificationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onAllow: () -> Void

    /// Drives the one-shot ring of the badge bell. Never animates under
    /// Reduce Motion — see `ringBellOnce()`.
    @State private var bellAngle: Double = 0

    /// A fixed-height detent cannot grow with its content, so it has to clear
    /// the tallest layout it will ever hold. 420 is the shipped height and
    /// still fits every standard size; the accessibility sizes roughly double
    /// the title + body height, so the sheet grows for those rather than
    /// clipping the buttons.
    private var detentHeight: CGFloat {
        if dynamicTypeSize >= .accessibility1 { return 620 }
        if dynamicTypeSize >= .xxLarge { return 520 }
        return 420
    }

    var body: some View {
        VStack(spacing: 0) {
            iconBlock

            Text("notifications.soft_ask.title")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 24)

            Text("notifications.soft_ask.body")
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
                    AppAnalytics.log("push_soft_ask_accepted")
                    onAllow()
                    dismiss()
                } label: {
                    Text("notifications.soft_ask.allow")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                // Same construction as the editor's Optimize CTA — the app's
                // primary button. `Color.accentColor` is deliberately avoided:
                // AccentColor.colorset carries no value, so it resolves to
                // system blue.
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button {
                    AppAnalytics.log("push_soft_ask_dismissed")
                    dismiss()
                } label: {
                    Text("notifications.soft_ask.not_now")
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
            AppAnalytics.log("push_soft_ask_shown")
            ringBellOnce()
        }
    }

    // MARK: - Icon block

    /// The app mark itself as the tile — it is a full-bleed square icon with
    /// its own dark ground, so it needs no gradient plate behind it. Clipped
    /// the same way `SplashView` clips it, at sheet scale, with a warm glow
    /// beneath. The notification meaning comes from the badge.
    private var iconBlock: some View {
        ZStack(alignment: .topTrailing) {
            Image("Icon")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Color.orange.opacity(0.35), radius: 18, x: 0, y: 10)

            Image(systemName: "bell.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                // Pivot at the top so the ring reads as a swing, not a spin.
                .rotationEffect(.degrees(bellAngle), anchor: .top)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.orange))
                .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                .offset(x: 9, y: -9)
        }
        // Balances the badge's offset so the tile still reads as centred.
        .padding(.top, 9)
        .padding(.trailing, 9)
    }

    /// Swings the badge bell ±12° twice, ~0.6 s in total, once per appearance.
    /// Skipped entirely under Reduce Motion — the bell simply sits still.
    private func ringBellOnce() {
        guard !reduceMotion else { return }
        Task { @MainActor in
            let steps: [(angle: Double, duration: Double)] = [
                (12, 0.12), (-12, 0.12), (12, 0.12), (-12, 0.12), (0, 0.12)
            ]
            for step in steps {
                withAnimation(.easeInOut(duration: step.duration)) {
                    bellAngle = step.angle
                }
                try? await Task.sleep(for: .seconds(step.duration))
            }
        }
    }
}

#if DEBUG
#Preview("Soft ask") {
    Color.black
        .sheet(isPresented: .constant(true)) {
            SoftAskNotificationView(onAllow: {})
        }
        .preferredColorScheme(.dark)
}

#Preview("Soft ask — xxLarge") {
    Color.black
        .sheet(isPresented: .constant(true)) {
            SoftAskNotificationView(onAllow: {})
                .dynamicTypeSize(.xxLarge)
        }
        .preferredColorScheme(.dark)
}
#endif
