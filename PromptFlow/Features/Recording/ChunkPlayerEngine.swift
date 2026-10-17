import Foundation
import Combine

/// Owns chunk advancement scheduling, independent of display views.
@MainActor
final class ChunkPlayerEngine: ObservableObject {
    @Published var currentChunkIndex = 0 {
        didSet {
            shownLog.append((currentChunkIndex, Date()))
            if shownLog.count > 64 { shownLog.removeFirst() }
        }
    }
    /// When each recent index went on screen, for `chunkIndex(shownAt:)`.
    private var shownLog: [(index: Int, at: Date)] = []
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

    /// First chunk index of each `////` section, ascending. `[0]` for a
    /// script without breaks, which never holds.
    @Published private(set) var sectionStarts: [Int] = [0]
    /// The section just read to its end, waiting for the user to replay it
    /// or go on. Set by the advance loop instead of moving past a break, and
    /// at the end of the last section too, which can only be replayed; the
    /// engine is paused while it is set. Nil otherwise.
    @Published private(set) var heldSection: Int?
    /// Take of the section on screen: 1, then one more per replay. Back to
    /// 1 whenever another section comes on screen.
    @Published private(set) var sectionTake = 1

    var sectionCount: Int { sectionStarts.count }

    var currentSection: Int { section(containing: currentChunkIndex) }

    /// Held at the end of the script: there is no section to go on to.
    var isHoldingLastSection: Bool { heldSection == sectionCount - 1 }

    /// The last word of a section, the script's last included once it has
    /// breaks at all.
    private func endsSection(_ index: Int) -> Bool {
        sectionStarts.contains(index + 1) || (sectionCount > 1 && index == chunks.count - 1)
    }

    func section(containing index: Int) -> Int {
        sectionStarts.lastIndex { $0 <= index } ?? 0
    }

    /// Chunk range of `section`, for the progress bar.
    func chunkRange(ofSection section: Int) -> Range<Int> {
        guard sectionStarts.indices.contains(section) else { return 0..<0 }
        let end = section + 1 < sectionStarts.count ? sectionStarts[section + 1] : chunks.count
        return sectionStarts[section]..<end
    }

    /// External freeze, owned by FollowMyVoiceServiceV2. Independent of
    /// `isPlaying` so a user-initiated pause and a voice-driven freeze
    /// don't clobber each other. Flipping back to false re-fires the
    /// advance loop without resetting the cursor.
    var externallyFrozen: Bool = false {
        didSet {
            guard oldValue != externallyFrozen else { return }
            if !isFrozen, isPlaying { scheduleAdvance() }
        }
    }

    /// Freeze owned by eye-contact tracking: set while the user looks away
    /// from the lens with auto-pause on. Separate from `externallyFrozen` so
    /// it and FMV never clobber each other. Unlike FMV's freeze it stops the
    /// current word at once — the user is not reading it — and on release the
    /// word gets its full time again.
    var gazeFrozen: Bool = false {
        didSet {
            guard oldValue != gazeFrozen else { return }
            if gazeFrozen {
                advanceTask?.cancel()
                advanceTask = nil
            } else if !isFrozen, isPlaying {
                scheduleAdvance()
            }
        }
    }

    private var isFrozen: Bool { externallyFrozen || gazeFrozen }

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
    /// The chunking run for the latest `loadScript`. Readable so callers
    /// (and tests) can wait for it.
    private(set) var loadTask: Task<Void, Never>?

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
        sectionStarts = [0]
        heldSection = nil
        sectionTake = 1
        currentChunkIndex = 0
        progress = 0
        isPlaying = false
        isReady = false

        loadedScriptText = text
        let scriptText = text
        let orpMode = orpEnabled
        let baseSpeed = orpBaseSpeedMs
        loadTask = Task { [weak self] in
            // Detect strategy + chunk on background, one `////` section at
            // a time. Latin scripts run through MarkerPreprocessor so `{N}`
            // and `///` resolve to chunkMetadata; non-Latin scripts skip
            // preprocessing and emit no-effect metadata (markers stay in
            // text as-is). Section breaks apply to every script.
            let result: (chunks: [String], metadata: [ChunkMetadata], sectionStarts: [Int]) = await Task.detached {
                let strat = LanguageDetector.detect(scriptText)
                var chunks: [String] = []
                var metadata: [ChunkMetadata] = []
                var starts: [Int] = []
                for section in MarkerPreprocessor.splitSections(scriptText) {
                    let part: (chunks: [String], metadata: [ChunkMetadata])
                    if strat is LatinLanguageStrategy {
                        let chunker: (String) -> [String]
                        if orpMode && strat.supportsORP {
                            chunker = { strat.chunksPerWord(text: $0, baseSpeedMs: baseSpeed) }
                        } else {
                            chunker = { strat.chunks(from: $0) }
                        }
                        part = MarkerPreprocessor.process(rawText: section, chunker: chunker)
                    } else {
                        let sectionChunks: [String]
                        if orpMode && strat.supportsORP {
                            sectionChunks = strat.chunksPerWord(text: section, baseSpeedMs: baseSpeed)
                        } else {
                            sectionChunks = strat.chunks(from: section)
                        }
                        part = (sectionChunks, Array(repeating: ChunkMetadata(), count: sectionChunks.count))
                    }
                    guard !part.chunks.isEmpty else { continue }
                    starts.append(chunks.count)
                    chunks += part.chunks
                    metadata += part.metadata
                }
                return (chunks, metadata, starts.isEmpty ? [0] : starts)
            }.value
            // A newer loadScript cancelled this run; its chunks are stale.
            // The detached chunking above doesn't see the cancellation, so
            // check before writing.
            guard let self, !Task.isCancelled else { return }
            // Strategy is cheap to recreate on MainActor
            self.strategy = LanguageDetector.detect(scriptText)
            self.chunks = result.chunks
            self.chunkMetadata = result.metadata
            self.sectionStarts = result.sectionStarts
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
            let load = loadTask
            Task { @MainActor [weak self] in
                // Resume once the re-chunking is in; it can take far longer
                // than a frame for a long script.
                await load?.value
                self?.play()
            }
        }
    }

    func play() {
        guard isReady, !chunks.isEmpty, !isPlaying else { return }
        // Plain play during a hold goes on, as "Next" does; at the end of
        // the script it starts over.
        if isHoldingLastSection {
            seekTo(index: 0)
        } else if heldSection != nil {
            resolveHold(replay: false)
        }
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
        heldSection = nil
        sectionTake = 1
        currentChunkIndex = 0
        progress = 0
    }

    /// Moving the cursor ends a hold. The take count survives a seek within
    /// the section (the gaze rewind) and restarts on another section.
    func seekTo(index: Int) {
        let wasPlaying = isPlaying
        advanceTask?.cancel()
        advanceTask = nil
        let oldSection = currentSection
        heldSection = nil
        currentChunkIndex = min(max(0, index), max(0, chunks.count - 1))
        progress = chunks.isEmpty ? 0 : Double(currentChunkIndex) / Double(chunks.count)
        if currentSection != oldSection { sectionTake = 1 }
        if wasPlaying {
            scheduleAdvance()
        }
    }

    /// Ends a hold: back to the first word of the held section (`replay`,
    /// one more take), or on to the first word of the next. Leaves the
    /// engine paused — the caller plays once its countdown is over. Going on
    /// from the last section does nothing.
    func resolveHold(replay: Bool) {
        guard let held = heldSection, replay || held + 1 < sectionCount else { return }
        let target = replay ? held : held + 1
        let take = replay ? sectionTake + 1 : 1
        seekTo(index: sectionStarts[target])
        sectionTake = take
    }

    /// Back to the first word of the section on screen, held or mid-read,
    /// as one more take. Leaves the engine paused, like `resolveHold`.
    func restartCurrentSection() {
        let section = heldSection ?? currentSection
        let take = sectionTake + 1
        pause()
        seekTo(index: sectionStarts[section])
        sectionTake = take
    }

    /// The chunk that was on screen at `date`, from the last ~64 changes.
    /// Nil when `date` predates the log.
    func chunkIndex(shownAt date: Date) -> Int? {
        shownLog.last { $0.at <= date }?.index
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
    ///     + sectionEndLingerSec (last word of a section, NOT scaled)
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
        let linger = endsSection(index) ? Self.sectionEndLingerSec : 0
        return base / combinedMul + meta.extraPauseSec + linger
    }

    /// How long a section's last word stays on screen beyond its own time
    /// before the section hold. Honest seconds, like `///`.
    static let sectionEndLingerSec: TimeInterval = 1.0

    // MARK: - Internal scheduling

    private func scheduleAdvance() {
        advanceTask?.cancel()
        guard currentChunkIndex < chunks.count, isPlaying else { return }
        guard !isFrozen else { return }

        let duration = chunkDuration(at: currentChunkIndex)

        advanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isPlaying else { return }

            let next = self.currentChunkIndex + 1
            if self.endsSection(self.currentChunkIndex) {
                // End of a section: stop on its last word and wait.
                self.heldSection = self.section(containing: self.currentChunkIndex)
                if next >= self.chunks.count { self.progress = 1 }
                self.isPlaying = false
            } else if next < self.chunks.count {
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
