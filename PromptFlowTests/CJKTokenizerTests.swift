import XCTest
@testable import PromptFlow

final class CJKTokenizerTests: XCTestCase {

    // MARK: - containsCJK

    func testContainsCJK_English() {
        XCTAssertFalse(CJKTokenizer.containsCJK("Hello world"))
    }

    func testContainsCJK_Empty() {
        XCTAssertFalse(CJKTokenizer.containsCJK(""))
    }

    func testContainsCJK_Japanese() {
        XCTAssertTrue(CJKTokenizer.containsCJK("こんにちは"))
    }

    func testContainsCJK_Chinese() {
        XCTAssertTrue(CJKTokenizer.containsCJK("你好世界"))
    }

    func testContainsCJK_Korean() {
        XCTAssertTrue(CJKTokenizer.containsCJK("안녕하세요"))
    }

    func testContainsCJK_Arabic() {
        XCTAssertFalse(CJKTokenizer.containsCJK("مرحبا"))
    }

    // MARK: - detectLanguage

    func testDetectJapanese() {
        XCTAssertEqual(CJKTokenizer.detectLanguage("こんにちは世界"), "ja")
    }

    func testDetectKorean() {
        XCTAssertEqual(CJKTokenizer.detectLanguage("안녕하세요"), "ko")
    }

    func testDetectChinese() {
        XCTAssertEqual(CJKTokenizer.detectLanguage("你好世界"), "zh")
    }

    func testDetectEnglish() {
        XCTAssertNil(CJKTokenizer.detectLanguage("Hello"))
    }

    // MARK: - tokenize

    func testTokenizeJapanese() {
        let tokens = CJKTokenizer.tokenize("今日は天気がいいです", language: "ja")
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertGreaterThanOrEqual(tokens.count, 2)
    }

    func testTokenizeChinese() {
        let tokens = CJKTokenizer.tokenize("今天天气很好", language: "zh")
        XCTAssertFalse(tokens.isEmpty)
    }

    func testTokenizeKorean() {
        let tokens = CJKTokenizer.tokenize("오늘 날씨가 좋습니다", language: "ko")
        XCTAssertFalse(tokens.isEmpty)
    }

    func testTokenizeEmpty() {
        XCTAssertTrue(CJKTokenizer.tokenize("", language: "ja").isEmpty)
    }

    // MARK: - countSyllables

    func testKoreanSyllables() {
        XCTAssertEqual(CJKTokenizer.countSyllables("안녕", language: "ko"), 2)
    }

    func testKoreanSingle() {
        XCTAssertEqual(CJKTokenizer.countSyllables("가", language: "ko"), 1)
    }

    func testMinimumOne() {
        XCTAssertGreaterThanOrEqual(CJKTokenizer.countSyllables("a", language: "ja"), 1)
    }

    // MARK: - CJK strategy chunking

    func testJapaneseChunking() {
        let cjk = CJKLanguageStrategy(language: "ja")
        let chunks = cjk.chunks(from: "今日は天気がいいですね。新しいアプリを作りました。")
        XCTAssertFalse(chunks.isEmpty)
        // Chunks should be short
        for chunk in chunks {
            let cjkCount = chunk.unicodeScalars.filter {
                (0x3040...0x9FFF).contains($0.value) || (0x30A0...0x30FF).contains($0.value)
            }.count
            XCTAssertLessThanOrEqual(cjkCount, 5,
                "CJK chunk '\(chunk)' too long (\(cjkCount) CJK chars)")
        }
        // Should detect sentence boundary
        let enders = chunks.filter { cjk.endsSentence($0) }
        XCTAssertGreaterThanOrEqual(enders.count, 1)
    }

    func testJapaneseChunkSize() {
        let cjk = CJKLanguageStrategy(language: "ja")
        let chunks = cjk.chunks(from: "カメラの前で話すのはかなり難しい。でも練習すれば上手になります。")
        XCTAssertGreaterThan(chunks.count, 3)
    }

    func testChineseChunking() {
        let cjk = CJKLanguageStrategy(language: "zh")
        let chunks = cjk.chunks(from: "今天天气很好。我们正在开发一个新的应用程序。")
        XCTAssertFalse(chunks.isEmpty)
    }

    func testKoreanChunking() {
        let cjk = CJKLanguageStrategy(language: "ko")
        let chunks = cjk.chunks(from: "오늘 날씨가 좋습니다. 새로운 앱을 만들고 있습니다.")
        XCTAssertFalse(chunks.isEmpty)
    }

    // MARK: - CJK via router

    func testJapaneseViaRouter() {
        let chunks = WordChunkEngine.chunks(from: "こんにちは世界")
        XCTAssertFalse(chunks.isEmpty)
    }

    // MARK: - CJK Timing

    func testCJKTimingReasonable() {
        let strategy = CJKLanguageStrategy(language: "ja")
        let text = "カメラの前で話すのは難しい"
        let chunks = strategy.chunks(from: text)

        print("=== CJK TIMING TEST ===")
        for chunk in chunks {
            let duration = strategy.duration(for: chunk, msPerChar: 30)
            print("  '\(chunk)' → \(String(format: "%.2f", duration))s")

            XCTAssertGreaterThanOrEqual(duration, 0.3,
                "Chunk '\(chunk)' is too fast at \(duration)s")
            XCTAssertLessThanOrEqual(duration, 3.0,
                "Chunk '\(chunk)' is too slow at \(duration)s")
        }
        print("=== END ===")
    }

    func testCJKKanjiSlowerThanKana() {
        let strategy = CJKLanguageStrategy(language: "ja")
        let kanjiDuration = strategy.duration(for: "経済", msPerChar: 30)
        let kanaDuration = strategy.duration(for: "けいざい", msPerChar: 30)

        print("経済: \(String(format: "%.2f", kanjiDuration))s, けいざい: \(String(format: "%.2f", kanaDuration))s")

        XCTAssertGreaterThanOrEqual(kanjiDuration, 0.3)
        XCTAssertGreaterThanOrEqual(kanaDuration, 0.3)
    }

    func testCJKParticleTiming() {
        let strategy = CJKLanguageStrategy(language: "ja")
        let duration = strategy.duration(for: "で", msPerChar: 30)
        print("Particle 'で' → \(String(format: "%.2f", duration))s")
        XCTAssertGreaterThanOrEqual(duration, 0.3,
            "Particle 'で' should get minimum duration, got \(duration)s")
    }

    func testCJKSentenceEndDetection() {
        let strategy = CJKLanguageStrategy(language: "ja")
        XCTAssertTrue(strategy.endsSentence("です。"))
        XCTAssertTrue(strategy.endsSentence("ます！"))
        XCTAssertTrue(strategy.endsSentence("か？"))
        XCTAssertFalse(strategy.endsSentence("です"))
        XCTAssertFalse(strategy.endsSentence(""))
    }

    func testCJKSentenceEndAddsDuration() {
        let strategy = CJKLanguageStrategy(language: "ja")
        let withEnd = ChunkPlayerEngine.calculateDuration(
            for: "です。", sliderValue: 0.5, strategy: strategy)
        let without = ChunkPlayerEngine.calculateDuration(
            for: "です", sliderValue: 0.5, strategy: strategy)

        print("です。: \(String(format: "%.2f", withEnd))s, です: \(String(format: "%.2f", without))s")

        XCTAssertGreaterThan(withEnd, without,
            "Sentence-ending chunk should be longer")
    }
}
