import SwiftUI

/// The recording screen's prompter pill, for onboarding.
///
/// Built from the same parts and the same portrait numbers as
/// `RecordingView`'s pill: the cutout config's radii and insets, 75% of the
/// screen width, the cutout band plus the active mode's content height, the
/// `PlaceholderLoopView`
/// renderer, and the eye from `GazeIndicator`. So it sits exactly where the
/// pill sits on the camera, under the lens, with the same anchor-aligned words.
struct OnboardingPrompterPill: View {
    /// Words to cycle through the pill.
    let phrase: String
    /// 3-line queue, or one word at a time.
    var isClassicMode = true
    var gazeState: GazeAttention.State = .looking

    /// `RecordingView.fontSize`.
    private let fontSize: CGFloat = 32

    var body: some View {
        GeometryReader { geo in
            let cfg = CutoutLayoutConfig.current(
                for: DeviceDetectionService.shared.cutoutType,
                screenWidth: geo.size.width,
                safeAreaTop: geo.safeAreaInsets.top
            )
            let collapsedExtent = max(1, geo.safeAreaInsets.top - cfg.topPadding)
            // `RecordingView.prompterGeometry`'s two content heights.
            let contentExtent = isClassicMode
                ? ClassicThreeLineView.lineHeight(for: fontSize) * 3 + 10
                : fontSize + 4 + 10
            let width = geo.size.width * 0.75

            UnevenRoundedRectangle(
                topLeadingRadius: cfg.topCornerRadius,
                bottomLeadingRadius: cfg.bottomCornerRadius,
                bottomTrailingRadius: cfg.bottomCornerRadius,
                topTrailingRadius: cfg.topCornerRadius,
                style: .continuous
            )
            .fill(Color.black)
            .frame(width: width, height: collapsedExtent + contentExtent)
            .overlay(alignment: .top) {
                PlaceholderLoopView(
                    fontSize: fontSize,
                    isClassicMode: isClassicMode,
                    phrase: phrase,
                    textOpacity: 1
                )
                .frame(width: width - 32)
                .padding(.top, cfg.textTopOffset)
            }
            .clipped()
            .overlay(alignment: .topLeading) { GazeIndicator(state: gazeState) }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: cfg.isCameraOffset ? .topTrailing : .top
            )
            .padding(.trailing, cfg.isCameraOffset ? 8 : 0)
            .padding(.top, cfg.topPadding)
            .ignoresSafeArea(edges: .top)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isClassicMode)
        }
        .accessibilityHidden(true)
    }
}
