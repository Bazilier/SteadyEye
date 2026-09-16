import XCTest
import CoreImage
import CoreVideo
import ImageIO

/// Geometry tests for the capture orientation correction added to
/// `CameraManager.captureOutput` / `CameraManager.orientedToWriter`.
///
/// WHAT THESE TESTS DO NOT DO — read before trusting a green run:
///
/// 1. They do NOT call the production code. `orientedToWriter` is `private`
///    and lives inside `#if !targetEnvironment(simulator)`, so it is not even
///    compiled for the simulator — the only destination available without
///    hardware. The helpers below (`orientation(forRecordingAngle:)`,
///    `rotate(_:to:context:pool:)`, `correctIfNeeded`) are a hand-copy of the
///    production logic. They can drift from it. Making the real symbol
///    testable would require extracting it out of that platform-gated
///    extension, which is a production change and was out of scope here.
///
/// 2. They cover rotation geometry ONLY. Front-camera mirroring is applied by
///    AVCaptureConnection before a buffer ever reaches the app, so a synthetic
///    buffer cannot reproduce it. A green suite is NOT clearance that a real
///    front-camera recording comes out upright — see
///    `testMirroredLandscapeInput_rotatedRight_landsUpsideDown`, which
///    documents the hazard, and verify on device.
///
/// 3. The CIContext here disables colour management so marker colours survive
///    the round trip exactly. Production uses a Metal-backed context with
///    default colour handling. That affects pixel values, not geometry.
final class CaptureOrientationGeometryTests: XCTestCase {

    // MARK: - Mirror of the production logic (see caveat 1 above)

    /// Mirrors the `switch Int(angle)` in `CameraManager.orientedToWriter`.
    private func orientation(forRecordingAngle angle: CGFloat) -> CGImagePropertyOrientation {
        switch Int(angle) {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    /// Mirrors the rotate-and-render step of `CameraManager.orientedToWriter`.
    private func rotate(
        _ pixelBuffer: CVPixelBuffer,
        to orientation: CGImagePropertyOrientation,
        context: CIContext,
        pool: CVPixelBufferPool
    ) -> CVPixelBuffer {
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess,
              let outputBuffer = output else { return pixelBuffer }
        let rotated = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let pinned = rotated.transformed(by: CGAffineTransform(
            translationX: -rotated.extent.minX,
            y: -rotated.extent.minY
        ))
        context.render(pinned, to: outputBuffer)
        return outputBuffer
    }

    /// Mirrors the branch in `CameraManager.captureOutput`: pass the buffer
    /// through untouched unless its orientation contradicts the writer's.
    private func correctIfNeeded(
        _ pixelBuffer: CVPixelBuffer,
        writerAngle: CGFloat,
        context: CIContext,
        pool: CVPixelBufferPool
    ) -> CVPixelBuffer {
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        let writerIsPortrait = writerAngle == 90 || writerAngle == 270
        if writerIsPortrait ? bufferWidth > bufferHeight : bufferHeight > bufferWidth {
            return rotate(
                pixelBuffer,
                to: orientation(forRecordingAngle: writerAngle),
                context: context,
                pool: pool
            )
        }
        return pixelBuffer
    }

    // MARK: - Fixtures

    private struct Marker {
        let name: String
        let row: Int
        let col: Int
        let color: (r: UInt8, g: UInt8, b: UInt8)
    }

    /// 1920x1080 landscape, matching what the connection delivers at angle 0
    /// for the 1080p preset. Corner markers catch cropping, the mid-edge
    /// markers catch edge loss, and the asymmetric marker catches flips that
    /// a symmetric layout would hide.
    private func landscapeMarkers(width w: Int, height h: Int) -> [Marker] {
        [
            Marker(name: "top-left",     row: 0,     col: 0,     color: (255, 0, 0)),
            Marker(name: "top-right",    row: 0,     col: w - 1, color: (0, 255, 0)),
            Marker(name: "bottom-left",  row: h - 1, col: 0,     color: (0, 0, 255)),
            Marker(name: "bottom-right", row: h - 1, col: w - 1, color: (255, 255, 0)),
            Marker(name: "asymmetric",   row: 100,   col: 100,   color: (255, 0, 255)),
            Marker(name: "top-mid",      row: 0,     col: w / 2, color: (0, 255, 255)),
            Marker(name: "bottom-mid",   row: h - 1, col: w / 2, color: (255, 255, 255)),
            Marker(name: "left-mid",     row: h / 2, col: 0,     color: (255, 128, 0)),
            Marker(name: "right-mid",    row: h / 2, col: w - 1, color: (128, 0, 255))
        ]
    }

    private func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess, "CVPixelBufferCreate failed")
        return try XCTUnwrap(buffer)
    }

    private func makePool(width: Int, height: Int) throws -> CVPixelBufferPool {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        XCTAssertEqual(status, kCVReturnSuccess, "CVPixelBufferPoolCreate failed")
        return try XCTUnwrap(pool)
    }

    /// Black background plus the given markers, one pixel each.
    private func fill(_ buffer: CVPixelBuffer, markers: [Marker]) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        memset(base, 0, bytesPerRow * height)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for marker in markers {
            let offset = marker.row * bytesPerRow + marker.col * 4
            bytes[offset] = marker.color.b
            bytes[offset + 1] = marker.color.g
            bytes[offset + 2] = marker.color.r
            bytes[offset + 3] = 255
        }
    }

    private func pixel(_ buffer: CVPixelBuffer, row: Int, col: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, 0, 0) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let offset = row * bytesPerRow + col * 4
        return (bytes[offset + 2], bytes[offset + 1], bytes[offset])
    }

    private func assertPixel(
        _ buffer: CVPixelBuffer,
        row: Int,
        col: Int,
        equals expected: (r: UInt8, g: UInt8, b: UInt8),
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Out-of-range reads land in the row padding and come back black,
        // which would look like a content failure instead of a bad fixture.
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard row >= 0, row < height, col >= 0, col < width else {
            XCTFail(
                "\(message): (row \(row), col \(col)) is outside the \(width)x\(height) buffer",
                file: file,
                line: line
            )
            return
        }
        let actual = pixel(buffer, row: row, col: col)
        let tolerance = 2
        let matches = abs(Int(actual.r) - Int(expected.r)) <= tolerance
            && abs(Int(actual.g) - Int(expected.g)) <= tolerance
            && abs(Int(actual.b) - Int(expected.b)) <= tolerance
        XCTAssertTrue(
            matches,
            "\(message): expected rgb\(expected) at (row \(row), col \(col)), got rgb\(actual)",
            file: file,
            line: line
        )
    }

    private func makeContext() -> CIContext {
        // Colour management off so marker RGB survives the round trip exactly.
        CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    }

    // Destination of an input pixel under each rotation. w/h are INPUT dims.
    private func destinationRight(row r: Int, col c: Int, w: Int, h: Int) -> (row: Int, col: Int) {
        (row: c, col: h - 1 - r)
    }
    private func destinationLeft(row r: Int, col c: Int, w: Int, h: Int) -> (row: Int, col: Int) {
        (row: w - 1 - c, col: r)
    }
    private func destinationDown(row r: Int, col c: Int, w: Int, h: Int) -> (row: Int, col: Int) {
        (row: h - 1 - r, col: w - 1 - c)
    }

    // MARK: - 1. Angle to orientation mapping

    func testAngleToOrientationMapping() {
        XCTAssertEqual(orientation(forRecordingAngle: 90), .right)
        XCTAssertEqual(orientation(forRecordingAngle: 180), .down)
        XCTAssertEqual(orientation(forRecordingAngle: 270), .left)
        XCTAssertEqual(orientation(forRecordingAngle: 0), .up)
    }

    // MARK: - 2. Geometry, .right (recording angle 90)

    func testRotateRight_producesPortraitWithMarkersRotatedClockwise() throws {
        let w = 1920, h = 1080
        let input = try makeBuffer(width: w, height: h)
        let markers = landscapeMarkers(width: w, height: h)
        fill(input, markers: markers)

        let output = rotate(
            input,
            to: .right,
            context: makeContext(),
            pool: try makePool(width: h, height: w)
        )

        XCTAssertEqual(CVPixelBufferGetWidth(output), 1080)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 1920)

        for marker in markers {
            let destination = destinationRight(row: marker.row, col: marker.col, w: w, h: h)
            assertPixel(output, row: destination.row, col: destination.col, equals: marker.color, "\(marker.name) after .right")
        }

        // The asymmetric marker is the flip detector. Input (100, 100) must
        // land at (row 100, col 979) — 1080 - 1 - 100.
        //   * A horizontally mirrored result would put it at col 100.
        //   * An upside-down result would put it at row 1819 (1920 - 1 - 100).
        // Both are asserted absent here, so this test fails if the rotation
        // ever picks up a flip.
        assertPixel(output, row: 100, col: 979, equals: (255, 0, 255), "asymmetric marker, unmirrored destination")
        XCTAssertNotEqual(pixel(output, row: 100, col: 100).r, 255, "result is horizontally mirrored")
        XCTAssertNotEqual(pixel(output, row: 1819, col: 979).r, 255, "result is upside down")
    }

    // MARK: - 3. Geometry, .left and .down

    func testRotateLeft_producesPortraitWithMarkersRotatedCounterClockwise() throws {
        let w = 1920, h = 1080
        let input = try makeBuffer(width: w, height: h)
        let markers = landscapeMarkers(width: w, height: h)
        fill(input, markers: markers)

        let output = rotate(
            input,
            to: .left,
            context: makeContext(),
            pool: try makePool(width: h, height: w)
        )

        XCTAssertEqual(CVPixelBufferGetWidth(output), 1080)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 1920)

        for marker in markers {
            let destination = destinationLeft(row: marker.row, col: marker.col, w: w, h: h)
            assertPixel(output, row: destination.row, col: destination.col, equals: marker.color, "\(marker.name) after .left")
        }

        // Asymmetric marker: input (100, 100) -> (row 1819, col 100).
        // A mirrored result would put it at col 979 instead.
        assertPixel(output, row: 1819, col: 100, equals: (255, 0, 255), "asymmetric marker, unmirrored destination")
    }

    func testRotateDown_keepsLandscapeAndRotates180() throws {
        let w = 1920, h = 1080
        let input = try makeBuffer(width: w, height: h)
        let markers = landscapeMarkers(width: w, height: h)
        fill(input, markers: markers)

        let output = rotate(
            input,
            to: .down,
            context: makeContext(),
            pool: try makePool(width: w, height: h)
        )

        XCTAssertEqual(CVPixelBufferGetWidth(output), 1920)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 1080)

        for marker in markers {
            let destination = destinationDown(row: marker.row, col: marker.col, w: w, h: h)
            assertPixel(output, row: destination.row, col: destination.col, equals: marker.color, "\(marker.name) after .down")
        }

        // Asymmetric marker: input (100, 100) -> (row 979, col 1819).
        assertPixel(output, row: 979, col: 1819, equals: (255, 0, 255), "asymmetric marker after 180")
    }

    // MARK: - 4. Pass-through on the normal path

    func testPortraitBufferIntoPortraitWriter_isReturnedUnchanged() throws {
        let input = try makeBuffer(width: 1080, height: 1920)
        fill(input, markers: [Marker(name: "probe", row: 5, col: 5, color: (255, 0, 255))])
        let pool = try makePool(width: 1080, height: 1920)

        let output = correctIfNeeded(input, writerAngle: 90, context: makeContext(), pool: pool)

        // Identical object: no pool allocation, no CIImage, no render.
        XCTAssertTrue(output === input, "normal path must return the input buffer itself")
        XCTAssertEqual(CVPixelBufferGetBaseAddress(output), CVPixelBufferGetBaseAddress(input))
    }

    func testLandscapeBufferIntoPortraitWriter_isRotated() throws {
        let input = try makeBuffer(width: 1920, height: 1080)
        fill(input, markers: landscapeMarkers(width: 1920, height: 1080))
        let pool = try makePool(width: 1080, height: 1920)

        let output = correctIfNeeded(input, writerAngle: 90, context: makeContext(), pool: pool)

        XCTAssertFalse(output === input, "mis-oriented buffer must be replaced")
        XCTAssertEqual(CVPixelBufferGetWidth(output), 1080)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 1920)
    }

    // MARK: - 5. Cropping regression

    /// The shipped defect kept only the left 1080 of 1920 columns and dropped
    /// everything above row 1080 of the portrait canvas. Every marker on all
    /// four input edges must survive the correction.
    func testNoContentIsCropped() throws {
        let w = 1920, h = 1080
        let input = try makeBuffer(width: w, height: h)
        let markers = landscapeMarkers(width: w, height: h)
        fill(input, markers: markers)

        let output = correctIfNeeded(
            input,
            writerAngle: 90,
            context: makeContext(),
            pool: try makePool(width: h, height: w)
        )

        for marker in markers {
            let destination = destinationRight(row: marker.row, col: marker.col, w: w, h: h)
            assertPixel(
                output,
                row: destination.row,
                col: destination.col,
                equals: marker.color,
                "\(marker.name) survived the correction (input col \(marker.col) of \(w))"
            )
        }

        // Under the defect, input columns >= 1080 were never written, leaving
        // the top of the canvas black. top-right (col 1919) lands at row 1919
        // of the output and is the direct regression probe.
        assertPixel(output, row: 1919, col: 1079, equals: (0, 255, 0), "top-right corner (defect dropped this column)")
    }

    // MARK: - Mirroring hazard (documentation, not a pass/fail on production)

    /// If AVCaptureConnection is mirroring front-camera frames, the buffer we
    /// receive at angle 0 is already horizontally flipped. Rotating THAT with
    /// .right does not give the same result as the connection's own mirrored
    /// portrait output: rotation and mirroring do not commute.
    ///
    /// Composing the operations, R90 . H_landscape == V_portrait . R90 — a
    /// vertical flip of the correctly rotated frame, i.e. upside down. The
    /// operation that would reproduce the connection's mirrored portrait is
    /// H_portrait . R90, which equals a 270-degree rotation (.left) applied
    /// to the mirrored landscape input.
    ///
    /// This test pins the algebra with real pixels on a small buffer. It says
    /// nothing about whether this app's connection actually mirrors — that is
    /// unverified and needs a device.
    func testMirroredLandscapeInput_rotatedRight_landsUpsideDown() throws {
        let w = 8, h = 4
        let marker = Marker(name: "probe", row: 0, col: 1, color: (255, 0, 255))

        // Un-mirrored sensor frame: probe near the top-left.
        let plain = try makeBuffer(width: w, height: h)
        fill(plain, markers: [marker])

        // Same frame as the connection would hand us WITH mirroring on.
        let mirrored = try makeBuffer(width: w, height: h)
        fill(mirrored, markers: [Marker(name: "probe", row: marker.row, col: w - 1 - marker.col, color: marker.color)])

        let context = makeContext()
        let plainRotated = rotate(plain, to: .right, context: context, pool: try makePool(width: h, height: w))
        let mirroredRotated = rotate(mirrored, to: .right, context: context, pool: try makePool(width: h, height: w))

        let plainDestination = destinationRight(row: marker.row, col: marker.col, w: w, h: h)
        assertPixel(plainRotated, row: plainDestination.row, col: plainDestination.col, equals: marker.color, "unmirrored input rotates as expected")

        // The mirrored input puts the probe at the vertically flipped row:
        // (h' - 1 - row) where h' == w. Same column — so the subject would
        // appear upside down, not merely mirrored.
        let flippedRow = w - 1 - plainDestination.row
        assertPixel(mirroredRotated, row: flippedRow, col: plainDestination.col, equals: marker.color, "mirrored input lands vertically flipped")
        XCTAssertNotEqual(flippedRow, plainDestination.row, "fixture must be asymmetric for this to mean anything")

        // .left on the mirrored input restores the connection's own layout.
        let mirroredRotatedLeft = rotate(mirrored, to: .left, context: context, pool: try makePool(width: h, height: w))
        // Mirror the column in PORTRAIT space: the rotated buffer is h wide,
        // not w. Mirroring with w indexes past the end of the row.
        let portraitWidth = CVPixelBufferGetWidth(mirroredRotatedLeft)
        assertPixel(mirroredRotatedLeft, row: plainDestination.row, col: portraitWidth - 1 - plainDestination.col, equals: marker.color, ".left on mirrored input is the mirrored portrait")
    }
}
