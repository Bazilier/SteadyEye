import Foundation
import AVFoundation
import CoreVideo
import VideoToolbox
import os

/// AVAssetWriter wrapper for the realtime burn-in pipeline. Owns a video
/// input (with a pixel buffer adaptor for composer-produced BGRA frames)
/// and an audio input (PCM passthrough → AAC encoder).
///
/// Threading: Apple's contract is that all `append(...)` calls on a single
/// AVAssetWriterInput must be serialized. The caller (CameraManager) is
/// responsible for delivering sample buffers from a single serial queue
/// (the `sampleBufferQueue` shared by both data outputs). The writer
/// callback for `finishWriting` runs on a writer-internal queue — caller
/// is responsible for hopping back to its own queue if needed.
final class AssetWriterRecorder {
    enum State {
        case idle
        case recording
        case finishing
        case finished
        case failed
    }

    private(set) var state: State = .idle
    private(set) var outputURL: URL?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var sessionStartedAtPTS: CMTime?

    private let camLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kirillvasilyev.SteadyEye",
        category: "CameraDiagnostic"
    )
    /// Writer's configured output size, captured at `startRecording` for the
    /// multi-frame dimension sampling and finish diagnostics.
    private var configuredVideoSize: CGSize = .zero
    /// Active composer path ("pro" pass-through vs "free" render-to-pool),
    /// supplied by the caller. Reported on a sampled `buffer_dims` mismatch: on
    /// the pro path a mismatch is unrecoverable (the encoder silently rescales
    /// the frame → rotated + stretched output).
    private var composerPath = "free"
    /// Frame index from the start of the recording, used to drive dimension
    /// sampling. Per-frame hot-path cost is this increment plus a set-membership
    /// check; dimensions are read only on sampled frames.
    private var videoFrameIndex = 0
    /// Frame indices at which buffer dimensions are sampled + logged, after
    /// which sampling stops. A preset change can make AVFoundation deliver the
    /// opening buffers at the previous size before the new format settles, so we
    /// look across several early frames rather than trusting frame one.
    private static let dimSampleFrames: Set<Int> = [1, 2, 3, 5, 10, 30, 60]
    /// Count of SAMPLED frames whose dimensions did not match the writer size.
    private var mismatchedSampleCount = 0
    /// Total video frames appended to the writer, for the finish diagnostic.
    private var framesWritten = 0

    /// Pool the composer should use for output BGRA frames. Available only
    /// after `startRecording` returns successfully.
    var pixelBufferPool: CVPixelBufferPool? {
        pixelBufferAdaptor?.pixelBufferPool
    }

    /// Configures the writer for the given output dimensions and frame rate,
    /// calls `startWriting()` (allocates the encoder), and leaves the
    /// instance in `.recording` state. The writer's session has NOT yet
    /// been started — that happens on the first appended video frame so the
    /// timeline starts at the actual first-frame PTS rather than 0.
    func startRecording(to url: URL, videoSize: CGSize, fps: Int, composerPath: String = "free") throws {
        precondition(state == .idle, "AssetWriterRecorder.startRecording called from non-idle state")

        // Pre-condition: writer fails if the file already exists.
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false

        // Video input — BGRA in (from composer), HEVC out where supported.
        //
        // Codec: prefer HEVC when the device has a HEVC hardware codec. We gate
        // on `VTIsHardwareDecodeSupported` — technically a decode probe, but on
        // the iOS 17+ device floor (A12/iPhone XS and later) hardware HEVC
        // decode implies hardware HEVC encode, so it's a reliable, public,
        // allocation-free proxy for encode availability. H.264 is the fallback
        // and is effectively dead in practice on this floor; the
        // `encoder_config` log below makes the chosen codec unambiguous so an
        // unexpected H.264 landing is visible in the field.
        let useHEVC = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let codec: AVVideoCodecType = useHEVC ? .hevc : .h264

        // Resolution tier from the ACTUAL writer size (not the UserDefaults
        // setting): the portrait output is 2160x3840 (4K) or 1080x1920 (1080p).
        let is4K = videoSize.width >= 2160 || videoSize.height >= 2160

        // Explicit tiered average bitrate. The previous 0.1 bits-per-pixel
        // formula produced only ~24.9 Mbps for a 2160x3840 4K frame at 30 fps —
        // matching the measured 25.3 Mbps and roughly half of Apple's ~47 Mbps
        // for H.264 4K30, which is why detailed/moving 4K looked soft. These
        // fixed per-codec/per-tier values replace that formula rather than
        // re-tuning the bpp constant. Base values are quoted at 30 fps and
        // scaled linearly with fps.
        let baseBitrate30: Int
        switch (useHEVC, is4K) {
        case (true,  true):  baseBitrate30 = 30_000_000   // HEVC 4K
        case (true,  false): baseBitrate30 = 10_000_000   // HEVC 1080p
        case (false, true):  baseBitrate30 = 45_000_000   // H.264 4K (fallback)
        case (false, false): baseBitrate30 = 16_000_000   // H.264 1080p (fallback)
        }
        let targetBitrate = Int(Double(baseBitrate30) * Double(fps) / 30.0)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: targetBitrate,
            AVVideoMaxKeyFrameIntervalKey: fps,           // one keyframe per second
            AVVideoExpectedSourceFrameRateKey: fps
        ]
        // Preserve the explicit H.264 profile level on the fallback path only;
        // the constant is H.264-specific and invalid for HEVC, which uses the
        // encoder's default profile.
        if !useHEVC {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
            AVVideoCompressionPropertiesKey: compression
        ]

        // Diagnostic: encoder configuration at recording start.
        let codecName = useHEVC ? "hevc" : "h264"
        let bitrateMbps = targetBitrate / 1_000_000
        camLog.notice(
            "event=encoder_config codec=\(codecName, privacy: .public) bitrate_mbps=\(bitrateMbps) keyframe_interval=\(fps) fps=\(fps) videoSize=\(Int(videoSize.width))x\(Int(videoSize.height))"
        )

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        // Source pixel format for the adaptor. BGRA matches what
        // CIContext.render writes; the encoder accepts BGRA via the
        // adaptor's automatic format conversion. IOSurface backing keeps
        // the buffer GPU-resident from composer through encoder.
        let sourceAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(videoSize.width),
            kCVPixelBufferHeightKey as String: Int(videoSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourceAttrs
        )

        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "AssetWriterRecorder", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot add video input to writer"
            ])
        }
        writer.add(videoInput)

        // Audio input — PCM in (from capture session), AAC out. Mono
        // 44.1kHz to match the prior pipeline's defaults.
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 128_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(audioInput) else {
            throw NSError(domain: "AssetWriterRecorder", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Cannot add audio input to writer"
            ])
        }
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "AssetWriterRecorder", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "startWriting failed"
            ])
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.pixelBufferAdaptor = adaptor
        self.outputURL = url
        self.configuredVideoSize = videoSize
        self.composerPath = composerPath
        self.state = .recording
    }

    /// Appends a video frame. Lazily starts the writer's session on the
    /// first frame so the timeline begins at the actual first-frame PTS.
    /// Drops the frame silently if the encoder is back-pressuring (input
    /// not ready) — alternative would be to block, which violates the
    /// realtime delivery contract.
    func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard state == .recording,
              let writer = writer,
              let adaptor = pixelBufferAdaptor else { return }

        if sessionStartedAtPTS == nil {
            writer.startSession(atSourceTime: pts)
            sessionStartedAtPTS = pts
        }

        // Multi-frame dimension sampling (logging only — never auto-corrects or
        // re-encodes). Cheap per frame: an increment + a set-membership check;
        // dimensions are read only on sampled frames. A dimension mismatch on
        // the opening frames is a settling artifact after a preset change, so
        // the error is raised only if the mismatch is still present at frame 30.
        videoFrameIndex += 1
        if videoFrameIndex <= 60, Self.dimSampleFrames.contains(videoFrameIndex) {
            let frame = videoFrameIndex
            let bw = CVPixelBufferGetWidth(pixelBuffer)
            let bh = CVPixelBufferGetHeight(pixelBuffer)
            let cw = Int(configuredVideoSize.width)
            let ch = Int(configuredVideoSize.height)
            let path = composerPath
            let match = bw == cw && bh == ch
            if !match { mismatchedSampleCount += 1 }
            camLog.notice(
                "event=buffer_dims frame=\(frame) buffer=\(bw)x\(bh) writer_size=\(cw)x\(ch) match=\(match) path=\(path, privacy: .public)"
            )
            if !match, frame == 30 {
                camLog.error(
                    "event=first_sample_buffer_mismatch buffer=\(bw)x\(bh) writer_size=\(cw)x\(ch) path=\(path, privacy: .public)"
                )
            }
        }

        guard adaptor.assetWriterInput.isReadyForMoreMediaData else { return }
        adaptor.append(pixelBuffer, withPresentationTime: pts)
        framesWritten += 1
    }

    /// Appends an audio sample buffer. Skips audio that arrives before the
    /// first video frame so the audio track is aligned to the video
    /// timeline (Apple's AVCam pattern). Drops if the input isn't ready.
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard state == .recording,
              let audioInput = audioInput,
              sessionStartedAtPTS != nil,
              audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    /// Marks both inputs as finished and finalizes the file. The completion
    /// runs on a writer-internal queue — caller hops to its own queue.
    /// Sub-step 4 will harden interruption / failure handling; this is the
    /// happy-path implementation for the spike.
    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        guard state == .recording, let writer = writer else {
            completion(.failure(NSError(domain: "AssetWriterRecorder", code: -4, userInfo: [
                NSLocalizedDescriptionKey: "stopRecording called from non-recording state"
            ])))
            return
        }
        state = .finishing

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        writer.finishWriting { [weak self] in
            guard let self else { return }
            // Diagnostic: recording finish. `configuredVideoSize` is the cheap
            // final-dimensions signal (no AVAsset load needed).
            self.camLog.notice(
                "event=recording_finish status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "none", privacy: .public) final_size=\(Int(self.configuredVideoSize.width))x\(Int(self.configuredVideoSize.height)) frames_written=\(self.framesWritten) mismatched_frames=\(self.mismatchedSampleCount)"
            )
            switch writer.status {
            case .completed:
                self.state = .finished
                if let url = self.outputURL {
                    completion(.success(url))
                } else {
                    completion(.failure(NSError(domain: "AssetWriterRecorder", code: -5, userInfo: [
                        NSLocalizedDescriptionKey: "Output URL missing after finish"
                    ])))
                }
            default:
                self.state = .failed
                completion(.failure(writer.error ?? NSError(domain: "AssetWriterRecorder", code: -6, userInfo: [
                    NSLocalizedDescriptionKey: "Writer finished with status \(writer.status.rawValue)"
                ])))
            }
        }
    }
}
