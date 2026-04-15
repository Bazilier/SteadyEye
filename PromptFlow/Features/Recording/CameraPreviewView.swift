import SwiftUI
import AVFoundation

/// UIViewRepresentable wrapper that displays an AVCaptureVideoPreviewLayer.
/// In screencast mode (Simulator always, or when the "Screencast Mode" toggle is on),
/// renders chroma key green (#00B140) instead so the teleprompter UI can be composited
/// over AI-generated footage in Final Cut Pro.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    @AppStorage("screenshotMode") private var screenshotMode: Bool = false

    private var showGreen: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return screenshotMode
        #endif
    }

    func makeUIView(context: Context) -> UIView {
        if showGreen {
            let view = UIView()
            // Standard broadcast chroma green — keys cleanly in FCP while preserving edge detail
            view.backgroundColor = UIColor(red: 0, green: 0.690, blue: 0.251, alpha: 1)
            return view
        }
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
