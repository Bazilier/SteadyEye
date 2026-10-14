import AVFoundation

/// The AVFoundation half of Studio Sound: lift a recording's audio track out,
/// and lay a processed one back under the video.
///
/// The video is never re-encoded. The processed audio replaces the original
/// track at the original track's own start time, so lip sync is exactly what
/// the recording had.
enum StudioSoundAudio {

    enum AudioError: Error {
        case noAudioTrack
        case noVideoTrack
        case exportFailed
        /// The processed audio is not as long as the original. Never laid
        /// under the video: something was cut, and sync would drift.
        case lengthMismatch(original: Double, processed: Double)
    }

    /// Longer or shorter than the original by more than this is a mismatch.
    /// Both sides are measured by AVFoundation, which already accounts for
    /// AAC priming, so a real cut shows up as far more than this.
    static let lengthTolerance: Double = 0.1

    // MARK: - Extract

    /// Copies the recording's audio track, without re-encoding, into an .m4a.
    static func extractAudio(from videoURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioError.noAudioTrack
        }
        let range = try await source.load(.timeRange)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw AudioError.exportFailed }
        try track.insertTimeRange(range, of: source, at: .zero)
        do {
            try await export(composition, preset: AVAssetExportPresetPassthrough, to: outputURL, as: .m4a)
        } catch {
            // Passthrough can refuse a track it cannot copy into .m4a as-is;
            // a re-encode costs a little quality, nothing else.
            try await export(composition, preset: AVAssetExportPresetAppleM4A, to: outputURL, as: .m4a)
        }
    }

    // MARK: - Finish

    /// Turns the downloaded lossless result into the AAC file kept next to
    /// the recording, after checking it is exactly as long as the original.
    static func finishProcessedAudio(downloadedURL: URL, videoURL: URL, to outputURL: URL) async throws {
        let original = try await audioDuration(ofVideoAt: videoURL)
        let processed = try await AVURLAsset(url: downloadedURL).load(.duration).seconds
        guard abs(original - processed) <= lengthTolerance else {
            throw AudioError.lengthMismatch(original: original, processed: processed)
        }
        try await export(
            AVURLAsset(url: downloadedURL),
            preset: AVAssetExportPresetAppleM4A,
            to: outputURL,
            as: .m4a
        )
    }

    // MARK: - Playback

    /// A player item carrying both soundtracks, and one audio mix for each,
    /// so the preview can switch between them without stopping playback.
    struct PlayerItem {
        let item: AVPlayerItem
        let studioMix: AVAudioMix
        let originalMix: AVAudioMix
    }

    @MainActor
    static func makePlayerItem(videoURL: URL, studioAudioURL: URL, useStudio: Bool) async throws -> PlayerItem {
        let composition = AVMutableComposition()
        let audioStart = try await insertVideo(of: videoURL, into: composition, includeOriginalAudio: true)
        let studioTrack = try await insertStudioAudio(studioAudioURL, into: composition, at: audioStart)

        let originalTrack = composition.tracks(withMediaType: .audio).first { $0 !== studioTrack }
        let studioMix = mix(audible: studioTrack, muted: originalTrack)
        let originalMix = mix(audible: originalTrack, muted: studioTrack)

        let item = AVPlayerItem(asset: composition)
        item.audioMix = useStudio ? studioMix : originalMix
        return PlayerItem(item: item, studioMix: studioMix, originalMix: originalMix)
    }

    // MARK: - Save

    /// The recording with its processed audio, as a temporary .mov for the
    /// Photos library. The caller deletes it once saved.
    static func exportWithStudioAudio(videoURL: URL, studioAudioURL: URL) async throws -> URL {
        let composition = AVMutableComposition()
        let audioStart = try await insertVideo(of: videoURL, into: composition, includeOriginalAudio: false)
        _ = try await insertStudioAudio(studioAudioURL, into: composition, at: audioStart)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-export-\(UUID().uuidString).mov")
        try await export(composition, preset: AVAssetExportPresetPassthrough, to: outputURL, as: .mov)
        return outputURL
    }

    // MARK: - Helpers

    static func audioDuration(ofVideoAt url: URL) async throws -> Double {
        // Held in a local: a track does not keep its asset alive, and a
        // track whose asset is gone fails every later call (-12780).
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioError.noAudioTrack
        }
        return try await track.load(.timeRange).duration.seconds
    }

    /// Inserts the video track (and, if asked, the original audio) at their
    /// own times. Returns where the original audio starts — where the
    /// processed audio must start too.
    private static func insertVideo(
        of videoURL: URL,
        into composition: AVMutableComposition,
        includeOriginalAudio: Bool
    ) async throws -> CMTime {
        let asset = AVURLAsset(url: videoURL)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else { throw AudioError.noVideoTrack }
        let videoRange = try await sourceVideo.load(.timeRange)
        try videoTrack.insertTimeRange(videoRange, of: sourceVideo, at: videoRange.start)
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

        guard let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioError.noAudioTrack
        }
        let audioRange = try await sourceAudio.load(.timeRange)
        if includeOriginalAudio,
           let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try audioTrack.insertTimeRange(audioRange, of: sourceAudio, at: audioRange.start)
        }
        return audioRange.start
    }

    /// Inserts the processed audio at `start`, trimmed so it never runs past
    /// the end of the composition's video.
    private static func insertStudioAudio(
        _ url: URL,
        into composition: AVMutableComposition,
        at start: CMTime
    ) async throws -> AVMutableCompositionTrack {
        let asset = AVURLAsset(url: url)  // kept alive for the insert below
        guard let source = try await asset.loadTracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else { throw AudioError.noAudioTrack }
        let range = try await source.load(.timeRange)
        let videoEnd = composition.tracks(withMediaType: .video).first?.timeRange.end ?? range.duration
        let duration = CMTimeMinimum(range.duration, CMTimeSubtract(videoEnd, start))
        try track.insertTimeRange(CMTimeRange(start: range.start, duration: duration), of: source, at: start)
        return track
    }

    private static func mix(audible: AVAssetTrack?, muted: AVAssetTrack?) -> AVAudioMix {
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [(audible, Float(1)), (muted, Float(0))].compactMap { track, volume in
            guard let track else { return nil }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(volume, at: .zero)
            return parameters
        }
        return audioMix
    }

    private static func export(
        _ asset: AVAsset,
        preset: String,
        to outputURL: URL,
        as fileType: AVFileType
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AudioError.exportFailed
        }
        if #available(iOS 18.0, *) {
            try await session.export(to: outputURL, as: fileType)
        } else {
            session.outputURL = outputURL
            session.outputFileType = fileType
            await session.export()
            guard session.status == .completed else {
                throw session.error ?? AudioError.exportFailed
            }
        }
    }
}
