import SwiftUI

/// First-run tip as a bottom sheet sized to its content: icon, title, a line
/// or two, and one button. Swipe down or the button dismisses it; either way
/// `onDismiss` runs once, after the sheet is gone. Replaces the old modal tip
/// card, which dimmed the screen and blocked it until read.
///
/// `allowsBackgroundInteraction` keeps the screen behind usable, so a tip can
/// sit there while the user tries what it describes.
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
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            CoachSheetContent(
                icon: icon,
                title: title,
                message: message,
                buttonLabel: buttonLabel,
                allowsBackgroundInteraction: allowsBackgroundInteraction,
                dismiss: { isPresented.wrappedValue = false }
            )
        }
    }
}

private struct CoachSheetContent: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let buttonLabel: LocalizedStringKey
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
                Text(title)
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) {
                Text(buttonLabel)
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
