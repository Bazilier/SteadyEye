import SwiftUI

struct SplashView: View {
    private let emojis = ["🎬", "👀", "🎥", "📱"]
    private let columns = 6
    private let rows = 12

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0, green: 0, blue: 0),
                         Color(red: 0.1, green: 0.04, blue: 0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<columns, id: \.self) { col in
                            let index = (row * columns + col) % emojis.count
                            Text(emojis[index])
                                .font(.system(size: 40))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            .opacity(0.2)
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
    }
}
