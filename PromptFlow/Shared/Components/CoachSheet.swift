import SwiftUI

/// First-run tip as a bottom sheet sized to its content: icon, title, a line
/// or two, and one button. Swipe down or the button dismisses it; either way
/// `onDismiss` runs once, after the sheet is gone. Replaces the old modal tip
/// card, which dimmed the screen and blocked it until read.
///
/// `allowsBackgroundInteraction` keeps the screen behind usable, so a tip can
/// sit there while the user tries what it describes. `onPrimary` makes the
/// button do the thing the tip is about; it runs after `onDismiss`, and only
/// for the button, not a swipe.
extension View {
    func coachSheet(
        isPresented: Binding<Bool>,
        icon: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        buttonLabel: LocalizedStringKey,
        allowsBackgroundInteraction: Bool = false,
        onDismiss: @escaping () -> Void
    ) -> some View {
        coachSheet(
            isPresented: isPresented,
            icon: icon,
            title: Text(title),
            message: Text(message),
            buttonLabel: Text(buttonLabel),
            allowsBackgroundInteraction: allowsBackgroundInteraction,
            onDismiss: onDismiss
        )
    }

    func coachSheet(
        isPresented: Binding<Bool>,
        icon: String,
        title: Text,
        message: Text,
        buttonLabel: Text,
        allowsBackgroundInteraction: Bool = false,
        onDismiss: @escaping () -> Void,
        onPrimary: (() -> Void)? = nil
    ) -> some View {
        modifier(CoachSheetModifier(
            isPresented: isPresented,
            icon: icon,
            title: title,
            message: message,
            buttonLabel: buttonLabel,
            allowsBackgroundInteraction: allowsBackgroundInteraction,
            onDismiss: onDismiss,
            onPrimary: onPrimary
        ))
    }
}

private struct CoachSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let icon: String
    let title: Text
    let message: Text
    let buttonLabel: Text
    let allowsBackgroundInteraction: Bool
    let onDismiss: () -> Void
    let onPrimary: (() -> Void)?

    /// Whether this presentation closed through the button.
    @State private var primaryTapped = false

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            onDismiss()
            if primaryTapped { onPrimary?() }
            primaryTapped = false
        }) {
            CoachSheetContent(
                icon: icon,
                title: title,
                message: message,
                buttonLabel: buttonLabel,
                allowsBackgroundInteraction: allowsBackgroundInteraction,
                dismiss: {
                    primaryTapped = true
                    isPresented = false
                }
            )
        }
    }
}

private struct CoachSheetContent: View {
    let icon: String
    let title: Text
    let message: Text
    let buttonLabel: Text
    let allowsBackgroundInteraction: Bool
    let dismiss: () -> Void

    /// Measured, so the sheet is exactly as tall as what it says.
    @State private var height: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                title
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
            message
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) {
                buttonLabel
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .primaryButtonStyle()
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .presentationBackground(Color(white: 0.11))
        .presentationBackgroundInteraction(
            allowsBackgroundInteraction ? .enabled(upThrough: .height(height)) : .disabled
        )
        .preferredColorScheme(.dark)
    }
}
