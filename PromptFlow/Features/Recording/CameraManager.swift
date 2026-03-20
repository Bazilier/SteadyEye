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
    /// Current audio input source name (e.g. "iPhone Microphone", "AirPods", "DJI Mic")
    var audioSourceName: String = "iPhone Microphone"
    /// Brief message shown when audio route changes (set to nil to dismiss)
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
        // Must be called on sessionQueue

        // 1. Tell AVCaptureSession to NOT manage AVAudioSession — we do it ourselves.
        //    This is the key fix for Bluetooth/external mic support.
        session.automaticallyConfiguresApplicationAudioSession = false

        // 2. Register route change observer before configuring audio session
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

        // 3. Configure AVAudioSession with Bluetooth options BEFORE adding audio input
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            try audioSession.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try audioSession.setActive(true)

            print("[Audio] Category: \(audioSession.category.rawValue)")
            print("[Audio] Route inputs: \(audioSession.currentRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" })")
            print("[Audio] Available: \(audioSession.availableInputs?.map { "\($0.portName) (\($0.portType.rawValue))" } ?? [])")

            // Prefer Bluetooth input if available
            if let btInput = audioSession.availableInputs?.first(where: {
                $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE || $0.portType == .bluetoothA2DP
            }) {
                try audioSession.setPreferredInput(btInput)
                print("[Audio] Preferred: \(btInput.portName)")
            }
        } catch {
            print("[Audio] Config failed: \(error)")
        }

        // Read source name after route settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.updateAudioSourceName()
        }

        // 4. Configure capture session
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
                // Fall back to 30fps
                let fallback = CMTime(value: 1, timescale: 30)
                videoDevice.activeVideoMinFrameDuration = fallback
                videoDevice.activeVideoMaxFrameDuration = fallback
            }
            videoDevice.unlockForConfiguration()
        } catch {
            // Frame rate configuration failed — continue with defaults
        }

        // Audio input (non-fatal if unavailable)
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

        if !session.isRunning {
            session.startRunning()
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
