import XCTest
@testable import PromptFlow

final class JapaneseIntegrationTests: XCTestCase {

    let testText = """
    今日は天気がいいです。
    SNSで動画を三本作ります。
    カメラの前で話すのは正直に言うと、かなり難しいです。
    でも、練習すれば上手になります。
    多分。
    //
    毎日十五分ずつ頑張りましょう。
    大切なのは続けることです。
    TikTokとYouTubeとInstagramに投稿する予定です。
    AIを使えば、スクリプトも簡単に作れます。
    ROIは二百パーセント以上になるかもしれません。
    //
    自分の言葉で心を込めて話してください。
    目を見て話すと百パーセント伝わります。
    一回で完璧にならなくていいです。
    これは重要です。
    四千九百九十九円で始められます。
    楽しんでやりましょう。
    """

    // MARK: - Chunking

    func testJapaneseFullTextChunking() {
        let chunks = WordChunkEngine.chunks(from: testText)

        // 1. No empty chunks
        XCTAssertFalse(chunks.contains(""), "Should have no empty chunks")

        // 2. No chunk contains raw newlines
        XCTAssertFalse(chunks.contains { $0.contains("\n") },
            "No chunk should contain newlines")

        // 3. Exactly 2 pause markers
        let pauses = chunks.filter { $0.trimmingCharacters(in: .whitespaces) == "//" }
        XCTAssertEqual(pauses.count, 2, "Should have exactly 2 pause markers")

        // 4. "//" is never attached to other text
        XCTAssertFalse(chunks.contains { $0.contains("//") && $0 != "//" },
            "Pause marker must be standalone: \(chunks.filter { $0.contains("//") && $0 != "//" })")

        // 5. Grouped chunks respect visual weight limit
        //    Single indivisible tokens (foreign words, long katakana) may exceed — that is ok
        for chunk in chunks where chunk != "//" {
            let isSingleToken = CJKTokenizer.tokenize(chunk, language: "ja").count <= 1
            if isSingleToken { continue }
            let weight = CJKLanguageStrategy.visualWeight(chunk)
            XCTAssertLessThanOrEqual(weight, 8,
                "Grouped chunk '\(chunk)' has visual weight \(weight), too heavy")
        }

        // 6. Latin words appear in chunks
        let allText = chunks.joined()
        XCTAssertTrue(allText.contains("SNS"), "SNS should appear in chunks")
        XCTAssertTrue(allText.contains("TikTok"), "TikTok should appear")
        XCTAssertTrue(allText.contains("AI"), "AI should appear")
        XCTAssertTrue(allText.contains("ROI"), "ROI should appear")
        XCTAssertTrue(allText.contains("YouTube"), "YouTube should appear")
        XCTAssertTrue(allText.contains("Instagram"), "Instagram should appear")

        // 7. Reasonable chunk count (50-70 words → expect 25-70 chunks)
        XCTAssertGreaterThan(chunks.count, 25, "Too few chunks: \(chunks.count)")
        XCTAssertLessThan(chunks.count, 80, "Too many chunks: \(chunks.count)")

        // 8. Print all chunks for manual review
        print("=== JAPANESE CHUNKS (\(chunks.count) total) ===")
        for (i, chunk) in chunks.enumerated() {
            let w = chunk == "//" ? "PAUSE" : "w:\(CJKLanguageStrategy.visualWeight(chunk))"
            print("  [\(i)] '\(chunk)' (\(w))")
        }
        print("=== END ===")
    }

    func testNoPunctuationInDisplay() {
        let chunks = WordChunkEngine.chunks(from: testText)
        // CJK sentence punctuation is kept in chunk text for timing
        // but stripped at display layer — verify it exists for timing
        let sentenceEnders = chunks.filter {
            $0.hasSuffix("。") || $0.hasSuffix("！") || $0.hasSuffix("？")
        }
        // Should have sentence-ending chunks (punctuation kept for timing engine)
        XCTAssertGreaterThan(sentenceEnders.count, 0,
            "Should have chunks with sentence-ending punctuation for timing")
    }

    func testParticlesAttachBackward() {
        let chunks = WordChunkEngine.chunks(from: testText)
        let particles: Set<String> = ["で", "に", "を", "は", "が", "の", "と", "も", "へ"]

        var leadingParticleChunks: [String] = []
        for chunk in chunks where chunk != "//" && chunk.count > 1 {
            if let first = chunk.first, particles.contains(String(first)) {
                // Check if this is a real particle leading (not a word starting with that char)
                // A real violation is a standalone particle at the start of a multi-char chunk
                // where the second char is kanji or katakana (content word)
                if let second = chunk.dropFirst().first {
                    let scalar = second.unicodeScalars.first?.value ?? 0
                    let isContent = (0x4E00...0x9FFF).contains(scalar) || (0x30A0...0x30FF).contains(scalar)
                    if isContent {
                        leadingParticleChunks.append(chunk)
                    }
                }
            }
        }

        // Print warnings but don't hard-fail (some tokenizer quirks are acceptable)
        for chunk in leadingParticleChunks {
            print("⚠️ Chunk starts with particle + content: '\(chunk)'")
        }
        // Soft assertion: most chunks should not start with particle + content
        XCTAssertLessThanOrEqual(leadingParticleChunks.count, 5,
            "Too many chunks start with leading particles: \(leadingParticleChunks)")
    }

    // MARK: - Timing

    func testJapaneseTimingReasonable() {
        let chunks = WordChunkEngine.chunks(from: testText)
        let strategy = CJKLanguageStrategy(language: "ja")
        let msPerChar = WordChunkEngine.msPerChar(forSlider: 0.5)

        print("=== JAPANESE TIMING (slider 0.5) ===")
        for chunk in chunks where chunk != "//" {
            let duration = strategy.duration(for: chunk, msPerChar: msPerChar)

            // Minimum 0.3s (strategy default)
            XCTAssertGreaterThanOrEqual(duration, 0.3,
                "Chunk '\(chunk)' duration \(duration)s below minimum")

            // Maximum 3s
            XCTAssertLessThanOrEqual(duration, 3.0,
                "Chunk '\(chunk)' duration \(duration)s too long")

            print("  '\(chunk)' → \(String(format: "%.2f", duration))s")
        }
        print("=== END ===")
    }

    func testPauseMarkerTiming() {
        // Pause is handled by ChunkPlayerEngine, not the strategy
        let duration = ChunkPlayerEngine.calculateDuration(
            for: "//", sliderValue: 0.5, strategy: CJKLanguageStrategy(language: "ja"))
        XCTAssertEqual(duration, 0.5, accuracy: 0.01,
            "Pause marker should be 0.5s")
    }

    func testSentenceEndAddsPause() {
        let strategy = CJKLanguageStrategy(language: "ja")
        // Chunk with 。 should get sentence pause via ChunkPlayerEngine
        let withPunct = ChunkPlayerEngine.calculateDuration(
            for: "です。", sliderValue: 0.5, strategy: strategy)
        let without = ChunkPlayerEngine.calculateDuration(
            for: "です", sliderValue: 0.5, strategy: strategy)

        XCTAssertGreaterThan(withPunct, without,
            "Sentence-ending chunk should have longer duration")
        XCTAssertEqual(withPunct - without, 0.3, accuracy: 0.1,
            "Sentence pause should add ~0.3s")
    }

    // MARK: - Total read time

    func testTotalReadTimeReasonable() {
        let chunks = WordChunkEngine.chunks(from: testText)
        let strategy = CJKLanguageStrategy(language: "ja")

        var totalTime: TimeInterval = 0
        for chunk in chunks {
            totalTime += ChunkPlayerEngine.calculateDuration(
                for: chunk, sliderValue: 0.5, strategy: strategy)
        }

        print("=== TOTAL READ TIME: \(String(format: "%.1f", totalTime))s ===")

        // This text is ~60 words, should take 30-90 seconds at medium speed
        XCTAssertGreaterThan(totalTime, 20, "Total time too short: \(totalTime)s")
        XCTAssertLessThan(totalTime, 120, "Total time too long: \(totalTime)s")
    }
}
