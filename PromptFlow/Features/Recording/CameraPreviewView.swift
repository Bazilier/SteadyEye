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
        (uiView as? PreviewUIView)?.followHorizon(of: device)
        #endif
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    /// iPhone Duo only: its interface rotates with the device (portrait lock
    /// does not apply on the inner display), so the preview's rotation must
    /// follow the RotationCoordinator's level-horizon angle for this layer.
    /// Everywhere else the interface is portrait-locked and the preview is
    /// left exactly as before. Rebuilt when the device changes.
    func followHorizon(of device: AVCaptureDevice?) {
        guard DuoDisplayMonitor.deviceHasHinge,
              let device,
              rotationCoordinator?.device !== device else { return }
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

    private func apply(_ angle: CGFloat) {
        guard let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
}
