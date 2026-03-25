import XCTest
@testable import PromptFlow

final class ScriptFormatterTests: XCTestCase {

    // MARK: - Empty / trivial input

    func testEmptyString() {
        XCTAssertEqual(ScriptFormatter.cleanUp(""), "")
    }

    func testWhitespaceOnly() {
        XCTAssertEqual(ScriptFormatter.cleanUp("   \n\n  "), "")
    }

    func testPlainText() {
        XCTAssertEqual(ScriptFormatter.cleanUp("Hello world"), "Hello world")
    }

    // MARK: - Dash removal

    func testEmDashRemoved() {
        let result = ScriptFormatter.cleanUp("Hello—world")
        XCTAssertFalse(result.contains("—"))
        XCTAssertTrue(result.contains("Hello"))
        XCTAssertTrue(result.contains("world"))
    }

    func testEnDashRemoved() {
        let result = ScriptFormatter.cleanUp("Hello–world")
        XCTAssertFalse(result.contains("–"))
    }

    func testPunctuationDashRemoved() {
        let result = ScriptFormatter.cleanUp("Hello - world")
        XCTAssertFalse(result.contains(" - "))
    }

    // MARK: - Bracket removal

    func testSquareBracketsRemoved() {
        let result = ScriptFormatter.cleanUp("Hello [note] world")
        XCTAssertFalse(result.contains("["))
        XCTAssertFalse(result.contains("]"))
        XCTAssertFalse(result.contains("note"))
    }

    func testParenthesesRemoved() {
        let result = ScriptFormatter.cleanUp("Hello (aside) world")
        XCTAssertFalse(result.contains("("))
        XCTAssertFalse(result.contains(")"))
    }

    func testAngleBracketsRemoved() {
        let result = ScriptFormatter.cleanUp("Hello <tag> world")
        XCTAssertFalse(result.contains("<"))
        XCTAssertFalse(result.contains(">"))
    }

    func testStrayBracketsRemoved() {
        let result = ScriptFormatter.cleanUp("Hello [ world ] test")
        XCTAssertFalse(result.contains("["))
        XCTAssertFalse(result.contains("]"))
    }

    // MARK: - Special characters

    func testBulletRemoved() {
        let result = ScriptFormatter.cleanUp("• Item one")
        XCTAssertFalse(result.contains("•"))
        XCTAssertTrue(result.contains("Item"))
    }

    func testAsteriskRemoved() {
        let result = ScriptFormatter.cleanUp("**bold** text")
        XCTAssertFalse(result.contains("*"))
    }

    func testHashtagRemoved() {
        let result = ScriptFormatter.cleanUp("#trending topic")
        XCTAssertFalse(result.contains("#"))
    }

    // MARK: - Paragraph preservation

    func testDoubleNewlinePreserved() {
        let result = ScriptFormatter.cleanUp("Line one.\n\nLine two.")
        XCTAssertTrue(result.contains("\n\n"))
        XCTAssertTrue(result.contains("Line one."))
        XCTAssertTrue(result.contains("Line two."))
    }

    func testSingleNewlineCollapsed() {
        let result = ScriptFormatter.cleanUp("Line one.\nLine two.")
        // Single newline within a paragraph should be collapsed to space
        XCTAssertFalse(result.contains("\n") && !result.contains("\n\n"))
    }

    // MARK: - Whitespace normalization

    func testMultipleSpacesCollapsed() {
        let result = ScriptFormatter.cleanUp("Hello    world")
        XCTAssertFalse(result.contains("  "))
    }

    func testLeadingTrailingWhitespace() {
        let result = ScriptFormatter.cleanUp("  Hello world  ")
        XCTAssertEqual(result, "Hello world")
    }

    // MARK: - Complex input

    func testComplexCleanup() {
        let input = """
        • First point [visual cue]

        Hello—everyone, this is **important**.

        Check (the details) at #website.
        """
        let result = ScriptFormatter.cleanUp(input)
        XCTAssertFalse(result.contains("•"))
        XCTAssertFalse(result.contains("["))
        XCTAssertFalse(result.contains("—"))
        XCTAssertFalse(result.contains("*"))
        XCTAssertFalse(result.contains("#"))
        XCTAssertTrue(result.contains("First"))
        XCTAssertTrue(result.contains("important"))
    }
}
