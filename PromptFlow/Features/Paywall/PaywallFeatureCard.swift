import SwiftUI

struct PaywallFeatureCard: View {
    let icon: String       // SF Symbol name
    let title: String      // already-localized display string
    let subtitle: String   // already-localized display string

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 80, weight: .semibold))
                .foregroundColor(Color(red: 0.85, green: 0.35, blue: 0.05))   // darker burnt orange

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2).bold()
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .frame(height: 280)
        .background(Color.orange)
        .cornerRadius(20)
    }
}
