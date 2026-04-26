import SwiftUI

struct SplashView: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(red: 1.0, green: 0.42, blue: 0.17), location: 0.0),
                        .init(color: Color(red: 0.78, green: 0.20, blue: 0.10), location: 0.5),
                        .init(color: Color(red: 0.30, green: 0.05, blue: 0.03), location: 1.0)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height)
                )
                Image("Icon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 16, x: 0, y: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}
