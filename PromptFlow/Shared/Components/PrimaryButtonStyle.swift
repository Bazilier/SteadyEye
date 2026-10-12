import SwiftUI

/// The app's primary CTA: accent capsule, minHeight 54, semibold body label
/// in `Theme.onAccent`. Apply with `.primaryButtonStyle()`, which picks the
/// system glass prominent style on iOS 26+ and this capsule elsewhere.
///
/// The label gets `.tint(Theme.onAccent)` so a `ProgressView` swapped into
/// it stays visible on the accent fill.
struct PrimaryButtonStyle: ButtonStyle {
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, fullWidth: fullWidth)
    }

    // `isEnabled` is only reliable from inside a View, not the style itself.
    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .tint(Theme.onAccent)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 54)
                .background(Theme.accent, in: Capsule())
                .contentShape(Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
        }
    }
}

/// iOS 26+ variant: the system `.glassProminent` style tinted with the
/// accent. `GlassProminentButtonStyle` is a `PrimitiveButtonStyle`, so it
/// can't be returned from a `ButtonStyle`; this re-wraps the label in a
/// `Button` instead.
@available(iOS 26.0, *)
private struct GlassPrimaryButtonStyle: PrimitiveButtonStyle {
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .tint(Theme.onAccent)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: GlassPrimaryButtonStyle.labelMinHeight)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(Theme.accent)
    }

    /// 54 minus the 7pt top/bottom inset `.glassProminent` adds around the
    /// label (measured on the iOS 26.2 simulator), so the rendered capsule
    /// matches the custom style's height.
    static let labelMinHeight: CGFloat = 40
}

extension View {
    /// Primary CTA styling. `fullWidth: false` keeps the label's intrinsic
    /// width (empty-state buttons).
    @ViewBuilder
    func primaryButtonStyle(fullWidth: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(GlassPrimaryButtonStyle(fullWidth: fullWidth))
        } else {
            buttonStyle(PrimaryButtonStyle(fullWidth: fullWidth))
        }
    }
}
