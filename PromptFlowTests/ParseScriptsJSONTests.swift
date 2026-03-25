import XCTest
@testable import PromptFlow

final class ParseScriptsJSONTests: XCTestCase {

    // MARK: - Valid JSON

    func testValidJSONArray() {
        let json = """
        [{"title":"Script One","content":"Hello world"},{"title":"Script Two","content":"Goodbye world"}]
        """
        let result = AnthropicService.parseScriptsJSON(json)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].title, "Script One")
        XCTAssertEqual(result[0].content, "Hello world")
        XCTAssertEqual(result[1].title, "Script Two")
        XCTAssertEqual(result[1].content, "Goodbye world")
    }

    func testSingleScript() {
        let json = """
        [{"title":"Solo","content":"Just one script"}]
        """
        let result = AnthropicService.parseScriptsJSON(json)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "Solo")
    }

    // MARK: - Markdown-wrapped JSON

    func testMarkdownCodeFence() {
        let json = """
        ```json
        [{"title":"Test","content":"Content here"}]
        ```
        """
        let result = AnthropicService.parseScriptsJSON(json)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "Test")
    }

    func testMarkdownCodeFenceNoLanguage() {
        let json = """
        ```
        [{"title":"Test","content":"Content"}]
        ```
        """
        let result = AnthropicService.parseScriptsJSON(json)
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - JSON with surrounding text

    func testJSONWithPreamble() {
        let json = """
        Here are the scripts I found:
        [{"title":"Found","content":"Some text"}]
        """
        let result = AnthropicService.parseScriptsJSON(json)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "Found")
    }

    func testJSONWithTrailingText() {
        let json = """
        [{"title":"Test","content":"Hello"}]
        I hope this helps!
        """
        let result = AnthropicService.parseScriptsJSON(json)
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Empty / invalid

    func testEmptyString() {
        let result = AnthropicService.parseScriptsJSON("")
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyArray() {
        let result = AnthropicService.parseScriptsJSON("[]")
        XCTAssertTrue(result.isEmpty)
    }

    func testInvalidJSON() {
        let result = AnthropicService.parseScriptsJSON("not json at all")
        XCTAssertTrue(result.isEmpty)
    }

    func testMalformedJSON() {
        let result = AnthropicService.parseScriptsJSON("[{broken")
        XCTAssertTrue(result.isEmpty)
    }

    func testJSONObject() {
        // Object instead of array
        let result = AnthropicService.parseScriptsJSON("""
        {"title":"Not an array","content":"Oops"}
        """)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Empty content filtering

    func testEmptyContentFiltered() {
        let json = """
        [{"title":"Has Content","content":"Real text"},{"title":"Empty","content":""},{"title":"Whitespace","content":"   "}]
        """
        let result = AnthropicService.parseScriptsJSON(json)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "Has Content")
    }

    // MARK: - Unicode content

    func testUnicodeContent() {
        let json = """
        [{"title":"Arabic","content":"مرحبا بكم"},{"title":"Japanese","content":"こんにちは"}]
        """
        let result = AnthropicService.parseScriptsJSON(json)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].content, "مرحبا بكم")
        XCTAssertEqual(result[1].content, "こんにちは")
    }

    // MARK: - Whitespace handling

    func testWhitespaceAroundJSON() {
        let json = """

          [{"title":"Padded","content":"Text"}]

        """
        let result = AnthropicService.parseScriptsJSON(json)
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Large response

    func testManyScripts() {
        var items: [String] = []
        for i in 0..<20 {
            items.append("""
            {"title":"Script \(i)","content":"Content for script \(i)"}
            """)
        }
        let json = "[" + items.joined(separator: ",") + "]"
        let result = AnthropicService.parseScriptsJSON(json)
        XCTAssertEqual(result.count, 20)
    }
}
