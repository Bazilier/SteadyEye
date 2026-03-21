import AVFoundation
import UIKit
import SwiftUI

@Observable
final class CameraManager: NSObject {
    // MARK: - Public state (main-thread readable)
    var isRecording = false
    var recordingDuration: TimeInterval = 0
    var errorMessage: String?
    var cameraPosition: AVCaptureDevice.Position = .front
    var lastRecordedURL: URL?
    var saveDirectlyOnStop = false
    /// True once the capture session is running and camera preview is available
    var isSessionReady = false
    var audioSourceName: String = "iPhone Microphone"
    var audioRouteToast: String?

    // MARK: - Private
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.steadyeye.sessionQueue")
    private var movieOutput = AVCaptureMovieFileOutput()
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var routeChangeObserver: NSObjectProtocol?

    // MARK: - Setup

    func configure(position: AVCaptureDevice.Position = .front) {
        cameraPosition = position
        sessionQueue.async { [weak self] in
            self?.setupSession(position: position)
        }
    }

    private func setupSession(position: AVCaptureDevice.Position) {
        // Must be called on sessionQueue — all steps run serially here

        // a) Prevent capture session from touching audio session
        session.automaticallyConfiguresApplicationAudioSession = false

        // b) Configure audio session (sole owner — no other code touches it)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try? audioSession.setActive(true)

        // Prefer Bluetooth input if available
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
                    default:
                        break
                    }
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateAudioSourceName()
        }

        // c) Configure capture session
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
            .builtInWideAngleCamera,
            for: .video,
            position: position
        ) else {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "Camera not available."
            }
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

        // Configure frame rate
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
        } catch {
            // Continue with defaults
        }

        // Audio input
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

        // 5. Start running — non-blocking for UI
        if !session.isRunning {
            session.startRunning()
            DispatchQueue.main.async { [weak self] in
                self?.isSessionReady = true
            }
        }
    }

    // MARK: - Camera switching

    func switchCamera() {
        let newPosition: AVCaptureDevice.Position = (cameraPosition == .front) ? .back : .front
        configure(position: newPosition)
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        sessionQueue.async { [weak self] in
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
        sessionQueue.async { [weak self] in
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

    func stopSession() {
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

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
