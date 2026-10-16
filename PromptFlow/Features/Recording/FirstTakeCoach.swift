import SwiftUI

/// Bounds of the record button, published so a coach overlay can spotlight it.
struct RecordButtonBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// First-take coach, shown over the camera before the first take of the
/// user's own script in the guided first run: the screen dims except a ring
/// around the record button, with one line above it. The record button takes
/// the tap through the hole; a tap anywhere else just clears the coach.
struct FirstTakeCoach: View {
    /// Record button frame in this view's coordinates; nil centres the line.
    let spotlight: CGRect?
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                dim(in: geo.size)
                    // The hole is not part of the dim's hit area, so a tap
                    // there reaches the real record button underneath.
                    .contentShape(SpotlightCutout(hole: spotlight.map(Self.hole)), eoFill: true)
                    .onTapGesture(perform: onDismiss)
                if let spot = spotlight {
                    Circle()
                        .stroke(Theme.accent.opacity(0.45), lineWidth: 6)
                        .shadow(color: Theme.accent.opacity(0.6), radius: 16)
                        .frame(width: spot.width + 16, height: spot.height + 16)
                        .position(x: spot.midX, y: spot.midY)
                        .allowsHitTesting(false)
                }
                bubble
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

    private static func hole(_ spot: CGRect) -> CGRect { spot.insetBy(dx: -8, dy: -8) }

    /// Dimmed screen with a round hole over the record button.
    private func dim(in size: CGSize) -> some View {
        SpotlightCutout(hole: spotlight.map(Self.hole))
            .fill(Color.black.opacity(0.58), style: FillStyle(eoFill: true))
            .frame(width: size.width, height: size.height)
    }

    /// One line pointing at the record button.
    private var bubble: some View {
        VStack(spacing: 0) {
            Text(String(
                localized: "first_take.compact",
                defaultValue: "Tap record to start",
                comment: "One-line coach above the spotlit record button when the user records their own script for the first time."
            ))
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(white: 0.11))
                .offset(y: -3)
        }
        .allowsHitTesting(false)
    }
}

/// The whole rect with an oval hole; drawn and hit-tested with even-odd fill.
private struct SpotlightCutout: Shape {
    let hole: CGRect?

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if let hole { path.addEllipse(in: hole) }
        return path
    }
}
