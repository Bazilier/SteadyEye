import SwiftUI

/// The recording screen's prompter pill, for onboarding and the paywall.
///
/// Built from the same parts and the same portrait numbers as
/// `RecordingView`'s pill: the cutout config's radii and insets, 75% of the
/// screen width, the cutout band plus the active mode's content height, the
/// `PlaceholderLoopView`
/// renderer, and the eye from `GazeIndicator`. So it sits exactly where the
/// pill sits on the camera, under the lens, with the same anchor-aligned words.
struct PrompterPillPreview: View {
    /// Words to cycle through the pill.
    let phrase: String
    /// 3-line queue, or one word at a time.
    var isClassicMode = true
    var gazeState: GazeAttention.State = .looking

    /// `RecordingView.fontSize`.
    static let fontSize: CGFloat = 32
    private var fontSize: CGFloat { Self.fontSize }

    /// `RecordingView.prompterGeometry`'s two content heights.
    static func contentExtent(isClassicMode: Bool) -> CGFloat {
        isClassicMode
            ? ClassicThreeLineView.lineHeight(for: fontSize) * 3 + 10
            : fontSize + 4 + 10
    }

    var body: some View {
        GeometryReader { geo in
            let cfg = CutoutLayoutConfig.current(
                for: DeviceDetectionService.shared.cutoutType,
                screenWidth: geo.size.width,
                safeAreaTop: geo.safeAreaInsets.top
            )
            let collapsedExtent = max(1, geo.safeAreaInsets.top - cfg.topPadding)
            let contentExtent = Self.contentExtent(isClassicMode: isClassicMode)
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

extension PrompterPillPreview {
    /// Where the pill ends and where a close button goes, in the safe-area
    /// coordinates of a full-screen view: content starts below the pill, and
    /// the close button takes the usual top-leading spot beside it, level
    /// with the top of the pill (the camera cutout). Sized as on the camera
    /// (`RecordingView.portraitCloseButton`). The close frame is at least
    /// 44 pt, so its leading and top are pulled in by the extra.
    struct Layout {
        let contentTop: CGFloat
        let closeSize: CGFloat
        let closeLeading: CGFloat
        let closeTop: CGFloat

        init(safeTop: CGFloat, screenWidth: CGFloat, isClassicMode: Bool, spacing: CGFloat = 16) {
            let cfg = CutoutLayoutConfig.current(
                for: DeviceDetectionService.shared.cutoutType,
                screenWidth: screenWidth,
                safeAreaTop: safeTop
            )
            let pillBottom = cfg.topPadding
                + max(1, safeTop - cfg.topPadding)
                + PrompterPillPreview.contentExtent(isClassicMode: isClassicMode)
            let size: CGFloat = cfg.isCameraOffset ? 42 : 32
            let inset = (max(size, 44) - size) / 2
            closeSize = size
            // Clear of the rounded screen corner. Where the pill is centred
            // (no camera offset) the gutter beside it is narrow, so the
            // button stays closer to the edge there.
            closeLeading = (cfg.isCameraOffset ? 20 : 8) - inset
            closeTop = max(20, cfg.topPadding + 8) - safeTop - inset
            contentTop = pillBottom - safeTop + spacing
        }
    }
}

/// The prompter pill on its own, not attached to a camera: for screens where
/// the lens is somewhere the layout cannot follow (iPhone Duo).
struct FloatingPrompterPill: View {
    let phrase: String
    var isClassicMode = true
    /// Where the words start: below the eye by default.
    var textTop: CGFloat = 26
    /// A lens the pill covers: the words keep clear of it on that side.
    var lensSide: HorizontalEdge = .trailing
    var lensBand: CGFloat = 0

    var body: some View {
        let fontSize = PrompterPillPreview.fontSize
        RoundedRectangle(cornerRadius: 32, style: .continuous)
            .fill(Color.black)
            .frame(
                maxWidth: 292 + lensBand,
                minHeight: PrompterPillPreview.contentExtent(isClassicMode: isClassicMode) + textTop + 4,
                maxHeight: PrompterPillPreview.contentExtent(isClassicMode: isClassicMode) + textTop + 4
            )
            .overlay(alignment: .top) {
                PlaceholderLoopView(
                    fontSize: fontSize,
                    isClassicMode: isClassicMode,
                    phrase: phrase,
                    textOpacity: 1
                )
                .padding(.horizontal, 16)
                .padding(lensSide == .trailing ? .trailing : .leading, lensBand)
                .padding(.top, textTop)
            }
            .overlay(alignment: lensSide == .trailing ? .bottomTrailing : .bottomLeading) {
                // Under the lens when there is one, else in the top corner.
                if lensBand > 0 {
                    GazeIndicator(state: .looking, frameSize: 32)
                        .frame(width: lensBand + 16)
                        .padding(.bottom, 8)
                }
            }
            .overlay(alignment: .topLeading) {
                if lensBand == 0 {
                    GazeIndicator(state: .looking, frameSize: 32)
                        .padding(.leading, 6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .accessibilityHidden(true)
    }
}
