import CoreVideo
import Foundation
import Vision
import os

/// DEV prototype: estimates where the user is looking from the frames the
/// camera already delivers, with Vision face landmarks (head pose plus where
/// each pupil sits inside its eye).
///
/// Public API only. Face ID's attention signal is private, and ARKit face
/// tracking would take the front camera away from the recording session, so
/// this reads the recording's own buffers instead.
///
/// Never slows the capture pipeline: `submit` is called on the camera's
/// sample-buffer queue and only takes a frame when none is in flight and
/// `minInterval` has passed; the Vision work runs on the probe's own queue.
nonisolated final class GazeProbe: @unchecked Sendable {
    struct Reading: Sendable, Equatable {
        /// Head turn left/right, degrees.
        var yaw: Double
        /// Head tilt up/down, degrees.
        var pitch: Double
        /// Pupil offset inside the eye, averaged over both eyes: -1...1 from
        /// one corner/lid to the other, 0 = centred.
        var eyeX: Double
        var eyeY: Double
        /// Eye opening, contour height / width, averaged over both eyes. The
        /// upper lid drops when the gaze goes down, so this falls when the
        /// user looks below the lens.
        var eyeOpen: Double
    }

    private struct State {
        var onReading: (@Sendable (Reading?) -> Void)?
        var busy = false
        var lastSubmit: CFAbsoluteTime = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "com.steadyeye.gazeprobe", qos: .utility)
    /// ~10 readings a second is plenty to judge where someone looks.
    private static let minInterval: CFAbsoluteTime = 0.1

    /// Starts delivering readings (nil = no face found) on the probe's queue.
    func start(onReading: @escaping @Sendable (Reading?) -> Void) {
        state.withLock { $0.onReading = onReading }
    }

    func stop() {
        state.withLock { $0.onReading = nil }
    }

    /// Called for every video frame. Cheap when stopped or busy.
    func submit(_ pixelBuffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        let taken = state.withLock { s -> Bool in
            guard s.onReading != nil, !s.busy, now - s.lastSubmit >= Self.minInterval else { return false }
            s.busy = true
            s.lastSubmit = now
            return true
        }
        guard taken else { return }
        // One buffer held at a time (`busy`), released when Vision returns.
        nonisolated(unsafe) let buffer = pixelBuffer
        queue.async { [self] in
            let reading = Self.estimate(buffer)
            let deliver = state.withLock { s -> (@Sendable (Reading?) -> Void)? in
                s.busy = false
                return s.onReading
            }
            deliver?(reading)
        }
    }

    // MARK: - Estimation

    private static func estimate(_ pixelBuffer: CVPixelBuffer) -> Reading? {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        // The capture connection already delivers upright buffers.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])

        // Biggest face = the person recording.
        guard let face = request.results?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else { return nil }

        let offsets = [
            pupilOffset(eye: face.landmarks?.leftEye, pupil: face.landmarks?.leftPupil),
            pupilOffset(eye: face.landmarks?.rightEye, pupil: face.landmarks?.rightPupil),
        ].compactMap { $0 }
        let eyeX = offsets.isEmpty ? 0 : offsets.map(\.x).reduce(0, +) / Double(offsets.count)
        let eyeY = offsets.isEmpty ? 0 : offsets.map(\.y).reduce(0, +) / Double(offsets.count)
        let openings = [face.landmarks?.leftEye, face.landmarks?.rightEye].compactMap(eyeOpening)
        let eyeOpen = openings.isEmpty ? 0 : openings.reduce(0, +) / Double(openings.count)

        return Reading(
            yaw: degrees(face.yaw),
            pitch: degrees(face.pitch),
            eyeX: eyeX,
            eyeY: eyeY,
            eyeOpen: eyeOpen
        )
    }

    /// Pupil position relative to the eye contour's box, -1...1 per axis.
    private static func pupilOffset(
        eye: VNFaceLandmarkRegion2D?,
        pupil: VNFaceLandmarkRegion2D?
    ) -> (x: Double, y: Double)? {
        guard let eyePoints = eye?.normalizedPoints, eyePoints.count > 2,
              let pupilPoint = pupil?.normalizedPoints.first else { return nil }
        let xs = eyePoints.map(\.x), ys = eyePoints.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(),
              maxX - minX > 0, maxY - minY > 0 else { return nil }
        let x = (pupilPoint.x - (minX + maxX) / 2) / ((maxX - minX) / 2)
        let y = (pupilPoint.y - (minY + maxY) / 2) / ((maxY - minY) / 2)
        return (Double(x), Double(y))
    }

    /// Height / width of the eye contour's box.
    private static func eyeOpening(_ eye: VNFaceLandmarkRegion2D?) -> Double? {
        guard let points = eye?.normalizedPoints, points.count > 2 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(),
              maxX - minX > 0 else { return nil }
        return Double((maxY - minY) / (maxX - minX))
    }

    private static func degrees(_ radians: NSNumber?) -> Double {
        (radians?.doubleValue ?? 0) * 180 / .pi
    }
}
