import AVFoundation
import os

/// Tightens section cuts (`Recording.sectionCuts`) to the voice: each kept
/// part's edges move in over the silence before the first words and after
/// the last, by loudness alone. No speech recognition — the pauses between
/// takes are silent by design, so loudness tells voice from room.
///
/// Edges only ever move inward, and never by more than `maxShiftSec`. A part
/// with no voice found in it is left as it is: the threshold is not to be
/// trusted there.
nonisolated enum SilenceTrimmer {

    /// Loudness of a recording's audio, one value per `frameSec`, in dBFS.
    struct Levels {
        /// Where the first frame starts, in seconds of the file.
        let start: Double
        let db: [Float]

        var end: Double { start + Double(db.count) * frameSec }

        func frame(at time: Double) -> Int {
            Int(((time - start) / frameSec).rounded(.down))
        }

        func time(ofFrame index: Int) -> Double {
            start + Double(index) * frameSec
        }

        func frames(in range: ClosedRange<Double>) -> ArraySlice<Float> {
            let lower = max(0, frame(at: range.lowerBound))
            let upper = min(db.count, frame(at: range.upperBound))
            return lower < upper ? db[lower..<upper] : []
        }
    }

    static let frameSec: Double = 0.02
    static let sampleRate: Double = 16_000
    /// Below the voice: mains hum, air conditioning, fridges.
    static let highPassHz: Double = 100
    /// Louder than the room by this much is voice.
    static let voiceAboveFloorDB: Float = 12
    /// Voice holds at least this long; clicks and knocks are shorter.
    static let minVoiceSec: Double = 0.08
    /// Room left between an edge and the voice, for soft endings — "-s",
    /// "-f", a breath out — that sit under the threshold.
    static let marginSec: Double = 0.15
    /// The same room at the very start and end of the video, which want a
    /// little air rather than a hard cut.
    static let outerMarginSec: Double = 0.5
    /// The furthest an edge moves.
    static let maxShiftSec: Double = 1.5
    /// A part is never trimmed shorter than this.
    static let minPartSec: Double = 0.3

    // MARK: - Trimming

    static func trim(_ ranges: [ClosedRange<Double>], toVoiceIn url: URL) async throws -> [ClosedRange<Double>] {
        trim(ranges, levels: try await levels(ofAudioIn: url))
    }

    static func trim(_ ranges: [ClosedRange<Double>], levels: Levels) -> [ClosedRange<Double>] {
        guard !levels.db.isEmpty else { return ranges }

        // The room: the quiet end of what is cut away, which holds the
        // countdowns and holds (a dropped take may be in there too, hence a
        // low percentile rather than the mean). Without enough of it, the
        // quiet end of the whole recording.
        var room = SectionCutComposition.gaps(keeping: ranges, total: levels.end)
            .flatMap { levels.frames(in: $0) }
        if Double(room.count) * frameSec < 0.5 { room = levels.db }
        let threshold = percentile(room, 0.2) + voiceAboveFloorDB

        let voice = voiceRuns(levels.db, above: threshold)
        log.notice("event=trim_start parts=\(ranges.count) audio_sec=\(fmt(levels.end), privacy: .public) room_db=\(fmt(Double(percentile(room, 0.2))), privacy: .public) threshold_db=\(fmt(Double(threshold)), privacy: .public) voice_runs=\(voice.count)")
        return ranges.enumerated().map { index, range in
            let trimmed = trim(
                range,
                voice: voice,
                levels: levels,
                startMargin: index == 0 ? outerMarginSec : marginSec,
                endMargin: index == ranges.count - 1 ? outerMarginSec : marginSec
            )
            log.notice("event=trim_part index=\(index) kept=\(fmt(range), privacy: .public) trimmed=\(fmt(trimmed), privacy: .public) cut_start=\(fmt(trimmed.lowerBound - range.lowerBound), privacy: .public) cut_end=\(fmt(range.upperBound - trimmed.upperBound), privacy: .public)")
            return trimmed
        }
    }

    private static func trim(
        _ range: ClosedRange<Double>,
        voice: [Range<Int>],
        levels: Levels,
        startMargin: Double,
        endMargin: Double
    ) -> ClosedRange<Double> {
        let inRange = voice
            .map { levels.time(ofFrame: $0.lowerBound)...levels.time(ofFrame: $0.upperBound) }
            .filter { $0.upperBound > range.lowerBound && $0.lowerBound < range.upperBound }
        guard let first = inRange.first, let last = inRange.last else {
            log.notice("event=trim_no_voice kept=\(fmt(range), privacy: .public)")
            return range
        }

        let firstVoice = max(first.lowerBound, range.lowerBound)
        let lastVoice = min(last.upperBound, range.upperBound)
        let start = max(range.lowerBound, min(firstVoice - startMargin, range.lowerBound + maxShiftSec))
        let end = min(range.upperBound, max(lastVoice + endMargin, range.upperBound - maxShiftSec))
        guard end - start >= minPartSec else {
            log.notice("event=trim_too_short kept=\(fmt(range), privacy: .public) voice=\(fmt(firstVoice...lastVoice), privacy: .public)")
            return range
        }
        return start...end
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kirillvasilyev.SteadyEye",
        category: "SectionCut"
    )

    private static func fmt(_ value: Double) -> String { String(format: "%.2f", value) }
    private static func fmt(_ range: ClosedRange<Double>) -> String { "\(fmt(range.lowerBound))-\(fmt(range.upperBound))" }

    /// Runs of frames above `threshold` that last at least `minVoiceSec`.
    static func voiceRuns(_ db: [Float], above threshold: Float) -> [Range<Int>] {
        let minFrames = Int((minVoiceSec / frameSec).rounded(.up))
        var runs: [Range<Int>] = []
        var runStart: Int?
        for (index, level) in db.enumerated() {
            if level > threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                if index - start >= minFrames { runs.append(start..<index) }
                runStart = nil
            }
        }
        if let start = runStart, db.count - start >= minFrames { runs.append(start..<db.count) }
        return runs
    }

    private static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return -120 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    // MARK: - Reading

    enum ReadError: Error {
        case noAudioTrack
        case readFailed
    }

    /// The audio track's loudness, high-passed, mono at `sampleRate`.
    static func levels(ofAudioIn url: URL) async throws -> Levels {
        // Held in a local: a track does not keep its asset alive.
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ReadError.noAudioTrack
        }
        let start = try await track.load(.timeRange).start.seconds
        // The read blocks while it decodes: off the caller's thread.
        return try await Task.detached(priority: .userInitiated) {
            try readLevels(asset: asset, track: track, start: start)
        }.value
    }

    private static func readLevels(asset: AVAsset, track: AVAssetTrack, start: Double) throws -> Levels {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ])
        guard reader.canAdd(output) else { throw ReadError.readFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ReadError.readFailed }

        let frameLength = Int(sampleRate * frameSec)
        let rc = 1 / (2 * Double.pi * highPassHz)
        let alpha = Float(rc / (rc + 1 / sampleRate))
        var previousIn: Float = 0
        var previousOut: Float = 0
        var sumOfSquares: Float = 0
        var count = 0
        var db: [Float] = []
        var samples: [Float] = []

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for sample in samples {
                let filtered = alpha * (previousOut + sample - previousIn)
                previousIn = sample
                previousOut = filtered
                sumOfSquares += filtered * filtered
                count += 1
                if count == frameLength {
                    db.append(10 * log10(sumOfSquares / Float(count) + 1e-12))
                    sumOfSquares = 0
                    count = 0
                }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? ReadError.readFailed }
        return Levels(start: start, db: db)
    }
}
