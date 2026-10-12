import SwiftUI

/// Bounds of the record button, published so a coach overlay can spotlight it.
struct RecordButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// First-take coach, shown over the camera on the onboarding demo instead of
/// leaving a new user alone with the controls: the screen dims except a ring
/// around the record button, and a card above it says what to do, explains
/// the eye on the pill, and offers to record or just rehearse.
struct FirstTakeCoach: View {
    /// Record button frame in this view's coordinates; nil centres the card.
    let spotlight: CGRect?
    /// Shown again once a rehearsal reaches the end: "now record it".
    var afterRehearsal = false
    let onRecord: () -> Void
    let onRehearse: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                dim(in: geo.size)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                if let spot = spotlight {
                    Circle()
                        .stroke(Theme.accent.opacity(0.45), lineWidth: 6)
                        .shadow(color: Theme.accent.opacity(0.6), radius: 16)
                        .frame(width: spot.width + 16, height: spot.height + 16)
                        .position(x: spot.midX, y: spot.midY)
                        .allowsHitTesting(false)
                }
                card
                    .padding(.horizontal, 12)
                    .frame(width: geo.size.width)
                    .frame(
                        height: spotlight.map { $0.minY - 20 } ?? geo.size.height,
                        alignment: spotlight == nil ? .center : .bottom
                    )
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    /// Dimmed screen with a round hole over the record button.
    private func dim(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            var path = Path(CGRect(origin: .zero, size: canvasSize))
            if let spot = spotlight {
                path.addEllipse(in: spot.insetBy(dx: -8, dy: -8))
            }
            context.fill(path, with: .color(.black.opacity(0.58)), style: FillStyle(eoFill: true))
        }
        .frame(width: size.width, height: size.height)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(
                localized: "first_take.chip",
                defaultValue: "First take",
                comment: "Small label at the top of the coach card shown on the user's first recording (onboarding demo)."
            ))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.accent.opacity(0.16), in: Capsule())

            VStack(alignment: .leading, spacing: 6) {
                Text(afterRehearsal
                    ? String(
                        localized: "first_take.after.title",
                        defaultValue: "Now record it",
                        comment: "Title of the first-take coach card shown again after the user rehearsed the sample script to the end."
                    )
                    : String(
                        localized: "first_take.title",
                        defaultValue: "Tap record and read the words",
                        comment: "Title of the first-take coach card on the camera screen."
                    ))
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Text(afterRehearsal
                    ? String(
                        localized: "first_take.after.body",
                        defaultValue: "Same words, same spot under the lens. The eye shows how you did.",
                        comment: "Body of the first-take coach card after a rehearsal. 'The eye' is the eye-contact indicator on the prompter pill."
                    )
                    : String(
                        localized: "first_take.body",
                        defaultValue: "They run right under the lens. Keep your eyes up there and the eye turns green.",
                        comment: "Body of the first-take coach card. 'The eye' is the eye-contact indicator in the corner of the prompter pill."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                legend(.idle, String(localized: "first_take.legend.ready", defaultValue: "Ready", comment: "Eye indicator legend: grey eye, tracking not started yet."))
                legend(.calibrating, String(localized: "first_take.legend.calibrating", defaultValue: "Calibrating", comment: "Eye indicator legend: orange eye, learning the user's eye contact in the first seconds."))
                legend(.looking, String(localized: "first_take.legend.contact", defaultValue: "Eye contact", comment: "Eye indicator legend: green eye, the user is looking at the lens."))
            }

            HStack(spacing: 10) {
                Button(action: onRecord) {
                    Text(String(
                        localized: "first_take.record",
                        defaultValue: "Start recording",
                        comment: "Primary button on the first-take coach card: starts the recording countdown."
                    ))
                        .font(.body.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.accent, in: Capsule())
                }
                Button(action: onRehearse) {
                    Text(afterRehearsal
                        ? String(
                            localized: "first_take.rehearse_again",
                            defaultValue: "Rehearse again",
                            comment: "Secondary button on the first-take coach card after a rehearsal: plays the sample script again without recording."
                        )
                        : String(
                            localized: "first_take.rehearse",
                            defaultValue: "Just rehearse",
                            comment: "Secondary button on the first-take coach card: plays the prompter without recording."
                        ))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color(white: 0.17), in: Capsule())
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .padding(20)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }

    private func legend(_ state: GazeAttention.State, _ label: String) -> some View {
        VStack(spacing: 2) {
            GazeIndicator(state: state, glyphSize: 18, frameSize: 26)
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
