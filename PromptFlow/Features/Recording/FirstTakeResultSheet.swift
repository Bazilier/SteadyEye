import SwiftUI

/// What the first-take result sheet shows about the take just recorded.
struct FirstTakeResult: Equatable {
    var duration: TimeInterval
    /// Nil when eye contact was not tracked long enough to summarise.
    var gaze: GazeAttention.TakeSummary?
}

/// Short bottom sheet over the preview of the guided first run's take: how
/// long it was, the eye contact it held, and one way on. Low enough that
/// the take itself stays in view (tap it to play).
struct FirstTakeResultSheet: View {
    let result: FirstTakeResult
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(Color(white: 0.3))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(
                        localized: "take_result.title",
                        defaultValue: "Your first take",
                        comment: "Title of the short sheet shown over the preview of the user's first take in the guided first run."
                    ))
                        .font(.title3.bold())
                    Text(String(
                        localized: "take_result.subtitle_duration",
                        defaultValue: "\(durationText) · Saved to Recordings",
                        comment: "Subtitle on the first-take result sheet. %@ is the take's length as m:ss; the take is already saved in the app's Recordings tab."
                    ))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer(minLength: 8)
                if let gaze = result.gaze {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text(gaze.lookingFraction, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 26, weight: .heavy).monospacedDigit())
                    }
                    .foregroundStyle(.green)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(String(
                        localized: "take_result.eye_contact_a11y",
                        defaultValue: "Eye contact \(Int((gaze.lookingFraction * 100).rounded())) percent",
                        comment: "VoiceOver label for the eye-contact score on the first-take result sheet. %lld is the whole percent."
                    )))
                }
            }

            if let gaze = result.gaze {
                timeline(gaze)
            }

            Button(action: onContinue) {
                Text(String(
                    localized: "take_result.continue",
                    defaultValue: "Continue",
                    comment: "The one button on the first-take result sheet: closes the preview and goes on (to the paywall for free users)."
                ))
                    .font(.body.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Theme.accent, in: Capsule())
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(
            Color(white: 0.11)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32, style: .continuous))
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var durationText: String {
        let seconds = Int(result.duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The take as a green bar with a grey tick wherever the eyes left.
    private func timeline(_ gaze: GazeAttention.TakeSummary) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.green)
                ForEach(Array(gaze.awayMoments.enumerated()), id: \.offset) { _, moment in
                    Rectangle()
                        .fill(Color(white: 0.4))
                        .frame(width: 6)
                        .offset(x: tickOffset(moment, width: geo.size.width))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func tickOffset(_ moment: TimeInterval, width: CGFloat) -> CGFloat {
        let fraction = CGFloat(moment / max(result.duration, 1))
        return max(0, min(width - 6, width * fraction))
    }
}
