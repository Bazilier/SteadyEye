import SwiftUI
import AVFoundation

/// UIViewRepresentable wrapper that displays an AVCaptureVideoPreviewLayer.
/// In chromakey mode (Simulator, or DEV with `dev_chromakey_enabled`) renders
/// a solid #00B140 fill for UI mockup video compositing.
/// Otherwise in Simulator renders a neutral dark-gray placeholder.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// The session's video device, once configured. Used only on iPhone Duo,
    /// to keep the preview level as the interface rotates.
    var device: AVCaptureDevice?
    /// Learned correction for an iPhone Duo camera, added to the level angle
    /// (`CameraManager.previewAngleCorrection`).
    var angleCorrection: CGFloat = 0

    func makeUIView(context: Context) -> UIView {
        if CameraManager.isChromakeyActive {
            let view = UIView()
            // RGB(0, 177, 64) — broadcast standard chromakey green.
            view.backgroundColor = UIColor(red: 0, green: 177/255, blue: 64/255, alpha: 1)
            return view
        }
        #if targetEnvironment(simulator)
        let view = UIView()
        view.backgroundColor = UIColor(white: 0.15, alpha: 1)
        return view
        #else
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
        #endif
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        #if !targetEnvironment(simulator)
        (uiView as? PreviewUIView)?.followHorizon(of: device, correction: angleCorrection)
        #endif
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var correction: CGFloat = 0

    /// iPhone Duo only: its interface rotates with the device (portrait lock
    /// does not apply on the inner display), so the preview's rotation must
    /// follow the RotationCoordinator's level-horizon angle for this layer.
    /// Everywhere else the interface is portrait-locked and the preview is
    /// left exactly as before — except under a learned correction, which only
    /// a Duo camera (or the DEV calibration test) has. Rebuilt when the device
    /// or the correction changes.
    func followHorizon(of device: AVCaptureDevice?, correction: CGFloat) {
        guard DuoDisplayMonitor.deviceHasHinge || correction != 0 || rotationCoordinator != nil,
              let device,
              rotationCoordinator?.device !== device || self.correction != correction else { return }
        self.correction = correction
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        apply(coordinator.videoRotationAngleForHorizonLevelPreview)
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.new]
        ) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { self?.apply(angle) }
        }
    }

    private func apply(_ level: CGFloat) {
        let angle = CGFloat((Int(level.rounded()) + Int(correction)) % 360)
        guard let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
}
