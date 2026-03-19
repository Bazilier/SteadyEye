import SwiftUI

// MARK: - Placeholder demo loop (mode-aware)

struct PlaceholderLoopView: View {
    let fontSize: CGFloat
    let isClassicMode: Bool

    private let words = ["Your", "script", "will", "appear", "here"]
    @State private var currentIndex = 0
    @State private var opacity: Double = 1
    @State private var scrollOffset: CGFloat = 0
    @State private var loopTask: Task<Void, Never>?

    private let lineHeight: CGFloat = 28

    var body: some View {
        Group {
            if isClassicMode {
                classicPlaceholder
            } else {
                wbwPlaceholder
            }
        }
        .onAppear { startLoop() }
        .onDisappear { loopTask?.cancel() }
        .onChange(of: isClassicMode) { _, _ in
            // Restart loop after container animation settles
            loopTask?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                startLoop()
            }
        }
    }

    // MARK: - WbW placeholder

    private var wbwPlaceholder: some View {
        Text(words[currentIndex])
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .opacity(opacity)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
    }

    // MARK: - Classic placeholder

    private var classicPlaceholder: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { slot in
                let idx = currentIndex - 1 + slot
                let wrapped = ((idx % words.count) + words.count) % words.count
                Text(idx < 0 ? "" : words[wrapped])
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(classicSlotOpacity(slot) * 0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)
                    .frame(height: lineHeight)
            }
        }
        .offset(y: -scrollOffset)
        .frame(height: lineHeight * 3, alignment: .top)
        .clipped()
        .padding(.horizontal, 16)
    }

    private func classicSlotOpacity(_ slot: Int) -> Double {
        switch slot {
        case 0: return 0.3
        case 1: return 1.0
        case 2: return 0.6
        default: return 0.0
        }
    }

    // MARK: - Loop

    private func startLoop() {
        loopTask?.cancel()
        currentIndex = 0
        opacity = 1
        scrollOffset = 0

        loopTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }

                if isClassicMode {
                    // Scroll up
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.3)) { scrollOffset = lineHeight }
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    let isLast = currentIndex == words.count - 1
                    await MainActor.run {
                        scrollOffset = 0
                        currentIndex = isLast ? 0 : currentIndex + 1
                    }
                    if isLast {
                        try? await Task.sleep(nanoseconds: 750_000_000)
                        guard !Task.isCancelled else { return }
                    }
                } else {
                    // WbW crossfade
                    await MainActor.run { withAnimation(.easeOut(duration: 0.1)) { opacity = 0 } }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { return }
                    let isLast = currentIndex == words.count - 1
                    await MainActor.run { currentIndex = isLast ? 0 : currentIndex + 1 }
                    await MainActor.run { withAnimation(.easeIn(duration: 0.1)) { opacity = 1 } }
                    if isLast {
                        try? await Task.sleep(nanoseconds: 750_000_000)
                        guard !Task.isCancelled else { return }
                    }
                }
            }
        }
    }
}

// MARK: - Word-by-word display (rendering only)

struct WordByWordView: View {
    @ObservedObject var player: ChunkPlayerEngine
    let fontSize: CGFloat

    @State private var displayedText: String = ""
    @State private var textOpacity: Double = 1
    @State private var lastIndex: Int = -1

    var body: some View {
        Text(displayedText)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .opacity(textOpacity)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .onAppear { syncToPlayer() }
            .onChange(of: player.currentChunkIndex) { _, _ in
                crossfadeToCurrentChunk()
            }
    }

    private func syncToPlayer() {
        let idx = player.currentChunkIndex
        if idx >= 0, idx < player.chunks.count {
            displayedText = player.chunks[idx]
        }
        textOpacity = 1
        lastIndex = idx
    }

    private func crossfadeToCurrentChunk() {
        let idx = player.currentChunkIndex
        guard idx != lastIndex else { return }
        lastIndex = idx

        guard idx < player.chunks.count else {
            displayedText = "✓"
            textOpacity = 1
            return
        }

        withAnimation(.easeInOut(duration: 0.08)) { textOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            displayedText = player.chunks[idx]
            withAnimation(.easeInOut(duration: 0.08)) { textOpacity = 1 }
        }
    }
}

// MARK: - Classic 3-line display (rendering only)

struct ClassicThreeLineView: View {
    @ObservedObject var player: ChunkPlayerEngine

    @State private var displayIndex: Int = 0
    @State private var scrollOffset: CGFloat = 0

    private let lineFontSize: CGFloat = 22
    private let lineHeight: CGFloat = 28

    private func chunkText(at i: Int) -> String {
        guard i >= 0, i < player.chunks.count else { return "" }
        return player.chunks[i]
    }

    private func lineOpacity(_ slot: Int) -> Double {
        switch slot {
        case 0: return 0.3
        case 1: return 1.0
        case 2: return 0.6
        default: return 0.0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { slot in
                let chunkIdx = displayIndex - 1 + slot
                Text(chunkText(at: chunkIdx))
                    .font(.system(size: lineFontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(lineOpacity(slot))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity)
                    .frame(height: lineHeight)
            }
        }
        .offset(y: -scrollOffset)
        .frame(height: lineHeight * 3, alignment: .top)
        .clipped()
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .onAppear {
            displayIndex = player.currentChunkIndex
            scrollOffset = 0
        }
        .onChange(of: player.currentChunkIndex) { _, newIdx in
            guard newIdx != displayIndex else { return }
            animateScrollTo(newIdx)
        }
    }

    private func animateScrollTo(_ newIdx: Int) {
        // Scroll up one slot
        withAnimation(.easeInOut(duration: 0.25)) {
            scrollOffset = lineHeight
        }
        // After animation, snap to new position
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            scrollOffset = 0
            displayIndex = newIdx
        }
    }
}
