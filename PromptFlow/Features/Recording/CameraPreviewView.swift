import SwiftUI
import AVFoundation

/// UIViewRepresentable wrapper that displays an AVCaptureVideoPreviewLayer.
/// In chromakey mode (Simulator, or DEV with `dev_chromakey_enabled`) renders
/// a solid #00B140 fill for UI mockup video compositing.
/// Otherwise in Simulator renders a neutral dark-gray placeholder.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

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

    func updateUIView(_ uiView: UIView, context: Context) {}
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
