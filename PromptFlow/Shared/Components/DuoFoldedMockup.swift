import SwiftUI

/// A folded iPhone Duo showing the camera screen as the app draws it there:
/// the prompter pill at the lens, cycling `phrase`, and the record button.
/// Onboarding on the unfolded Duo shows it beside the steps, since filming
/// happens folded (frame proportions from the simulator's device art,
/// titanium from the product photo). All sizes scale with `width`.
struct DuoFoldedMockup: View {
    /// Words cycled in the pill. Nil: the "your script will appear here"
    /// placeholder.
    var phrase: String?
    var eyeContact = true
    var width: CGFloat = 250

    /// The art is drawn on a 250 × 350 grid.
    private var k: CGFloat { width / 250 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Hinge, then the buttons on the top and trailing edges.
            RoundedRectangle(cornerRadius: 3 * k)
                .fill(LinearGradient(colors: [Self.hingeDark, Self.hingeLight, Self.hingeMid], startPoint: .leading, endPoint: .trailing))
                .frame(width: 8 * k, height: 326 * k)
                .offset(x: 0.5 * k, y: 12 * k)
            Capsule().fill(Self.hingeMid)
                .frame(width: 31 * k, height: 4 * k)
                .offset(x: 114 * k, y: 1.5 * k)
            Capsule().fill(Self.hingeMid)
                .frame(width: 31 * k, height: 4 * k)
                .offset(x: 153 * k, y: 1.5 * k)
            Capsule().fill(Self.hingeMid)
                .frame(width: 4 * k, height: 55 * k)
                .offset(x: 244.5 * k, y: 103 * k)

            shape(leading: 7, trailing: 38)
                .fill(LinearGradient(colors: [Self.titaniumLight, Self.titaniumDark, Self.titaniumMid], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(shape(leading: 7, trailing: 38).stroke(Self.titaniumEdge, lineWidth: 0.8 * k))
                .frame(width: 242 * k, height: 342 * k)
                .offset(x: 4 * k, y: 4 * k)
            shape(leading: 5, trailing: 36)
                .fill(Color(white: 0.02))
                .frame(width: 238 * k, height: 338 * k)
                .offset(x: 6 * k, y: 6 * k)
            screen
                .frame(width: 226 * k, height: 326 * k)
                .clipShape(shape(leading: 3, trailing: 31))
                .offset(x: 12 * k, y: 12 * k)
        }
        .frame(width: 250 * k, height: 350 * k, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// The screen, in its own 226 × 326 grid.
    private var screen: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(red: 0.23, green: 0.22, blue: 0.2), Color(red: 0.13, green: 0.11, blue: 0.1), Color(red: 0.05, green: 0.04, blue: 0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
            // Someone in front of the camera.
            Circle()
                .fill(Color.white.opacity(0.09))
                .frame(width: 80 * k, height: 80 * k)
                .offset(x: 73 * k, y: 116 * k)
            UnevenRoundedRectangle(topLeadingRadius: 68 * k, topTrailingRadius: 68 * k, style: .continuous)
                .fill(Color.white.opacity(0.09))
                .frame(width: 136 * k, height: 112 * k)
                .offset(x: 45 * k, y: 214 * k)

            pill
                .frame(width: 143 * k, height: 62 * k)
                .offset(x: 72 * k, y: 6 * k)

            recordButton
                .frame(width: 54 * k, height: 54 * k)
                .offset(x: 86 * k, y: 246 * k)
        }
    }

    private var pill: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13 * k, style: .continuous).fill(Color.black)
            PlaceholderLoopView(fontSize: 14 * k, isClassicMode: true, phrase: phrase, textOpacity: 1)
                // It reads the phrase once, as it appears.
                .id(phrase)
                .frame(width: 100 * k)
                .clipped()
            Image(systemName: "chevron.up")
                .font(.system(size: 6 * k, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 9 * k)
            Image(systemName: "eye")
                .font(.system(size: 8 * k, weight: .semibold))
                .foregroundStyle(eyeContact ? Color.green : .white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 7 * k)
                .padding(.bottom, 8 * k)
            // The outer camera, in the pill's top-trailing corner.
            Circle()
                .fill(Color(white: 0.04))
                .overlay(Circle().stroke(Color(white: 0.16), lineWidth: 1.5 * k))
                .overlay(Circle().fill(Color(red: 0.1, green: 0.16, blue: 0.22)).frame(width: 4 * k, height: 4 * k))
                .frame(width: 11 * k, height: 11 * k)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 5.5 * k)
                .padding(.trailing, 8.5 * k)
        }
    }

    private var recordButton: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Theme.accent.opacity(0.55), Theme.accent.opacity(0)], center: .center, startRadius: 14 * k, endRadius: 27 * k))
            Circle().fill(Color(red: 0.48, green: 0.21, blue: 0.1)).frame(width: 42 * k, height: 42 * k)
            Circle().fill(Color(white: 0.05))
                .overlay(Circle().stroke(.white, lineWidth: 2.4 * k))
                .frame(width: 35 * k, height: 35 * k)
            Circle().fill(Theme.accent).frame(width: 26 * k, height: 26 * k)
        }
    }

    /// Small corners on the hinge side, large ones on the other.
    private func shape(leading: CGFloat, trailing: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: leading * k,
            bottomLeadingRadius: leading * k,
            bottomTrailingRadius: trailing * k,
            topTrailingRadius: trailing * k,
            style: .continuous
        )
    }

    private static let titaniumLight = Color(red: 0.89, green: 0.87, blue: 0.83)
    private static let titaniumDark = Color(red: 0.73, green: 0.70, blue: 0.65)
    private static let titaniumMid = Color(red: 0.84, green: 0.81, blue: 0.76)
    private static let titaniumEdge = Color(red: 0.54, green: 0.52, blue: 0.47)
    private static let hingeDark = Color(red: 0.55, green: 0.53, blue: 0.48)
    private static let hingeLight = Color(red: 0.91, green: 0.89, blue: 0.85)
    private static let hingeMid = Color(red: 0.64, green: 0.61, blue: 0.56)
}
