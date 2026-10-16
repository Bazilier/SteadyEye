#if DEBUG
import SwiftUI
import UIKit

/// DEBUG-only geometry overlay for iPhone Duo, drawn over the chromakey
/// background in RecordingView. Everything is in window coordinates, the
/// space `DuoDisplayState` is resolved in.
struct DuoDebugOverlay: View {
    /// Off by default, so chromakey mockups stay clean; switched on from
    /// Settings → iPhone Duo (DEV). Read on each render of the recording screen.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "dev_duo_geometry_overlay")
    }

    let state: DuoDisplayState
    /// All occlusion regions, lens included.
    let occlusionFrames: [CGRect]

    /// For the hinge angle only, which is not part of `state`. Read here so
    /// angle updates re-render the overlay and nothing else.
    @Environment(DuoDisplayMonitor.self) private var monitor: DuoDisplayMonitor?
    @State private var interfaceOrientation = "unknown"
    @State private var deviceOrientation = UIDevice.current.orientation

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Camera half: blue tint.
            region(state.cameraHalf) {
                Rectangle().fill(Color.blue.opacity(0.18))
            }

            // Crease: yellow fill; solid border when active, dashed otherwise.
            if let crease = state.creaseFrame {
                region(crease) {
                    Rectangle()
                        .fill(Color.yellow.opacity(0.2))
                        .overlay {
                            Rectangle().stroke(
                                Color.yellow,
                                style: StrokeStyle(lineWidth: 2, dash: state.isCreaseActive ? [] : [8, 6])
                            )
                        }
                }
            }

            // Other occlusion regions: thin white outline.
            ForEach(Array(occlusionFrames.enumerated()), id: \.offset) { _, frame in
                if frame != state.lensFrame {
                    region(frame) {
                        Rectangle().stroke(Color.white, lineWidth: 1)
                    }
                }
            }

            // Lens: red outline.
            region(state.lensFrame) {
                Rectangle().stroke(Color.red, lineWidth: 2)
            }

            cornerLabels
            upArrow
            infoBlock
        }
        .frame(width: state.windowSize.width, height: state.windowSize.height, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .background(WindowSceneOrientationReader { interfaceOrientation = $0 })
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        .onDisappear { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            deviceOrientation = UIDevice.current.orientation
        }
    }

    // MARK: - Pieces

    private func region<S: View>(_ rect: CGRect, @ViewBuilder _ shape: () -> S) -> some View {
        shape()
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private var cornerLabels: some View {
        let w = state.windowSize.width
        let h = state.windowSize.height
        let inset: CGFloat = 24
        return ZStack(alignment: .topLeading) {
            label("TL").position(x: inset, y: inset)
            label("TR").position(x: w - inset, y: inset)
            label("BL").position(x: inset, y: h - inset)
            label("BR").position(x: w - inset, y: h - inset)
        }
    }

    private var upArrow: some View {
        VStack(spacing: 2) {
            Image(systemName: "arrow.up")
                .font(.system(size: 28, weight: .bold))
            Text(verbatim: "UP").font(.caption.bold())
        }
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .position(x: state.windowSize.width / 2, y: 48)
    }

    private var infoBlock: some View {
        let target = infoArea
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "posture: \(state.posture.rawValue)")
            Text("hinge: \(state.hingeStatus.rawValue) \(String(format: "%.1f°", monitor?.hingeAngleDegrees ?? 0))")
            Text(verbatim: "window: \(DuoDisplayMonitor.fmt(state.windowSize))")
            Text(verbatim: "interface: \(interfaceOrientation)")
            Text(verbatim: "device: \(Self.describe(deviceOrientation))")
            Text(verbatim: "lensFrame: \(DuoDisplayMonitor.fmt(state.lensFrame))")
            Text(verbatim: "lensEdge: \(state.lensEdge.rawValue)")
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .position(x: target.midX, y: target.midY)
    }

    /// The half without the lens when unfolded; the whole window when folded.
    private var infoArea: CGRect {
        let window = CGRect(origin: .zero, size: state.windowSize)
        guard let crease = state.creaseFrame else { return window }
        let half = state.cameraHalf
        if crease.height >= crease.width {
            return half.minX < crease.minX
                ? CGRect(x: crease.maxX, y: 0, width: max(0, window.maxX - crease.maxX), height: window.height)
                : CGRect(x: 0, y: 0, width: max(0, crease.minX), height: window.height)
        }
        return half.minY < crease.minY
            ? CGRect(x: 0, y: crease.maxY, width: window.width, height: max(0, window.maxY - crease.maxY))
            : CGRect(x: 0, y: 0, width: window.width, height: max(0, crease.minY))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
    }

    private static func describe(_ o: UIDeviceOrientation) -> String {
        switch o {
        case .unknown: return "unknown"
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .faceUp: return "faceUp"
        case .faceDown: return "faceDown"
        @unknown default: return "raw(\(o.rawValue))"
        }
    }
}

/// Reports the interface orientation of the window scene hosting this view,
/// tracking `effectiveGeometry` so a rotation or a display switch is picked up.
private struct WindowSceneOrientationReader: UIViewRepresentable {
    let onChange: (String) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onChange = onChange
    }

    final class ReaderView: UIView {
        var onChange: ((String) -> Void)?
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observation = window?.windowScene?.observe(\.effectiveGeometry, options: [.initial, .new]) { [weak self] scene, _ in
                let value = ReaderView.describe(scene.effectiveGeometry.interfaceOrientation)
                // Deferred: KVO can fire during a SwiftUI update.
                DispatchQueue.main.async { self?.onChange?(value) }
            }
        }

        nonisolated static func describe(_ o: UIInterfaceOrientation) -> String {
            switch o {
            case .unknown: return "unknown"
            case .portrait: return "portrait"
            case .portraitUpsideDown: return "portraitUpsideDown"
            case .landscapeLeft: return "landscapeLeft"
            case .landscapeRight: return "landscapeRight"
            @unknown default: return "raw(\(o.rawValue))"
            }
        }
    }
}
#endif
