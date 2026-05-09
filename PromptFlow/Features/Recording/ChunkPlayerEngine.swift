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

    /// External freeze, owned by FollowMyVoiceServiceV2. Independent of
    /// `isPlaying` so a user-initiated pause and a voice-driven freeze
    /// don't clobber each other. Flipping back to false re-fires the
    /// advance loop without resetting the cursor.
    var externallyFrozen: Bool = false {
        didSet {
            guard oldValue != externallyFrozen else { return }
            if !externallyFrozen, isPlaying { scheduleAdvance() }
        }
    }

    /// External speed multiplier (1.0 = no change, >1.0 = faster).
    /// Currently only set by FollowMyVoiceServiceV2 for pace tracking. Composed
    /// multiplicatively with the slider-derived base duration.
    /// Published so the recording UI can react (visual slider thumb).
    @Published var externalSpeedMultiplier: Double = 1.0

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

    /// Baseline duration per typical word at the current slider position,
    /// IGNORING `externalSpeedMultiplier`. Used by FMV2 to compute a
    /// target multiplier from measured user WPM:
    ///   target = baseline × measuredWPM × leadFactor / 60
    /// Returns the per-word time the engine would spend if the multiplier
    /// were 1.0. ORP path uses the slider-derived `orpBaseSpeedMs`
    /// directly; non-ORP path uses a representative short word ("the")
    /// against the same slider/strategy math the engine uses internally.
    func averageBaselineDurationPerWord() -> TimeInterval {
        if useORPPath {
            return TimeInterval(orpBaseSpeedMs) / 1000.0
        } else {
            return ChunkTimingCalculator.calculateDuration(for: "the", sliderValue: sliderValue, strategy: strategy)
        }
    }

    func chunkDuration(_ chunk: String) -> TimeInterval {
        let base: TimeInterval
        if useORPPath {
            base = strategy.durationPerWord(chunk: chunk, baseSpeedMs: orpBaseSpeedMs)
        } else {
            base = ChunkTimingCalculator.calculateDuration(for: chunk, sliderValue: sliderValue, strategy: strategy)
        }
        // multiplier > 1 means faster → shorter duration. Floor at 0.1
        // defensively so a stuck-at-zero multiplier doesn't divide by zero.
        return base / max(externalSpeedMultiplier, 0.1)
    }

    // MARK: - Internal scheduling

    private func scheduleAdvance() {
        advanceTask?.cancel()
        guard currentChunkIndex < chunks.count, isPlaying else { return }
        guard !externallyFrozen else { return }

        let chunk = chunks[currentChunkIndex]
        let duration = chunkDuration(chunk)

        // DIAGNOSTIC: surfaces the multiplier value at the moment the
        // engine commits to a chunk-advance sleep. If `mul` here stays
        // at 1.0 while FMV2 logs say it set it to 1.6, the chain is
        // broken (different engine instance, write lost, etc.). If
        // `mul` reflects FMV2's value but the UI feels unchanged, the
        // bug is downstream (rendering / perception). Remove after
        // diagnosis.
        print("[ENGINE] chunk \(currentChunkIndex) duration=\(String(format: "%.3f", duration))s mul=\(String(format: "%.2f", externalSpeedMultiplier)) frozen=\(externallyFrozen)")

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
