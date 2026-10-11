import SwiftUI

/// App-wide design tokens. Colors resolve through the asset catalog
/// (`AccentColor` = #FD572D, same value for Any and Dark), so sheets and
/// system controls that read the accent pick up the brand orange without
/// a `.tint` being inherited.
enum Theme {
    static let accent = Color.accentColor
    /// Tinted fill behind icons and badges.
    static let accentTint = accent.opacity(0.18)
    /// Label color on accent fills. White fails contrast on this orange.
    static let onAccent = Color.black
    /// Semantic warning/caution state (system orange). Not the brand accent.
    static let warning = Color.orange

    enum Radius {
        static let chip: CGFloat = 8
        static let small: CGFloat = 12
        static let medium: CGFloat = 18
        static let card: CGFloat = 26
    }
}
