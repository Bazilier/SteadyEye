import XCTest
import Combine
@testable import PromptFlow

final class ChunkPlayerEngineTests: XCTestCase {

    let slider: Double = 0.5

    // MARK: - isPause

    func testIsPause() {
        XCTAssertTrue(ChunkTimingCalculator.isPause("//"))
        XCTAssertTrue(ChunkTimingCalculator.isPause(" // "))
    }

    func testIsNotPause() {
        XCTAssertFalse(ChunkTimingCalculator.isPause("hello"))
        XCTAssertFalse(ChunkTimingCalculator.isPause("/"))
        XCTAssertFalse(ChunkTimingCalculator.isPause("///"))
        XCTAssertFalse(ChunkTimingCalculator.isPause(""))
    }

    // MARK: - Pause duration

    func testPauseDuration() {
        let d = ChunkTimingCalculator.calculateDuration(for: "//", sliderValue: slider)
        XCTAssertEqual(d, 0.5, accuracy: 0.01)
    }

    func testPauseDurationScalesWithSpeed() {
        let slow = ChunkTimingCalculator.calculateDuration(for: "//", sliderValue: 0.0)
        let fast = ChunkTimingCalculator.calculateDuration(for: "//", sliderValue: 1.0)
        XCTAssertEqual(slow, 0.5, accuracy: 0.01)
        XCTAssertEqual(fast, 0.2, accuracy: 0.01)
    }

    // MARK: - Normal duration

    func testNormalChunkPositive() {
        let d = ChunkTimingCalculator.calculateDuration(for: "Hello", sliderValue: slider)
        XCTAssertGreaterThan(d, 0)
    }

    func testSlowerSpeedLongerDuration() {
        let slow = ChunkTimingCalculator.calculateDuration(for: "Hello", sliderValue: 0.0)
        let fast = ChunkTimingCalculator.calculateDuration(for: "Hello", sliderValue: 1.0)
        XCTAssertGreaterThan(slow, fast)
    }

    // MARK: - Sentence-end +0.3s

    func testSentenceEndAddsPause() {
        let without = ChunkTimingCalculator.calculateDuration(for: "word", sliderValue: slider)
        let with = ChunkTimingCalculator.calculateDuration(for: "word.", sliderValue: slider)
        XCTAssertEqual(with - without, 0.3, accuracy: 0.05)
    }

    func testArabicSentenceEnd() {
        let without = ChunkTimingCalculator.calculateDuration(
            for: "ماذا", sliderValue: slider, strategy: ArabicLanguageStrategy())
        let with = ChunkTimingCalculator.calculateDuration(
            for: "ماذا؟", sliderValue: slider, strategy: ArabicLanguageStrategy())
        XCTAssertGreaterThan(with, without)
    }

    func testCJKSentenceEnd() {
        let cjk = CJKLanguageStrategy(language: "ja")
        let without = ChunkTimingCalculator.calculateDuration(
            for: "です", sliderValue: slider, strategy: cjk)
        let with = ChunkTimingCalculator.calculateDuration(
            for: "です。", sliderValue: slider, strategy: cjk)
        XCTAssertGreaterThan(with, without)
    }

    // MARK: - Abbreviations

    func testAbbreviationLongerThanNormal() {
        let latin = LatinLanguageStrategy()
        let dAbbrev = ChunkTimingCalculator.calculateDuration(
            for: "CEO", sliderValue: slider, strategy: latin)
        let dNormal = ChunkTimingCalculator.calculateDuration(
            for: "cat", sliderValue: slider, strategy: latin)
        XCTAssertGreaterThanOrEqual(dAbbrev, dNormal)
    }

    func testTwoLetterAbbreviation() {
        let d = ChunkTimingCalculator.calculateDuration(
            for: "AI", sliderValue: slider, strategy: LatinLanguageStrategy())
        XCTAssertGreaterThanOrEqual(d, 0.3)
    }

    func testArabicNotAbbreviation() {
        let d = ChunkTimingCalculator.calculateDuration(
            for: "مرحبا", sliderValue: slider, strategy: ArabicLanguageStrategy())
        XCTAssertGreaterThan(d, 0)
    }

    // MARK: - CJK duration

    func testCJKChunkPositive() {
        let d = ChunkTimingCalculator.calculateDuration(
            for: "猫", sliderValue: slider, strategy: CJKLanguageStrategy(language: "ja"))
        XCTAssertGreaterThan(d, 0)
    }

    func testKoreanDuration() {
        let d = ChunkTimingCalculator.calculateDuration(
            for: "안녕", sliderValue: slider, strategy: CJKLanguageStrategy(language: "ko"))
        XCTAssertGreaterThan(d, 0)
    }

    // MARK: - Engine loading

    /// Long words go through hyphenation in anchor mode, so chunking this
    /// takes well over 50 ms.
    private let slowScript = Array(repeating: "extraordinariamente responsabilidad", count: 100)
        .joined(separator: " ")

    @MainActor
    func testCancelledLoadDoesNotWrite() async {
        let engine = ChunkPlayerEngine()
        engine.orpEnabled = true
        // Every value the chunks take, so the check holds whichever run
        // finishes first.
        var seen: [[String]] = []
        let sink = engine.$chunks.sink { seen.append($0) }
        engine.loadScript(slowScript)
        let stale = engine.loadTask
        engine.loadScript("Привет, мир.")
        await stale?.value
        await engine.loadTask?.value
        sink.cancel()
        XCTAssertFalse(seen.contains { $0.count > 2 }, "The cancelled load wrote its chunks")
        XCTAssertEqual(engine.chunks, ["Привет,", "мир."])
    }

    @MainActor
    func testReloadWhilePlayingResumesAfterSlowLoad() async throws {
        let engine = ChunkPlayerEngine()
        engine.orpEnabled = false
        // Several times the 50 ms the resume used to wait.
        engine.loadScript(Array(repeating: slowScript, count: 3).joined(separator: " "))
        await engine.loadTask?.value
        engine.play()
        XCTAssertTrue(engine.isPlaying)

        // Anchor mode re-chunks through hyphenation: the slow path.
        engine.orpEnabled = true
        engine.reloadChunks()
        await engine.loadTask?.value
        // The resume runs right after the load, on the next main-actor turn.
        for _ in 0..<100 where !engine.isPlaying {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(engine.isPlaying, "Playback did not resume after re-chunking")
    }
}
