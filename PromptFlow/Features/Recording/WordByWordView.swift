import SwiftUI

// MARK: - Placeholder demo loop

/// Cycles through sample words to demonstrate word-by-word display before playback starts.
struct PlaceholderLoopView: View {
    let fontSize: CGFloat

    private let words = ["Your", "script", "will", "appear", "here", "word", "by", "word"]
    @State private var currentIndex = 0
    @State private var opacity: Double = 1
    @State private var loopTask: Task<Void, Never>?

    var body: some View {
        Text(words[currentIndex])
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .opacity(opacity)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .onAppear { startLoop() }
            .onDisappear { loopTask?.cancel() }
    }

    private func startLoop() {
        loopTask?.cancel()
        currentIndex = 0
        opacity = 1
        loopTask = Task {
            while !Task.isCancelled {
                // Display current word
                try? await Task.sleep(nanoseconds: 1_100_000_000) // 1.1s display
                guard !Task.isCancelled else { return }

                // Fade out
                await MainActor.run { withAnimation(.easeOut(duration: 0.1)) { opacity = 0 } }
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }

                // Advance index
                let isLast = currentIndex == words.count - 1
                await MainActor.run { currentIndex = isLast ? 0 : currentIndex + 1 }

                // Fade in
                await MainActor.run { withAnimation(.easeIn(duration: 0.1)) { opacity = 1 } }

                // Extra pause after the last word before looping
                if isLast {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled else { return }
                }
            }
        }
    }
}

/// Pure content view — shows one word chunk at a time.
/// Has NO positioning or safe-area logic; the parent handles layout.
/// Scheduling state is isolated from recording state.
struct WordByWordView: View {

    // MARK: - Inputs
    let chunks: [String]
    let fontSize: CGFloat
    let speed: WordChunkEngine.ReadingSpeed
    @Binding var isPlaying: Bool
    @Binding var resetToken: UUID
    var onFinished: () -> Void = {}
    @Binding var currentIndex: Int

    // MARK: - Private scheduling state
    @State private var displayedText: String = ""
    @State private var finished = false
    @State private var lastResetToken: UUID = UUID()
    @State private var scheduledTask: Task<Void, Never>?

    var body: some View {
        Text(displayedText)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
        .onAppear {
            lastResetToken = resetToken
            let idx = min(currentIndex, chunks.count - 1)
            if idx >= 0 && !chunks.isEmpty { displayedText = chunks[idx] }
            // If already playing when mounted (e.g. parent uses `if isPlaying`),
            // start scheduling immediately — onChange won't fire for the initial state.
            if isPlaying && !finished {
                scheduleNext(at: currentIndex)
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                guard !finished else { return }
                scheduleNext(at: currentIndex)
            } else {
                cancelScheduled()
            }
        }
        .onChange(of: resetToken) { _, token in
            guard token != lastResetToken else { return }
            lastResetToken = token
            reset()
        }
        // Speed changes apply from the next chunk — no restart needed
    }

    // MARK: - Chunk scheduling

    private func showChunk(at index: Int) {
        guard index < chunks.count else { return }
        displayedText = chunks[index]
    }

    private func scheduleNext(at index: Int) {
        guard index < chunks.count, isPlaying else { return }

        showChunk(at: index)
        currentIndex = index

        let displayDuration = WordChunkEngine.duration(
            for: chunks[index],
            speed: speed
        )

        scheduledTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(displayDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }

            await MainActor.run { displayedText = "" }

            let gap = WordChunkEngine.gapDuration(speed: speed)
            try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                let next = index + 1
                if next < chunks.count {
                    scheduleNext(at: next)
                } else {
                    displayedText = "✓"
                    finished = true
                    isPlaying = false
                    onFinished()
                }
            }
        }
    }

    private func cancelScheduled() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }

    /// Resyncs to the current parent-owned currentIndex.
    /// Used for both full reset (parent sets index=0) and scrub seeks.
    private func reset() {
        cancelScheduled()
        finished = false
        let idx = min(currentIndex, chunks.count - 1)
        displayedText = (idx >= 0 && !chunks.isEmpty) ? chunks[idx] : ""
    }
}
