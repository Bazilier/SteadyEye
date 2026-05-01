import Foundation
import AVFoundation
import CoreVideo

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
    func startRecording(to url: URL, videoSize: CGSize, fps: Int) throws {
        precondition(state == .idle, "AssetWriterRecorder.startRecording called from non-idle state")

        // Pre-condition: writer fails if the file already exists.
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false

        // Video input — BGRA in (from composer), H.264 out.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate(for: videoSize, fps: fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: max(fps, 30)
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        // Source pixel format for the adaptor. BGRA matches what
        // CIContext.render writes; the H.264 encoder accepts BGRA via the
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

        guard adaptor.assetWriterInput.isReadyForMoreMediaData else { return }
        adaptor.append(pixelBuffer, withPresentationTime: pts)
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

    /// H.264 bitrate. ~6.5 Mbps for 1080p30, scales with pixel count and
    /// frame rate at 0.1 bits/pixel — a rough industry default for "good"
    /// H.264 quality. Tune if side-by-side reveals visible compression.
    private func bitRate(for size: CGSize, fps: Int) -> Int {
        let pixels = Int(size.width * size.height)
        let bitsPerPixel = 0.1
        let scaledFPS = max(fps, 30)
        return Int(Double(pixels) * bitsPerPixel * Double(scaledFPS))
    }
}
