import SwiftUI

/// What the first-take result sheet shows about the take just recorded.
struct FirstTakeResult: Equatable {
    var duration: TimeInterval
    /// Nil when eye contact was not tracked long enough to summarise.
    var gaze: GazeAttention.TakeSummary?
}

/// Bottom sheet over the preview of a user's very first take: the value
/// moment. Shows eye contact for the take, offers pause-when-you-look-away
/// right where it pays off, and leads to recording an own script.
struct FirstTakeResultSheet: View {
    let result: FirstTakeResult
    @Binding var autoPause: Bool
    let onOwnScript: () -> Void
    let onWatch: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule()
                .fill(Color(white: 0.3))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    localized: "take_result.title",
                    defaultValue: "Nice first take",
                    comment: "Title of the sheet shown over the preview of the user's very first recording."
                ))
                    .font(.title2.bold())
                Text(String(
                    localized: "take_result.subtitle",
                    defaultValue: "Saved to Recordings",
                    comment: "Subtitle on the first-take result sheet: the take is already saved in the app's Recordings tab."
                ))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }

            if let gaze = result.gaze {
                eyeContactCard(gaze)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(
                        localized: "settings.recording.gazeAutoPause",
                        defaultValue: "Pause when you look away",
                        comment: "Toggle: freeze the prompter while the user looks away from the lens."
                    ))
                        .font(.subheadline.weight(.semibold))
                    Text(String(
                        localized: "take_result.autopause.body",
                        defaultValue: "The script waits for you and picks up on the same word.",
                        comment: "Explanation under the pause-when-you-look-away toggle on the first-take result sheet."
                    ))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $autoPause)
                    .labelsHidden()
                    .tint(.green)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(spacing: 10) {
                Button(action: onOwnScript) {
                    Text(String(
                        localized: "take_result.own_script",
                        defaultValue: "Now record your own script",
                        comment: "Primary button on the first-take result sheet: leads to writing and recording the user's own script."
                    ))
                        .font(.body.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Theme.accent, in: Capsule())
                }
                HStack(spacing: 10) {
                    secondaryButton(String(
                        localized: "take_result.watch",
                        defaultValue: "Watch take",
                        comment: "Button on the first-take result sheet: hides the sheet and plays the take."
                    ), action: onWatch)
                    secondaryButton(String(
                        localized: "recordings.preview.saveToCameraRoll",
                        defaultValue: "Save to Camera Roll",
                        comment: "Button on the preview screen to save the recording to the Photos library."
                    ), action: onSave)
                }
            }
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

    private func eyeContactCard(_ gaze: GazeAttention.TakeSummary) -> some View {
        let percent = Int((gaze.lookingFraction * 100).rounded())
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(String(
                        localized: "first_take.legend.contact",
                        defaultValue: "Eye contact",
                        comment: "Eye indicator legend: green eye, the user is looking at the lens."
                    ))
                } icon: {
                    Image(systemName: "eye.fill").foregroundStyle(.green)
                }
                .font(.subheadline.weight(.semibold))
                Spacer()
                Text(percent, format: .percent)
                    .font(.system(size: 34, weight: .heavy).monospacedDigit())
                    .foregroundStyle(.green)
            }
            timeline(gaze)
            Text(awayText(gaze))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private func tickOffset(_ moment: TimeInterval, width: CGFloat) -> CGFloat {
        let fraction = CGFloat(moment / max(result.duration, 1))
        return max(0, min(width - 6, width * fraction))
    }

    private func awayText(_ gaze: GazeAttention.TakeSummary) -> String {
        guard !gaze.awayMoments.isEmpty else {
            return String(
                localized: "take_result.away_none",
                defaultValue: "You kept your eyes on the lens the whole time.",
                comment: "First-take result sheet: the user never looked away during the take."
            )
        }
        let times = gaze.awayMoments.map { moment -> String in
            let seconds = Int(moment.rounded())
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        let list = ListFormatter.localizedString(byJoining: times)
        return String(
            localized: "take_result.away_some",
            defaultValue: "You looked down at \(list).",
            comment: "First-take result sheet: when the user looked away, e.g. 'You looked down at 0:04 and 0:09.' The placeholder is a localized list of m:ss times."
        )
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color(white: 0.17), in: Capsule())
        }
    }
}
