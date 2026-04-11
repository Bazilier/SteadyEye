import XCTest
@testable import PromptFlow

final class WordSplittingTests: XCTestCase {

    // MARK: - Group 1: orpIndex

    func testOrpIndexShortWords() {
        XCTAssertEqual(orpIndex(for: "a"), 0)
        XCTAssertEqual(orpIndex(for: "I"), 0)
        XCTAssertEqual(orpIndex(for: "hi"), 1)
        XCTAssertEqual(orpIndex(for: "to"), 1)
        XCTAssertEqual(orpIndex(for: "hello"), 1)
        XCTAssertEqual(orpIndex(for: "wonder"), 2)
        XCTAssertEqual(orpIndex(for: "amazing"), 2)
        XCTAssertEqual(orpIndex(for: "incredible"), 3)
        XCTAssertEqual(orpIndex(for: "responsibility"), 4)
    }

    func testOrpIndexWithPunctuation() {
        // Trailing punctuation is stripped before computing the index,
        // so the punctuated and bare versions match.
        XCTAssertEqual(orpIndex(for: "hello,"), orpIndex(for: "hello"))
        XCTAssertEqual(orpIndex(for: "world."), orpIndex(for: "world"))
        XCTAssertEqual(orpIndex(for: "wow!"),    orpIndex(for: "wow"))
        XCTAssertEqual(orpIndex(for: "really?"), orpIndex(for: "really"))
    }

    func testOrpIndexEdgeCases() {
        XCTAssertEqual(orpIndex(for: ""), 0)
        XCTAssertEqual(orpIndex(for: "x"), 0)
    }

    // MARK: - Group 2: hyphenationPoints (system dictionary smoke tests)

    func testHyphenationEnglish() {
        let p1 = hyphenationPoints(for: "responsibility", locale: Locale(identifier: "en_US"))
        XCTAssertFalse(p1.isEmpty, "English hyphenation returned no points for 'responsibility'")

        let p2 = hyphenationPoints(for: "extraordinarily", locale: Locale(identifier: "en_US"))
        XCTAssertFalse(p2.isEmpty, "English hyphenation returned no points for 'extraordinarily'")
        // 'the' is intentionally not asserted (too short for reliable hyphenation).
    }

    func testHyphenationRussian() {
        let p1 = hyphenationPoints(for: "тестирование", locale: Locale(identifier: "ru_RU"))
        XCTAssertFalse(p1.isEmpty, "Russian hyphenation returned no points for 'тестирование'")

        let p2 = hyphenationPoints(for: "превосходительство", locale: Locale(identifier: "ru_RU"))
        XCTAssertFalse(p2.isEmpty, "Russian hyphenation returned no points for 'превосходительство'")
    }

    func testHyphenationSpanish() {
        let words = ["extraordinario", "presentación", "fundamental", "completamente"]
        for word in words {
            let points = hyphenationPoints(for: word, locale: Locale(identifier: "es_ES"))
            XCTAssertFalse(
                points.isEmpty,
                "CRITICAL: Spanish hyphenation returned no points for '\(word)'. " +
                "Apple's es_ES dictionary may be missing or broken."
            )
        }
    }

    func testHyphenationPortuguese() {
        let words = ["extraordinário", "apresentação", "fundamentalmente", "completamente"]
        for word in words {
            let points = hyphenationPoints(for: word, locale: Locale(identifier: "pt_PT"))
            XCTAssertFalse(
                points.isEmpty,
                "CRITICAL: Portuguese hyphenation returned no points for '\(word)'. " +
                "Apple's pt_PT dictionary may be missing or broken."
            )
        }
    }

    // MARK: - Critical canary tests

    func testCriticalSpanishHyphenationAvailable() {
        let points = hyphenationPoints(for: "extraordinario", locale: Locale(identifier: "es_ES"))
        XCTAssertFalse(
            points.isEmpty,
            """
            CRITICAL: Apple Spanish hyphenation returned no points for 'extraordinario'.
            This means Spanish ORP support is broken on this iOS version.
            Either Apple removed the dictionary, or the locale identifier changed.
            Check CFStringGetHyphenationLocationBeforeIndex documentation.
            """
        )
    }

    func testCriticalPortugueseHyphenationAvailable() {
        let points = hyphenationPoints(for: "extraordinário", locale: Locale(identifier: "pt_PT"))
        XCTAssertFalse(
            points.isEmpty,
            """
            CRITICAL: Apple Portuguese hyphenation returned no points for 'extraordinário'.
            This means Portuguese ORP support is broken on this iOS version.
            """
        )
    }

    // MARK: - Group 3: splitLongWord invariants per language

    func testSplitLongWordInvariantsEnglish() {
        let words = [
            "teleprompter", "responsibility", "extraordinarily",
            "straightforward", "untrustworthy", "unprofessional",
            "uninterrupted", "frameworks", "immediately"
        ]
        for word in words {
            let parts = splitLongWord(word, threshold: 10, locale: Locale(identifier: "en_US"))
            assertSplitInvariants(word: word, parts: parts)
        }
    }

    func testSplitLongWordInvariantsSpanish() {
        let words = [
            "extraordinario", "presentación", "fundamental",
            "tradicionales", "inmediatamente", "completamente",
            "posicionada", "directamente", "profesionales"
        ]
        for word in words {
            let parts = splitLongWord(word, threshold: 10, locale: Locale(identifier: "es_ES"))
            assertSplitInvariants(word: word, parts: parts)
        }
    }

    func testSplitLongWordInvariantsPortuguese() {
        let words = [
            "extraordinário", "apresentação", "fundamentalmente",
            "tradicionais", "imediatamente", "completamente",
            "posicionada", "diretamente", "profissionais"
        ]
        for word in words {
            let parts = splitLongWord(word, threshold: 10, locale: Locale(identifier: "pt_PT"))
            assertSplitInvariants(word: word, parts: parts)
        }
    }

    func testSplitLongWordInvariantsRussian() {
        let words = [
            "тестирование", "превосходительство", "необыкновенное",
            "последовательного", "фундаментальная", "непрофессионально",
            "предпринимателей", "непосредственно"
        ]
        for word in words {
            let parts = splitLongWord(word, threshold: 10, locale: Locale(identifier: "ru_RU"))
            assertSplitInvariants(word: word, parts: parts)
        }
    }

    // MARK: - Group 4: hyphen-splitting (compound words)

    func testHyphenSplitting() {
        // All segments here are ≤ 8 chars, so they hit the short-circuit and
        // each becomes a single chunk; parts.joined() reconstructs the original.
        let cases: [(input: String, minParts: Int)] = [
            ("word-by-word", 3),
            ("state-of-the-art", 4),
            ("talking-head", 2)
        ]
        for c in cases {
            let parts = splitLongWord(c.input, threshold: 10, locale: Locale(identifier: "en_US"))
            XCTAssertGreaterThanOrEqual(parts.count, c.minParts,
                "'\(c.input)' should split into at least \(c.minParts) parts, got \(parts)")
            let rejoined = parts.joined()
            XCTAssertEqual(rejoined, c.input,
                "Hyphen-split parts don't rejoin to original: \(parts) → '\(rejoined)' ≠ '\(c.input)'")
        }
    }

    // MARK: - Group 5: enforceBudget

    func testEnforceBudgetWithinLimit() {
        // "hello" → orpIndex 1 → suffix "ello" = 4 chars ≤ 5 → unchanged
        let result = enforceBudget("hello", rightBudget: 5)
        XCTAssertEqual(result, ["hello"])
    }

    func testEnforceBudgetOverLimit() {
        // "telephone" (9 chars) → anchor 2 → suffix length 7 > budget 6 → must split.
        let result = enforceBudget("telephone", rightBudget: 6)
        XCTAssertGreaterThan(result.count, 1, "Long syllable should be force-split")

        // Each emitted part's anchor-to-end span must fit the budget.
        for part in result {
            let anchor = orpIndex(for: part)
            let suffixLen = part.count - anchor
            XCTAssertLessThanOrEqual(suffixLen, 6,
                "Part '\(part)' has suffix length \(suffixLen) > budget 6")
        }
        // Joining parts (stripping continuation hyphens) gives back the original.
        let rejoined = result.map { $0.hasSuffix("-") ? String($0.dropLast()) : $0 }.joined()
        XCTAssertEqual(rejoined, "telephone")
    }

    func testEnforceBudgetMinSyllableLength() {
        // Result should never contain a part with clean length < 3,
        // unless the input itself was that short.
        let inputs = ["frameworks", "telepromp-", "abcdefghijkl", "responsibility"]
        for input in inputs {
            let result = enforceBudget(input, rightBudget: 6)
            for part in result {
                let cleanLen = part.trimmingCharacters(in: CharacterSet(charactersIn: "-,.!?;:")).count
                let inputCleanLen = input.trimmingCharacters(in: CharacterSet(charactersIn: "-,.!?;:")).count
                if inputCleanLen >= 3 {
                    XCTAssertGreaterThanOrEqual(cleanLen, 3,
                        "Part '\(part)' has clean length \(cleanLen) < 3 (from input '\(input)')")
                }
            }
        }
    }

    // MARK: - Group 6: mergeShortTail

    func testMergeShortTailMergesSingleLetter() {
        XCTAssertEqual(
            mergeShortTail(["framew-", "ork-", "s"]),
            ["framew-", "orks"]
        )
        XCTAssertEqual(
            mergeShortTail(["tele-", "promp-", "y"]),
            ["tele-", "prompy"]
        )
    }

    func testMergeShortTailNoMergeWhenOk() {
        XCTAssertEqual(
            mergeShortTail(["responsi-", "bility"]),
            ["responsi-", "bility"]
        )
    }

    func testMergeShortTailHandlesSinglePart() {
        XCTAssertEqual(mergeShortTail(["word"]), ["word"])
        let empty: [String] = []
        XCTAssertEqual(mergeShortTail(empty), empty)
    }

    func testMergeShortTailRepeatsUntilStable() {
        // Two short tails in a row should both merge.
        // ["aa-", "bb-", "c", "d"] → ["aa-", "bb-", "cd"] is still 2 chars → merge again
        // → ["aa-", "bbcd"] (4 clean chars, OK)
        let result = mergeShortTail(["aa-", "bb-", "c", "d"])
        // Verify it doesn't crash and final tail is at least the cumulative leftover.
        let last = result.last ?? ""
        let lastClean = last.trimmingCharacters(in: CharacterSet(charactersIn: "-,.!?;:"))
        // After all merging, only the very first part ("aa-") could remain "short"
        // but mergeShortTail only operates on the tail, so "aa-" stays.
        XCTAssertGreaterThanOrEqual(lastClean.count, 3,
            "After mergeShortTail, tail clean length should be ≥ 3, got '\(last)' in \(result)")
    }

    // MARK: - Group 7: chunksPerWord end-to-end

    func testChunksPerWordEnglishSentence() {
        let strategy = LatinLanguageStrategy()
        let chunks = strategy.chunksPerWord(
            text: "Hello world this is a test",
            baseSpeedMs: 300
        )
        XCTAssertFalse(chunks.isEmpty)
        // Six words; chunks should be at least six (some may be syllable-split).
        XCTAssertGreaterThanOrEqual(chunks.count, 6)
        // No nil/empty chunks (no pause markers in this text).
        for chunk in chunks {
            XCTAssertFalse(chunk.isEmpty, "Got an unexpected empty chunk")
        }
    }

    func testChunksPerWordSpanishSentence() {
        let strategy = LatinLanguageStrategy()
        let chunks = strategy.chunksPerWord(
            text: "Hola mundo esto es una prueba extraordinaria",
            baseSpeedMs: 300
        )
        XCTAssertFalse(chunks.isEmpty)
        // 7 input words; "extraordinaria" is long and should be syllable-split.
        XCTAssertGreaterThanOrEqual(chunks.count, 7)
        // The long word's pieces appear somewhere in the result.
        let joined = chunks.joined(separator: " ")
        XCTAssertTrue(
            joined.contains("extra") || joined.contains("ordi") || joined.contains("naria"),
            "Long Spanish word should appear (possibly split) in chunks: \(chunks)"
        )
    }

    func testChunksPerWordPortugueseSentence() {
        let strategy = LatinLanguageStrategy()
        let chunks = strategy.chunksPerWord(
            text: "Olá mundo isto é um teste extraordinário",
            baseSpeedMs: 300
        )
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertGreaterThanOrEqual(chunks.count, 7)
    }

    func testChunksPerWordPauseMarker() {
        let strategy = LatinLanguageStrategy()
        let chunks = strategy.chunksPerWord(
            text: "Hello // world",
            baseSpeedMs: 300
        )
        // The "//" token becomes an empty-string pause chunk.
        XCTAssertTrue(chunks.contains(""), "Expected an empty pause chunk, got: \(chunks)")
    }

    func testChunksPerWordPunctuationDuration() {
        let strategy = LatinLanguageStrategy()
        let plain  = strategy.durationPerWord(chunk: "hello",  baseSpeedMs: 300)
        let comma  = strategy.durationPerWord(chunk: "hello,", baseSpeedMs: 300)
        let period = strategy.durationPerWord(chunk: "hello.", baseSpeedMs: 300)

        XCTAssertGreaterThan(comma, plain, "Comma should add bonus over plain word")
        XCTAssertGreaterThan(period, comma, "Period should add more bonus than comma")
    }

    func testChunksPerWordContinuationHasPenalty() {
        let strategy = LatinLanguageStrategy()
        let plain        = strategy.durationPerWord(chunk: "respon",  baseSpeedMs: 300)
        let continuation = strategy.durationPerWord(chunk: "respon-", baseSpeedMs: 300)
        XCTAssertGreaterThan(continuation, plain,
            "Continuation syllable (trailing -) should have a longer duration than the plain form")
    }

    // MARK: - Helper

    /// Verifies the invariants the splitting pipeline must always satisfy.
    private func assertSplitInvariants(
        word: String,
        parts: [String],
        file: StaticString = #file,
        line: UInt = #line
    ) {
        // 1. At least one part.
        XCTAssertFalse(parts.isEmpty,
            "splitLongWord returned empty for '\(word)'", file: file, line: line)

        // 2. Joining (stripping continuation hyphens) gives back the original word.
        let rejoined = parts.map { $0.hasSuffix("-") ? String($0.dropLast()) : $0 }.joined()
        XCTAssertEqual(rejoined, word,
            "Parts don't rejoin to original: \(parts) → '\(rejoined)' ≠ '\(word)'",
            file: file, line: line)

        // 3. All parts except the last end with a continuation hyphen.
        for (i, part) in parts.enumerated() where i < parts.count - 1 {
            XCTAssertTrue(part.hasSuffix("-"),
                "Non-final part missing hyphen: '\(part)' in \(parts)",
                file: file, line: line)
        }

        // 4. Last part does NOT end with a hyphen unless the original word did.
        if !word.hasSuffix("-") {
            XCTAssertFalse(parts.last?.hasSuffix("-") ?? false,
                "Final part has stray hyphen: \(parts)", file: file, line: line)
        }

        // 5. Every part contains at least one vowel (Latin + diacritics + Cyrillic).
        let vowelChars = "aeiouyAEIOUYáéíóúüâêôãõàÁÉÍÓÚÜÂÊÔÃÕÀаеёиоуыэюяАЕЁИОУЫЭЮЯ"
        let vowels = Set(vowelChars)
        for part in parts {
            let cleanPart = part.trimmingCharacters(in: CharacterSet(charactersIn: "-,.!?;:"))
            let hasVowel = cleanPart.contains { vowels.contains($0) }
            XCTAssertTrue(hasVowel,
                "Part has no vowels: '\(part)' in \(parts) for word '\(word)'",
                file: file, line: line)
        }

        // 6. No part is shorter than 2 clean characters (sanity floor).
        for part in parts {
            let cleanPart = part.trimmingCharacters(in: CharacterSet(charactersIn: "-,.!?;:"))
            XCTAssertGreaterThanOrEqual(cleanPart.count, 2,
                "Part too short: '\(part)' in \(parts)",
                file: file, line: line)
        }
    }
}
