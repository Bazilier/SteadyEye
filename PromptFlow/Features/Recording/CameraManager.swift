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
    /// URL of the last recorded video (temp file). Set after recording finishes writing.
    var lastRecordedURL: URL?
    /// When true, save directly to Photos instead of showing preview (used for background saves).
    var saveDirectlyOnStop = false

    // MARK: - Private
    let session = AVCaptureSession()
    /// Dedicated serial queue for all AVCaptureSession calls — required by AVFoundation.
    private let sessionQueue = DispatchQueue(label: "com.steadyeye.sessionQueue")
    private var movieOutput = AVCaptureMovieFileOutput()
    private var durationTimer: Timer?
    private var recordingStartTime: Date?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Setup

    func configure(position: AVCaptureDevice.Position = .front) {
        cameraPosition = position
        sessionQueue.async { [weak self] in
            self?.setupSession(position: position)
        }
    }

    private func setupSession(position: AVCaptureDevice.Position) {
        // Must be called on sessionQueue
        let resolution = UserDefaults.standard.string(forKey: "videoResolution") ?? "1080p"
        let fps = UserDefaults.standard.integer(forKey: "videoFPS")
        let targetFPS = fps > 0 ? fps : 30

        session.beginConfiguration()

        // Set resolution preset
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
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
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
