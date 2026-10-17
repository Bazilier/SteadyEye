import XCTest
@testable import PromptFlow

final class SubtitlesTests: XCTestCase {

    private func heard(_ text: String, start: Double = 0, step: Double = 0.4) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            TimedWord(text: String(word), start: start + Double(index) * step, end: start + Double(index) * step + 0.3)
        }
    }

    // MARK: - Script words

    func testScriptWordsDropMarkers() {
        XCTAssertEqual(SubtitleAligner.scriptWords("Hi // there. /// {1.5} Next\n////\nPart"),
                       ["Hi", "there.", "Next", "Part"])
    }

    // MARK: - Alignment

    func testScriptSpellingWins() {
        let out = SubtitleAligner.align(heard: heard("hi im cyril from steady eye"),
                                        script: SubtitleAligner.scriptWords("Hi, I'm Cyril from Steady Eye."))
        XCTAssertEqual(out.map(\.text), ["Hi,", "I'm", "Cyril", "from", "Steady", "Eye."])
    }

    func testNearMissMatches() {
        let out = SubtitleAligner.align(heard: heard("the teleprompters work"),
                                        script: ["The", "teleprompter's", "work."])
        XCTAssertEqual(out.map(\.text), ["The", "teleprompter's", "work."])
    }

    func testAdLibStaysAsHeard() {
        let out = SubtitleAligner.align(heard: heard("so um today we start"),
                                        script: ["So", "today", "we", "start."])
        XCTAssertEqual(out.map(\.text), ["So", "um", "today", "we", "start."])
    }

    func testTimesAreKept() {
        let words = heard("one two", start: 3)
        let out = SubtitleAligner.align(heard: words, script: ["One,", "two."])
        XCTAssertEqual(out.map(\.start), words.map(\.start))
    }

    func testMisheardStretchTakesScriptWords() {
        let out = SubtitleAligner.align(heard: heard("of the subtitles and study I"),
                                        script: ["of", "the", "subtitles", "in", "SteadyEye."])
        XCTAssertEqual(out.map(\.text), ["of", "the", "subtitles", "in", "SteadyEye."])
        XCTAssertEqual(out.last!.end, heard("of the subtitles and study I").last!.end, accuracy: 0.001)
    }

    func testDigitsTakeTheScriptsWords() {
        let out = SubtitleAligner.align(heard: heard("встречаемся в 20:00 у входа"),
                                        script: ["Встречаемся", "в", "двадцать", "часов", "у", "входа."])
        XCTAssertEqual(out.map(\.text), ["Встречаемся", "в", "двадцать", "часов", "у", "входа."])
    }

    func testDigitsInTheScriptStay() {
        let out = SubtitleAligner.align(heard: heard("at 8 pm"), script: ["At", "8", "pm."])
        XCTAssertEqual(out.map(\.text), ["At", "8", "pm."])
    }

    func testLongAdLibIsNotReplaced() {
        // Five words said where two were written: too long to be a slip.
        let out = SubtitleAligner.align(heard: heard("start well you know what I mean end"),
                                        script: ["Start", "skip", "this", "end."])
        XCTAssertEqual(out.map(\.text), ["Start", "well", "you", "know", "what", "I", "mean", "end."])
    }

    func testRetakeMatchesOneReading() {
        // The section read twice: one reading takes the script's spelling,
        // the other stays as heard; the cut keeps one of them anyway.
        let out = SubtitleAligner.align(heard: heard("hello world hello world"), script: ["Hello,", "world!"])
        XCTAssertEqual(out.filter { $0.text == "Hello," }.count, 1)
        XCTAssertEqual(out.count, 4)
    }

    // MARK: - Phrases

    func testBreaksAtSentenceEnd() {
        let words = heard("One two. Three four")
        let phrases = SubtitlePhrases.phrases(words: words, keep: nil)
        XCTAssertEqual(phrases.map(\.text), ["One two.", "Three four"])
    }

    func testBreaksAtMaxWords() {
        let words = heard("a b c d e f g")
        let phrases = SubtitlePhrases.phrases(words: words, keep: nil)
        XCTAssertEqual(phrases.map(\.text), ["a b c d e", "f g"])
    }

    func testBreaksAtPause() {
        var words = heard("one two")
        words += heard("three", start: 2)
        XCTAssertEqual(SubtitlePhrases.phrases(words: words, keep: nil).map(\.text), ["one two", "three"])
    }

    func testCutDropsWordsAndShiftsTimes() {
        // Kept 0–1 and 3–4; "lost" at 2 is cut away.
        let words = [
            TimedWord(text: "first", start: 0.1, end: 0.5),
            TimedWord(text: "lost", start: 2.0, end: 2.4),
            TimedWord(text: "second", start: 3.2, end: 3.6),
        ]
        let phrases = SubtitlePhrases.phrases(words: words, keep: [0...1, 3...4])
        XCTAssertEqual(phrases.map(\.text), ["first", "second"])
        XCTAssertEqual(phrases[1].start, 1.2, accuracy: 0.001)
    }

    func testCaptionsDoNotOverlap() {
        let phrases = SubtitlePhrases.phrases(words: heard("a b c d e f g h", step: 0.3), keep: nil)
        for (x, y) in zip(phrases, phrases.dropFirst()) {
            XCTAssertLessThanOrEqual(x.end, y.start)
        }
    }

    func testPhraseLookup() {
        let phrases = [SubtitlePhrase(text: "a", start: 0, end: 1), SubtitlePhrase(text: "b", start: 1.5, end: 2)]
        XCTAssertEqual(SubtitlePhrases.phrase(at: 0.5, in: phrases)?.text, "a")
        XCTAssertNil(SubtitlePhrases.phrase(at: 1.2, in: phrases))
        XCTAssertEqual(SubtitlePhrases.phrase(at: 1.7, in: phrases)?.text, "b")
    }
}
