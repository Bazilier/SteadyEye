import SwiftUI

/// What the take-result toast shows about the take just recorded.
struct FirstTakeResult: Equatable {
    var duration: TimeInterval
    /// Nil when eye contact was not tracked long enough to summarise.
    var gaze: GazeAttention.TakeSummary?
}

/// A small card floating over the preview's progress bar with the eye
/// contact the take just recorded held. The scrubber and the buttons stay
/// usable under it, and the cross closes it.
///
/// After the guided first run's take it says so and the preview's one
/// button below is Continue. After any other take (eye-contact indicator
/// on) it carries "Don't show again"; Settings turns it back on.
struct EyeContactToast: View {
    let result: FirstTakeResult
    var isFirstTake = false
    let onClose: () -> Void

    @AppStorage(Self.enabledKey) private var showsAfterTakes = true
    /// Whether the toast follows an ordinary take.
    static let enabledKey = "takeEyeContactSheetEnabled"

    /// Below this the first take's score is left out. The first take is the
    /// one where the measurement is least settled (no baseline before it),
    /// and a low number at the moment that should feel good would mislead
    /// more than it tells.
    static let minimumShownEyeContact = 0.6

    /// Eye contact worth showing, if any.
    private var gaze: GazeAttention.TakeSummary? {
        guard let gaze = result.gaze else { return nil }
        if isFirstTake, gaze.lookingFraction < Self.minimumShownEyeContact { return nil }
        return gaze
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                if let gaze {
                    EyeContactScore(fraction: gaze.lookingFraction, size: 22)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, 34)

            if let gaze {
                EyeContactBar(gaze: gaze)
            }

            if !isFirstTake {
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.12), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel(Text(String(localized: "common.close", defaultValue: "Close", comment: "Close button.")))
        }
        .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
    }

    private var title: String {
        isFirstTake
            ? String(
                localized: "take_result.title",
                defaultValue: "Your first take",
                comment: "Title of the short sheet shown over the preview of the user's first take in the guided first run."
            )
            : String(
                localized: "take_result.regular_title",
                defaultValue: "Eye contact",
                comment: "Title of the short card shown over a take's preview with the eye contact the take held."
            )
    }

    private var subtitle: String {
        let duration = EyeContactBar.timeText(result.duration)
        guard isFirstTake else { return duration }
        return String(
            localized: "take_result.subtitle_duration",
            defaultValue: "\(duration) · Saved to Recordings",
            comment: "Subtitle on the first-take result sheet. %@ is the take's length as m:ss; the take is already saved in the app's Recordings tab."
        )
    }
}

/// The eye icon and the percentage, in green.
private struct EyeContactScore: View {
    let fraction: Double
    let size: CGFloat

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "eye.fill")
                .font(.system(size: size * 0.7, weight: .semibold))
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
