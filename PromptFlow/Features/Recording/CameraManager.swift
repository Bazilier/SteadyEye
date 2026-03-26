import AVFoundation
import UIKit
import SwiftUI
import Combine

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
    @Published var audioSourceName: String = "iPhone Microphone"
    @Published var audioRouteToast: String?

    // MARK: - Private
    private static let cameraQueue = DispatchQueue(label: "com.steadyeye.camera", qos: .userInitiated)
    let session = AVCaptureSession()
    private var movieOutput = AVCaptureMovieFileOutput()
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var routeChangeObserver: NSObjectProtocol?

    private override init() {
        super.init()
    }

    // MARK: - Start / Stop

    func start(position: AVCaptureDevice.Position = .front) {
        cameraPosition = position
        Self.cameraQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                DispatchQueue.main.async { self.isSessionReady = true }
                return
            }
            self.setupSession(position: position)
        }
    }

    func stop() {
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
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
    }

    // MARK: - Phase 1: Video + audio with built-in mic (instant)

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
        if want4K && session.canSetSessionPreset(.hd4K3840x2160) {
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
            DispatchQueue.main.async { [weak self] in self?.errorMessage = "Camera not available." }
            return
        }

        do {
            let vInput = try AVCaptureDeviceInput(device: videoDevice)
            if session.canAddInput(vInput) { session.addInput(vInput) }
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "Failed to access camera: \(error.localizedDescription)"
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

        // Movie output
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        session.commitConfiguration()
        session.startRunning()

        DispatchQueue.main.async { [weak self] in
            self?.isSessionReady = true
        }
        // Phase 2: enable Bluetooth audio routing (non-blocking, no session reconfig)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.enableBluetoothAudio()
        }
    }

    // MARK: - Phase 2: Bluetooth audio routing (no capture session changes)

    private func enableBluetoothAudio() {
        // Reconfigure audio session WITH Bluetooth options
        // iOS automatically routes the existing audio input to AirPods — no capture session reconfig needed
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )

        // Prefer Bluetooth if available
        if let btInput = audioSession.availableInputs?.first(where: {
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
                        self.audioRouteToast = "Switched to iPhone microphone"
                    case .newDeviceAvailable:
                        self.audioRouteToast = "New mic detected. Will use on next recording."
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

    // MARK: - Camera switching

    func switchCamera() {
        let newPosition: AVCaptureDevice.Position = (cameraPosition == .front) ? .back : .front
        cameraPosition = newPosition
        Self.cameraQueue.async { [weak self] in
            guard let self else { return }
            self.setupSession(position: newPosition)
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        Self.cameraQueue.async { [weak self] in
            self?.movieOutput.startRecording(to: outputURL, recordingDelegate: self!)
        }

        recordingStartTime = Date()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            self.recordingDuration = Date().timeIntervalSince(start)
        }
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else { return }
        // Register background task so the video file finishes writing even if app is backgrounded
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
        Self.cameraQueue.async { [weak self] in
            self?.movieOutput.stopRecording()
        }
        durationTimer?.invalidate()
        durationTimer = nil
        isRecording = false
        recordingDuration = 0
        recordingStartTime = nil
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // stopSession removed — use stop() instead

    private func updateAudioSourceName() {
        let input = AVAudioSession.sharedInstance().currentRoute.inputs.first
        audioSourceName = input?.portName ?? "iPhone Microphone"
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            defer { self?.endBackgroundTask() }

            if let error {
                self?.errorMessage = "Recording error: \(error.localizedDescription)"
                return
            }
            if self?.saveDirectlyOnStop == true {
                self?.saveDirectlyOnStop = false
                UISaveVideoAtPathToSavedPhotosAlbum(outputFileURL.path, nil, nil, nil)
            } else {
                self?.lastRecordedURL = outputFileURL
            }
        }
    }
}
