import XCTest
@testable import PromptFlow

final class WordChunkEngineTests: XCTestCase {

    // MARK: - Basic chunking (via router)

    func testEmptyString() {
        XCTAssertTrue(WordChunkEngine.chunks(from: "").isEmpty)
    }

    func testSingleWord() {
        XCTAssertEqual(WordChunkEngine.chunks(from: "Hello"), ["Hello"])
    }

    func testSingleLongWord() {
        XCTAssertEqual(WordChunkEngine.chunks(from: "Supercalifragilistic"), ["Supercalifragilistic"])
    }

    func testWhitespaceOnly() {
        XCTAssertTrue(WordChunkEngine.chunks(from: "   \n\t  ").isEmpty)
    }

    func testMultipleSpaces() {
        XCTAssertEqual(WordChunkEngine.chunks(from: "Hello    world"), ["Hello", "world"])
    }

    func testNewlines() {
        XCTAssertEqual(WordChunkEngine.chunks(from: "Hello\nworld\n\ntest"), ["Hello", "world", "test"])
    }

    // MARK: - Latin strategy: glue words

    func testGlueWordAttachesToNext() {
        let latin = LatinLanguageStrategy()
        let chunks = latin.chunks(from: "the cat")
        XCTAssertEqual(chunks, ["the cat"])
    }

    func testNonGlueWordStandsAlone() {
        let latin = LatinLanguageStrategy()
        XCTAssertEqual(latin.chunks(from: "cat dog bird"), ["cat", "dog", "bird"])
    }

    func testGlueWordExceedsMaxLength() {
        let latin = LatinLanguageStrategy()
        let chunks = latin.chunks(from: "the extraordinary")
        XCTAssertEqual(chunks, ["the", "extraordinary"])
    }

    // MARK: - Sentence endings (universal)

    func testEndsSentencePeriod() {
        XCTAssertTrue(WordChunkEngine.endsSentence("hello."))
    }

    func testEndsSentenceExclamation() {
        XCTAssertTrue(WordChunkEngine.endsSentence("wow!"))
    }

    func testEndsSentenceQuestion() {
        XCTAssertTrue(WordChunkEngine.endsSentence("what?"))
    }

    func testDoesNotEndSentence() {
        XCTAssertFalse(WordChunkEngine.endsSentence("hello"))
        XCTAssertFalse(WordChunkEngine.endsSentence(""))
    }

    // MARK: - Arabic sentence endings

    func testArabicQuestionMark() {
        let arabic = ArabicLanguageStrategy()
        XCTAssertTrue(arabic.endsSentence("ماذا؟"))
    }

    func testArabicPeriod() {
        let arabic = ArabicLanguageStrategy()
        XCTAssertTrue(arabic.endsSentence("نهاية۔"))
    }

    // MARK: - CJK sentence endings

    func testCJKPunctuation() {
        let cjk = CJKLanguageStrategy(language: "ja")
        XCTAssertTrue(cjk.endsSentence("です。"))
        XCTAssertTrue(cjk.endsSentence("何！"))
        XCTAssertTrue(cjk.endsSentence("何？"))
    }

    func testSentenceEndClosesChunk() {
        let latin = LatinLanguageStrategy()
        let chunks = latin.chunks(from: "here. The formula")
        XCTAssertEqual(chunks[0], "here.")
    }

    // MARK: - Pause markers

    func testPauseMarkerChunk() {
        let chunks = WordChunkEngine.chunks(from: "Hello // World")
        XCTAssertTrue(chunks.contains("//"))
    }

    func testMultiplePauseMarkers() {
        let chunks = WordChunkEngine.chunks(from: "A // B // C")
        let pauses = chunks.filter { $0 == "//" }
        XCTAssertEqual(pauses.count, 2)
    }

    // MARK: - Duration

    func testDurationPositive() {
        let d = WordChunkEngine.duration(for: "Hello", sliderValue: 0.5)
        XCTAssertGreaterThan(d, 0)
    }

    func testSlowerSpeedLongerDuration() {
        let slow = WordChunkEngine.duration(for: "Hello", sliderValue: 0.0)
        let fast = WordChunkEngine.duration(for: "Hello", sliderValue: 1.0)
        XCTAssertGreaterThan(slow, fast)
    }

    func testMsPerCharExponential() {
        XCTAssertEqual(WordChunkEngine.msPerChar(forSlider: 0.0), 80.0, accuracy: 0.01)
        XCTAssertGreaterThan(WordChunkEngine.msPerChar(forSlider: 0.0),
                             WordChunkEngine.msPerChar(forSlider: 1.0))
    }

    // MARK: - Arabic text via router

    func testArabicChunking() {
        let chunks = WordChunkEngine.chunks(from: "مرحبا بكم")
        XCTAssertEqual(chunks.count, 2)
    }

    // MARK: - Language detection routing

    func testLatinRouting() {
        let strategy = LanguageDetector.detect("Hello world")
        XCTAssertTrue(strategy is LatinLanguageStrategy)
    }

    func testArabicRouting() {
        let strategy = LanguageDetector.detect("مرحبا بكم")
        XCTAssertTrue(strategy is ArabicLanguageStrategy)
    }

    func testJapaneseRouting() {
        let strategy = LanguageDetector.detect("こんにちは")
        XCTAssertTrue(strategy is CJKLanguageStrategy)
    }

    func testChineseRouting() {
        let strategy = LanguageDetector.detect("你好世界")
        XCTAssertTrue(strategy is CJKLanguageStrategy)
    }

    func testKoreanRouting() {
        let strategy = LanguageDetector.detect("안녕하세요")
        XCTAssertTrue(strategy is CJKLanguageStrategy)
    }

    // MARK: - Strategy abbreviation detection

    func testLatinAbbreviation() {
        let latin = LatinLanguageStrategy()
        XCTAssertTrue(latin.isAbbreviation("CEO"))
        XCTAssertTrue(latin.isAbbreviation("AI"))
        XCTAssertFalse(latin.isAbbreviation("cat"))
    }

    func testArabicNoAbbreviation() {
        let arabic = ArabicLanguageStrategy()
        XCTAssertFalse(arabic.isAbbreviation("مرحبا"))
    }

    func testCJKNoAbbreviation() {
        let cjk = CJKLanguageStrategy(language: "ja")
        XCTAssertFalse(cjk.isAbbreviation("猫"))
    }
}
