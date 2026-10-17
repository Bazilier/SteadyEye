import SwiftUI

/// The preview's toggle between the take cut down to its sections' last
/// takes and the whole take. Shaped like `StudioSoundButton`, beside it.
struct SectionCutButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "scissors")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isOn ? Theme.onAccent : .white)
                .frame(width: 56, height: 56)
                .background {
                    if isOn {
                        Circle().fill(Theme.accent)
                    } else {
                        Color.clear.modifier(GlassCircleModifier())
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SectionCutChip.label(isCut: true))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Over the preview after the cut button: which version plays now.
struct SectionCutChip: View {
    let isCut: Bool

    static func label(isCut: Bool) -> Text {
        isCut
            ? Text("preview.section_cut.cut", comment: "Chip over the preview video, and VoiceOver label of the scissors toggle: the take plays cut down to the last take of each //// section, without the pauses between.")
            : Text("preview.section_cut.whole", comment: "Chip over the preview video when the scissors toggle is off: the whole take plays, repeats and pauses included.")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "scissors")
                .foregroundStyle(isCut ? Theme.accent : .white)
            Self.label(isCut: isCut)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Color.black.opacity(0.55), in: Capsule())
    }
}

/// Over the preview video while it is held and plays fast.
struct FastForwardChip: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "forward.fill")
            Text(verbatim: "\(Int(PlaybackController.fastForwardRate))×")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Color.black.opacity(0.55), in: Capsule())
        .accessibilityHidden(true)
    }
}
