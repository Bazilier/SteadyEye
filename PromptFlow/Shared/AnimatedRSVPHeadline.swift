import SwiftUI
import Combine

/// Word-by-word headline animator. Two modes: looping (onboarding's preview
/// pill) and play-once-then-settle (paywall headline). Encapsulates the timer-
/// driven sequencing, optional ORP-style anchor-letter highlight, and optional
/// full-phrase space reservation to prevent layout shift when settling.
struct AnimatedRSVPHeadline: View {
    let text: String
    let font: Font
    let textColor: Color
    let highlightColor: Color
    let tickInterval: Double
    let loops: Bool
    let endHoldSeconds: Double
    let useORPHighlight: Bool
    /// When true, an invisible Text("text") overlay reserves the full-phrase
    /// frame size during the animating phase so the layout doesn't reflow when
    /// the view transitions to its settled state. Use for content-driven
    /// layouts (paywall). For fixed-size containers (onboarding's 280×56 pill)
    /// leave at the default `false` — the outer frame already constrains size.
    let reserveFullPhraseSpace: Bool

    @State private var currentIndex: Int = 0
    @State private var pausedUntil: Date? = nil
    @State private var isSettled: Bool = false

    private let timer: Publishers.Autoconnect<Timer.TimerPublisher>

    init(
        text: String,
        font: Font,
        textColor: Color = .white,
        highlightColor: Color = .orange,
        tickInterval: Double = 0.28,
        loops: Bool = true,
        endHoldSeconds: Double = 0.6,
        useORPHighlight: Bool = true,
        reserveFullPhraseSpace: Bool = false
    ) {
        self.text = text
        self.font = font
        self.textColor = textColor
        self.highlightColor = highlightColor
        self.tickInterval = tickInterval
        self.loops = loops
        self.endHoldSeconds = endHoldSeconds
        self.useORPHighlight = useORPHighlight
        self.reserveFullPhraseSpace = reserveFullPhraseSpace
        self.timer = Timer.publish(every: tickInterval, on: .main, in: .common).autoconnect()
    }

    private var words: [String] {
        text.split { $0.isWhitespace || $0.isNewline }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    var body: some View {
        Group {
            if isSettled {
                Text(text)
                    .font(font)
                    .foregroundStyle(textColor)
            } else if reserveFullPhraseSpace {
                ZStack(alignment: .topLeading) {
                    // Invisible placeholder reserves the settled-state frame size.
                    Text(text)
                        .font(font)
                        .foregroundStyle(.clear)
                    wordContent
                }
            } else {
                wordContent
            }
        }
        .onReceive(timer) { _ in advance() }
        .onDisappear { timer.upstream.connect().cancel() }
    }

    @ViewBuilder
    private var wordContent: some View {
        let word = currentIndex < words.count ? words[currentIndex] : ""
        if word.isEmpty {
            Text(" ")
                .font(font)
                .foregroundStyle(.clear)
        } else if !useORPHighlight || word.count > 12 {
            Text(word)
                .font(font)
                .foregroundStyle(textColor)
        } else {
            let idx = min(headlineORPIndex(for: word), max(0, word.count - 1))
            let chars = Array(word)
            let prefix = String(chars[0..<idx])
            let anchor = String(chars[idx])
            let suffix = idx + 1 <= chars.count - 1 ? String(chars[(idx + 1)...]) : ""
            // Pin the highlight char to the container's horizontal center —
            // prefix and suffix occupy equal flexible slots.
            HStack(spacing: 0) {
                Text(prefix)
                    .foregroundStyle(textColor)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(anchor)
                    .foregroundStyle(highlightColor)
                Text(suffix)
                    .foregroundStyle(textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(font)
        }
    }

    private func advance() {
        if isSettled { return }
        if let until = pausedUntil, Date() < until { return }
        pausedUntil = nil
        currentIndex += 1
        if currentIndex >= words.count {
            if loops {
                currentIndex = 0
                pausedUntil = Date().addingTimeInterval(endHoldSeconds)
            } else {
                isSettled = true
            }
        }
    }
}

// ORP formula — copied from ORPAlignment.orpIndex(for:) — keep in sync if production logic changes.
private func headlineORPIndex(for word: String) -> Int {
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
