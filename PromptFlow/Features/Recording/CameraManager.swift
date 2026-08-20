import AVFoundation
import UIKit
import SwiftUI
import Combine
import FirebaseCrashlytics
import os

final class CameraManager: NSObject, ObservableObject {
    static let shared = CameraManager()

    // MARK: - Public state
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var cameraPosition: AVCaptureDevice.Position = .front
    @Published var lastRecordedURL: URL?
    @Published var saveDirectlyOnStop = false
    @Published var isSessionReady = false
    @Published var isAudioReady = false
    @Published var audioSourceName: String = String(
        localized: "camera.audio.iPhoneMic",
        defaultValue: "iPhone Microphone",
        comment: "Default audio source name in the recording HUD."
    )
    @Published var audioRouteToast: String?

    // MARK: - Private
    private static let cameraQueue = DispatchQueue(label: "com.steadyeye.camera", qos: .userInitiated)
    /// Single serial queue for both video and audio data outputs. Apple
    /// requires AVAssetWriter appends to be serialized; sharing the queue
    /// across both outputs guarantees that without explicit locking.
    private static let sampleBufferQueue = DispatchQueue(label: "com.steadyeye.samplebuffers", qos: .userInitiated)
    let session = AVCaptureSession()
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var audioDataOutput: AVCaptureAudioDataOutput?

    /// Optional fan-out for audio sample buffers on `sampleBufferQueue`.
    /// Set by `RecordingView` when Follow-My-Voice is active so the FMV
    /// service can compute RMS + feed SFSpeechRecognizer without spinning
    /// up a separate AVAudioEngine. Called AFTER the asset writer has
    /// consumed the buffer so the file's audio track is unaffected.
    /// Read concurrently across `sampleBufferQueue` and the main thread
    /// (when set/cleared) — the `ifNotNil` check tolerates the race.
    var audioBufferBroadcast: ((CMSampleBuffer) -> Void)?
    private var assetWriterRecorder: AssetWriterRecorder?
    private var watermarkComposer: RealtimeWatermarkComposer?
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private(set) var lastRecordingDuration: TimeInterval = 0
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var routeChangeObserver: NSObjectProtocol?

    // MARK: - Rotation (RotationCoordinator-driven)
    /// Retained for the lifetime of the session so its KVO keeps firing.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    /// Rotation angle currently applied to the video connection. Only ever a
    /// portrait-producing angle (90 or 270). Frozen while recording is active.
    private var appliedRotationAngle: CGFloat = 90
    /// True between record start and stop. While true the RotationCoordinator
    /// KVO handler logs but does NOT apply angle changes — the writer's
    /// videoSize is fixed at record start and buffer dimensions must not change.
    private var isRecordingActive = false
    /// A portrait angle reported while recording was active (therefore
    /// suppressed); applied after recording stops.
    private var pendingRotationAngle: CGFloat?
    private let camLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kirillvasilyev.SteadyEye",
        category: "CameraDiagnostic"
    )

    #if DEV
    /// DEV-ONLY reproduction hook (does not exist in release builds). When
    /// non-nil, the video connection's rotation angle is forced to this raw
    /// value, bypassing the RotationCoordinator result and the portrait clamp,
    /// while `appliedRotationAngle` (and therefore the writer's videoSize) is
    /// left untouched. Set to `0` to deliver LANDSCAPE buffers into a PORTRAIT
    /// writer — reproducing the confirmed field artifact (correct portrait
    /// container, rotated + horizontally squeezed image). The first-sample
    /// buffer mismatch guard still fires. Default nil (off). Flip in code only:
    /// no UI, no settings, no remote config.
    static var debugForcedRotationAngle: CGFloat?
    #endif

    /// Hardware model identifier (e.g. "iPhone16,1") for diagnostics.
    private static var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    /// Clamps `reported` to a portrait angle (90 or 270) and applies it to
    /// `connection`, updating `appliedRotationAngle`. Portrait-locked product:
    /// 0/180 are never applied (keep last portrait angle, log the clamp); if
    /// the chosen angle isn't supported, fall back to 90 and log it. Returns
    /// the angle actually applied.
    @discardableResult
    private func applyClampedRotation(reported: CGFloat, to connection: AVCaptureConnection) -> CGFloat {
        #if DEV
        // DEV-only override: force the connection to a raw angle and leave
        // `appliedRotationAngle` (hence the writer's videoSize) unchanged, so a
        // forced value of 0 delivers landscape buffers into a portrait writer.
        // The mismatch guard downstream still fires — this only changes what is
        // applied to the connection, not the diagnostics.
        if let forced = Self.debugForcedRotationAngle {
            let unchanged = Int(appliedRotationAngle)
            let supported = connection.isVideoRotationAngleSupported(forced)
            if supported {
                connection.videoRotationAngle = forced
            }
            camLog.notice("event=rotation_debug_override forced=\(Int(forced)) applied_unchanged=\(unchanged) supported=\(supported)")
            return appliedRotationAngle
        }
        #endif
        var target = appliedRotationAngle
        if reported == 90 || reported == 270 {
            target = reported
        } else {
            camLog.error("event=rotation_clamp reported=\(Int(reported)) applied=\(Int(target)) clamped=true")
        }
        if !connection.isVideoRotationAngleSupported(target) {
            camLog.error("event=rotation_fallback requested=\(Int(target)) applied=90 supported=false")
            target = 90
        }
        if connection.isVideoRotationAngleSupported(target) {
            connection.videoRotationAngle = target
        }
        appliedRotationAngle = target
        return target
    }

    /// RotationCoordinator KVO handler. Freezes the applied angle while a
    /// recording is active (logs suppressed=true, stashes a pending portrait
    /// angle); otherwise applies the clamped angle immediately.
    private func handleRotationChange(_ coordinator: AVCaptureDevice.RotationCoordinator) {
        let reported = coordinator.videoRotationAngleForHorizonLevelCapture
        guard let connection = videoDataOutput?.connection(with: .video) else { return }
        let old = appliedRotationAngle
        if isRecordingActive {
            pendingRotationAngle = (reported == 90 || reported == 270) ? reported : old
            camLog.notice("event=rotation_change old=\(Int(old)) new=\(Int(reported)) suppressed=true")
            return
        }
        applyClampedRotation(reported: reported, to: connection)
        camLog.notice("event=rotation_change old=\(Int(old)) new=\(Int(reported)) suppressed=false")
    }

    private override init() {
        super.init()
    }

    // MARK: - Chromakey background mode (DEV)

    /// Single source of truth for chromakey mockup mode. When true, the
    /// camera preview renders a solid #00B140 fill and the capture session
    /// is not started — used for recording UI mockup videos where real
    /// footage is composited behind the SteadyEye interface in post.
    /// Read once per view lifecycle; toggle changes require re-entering RecordingView.
    static var isChromakeyActive: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        #if DEV
        return UserDefaults.standard.bool(forKey: "dev_chromakey_enabled")
        #else
        return false
        #endif
        #endif
    }

    // MARK: - Start / Stop

    func start(position: AVCaptureDevice.Position = .front) {
        cameraPosition = position
        if Self.isChromakeyActive {
            // No real camera (Simulator) or chromakey mockup mode — mark
            // session ready immediately so UI is fully interactive.
            isSessionReady = true
            isAudioReady = true
            return
        }
        #if !targetEnvironment(simulator)
        Self.cameraQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                DispatchQueue.main.async { self.isSessionReady = true }
                return
            }
            self.setupSession(position: position)
        }
        #endif
    }

    func stop() {
        if Self.isChromakeyActive {
            isSessionReady = false
            isAudioReady = false
            return
        }
        #if !targetEnvironment(simulator)
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
        // Tear down the RotationCoordinator KVO so no observation survives a
        // session stop (there is no deinit).
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
        Self.cameraQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            DispatchQueue.main.async {
                self.isSessionReady = false
                self.isAudioReady = false
            }
        }
        #endif
    }

    // MARK: - Phase 1: Video + audio with built-in mic (instant)

    #if !targetEnvironment(simulator)
    private func setupSession(position: AVCaptureDevice.Position) {
        session.automaticallyConfiguresApplicationAudioSession = false

        // Audio session with built-in mic only (no Bluetooth yet — instant)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
        try? audioSession.setActive(true)

        let resolution = UserDefaults.standard.string(forKey: "videoResolution") ?? "1080p"
        let fps = UserDefaults.standard.integer(forKey: "videoFPS")
        let targetFPS = fps > 0 ? fps : 30

        session.beginConfiguration()

        let want4K = resolution == "4k"
        let allow4K = SubscriptionManager.shared.canRecord4K
        if want4K && allow4K && session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else {
            session.sessionPreset = .hd1920x1080
        }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        // Video input
        guard let videoDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: position
        ) else {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = String(
                    localized: "camera.error.notAvailable",
                    defaultValue: "Camera not available.",
                    comment: "Shown when the requested camera is not available on this device."
                )
            }
            return
        }

        do {
            let vInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(vInput) { session.addInput(vInput) }
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = String(
                    localized: "camera.error.failedToAccess",
                    defaultValue: "Failed to access camera: \(error.localizedDescription)",
                    comment: "Camera access failure with system-localized error description."
                )
            }
            return
        }

        // Frame rate
        do {
            try videoDevice.lockForConfiguration()
            let desiredFPS = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            let supported = videoDevice.activeFormat.videoSupportedFrameRateRanges.contains {
                Int($0.maxFrameRate) >= targetFPS
            }
            if supported {
                videoDevice.activeVideoMinFrameDuration = desiredFPS
                videoDevice.activeVideoMaxFrameDuration = desiredFPS
            } else {
                let fallback = CMTime(value: 1, timescale: 30)
                videoDevice.activeVideoMinFrameDuration = fallback
                videoDevice.activeVideoMaxFrameDuration = fallback
            }
            videoDevice.unlockForConfiguration()
        } catch {}

        // Audio input (built-in mic — instant, no BT negotiation)
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let aInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(aInput) {
            session.addInput(aInput)
        }

        // Outputs: video data + audio data. Sample buffers go through the
        // realtime watermark composer and into AVAssetWriter via
        // AssetWriterRecorder. Both delegates fire on `sampleBufferQueue`
        // so writer appends are naturally serialized.
        videoDataOutput = nil
        audioDataOutput = nil

        let videoData = AVCaptureVideoDataOutput()
        videoData.alwaysDiscardsLateVideoFrames = true
        videoData.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoData.setSampleBufferDelegate(self, queue: Self.sampleBufferQueue)
        if session.canAddOutput(videoData) {
            session.addOutput(videoData)
            videoDataOutput = videoData
        }

        let audioData = AVCaptureAudioDataOutput()
        audioData.setSampleBufferDelegate(self, queue: Self.sampleBufferQueue)
        if session.canAddOutput(audioData) {
            session.addOutput(audioData)
            audioDataOutput = audioData
        }

        session.commitConfiguration()

        // Stabilization + portrait orientation on the video data output's
        // connection. Set BEFORE startRunning to avoid a crop jump.
        let stabilizePref = UserDefaults.standard.object(forKey: "stabilizationEnabled") as? Bool ?? true
        let stabilize = stabilizePref && canUseStabilization
        // Tear down any coordinator/observation from a previous configuration
        // (e.g. switchCamera re-entry) before building a new one.
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
        if let connection = videoDataOutput?.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = stabilize ? .cinematic : .off
            }
            // Drive rotation from the horizon-level capture angle via
            // RotationCoordinator instead of a single-shot 90° assignment.
            let coordinator = AVCaptureDevice.RotationCoordinator(device: videoDevice, previewLayer: nil)
            rotationCoordinator = coordinator
            applyClampedRotation(reported: coordinator.videoRotationAngleForHorizonLevelCapture, to: connection)
            rotationObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelCapture,
                options: [.new]
            ) { [weak self] coord, _ in
                // KVO delivered on the main queue.
                self?.handleRotationChange(coord)
            }
        }

        // Diagnostic: session configuration complete.
        if let connection = videoDataOutput?.connection(with: .video) {
            let dims = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
            camLog.notice(
                "event=session_config_complete device_model=\(Self.deviceModelIdentifier, privacy: .public) active_format=\(dims.width)x\(dims.height) preset=\(self.session.sessionPreset.rawValue, privacy: .public) rotation_angle=\(Int(connection.videoRotationAngle)) angle_supported=\(connection.isVideoRotationAngleSupported(connection.videoRotationAngle))"
            )
        }

        session.startRunning()

        // Exposure needs a running session
        let exposure = UserDefaults.standard.double(forKey: "exposureCompensation")
        if exposure != 0 { setExposureCompensation(Float(exposure)) }

        DispatchQueue.main.async { [weak self] in
            self?.isSessionReady = true
        }
        // Phase 2: enable Bluetooth audio routing (non-blocking, no session reconfig)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.enableBluetoothAudio()
        }
    }

    // MARK: - Phase 2: Bluetooth audio routing (no capture session changes)

    private func enableBluetoothAudio() {
        // BT off by default — AirPods etc. force HFP profile (16kHz mono,
        // telephony-grade) when used as input, often worse than the built-in
        // mic. User opt-in via Settings → "Allow Bluetooth microphones".
        // Wired/USB mics (DJI, Rode, Shure) are unaffected by this flag —
        // they win via iOS default routing priority regardless.
        let useBluetoothMic = UserDefaults.standard.bool(forKey: "useBluetoothMic")
        let audioSession = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = useBluetoothMic
            ? [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
            : [.defaultToSpeaker]
        try? audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: options)

        // Prefer Bluetooth if available — only when the user has opted in.
        if useBluetoothMic, let btInput = audioSession.availableInputs?.first(where: {
            $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE || $0.portType == .bluetoothA2DP
        }) {
            try? audioSession.setPreferredInput(btInput)
        }

        // Route change observer
        if routeChangeObserver == nil {
            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                self.updateAudioSourceName()
                guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
                if self.isRecording {
                    switch reason {
                    case .oldDeviceUnavailable:
                        self.audioRouteToast = String(
                            localized: "camera.audio.toast.switchedToBuiltin",
                            defaultValue: "Switched to iPhone microphone",
                            comment: "Toast when audio route falls back to the built-in mic."
                        )
                    case .newDeviceAvailable:
                        self.audioRouteToast = String(
                            localized: "camera.audio.toast.newMicDetected",
                            defaultValue: "New mic detected. Will use on next recording.",
                            comment: "Toast when a new external mic is connected."
                        )
                    default: break
                    }
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.isAudioReady = true
            self?.updateAudioSourceName()
        }
    }
    #endif // !targetEnvironment(simulator)

    // MARK: - Exposure & Stabilization

    private var currentCamera: AVCaptureDevice? {
        session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .first(where: { $0.hasMediaType(.video) })
    }

    func setExposureCompensation(_ value: Float) {
        #if !targetEnvironment(simulator)
        guard let device = currentCamera else { return }
        let clamped = max(device.minExposureTargetBias, min(value, device.maxExposureTargetBias))
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(clamped) { _ in }
            device.unlockForConfiguration()
        } catch {}
        #endif
    }

    /// Mirrors `SubscriptionManager.canUseStabilization` so the camera setup
    /// sites have a local short-name. Stabilization is paid-only.
    private var canUseStabilization: Bool {
        SubscriptionManager.shared.isSubscribed
    }

    func setStabilization(_ enabled: Bool) {
        #if !targetEnvironment(simulator)
        guard currentCamera != nil else { return }
        let allowed = enabled && canUseStabilization
        if let connection = videoDataOutput?.connection(with: .video),
           connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = allowed ? .auto : .off
        }
        #endif
    }

    func applySavedSettings() {
        let exposure = UserDefaults.standard.double(forKey: "exposureCompensation")
        setExposureCompensation(Float(exposure))
        let stabilization = UserDefaults.standard.object(forKey: "stabilizationEnabled") as? Bool ?? true
        setStabilization(stabilization)
    }

    // MARK: - Camera switching

    func switchCamera() {
        #if !targetEnvironment(simulator)
        let newPosition: AVCaptureDevice.Position = (cameraPosition == .front) ? .back : .front
        cameraPosition = newPosition
        Self.cameraQueue.async { [weak self] in
            guard let self else { return }
            self.setupSession(position: newPosition)
        }
        #endif
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }

        if Self.isChromakeyActive {
            // Fake recording: flip UI state and start the duration timer — no AVCapture calls.
            #if DEV
            print("[chromakey] recording skipped — chromakey mode active")
            #endif
            recordingStartTime = Date()
            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
            isRecording = true
            return
        }

        #if !targetEnvironment(simulator)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        // Freeze the rotation angle for the duration of the take before any
        // buffers can reach a writer whose videoSize is fixed at start.
        isRecordingActive = true

        Self.cameraQueue.async { [weak self] in
            self?.startWriterPipeline(outputURL: outputURL)
        }

        recordingStartTime = Date()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            self.recordingDuration = Date().timeIntervalSince(start)
        }
        isRecording = true
        #endif
    }

    #if !targetEnvironment(simulator)
    /// Allocates the writer and composer, hooks the writer's pixel buffer
    /// pool into the composer, and starts the writer (encoder allocation).
    /// After this returns, the AVCaptureVideoDataOutput /
    /// AVCaptureAudioDataOutput delegate methods can deliver sample
    /// buffers to the recorder via the composer.
    private func startWriterPipeline(outputURL: URL) {
        // Output frame size derived from the ACTIVE format at record time
        // (not the session preset — the active format can change after
        // startRunning). Width/height are swapped for portrait-producing
        // rotation so writer dimensions match the delivered buffers. The
        // angle is captured into a local constant here (frozen for the take)
        // and reused for both the swap and the recording-start log.
        let recordingAngle = appliedRotationAngle
        let videoSize: CGSize
        if let dims = currentCamera.map({ CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }) {
            let w = CGFloat(dims.width)
            let h = CGFloat(dims.height)
            if recordingAngle == 90 || recordingAngle == 270 {
                videoSize = CGSize(width: min(w, h), height: max(w, h))
            } else {
                videoSize = CGSize(width: max(w, h), height: min(w, h))
            }
        } else {
            // Defensive fallback: preserve prior preset-based behavior.
            switch session.sessionPreset {
            case .hd4K3840x2160:
                videoSize = CGSize(width: 2160, height: 3840)
            default:
                videoSize = CGSize(width: 1080, height: 1920)
            }
        }
        let fps = UserDefaults.standard.integer(forKey: "videoFPS")
        let targetFPS = fps > 0 ? fps : 30

        let isPro = !SubscriptionManager.shared.showWatermark
        let composer = RealtimeWatermarkComposer(renderSize: videoSize, isPro: isPro)
        let recorder = AssetWriterRecorder()

        do {
            // `composerPath` tells the recorder which composer path is active
            // so a sampled dimension mismatch can be logged as pro (unrecoverable —
            // encoder rescales) vs free. Mirrors the composer's `isPro` branch.
            try recorder.startRecording(to: outputURL, videoSize: videoSize, fps: targetFPS, composerPath: isPro ? "pro" : "free")
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = String(
                    localized: "camera.error.recordingError",
                    defaultValue: "Recording error: \(error.localizedDescription)",
                    comment: "Recording session error with system-localized error description."
                )
            }
            return
        }

        // Diagnostic: recording start. Active format is re-read here because it
        // can diverge from the config-time format after startRunning.
        let quality = (session.sessionPreset == .hd4K3840x2160) ? "4K" : "1080p"
        let recDims = currentCamera.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
        let stabMode = videoDataOutput?.connection(with: .video)?.preferredVideoStabilizationMode
        camLog.notice(
            "event=recording_start writer_size=\(Int(videoSize.width))x\(Int(videoSize.height)) applied_angle=\(Int(recordingAngle)) quality=\(quality, privacy: .public) active_format=\(recDims?.width ?? -1)x\(recDims?.height ?? -1) preset=\(self.session.sessionPreset.rawValue, privacy: .public) stabilization=\(stabMode?.rawValue ?? -1)"
        )

        if let pool = recorder.pixelBufferPool {
            composer.setPixelBufferPool(pool)
        }

        self.watermarkComposer = composer
        self.assetWriterRecorder = recorder
    }
    #endif

    func stopRecording() {
        guard isRecording else { return }

        let elapsed = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        lastRecordingDuration = elapsed
        AppAnalytics.log("recording_stopped", params: [
            "duration_sec": Int(elapsed.rounded()),
            "display_mode": UserDefaults.standard.string(forKey: "teleprompterMode") ?? "wbw"
        ])

        durationTimer?.invalidate()
        durationTimer = nil
        isRecording = false
        recordingDuration = 0
        recordingStartTime = nil

        // Recording is no longer active — unfreeze rotation and apply any
        // angle change that arrived (and was suppressed) mid-take.
        isRecordingActive = false
        if let pending = pendingRotationAngle {
            pendingRotationAngle = nil
            if let connection = videoDataOutput?.connection(with: .video) {
                let old = appliedRotationAngle
                applyClampedRotation(reported: pending, to: connection)
                camLog.notice("event=rotation_change old=\(Int(old)) new=\(Int(pending)) suppressed=false")
            }
        }

        if Self.isChromakeyActive {
            // No file to write — nothing to do. lastRecordedURL stays nil so VideoPreviewView is not triggered.
            return
        }

        #if !targetEnvironment(simulator)
        // Register background task so the video file finishes writing even if app is backgrounded
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
        Self.cameraQueue.async { [weak self] in
            self?.stopWriterPipeline()
        }
        #endif
    }

    #if !targetEnvironment(simulator)
    /// Marks the writer's inputs as finished, finalizes the file, and hops
    /// to main with the resulting URL. Honors the
    /// `lastRecordedURL` / `saveDirectlyOnStop` contract that downstream
    /// consumers (RecordingView, scenePhase autosave) rely on.
    private func stopWriterPipeline() {
        guard let recorder = assetWriterRecorder else {
            DispatchQueue.main.async { [weak self] in self?.endBackgroundTask() }
            return
        }
        recorder.stopRecording { [weak self] result in
            // Don't nil out assetWriterRecorder / watermarkComposer here —
            // sampleBufferQueue may still hold a reference and clearing it
            // mid-flight can race with concurrent reads. The recorder's
            // internal state machine (`.finishing` / `.finished`) silently
            // drops late appends, and the next startWriterPipeline
            // replaces both properties wholesale.
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.endBackgroundTask() }
                switch result {
                case .success(let url):
                    if self.saveDirectlyOnStop {
                        self.handleSaveDirectlyOnStop(url: url)
                    } else {
                        self.lastRecordedURL = url
                    }
                case .failure(let error):
                    // Writer-level failure (AVAssetWriter status != .completed).
                    // This path never sets `lastRecordedURL`, so RecordingView's
                    // persist flow — and its own `recording_failed` — is never
                    // reached. Without this the take is invisible to analytics:
                    // `recording_stopped` fires either way, so a failed write
                    // looks exactly like a user stopping after a second.
                    // Same parameter shape as `recording_stopped` above;
                    // `error_reason` is the NSError domain/code rather than
                    // `localizedDescription`, which would fragment across the
                    // app's four locales.
                    let nsError = error as NSError
                    AppAnalytics.log("recording_failed", params: [
                        "duration_sec": Int(self.lastRecordingDuration.rounded()),
                        "display_mode": UserDefaults.standard.string(forKey: "teleprompterMode") ?? "wbw",
                        "error_reason": "\(nsError.domain)/\(nsError.code)"
                    ])
                    self.errorMessage = String(
                        localized: "camera.error.recordingError",
                        defaultValue: "Recording error: \(error.localizedDescription)",
                        comment: "Recording session error with system-localized error description."
                    )
                    #if !DEV
                    Crashlytics.crashlytics().record(error: error)
                    #endif
                }
            }
        }
    }

    /// Autosave path for scenePhase-while-recording. The file already has
    /// the watermark burned in (or doesn't, for Pro users) by the realtime
    /// pipeline, so no post-process step is needed — direct hand-off to
    /// PhotoKit.
    @MainActor
    private func handleSaveDirectlyOnStop(url: URL) {
        saveDirectlyOnStop = false
        let durationSec = Int(lastRecordingDuration.rounded())
        let wasFirst = UserDefaults.standard.bool(forKey: "hasCompletedFirstRecording")
        UISaveVideoAtPathToSavedPhotosAlbum(url.path, nil, nil, nil)
        AppAnalytics.log("recording_saved", params: [
            "duration_sec": durationSec,
            "was_first": wasFirst,
            "via": "background_autosave"
        ])
    }
    #endif

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func updateAudioSourceName() {
        #if !targetEnvironment(simulator)
        let input = AVAudioSession.sharedInstance().currentRoute.inputs.first
        audioSourceName = input?.portName ?? String(
            localized: "camera.audio.iPhoneMic",
            defaultValue: "iPhone Microphone",
            comment: "Default audio source name in the recording HUD."
        )
        #endif
    }
}

// MARK: - Video + audio data output delegates

#if !targetEnvironment(simulator)
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Delivered on `sampleBufferQueue` (set in setupSession). Both
        // outputs share this queue so AVAssetWriter's serialization
        // contract is satisfied without explicit locking.
        if output is AVCaptureAudioDataOutput {
            assetWriterRecorder?.appendAudio(sampleBuffer)
            audioBufferBroadcast?(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let processed = watermarkComposer?.process(pixelBuffer) ?? pixelBuffer
        assetWriterRecorder?.appendVideo(processed, pts: pts)
    }
}
#endif
