import SwiftUI

/// Press feedback for the script and recording cards. The card eases down
/// while touched; with `isOpening` it stays down after release until the
/// destination it opened is dismissed, so the zoom starts from, and lands
/// back on, the pressed size before the card eases back up.
struct CardPressStyle: ButtonStyle {
    static let pressedScale: CGFloat = 0.96
    static let pressDuration: Double = 0.3
    /// Back to full size, after a cancelled press or a closed destination.
    static let releaseDuration: Double = 0.2

    var isOpening = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let isDown = !reduceMotion && (configuration.isPressed || isOpening)
        configuration.label
            .scaleEffect(isDown ? Self.pressedScale : 1)
            .animation(
                .easeOut(duration: isDown ? Self.pressDuration : Self.releaseDuration),
                value: isDown
            )
    }
}
