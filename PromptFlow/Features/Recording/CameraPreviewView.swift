import SwiftUI
import AVFoundation

/// UIViewRepresentable wrapper that displays an AVCaptureVideoPreviewLayer.
/// In Simulator (no real camera) renders a neutral dark-gray placeholder.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
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

    func updateUIView(_ uiView: UIView, context: Context) {}
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
