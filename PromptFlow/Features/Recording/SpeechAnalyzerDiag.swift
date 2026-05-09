import Foundation
import Speech
@preconcurrency import AVFoundation
@preconcurrency import AVFAudio
import CoreMedia
import Combine
import SwiftUI

/// Hardcoded knob to switch between SpeechTranscriber configurations
/// while we hunt for one that emits results. Change `mode` and rebuild
/// — no UI for picking, this is a build-time investigation tool.
@available(iOS 26.0, *)
private enum DiagConfig {
    static let mode: TranscriberMode = .explicitOptions
}

@available(iOS 26.0, *)
private enum TranscriberMode {
    /// `Preset.progressiveLiveTranscription` — proven NON-buildable in
    /// this SDK ("Type 'SpeechTranscriber.Preset' has no member
    /// 'progressiveLiveTranscription'"). Falls back to
    /// `.explicitOptions` so the switch still compiles.
    case progressiveLivePreset
    /// `Preset.offlineTranscription` — also NON-buildable in this SDK
    /// (same "no member" rejection). The Preset enum may exist as a
    /// type but expose no cases we can use. Falls back to
    /// `.explicitOptions`.
    case offlineTranscription
    /// All options spelled out manually. Includes `.volatileResults`
    /// (so partials flow during analysis) and `.audioTimeRange` (per-
    /// run timing on the result's AttributedString). `.frequentFinalization`
    /// also tried — `ReportingOption` rejects that case too in this SDK.
    case explicitOptions
}


/// iOS 26 SpeechAnalyzer diagnostic harness.
///
/// Verifies whether `SpeechTranscriber` delivers per-word `audioTimeRange`
/// data in volatile (real-time) results, or only on `isFinal=true`. Runs
/// only when manually started from the DEV settings screen — never wired
/// into RecordingView, never replaces FollowMyVoiceService.
///
/// Usage flow:
/// 1. DEV → "Test SpeechAnalyzer" toggles `start()` on
/// 2. `CameraManager.audioBufferBroadcast` is hijacked to forward audio
///    samples into `ingest(_:)`
/// 3. Start a normal recording — speak — observe `[SA-DIAG]` console lines
/// 4. Toggle the button again to stop and restore the broadcast hook
///
/// NOTE on API stability: SpeechAnalyzer iterated between iOS 26 betas.
/// Lines marked `// DEVIATION:` are best-effort guesses. If the build
/// fails on those, refer to the current docs at
/// https://developer.apple.com/documentation/speech/speechanalyzer
/// and adjust the spelling. The shape is correct; the names may not be.
@available(iOS 26.0, *)
@MainActor
final class SpeechAnalyzerDiag: ObservableObject {
    static let shared = SpeechAnalyzerDiag()

    @Published private(set) var isRunning: Bool = false

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    /// Drives `analyzer.analyzeSequence(_:)`. Returns the last consumed
    /// audio sample (or nil) when the input sequence finishes — i.e.
    /// when `inputBuilder.finish()` is called from `stop()`.
    private var analysisTask: Task<Void, Never>?
    /// Periodic "is the results task still alive?" log. Exists so we
    /// can distinguish "transcriber emits nothing" from "results task
    /// silently died" when no `[SA-DIAG] RESULT` lines appear.
    private var heartbeatTask: Task<Void, Never>?

    /// Format that `SpeechAnalyzer` reports as best for the current
    /// transcriber. The model's expected sample rate is typically 16 kHz;
    /// the camera mic delivers 48 kHz — we converge them via
    /// `AVAudioConverter`.
    private var targetFormat: AVAudioFormat?
    /// Lazy-initialised on the first audio buffer we receive (so we can
    /// see its actual format before committing to a conversion path).
    private var converter: AVAudioConverter?
    /// Locale we asked AssetInventory to allocate; held so `stop()` can
    /// deallocate the same one without re-deriving it.
    private var allocatedLocale: Locale?

    /// One-shot flag — log the first incoming buffer's format for
    /// debugging, then suppress.
    private var loggedFirstBuffer: Bool = false
    /// Heartbeat counter so the console gets one summary line per ~50
    /// buffers (~1 s at 50 Hz) instead of a per-buffer flood.
    private var bufferCounter: Int = 0
    /// Per-buffer diagnostic index — used to gate the verbose
    /// frames/maxAmp/nonZero log to the first 5 buffers and every 100th
    /// thereafter.
    private var diagBufferIndex: Int = 0
    /// Cumulative frame count fed to the analyzer in the target format.
    /// Used for the 50-buffer heartbeat log; mirrors `nextStartFrame`.
    private var totalFramesYielded: UInt64 = 0
    /// Start-of-buffer frame on the analyzer's timeline. Used to build
    /// each `AnalyzerInput`'s `bufferStartTime` via exact rational
    /// CMTime arithmetic — `CMTime(value: nextStartFrame, timescale:
    /// sampleRate)` — so consecutive buffers' end-of-N == start-of-N+1
    /// without floating-point drift. SpeechAnalyzer rejects the entire
    /// stream if it sees `bufferStartTime` overlap or precede the
    /// previous buffer's end, so this MUST be exact.
    private var nextStartFrame: AVAudioFramePosition = 0

    private init() {}

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }

        // Step 1: locale check via supportedLocale(equivalentTo:) — Apple's
        // recommended way to canonicalize a requested locale (e.g.
        // "en-US" → whatever the supported locale variant is).
        let preferredLocale = Locale(identifier: "en-US")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale) else {
            print("[SA-DIAG] no supported locale equivalent to \(preferredLocale.identifier(.bcp47))")
            return
        }
        print("[SA-DIAG] using locale: \(locale.identifier(.bcp47))")

        // Build the transcriber up-front; reuse for the asset install
        // request AND for analyzer modules. The shape depends on
        // `DiagConfig.mode` so we can A/B configurations to find one
        // that actually emits results.
        let transcriber: SpeechTranscriber
        switch DiagConfig.mode {
        case .progressiveLivePreset:
            // Preset doesn't exist in this SDK — fall back. Logged so
            // we don't silently use the wrong mode.
            print("[SA-DIAG] ⚠️ mode=progressiveLivePreset is not buildable in this SDK; using explicitOptions")
            transcriber = Self.makeExplicitOptionsTranscriber(locale: locale)

        case .offlineTranscription:
            // Preset doesn't exist in this SDK either — same fate as
            // `.progressiveLivePreset`. Fall back so the file compiles.
            print("[SA-DIAG] ⚠️ mode=offlineTranscription is not buildable in this SDK (Preset.offlineTranscription missing); using explicitOptions")
            transcriber = Self.makeExplicitOptionsTranscriber(locale: locale)

        case .explicitOptions:
            transcriber = Self.makeExplicitOptionsTranscriber(locale: locale)
            print("[SA-DIAG] mode=explicitOptions (volatileResults + audioTimeRange)")
        }
        self.transcriber = transcriber

        // Step 2: install assets if needed.
        let installed = await SpeechTranscriber.installedLocales
        let alreadyInstalled = installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        if !alreadyInstalled {
            print("[SA-DIAG] not installed — requesting download")
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                    print("[SA-DIAG] asset installed")
                } else {
                    print("[SA-DIAG] no installation request returned")
                }
            } catch {
                print("[SA-DIAG] asset install error: \(error)")
                self.transcriber = nil
                return
            }
        } else {
            print("[SA-DIAG] locale already installed")
        }

        // Reserve (allocate) the locale before any analyzer with it can
        // run. SDK names: `reserve(locale:)` / `release(reservedLocale:)`.
        do {
            try await AssetInventory.reserve(locale: locale)
            self.allocatedLocale = locale
            print("[SA-DIAG] locale reserved")
        } catch {
            print("[SA-DIAG] ❌ reserve failed: \(error)")
            self.transcriber = nil
            return
        }

        // Step 3: input sequence.
        let (inputSequence, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputBuilder = builder

        // Step 4: best audio format. `bestAvailableAudioFormat` is
        // non-throwing in this SDK.
        let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard let audioFormat else {
            print("[SA-DIAG] no compatible audio format — abort")
            await releaseLocaleIfReserved()
            self.transcriber = nil
            return
        }
        self.targetFormat = audioFormat
        print("[SA-DIAG] target format: \(audioFormat)")

        // Step 5: analyzer.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Optional preheat — non-fatal if it fails.
        do {
            try await analyzer.prepareToAnalyze(in: audioFormat)
            print("[SA-DIAG] analyzer preheated")
        } catch {
            print("[SA-DIAG] preheat error (non-fatal): \(error)")
        }

        // Step 7: results consumer FIRST — must be running before
        // analyzeSequence so we don't drop early partials.
        self.resultsTask = Task { [weak self] in
            await self?.consumeResults()
        }

        // Heartbeat: every 2s, report whether resultsTask is still
        // subscribed. Lets us distinguish "transcriber emits nothing"
        // from "resultsTask silently died" when no RESULT lines appear.
        self.heartbeatTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                tick += 1
                guard let self else { return }
                let cancelled = self.resultsTask?.isCancelled ?? true
                let buffers = self.bufferCounter
                print("[SA-DIAG] 💓 heartbeat #\(tick): resultsTask cancelled=\(cancelled) buffers=\(buffers)")
            }
        }

        // Tried subscribing to a separate `transcriber.volatileResults`
        // stream — SpeechTranscriber in this SDK does NOT expose that
        // property. So volatile partials flow through the same
        // `transcriber.results` stream as finals, distinguished only by
        // the `isFinal` flag on each result. The verbose
        // `consumeResults()` already logs that flag for every result,
        // which is sufficient.

        // Step 6 + 8: analyzeSequence in background. It blocks until
        // `inputBuilder.finish()` is called, returning the last
        // consumed sample's CMTime (or nil).
        self.analysisTask = Task {
            do {
                print("[SA-DIAG] analyzeSequence starting...")
                let lastSample = try await analyzer.analyzeSequence(inputSequence)
                print("[SA-DIAG] analyzeSequence returned, lastSample=\(String(describing: lastSample?.seconds))")
                if let lastSample {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                print("[SA-DIAG] ❌ analyzeSequence error: \(error)")
            }
        }

        isRunning = true
        print("[SA-DIAG] start() complete — awaiting first audio buffer")
    }

    /// Build a `SpeechTranscriber` configured with explicit options.
    /// `.volatileResults` enables partial results during analysis;
    /// `.audioTimeRange` populates per-run `audioTimeRange` attributes
    /// on the result's AttributedString.
    /// Tried `.frequentFinalization` — `ReportingOption` doesn't expose
    /// that case in this SDK ("has no member 'frequentFinalization'").
    /// `.volatileResults` appears to be the only relevant reporting
    /// option available.
    private static func makeExplicitOptionsTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Helper: release the locale if we reserved it earlier in `start()`.
    /// Used by error paths so we don't leak an allocated locale on abort.
    private func releaseLocaleIfReserved() async {
        if let allocated = allocatedLocale {
            await AssetInventory.release(reservedLocale: allocated)
            allocatedLocale = nil
            print("[SA-DIAG] locale \(allocated.identifier(.bcp47)) released (abort path)")
        }
    }

    func stop() async {
        guard isRunning else { return }
        inputBuilder?.finish()
        print("[SA-DIAG] inputBuilder finished")

        // Wait for analyzeSequence to drain. Without this, we could
        // tear down the analyzer mid-finalization and lose any pending
        // results.
        await analysisTask?.value

        resultsTask?.cancel()
        analysisTask?.cancel()
        heartbeatTask?.cancel()

        if let allocated = allocatedLocale {
            await AssetInventory.release(reservedLocale: allocated)
            allocatedLocale = nil
            print("[SA-DIAG] locale \(allocated.identifier(.bcp47)) released")
        }

        analyzer = nil
        transcriber = nil
        inputBuilder = nil
        targetFormat = nil
        converter = nil
        loggedFirstBuffer = false
        bufferCounter = 0
        diagBufferIndex = 0
        totalFramesYielded = 0
        nextStartFrame = 0
        resultsTask = nil
        analysisTask = nil
        heartbeatTask = nil
        isRunning = false
        print("[SA-DIAG] stop() complete")
    }

    // MARK: - Audio ingestion

    /// Called from CameraManager's audio data output via the
    /// `audioBufferBroadcast` hook (on `sampleBufferQueue`). Converts
    /// CMSampleBuffer → AVAudioPCMBuffer on the calling queue, then
    /// hops to MainActor for the format conversion + yield (the
    /// AVAudioConverter's lifecycle is MainActor-owned for thread
    /// safety).
    nonisolated func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.convertToPCMBuffer(sampleBuffer) else { return }
        Task { @MainActor [weak self] in
            self?.processIngestedBuffer(pcm)
        }
    }

    /// MainActor: format-convert the captured PCM buffer into the
    /// analyzer's preferred format and yield to the input stream.
    @MainActor
    private func processIngestedBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let inputBuilder, let targetFormat else { return }

        if !loggedFirstBuffer {
            print("[SA-DIAG] first buffer received: format=\(buffer.format) sampleRate=\(buffer.format.sampleRate) channels=\(buffer.format.channelCount) frames=\(buffer.frameLength)")
            loggedFirstBuffer = true
        }

        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            if converter == nil {
                print("[SA-DIAG] failed to create AVAudioConverter from \(buffer.format) to \(targetFormat)")
                return
            }
            print("[SA-DIAG] converter created: \(buffer.format) → \(targetFormat)")
        }
        guard let converter else { return }

        // Output frame capacity scales by the sample-rate ratio.
        // 48 kHz → 16 kHz with frameLength=1024 in → ~341 frames out.
        let outputFrameCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate).rounded(.up)
        )
        guard outputFrameCapacity > 0,
              let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCapacity
              ) else {
            print("[SA-DIAG] failed to allocate converted buffer (capacity=\(outputFrameCapacity))")
            return
        }

        // Per-buffer conversion: deliver the source buffer once, then
        // tell the converter "no data right now" (NOT end-of-stream).
        // CRITICAL: signaling `.endOfStream` here puts the converter
        // into a terminal flushed state — subsequent `convert()` calls
        // on the same converter produce zero frames. That was the bug
        // behind buf #2+ all having frames=0. `.noDataNow` keeps the
        // converter alive between ingest calls; we'll feed it a fresh
        // source buffer on the next one.
        var sourceBufferProvided = false
        var convertError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &convertError) { _, outStatus in
            if sourceBufferProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            sourceBufferProvided = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            print("[SA-DIAG] conversion error status=.error err=\(convertError?.localizedDescription ?? "nil")")
            return
        }
        if let convertError {
            print("[SA-DIAG] conversion error: \(convertError.localizedDescription)")
            return
        }
        if convertedBuffer.frameLength == 0 {
            print("[SA-DIAG] WARNING: converted buffer has 0 frames (status=\(status.rawValue))")
            return
        }

        // Buffer-content diagnostic: are we actually feeding the
        // analyzer real audio, or silent zeros? Logged for the first 5
        // buffers (catches a bad converter setup at warmup) and every
        // 100th buffer after (heartbeat that levels are real). Walks
        // the int16 channel data; assumes the target format is Int16
        // PCM, which is what `bestAvailableAudioFormat` returns for the
        // SpeechAnalyzer model.
        diagBufferIndex += 1
        if diagBufferIndex <= 5 || diagBufferIndex % 100 == 0 {
            let frames = convertedBuffer.frameLength
            let capacity = convertedBuffer.frameCapacity
            var maxAmplitude: Int16 = 0
            var nonZeroSamples = 0
            if let int16Data = convertedBuffer.int16ChannelData?[0] {
                for i in 0..<Int(frames) {
                    // Int32 cast first — `abs(Int16.min)` would overflow
                    // and trap. Int32(-32768) → 32768, Int16(...) maps
                    // back into [0, 32767] safely.
                    let sample = Int16(min(Int32(Int16.max), abs(Int32(int16Data[i]))))
                    if sample > 0 { nonZeroSamples += 1 }
                    if sample > maxAmplitude { maxAmplitude = sample }
                }
            } else {
                print("[SA-DIAG] buf #\(diagBufferIndex): int16ChannelData nil — target format may not be Int16 PCM")
            }
            print("[SA-DIAG] buf #\(diagBufferIndex): frames=\(frames)/\(capacity) maxAmp=\(maxAmplitude) nonZero=\(nonZeroSamples)/\(frames) startFrame=\(nextStartFrame)")
        }

        // Build the analyzer's timeline using EXACT rational CMTime
        // arithmetic — `CMTime(value: frameNumber, timescale: sampleRate)`
        // — instead of `CMTime(seconds: Double, preferredTimescale:)`.
        // The seconds-based init does floating-point math internally and
        // accumulates error: a buffer ending "at" frame 368 might compute
        // a CMTime equivalent to 0.367999... while the next buffer
        // starts at exactly 0.368. SpeechAnalyzer treats that mismatch
        // as overlap and rejects the entire stream after a few buffers.
        // Using integer (frame, sampleRate) ratios, two buffers that
        // share a boundary frame produce CMTimes that compare equal.
        let frames = AVAudioFramePosition(convertedBuffer.frameLength)
        let sampleRate = targetFormat.sampleRate
        let startFrame = nextStartFrame
        let startTime = CMTime(
            value: CMTimeValue(startFrame),
            timescale: CMTimeScale(sampleRate)
        )

        let input = AnalyzerInput(buffer: convertedBuffer, bufferStartTime: startTime)
        inputBuilder.yield(input)

        // Advance AFTER yield, by exact frame count. Must mirror the
        // converted buffer's frameLength so the next start frame =
        // this buffer's end frame, with no gap and no overlap.
        nextStartFrame += frames
        totalFramesYielded = UInt64(nextStartFrame)

        bufferCounter += 1
        if bufferCounter % 50 == 0 {
            print("[SA-DIAG] yielded \(bufferCounter) buffers, nextStartFrame=\(nextStartFrame)")
        }
    }

    // MARK: - Results consumption

    private func consumeResults() async {
        guard let transcriber else {
            print("[SA-DIAG] ❌ resultsTask: no transcriber, exiting immediately")
            return
        }
        print("[SA-DIAG] resultsTask: subscribed to transcriber.results, awaiting...")
        do {
            var resultCount = 0
            for try await result in transcriber.results {
                resultCount += 1
                print("[SA-DIAG] 🔥 result #\(resultCount) received")
                print("[SA-DIAG]   isFinal=\(result.isFinal)")
                print("[SA-DIAG]   range=\(result.range)")
                print("[SA-DIAG]   resultsFinalizationTime=\(String(describing: result.resultsFinalizationTime))")

                let plainText = String(result.text.characters)
                print("[SA-DIAG]   text='\(plainText)' len=\(plainText.count)")

                var runCount = 0
                for run in result.text.runs {
                    runCount += 1
                    let segment = String(result.text[run.range].characters)
                    let timeRangeStr: String
                    if let tr = run.audioTimeRange {
                        timeRangeStr = "tr_start=\(tr.start.seconds) tr_end=\(tr.end.seconds)"
                    } else {
                        timeRangeStr = "NO_TIMERANGE"
                    }
                    print("[SA-DIAG]   run #\(runCount): '\(segment)' \(timeRangeStr)")
                }
                print("[SA-DIAG]   total runs in this result: \(runCount)")
            }
            print("[SA-DIAG] ✅ resultsTask: stream completed, total results: \(resultCount)")
        } catch {
            print("[SA-DIAG] ❌ resultsTask error: \(error)")
            print("[SA-DIAG]   error type: \(type(of: error))")
            let nsError = error as NSError
            print("[SA-DIAG]   domain: \(nsError.domain) code: \(nsError.code)")
            print("[SA-DIAG]   userInfo: \(nsError.userInfo)")
        }
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    /// `nonisolated` so the `nonisolated ingest(_:)` can call it
    /// without hopping actors. The function is pure (no instance or
    /// type state), so this is safe.
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

        // Pull source bytes via a temp AudioBufferList anchored to the
        // sample buffer's block buffer, then memcpy into the PCM
        // buffer's storage. Avoids the trap of overwriting PCM buffer's
        // mBuffer pointers (which would leak its allocated memory).
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
        // Camera-mic audio is single-buffer interleaved; AudioBufferList
        // declares mBuffers as a single-element flexible array, so this
        // covers the common case.
        if let dstData = dstListPtr[0].mData,
           let srcData = srcList.mBuffers.mData {
            let bytes = min(dstListPtr[0].mDataByteSize, srcList.mBuffers.mDataByteSize)
            memcpy(dstData, srcData, Int(bytes))
        }
        return pcm
    }
}

// MARK: - DEV button

/// Toggle button for the DEV settings panel. Starts/stops the analyzer
/// and hijacks `CameraManager.audioBufferBroadcast` so audio buffers
/// from the active recording route into `SpeechAnalyzerDiag.ingest`.
/// Test workflow: disable Follow-My-Voice → toggle this on → start a
/// recording → speak → stop the recording → toggle this off → read
/// `[SA-DIAG]` lines in the console.
@available(iOS 26.0, *)
struct SpeechAnalyzerDiagButton: View {
    @ObservedObject private var diag = SpeechAnalyzerDiag.shared

    var body: some View {
        Button(diag.isRunning ? "Stop SpeechAnalyzer (DEV)" : "Test SpeechAnalyzer (DEV)") {
            Task {
                if diag.isRunning {
                    // Restore the broadcast hook BEFORE stopping so any
                    // in-flight buffer doesn't try to feed a stopped
                    // analyzer.
                    CameraManager.shared.audioBufferBroadcast = nil
                    await diag.stop()
                } else {
                    await diag.start()
                    if diag.isRunning {
                        CameraManager.shared.audioBufferBroadcast = { buffer in
                            SpeechAnalyzerDiag.shared.ingest(buffer)
                        }
                    }
                }
            }
        }
        if diag.isRunning {
            Text("SpeechAnalyzer is RUNNING — recording audio routes here.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
