import Foundation
import Combine

/// Owns chunk advancement scheduling, independent of display views.
/// Views observe published properties to render the current chunk.
final class ChunkPlayerEngine: ObservableObject {
    @Published var currentChunkIndex = 0
    @Published var isPlaying = false
    @Published private(set) var chunks: [String] = []
    @Published var progress: Double = 0

    var sliderValue: Double = 0.5

    private var advanceTask: Task<Void, Never>?

    // MARK: - Public API

    func loadScript(_ text: String) {
        advanceTask?.cancel()
        chunks = WordChunkEngine.chunks(from: text)
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

    /// Pause chunk marker — displayed as empty/subtle, fixed 1.5s duration.
    static let pauseMarker = "//"

    static func isPause(_ chunk: String) -> Bool {
        chunk.trimmingCharacters(in: .whitespaces) == pauseMarker
    }

    // MARK: - Duration calculation

    /// Returns display duration for a chunk, handling pauses, abbreviations, and sentence ends.
    func chunkDuration(_ chunk: String) -> TimeInterval {
        if Self.isPause(chunk) { return 0.5 }

        let trimmed = chunk.trimmingCharacters(in: .punctuationCharacters)
        let endsSentence = chunk.hasSuffix(".") || chunk.hasSuffix("!") || chunk.hasSuffix("?")

        // Abbreviation: all uppercase letters (optionally with dots), 2-6 chars
        if trimmed.count >= 2 && trimmed.count <= 6
            && trimmed == trimmed.uppercased()
            && trimmed.allSatisfy({ $0.isLetter || $0 == "." }) {
            let letterCount = trimmed.filter { $0.isLetter }.count
            let effectiveCharCount = letterCount * 3
            var d = WordChunkEngine.duration(for: String(repeating: "x", count: effectiveCharCount), sliderValue: sliderValue)
            if endsSentence { d += 0.3 }
            return d
        }

        // Normal chunk
        var d = WordChunkEngine.duration(for: chunk, sliderValue: sliderValue)
        if endsSentence { d += 0.3 }
        return d
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
                // Finished
                self.progress = 1
                self.isPlaying = false
            }
        }
    }
}
