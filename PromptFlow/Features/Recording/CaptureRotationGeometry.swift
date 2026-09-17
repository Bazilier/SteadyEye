import CoreGraphics
import ImageIO

/// Pure rotation geometry for the capture pipeline. No AVFoundation state, so
/// it compiles for the simulator and is unit-tested directly.
///
/// Every decision here is derived from what the video connection actually
/// DELIVERED (a buffer's dimensions at a known connection angle) or from
/// `AVCaptureDevice.RotationCoordinator`'s reported angle — never from the
/// active format's dimensions and never from a device model.
///
/// Why not the active format: on iPhone 17 front cameras the sensor is mounted
/// with a different rotation (Apple Developer Forums thread 813548). The active
/// format still reports 1920x1080, yet a connection at 90 delivers 1920x1080 and
/// the coordinator reports 0 for portrait. The format's shape therefore says
/// nothing about which angle yields a portrait buffer; a delivered buffer does.
nonisolated enum CaptureRotationGeometry {
    /// Normalises any angle in degrees to 0, 90, 180 or 270.
    static func normalized(_ angle: CGFloat) -> Int {
        let rounded = Int((angle / 90).rounded()) * 90
        return ((rounded % 360) + 360) % 360
    }

    /// The residue (0 or 90) shared by every connection angle that yields a
    /// portrait buffer on this device, learned from one delivered buffer.
    ///
    /// A quarter turn swaps a buffer's axes and a half turn preserves them —
    /// the only property relied on. If the buffer delivered at `connectionAngle`
    /// is portrait, portrait angles are congruent to it mod 180; otherwise they
    /// are a quarter turn away.
    static func portraitResidue(bufferWidth: Int, bufferHeight: Int, connectionAngle: CGFloat) -> Int {
        let angle = normalized(connectionAngle)
        let bufferIsPortrait = bufferHeight > bufferWidth
        return (bufferIsPortrait ? angle : angle + 90) % 180
    }

    /// True when `angle` yields a portrait buffer on a device whose portrait
    /// angles share `portraitResidue`.
    static func producesPortrait(angle: CGFloat, portraitResidue: Int) -> Bool {
        normalized(angle) % 180 == portraitResidue
    }

    /// True when `angle` yields a landscape buffer on a device whose portrait
    /// angles share `portraitResidue`. The exact complement of
    /// `producesPortrait`, spelled out so landscape call sites read as intent
    /// rather than as a negation.
    static func producesLandscape(angle: CGFloat, portraitResidue: Int) -> Bool {
        !producesPortrait(angle: angle, portraitResidue: portraitResidue)
    }

    /// The two connection angles that yield a landscape buffer on this device.
    ///
    /// Both are returned because shape alone cannot choose between them: they
    /// differ by a half turn, which preserves a buffer's dimensions. Deciding
    /// which one puts the front lens on a particular side needs gravity, not
    /// geometry — see `landscapeLeftAngle(horizonAngle:portraitResidue:)`.
    static func landscapeCandidates(portraitResidue: Int) -> [Int] {
        let first = (portraitResidue + 90) % 180
        return [first, (first + 180) % 360]
    }

    /// The connection angle for the one supported landscape grip: device rotated
    /// LEFT, so the front lens sits on the left of the frame.
    ///
    /// When the device is already held that way, the coordinator reports that
    /// angle itself, so it is used unchanged. When the device is still upright —
    /// the mode was changed while holding the phone in portrait — the reported
    /// angle is a portrait one, and landscape-left is a quarter turn on from it.
    /// That step holds on both rotation bases without branching on the device:
    /// iPhone 16 and earlier report portrait 90 and landscape-left 180; iPhone 17
    /// front cameras report portrait 0 and landscape-left 90 (Apple Developer
    /// Forums thread 813548).
    ///
    /// CONTRACT, NOT OBSERVATION. Which of the two candidates corresponds to
    /// lens-on-the-left rests on Apple's definition of the horizon-level angle,
    /// not on anything this codebase has measured. Callers log both candidates
    /// and the choice so a single device run confirms or refutes it.
    static func landscapeLeftAngle(horizonAngle: CGFloat, portraitResidue: Int) -> Int {
        let reported = normalized(horizonAngle)
        if producesLandscape(angle: CGFloat(reported), portraitResidue: portraitResidue) {
            return reported
        }
        return (reported + 90) % 360
    }

    /// Dimensions a connection at `targetAngle` will deliver, given a buffer
    /// observed at `observedAngle`: swapped for an odd number of quarter turns
    /// between the two, unchanged otherwise.
    static func expectedDimensions(
        observedWidth: Int,
        observedHeight: Int,
        observedAngle: CGFloat,
        targetAngle: CGFloat
    ) -> (width: Int, height: Int) {
        let delta = (normalized(targetAngle) - normalized(observedAngle) + 360) % 360
        return delta % 180 == 0
            ? (observedWidth, observedHeight)
            : (observedHeight, observedWidth)
    }

    /// Clockwise rotation, in degrees, that turns a buffer delivered at
    /// `connectionAngle` into what a connection at `horizonAngle` would have
    /// delivered. This is Apple's recommended correction (thread 813548):
    /// `videoRotationAngle - videoConnectionVideoRotationAngle`, where the first
    /// term is the RotationCoordinator's horizon-level angle.
    ///
    /// Valid for UNMIRRORED buffers only. Mirroring reverses the sense of a
    /// rotation, and whether the connection mirrors before or after rotating is
    /// not exposed by the API, so a mirrored buffer has no reliable correction.
    static func correctionDegrees(horizonAngle: CGFloat, connectionAngle: CGFloat) -> Int {
        (normalized(horizonAngle) - normalized(connectionAngle) + 360) % 360
    }

    /// Core Image orientation that rotates a buffer `degrees` clockwise in
    /// buffer (row, column) space. Pinned by `CaptureOrientationGeometryTests`
    /// against real pixels. `nil` for 0 (nothing to do).
    static func orientation(forClockwiseDegrees degrees: Int) -> CGImagePropertyOrientation? {
        switch ((degrees % 360) + 360) % 360 {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return nil
        }
    }
}
