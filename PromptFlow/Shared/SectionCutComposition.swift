import AVFoundation

/// A take cut down to the last take of each `////` section
/// (`Recording.sectionCuts`). The file itself is never touched: playback
/// and saving build a composition and take the gaps out of it, every track
/// alike, so picture and both soundtracks stay in sync.
enum SectionCutComposition {

    /// Gaps shorter than this are left in: a frame or two of nothing is not
    /// worth a cut.
    static let minimumGapSec: Double = 0.05

    /// The parts of `0...total` outside `keep`, in order.
    static func gaps(keeping keep: [ClosedRange<Double>], total: Double) -> [ClosedRange<Double>] {
        var gaps: [ClosedRange<Double>] = []
        var cursor = 0.0
        for range in keep.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let start = min(max(range.lowerBound, 0), total)
            if start - cursor >= minimumGapSec { gaps.append(cursor...start) }
            cursor = max(cursor, min(range.upperBound, total))
        }
        if total - cursor >= minimumGapSec { gaps.append(cursor...total) }
        return gaps
    }

    /// Takes everything outside `keep` out of `composition`.
    static func removeGaps(keeping keep: [ClosedRange<Double>], from composition: AVMutableComposition) {
        // From the end, so the earlier gaps keep their times.
        for gap in gaps(keeping: keep, total: composition.duration.seconds).reversed() {
            composition.removeTimeRange(CMTimeRange(
                start: CMTime(seconds: gap.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: gap.upperBound, preferredTimescale: 600)
            ))
        }
    }

    /// The cut take with its own soundtrack, for the preview.
    @MainActor
    static func playerItem(videoURL: URL, keep: [ClosedRange<Double>]) async throws -> AVPlayerItem {
        let composition = AVMutableComposition()
        _ = try await StudioSoundAudio.insertVideo(of: videoURL, into: composition, includeOriginalAudio: true)
        removeGaps(keeping: keep, from: composition)
        return AVPlayerItem(asset: composition)
    }

    /// The cut take as a temporary .mov for the Photos library, with the
    /// processed soundtrack when `studioAudioURL` is given. Re-encoded:
    /// a passthrough copy keeps the cuts only as an edit list, which some
    /// editors ignore, bringing the gaps back. The caller deletes the file.
    /// `studioIsCut`: the processed audio covers the cut only, on its
    /// timeline (`Recording.studioCutData`).
    static func export(
        videoURL: URL,
        studioAudioURL: URL?,
        keep: [ClosedRange<Double>],
        studioIsCut: Bool = false
    ) async throws -> URL {
        let composition = AVMutableComposition()
        let audioStart = try await StudioSoundAudio.insertVideo(
            of: videoURL, into: composition, includeOriginalAudio: studioAudioURL == nil
        )
        if let studioAudioURL, studioIsCut {
            removeGaps(keeping: keep, from: composition)
            _ = try await StudioSoundAudio.insertStudioAudio(studioAudioURL, into: composition, at: .zero)
        } else {
            if let studioAudioURL {
                _ = try await StudioSoundAudio.insertStudioAudio(studioAudioURL, into: composition, at: audioStart)
            }
            removeGaps(keeping: keep, from: composition)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cut-export-\(UUID().uuidString).mov")
        try await StudioSoundAudio.export(composition, preset: AVAssetExportPresetHighestQuality, to: outputURL, as: .mov)
        return outputURL
    }
}
