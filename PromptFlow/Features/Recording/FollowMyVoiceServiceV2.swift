import Foundation
import Speech
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio
import CoreMedia
import Combine
import SwiftUI

/// Follow-My-Voice V2 — pure adaptive-speed speedometer on iOS 26
/// SpeechAnalyzer.
///
/// **Mental model**: FMV2 measures how fast the user reads (WPM, from
/// `SFSpeech` final results carrying `audioTimeRange` per word) and
/// snaps `engine.externalSpeedMultiplier` to one of five fixed values
/// (0.4 / 0.7 / 1.0 / 1.5 / 2.5) with hysteresis + 1 s dwell. The
/// prompter ALWAYS rolls autonomously on `slider × multiplier` —
/// FMV2 never freezes the engine, never writes
/// `engine.currentChunkIndex`, and has no notion of script position.
///
/// Volatile (partial) results are ignored — only finalized words
/// (with reliable `audioTimeRange` populated) contribute to WPM, so
/// the rate is derived from "actual time the user spent saying these
/// words" rather than from when SpeechAnalyzer happened to deliver
/// them.
///
/// **SDK adjustments**:
/// - `AssetInventory.reserve(locale:)` / `release(reservedLocale:)` —
///   the spec's `allocate`/`deallocate` aren't in this iOS 26 SDK.
/// - `ReportingOption.frequentFinalization` not in this SDK; using
///   `.volatileResults` only (we filter to `result.isFinal` ourselves
///   in `handleResult`).
/// - `AnalyzerInput(buffer:bufferStartTime:)` with exact rational
///   CMTime so the analyzer doesn't reject the stream as overlapping.
/// - `AVAudioConverter` input block returns `.noDataNow` (NOT
///   `.endOfStream`) so the converter survives across ingest calls.
@available(iOS 26.0, *)
@MainActor
final class FollowMyVoiceServiceV2: ObservableObject {

    // MARK: - Public state

    @Published private(set) var isActive: Bool = false
    /// Continuous multiplier applied to `engine.externalSpeedMultiplier`.
    /// Computed per finalization to make the engine's effective pace
    /// equal to `measuredWPM × leadFactor`. EMA-smoothed across
    /// finalizations so single noisy measurements don't whiplash.
    @Published private(set) var currentMultiplier: Double = 1.0
    /// Most recent finalization's measured user WPM, exposed for the
    /// indicator chip in the recording HUD.
    @Published private(set) var lastMeasuredWPM: Double = 0

    enum FMVError: Error {
        case localeNotAvailable
        case localeAllocateFailed
        case audioFormatUnavailable
    }

    // MARK: - Configuration

    private let engine: ChunkPlayerEngine
    private weak var cameraManager: CameraManager?

    // MARK: - SpeechAnalyzer state

    private var locale: Locale?
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    // MARK: - Audio conversion

    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var nextStartFrame: AVAudioFramePosition = 0

    // MARK: - WPM measurement

    /// Wall-clock of the most recent finalization. Drives the silence
    /// safety net — if no finalization arrives for `silenceSafetySec`,
    /// the multiplier drifts back toward 1.0 so the prompter doesn't
    /// stay parked at last-measured pace.
    private var lastFinalizationAt: Date?
    private var tickTimer: Timer?

    // MARK: - Constants

    /// How often `tick()` runs the silence safety check.
    private static let monitorInterval: TimeInterval = 0.5
    /// Without a finalization for this long, the multiplier drifts
    /// toward 1.0 so the prompter doesn't stay parked at stale pace.
    private static let silenceSafetySec: TimeInterval = 6.0
    /// Per-tick blend factor used during silence drift: each tick,
    /// `multiplier ← (1-α)·multiplier + α·1.0`. With monitorInterval=0.5
    /// and α=0.05, half-life is ~7s — gentle, not snappy.
    private static let silenceDriftAlpha: Double = 0.05

    /// Prompter pace runs this much faster than the user's measured
    /// WPM, so the next words are visible just before they're spoken.
    /// 1.10 = 10% lead. Bigger = prompter further ahead.
    private static let leadFactor: Double = 1.10
    /// Hard clamp on multiplier so a pathological measurement (5-word
    /// burst with span 0.4s = 750 WPM) can't drive the prompter into
    /// nonsense. The engine's own duration math also has a 0.1 floor.
    private static let minMultiplier: Double = 0.3
    private static let maxMultiplier: Double = 3.0
    /// EMA blend factor for new-multiplier vs. current-multiplier.
    /// 0.75 = each finalization carries 75% of the new measurement,
    /// 25% inherited from the previous multiplier. With finalizations
    /// every 3–5 s, the multiplier converges to a sustained new pace
    /// in 1–2 finalizations rather than 3–4.
    private static let smoothingAlpha: Double = 0.75
    /// If the raw (clamped-but-not-yet-smoothed) multiplier differs
    /// from the current multiplier by more than this fraction, snap
    /// directly to the clamped value rather than EMA-blending. Catches
    /// sudden pace shifts (e.g. user paused then sprinted) that EMA
    /// would lag behind.
    private static let snapThreshold: Double = 0.30

    // MARK: - Init

    init(engine: ChunkPlayerEngine, cameraManager: CameraManager) {
        self.engine = engine
        self.cameraManager = cameraManager
    }

    // MARK: - Public API

    /// `scriptText` is accepted for API compatibility with the previous
    /// voice-anchored variant but is unused by the speedometer.
    func start(scriptText: String) async throws {
        guard !isActive else { return }
        print("[FMV2] start: speedometer mode")

        let preferred = Locale.current
        guard let resolvedLocale = await Self.resolveEnglishLocale(preferred: preferred) else {
            throw FMVError.localeNotAvailable
        }
        self.locale = resolvedLocale
        print("[FMV2] using locale: \(resolvedLocale.identifier(.bcp47))")

        do {
            try await AssetInventory.reserve(locale: resolvedLocale)
        } catch {
            print("[FMV2] reserve failed: \(error)")
            throw FMVError.localeAllocateFailed
        }

        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        guard let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw FMVError.audioFormatUnavailable
        }
        self.targetFormat = bestFormat
        print("[FMV2] target format: \(bestFormat)")

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try? await analyzer.prepareToAnalyze(in: bestFormat)

        let (inputStream, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputBuilder = builder

        // Reset per-session state.
        nextStartFrame = 0
        lastMeasuredWPM = 0
        lastFinalizationAt = nil
        currentMultiplier = 1.0

        // CRITICAL: the prompter is autonomous throughout. Speedometer
        // only modulates `externalSpeedMultiplier`; never freezes the
        // engine; never writes `currentChunkIndex`.
        engine.externallyFrozen = false
        engine.externalSpeedMultiplier = 1.0

        // Results consumer FIRST so we don't drop early finals.
        self.resultsTask = Task { [weak self] in
            await self?.consumeResults(transcriber: transcriber)
        }

        // analysisTask drives `analyzeSequence`, which blocks until the
        // input stream finishes (in stop()).
        self.analysisTask = Task { [weak self] in
            do {
                let lastSample = try await analyzer.analyzeSequence(inputStream)
                if let lastSample {
                    try? await analyzer.finalizeAndFinish(through: lastSample)
                }
            } catch {
                print("[FMV2] analyzeSequence error: \(error)")
            }
            _ = self
        }

        // Audio broadcast hook last so no buffers are dropped during
        // setup.
        cameraManager?.audioBufferBroadcast = { [weak self] sampleBuffer in
            self?.ingest(sampleBuffer)
        }

        // Tick timer: every `monitorInterval`, check whether silence
        // since the last finalization has crossed `silenceSafetySec`
        // and we should reset to Normal.
        tickTimer = Timer.scheduledTimer(withTimeInterval: Self.monitorInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        isActive = true
        print("[FMV2] active (speedometer mode)")
    }

    func stop() async {
        guard isActive else { return }

        cameraManager?.audioBufferBroadcast = nil
        tickTimer?.invalidate()
        tickTimer = nil

        inputBuilder?.finish()
        await analysisTask?.value
        resultsTask?.cancel()

        if let locale {
            await AssetInventory.release(reservedLocale: locale)
        }

        // Restore engine to neutral. We never froze it during the
        // session, so just zero the multiplier offset.
        engine.externalSpeedMultiplier = 1.0

        analyzer = nil
        transcriber = nil
        inputBuilder = nil
        converter = nil
        targetFormat = nil
        nextStartFrame = 0
        lastMeasuredWPM = 0
        lastFinalizationAt = nil
        analysisTask = nil
        resultsTask = nil
        self.locale = nil
        currentMultiplier = 1.0
        isActive = false

        print("[FMV2] stopped")
    }

    // MARK: - Audio ingestion

    nonisolated func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.convertToPCMBuffer(sampleBuffer) else { return }
        Task { @MainActor [weak self] in
            self?.processIngested(pcm)
        }
    }

    private func processIngested(_ buffer: AVAudioPCMBuffer) {
        guard let inputBuilder, let targetFormat else { return }

        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
        guard outputCapacity > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return
        }

        var sourceProvided = false
        var convertError: NSError?
        let status = converter.convert(to: outBuffer, error: &convertError) { _, outStatus in
            if sourceProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            sourceProvided = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error || convertError != nil { return }
        if outBuffer.frameLength == 0 { return }

        let startTime = CMTime(
            value: CMTimeValue(nextStartFrame),
            timescale: CMTimeScale(targetFormat.sampleRate)
        )
        let input = AnalyzerInput(buffer: outBuffer, bufferStartTime: startTime)
        inputBuilder.yield(input)
        nextStartFrame += AVAudioFramePosition(outBuffer.frameLength)
    }

    // MARK: - Results

    private func consumeResults(transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                await handleResult(result)
            }
        } catch {
            print("[FMV2] results stream error: \(error)")
        }
    }

    @MainActor
    private func handleResult(_ result: SpeechTranscriber.Result) async {
        // Ignore volatile partials — only finalized runs carry reliable
        // `audioTimeRange` we can use for honest WPM.
        guard result.isFinal else { return }

        // Collect this finalization's words with timestamps. Each
        // finalization is treated as a self-contained measurement —
        // no rolling window across finalizations, no smoothing.
        var words: [(start: TimeInterval, end: TimeInterval)] = []
        for run in result.text.runs {
            guard let timeRange = run.audioTimeRange else { continue }
            let word = String(result.text[run.range].characters)
            let normalized = Self.normalize(word)
            guard !normalized.isEmpty else { continue }
            words.append((start: timeRange.start.seconds, end: timeRange.end.seconds))
        }

        guard words.count >= 2 else {
            print("[FMV2] FINAL: only \(words.count) words, skipping rate calc")
            return
        }

        let span = words.last!.end - words.first!.start
        guard span > 0.3 else {
            print("[FMV2] FINAL: span=\(String(format: "%.2f", span))s too short, skipping")
            return
        }

        let wpm = Double(words.count) / span * 60.0
        // Mark activity BEFORE the short-segment skip so brief
        // finalizations still suppress silence drift — the user is
        // clearly speaking, we just don't trust the measurement.
        lastFinalizationAt = Date()

        // Skip short segments. Below ~5 words, statistical noise
        // dominates: a single internal micro-pause swings WPM by 30%+,
        // and SpeechAnalyzer's trailing finalizations (1–3 residual
        // words after a longer one) routinely produce phantom slowdown
        // signals. Don't touch the multiplier or the displayed WPM
        // for these — the prior steady-state values stay.
        guard words.count >= 5 else {
            print("[FMV2] FINAL words=\(words.count) span=\(String(format: "%.2f", span))s wpm=\(String(format: "%.0f", wpm)) — too few words, ignoring")
            return
        }

        lastMeasuredWPM = wpm

        // Compute the multiplier that would make the engine's effective
        // per-word duration match the user's measured WPM, with a small
        // lead factor so the prompter sits a step ahead of the user.
        //
        //   targetDurationPerWord = 60 / (wpm × leadFactor)
        //   multiplier            = baseline / target
        //                         = baseline × wpm × leadFactor / 60
        //
        // The engine then divides its baseline-derived chunk duration
        // by this multiplier, landing on the target.
        let baselineDur = engine.averageBaselineDurationPerWord()
        let targetDur = 60.0 / (wpm * Self.leadFactor)
        let raw = baselineDur / max(targetDur, 0.001)
        let clamped = min(Self.maxMultiplier, max(Self.minMultiplier, raw))

        // Big-delta snap: if the raw proposal differs from the current
        // multiplier by more than `snapThreshold`, bypass EMA and apply
        // the clamped value directly. EMA lag is fine for incremental
        // pace shifts but harmful when the user abruptly changes
        // direction (silence-then-sprint, slow-then-fast).
        let rawDelta = abs(raw - currentMultiplier) / max(currentMultiplier, 0.1)
        let smoothed: Double
        let snapped: Bool
        if rawDelta > Self.snapThreshold {
            smoothed = clamped
            snapped = true
        } else {
            smoothed = Self.smoothingAlpha * clamped + (1 - Self.smoothingAlpha) * currentMultiplier
            snapped = false
        }

        print("[FMV2] FINAL words=\(words.count) span=\(String(format: "%.2f", span))s wpm=\(String(format: "%.0f", wpm)) baselineDur=\(String(format: "%.3f", baselineDur))s targetDur=\(String(format: "%.3f", targetDur))s mul raw=\(String(format: "%.2f", raw)) clamped=\(String(format: "%.2f", clamped)) smoothed=\(String(format: "%.2f", smoothed))\(snapped ? " (big delta \(String(format: "%.0f%%", rawDelta * 100)) — snapped)" : "")")

        currentMultiplier = smoothed
        engine.externalSpeedMultiplier = smoothed
    }

    // MARK: - Tick

    @MainActor
    private func tick() {
        // Silence drift only — every tick after `silenceSafetySec` of
        // no finalizations, blend the multiplier toward 1.0. With
        // monitorInterval=0.5 and silenceDriftAlpha=0.05, the half-life
        // is ~7 s, so a long pause unwinds gradually rather than snapping.
        guard let last = lastFinalizationAt else { return }
        guard Date().timeIntervalSince(last) > Self.silenceSafetySec else { return }
        let target = 1.0
        let drifted = (1 - Self.silenceDriftAlpha) * currentMultiplier + Self.silenceDriftAlpha * target
        if abs(drifted - currentMultiplier) > 0.005 {
            currentMultiplier = drifted
            engine.externalSpeedMultiplier = drifted
            print("[FMV2] silence drift: mul → \(String(format: "%.2f", drifted))")
        }
    }

    // MARK: - Locale resolution

    /// Pick an installed English SpeechTranscriber locale. Priority:
    /// 1) exact BCP-47 match against the device locale, 2) same region
    /// as the device locale, 3) en-US, 4) any installed English locale.
    private static func resolveEnglishLocale(preferred: Locale) async -> Locale? {
        let installed = await SpeechTranscriber.installedLocales
        let englishInstalled = installed.filter { $0.language.languageCode?.identifier == "en" }
        if let exact = englishInstalled.first(where: { $0.identifier(.bcp47) == preferred.identifier(.bcp47) }) {
            return exact
        }
        if let region = preferred.region {
            if let regionMatch = englishInstalled.first(where: { $0.region == region }) {
                return regionMatch
            }
        }
        if let usFallback = englishInstalled.first(where: { $0.identifier(.bcp47).hasPrefix("en-US") }) {
            return usFallback
        }
        return englishInstalled.first
    }

    // MARK: - Helpers

    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated private static func convertToPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcm.frameLength = AVAudioFrameCount(frameCount)

        var srcList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &srcList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let dstListPtr = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        if let dstData = dstListPtr[0].mData,
           let srcData = srcList.mBuffers.mData {
            let bytes = min(dstListPtr[0].mDataByteSize, srcList.mBuffers.mDataByteSize)
            memcpy(dstData, srcData, Int(bytes))
        }
        return pcm
    }
}

// MARK: - iOS 26 helper subviews

/// Compact indicator chip shown during active FMV. Displays the most
/// recent measured WPM (from finalizations); empty `0` placeholder
/// before the first finalization arrives. Replaces the previous
/// step-name chip — V2 now uses a continuous multiplier driven from
/// measured WPM, so a single number is the most informative readout.
@available(iOS 26.0, *)
struct FMVStepIndicator: View {
    @ObservedObject var service: FollowMyVoiceServiceV2

    var body: some View {
        if service.isActive {
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                    .font(.caption2)
                    .foregroundColor(.white)
                Text(wpmText)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.5), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var wpmText: String {
        service.lastMeasuredWPM > 0
            ? "\(Int(service.lastMeasuredWPM.rounded())) WPM"
            : "— WPM"
    }

    private var accessibilityText: String {
        service.lastMeasuredWPM > 0
            ? "Voice tracking: \(Int(service.lastMeasuredWPM.rounded())) words per minute"
            : "Voice tracking: awaiting first measurement"
    }
}

/// Invisible bridge view: observes `service.currentMultiplier` via
/// `@ObservedObject` (so SwiftUI's reactive observation works without
/// wiring up Combine cancellables on the parent View struct), and
/// writes `baseline * multiplier` back into the parent's slider
/// binding whenever the multiplier changes. Mounted only when the
/// parent has a non-nil baseline AND a live FMV service.
@available(iOS 26.0, *)
struct FMVSliderSync: View {
    @ObservedObject var service: FollowMyVoiceServiceV2
    @Binding var slider: Double
    let baseline: Double

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: service.currentMultiplier) { _, newMult in
                slider = max(0, min(1, baseline * newMult))
            }
    }
}
