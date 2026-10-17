import XCTest
import AVFoundation
@testable import PromptFlow

final class SilenceTrimmerTests: XCTestCase {

    private let frame = SilenceTrimmer.frameSec
    private let margin = SilenceTrimmer.marginSec
    private let outer = SilenceTrimmer.outerMarginSec
    private let opening = SilenceTrimmer.openingMarginSec

    /// Room at -60 dB with voice at -20 dB over `voice` (seconds).
    private func levels(total: Double, room: Float = -60, voice: [ClosedRange<Double>]) -> SilenceTrimmer.Levels {
        let count = Int((total / frame).rounded())
        let db = (0..<count).map { index -> Float in
            let time = Double(index) * frame
            return voice.contains { $0.contains(time) } ? -20 : room
        }
        return SilenceTrimmer.Levels(start: 0, db: db)
    }

    private func assertRange(_ range: ClosedRange<Double>, _ lower: Double, _ upper: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(range.lowerBound, lower, accuracy: frame + 0.001, file: file, line: line)
        XCTAssertEqual(range.upperBound, upper, accuracy: frame + 0.001, file: file, line: line)
    }

    func testEdgesMoveToVoicePlusMargin() {
        // Kept 1...6 and 9...14; voice 1.6...5.2 and 9.5...13.4. The joint
        // gets the tight margin, the video's start the opening one (here as far
        // as the kept edge), its end the outer one.
        let lv = levels(total: 15, voice: [1.6...5.2, 9.5...13.4])
        let trimmed = SilenceTrimmer.trim([1...6, 9...14], levels: lv)
        assertRange(trimmed[0], max(1, 1.6 - opening), 5.2 + margin)
        assertRange(trimmed[1], 9.5 - margin, 13.4 + outer)
    }

    func testMiddlePartGetsTightMarginsBothSides() {
        let lv = levels(total: 20, voice: [1...3, 7.6...10.4, 15...18])
        let trimmed = SilenceTrimmer.trim([0.5...4, 7...11, 14...19], levels: lv)
        assertRange(trimmed[1], 7.6 - margin, 10.4 + margin)
    }

    func testOuterMarginStaysInsideKeptPart() {
        // Voice close to the outer edges: the wider margin cannot push past them.
        let lv = levels(total: 6, voice: [0.8...5.3])
        let trimmed = SilenceTrimmer.trim([0.6...5.5], levels: lv)
        assertRange(trimmed[0], 0.6, 5.5)
    }

    func testEdgesNeverMoveOutward() {
        // Voice runs right up to the kept edges and past them.
        let lv = levels(total: 10, voice: [0.5...4.5, 6...9.5])
        let trimmed = SilenceTrimmer.trim([1...4, 6.2...9], levels: lv)
        assertRange(trimmed[0], 1, 4)
        assertRange(trimmed[1], 6.2, 9)
    }

    func testEdgesMoveAtMostMaxShift() {
        // Voice only in the middle of a long part.
        let lv = levels(total: 12, voice: [5...6])
        let trimmed = SilenceTrimmer.trim([1...10], levels: lv)
        assertRange(trimmed[0], 1 + SilenceTrimmer.maxShiftSec, 10 - SilenceTrimmer.maxShiftSec)
    }

    func testPartWithoutVoiceIsLeftAlone() {
        let lv = levels(total: 10, voice: [1...3])
        let trimmed = SilenceTrimmer.trim([0.5...3.5, 5...9], levels: lv)
        assertRange(trimmed[1], 5, 9)
    }

    func testClicksAreNotVoice() {
        // A 40 ms knock before the voice.
        let lv = levels(total: 8, voice: [1.2...1.24, 2...5])
        let trimmed = SilenceTrimmer.trim([1...6], levels: lv)
        assertRange(trimmed[0], 2 - opening, 5 + outer)
    }

    func testNoisyRoomStillFindsVoice() {
        let lv = levels(total: 10, room: -35, voice: [2...6])
        let trimmed = SilenceTrimmer.trim([1...7], levels: lv)
        assertRange(trimmed[0], 2 - opening, 6 + outer)
    }

    func testVoiceAsLoudAsRoomLeavesCutAlone() {
        // No contrast: everything sits at the room level.
        let lv = levels(total: 10, room: -20, voice: [])
        XCTAssertEqual(SilenceTrimmer.trim([1...4, 6...9], levels: lv), [1...4, 6...9])
    }

    // MARK: - Reading a real file

    func testReadsLoudnessFromAnAudioFile() async throws {
        // 1 s of silence, 1 s of a 440 Hz tone, 1 s of silence.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trim-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        // In a scope: the file is finished when it is released.
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1
            ])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 3)!
            buffer.frameLength = 44_100 * 3
            let samples = buffer.floatChannelData![0]
            for index in 0..<Int(buffer.frameLength) {
                let time = Double(index) / 44_100
                samples[index] = (1...2).contains(time) ? Float(0.3 * sin(2 * .pi * 440 * time)) : 0
            }
            try file.write(from: buffer)
        }

        let lv = try await SilenceTrimmer.levels(ofAudioIn: url)
        let loud = SilenceTrimmer.voiceRuns(lv.db, above: -40)
        XCTAssertEqual(loud.count, 1)
        let run = try XCTUnwrap(loud.first)
        XCTAssertEqual(lv.time(ofFrame: run.lowerBound), 1, accuracy: 0.1)
        XCTAssertEqual(lv.time(ofFrame: run.upperBound), 2, accuracy: 0.1)
    }
}
