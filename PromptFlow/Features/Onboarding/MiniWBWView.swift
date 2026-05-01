import SwiftUI

/// Onboarding-specific styled wrapper around `AnimatedRSVPHeadline`. Mimics
/// the Dynamic-Island pill the user will see during recording so the priming
/// screen previews the WBW reading mode. The word-sequencing logic itself is
/// shared with the paywall headline via `AnimatedRSVPHeadline`.
struct MiniWBWView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black)
            AnimatedRSVPHeadline(
                text: Self.loadText(),
                font: .system(.title2, design: .monospaced).weight(.semibold),
                tickInterval: 0.28,
                loops: true,
                endHoldSeconds: 0.6,
                useORPHighlight: true,
                reserveFullPhraseSpace: false
            )
        }
        .frame(width: 280, height: 56)
    }

    private static func loadText() -> String {
        String(
            localized: "onboarding.mini_wbw.script",
            defaultValue: "You're reading right now without moving your eyes. That's the whole trick."
        )
    }
}
