import SwiftUI

enum ToastStyle {
    case success
    case error
    case info

    var iconName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .success: return .green
        case .error: return .red
        case .info: return .blue
        }
    }
}

struct ToastView: View {
    let message: String
    let style: ToastStyle
    let onDismiss: () -> Void
    let actionLabel: String?
    let action: (() -> Void)?

    init(
        message: String,
        style: ToastStyle,
        onDismiss: @escaping () -> Void,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.message = message
        self.style = style
        self.onDismiss = onDismiss
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: style.iconName)
                .foregroundStyle(style.iconColor)
                .font(.system(size: 18, weight: .semibold))

            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)

            Spacer(minLength: 8)

            if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 24)
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}

/// Modifier to bind a toast to a Bool with auto-dismiss after a duration.
struct ToastModifier: ViewModifier {
    @Binding var isPresented: Bool
    let message: String
    let style: ToastStyle
    let duration: TimeInterval
    let actionLabel: String?
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isPresented {
                    ToastView(
                        message: message,
                        style: style,
                        onDismiss: { withAnimation { isPresented = false } },
                        actionLabel: actionLabel,
                        action: action.map { handler in
                            {
                                handler()
                                withAnimation { isPresented = false }
                            }
                        }
                    )
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                        withAnimation { isPresented = false }
                    }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: isPresented)
    }
}

extension View {
    func toast(
        isPresented: Binding<Bool>,
        message: String,
        style: ToastStyle,
        duration: TimeInterval = 2.5,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        modifier(ToastModifier(
            isPresented: isPresented,
            message: message,
            style: style,
            duration: duration,
            actionLabel: actionLabel,
            action: action
        ))
    }
}
