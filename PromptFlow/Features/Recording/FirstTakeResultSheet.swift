import SwiftUI

/// What the take-result surfaces show about the take just recorded.
struct FirstTakeResult: Equatable {
    var duration: TimeInterval
    /// Nil when eye contact was not tracked long enough to summarise.
    var gaze: GazeAttention.TakeSummary?
}

/// Short bottom sheet over the preview of the guided first run's take: how
/// long it was, the eye contact it held, and one way on. Low enough that the
/// take itself stays in view (tap it to play).
struct FirstTakeResultSheet: View {
    let result: FirstTakeResult
    let onContinue: () -> Void

    /// Below this the score is left out. The first take is the one where
    /// the measurement is least settled (no baseline before it), and a low
    /// number at the moment that should feel good would mislead more than
    /// it tells.
    static let minimumShownEyeContact = 0.6

    /// Eye contact worth showing, if any.
    private var gaze: GazeAttention.TakeSummary? {
        guard let gaze = result.gaze, gaze.lookingFraction >= Self.minimumShownEyeContact else { return nil }
        return gaze
    }

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
                        defaultValue: "\(EyeContactBar.timeText(result.duration)) · Saved to Recordings",
                        comment: "Subtitle on the first-take result sheet. %@ is the take's length as m:ss; the take is already saved in the app's Recordings tab."
                    ))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer(minLength: 8)
                if let gaze {
                    EyeContactScore(fraction: gaze.lookingFraction, size: 26)
                }
            }

            if let gaze {
                EyeContactBar(gaze: gaze)
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
}

/// After an ordinary take (eye-contact indicator on): a small card floating
/// over the preview's progress bar, with the take's eye contact and its bar.
/// The scrubber and the buttons stay usable under it. The cross closes it;
/// "Don't show again" turns it off, and Settings turns it back on.
struct EyeContactToast: View {
    let result: FirstTakeResult
    let onClose: () -> Void

    @AppStorage(Self.enabledKey) private var showsAfterTakes = true
    /// Whether the toast follows an ordinary take.
    static let enabledKey = "takeEyeContactSheetEnabled"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(String(
                    localized: "take_result.regular_title",
                    defaultValue: "Eye contact",
                    comment: "Title of the short card shown over a take's preview with the eye contact the take held."
                ))
                    .font(.subheadline.weight(.semibold))
                if let gaze = result.gaze {
                    EyeContactScore(fraction: gaze.lookingFraction, size: 20)
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, 28)

            if let gaze = result.gaze {
                EyeContactBar(gaze: gaze)
            }

            Button {
                AppAnalytics.log("take_eye_contact_sheet_toggled", params: ["shows": false])
                showsAfterTakes = false
                onClose()
            } label: {
                Text(String(
                    localized: "take_result.dont_show",
                    defaultValue: "Don’t show again",
                    comment: "Quiet button on the eye-contact card after a take: stop showing it after takes. It can be turned back on in Settings."
                ))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.12), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(2)
            .accessibilityLabel(Text(String(localized: "common.close", defaultValue: "Close", comment: "Close button.")))
        }
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
    }
}

/// The eye icon and the percentage, in green.
private struct EyeContactScore: View {
    let fraction: Double
    let size: CGFloat

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "eye.fill")
                .font(.system(size: size * 0.58, weight: .semibold))
            Text(fraction, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: size, weight: .heavy).monospacedDigit())
        }
        .foregroundStyle(.green)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(
            localized: "take_result.eye_contact_a11y",
            defaultValue: "Eye contact \(Int((fraction * 100).rounded())) percent",
            comment: "VoiceOver label for the eye-contact score on the first-take result sheet. %lld is the whole percent."
        )))
    }
}

/// The measured part of a take (calibration and the time after the script
/// ran out are left out, as they are from the percentage) as a green bar,
/// grey wherever the eyes were away and for as long, so it agrees with the
/// percentage.
struct EyeContactBar: View {
    let gaze: GazeAttention.TakeSummary

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.green)
                ForEach(Array(gaze.awaySpans.enumerated()), id: \.offset) { _, span in
                    let x = position(span.lowerBound, width: geo.size.width)
                    let end = position(span.upperBound, width: geo.size.width)
                    Rectangle()
                        .fill(Color(white: 0.4))
                        .frame(width: max(3, end - x))
                        .offset(x: min(x, geo.size.width - 3))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func position(_ time: TimeInterval, width: CGFloat) -> CGFloat {
        let span = max(gaze.trackedUntil - gaze.trackedFrom, 1)
        let fraction = CGFloat((time - gaze.trackedFrom) / span)
        return max(0, min(width, width * fraction))
    }

    /// A length as m:ss.
    static func timeText(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
