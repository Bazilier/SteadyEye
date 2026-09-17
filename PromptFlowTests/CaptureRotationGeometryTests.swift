import XCTest
import ImageIO
@testable import PromptFlow

/// Tests for `CaptureRotationGeometry`, the production rotation math. Unlike
/// `CaptureOrientationGeometryTests`, these call the real symbols.
///
/// The iPhone 17 cases use values from a field log on real hardware
/// (device_model=iPhone18,1, front camera):
///
///   rotation_selected reported=0 ... connection_angle_after=90 active_format=1920x1080
///   recording_start writer_size=1080x1920 applied_angle=90
///   orientation_backstop_skipped buffer_w=1920 buffer_h=1080 ... connection_angle=90
///
/// What these tests establish is geometry derived from delivered buffers. They
/// do NOT establish that the coordinator's angle yields an UPRIGHT image rather
/// than an upside-down one — that is Apple's contract and is confirmed on
/// device by looking at the recorded video.
final class CaptureRotationGeometryTests: XCTestCase {

    // MARK: - Normalisation

    func testNormalized() {
        XCTAssertEqual(CaptureRotationGeometry.normalized(0), 0)
        XCTAssertEqual(CaptureRotationGeometry.normalized(90), 90)
        XCTAssertEqual(CaptureRotationGeometry.normalized(360), 0)
        XCTAssertEqual(CaptureRotationGeometry.normalized(-90), 270)
        XCTAssertEqual(CaptureRotationGeometry.normalized(89.6), 90)
    }

    // MARK: - Portrait residue from a delivered buffer

    /// iPhone 17 front camera: a connection at 90 delivered 1920x1080, so
    /// portrait angles are 0/180 — matching the coordinator reporting 0.
    func testIPhone17Front_landscapeBufferAt90_portraitIs0And180() {
        let residue = CaptureRotationGeometry.portraitResidue(bufferWidth: 1920, bufferHeight: 1080, connectionAngle: 90)
        XCTAssertEqual(residue, 0)
        XCTAssertTrue(CaptureRotationGeometry.producesPortrait(angle: 0, portraitResidue: residue))
        XCTAssertTrue(CaptureRotationGeometry.producesPortrait(angle: 180, portraitResidue: residue))
        XCTAssertFalse(CaptureRotationGeometry.producesPortrait(angle: 90, portraitResidue: residue))
        XCTAssertFalse(CaptureRotationGeometry.producesPortrait(angle: 270, portraitResidue: residue))
    }

    /// Earlier devices: a connection at 90 delivers 1080x1920, so portrait
    /// angles are 90/270.
    func testEarlierDevices_portraitBufferAt90_portraitIs90And270() {
        let residue = CaptureRotationGeometry.portraitResidue(bufferWidth: 1080, bufferHeight: 1920, connectionAngle: 90)
        XCTAssertEqual(residue, 90)
        XCTAssertTrue(CaptureRotationGeometry.producesPortrait(angle: 90, portraitResidue: residue))
        XCTAssertTrue(CaptureRotationGeometry.producesPortrait(angle: 270, portraitResidue: residue))
        XCTAssertFalse(CaptureRotationGeometry.producesPortrait(angle: 0, portraitResidue: residue))
        XCTAssertFalse(CaptureRotationGeometry.producesPortrait(angle: 180, portraitResidue: residue))
    }

    /// The residue is a property of the device, so it must come out the same
    /// whichever angle the observed buffer happened to be delivered at.
    func testResidueIsIndependentOfObservationAngle() {
        // iPhone 17 front: portrait at 0/180, landscape at 90/270.
        XCTAssertEqual(CaptureRotationGeometry.portraitResidue(bufferWidth: 1080, bufferHeight: 1920, connectionAngle: 0), 0)
        XCTAssertEqual(CaptureRotationGeometry.portraitResidue(bufferWidth: 1080, bufferHeight: 1920, connectionAngle: 180), 0)
        XCTAssertEqual(CaptureRotationGeometry.portraitResidue(bufferWidth: 1920, bufferHeight: 1080, connectionAngle: 270), 0)
        // Earlier devices: portrait at 90/270, landscape at 0/180.
        XCTAssertEqual(CaptureRotationGeometry.portraitResidue(bufferWidth: 1920, bufferHeight: 1080, connectionAngle: 0), 90)
        XCTAssertEqual(CaptureRotationGeometry.portraitResidue(bufferWidth: 1080, bufferHeight: 1920, connectionAngle: 270), 90)
    }

    // MARK: - Writer canvas from a delivered buffer

    /// The shipped defect: the canvas was sized 1080x1920 from the active
    /// format while the connection at 90 delivered 1920x1080. Sized from the
    /// observed buffer at the same angle, the canvas matches.
    func testIPhone17Front_canvasMatchesDeliveredBufferAtSameAngle() {
        let size = CaptureRotationGeometry.expectedDimensions(observedWidth: 1920, observedHeight: 1080, observedAngle: 90, targetAngle: 90)
        XCTAssertEqual(size.width, 1920)
        XCTAssertEqual(size.height, 1080)
    }

    /// With the coordinator's angle (0) applied, a buffer observed at 90 maps
    /// to a portrait canvas.
    func testIPhone17Front_observedAt90_canvasAt0IsPortrait() {
        let size = CaptureRotationGeometry.expectedDimensions(observedWidth: 1920, observedHeight: 1080, observedAngle: 90, targetAngle: 0)
        XCTAssertEqual(size.width, 1080)
        XCTAssertEqual(size.height, 1920)
    }

    func testHalfTurnKeepsDimensions() {
        let size = CaptureRotationGeometry.expectedDimensions(observedWidth: 1080, observedHeight: 1920, observedAngle: 0, targetAngle: 180)
        XCTAssertEqual(size.width, 1080)
        XCTAssertEqual(size.height, 1920)
    }

    // MARK: - Backstop correction (Apple's formula)

    /// Field values: coordinator 0, connection 90. The shipped backstop used the
    /// app's own selected angle (90) and computed 90 - 90 = 0 — no rotation for
    /// a landscape buffer in a portrait canvas. Apple's formula gives 270.
    func testIPhone17Front_correctionFromCoordinatorAngle() {
        let degrees = CaptureRotationGeometry.correctionDegrees(horizonAngle: 0, connectionAngle: 90)
        XCTAssertEqual(degrees, 270)
        XCTAssertEqual(CaptureRotationGeometry.orientation(forClockwiseDegrees: degrees), .left)
    }

    func testCorrectionIsZeroWhenConnectionAlreadyHoldsHorizonAngle() {
        XCTAssertEqual(CaptureRotationGeometry.correctionDegrees(horizonAngle: 0, connectionAngle: 0), 0)
        XCTAssertEqual(CaptureRotationGeometry.correctionDegrees(horizonAngle: 90, connectionAngle: 90), 0)
        XCTAssertNil(CaptureRotationGeometry.orientation(forClockwiseDegrees: 0))
    }

    func testCorrectionWrapsAround() {
        XCTAssertEqual(CaptureRotationGeometry.correctionDegrees(horizonAngle: 90, connectionAngle: 0), 90)
        XCTAssertEqual(CaptureRotationGeometry.correctionDegrees(horizonAngle: 270, connectionAngle: 90), 180)
        XCTAssertEqual(CaptureRotationGeometry.correctionDegrees(horizonAngle: 0, connectionAngle: 270), 90)
    }

    func testOrientationMapping() {
        XCTAssertEqual(CaptureRotationGeometry.orientation(forClockwiseDegrees: 90), .right)
        XCTAssertEqual(CaptureRotationGeometry.orientation(forClockwiseDegrees: 180), .down)
        XCTAssertEqual(CaptureRotationGeometry.orientation(forClockwiseDegrees: 270), .left)
        XCTAssertEqual(CaptureRotationGeometry.orientation(forClockwiseDegrees: -90), .left)
    }

    // MARK: - Landscape candidates and the lens-on-the-left pick

    /// Landscape angles are the complement of the portrait pair, on either basis.
    func testLandscapeCandidates() {
        // iPhone 16 and earlier: portrait 90/270 -> landscape 0/180.
        XCTAssertEqual(Set(CaptureRotationGeometry.landscapeCandidates(portraitResidue: 90)), [0, 180])
        // iPhone 17 front: portrait 0/180 -> landscape 90/270.
        XCTAssertEqual(Set(CaptureRotationGeometry.landscapeCandidates(portraitResidue: 0)), [90, 270])
    }

    func testProducesLandscapeIsComplementOfProducesPortrait() {
        for residue in [0, 90] {
            for angle in [0, 90, 180, 270] {
                let portrait = CaptureRotationGeometry.producesPortrait(angle: CGFloat(angle), portraitResidue: residue)
                let landscape = CaptureRotationGeometry.producesLandscape(angle: CGFloat(angle), portraitResidue: residue)
                XCTAssertNotEqual(portrait, landscape, "angle \(angle) residue \(residue)")
            }
        }
    }

    /// Device already rotated left: the coordinator reports the landscape angle
    /// itself, so it is used unchanged. Values from the rotation table in
    /// Apple Developer Forums thread 813548.
    func testLandscapeLeft_deviceAlreadyRotated_usesReportedAngle() {
        // iPhone 16 and earlier: landscape-left reports 180, and 180 is landscape there.
        XCTAssertEqual(CaptureRotationGeometry.landscapeLeftAngle(horizonAngle: 180, portraitResidue: 90), 180)
        // iPhone 17 front: landscape-left reports 90, and 90 is landscape there.
        XCTAssertEqual(CaptureRotationGeometry.landscapeLeftAngle(horizonAngle: 90, portraitResidue: 0), 90)
    }

    /// Device still upright (mode switched while holding the phone in portrait):
    /// landscape-left is a quarter turn on from the reported portrait angle. The
    /// same step works on both bases without branching on the device model.
    func testLandscapeLeft_devicePortrait_takesQuarterTurnFromReported() {
        // iPhone 16 and earlier: portrait 90 -> landscape-left 180.
        XCTAssertEqual(CaptureRotationGeometry.landscapeLeftAngle(horizonAngle: 90, portraitResidue: 90), 180)
        // iPhone 17 front: portrait 0 -> landscape-left 90.
        XCTAssertEqual(CaptureRotationGeometry.landscapeLeftAngle(horizonAngle: 0, portraitResidue: 0), 90)
    }

    /// Whatever it returns must be one of the two candidates, and must actually
    /// produce a landscape buffer — the property the canvas depends on.
    func testLandscapeLeftAlwaysYieldsALandscapeCandidate() {
        for residue in [0, 90] {
            let candidates = Set(CaptureRotationGeometry.landscapeCandidates(portraitResidue: residue))
            for reported in [0, 90, 180, 270] {
                let chosen = CaptureRotationGeometry.landscapeLeftAngle(
                    horizonAngle: CGFloat(reported), portraitResidue: residue
                )
                XCTAssertTrue(candidates.contains(chosen), "reported \(reported) residue \(residue) -> \(chosen)")
                XCTAssertTrue(
                    CaptureRotationGeometry.producesLandscape(angle: CGFloat(chosen), portraitResidue: residue)
                )
            }
        }
    }

    /// A landscape connection angle must give the writer a landscape canvas.
    func testLandscapeCanvasFromObservedPortraitBuffer() {
        // iPhone 16: observed 1080x1920 at 90 (portrait); canvas at 180 is landscape.
        let size = CaptureRotationGeometry.expectedDimensions(
            observedWidth: 1080, observedHeight: 1920, observedAngle: 90, targetAngle: 180
        )
        XCTAssertEqual(size.width, 1920)
        XCTAssertEqual(size.height, 1080)
    }
}
