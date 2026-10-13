import CoreVideo
import Foundation
import Vision
import os

/// iPhone Duo diagnostics: which way is up in the buffers the camera actually
/// delivers. Buffer dimensions cannot tell an upright frame from one turned a
/// half turn, or a level landscape frame from a portrait scene lying on its
/// side — a face can. The person in front of a teleprompter is the one
/// reference every session has.
///
/// Finds the face with Vision in each of the four orientations and reports the
/// one it reads upright in. Only the angles and the buffer size leave the
/// probe — never the frame, the face box or landmarks.
///
/// Armed for a few frames at a time (`arm`), then idle: one lock check per
/// frame. Vision work runs on the probe's own queue, one frame in flight.
nonisolated final class FaceOrientationProbe: @unchecked Sendable {
    struct Result: Sendable {
        let context: String
        let bufferWidth: Int
        let bufferHeight: Int
        let connectionAngle: Int
        let mirrored: Bool
        let attempts: Int
        /// Degrees the buffer must turn clockwise for the face to be upright
        /// (0 / 90 / 180 / 270); nil when no face was found.
        let uprightRotation: Int?
        /// The face's roll in that orientation, degrees.
        let roll: Double?
        /// The face's roll in every orientation Vision found it in, by
        /// clockwise rotation. Vision finds a turned face in all four, so the
        /// answer rests on these rolls: the upright one is near 0, the others
        /// near ±90 and ±180.
        let rollsByRotation: [(cw: Int, roll: Double)]

        var logLine: String {
            "event=face_orientation context=\(context) buffer_w=\(bufferWidth) buffer_h=\(bufferHeight) connection_angle=\(connectionAngle) mirrored=\(mirrored) upright_cw=\(uprightRotation.map(String.init) ?? "none") roll=\(roll.map { String(Int($0.rounded())) } ?? "none") rolls=\(rollsByRotation.map { "\($0.cw):\(Int($0.roll.rounded()))" }.joined(separator: "/")) attempts=\(attempts)"
        }

        var report: [String: Any] {
            var info: [String: Any] = [
                "context": context,
                "buffer": "\(bufferWidth)x\(bufferHeight)",
                "connection_angle": connectionAngle,
                "mirrored": mirrored,
                "attempts": attempts,
                "rolls_by_cw": Dictionary(
                    rollsByRotation.map { ("\($0.cw)", ($0.roll * 10).rounded() / 10) },
                    uniquingKeysWith: { first, _ in first }
                ),
            ]
            if let uprightRotation { info["upright_cw"] = uprightRotation }
            if let roll { info["roll"] = (roll * 10).rounded() / 10 }
            return info
        }
    }

    private struct Arming {
        var context: String
        var notBefore: CFAbsoluteTime
        var attempts = 0
    }

    private struct State {
        var arming: Arming?
        var busy = false
        var lastSubmit: CFAbsoluteTime = 0
        var lastResult: Result?
        var onResult: (@Sendable (Result) -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "com.steadyeye.faceorientation", qos: .utility)
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PromptFlow", category: "CameraDiagnostic")
    /// Frames tried per arming before reporting "none": about three seconds,
    /// which covers someone glancing away or settling in front of the camera.
    private static let maxAttempts = 8
    private static let minInterval: CFAbsoluteTime = 0.4
    /// Vision's orientation for each clockwise rotation that makes the buffer
    /// upright (CGImagePropertyOrientation: `.right` = shown turned 90° clockwise).
    private static let orientations: [(cw: Int, orientation: CGImagePropertyOrientation)] = [
        (0, .up), (90, .right), (180, .down), (270, .left),
    ]

    /// Starts looking for a face, replacing any arming in progress.
    /// `delay` skips the frames still in flight from a previous configuration.
    func arm(context: String, delay: TimeInterval = 0) {
        let notBefore = CFAbsoluteTimeGetCurrent() + delay
        state.withLock { $0.arming = Arming(context: context, notBefore: notBefore) }
    }

    /// Whether an arming has not produced its result yet.
    var isPending: Bool { state.withLock { $0.arming != nil } }

    var lastResult: Result? { state.withLock { $0.lastResult } }

    /// Receives every finished reading, on the probe's queue. Set once by the
    /// camera, which corrects an iPhone Duo camera's angle from it.
    func setResultHandler(_ handler: @escaping @Sendable (Result) -> Void) {
        state.withLock { $0.onResult = handler }
    }

    /// Called for every video frame. Cheap unless armed.
    func submit(_ pixelBuffer: CVPixelBuffer, connectionAngle: CGFloat, mirrored: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        let taken: Arming? = state.withLock { s in
            guard var arming = s.arming, !s.busy,
                  now >= arming.notBefore, now - s.lastSubmit >= Self.minInterval else { return nil }
            arming.attempts += 1
            s.arming = arming
            s.busy = true
            s.lastSubmit = now
            return arming
        }
        guard let taken else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        nonisolated(unsafe) let buffer = pixelBuffer
        queue.async { [self] in
            let found = Self.detect(buffer)
            let upright = found.min { abs($0.roll) < abs($1.roll) }
            let finished = upright != nil || taken.attempts >= Self.maxAttempts
            let result = Result(
                context: taken.context,
                bufferWidth: width,
                bufferHeight: height,
                connectionAngle: Int(connectionAngle),
                mirrored: mirrored,
                attempts: taken.attempts,
                uprightRotation: upright?.cw,
                roll: upright?.roll,
                rollsByRotation: found
            )
            let handler = state.withLock { s -> (@Sendable (Result) -> Void)?? in
                s.busy = false
                // A newer arming replaced this one while Vision ran: its own
                // frames will report.
                guard finished, s.arming?.context == taken.context,
                      s.arming?.notBefore == taken.notBefore else { return nil }
                s.arming = nil
                s.lastResult = result
                return .some(s.onResult)
            }
            guard let handler else { return }
            log.notice("\(result.logLine, privacy: .public)")
            CameraDiagnosticsLog.record(result.logLine)
            handler?(result)
        }
    }

    // MARK: - Detection

    /// The biggest face in each orientation Vision finds one in, with its roll.
    private static func detect(_ pixelBuffer: CVPixelBuffer) -> [(cw: Int, roll: Double)] {
        orientations.compactMap { entry in
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: entry.orientation)
            try? handler.perform([request])
            guard let face = request.results?.max(by: {
                $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
            }), face.confidence >= 0.5 else { return nil }
            return (entry.cw, (face.roll?.doubleValue ?? 0) * 180 / .pi)
        }
    }
}
