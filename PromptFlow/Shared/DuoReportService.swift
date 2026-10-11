import AVFoundation
import UIKit

// iPhone Duo diagnostics, sent to the backend (`/analytics/duo-report/`),
// which stores each report and forwards it to the founder's Telegram. Exists
// because the Duo's camera behaviour can only be learned on hardware, and the
// first hardware may be anyone's: a store demo unit or a user's phone, running
// the App Store build.
//
// Only on a device with a hinge. Technical data only: geometry, camera
// properties, capture events. Never script text or media. Each report key is
// sent at most once per process; the server also caps reports per install.
// In the Simulator the JSON is printed instead of sent.

@MainActor
enum DuoReportService {
    private static let endpoint = URL(string: "https://web-production-49244.up.railway.app/api/v1/analytics/duo-report/")!
    private static var sentKeys: Set<String> = []
    private static var takeCount = 0
    /// Takes reported per process; enough to compare postures, not a stream.
    private static let maxTakesPerProcess = 3

    // MARK: - Reports

    /// Geometry, scene and camera inventory for the current posture and
    /// interface orientation, once per pair. Delayed so the regions of a
    /// display switch or rotation have settled.
    static func scheduleDeviceReport(_ monitor: DuoDisplayMonitor) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard let state = monitor.state else { return }
            let scene = sceneInfo()
            let key = "\(state.posture.rawValue):\(scene["interface_orientation"] as? String ?? "?")"
            guard claim("device:\(key)") else { return }
            var payload: [String: Any] = [
                "state": stateInfo(state, monitor: monitor),
                "scene": scene,
                "cutout_static": "\(DeviceDetectionService.shared.cutoutType)",
            ]
            payload["cameras"] = await Task.detached { cameraInventory() }.value
            send(kind: "device", payload: payload)
        }
    }

    /// The recording screen's live camera configuration for the current
    /// posture and interface orientation, once per pair. Delayed so the
    /// session has delivered its first buffer.
    static func scheduleCameraReport(_ cameraManager: CameraManager, monitor: DuoDisplayMonitor?) {
        guard DuoDisplayMonitor.deviceHasHinge else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            let scene = sceneInfo()
            let posture = monitor?.state?.posture.rawValue ?? "unknown"
            let key = "\(posture):\(scene["interface_orientation"] as? String ?? "?")"
            guard claim("camera:\(key)") else { return }
            var payload: [String: Any] = [
                "posture": posture,
                "scene": scene,
                "camera": cameraManager.duoDiagnostics(),
                "events": recentCameraEvents(limit: 40),
            ]
            if let state = monitor?.state {
                payload["state"] = stateInfo(state, monitor: monitor)
            }
            send(kind: "camera", payload: payload)
        }
    }

    /// One finished take: how it was configured, how it ended, the capture
    /// events, and the saved file's actual video track geometry — or, when
    /// saving failed, the error instead.
    static func reportTake(
        fileURL: URL?,
        failure: String?,
        duration: TimeInterval,
        stoppedByFold: Bool,
        cameraManager: CameraManager,
        monitor: DuoDisplayMonitor?
    ) {
        guard DuoDisplayMonitor.deviceHasHinge, takeCount < maxTakesPerProcess else { return }
        takeCount += 1
        let camera = cameraManager.duoDiagnostics()
        let events = recentCameraEvents(limit: 80)
        let scene = sceneInfo()
        let state = monitor?.state.map { stateInfo($0, monitor: monitor) }
        Task { @MainActor in
            var payload: [String: Any] = [
                "duration_sec": (duration * 10).rounded() / 10,
                "stopped_by_fold": stoppedByFold,
                "scene": scene,
                "camera": camera,
                "events": events,
            ]
            if let fileURL { payload["file"] = await fileInfo(fileURL) }
            if let failure { payload["save_failure"] = failure }
            if let state { payload["state"] = state }
            send(kind: "take", payload: payload)
        }
    }

    // MARK: - Sending

    private static func claim(_ key: String) -> Bool {
        guard DuoDisplayMonitor.deviceHasHinge else { return false }
        return sentKeys.insert(key).inserted
    }

    private static func send(kind: String, payload: [String: Any]) {
        let info = Bundle.main.infoDictionary
        let body: [String: Any] = [
            "install_id": UserIdentity.uuid,
            "kind": kind,
            "app_version": info?["CFBundleShortVersionString"] as? String ?? "?",
            "build": info?["CFBundleVersion"] as? String ?? "?",
            "os_version": UIDevice.current.systemVersion,
            "model": DeviceDetectionService.shared.modelIdentifier,
            "payload": payload,
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            print("[DUO-REPORT] \(kind): payload is not valid JSON, not sent")
            return
        }
        #if targetEnvironment(simulator)
        print("[DUO-REPORT] \(kind) \(data.count) bytes (simulator, not sent): \(String(decoding: data, as: UTF8.self))")
        #else
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        Task.detached {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[DUO-REPORT] \(kind) sent, status \(status)")
            } catch {
                print("[DUO-REPORT] \(kind) failed: \(error.localizedDescription)")
            }
        }
        #endif
    }

    // MARK: - Payload pieces

    private static func stateInfo(_ state: DuoDisplayState, monitor: DuoDisplayMonitor?) -> [String: Any] {
        var info: [String: Any] = [
            "posture": state.posture.rawValue,
            "hinge": state.hingeStatus.rawValue,
            "window": size(state.windowSize),
            "lens": rect(state.lensFrame),
            "lens_edge": state.lensEdge.rawValue,
            "crease_active": state.isCreaseActive,
            "camera_half": rect(state.cameraHalf),
        ]
        if let crease = state.creaseFrame { info["crease"] = rect(crease) }
        if let other = state.otherHalf { info["other_half"] = rect(other) }
        if let monitor {
            info["hinge_angle"] = (monitor.hingeAngleDegrees * 10).rounded() / 10
            info["occlusions"] = monitor.occlusionFrames.map(rect)
        }
        return info
    }

    /// The foreground window scene, read directly: on Duo the scene moves
    /// between screens and `UIScreen.main` goes stale.
    private static func sceneInfo() -> [String: Any] {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var info: [String: Any] = [
            "device_orientation": name(UIDevice.current.orientation),
        ]
        guard let scene else { return info }
        info["interface_orientation"] = name(scene.interfaceOrientation)
        info["screen_bounds"] = rect(scene.screen.bounds)
        info["screen_native_bounds"] = rect(scene.screen.nativeBounds)
        info["screen_scale"] = scene.screen.scale
        info["size_class_h"] = scene.traitCollection.horizontalSizeClass == .compact ? "compact" : "regular"
        info["size_class_v"] = scene.traitCollection.verticalSizeClass == .compact ? "compact" : "regular"
        if let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first {
            let insets = window.safeAreaInsets
            info["window_bounds"] = rect(window.bounds)
            info["safe_area"] = ["top": insets.top, "left": insets.left, "bottom": insets.bottom, "right": insets.right]
        }
        return info
    }

    private static func recentCameraEvents(limit: Int) -> [String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withColonSeparatorInTime, .withFractionalSeconds]
        return CameraDiagnosticsLog.snapshot().suffix(limit).map {
            "\(formatter.string(from: $0.time)) \($0.line)"
        }
    }

    private static func fileInfo(_ url: URL) async -> [String: Any] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return ["error": "no video track"]
        }
        var info: [String: Any] = [:]
        if let natural = try? await track.load(.naturalSize) { info["natural_size"] = size(natural) }
        if let transform = try? await track.load(.preferredTransform) {
            info["transform"] = [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
        }
        if let fps = try? await track.load(.nominalFrameRate) { info["fps"] = fps }
        if let duration = try? await asset.load(.duration) { info["duration_sec"] = duration.seconds }
        return info
    }

    // MARK: - Cameras

    /// Every video device discovery can see — the new Duo types included —
    /// what the app's own camera lookup returns, and the level-horizon angle
    /// each would need right now. Needs no camera permission.
    nonisolated static func cameraInventory() -> [String: Any] {
        var types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
            .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera,
            .builtInTrueDepthCamera, .builtInLiDARDepthCamera,
        ]
        if #available(iOS 27.1, *) {
            types += [.builtInOuterUltraWideCamera, .builtInInnerUltraWideCamera]
        }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        ).devices
        var info: [String: Any] = [
            "authorization": "\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)",
            "devices": devices.map { describe($0, formats: true) },
        ]
        if let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            info["app_front_default"] = describe(front, formats: false)
        }
        if let any = AVCaptureDevice.default(for: .video) {
            info["system_default"] = describe(any, formats: false)
        }
        return info
    }

    /// Identity, active configuration and, optionally, a deduplicated format
    /// list ("WxH@fps", plus dynamic aspect ratios where a format has them).
    nonisolated static func describe(_ device: AVCaptureDevice, formats: Bool) -> [String: Any] {
        var info: [String: Any] = [
            "type": device.deviceType.rawValue,
            "name": device.localizedName,
            "position": device.position == .front ? "front" : device.position == .back ? "back" : "unspecified",
            "id": String(device.uniqueID.suffix(12)),
            "active_format": formatLabel(device.activeFormat),
            "center_stage_active": device.isCenterStageActive,
            "zoom": device.videoZoomFactor,
            "horizon_angle_capture": AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                .videoRotationAngleForHorizonLevelCapture,
        ]
        if #available(iOS 26.0, *) {
            info["dynamic_aspect_ratio"] = device.dynamicAspectRatio?.rawValue ?? "none"
            let dims = device.dynamicDimensions
            info["dynamic_dimensions"] = "\(dims.width)x\(dims.height)"
        }
        if formats {
            var labels: [String] = []
            for format in device.formats {
                let label = formatLabel(format)
                if !labels.contains(label) { labels.append(label) }
            }
            info["formats"] = labels
        }
        return info
    }

    nonisolated private static func formatLabel(_ format: AVCaptureDevice.Format) -> String {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let fps = Int(format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        var label = "\(dims.width)x\(dims.height)@\(fps)"
        if #available(iOS 26.0, *) {
            let ratios = format.supportedDynamicAspectRatios.map(\.rawValue)
            if !ratios.isEmpty { label += " ar[\(ratios.joined(separator: ","))]" }
        }
        if format.isCenterStageSupported { label += " cs" }
        return label
    }

    // MARK: - Formatting

    private static func rect(_ r: CGRect) -> [Double] {
        [r.minX, r.minY, r.width, r.height].map(round1)
    }

    private static func size(_ s: CGSize) -> [Double] {
        [s.width, s.height].map(round1)
    }

    private static func round1(_ value: CGFloat) -> Double {
        (Double(value) * 10).rounded() / 10
    }

    private static func name(_ o: UIInterfaceOrientation) -> String {
        switch o {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        default: return "unknown"
        }
    }

    private static func name(_ o: UIDeviceOrientation) -> String {
        switch o {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .faceUp: return "faceUp"
        case .faceDown: return "faceDown"
        default: return "unknown"
        }
    }
}
