import SwiftUI

/// Full-screen overlay with spotlight cutout and tooltip bubble.
/// Only shows if the current step belongs to the specified screen.
struct CoachMarkOverlay: View {
    @ObservedObject var manager: CoachMarkManager
    let screen: CoachTooltip.Screen

    var body: some View {
        if manager.isActive,
           let tooltip = manager.currentTooltip,
           tooltip.screen == screen {
            let frame = manager.spotlightFrames[manager.currentStep] ?? .zero

            ZStack {
                // Dim overlay with spotlight cutout
                SpotlightMask(spotlightRect: frame)
                    .fill(Color.black.opacity(0.6))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // Tooltip bubble
                tooltipBubble(tooltip: tooltip, spotlightFrame: frame)
            }
            .animation(.easeInOut(duration: 0.3), value: manager.currentStep)
        }
    }

    @ViewBuilder
    private func tooltipBubble(tooltip: CoachTooltip, spotlightFrame: CGRect) -> some View {
        let screenHeight = UIScreen.main.bounds.height

        VStack(spacing: 12) {
            Text(tooltip.text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Button {
                if tooltip.buttonText == "Done" {
                    withAnimation { manager.complete() }
                } else {
                    withAnimation { manager.advance() }
                }
            } label: {
                Text(tooltip.buttonText)
                    .font(.subheadline.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.orange, in: Capsule())
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.15))
        )
        .padding(.horizontal, 32)
        .position(
            x: UIScreen.main.bounds.width / 2,
            y: tooltip.position == .below
                ? min(spotlightFrame.maxY + 80, screenHeight - 120)
                : max(spotlightFrame.minY - 80, 120)
        )
    }
}

/// Shape that fills the screen except for a rounded-rect cutout.
struct SpotlightMask: Shape {
    var spotlightRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        if spotlightRect != .zero {
            let inset = spotlightRect.insetBy(dx: -8, dy: -8)
            path.addRoundedRect(in: inset, cornerSize: CGSize(width: 12, height: 12))
        }
        return path
    }
}

// MARK: - Spotlight frame reporter

struct SpotlightFrameModifier: ViewModifier {
    let step: Int
    @ObservedObject var manager: CoachMarkManager

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            manager.registerFrame(geo.frame(in: .global), for: step)
                        }
                        .onChange(of: geo.frame(in: .global)) { _, newFrame in
                            manager.registerFrame(newFrame, for: step)
                        }
                }
            )
    }
}

extension View {
    func coachSpotlight(step: Int, manager: CoachMarkManager) -> some View {
        modifier(SpotlightFrameModifier(step: step, manager: manager))
    }
}
