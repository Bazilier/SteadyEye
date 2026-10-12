import Foundation
import RevenueCat

struct ImportedScript: Decodable {
    let title: String
    let content: String
}

enum AnthropicService {

    /// Backend AI proxy. The Anthropic key lives on the server only — this app
    /// no longer ships one. Same hardcoded-constant pattern as `ChatService`.
    private static let baseURL = "https://web-production-49244.up.railway.app/api/v1/ai"

    /// Overridable so tests can install a `URLProtocol` stub. Production always
    /// uses `.shared`.
    static var session: URLSession = .shared

    enum ServiceError: LocalizedError {
        case missingAPIKey
        case networkError(Error)
        case httpError(Int)
        case decodingError
        case emptyResponse
        case subscriptionRequired
        case freeQuotaExhausted
        case rateLimited
        case aiDisabled
        case inputTooLong(maxChars: Int?)
        /// The model declined the topic (`/draft/` only).
        case cannotDraft

        // Developer-facing only. The user sees the wrapped message produced by
        // ScriptEditorView (`scripts.editor.error.formatFailed`) — these strings
        // are intentionally not localized.
        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "API key not configured."
            case .networkError(let e): return e.localizedDescription
            case .httpError(let code): return "Server returned status \(code)."
            case .decodingError: return "Could not parse response."
            case .emptyResponse: return "Empty response from API."
            case .subscriptionRequired: return "Subscription required for this feature."
            case .freeQuotaExhausted: return "Free quota exhausted."
            case .rateLimited: return "Rate limited. Try again later."
            case .aiDisabled: return "AI features are temporarily unavailable."
            case .cannotDraft: return "The model declined this topic."
            case .inputTooLong(let maxChars):
                if let maxChars {
                    return "Input too long (max \(maxChars) characters)."
                }
                return "Input too long."
            }
        }
    }

    private static let systemPrompt: String = loadPrompt("FormatPrompt")

    static func optimizeForReading(_ text: String) async throws -> String {
        let responseText = try await callProxy(path: "/optimize/", text: text)

        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServiceError.emptyResponse }
        return trimmed
    }

    // MARK: - Bulk script splitting

    private static let splitSystemPrompt: String = loadPrompt("SplitPrompt")

    static func splitScripts(_ text: String) async throws -> [ImportedScript] {
        let responseText = try await callProxy(path: "/split/", text: text)
        return parseScriptsJSON(responseText)
    }

    // MARK: - Script drafts

    /// Target length of a drafted script; the server maps it to a word count.
    enum DraftLength: Int, CaseIterable, Identifiable {
        case seconds15 = 15, seconds30 = 30, seconds60 = 60
        var id: Int { rawValue }
    }

    /// What the video is for. Raw values are the server's closed enum.
    enum DraftKind: String, CaseIterable, Identifiable {
        case short, youtube, sales, lesson, other
        var id: String { rawValue }
    }

    /// Drafts a script to read aloud from a one-line topic, in the topic's
    /// language (the app's language when the topic does not tell).
    static func draftScript(
        topic: String,
        length: DraftLength,
        kind: DraftKind
    ) async throws -> String {
        let responseText = try await callProxy(
            path: "/draft/",
            text: topic,
            extra: ["length_sec": length.rawValue, "kind": kind.rawValue],
            language: Bundle.main.preferredLocalizations.first
        )
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServiceError.emptyResponse }
        return trimmed
    }

    // MARK: - Proxy transport

    /// POSTs `{"text": ...}` to the backend proxy and returns the `text` field
    /// of a 200 response. The model, system prompt and token limits are fixed
    /// server-side — this client sends the script and nothing else, plus the
    /// closed-enum options `/draft/` takes.
    private static func callProxy(
        path: String,
        text: String,
        extra: [String: Any] = [:],
        language: String? = nil
    ) async throws -> String {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 100
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appUserId(), forHTTPHeaderField: "X-App-User-Id")
        if let language {
            request.setValue(language, forHTTPHeaderField: "Accept-Language")
        }

        var body: [String: Any] = ["text": text]
        body.merge(extra) { _, new in new }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServiceError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.decodingError
        }
        guard http.statusCode == 200 else {
            throw proxyError(status: http.statusCode, data: data)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["text"] as? String
        else {
            throw ServiceError.decodingError
        }
        // `remaining_free` is present for free users on /optimize/; the client
        // keeps its own gating, so it is deliberately ignored.
        return responseText
    }

    /// Maps the proxy's `{"error": "<code>"}` body onto a `ServiceError`.
    /// An unrecognised or unparsable body falls back to `.httpError`, so a new
    /// server-side code degrades to the existing generic failure path.
    private static func proxyError(status: Int, data: Data) -> ServiceError {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["error"] as? String
        else {
            return .httpError(status)
        }

        switch code {
        case "subscription_required": return .subscriptionRequired
        case "free_quota_exhausted":  return .freeQuotaExhausted
        case "rate_limited":          return .rateLimited
        case "ai_disabled":           return .aiDisabled
        case "input_too_long":        return .inputTooLong(maxChars: json["max_chars"] as? Int)
        case "cannot_draft":          return .cannotDraft
        default:                      return .httpError(status)
        }
    }

    /// Identity the proxy checks against RevenueCat. Release builds use the RC
    /// appUserID; DEV builds never call `Purchases.configure`, and touching
    /// `Purchases.shared` there is a fatal error, so they fall back to a
    /// persistent local UUID.
    private static func appUserId() -> String {
        if Purchases.isConfigured {
            return Purchases.shared.appUserID
        }
        let key = "aiProxyFallbackUserId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    /// Parses JSON array from the API response, handling markdown fences and edge cases.
    static func parseScriptsJSON(_ text: String) -> [ImportedScript] {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences if present
        if cleaned.hasPrefix("```") {
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try to find JSON array boundaries
        if let start = cleaned.firstIndex(of: "["),
           let end = cleaned.lastIndex(of: "]") {
            cleaned = String(cleaned[start...end])
        }

        guard let data = cleaned.data(using: .utf8),
              let scripts = try? JSONDecoder().decode([ImportedScript].self, from: data),
              !scripts.isEmpty
        else {
            return []
        }

        return scripts.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func loadPrompt(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("Missing prompt file: \(name).txt")
            return ""
        }
        return text
    }
}
