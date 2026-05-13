import Foundation
import Combine

/// Owns chunk advancement scheduling, independent of display views.
@MainActor
final class ChunkPlayerEngine: ObservableObject {
    @Published var currentChunkIndex = 0
    @Published var isPlaying = false
    @Published private(set) var chunks: [String] = []
    /// Parallel array to `chunks` carrying per-chunk speed multiplier
    /// (from `{N}` markers) and extra pause (from `///` markers).
    /// Always the same length as `chunks` after `loadScript`. Populated
    /// by `MarkerPreprocessor` on the Latin path; defaults (no-effect
    /// metadata) on Arabic/CJK paths so the marker feature is Latin-only
    /// at v1 without crashing other scripts.
    private var chunkMetadata: [ChunkMetadata] = []
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
        chunkMetadata = [ChunkMetadata()]
        currentChunkIndex = 0
        progress = 0
        isPlaying = false
        isReady = false

        loadedScriptText = text
        let scriptText = text
        let orpMode = orpEnabled
        let baseSpeed = orpBaseSpeedMs
        loadTask = Task { [weak self] in
            // Detect strategy + chunk on background. Latin scripts run
            // through MarkerPreprocessor so `{N}` and `///` resolve to
            // chunkMetadata; non-Latin scripts skip preprocessing and
            // emit no-effect metadata (markers stay in text as-is).
            let result: (chunks: [String], metadata: [ChunkMetadata]) = await Task.detached {
                let strat = LanguageDetector.detect(scriptText)
                if strat is LatinLanguageStrategy {
                    let chunker: (String) -> [String]
                    if orpMode && strat.supportsORP {
                        chunker = { strat.chunksPerWord(text: $0, baseSpeedMs: baseSpeed) }
                    } else {
                        chunker = { strat.chunks(from: $0) }
                    }
                    return MarkerPreprocessor.process(rawText: scriptText, chunker: chunker)
                } else {
                    let chunks: [String]
                    if orpMode && strat.supportsORP {
                        chunks = strat.chunksPerWord(text: scriptText, baseSpeedMs: baseSpeed)
                    } else {
                        chunks = strat.chunks(from: scriptText)
                    }
                    return (chunks, Array(repeating: ChunkMetadata(), count: chunks.count))
                }
            }.value
            guard let self else { return }
            // Strategy is cheap to recreate on MainActor
            self.strategy = LanguageDetector.detect(scriptText)
            self.chunks = result.chunks
            self.chunkMetadata = result.metadata
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

    /// Per-chunk duration, composed from:
    ///   base (slider × strategy)
    ///     ÷ markerMul (from `{N}` inline marker)
    ///     ÷ externalSpeedMultiplier (FMV2)
    ///     + extraPauseSec (from `///` inline marker, NOT scaled)
    /// markerMul and externalSpeedMultiplier multiply together to form
    /// the divisor — slowdowns stack, speedups stack, mixing slows-and-
    /// speeds-at-once partially cancel. The combined divisor is floored
    /// at 0.1 so a pathological 0× can't divide by zero.
    func chunkDuration(at index: Int) -> TimeInterval {
        guard index >= 0, index < chunks.count else { return 0 }
        let chunk = chunks[index]
        let meta = (index < chunkMetadata.count) ? chunkMetadata[index] : ChunkMetadata()

        let base: TimeInterval
        if useORPPath {
            base = strategy.durationPerWord(chunk: chunk, baseSpeedMs: orpBaseSpeedMs)
        } else {
            base = ChunkTimingCalculator.calculateDuration(for: chunk, sliderValue: sliderValue, strategy: strategy)
        }
        let combinedMul = max(externalSpeedMultiplier * meta.speedMultiplier, 0.1)
        return base / combinedMul + meta.extraPauseSec
    }

    // MARK: - Internal scheduling

    private func scheduleAdvance() {
        advanceTask?.cancel()
        guard currentChunkIndex < chunks.count, isPlaying else { return }
        guard !externallyFrozen else { return }

        let duration = chunkDuration(at: currentChunkIndex)

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
