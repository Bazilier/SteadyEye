import SwiftUI

/// In-app soft ask shown before triggering iOS's notification permission
/// prompt. Improves grant rate by pre-qualifying users before the system
/// prompt — once the user denies the system prompt, we lose the surface
/// for the lifetime of the install.
struct SoftAskNotificationView: View {
    @Environment(\.dismiss) private var dismiss
    let onAllow: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 16)

            Image(systemName: "bell.badge")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .padding(.bottom, 8)

            Text("notifications.soft_ask.title")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("notifications.soft_ask.body")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    AppAnalytics.log("push_soft_ask_accepted")
                    onAllow()
                    dismiss()
                } label: {
                    Text("notifications.soft_ask.allow")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button {
                    AppAnalytics.log("push_soft_ask_dismissed")
                    dismiss()
                } label: {
                    Text("notifications.soft_ask.not_now")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .padding(.top, 24)
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.visible)
        .onAppear {
            AppAnalytics.log("push_soft_ask_shown")
        }
    }
}
