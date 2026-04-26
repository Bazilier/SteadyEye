import SwiftUI
import Combine

// ORP formula copied from ORPAlignment.orpIndex(for:) — keep in sync if production logic changes.
private func miniORPIndex(for word: String) -> Int {
    let clean = word.trimmingCharacters(in: .punctuationCharacters)
    let len = clean.count
    switch len {
    case 0...1: return 0
    case 2...5: return 1
    case 6...9: return 2
    case 10...13: return 3
    default: return 4
    }
}

struct MiniWBWView: View {
    private let words: [String] = MiniWBWView.loadWords()

    @State private var currentIndex: Int = 0
    @State private var pausedUntil: Date? = nil

    private let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black)
            wordContent
                .font(.system(.title2, design: .monospaced).weight(.semibold))
        }
        .frame(width: 280, height: 56)
        .onReceive(timer) { _ in advance() }
        .onDisappear { timer.upstream.connect().cancel() }
    }

    @ViewBuilder
    private var wordContent: some View {
        let word = currentIndex < words.count ? words[currentIndex] : ""
        if word.isEmpty {
            Text(" ").foregroundStyle(.clear)
        } else if word.count > 12 {
            // Mirrors ORPWord fallback: long words render plain without ORP highlight.
            Text(word).foregroundStyle(.white)
        } else {
            let idx = min(miniORPIndex(for: word), max(0, word.count - 1))
            let chars = Array(word)
            let prefix = String(chars[0..<idx])
            let anchor = String(chars[idx])
            let suffix = idx + 1 <= chars.count - 1 ? String(chars[(idx + 1)...]) : ""
            // Pin the orange anchor char to the container's horizontal center.
            // Prefix and suffix occupy equal flexible slots that absorb the
            // remaining width, forcing the anchor to the exact midpoint.
            HStack(spacing: 0) {
                Text(prefix)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(anchor)
                    .foregroundStyle(.orange)
                Text(suffix)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func advance() {
        if let until = pausedUntil, Date() < until { return }
        pausedUntil = nil
        currentIndex += 1
        if currentIndex >= words.count {
            currentIndex = 0
            pausedUntil = Date().addingTimeInterval(0.6)
        }
    }

    private static func loadWords() -> [String] {
        let content = String(
            localized: "onboarding.mini_wbw.script",
            defaultValue: "You're reading right now without moving your eyes. That's the whole trick."
        )
        return content
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
