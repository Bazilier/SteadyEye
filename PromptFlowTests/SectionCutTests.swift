import XCTest
import CoreMedia
@testable import PromptFlow

/// Cutting a take down to the last take of each section.
final class SectionCutTests: XCTestCase {

    private func t(_ seconds: Double) -> CMTime { CMTime(seconds: 100 + seconds, preferredTimescale: 600) }
    private let firstFrame = CMTime(seconds: 100, preferredTimescale: 600)
    private let lead = SectionTakeLog.leadInSec

    private func assertRanges(_ ranges: [ClosedRange<Double>]?, _ expected: [(Double, Double)],
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let ranges else { return XCTFail("No ranges", file: file, line: line) }
        XCTAssertEqual(ranges.count, expected.count, file: file, line: line)
        for (range, (lo, hi)) in zip(ranges, expected) {
            XCTAssertEqual(range.lowerBound, lo, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(range.upperBound, hi, accuracy: 0.001, file: file, line: line)
        }
    }

    // MARK: - Take log

    func testOneTakePerSection() {
        var log = SectionTakeLog()
        log.begin(section: 0, at: t(0.5)); log.end(at: t(5))
        log.begin(section: 1, at: t(8)); log.end(at: t(12))
        assertRanges(log.keptRanges(firstFrame: firstFrame, fileEnd: 14), [(0.5 - lead, 5), (8 - lead, 12)])
    }

    func testReplayKeepsLastTake() {
        var log = SectionTakeLog()
        log.begin(section: 0, at: t(1)); log.end(at: t(5))
        log.begin(section: 0, at: t(8)); log.end(at: t(12))
        log.begin(section: 1, at: t(15)); log.end(at: t(20))
        assertRanges(log.keptRanges(firstFrame: firstFrame, fileEnd: 21), [(8 - lead, 12), (15 - lead, 20)])
    }

    func testRestartMidSectionDropsTheCutShortTake() {
        var log = SectionTakeLog()
        log.begin(section: 0, at: t(1))
        log.begin(section: 0, at: t(4))   // ↺ mid-read
        log.end(at: t(9))
        assertRanges(log.keptRanges(firstFrame: firstFrame, fileEnd: 10), [(4 - lead, 9)])
    }

    func testOpenTakeRunsToFileEnd() {
        var log = SectionTakeLog()
        log.begin(section: 0, at: t(1)); log.end(at: t(5))
        log.begin(section: 1, at: t(7))
        assertRanges(log.keptRanges(firstFrame: firstFrame, fileEnd: 11), [(1 - lead, 5), (7 - lead, 11)])
    }

    func testTakeBeforeFirstFrameClampsToZero() {
        var log = SectionTakeLog()
        log.begin(section: 0, at: t(-0.4)); log.end(at: t(3))
        assertRanges(log.keptRanges(firstFrame: firstFrame, fileEnd: 4), [(0, 3)])
    }

    func testLeadInNeverOverlapsPreviousPart() {
        var log = SectionTakeLog()
        log.begin(section: 0, at: t(0)); log.end(at: t(5))
        log.begin(section: 1, at: t(5.1)); log.end(at: t(9))
        assertRanges(log.keptRanges(firstFrame: firstFrame, fileEnd: 10), [(0, 5), (5, 9)])
    }

    func testNoTakesIsNil() {
        XCTAssertNil(SectionTakeLog().keptRanges(firstFrame: firstFrame, fileEnd: 10))
    }

    // MARK: - Gaps

    func testGapsAroundKeptParts() {
        let gaps = SectionCutComposition.gaps(keeping: [1...4, 6...9], total: 12)
        XCTAssertEqual(gaps, [0...1, 4...6, 9...12])
    }

    func testNoGapAtEdgesWhenKeptToThem() {
        XCTAssertEqual(SectionCutComposition.gaps(keeping: [0...4, 6...12], total: 12), [4...6])
    }

    func testTinyGapsLeftIn() {
        XCTAssertEqual(SectionCutComposition.gaps(keeping: [0...4, 4.02...12], total: 12), [])
    }

    func testPartsPastTheEndAreClamped() {
        XCTAssertEqual(SectionCutComposition.gaps(keeping: [2...20], total: 12), [0...2])
    }

    // MARK: - Recording storage

    func testRecordingRoundTripsCuts() {
        let recording = Recording(fileName: "x.mov", scriptTitle: "x", duration: 12, hasWatermark: false)
        XCTAssertNil(recording.sectionCuts)
        XCTAssertEqual(recording.displayDuration, 12)
        recording.sectionCuts = [1...4, 6...9]
        XCTAssertEqual(recording.sectionCuts, [1...4, 6...9])
        XCTAssertTrue(recording.usesSectionCuts)
        XCTAssertEqual(recording.displayDuration, 6, accuracy: 0.001)
        recording.sectionCutsEnabled = false
        XCTAssertEqual(recording.displayDuration, 12)
    }
}
