import Foundation
import Combine

/// Owns chunk advancement scheduling, independent of display views.
final class ChunkPlayerEngine: ObservableObject {
    @Published var currentChunkIndex = 0
    @Published var isPlaying = false
    @Published private(set) var chunks: [String] = []
    @Published var progress: Double = 0

    var sliderValue: Double = 0.5
    private var strategy: LanguageStrategy = LatinLanguageStrategy()
    private var advanceTask: Task<Void, Never>?

    // MARK: - Public API

    func loadScript(_ text: String) {
        advanceTask?.cancel()
        strategy = LanguageDetector.detect(text)
        chunks = strategy.chunks(from: text)
        currentChunkIndex = 0
        progress = 0
        isPlaying = false
    }

    func play() {
        guard !chunks.isEmpty else { return }
        if currentChunkIndex >= chunks.count {
            currentChunkIndex = 0
            progress = 0
        }
        isPlaying = true
        scheduleAdvance()
    }

    func pause() {
        isPlaying = false
        advanceTask?.cancel()
        advanceTask = nil
    }

    func reset() {
        pause()
        currentChunkIndex = 0
        progress = 0
    }

    func seekTo(index: Int) {
        let wasPlaying = isPlaying
        advanceTask?.cancel()
        advanceTask = nil
        currentChunkIndex = min(max(0, index), max(0, chunks.count - 1))
        progress = chunks.isEmpty ? 0 : Double(currentChunkIndex) / Double(chunks.count)
        if wasPlaying {
            scheduleAdvance()
        }
    }

    // MARK: - Pause marker (language-independent)

    nonisolated(unsafe) static let pauseMarker = "//"

    nonisolated static func isPause(_ chunk: String) -> Bool {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "//" || trimmed == "／／"  // halfwidth and fullwidth
    }

    // MARK: - Duration calculation

    /// Pure static duration calculation using a strategy.
    nonisolated static func calculateDuration(
        for chunk: String,
        sliderValue: Double,
        strategy: (any LanguageStrategy)? = nil
    ) -> TimeInterval {
        if isPause(chunk) { return 0.5 }

        let strat = strategy ?? LanguageDetector.detect(chunk)
        let msPerChar = WordChunkEngine.msPerChar(forSlider: sliderValue)
        var d = strat.duration(for: chunk, msPerChar: msPerChar)
        d = max(strat.minimumDuration, d)

        if strat.endsSentence(chunk) {
            d += strat.sentencePauseDuration
        }

        return d
    }

    /// Instance convenience — uses the script's detected strategy.
    func chunkDuration(_ chunk: String) -> TimeInterval {
        Self.calculateDuration(for: chunk, sliderValue: sliderValue, strategy: strategy)
    }

    // MARK: - Internal scheduling

    private func scheduleAdvance() {
        advanceTask?.cancel()
        guard currentChunkIndex < chunks.count, isPlaying else { return }

        let chunk = chunks[currentChunkIndex]
        let duration = chunkDuration(chunk)

        advanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isPlaying else { return }

            let next = self.currentChunkIndex + 1
            if next < self.chunks.count {
                self.currentChunkIndex = next
                self.progress = Double(next) / Double(self.chunks.count)
                self.scheduleAdvance()
            } else {
                self.progress = 1
                self.isPlaying = false
            }
        }
    }
}
