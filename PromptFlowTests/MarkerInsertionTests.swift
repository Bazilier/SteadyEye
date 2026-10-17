import XCTest
@testable import PromptFlow

final class MarkerInsertionTests: XCTestCase {

    private func insert(_ marker: ScriptMarker, _ text: String, at offset: Int) -> (String, Int) {
        let index = text.index(text.startIndex, offsetBy: offset)
        let result = MarkerInsertion.insert(marker, into: text, replacing: index..<index)
        return (result.text, result.text.distance(from: result.text.startIndex, to: result.cursor))
    }

    func testPauseBetweenWordsGetsSpaces() {
        let (text, cursor) = insert(.shortPause, "one two", at: 3)
        XCTAssertEqual(text, "one // two")
        XCTAssertEqual(cursor, 6)
    }

    func testPauseAfterSpaceAddsNoDoubleSpace() {
        XCTAssertEqual(insert(.longPause, "one two", at: 4).0, "one /// two")
    }

    func testPauseInsideWordSplitsIt() {
        XCTAssertEqual(insert(.shortPause, "onetwo", at: 3).0, "one // two")
    }

    func testPauseAtEnd() {
        let (text, cursor) = insert(.shortPause, "one", at: 3)
        XCTAssertEqual(text, "one //")
        XCTAssertEqual(cursor, 6)
    }

    func testPauseInEmptyText() {
        XCTAssertEqual(insert(.shortPause, "", at: 0).0, "//")
    }

    func testSectionGetsItsOwnLine() {
        let (text, cursor) = insert(.section, "One. Two.", at: 5)
        XCTAssertEqual(text, "One. \n////\nTwo.")
        XCTAssertEqual(cursor, 11)
    }

    func testSectionAfterNewlineAddsNoBlankLine() {
        XCTAssertEqual(insert(.section, "One.\nTwo.", at: 5).0, "One.\n////\nTwo.")
    }

    func testSectionAtEndLeavesCursorOnNewLine() {
        let (text, cursor) = insert(.section, "One.", at: 4)
        XCTAssertEqual(text, "One.\n////\n")
        XCTAssertEqual(cursor, text.count)
    }

    func testReplacesSelection() {
        let text = "one two three"
        let range = text.index(text.startIndex, offsetBy: 4)..<text.index(text.startIndex, offsetBy: 7)
        XCTAssertEqual(MarkerInsertion.insert(.shortPause, into: text, replacing: range).text, "one // three")
    }

    func testInsertedSectionSplitsForThePrompter() {
        let text = insert(.section, "One. Two.", at: 5).0
        XCTAssertEqual(MarkerPreprocessor.splitSections(text).count, 2)
    }
}
