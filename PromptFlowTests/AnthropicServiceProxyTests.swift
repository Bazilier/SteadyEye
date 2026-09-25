import XCTest
@testable import PromptFlow

/// URLProtocol stub. `AnthropicService.session` is swapped for a session whose
/// configuration installs this class, so no request ever leaves the process.
final class ProxyStubURLProtocol: URLProtocol {
    /// Set per test: returns (status, body) for the request being made.
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    /// The last request the stub saw, including its body (which URLProtocol
    /// strips from `httpBody`, so it is read off the stream here).
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.readStream)

        let (status, data) = Self.handler?(request) ?? (200, Data())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class AnthropicServiceProxyTests: XCTestCase {

    private var originalSession: URLSession!

    override func setUp() {
        super.setUp()
        originalSession = AnthropicService.session

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProxyStubURLProtocol.self]
        AnthropicService.session = URLSession(configuration: config)

        ProxyStubURLProtocol.handler = nil
        ProxyStubURLProtocol.lastRequest = nil
        ProxyStubURLProtocol.lastBody = nil
    }

    override func tearDown() {
        AnthropicService.session = originalSession
        ProxyStubURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func respond(_ status: Int, _ json: String) {
        ProxyStubURLProtocol.handler = { _ in (status, Data(json.utf8)) }
    }

    private func respondRaw(_ status: Int, _ body: String) {
        ProxyStubURLProtocol.handler = { _ in (status, Data(body.utf8)) }
    }

    /// Runs `body`, expecting it to throw a `ServiceError`, and returns it.
    private func captureServiceError(
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> AnthropicService.ServiceError? {
        do {
            try await body()
            XCTFail("Expected a ServiceError, call succeeded", file: file, line: line)
            return nil
        } catch let error as AnthropicService.ServiceError {
            return error
        } catch {
            XCTFail("Expected a ServiceError, got \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - Success paths

    func testOptimizeReturnsTrimmedTextAndSendsTheRightRequest() async throws {
        respond(200, #"{"text": "  Optimized body.  ", "remaining_free": 0}"#)

        let result = try await AnthropicService.optimizeForReading("raw script")

        XCTAssertEqual(result, "Optimized body.")

        let request = try XCTUnwrap(ProxyStubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://web-production-49244.up.railway.app/api/v1/ai/optimize/"
        )
        XCTAssertTrue(request.url!.absoluteString.hasSuffix("/ai/optimize/"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let userId = try XCTUnwrap(request.value(forHTTPHeaderField: "X-App-User-Id"))
        XCTAssertFalse(userId.isEmpty)

        // The key must be gone from the client entirely.
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-version"))

        // Body is exactly {"text": ...} — no model, max_tokens, system or messages.
        let body = try XCTUnwrap(ProxyStubURLProtocol.lastBody)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(json["text"] as? String, "raw script")
    }

    func testSplitReturnsParsedScriptsAndHitsTheSplitPath() async throws {
        respond(200, #"""
        {"text": "[{\"title\":\"One\",\"content\":\"First\"},{\"title\":\"Two\",\"content\":\"Second\"}]", "remaining_free": null}
        """#)

        let scripts = try await AnthropicService.splitScripts("a document")

        XCTAssertEqual(scripts.count, 2)
        XCTAssertEqual(scripts[0].title, "One")
        XCTAssertEqual(scripts[0].content, "First")
        XCTAssertEqual(scripts[1].title, "Two")

        let request = try XCTUnwrap(ProxyStubURLProtocol.lastRequest)
        XCTAssertTrue(request.url!.absoluteString.hasSuffix("/ai/split/"))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
    }

    func testAppUserIdHeaderIsStableAcrossCalls() async throws {
        respond(200, #"{"text": "ok"}"#)

        _ = try await AnthropicService.optimizeForReading("one")
        let first = ProxyStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-App-User-Id")

        _ = try await AnthropicService.optimizeForReading("two")
        let second = ProxyStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-App-User-Id")

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    // MARK: - Error mapping

    func testFreeQuotaExhaustedMapsToServiceError() async {
        respond(403, #"{"error": "free_quota_exhausted"}"#)

        let error = await captureServiceError {
            _ = try await AnthropicService.optimizeForReading("text")
        }

        guard case .freeQuotaExhausted = error else {
            return XCTFail("Expected .freeQuotaExhausted, got \(String(describing: error))")
        }
    }

    func testSubscriptionRequiredMapsToServiceError() async {
        respond(403, #"{"error": "subscription_required"}"#)

        let error = await captureServiceError {
            _ = try await AnthropicService.splitScripts("text")
        }

        guard case .subscriptionRequired = error else {
            return XCTFail("Expected .subscriptionRequired, got \(String(describing: error))")
        }
    }

    func testRateLimitedMapsToServiceError() async {
        respond(429, #"{"error": "rate_limited"}"#)

        let error = await captureServiceError {
            _ = try await AnthropicService.optimizeForReading("text")
        }

        guard case .rateLimited = error else {
            return XCTFail("Expected .rateLimited, got \(String(describing: error))")
        }
    }

    func testAIDisabledMapsToServiceError() async {
        respond(503, #"{"error": "ai_disabled"}"#)

        let error = await captureServiceError {
            _ = try await AnthropicService.optimizeForReading("text")
        }

        guard case .aiDisabled = error else {
            return XCTFail("Expected .aiDisabled, got \(String(describing: error))")
        }
    }

    func testInputTooLongCarriesMaxChars() async {
        respond(413, #"{"error": "input_too_long", "max_chars": 18000}"#)

        let error = await captureServiceError {
            _ = try await AnthropicService.splitScripts("text")
        }

        guard case .inputTooLong(let maxChars) = error else {
            return XCTFail("Expected .inputTooLong, got \(String(describing: error))")
        }
        XCTAssertEqual(maxChars, 18000)
    }

    func testNonJSONErrorBodyFallsBackToHTTPError() async {
        respondRaw(500, "<html>502 Bad Gateway</html>")

        let error = await captureServiceError {
            _ = try await AnthropicService.optimizeForReading("text")
        }

        guard case .httpError(let code) = error else {
            return XCTFail("Expected .httpError, got \(String(describing: error))")
        }
        XCTAssertEqual(code, 500)
    }

    func testUnknownErrorCodeFallsBackToHTTPError() async {
        respond(418, #"{"error": "some_future_code"}"#)

        let error = await captureServiceError {
            _ = try await AnthropicService.optimizeForReading("text")
        }

        guard case .httpError(let code) = error else {
            return XCTFail("Expected .httpError, got \(String(describing: error))")
        }
        XCTAssertEqual(code, 418)
    }

    func testUpstreamErrorFallsBackToHTTPError() async {
        respond(502, #"{"error": "upstream_error"}"#)

        let error = await captureServiceError {
            _ = try await AnthropicService.optimizeForReading("text")
        }

        guard case .httpError(let code) = error else {
            return XCTFail("Expected .httpError, got \(String(describing: error))")
        }
        XCTAssertEqual(code, 502)
    }

    // MARK: - Response shape

    func testMissingTextFieldIsADecodingError() async {
        respond(200, #"{"remaining_free": 2}"#)

        let error = await captureServiceError {
            _ = try await AnthropicService.optimizeForReading("text")
        }

        guard case .decodingError = error else {
            return XCTFail("Expected .decodingError, got \(String(describing: error))")
        }
    }

    func testWhitespaceOnlyTextIsAnEmptyResponse() async {
        respond(200, #"{"text": "   \n  "}"#)

        let error = await captureServiceError {
            _ = try await AnthropicService.optimizeForReading("text")
        }

        guard case .emptyResponse = error else {
            return XCTFail("Expected .emptyResponse, got \(String(describing: error))")
        }
    }

    func testSplitWithUnparsableModelTextReturnsEmptyArray() async throws {
        // parseScriptsJSON swallows bad payloads by design; the caller shows
        // "No scripts found in the text."
        respond(200, #"{"text": "not json at all"}"#)

        let scripts = try await AnthropicService.splitScripts("text")
        XCTAssertTrue(scripts.isEmpty)
    }
}
