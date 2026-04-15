import Foundation
import Combine

/// Owns chunk advancement scheduling, independent of display views.
@MainActor
final class ChunkPlayerEngine: ObservableObject {
    @Published var currentChunkIndex = 0
    @Published var isPlaying = false
    @Published private(set) var chunks: [String] = []
    @Published var progress: Double = 0
    @Published var isReady = false

    var sliderValue: Double = 0.5
    @Published private(set) var supportsORP: Bool = true
    /// ORP per-word mode. Toggling this triggers re-chunking via reloadChunks().
    /// Initialised from UserDefaults so `loadScript` at startup sees the correct mode.
    var orpEnabled: Bool = (UserDefaults.standard.object(forKey: "orpAlignmentEnabled") as? Bool) ?? true
    private var strategy: any LanguageStrategy = LatinLanguageStrategy() {
        didSet { supportsORP = strategy.supportsORP }
    }
    private var loadedScriptText: String = ""
    private var advanceTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    private var orpBaseSpeedMs: Int {
        ChunkTimingCalculator.orpBaseSpeedMs(sliderValue: sliderValue)
    }

    private var useORPPath: Bool {
        orpEnabled && strategy.supportsORP
    }

    // MARK: - Public API

    func loadScript(_ text: String) {
        advanceTask?.cancel()
        loadTask?.cancel()

        chunks = ["..."]
        currentChunkIndex = 0
        progress = 0
        isPlaying = false
        isReady = false

        loadedScriptText = text
        let scriptText = text
        let orpMode = orpEnabled
        let baseSpeed = orpBaseSpeedMs
        loadTask = Task { [weak self] in
            // Detect + chunk on background, only return Sendable results
            let newChunks = await Task.detached {
                let strat = LanguageDetector.detect(scriptText)
                if orpMode && strat.supportsORP {
                    return strat.chunksPerWord(text: scriptText, baseSpeedMs: baseSpeed)
                } else {
                    return strat.chunks(from: scriptText)
                }
            }.value
            guard let self else { return }
            // Strategy is cheap to recreate on MainActor
            self.strategy = LanguageDetector.detect(scriptText)
            self.chunks = newChunks
            self.currentChunkIndex = 0
            self.isReady = true
        }
    }

    /// Re-chunk the currently loaded script, e.g. after ORP toggle.
    /// Resets playback to chunk 0.
    func reloadChunks() {
        guard !loadedScriptText.isEmpty else { return }
        let wasPlaying = isPlaying
        advanceTask?.cancel()
        advanceTask = nil
        isPlaying = false
        loadScript(loadedScriptText)
        if wasPlaying {
            Task { @MainActor [weak self] in
                // Wait for async loadTask to finish
                try? await Task.sleep(nanoseconds: 50_000_000)
                self?.play()
            }
        }
    }

    func play() {
        guard isReady, !chunks.isEmpty, !isPlaying else { return }
        if currentChunkIndex >= chunks.count {
            currentChunkIndex = 0
            progress = 0
        }
        isPlaying = true
        scheduleAdvance()
    }

    func pause() {
        advanceTask?.cancel()
        advanceTask = nil
        isPlaying = false
    }

    func reset() {
        advanceTask?.cancel()
        advanceTask = nil
        isPlaying = false
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

    // MARK: - Duration

    func chunkDuration(_ chunk: String) -> TimeInterval {
        if useORPPath {
            return strategy.durationPerWord(chunk: chunk, baseSpeedMs: orpBaseSpeedMs)
        }
        return ChunkTimingCalculator.calculateDuration(for: chunk, sliderValue: sliderValue, strategy: strategy)
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
