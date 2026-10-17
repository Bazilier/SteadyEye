import SwiftUI

/// Caption geometry shared by the preview overlay and the burn-in, so what
/// the preview shows is what the saved video gets. Fractions of the
/// video's width and height.
nonisolated enum SubtitleStyle {
    static let fontSizeOfWidth: CGFloat = 0.062
    static let maxWidthOfWidth: CGFloat = 0.86
    /// From the bottom edge to the caption's bottom.
    static let bottomInsetOfHeight: CGFloat = 0.2
}

/// The preview's captions toggle, beside the scissors. Shaped like
/// `SectionCutButton`; spins while the take is being transcribed.
struct SubtitlesButton: View {
    let isOn: Bool
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isWorking {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isOn ? Theme.onAccent : .white)
                }
            }
            .frame(width: 56, height: 56)
            .background {
                if isOn && !isWorking {
                    Circle().fill(Theme.accent)
                } else {
                    Color.clear.modifier(GlassCircleModifier())
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityLabel(Text("preview.subtitles", comment: "VoiceOver label of the captions toggle in the recording preview."))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The caption for the playhead, over the video frame it sits on.
struct SubtitleOverlay: View {
    @ObservedObject var clock: PlaybackClock
    let phrases: [SubtitlePhrase]

    var body: some View {
        GeometryReader { geo in
            if let phrase = SubtitlePhrases.phrase(at: clock.time, in: phrases) {
                Text(phrase.text)
                    .font(.system(size: geo.size.width * SubtitleStyle.fontSizeOfWidth, weight: .heavy))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.85), radius: 1)
                    .shadow(color: .black.opacity(0.6), radius: 4)
                    .frame(maxWidth: geo.size.width * SubtitleStyle.maxWidthOfWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, geo.size.height * SubtitleStyle.bottomInsetOfHeight)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
