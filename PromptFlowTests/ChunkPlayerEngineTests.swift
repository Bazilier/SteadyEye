import XCTest
@testable import PromptFlow

final class ChunkPlayerEngineTests: XCTestCase {

    let slider: Double = 0.5

    // MARK: - isPause

    func testIsPause() {
        XCTAssertTrue(ChunkPlayerEngine.isPause("//"))
        XCTAssertTrue(ChunkPlayerEngine.isPause(" // "))
    }

    func testIsNotPause() {
        XCTAssertFalse(ChunkPlayerEngine.isPause("hello"))
        XCTAssertFalse(ChunkPlayerEngine.isPause("/"))
        XCTAssertFalse(ChunkPlayerEngine.isPause("///"))
        XCTAssertFalse(ChunkPlayerEngine.isPause(""))
    }

    // MARK: - Pause duration

    func testPauseDuration() {
        let d = ChunkPlayerEngine.calculateDuration(for: "//", sliderValue: slider)
        XCTAssertEqual(d, 0.5, accuracy: 0.01)
    }

    func testPauseDurationIgnoresSlider() {
        let slow = ChunkPlayerEngine.calculateDuration(for: "//", sliderValue: 0.0)
        let fast = ChunkPlayerEngine.calculateDuration(for: "//", sliderValue: 1.0)
        XCTAssertEqual(slow, fast, accuracy: 0.01)
    }

    // MARK: - Normal duration

    func testNormalChunkPositive() {
        let d = ChunkPlayerEngine.calculateDuration(for: "Hello", sliderValue: slider)
        XCTAssertGreaterThan(d, 0)
    }

    func testSlowerSpeedLongerDuration() {
        let slow = ChunkPlayerEngine.calculateDuration(for: "Hello", sliderValue: 0.0)
        let fast = ChunkPlayerEngine.calculateDuration(for: "Hello", sliderValue: 1.0)
        XCTAssertGreaterThan(slow, fast)
    }

    // MARK: - Sentence-end +0.3s

    func testSentenceEndAddsPause() {
        let without = ChunkPlayerEngine.calculateDuration(for: "word", sliderValue: slider)
        let with = ChunkPlayerEngine.calculateDuration(for: "word.", sliderValue: slider)
        XCTAssertEqual(with - without, 0.3, accuracy: 0.05)
    }

    func testArabicSentenceEnd() {
        let without = ChunkPlayerEngine.calculateDuration(
            for: "ماذا", sliderValue: slider, strategy: ArabicLanguageStrategy())
        let with = ChunkPlayerEngine.calculateDuration(
            for: "ماذا؟", sliderValue: slider, strategy: ArabicLanguageStrategy())
        XCTAssertGreaterThan(with, without)
    }

    func testCJKSentenceEnd() {
        let cjk = CJKLanguageStrategy(language: "ja")
        let without = ChunkPlayerEngine.calculateDuration(
            for: "です", sliderValue: slider, strategy: cjk)
        let with = ChunkPlayerEngine.calculateDuration(
            for: "です。", sliderValue: slider, strategy: cjk)
        XCTAssertGreaterThan(with, without)
    }

    // MARK: - Abbreviations

    func testAbbreviationLongerThanNormal() {
        let latin = LatinLanguageStrategy()
        let dAbbrev = ChunkPlayerEngine.calculateDuration(
            for: "CEO", sliderValue: slider, strategy: latin)
        let dNormal = ChunkPlayerEngine.calculateDuration(
            for: "cat", sliderValue: slider, strategy: latin)
        XCTAssertGreaterThanOrEqual(dAbbrev, dNormal)
    }

    func testTwoLetterAbbreviation() {
        let d = ChunkPlayerEngine.calculateDuration(
            for: "AI", sliderValue: slider, strategy: LatinLanguageStrategy())
        XCTAssertGreaterThanOrEqual(d, 0.3)
    }

    func testArabicNotAbbreviation() {
        let d = ChunkPlayerEngine.calculateDuration(
            for: "مرحبا", sliderValue: slider, strategy: ArabicLanguageStrategy())
        XCTAssertGreaterThan(d, 0)
    }

    // MARK: - CJK duration

    func testCJKChunkPositive() {
        let d = ChunkPlayerEngine.calculateDuration(
            for: "猫", sliderValue: slider, strategy: CJKLanguageStrategy(language: "ja"))
        XCTAssertGreaterThan(d, 0)
    }

    func testKoreanDuration() {
        let d = ChunkPlayerEngine.calculateDuration(
            for: "안녕", sliderValue: slider, strategy: CJKLanguageStrategy(language: "ko"))
        XCTAssertGreaterThan(d, 0)
    }
}
