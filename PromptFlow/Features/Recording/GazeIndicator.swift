import SwiftUI

/// The eye on the prompter pill (see `GazeAttention`): grey outline while
/// idle, accent while it calibrates, green on eye contact, grey filled once
/// the user looks away. Decorative — no hit area. Shared by the recording
/// screen and onboarding so both draw the same eye.
struct GazeIndicator: View {
    let state: GazeAttention.State
    var isLandscape = false

    var body: some View {
        Image(systemName: state == .idle ? "eye" : "eye.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .rotationEffect(isLandscape ? .degrees(90) : .degrees(0))
            .frame(width: 44, height: 44)
            .animation(.easeInOut(duration: 0.2), value: state)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch state {
        case .idle, .away: return .white.opacity(0.35)
        case .calibrating: return Theme.accent
        case .looking: return .green
        }
    }
}
